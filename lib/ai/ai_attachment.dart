import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../sim/ladder.dart';
import '../sim/zm2.dart';
import 'ai_settings.dart';

/// A picture or file the user adds to a chat message: a photo or drawing of a circuit or panel to copy, a ladder
/// program, a project, a list of parts.
class AiAttachment {
  const AiAttachment._(this.name, {this.image, this.mediaType, this.text});

  final String name;

  /// Image bytes as sent to the model (PNG or JPEG), or null for a text file.
  final Uint8List? image;
  final String? mediaType;

  /// The file's contents as text, or null for an image.
  final String? text;

  bool get isImage => image != null;

  /// Largest side of a picture sent to the model. Bigger pictures cost more and are scaled down by the endpoints
  /// anyway (Anthropic recommends at most 1568 px).
  static const int maxSide = 1568;

  /// Largest picture after re-encoding; Anthropic refuses images over 5 MB, this keeps well under it.
  static const int maxImageBytes = 3800 * 1024;

  /// Longest text file passed on, in characters.
  static const int maxText = 60000;

  static const imageExtensions = ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'];
  static const textExtensions = ['txt', 'md', 'csv', 'json', 'bwlad', 'bwproj', 'tdproj', 'xml', 'log'];
  static const otherExtensions = ['zm2'];
  static const allExtensions = [...imageExtensions, ...textExtensions, ...otherExtensions];

  /// Reads a picked, dropped or pasted file. Pictures are decoded and scaled down off the UI thread.
  /// Throws a [FormatException] with an Indonesian message for files that cannot be used.
  static Future<AiAttachment> load(String name, Uint8List bytes) async {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (imageExtensions.contains(ext)) return picture(name, bytes);
    if (ext == 'zm2') {
      // A Zelio Soft program: passed on as the ladder grid the assistant already reads and writes.
      final result = readZm2(bytes);
      final lines = ladderText(result.program);
      return AiAttachment._(name,
          text: 'Program Zelio${result.module.isEmpty ? '' : ' untuk modul ${result.module}'} (${lines.length} baris):\n${lines.join('\n')}');
    }
    if (textExtensions.contains(ext)) {
      var text = utf8.decode(bytes, allowMalformed: true);
      if (text.length > maxText) text = '${text.substring(0, maxText)}\n… [dipotong, file terlalu panjang]';
      return AiAttachment._(name, text: text);
    }
    throw FormatException('"$name" tidak bisa dilampirkan. Pakai gambar (${imageExtensions.join(', ')}) atau file teks (${textExtensions.join(', ')}, zm2).');
  }

  /// A picture from any source, e.g. the clipboard. Scaled to [maxSide] and re-encoded when it is large.
  static Future<AiAttachment> picture(String name, Uint8List bytes) async {
    final prepared = await compute(_prepareImage, bytes);
    if (prepared == null) throw FormatException('Gambar "$name" tidak bisa dibaca.');
    final (data, type) = prepared;
    if (data.length > maxImageBytes) throw FormatException('Gambar "$name" terlalu besar setelah diperkecil.');
    return AiAttachment._(name, image: data, mediaType: type);
  }

  /// Decodes, shrinks to [maxSide] and encodes: PNG for small images with sharp edges (screenshots, diagrams),
  /// JPEG when the PNG would be large (photos). Runs in a background isolate.
  static (Uint8List, String)? _prepareImage(Uint8List bytes) {
    try {
      final decoder = img.findDecoderForData(bytes);
      if (decoder == null) return null;
      final info = decoder.startDecode(bytes);
      if (info == null || info.width <= 0 || info.height <= 0 || info.width > 16384 || info.height > 16384 || info.width * info.height > 40000000) {
        return null;
      }
      final decoded = decoder.decodeFrame(0);
      if (decoded == null) return null;
      var picture = decoded;
      final side = picture.width > picture.height ? picture.width : picture.height;
      if (side > maxSide) {
        picture = picture.width >= picture.height
            ? img.copyResize(picture, width: maxSide, interpolation: img.Interpolation.average)
            : img.copyResize(picture, height: maxSide, interpolation: img.Interpolation.average);
      }
      final png = img.encodePng(picture, level: 6);
      if (png.length <= 1200 * 1024) return (png, 'image/png');
      return (img.encodeJpg(picture, quality: 85), 'image/jpeg');
    } catch (_) {
      return null;
    }
  }

  /// The text of a user message with its attachments, in the endpoint's format: content blocks with images first
  /// (both Anthropic and OpenAI read pictures best before the question), then the text with any text files.
  static Object content(ApiFormat format, String text, List<AiAttachment> attachments) {
    if (attachments.isEmpty) return text;
    final files = attachments.where((a) => !a.isImage);
    final images = attachments.where((a) => a.isImage).toList();
    final body = StringBuffer(text);
    for (final file in files) {
      body.write('\n\n[Lampiran ${file.name}]\n```\n${file.text}\n```');
    }
    if (images.isNotEmpty) {
      body.write('\n\n[${images.length} gambar terlampir: ${images.map((a) => a.name).join(', ')}]');
    }
    return [
      for (final a in images)
        switch (format) {
          ApiFormat.anthropic => {
              'type': 'image',
              'source': {'type': 'base64', 'media_type': a.mediaType, 'data': base64Encode(a.image!)},
            },
          ApiFormat.openai => {
              'type': 'image_url',
              'image_url': {'url': 'data:${a.mediaType};base64,${base64Encode(a.image!)}'},
            },
        },
      {'type': 'text', 'text': body.toString()},
    ];
  }

  /// Whether a history message carries a picture.
  static bool hasImage(Map<String, Object?> message) =>
      message['content'] is List && (message['content'] as List).any((b) => b is Map && (b['type'] == 'image' || b['type'] == 'image_url'));

  /// Replaces the pictures in a history message with a short note, so they are not sent again with every request.
  static void dropImages(Map<String, Object?> message, String note) {
    final content = message['content'];
    if (content is! List) return;
    final kept = content.where((b) => !(b is Map && (b['type'] == 'image' || b['type'] == 'image_url'))).toList();
    if (kept.length == content.length) return;
    message['content'] = [
      ...kept,
      {'type': 'text', 'text': note},
    ];
  }
}
