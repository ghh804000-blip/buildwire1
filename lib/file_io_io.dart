import 'dart:io';
import 'dart:typed_data';

/// Writes [bytes] to a sibling temp file then renames over [path], keeping the existing file intact if writing fails.
Future<void> writeBytesAtomically(String path, Uint8List bytes) async {
  final tmp = File('$path.tmp.${DateTime.now().microsecondsSinceEpoch}');
  try {
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  } catch (_) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}
