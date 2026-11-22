import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:buildwire/ai/ai_agent.dart';
import 'package:buildwire/ai/ai_attachment.dart';
import 'package:buildwire/ai/ai_connector.dart';
import 'package:buildwire/ai/ai_settings.dart';
import 'package:buildwire/app_state.dart';
import 'package:buildwire/model/device_def.dart';
import 'package:buildwire/sound.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

class Quiet extends SoundPlayer {
  @override
  Future<void> play(String name, bool enabled) async {}
  @override
  Future<void> setLoops(Set<String> names) async {}
  @override
  Future<void> mixLoop(String name, double volume, double rate) async {}
  @override
  Future<void> preload(Iterable<String> names) async {}
  @override
  Future<void> stopShots() async {}
}

AppState buildApp(ApiFormat format) {
  final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
  final defs = {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
  return AppState(defs, null, sound: Quiet(), secrets: MemorySecretStore('sk-test'))
    ..aiSettings = AiSettings(baseUrl: 'https://api.example/v1', format: format, model: 'model-x');
}

Uint8List png(int width, int height) => img.encodePng(img.Image(width: width, height: height)..clear(img.ColorRgb8(200, 120, 0)));

Map<String, Object?> openAiText(String text) => {
      'choices': [
        {
          'message': {'role': 'assistant', 'content': text},
          'finish_reason': 'stop',
        },
      ],
    };

Map<String, Object?> anthropicText(String text) => {
      'content': [
        {'type': 'text', 'text': text},
      ],
      'stop_reason': 'end_turn',
    };

void main() {
  test('a large picture is scaled down to 1568 px and a text file is read as text', () async {
    final picture = await AiAttachment.load('panel.png', png(3000, 1500));
    expect(picture.isImage, isTrue);
    final decoded = img.decodeImage(picture.image!)!;
    expect(decoded.width, AiAttachment.maxSide);
    expect(decoded.height, 784);

    final text = await AiAttachment.load('daftar.csv', Uint8List.fromList(utf8.encode('tag,perangkat\nQF1,MCB')));
    expect(text.isImage, isFalse);
    expect(text.text, contains('QF1,MCB'));

    expect(() => AiAttachment.load('lagu.mp3', Uint8List(4)), throwsA(isA<FormatException>()));
  });

  test('pictures go to each endpoint in its own format, before the text', () async {
    final picture = await AiAttachment.load('panel.png', png(40, 30));
    final note = await AiAttachment.load('catatan.txt', Uint8List.fromList(utf8.encode('pakai MCB 10 A')));

    final anthropic = AiAttachment.content(ApiFormat.anthropic, 'tiru ini', [picture, note]) as List;
    expect((anthropic.first as Map)['type'], 'image');
    expect(((anthropic.first as Map)['source'] as Map)['media_type'], 'image/png');
    expect(((anthropic.last as Map)['text'] as String), allOf(contains('tiru ini'), contains('pakai MCB 10 A'), contains('1 gambar terlampir')));

    final openai = AiAttachment.content(ApiFormat.openai, 'tiru ini', [picture]) as List;
    expect((openai.first as Map)['type'], 'image_url');
    expect(((openai.first as Map)['image_url'] as Map)['url'], startsWith('data:image/png;base64,'));

    expect(AiAttachment.content(ApiFormat.openai, 'tanpa lampiran', const []), 'tanpa lampiran');
  });

  test('the agent sends the picture, adds the copy-a-picture guide, and only sends the newest picture again', () async {
    final app = buildApp(ApiFormat.anthropic);
    final seen = <Map<String, dynamic>>[];
    final agent = AiAgent(app, connector: AiConnector(client: MockClient((request) async {
      seen.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(jsonEncode(anthropicText('Terlihat MCB QF1 dan kontaktor KM1.')), 200);
    })));
    final first = await AiAttachment.load('satu.png', png(20, 20));
    await agent.send('tiru gambar ini', attachments: [first]);
    expect(agent.entries.first.attachments.single.name, 'satu.png');
    final firstMessage = (seen.last['messages'] as List).first as Map;
    expect(((firstMessage['content'] as List).first as Map)['type'], 'image');
    expect(seen.last['system'] as String, contains('Kalau diminta meniru atau mengikuti gambar'));

    final second = await AiAttachment.load('dua.png', png(20, 20));
    await agent.send('', attachments: [second]);
    final messages = (seen.last['messages'] as List).cast<Map>();
    final withImages = messages.where((m) => m['content'] is List && (m['content'] as List).any((b) => (b as Map)['type'] == 'image')).toList();
    expect(withImages, hasLength(1), reason: 'the older picture is replaced by a note');
    expect(jsonEncode(messages.first), contains('sudah dilihat dan tidak dikirim ulang'));
    expect(agent.entries.where((e) => e.kind == ChatKind.user).last.text, 'Lihat lampiran ini.');
    app.dispose();
  });

  test('a model that cannot read pictures gets a clear message and the conversation carries on without them', () async {
    final app = buildApp(ApiFormat.openai);
    var turn = 0;
    final agent = AiAgent(app, connector: AiConnector(client: MockClient((request) async {
      turn++;
      if (turn == 1) return http.Response('{"error":{"message":"image input is not supported by this model"}}', 400);
      expect(request.body, isNot(contains('image_url')), reason: 'the refused picture is not sent again');
      return http.Response(jsonEncode(openAiText('Baik.')), 200);
    })));
    await agent.send('tiru ini', attachments: [await AiAttachment.load('panel.png', png(20, 20))]);
    expect(agent.entries.last.kind, ChatKind.error);
    expect(agent.entries.last.text, contains('tidak bisa membaca gambar'));
    await agent.send('lanjut tanpa gambar');
    expect(agent.entries.last.text, 'Baik.');
    app.dispose();
  });
}
