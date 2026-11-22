import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import 'file_io_stub.dart' if (dart.library.io) 'file_io_io.dart' as io;

const _projectType = XTypeGroup(label: 'Proyek BuildWire', extensions: ['bwproj', 'tdproj']);
const _maxBytes = 16 * 1024 * 1024;

String _decodeUtf8(Uint8List bytes, String kind) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw FormatException('File bukan teks UTF-8 yang valid untuk $kind.');
  }
}

/// Returns the chosen file's text, or null if the user cancelled.
/// Throws [FormatException] with a message for the user when the file can't be used.
Future<String?> pickProjectText() async {
  final file = await openFile(acceptedTypeGroups: const [_projectType]);
  if (file == null) return null;
  if (await file.length() > _maxBytes) {
    throw const FormatException('File terlalu besar untuk proyek BuildWire (maksimal 16 MB).');
  }
  return _decodeUtf8(await file.readAsBytes(), 'proyek BuildWire');
}

String _safeName(String projectName, String fallback) {
  final safe = projectName.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
  return safe.isEmpty ? fallback : safe;
}

/// Saves bytes, asking for a location on desktop. Returns false if the user cancelled.
Future<bool> saveBytes({required String baseName, required String extension, required String label, required String mimeType, required Uint8List bytes}) async {
  final name = '${_safeName(baseName, 'proyek')}.$extension';
  if (kIsWeb) {
    await XFile.fromData(bytes, name: name, mimeType: mimeType).saveTo(name);
    return true;
  }
  final location = await getSaveLocation(suggestedName: name, acceptedTypeGroups: [XTypeGroup(label: label, extensions: [extension])]);
  if (location == null) return false;
  var path = location.path;
  if (extension.isNotEmpty && !path.toLowerCase().endsWith('.${extension.toLowerCase()}')) {
    path = '$path.$extension';
  }
  await io.writeBytesAtomically(path, bytes);
  return true;
}

Future<bool> saveProjectText(String projectName, String text) =>
    saveBytes(baseName: projectName, extension: 'bwproj', label: 'Proyek BuildWire', mimeType: 'application/json', bytes: Uint8List.fromList(utf8.encode(text)));

Future<bool> saveCsv(String projectName, String text) => saveBytes(
      baseName: '$projectName material',
      extension: 'csv',
      label: 'CSV',
      mimeType: 'text/csv',
      // A byte order mark lets Excel read the file as UTF-8.
      bytes: Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]),
    );

Future<bool> savePng(String projectName, Uint8List bytes) =>
    saveBytes(baseName: projectName, extension: 'png', label: 'Gambar PNG', mimeType: 'image/png', bytes: bytes);

const _ladderTypes = [
  XTypeGroup(label: 'Program ladder (BuildLadder, Zelio)', extensions: ['bwlad', 'zm2']),
];

/// A ladder file the user picked: its name and bytes, or null if cancelled. Opens BuildLadder (.bwlad) and Zelio Soft 2
/// (.zm2) files.
Future<(String, Uint8List)?> pickLadderFile() async {
  final file = await openFile(acceptedTypeGroups: _ladderTypes);
  if (file == null) return null;
  if (await file.length() > _maxBytes) throw const FormatException('File terlalu besar (maksimal 16 MB).');
  return (file.name, await file.readAsBytes());
}

Future<bool> saveLadderText(String name, String text) =>
    saveBytes(baseName: name, extension: 'bwlad', label: 'Program ladder BuildLadder', mimeType: 'application/json', bytes: Uint8List.fromList(utf8.encode(text)));

/// Saves a ladder program, offering Zelio Soft 2 (.zm2) first when [zm2] is given and BuildLadder (.bwlad) always.
/// Returns the extension written, or null if the user cancelled.
Future<String?> saveLadderFile(String baseName, {Uint8List? zm2, required String bwlad}) async {
  final first = zm2 != null ? 'zm2' : 'bwlad';
  final suggested = '${_safeName(baseName, 'program')}.$first';
  if (kIsWeb) {
    final bytes = zm2 ?? Uint8List.fromList(utf8.encode(bwlad));
    final mime = zm2 != null ? 'application/octet-stream' : 'application/json';
    await XFile.fromData(bytes, name: suggested, mimeType: mime).saveTo(suggested);
    return first;
  }
  final groups = [
    if (zm2 != null) const XTypeGroup(label: 'Zelio Soft 2 (.zm2)', extensions: ['zm2']),
    const XTypeGroup(label: 'BuildLadder (.bwlad)', extensions: ['bwlad']),
  ];
  final location = await getSaveLocation(suggestedName: suggested, acceptedTypeGroups: groups);
  if (location == null) return null;
  var path = location.path;
  final lower = path.toLowerCase();
  if (!lower.endsWith('.zm2') && !lower.endsWith('.bwlad')) {
    path = '$path.${location.activeFilter?.extensions?.first ?? first}';
  }
  final asZm2 = zm2 != null && path.toLowerCase().endsWith('.zm2');
  final bytes = asZm2 ? zm2 : Uint8List.fromList(utf8.encode(bwlad));
  await io.writeBytesAtomically(path, bytes);
  return asZm2 ? 'zm2' : 'bwlad';
}

const _relayTypes = [XTypeGroup(label: 'Diagram BuildRelay', extensions: ['bwrelay'])];

/// A BuildRelay diagram the user picked: its name and text, or null if cancelled.
Future<(String, String)?> pickRelayFile() async {
  final file = await openFile(acceptedTypeGroups: _relayTypes);
  if (file == null) return null;
  if (await file.length() > _maxBytes) throw const FormatException('File terlalu besar (maksimal 16 MB).');
  return (file.name, _decodeUtf8(await file.readAsBytes(), 'diagram BuildRelay'));
}

Future<bool> saveRelayFile(String name, String text) =>
    saveBytes(baseName: name, extension: 'bwrelay', label: 'Diagram BuildRelay', mimeType: 'application/json', bytes: Uint8List.fromList(utf8.encode(text)));
