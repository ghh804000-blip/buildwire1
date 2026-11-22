import 'dart:convert';
import 'dart:typed_data';

import 'ladder.dart';

/// What came out of a Zelio Soft 2 file.
class Zm2Import {
  const Zm2Import(this.program, this.module, this.warnings);

  final LadderProgram program;

  /// The module the program was written for, e.g. SR3B261FU.
  final String module;

  /// Parts BuildWire does not simulate (clocks, analog comparators, texts …), named once each.
  final List<String> warnings;
}

// The Zelio Soft 2 `.zm2` format, as far as it was worked out (for interoperability) from files saved by Zelio Soft
// itself; see tools/zelio_zm2_format.md.
//
// The ladder sheet is a run of named records `P1, P2 …` (`len:u32, name, NUL, value:u32`): P1 is the row count, then
// six cells per row (five contacts and the coil), then the file's own table of element types, which maps the cell
// codes to names like I1, Q3 or TT1. Every file also carries 28 timer blocks (P2_MODE, O2R_VALEUR CONSIGNE_T,
// O4R_VALEUR CONSIGNE_T) and 28 counter blocks (P2_SENS_PRESELECTION, O2R_VALEUR DE PRESELECTION), in item order.

/// Timer function codes in P2_MODE. 1 (A) and 3 (C) were confirmed; the rest follow the order of Zelio's dialog.
const Map<int, String> _modes = {1: 'A', 2: 'a', 3: 'C', 4: 'B', 5: 'W', 6: 'D', 7: 'PD', 8: 'T', 9: 'AC', 10: 'L', 11: 'I'};

/// Coil kind characters in the element table: 0xFA contactor `[`, 0x12 impulse, then letters.
const Map<int, String> _kinds = {0xFA: '[', 0x12: '^', 0x53: 'S', 0x52: 'R', 0x54: 'T', 0x43: 'C', 0x44: 'D'};

class _Type {
  const _Type(this.letter, this.count, this.firstIndex, this.first, this.kinds);
  final String letter;
  final int count;
  final String firstIndex;
  final int first;
  final List<int> kinds;

  int get per => 1 + kinds.length;
  String label(int item) {
    final base = kLadderIndex.indexOf(firstIndex);
    return base >= 0 && base + item < kLadderIndex.length ? kLadderIndex[base + item] : '${item + 1}';
  }
}

class _Sheet {
  _Sheet(this.bytes) : data = ByteData.sublistView(bytes) {
    if (bytes.length < 16 || ascii.decode(bytes.sublist(0, 12), allowInvalid: true) != 'SCHNEIDER_Z2') {
      throw const FormatException('Bukan file Zelio Soft 2 (.zm2).');
    }
    final start = _find(bytes, const [2, 0, 0, 0, 0x50, 0x31, 0]);
    if (start < 0) throw const FormatException('File Zelio ini tidak berisi lembar ladder (mungkin FBD).');
    tableStart = start;
    var at = start;
    while (at + 9 < bytes.length) {
      final n = data.getUint32(at, Endian.little);
      if (n < 2 || n > 6 || at + 9 + n > bytes.length || bytes[at + 4] != 0x50 || bytes[at + 4 + n] != 0) break;
      final number = int.tryParse(ascii.decode(bytes.sublist(at + 5, at + 4 + n), allowInvalid: true));
      if (number == null) break;
      values[number] = data.getUint32(at + 5 + n, Endian.little);
      offsets[number] = at + 5 + n;
      at += n + 9;
    }
    rows = values[1] ?? 0;
    if (rows <= 0 || rows > 1000) throw const FormatException('Lembar ladder di file Zelio tidak terbaca.');
    var k = 3 + rows * 6;
    while (values.containsKey(k) && values[k]! >= 0x41 && values[k]! <= 0x5A) {
      final kindCount = values[k + 5] ?? 0;
      final count = values[k + 2] ?? 0;
      final firstCode = values[k + 3] ?? 0x31;
      if (kindCount < 0 || kindCount > 32 || count < 0 || count > 256 || firstCode < 0 || firstCode > 0x10FFFF) break;
      final kinds = [for (var j = 0; j < kindCount; j++) values[k + 6 + j] ?? 0];
      types.add(_Type(String.fromCharCode(values[k]!), count, String.fromCharCode(firstCode), values[k + 4] ?? 0, kinds));
      k += 6 + kinds.length;
    }
  }

  final Uint8List bytes;
  final ByteData data;
  final Map<int, int> values = {};
  final Map<int, int> offsets = {};
  final List<_Type> types = [];
  late final int rows;
  late final int tableStart;

  int cell(int row, int col) => values[3 + row * 6 + col] ?? 0;

  /// (name, kind character or 0 for a contact) for a cell code.
  (String, int)? lookup(int code) {
    for (final t in types) {
      if (code >= t.first && code < t.first + t.count * t.per) {
        final item = (code - t.first) ~/ t.per;
        final part = (code - t.first) % t.per;
        return ('${t.letter}${t.label(item)}', part == 0 ? 0 : t.kinds[part - 1]);
      }
    }
    return null;
  }

  /// The cell code for a contact (kind null) or a coil kind of an item, or null when this module has no such item.
  int? code(String ref, String? kind) {
    if (ref.length < 2) return null;
    final letter = ref[0];
    final label = ref.substring(1);
    for (final t in types.where((t) => t.letter == letter)) {
      for (var item = 0; item < t.count; item++) {
        if (t.label(item) != label) continue;
        if (kind == null) return t.first + item * t.per;
        final index = t.kinds.indexWhere((c) => _kinds[c] == kind);
        return index < 0 ? null : t.first + item * t.per + 1 + index;
      }
    }
    return null;
  }

  /// Offsets of the value after each occurrence of a record name, in file order.
  List<int> fields(String name) {
    // With the length in front, so PRESELECTION does not also match the end of P2_SENS_PRESELECTION.
    final pattern = [name.length, 0, 0, 0, ...ascii.encode(name), 0];
    final out = <int>[];
    var at = 0;
    while (true) {
      final i = _find(bytes, pattern, at);
      if (i < 0) return out;
      out.add(i + pattern.length);
      at = i + 1;
    }
  }

  int u32(int at) {
    if (at < 0 || at + 4 > bytes.length) throw const FormatException('File Zelio Soft 2 rusak.');
    return data.getUint32(at, Endian.little);
  }

  void setU32(int at, int value) {
    if (at < 0 || at + 4 > bytes.length) throw const FormatException('File Zelio Soft 2 rusak.');
    data.setUint32(at, value, Endian.little);
  }
}

/// Reads the ladder program from a Zelio Soft 2 `.zm2` file.
Zm2Import readZm2(Uint8List bytes) {
  final sheet = _Sheet(bytes);
  final warnings = <String>{};
  const simulated = {'I', 'Q', 'M', 'N', 'T', 'C', 'Z'};
  (String, int)? lookup(int code) {
    final found = sheet.lookup(code);
    if (found != null && !simulated.contains(found.$1[0])) warnings.add(found.$1);
    return found;
  }

  final comments = _comments(sheet);
  final program = LadderProgram();
  for (var r = 0; r < sheet.rows && r < LadderProgram.maxRows; r++) {
    final cells = <LadderCell>[];
    LadderCoil? coil;
    var any = false;
    for (var c = 0; c < 6; c++) {
      final v = sheet.cell(r, c);
      if (v & 0x43FF != 0) any = true;
      final code = v & 0x3FF;
      final down = v & 0x4000 != 0;
      if (c == 5) {
        if (code > 1) {
          final found = lookup(code);
          final fn = found == null ? null : _kinds[found.$2];
          if (fn != null) coil = LadderCoil(fn, found!.$1);
        }
        continue;
      }
      if (code == 0) {
        cells.add(LadderCell.empty(down: down));
      } else if (code == 1) {
        cells.add(LadderCell.wire(down: down));
      } else {
        final found = lookup(code);
        cells.add(found == null ? LadderCell.empty(down: down) : LadderCell.contact(found.$1, nc: v & 0x400 != 0, down: down));
      }
    }
    final comment = r < comments.length ? comments[r] : '';
    program.rows.add(any || comment.isNotEmpty ? LadderRow(cells: cells, coil: coil, comment: comment) : LadderRow());
  }
  while (program.rows.isNotEmpty && program.rows.last.isEmpty) {
    program.rows.removeLast();
  }

  // Timer and counter blocks are in item order: block k belongs to T(k+1) and C(k+1).
  final modes = sheet.fields('P2_MODE');
  final first = sheet.fields('O2R_VALEUR CONSIGNE_T'), second = sheet.fields('O4R_VALEUR CONSIGNE_T');
  for (final ref in program.used('T')) {
    final k = kLadderIndex.indexOf(ref.substring(1));
    if (k < 0 || k >= modes.length || k >= first.length || k >= second.length) continue;
    final t1 = sheet.u32(first[k]) / 10, t2 = sheet.u32(second[k]) / 10;
    program.timer(ref)
      ..function = _modes[sheet.u32(modes[k])] ?? 'A'
      ..preset = t1 > 0 ? t1 : 1
      ..preset2 = t2 > 0 ? t2 : 1;
  }
  final targets = sheet.fields('O2R_VALEUR DE PRESELECTION');
  final senses = sheet.fields('P2_SENS_PRESELECTION');
  for (final ref in program.used('C')) {
    final k = kLadderIndex.indexOf(ref.substring(1));
    if (k < 0 || k >= targets.length) continue;
    program.counter(ref)
      ..preset = sheet.u32(targets[k])
      ..toZero = k < senses.length && sheet.u32(senses[k]) == 1;
  }
  return Zm2Import(program, _module(bytes), warnings.toList()..sort());
}

/// Row comments, when the file has the table: 240 entries of a NUL-terminated string and two bytes, after a 240 count.
List<String> _comments(_Sheet sheet) {
  final bytes = sheet.bytes;
  final at = _findLast(bytes, const [1, 1, 0xF0, 0, 0, 0], sheet.tableStart);
  if (at < 0) return const [];
  final out = <String>[];
  var i = at + 6;
  for (var r = 0; r < 240 && i < sheet.tableStart; r++) {
    var end = i;
    while (end < bytes.length && bytes[end] != 0) {
      end++;
    }
    if (end - i > 64) return const [];
    out.add(latin1.decode(bytes.sublist(i, end)));
    i = end + 3;
  }
  return out;
}

/// Writes [program] into a copy of [template], an empty program saved by Zelio Soft for the same module. Only fixed-size
/// values change (the grid cells, timer and counter settings), so the file keeps Zelio's own structure. Row comments
/// are not written. Throws [FormatException] naming items the module does not have.
Uint8List writeZm2(LadderProgram program, Uint8List template) {
  final out = Uint8List.fromList(template);
  final sheet = _Sheet(out);
  final missing = <String>{};
  void put(int record, int value) {
    final at = sheet.offsets[record];
    if (at != null) sheet.setU32(at, value);
  }

  if (program.rows.length > sheet.rows) throw FormatException('Program lebih dari ${sheet.rows} baris.');
  for (var r = 0; r < sheet.rows; r++) {
    final row = r < program.rows.length ? program.rows[r] : null;
    final above = r > 0 && r - 1 < program.rows.length ? program.rows[r - 1] : null;
    for (var c = 0; c < 5; c++) {
      final cell = row?.cells[c] ?? const LadderCell.empty();
      var v = 0;
      if (cell.wire) v = 1;
      if (cell.ref != null) {
        final code = sheet.code(cell.ref!, null);
        if (code == null) {
          missing.add(cell.ref!);
        } else {
          v = code | (cell.nc ? 0x400 : 0);
        }
      }
      if (cell.down) v |= 0x4000;
      // Zelio marks the cell a vertical link arrives at, too.
      if (above?.cells[c].down ?? false) v |= 0x8000;
      put(3 + r * 6 + c, v);
    }
    var coil = 0;
    final target = row?.coil;
    if (target != null) {
      final code = sheet.code(target.ref, target.fn);
      code == null ? missing.add(target.text) : coil = code;
    }
    put(3 + r * 6 + 5, coil);
  }
  if (missing.isNotEmpty) throw FormatException('Modul ini tidak punya: ${missing.join(', ')}.');

  final modes = sheet.fields('P2_MODE');
  final first = sheet.fields('O2R_VALEUR CONSIGNE_T'), second = sheet.fields('O4R_VALEUR CONSIGNE_T');
  final inverse = {for (final e in _modes.entries) e.value: e.key};
  for (final e in program.timers.entries) {
    final k = kLadderIndex.indexOf(e.key.substring(1));
    if (k < 0 || k >= modes.length || k >= first.length || k >= second.length) continue;
    sheet.setU32(modes[k], inverse[e.value.function] ?? 1);
    sheet.setU32(first[k], (e.value.preset * 10).round().clamp(0, 99999));
    sheet.setU32(second[k], e.value.hasSecond ? (e.value.preset2 * 10).round().clamp(0, 99999) : 0);
  }
  final targets = sheet.fields('O2R_VALEUR DE PRESELECTION');
  final senses = sheet.fields('P2_SENS_PRESELECTION');
  for (final e in program.counters.entries) {
    final k = kLadderIndex.indexOf(e.key.substring(1));
    if (k < 0 || k >= targets.length) continue;
    sheet.setU32(targets[k], e.value.preset.clamp(0, 32767));
    if (k < senses.length) sheet.setU32(senses[k], e.value.toZero ? 1 : 0);
  }
  return out;
}

String _module(Uint8List bytes) {
  final at = _find(bytes, ascii.encode('SR'), 0, 4096);
  if (at < 0) return '';
  var end = at;
  while (end < bytes.length && end - at < 16 && bytes[end] >= 0x30 && bytes[end] <= 0x5A) {
    end++;
  }
  return ascii.decode(bytes.sublist(at, end), allowInvalid: true);
}

int _find(Uint8List bytes, List<int> pattern, [int from = 0, int? limit]) {
  final cap = limit == null || limit > bytes.length ? bytes.length : limit;
  final end = cap - pattern.length;
  outer:
  for (var i = from; i <= end; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}

int _findLast(Uint8List bytes, List<int> pattern, int before) {
  outer:
  for (var i = before - pattern.length; i >= 0; i--) {
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}
