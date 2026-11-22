import 'dart:convert';

import '../model/device_def.dart';
import '../sim/ladder.dart';
import '../sim/plc.dart';
import 'ai_agent.dart';
import 'ai_connector.dart';
import 'circuit_tools.dart';

class _Fail implements Exception {
  _Fail(this.message);
  final String message;
}

/// The assistant inside BuildLadder: it reads, writes and tests the ladder program open in the editor.
class LadderWorkspace extends AgentWorkspace {
  LadderWorkspace({required this.def, required this.read, required this.write});

  /// The PLC model being programmed.
  final DeviceDef Function() def;
  final LadderProgram Function() read;

  /// Puts a new program in the editor.
  final void Function(LadderProgram program) write;

  @override
  Set<String> get editingTools => const {'tulis_program', 'ubah_baris', 'atur_parameter'};
  @override
  String get testTool => 'uji_program';

  @override
  String context() {
    final program = read();
    return 'Editor BuildLadder: PLC ${def().name}, program ${program.rows.where((r) => !r.isEmpty).length} baris.';
  }

  // ----- Addresses for this model

  bool get _zelio => def().isZelio;
  List<String> get _memory => _zelio ? ladderNames('M', 28) : kPlcMemory;
  List<String> get _timers => ladderNames('T', _zelio ? 28 : 16);
  List<String> get _counters => ladderNames('C', _zelio ? 28 : 16);
  List<String> get _clocks => ladderNames('H', 8);
  Set<String> get _contacts => {...def().plcInputs, 'Z1', 'Z2', 'Z3', 'Z4', ...def().plcOutputs, ..._memory, ..._timers, ..._counters, ..._clocks};

  String get _addresses => 'Input ${def().plcInputs.join(' ')}; output ${def().plcOutputs.join(' ')}; relay bantu ${_memory.first}..${_memory.last}; '
      'timer ${_timers.first}..${_timers.last}; counter ${_counters.first}..${_counters.last}; jam (jadwal) H1..H8; tombol panah Z1-Z4.';

  @override
  String get systemPrompt => '''
Kamu asisten pemrograman PLC di BuildLadder, editor ladder bergaya Zelio Soft di aplikasi BuildWire. Kamu menulis program langsung di grid editor memakai alat, lalu mengujinya sendiri dengan uji_program. Jawab dalam bahasa Indonesia yang singkat dan jelas, tanpa menampilkan JSON.

PLC yang sedang diprogram: ${def().name}. Alamat yang tersedia: $_addresses

Grid ladder:
- Tiap baris punya 5 sel kontak lalu 1 koil. Sel ditulis sebagai teks: "I1" kontak NO, "!I1" kontak NC, "-" garis horizontal, "" sel kosong (memutus).
- Akhiran "|" pada sebuah sel = garis vertikal dari tepi kanan sel itu ke baris di bawahnya, untuk cabang paralel. Contoh self-holding start I1, stop NC I2, output Q1:
  baris 1: ["I1|", "!I2", "-", "-", "-"] koil "[Q1"
  baris 2: ["Q1", "", "", "", ""] tanpa koil
  Garis vertikal di tepi kanan sel 1 menyatukan I1 dan Q1, lalu lewat !I2 ke koil Q1.
- Dua koil paralel (satu kondisi menggerakkan dua koil): beri "|" pada sel ke-5 baris atas, baris bawah sel-selnya kosong dan punya koil sendiri.
- Sel antara kontak terakhir dan koil harus diisi "-" supaya tersambung.
- Koil (notasi Zelio): "[Q1" koil biasa, "^Q1" impuls/toggle, "SQ1" set (kunci), "RQ1" reset, juga untuk M. "TT1" perintah timer, "RT1" reset timer. "CC1" hitung naik, "DC1" arah turun selama aktif, "RC1" reset counter.
- Kontak T1 menyala saat keluaran timer aktif; kontak C1 menyala saat counter mencapai target.
- Kontak H1..H8 adalah blok jam (time switch): menyala saat jam PLC berada di salah satu jadwalnya (hari MO..SU, jam ON sampai OFF; OFF lebih kecil dari ON berarti lewat tengah malam). Atur jadwalnya dengan atur_parameter "jam". H hanya kontak, tidak punya koil. Uji dengan aksi "atur_jam" lalu "tunggu".
- CC, ^ (impuls), dan fungsi timer B/W/a/PD/I sudah bereaksi pada tepi naik sendiri; tidak perlu membuat rangkaian deteksi tepi dengan relay M.
- Fungsi timer: A tunda nyala selama perintah aktif, a tunda nyala start/stop dengan pulsa, C tunda padam, B pulsa sekali saat perintah naik, W pulsa sekali saat perintah turun, D kedip simetris, PD kedip start/stop pulsa, T totalisator, AC tunda nyala lalu tunda padam (detik dan detik2), L kedip asimetris (detik nyala, detik2 padam), I kedip asimetris start/stop pulsa.
- Baris dibaca dari atas ke bawah setiap scan.

Cara kerja:
1. Kalau pengguna minta memeriksa atau mengubah program, lihat_program dulu. Kalau minta program baru, tulis_program (mengganti semuanya). Untuk perubahan kecil pakai ubah_baris.
2. Beri nama simbol pada input/output yang penting (misalnya I1 Start, Q1 Motor) dan komentar singkat per baris.
3. WAJIB uji dengan uji_program sebelum selesai: nyalakan/matikan input, tekan tombol (pulsa), tunggu timer, lalu periksa output yang diharapkan. Uji juga kondisi stop dan pengaman. Kalau salah, perbaiki lalu uji lagi.
4. Akhiri dengan penjelasan singkat cara kerja program dan cara mencobanya. Ingatkan bahwa program ada di editor: tekan Kirim ke PLC (atau Simpan file / Simulasi) untuk memakainya.
''';

  @override
  List<AiTool> get tools => [
        AiTool(
          name: 'lihat_program',
          description: 'Isi program ladder yang terbuka di editor, model PLC dan alamat yang tersedia, timer, counter, dan simbol.',
          schema: {'type': 'object', 'properties': <String, Object>{}},
        ),
        AiTool(
          name: 'tulis_program',
          description: 'Mengganti seluruh program di editor. Tiap baris: 5 sel kontak dan koil (opsional). Bisa sekalian mengatur timer, counter, dan simbol.',
          schema: {
            'type': 'object',
            'properties': {
              'baris': _rowsSchema,
              ..._parameterSchema,
            },
            'required': ['baris'],
          },
        ),
        AiTool(
          name: 'ubah_baris',
          description: 'Mengganti atau menghapus baris tertentu (nomor mulai 1) tanpa menyentuh baris lain. Baris yang belum ada akan dibuat.',
          schema: {
            'type': 'object',
            'properties': {
              'baris': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {'no': {'type': 'integer'}, ..._rowProperties},
                  'required': ['no', 'kontak'],
                },
              },
              'hapus': {'type': 'array', 'items': {'type': 'integer'}, 'description': 'Nomor baris yang dihapus (baris di bawahnya naik).'},
            },
          },
        ),
        AiTool(
          name: 'atur_parameter',
          description: 'Mengatur fungsi dan waktu timer, target counter, dan nama simbol.',
          schema: {'type': 'object', 'properties': _parameterSchema},
        ),
        AiTool(
          name: 'uji_program',
          description: 'Menjalankan program di simulator dari awal dengan langkah-langkah, lalu melaporkan perubahan output, relay, timer, dan counter tiap langkah. '
              'Aksi: "nyala"/"mati" (input atau Z tetap), "tekan" (pulsa singkat), "tunggu" (detik, waktu disimulasikan), "atur_jam" (hari MO..SU dan waktu HH:MM untuk jam PLC, mulai Senin 00:00). WAJIB dipakai sebelum selesai.',
          schema: {
            'type': 'object',
            'properties': {
              'langkah': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'aksi': {'type': 'string', 'enum': ['nyala', 'mati', 'tekan', 'tunggu', 'atur_jam']},
                    'alamat': {'type': 'string'},
                    'detik': {'type': 'number'},
                    'hari': {'type': 'string', 'description': 'Untuk atur_jam: MO..SU.'},
                    'waktu': {'type': 'string', 'description': 'Untuk atur_jam: HH:MM.'},
                  },
                  'required': ['aksi'],
                },
              },
            },
            'required': ['langkah'],
          },
        ),
      ];

  static const Map<String, Object> _rowProperties = {
    'kontak': {
      'type': 'array',
      'items': {'type': 'string'},
      'description': '5 sel: "I1", "!I2" (NC), "-" garis, "" kosong; akhiran "|" untuk garis vertikal ke baris bawah.',
    },
    'koil': {'type': 'string', 'description': 'Misalnya "[Q1", "SQ1", "RQ1", "^M1", "TT1", "RT1", "CC1", "RC1". Kosongkan bila tidak ada.'},
    'komentar': {'type': 'string'},
  };

  static const Map<String, Object> _rowsSchema = {
    'type': 'array',
    'items': {'type': 'object', 'properties': _rowProperties, 'required': ['kontak']},
  };

  static const Map<String, Object> _parameterSchema = {
    'timer': {
      'type': 'object',
      'description': 'Per timer, misalnya {"T1": {"fungsi": "A", "detik": 5}}; "detik2" untuk AC, L, I.',
    },
    'counter': {'type': 'object', 'description': 'Per counter, misalnya {"C1": {"target": 10, "ke_nol": false}}.'},
    'simbol': {'type': 'object', 'description': 'Nama alamat, misalnya {"I1": "Start", "Q1": "Motor"}.'},
    'jam': {
      'type': 'object',
      'description': 'Jadwal blok jam, sampai 4 per blok, misalnya {"H1": [{"hari": ["MO","TU","WE","TH","FR"], "on": "08:00", "off": "17:00"}]}.',
    },
  };

  // ----- Running tools

  @override
  Future<ToolOutcome> run(String name, Map<String, dynamic> input) async {
    try {
      return switch (name) {
        'lihat_program' => _look(),
        'tulis_program' => _writeAll(input),
        'ubah_baris' => _editRows(input),
        'atur_parameter' => _parameters(input),
        'uji_program' => _test(input),
        _ => throw _Fail('Alat "$name" tidak ada.'),
      };
    } on _Fail catch (fail) {
      return ToolOutcome(jsonEncode({'galat': fail.message}), fail.message, error: true);
    } catch (error) {
      return ToolOutcome(jsonEncode({'galat': 'Masukan tidak bisa diproses: $error'}), 'Masukan tidak valid', error: true);
    }
  }

  Map<String, Object?> _describe(LadderProgram program) => {
        'plc': def().name,
        'alamat': _addresses,
        'baris': ladderText(program),
        if (program.timers.isNotEmpty) 'timer': {for (final e in program.timers.entries) e.key: e.value.toJson()},
        if (program.counters.isNotEmpty) 'counter': {for (final e in program.counters.entries) e.key: e.value.toJson()},
        if (program.clocks.isNotEmpty)
          'jam': {
            for (final e in program.clocks.entries)
              e.key: [
                for (final s in e.value.slots) {'hari': [for (final d in s.days.toList()..sort()) kPlcDays[d - 1]], 'on': clockText(s.on), 'off': clockText(s.off)},
              ],
          },
        if (program.symbols.isNotEmpty) 'simbol': program.symbols,
      };

  ToolOutcome _look() => ToolOutcome(jsonEncode(_describe(read())), 'Melihat program');

  LadderRow _row(Map<String, dynamic> item, String where) {
    final raw = item['kontak'];
    final texts = raw is List ? raw.map((e) => '$e').toList() : <String>[];
    if (texts.length > LadderProgram.columns) throw _Fail('$where: paling banyak ${LadderProgram.columns} sel kontak.');
    while (texts.length < LadderProgram.columns) {
      texts.add('');
    }
    final cells = <LadderCell>[];
    for (final text in texts) {
      final cell = LadderCell.parse(text);
      if (cell.ref != null && !_contacts.contains(cell.ref)) {
        throw _Fail('$where: kontak "$text" tidak ada di PLC ini. $_addresses');
      }
      cells.add(cell);
    }
    LadderCoil? coil;
    final coilText = '${item['koil'] ?? ''}'.trim();
    if (coilText.isNotEmpty) {
      coil = LadderCoil.parse(RegExp(r'^[QMN][0-9A-Z]+$').hasMatch(coilText.toUpperCase()) ? '[$coilText' : coilText);
      final ref = coil?.ref ?? '';
      final ok = coil != null &&
          switch (coil.fn) {
            '[' || '^' || 'S' => def().plcOutputs.contains(ref) || _memory.contains(ref),
            'R' => def().plcOutputs.contains(ref) || _memory.contains(ref) || _timers.contains(ref) || _counters.contains(ref),
            'T' => _timers.contains(ref),
            'C' || 'D' => _counters.contains(ref),
            _ => false,
          };
      if (!ok) throw _Fail('$where: koil "$coilText" tidak valid untuk PLC ini.');
    }
    return LadderRow(cells: cells, coil: coil, comment: '${item['komentar'] ?? ''}');
  }

  void _applyParameters(LadderProgram program, Map<String, dynamic> input) {
    final timers = input['timer'];
    if (timers is Map) {
      for (final e in timers.entries) {
        final ref = '${e.key}'.toUpperCase();
        if (!_timers.contains(ref) || e.value is! Map) throw _Fail('Timer "${e.key}" tidak valid.');
        final v = e.value as Map;
        final timer = program.timer(ref);
        final fn = '${v['fungsi'] ?? timer.function}';
        timer.function = LadderTimer.functions.containsKey(fn) ? fn : (LadderTimer.functions.containsKey(fn.toUpperCase()) ? fn.toUpperCase() : 'A');
        if (v['detik'] is num) timer.preset = (v['detik'] as num).toDouble().clamp(0.1, 9999);
        if (v['detik2'] is num) timer.preset2 = (v['detik2'] as num).toDouble().clamp(0.1, 9999);
      }
    }
    final counters = input['counter'];
    if (counters is Map) {
      for (final e in counters.entries) {
        final ref = '${e.key}'.toUpperCase();
        if (!_counters.contains(ref) || e.value is! Map) throw _Fail('Counter "${e.key}" tidak valid.');
        final v = e.value as Map;
        final counter = program.counter(ref);
        if (v['target'] is num) counter.preset = (v['target'] as num).toInt().clamp(0, 32767);
        if (v['ke_nol'] is bool) counter.toZero = v['ke_nol'] as bool;
      }
    }
    final clocks = input['jam'];
    if (clocks is Map) {
      for (final e in clocks.entries) {
        final ref = '${e.key}'.toUpperCase();
        if (!_clocks.contains(ref) || e.value is! List) throw _Fail('Jam "${e.key}" tidak valid (H1..H8 dengan daftar jadwal).');
        final slots = <ClockSlot>[];
        for (final item in (e.value as List).whereType<Map<String, dynamic>>().take(LadderClock.maxSlots)) {
          final days = <int>{
            for (final d in item['hari'] as List<dynamic>? ?? const [])
              if (kPlcDays.contains('$d'.toUpperCase())) kPlcDays.indexOf('$d'.toUpperCase()) + 1,
          };
          final on = _minuteOf(item['on']), off = _minuteOf(item['off']);
          if (days.isEmpty || on == null || off == null) throw _Fail('Jadwal $ref perlu "hari" (MO..SU), "on" dan "off" (HH:MM).');
          slots.add(ClockSlot(days: days, on: on, off: off));
        }
        program.clocks[ref] = LadderClock(slots: slots);
      }
    }
    final symbols = input['simbol'];
    if (symbols is Map) {
      for (final e in symbols.entries) {
        final ref = '${e.key}'.toUpperCase();
        final name = '${e.value}'.trim();
        name.isEmpty ? program.symbols.remove(ref) : program.symbols[ref] = name;
      }
    }
  }

  ToolOutcome _writeAll(Map<String, dynamic> input) {
    final items = (input['baris'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();
    if (items.isEmpty) throw _Fail('Daftar baris kosong.');
    if (items.length > LadderProgram.maxRows) throw _Fail('Paling banyak ${LadderProgram.maxRows} baris.');
    final program = LadderProgram(symbols: {...read().symbols});
    for (var i = 0; i < items.length; i++) {
      program.rows.add(_row(items[i], 'Baris ${i + 1}'));
    }
    // Keep the old settings of timers and counters still in use, then apply the new ones.
    final old = read();
    for (final t in program.used('T')) {
      if (old.timers[t] != null) program.timers[t] = LadderTimer.fromJson(old.timers[t]!.toJson());
    }
    for (final c in program.used('C')) {
      if (old.counters[c] != null) program.counters[c] = LadderCounter.fromJson(old.counters[c]!.toJson());
    }
    for (final h in program.usedClocks) {
      if (old.clocks[h] != null) program.clocks[h] = LadderClock.fromJson(old.clocks[h]!.toJson());
    }
    _applyParameters(program, input);
    write(program);
    return ToolOutcome(jsonEncode({'ok': true, ..._describe(program)}), 'Menulis program (${program.rows.length} baris)');
  }

  ToolOutcome _editRows(Map<String, dynamic> input) {
    final program = read().copy();
    final removed = (input['hapus'] as List<dynamic>? ?? const []).whereType<num>().map((e) => e.toInt()).toSet().toList()..sort((a, b) => b.compareTo(a));
    final items = (input['baris'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();
    if (removed.isEmpty && items.isEmpty) throw _Fail('Tidak ada yang diubah.');
    for (final item in items) {
      final no = (item['no'] as num?)?.toInt() ?? 0;
      if (item['no'] == null) throw _Fail('Setiap baris di ubah_baris perlu "no" (nomor baris mulai 1).');
      if (no < 1 || no > LadderProgram.maxRows) throw _Fail('Nomor baris $no tidak valid (1-${LadderProgram.maxRows}).');
      while (program.rows.length < no) {
        program.rows.add(LadderRow());
      }
      program.rows[no - 1] = _row(item, 'Baris $no');
    }
    for (final no in removed) {
      if (no >= 1 && no <= program.rows.length) program.rows.removeAt(no - 1);
    }
    write(program);
    return ToolOutcome(jsonEncode({'ok': true, 'baris': ladderText(program)}),
        'Mengubah ${items.length} baris${removed.isEmpty ? '' : ', menghapus ${removed.length}'}');
  }

  static int? _minuteOf(Object? text) {
    final match = RegExp(r'^\s*(\d{1,2})[:.](\d{2})\s*$').firstMatch('$text');
    final hour = int.tryParse(match?.group(1) ?? ''), minute = int.tryParse(match?.group(2) ?? '');
    return hour == null || minute == null || hour > 23 || minute > 59 ? null : hour * 60 + minute;
  }

  ToolOutcome _parameters(Map<String, dynamic> input) {
    final program = read().copy();
    _applyParameters(program, input);
    write(program);
    return ToolOutcome(jsonEncode({'ok': true, ..._describe(program)}), 'Mengatur parameter');
  }

  /// Runs the program on a simulated clock. Changes are reported per step for outputs, relays, timers and counters.
  ToolOutcome _test(Map<String, dynamic> input) {
    final program = read();
    if (program.isEmpty) throw _Fail('Program masih kosong.');
    final steps = (input['langkah'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();
    final inputs = def().plcInputs.toSet();
    final on = <String>{};
    final held = <String>{};
    var memory = PlcMemory();
    var now = 0.0;
    // The PLC clock during the test: Monday 00:00 at the start, moved by "atur_jam", running on with "tunggu".
    var clockBase = DateTime(2024, 1, 1);
    DateTime clock() => clockBase.add(Duration(milliseconds: (now * 1000).round()));
    var bits = <String>{};
    bool shown(String b) => !inputs.contains(b) && !b.startsWith('Z');
    Set<String> scan() {
      final result = scanLadder(program, inputs: {...on}, external: {...held}, memory: memory, now: now, clock: clock());
      memory = result.memory;
      return result.bits;
    }

    void settle() {
      // A few scans so rows that feed rows above them settle, as a real PLC does over successive cycles.
      for (var i = 0; i < 3; i++) {
        bits = scan();
      }
    }

    settle();
    final log = <Map<String, Object?>>[];
    var before = bits.where(shown).toSet();
    var waited = 0.0;
    for (final step in steps) {
      final action = '${step['aksi']}';
      final ref = '${step['alamat'] ?? ''}'.toUpperCase();
      String? problem;
      final isKey = RegExp(r'^Z[1-4]$').hasMatch(ref);
      if (action == 'atur_jam') {
        final day = kPlcDays.indexOf('${step['hari'] ?? 'MO'}'.toUpperCase());
        final minute = _minuteOf(step['waktu']);
        if (day < 0 || minute == null) {
          problem = 'atur_jam perlu "hari" (MO..SU) dan "waktu" (HH:MM).';
        } else {
          clockBase = DateTime(2024, 1, 1 + day).add(Duration(minutes: minute)).subtract(Duration(milliseconds: (now * 1000).round()));
          settle();
        }
      } else if (action != 'tunggu' && !inputs.contains(ref) && !isKey) {
        problem = 'Alamat "$ref" bukan input PLC ini (${def().plcInputs.join(' ')}) atau Z1-Z4.';
      } else {
        final target = isKey ? held : on;
        switch (action) {
          case 'nyala':
            target.add(ref);
            settle();
          case 'mati':
            target.remove(ref);
            settle();
          case 'tekan':
            target.add(ref);
            settle();
            now += 0.3;
            settle();
            target.remove(ref);
            settle();
          case 'tunggu':
            // Time passes in tenths, so timers and flashers step as they would.
            final remaining = waited >= 3600.0 ? 0.0 : 3600.0 - waited;
            final raw = (step['detik'] as num?)?.toDouble() ?? 1.0;
            final seconds = raw.isFinite ? raw.clamp(0.0, remaining) : 0.0;
            waited += seconds;
            final end = now + seconds;
            while (now < end) {
              now = (now + 0.1).clamp(0, end);
              bits = scan();
            }
            settle();
          default:
            problem = 'Aksi "$action" tidak dikenal.';
        }
      }
      final after = bits.where(shown).toSet();
      log.add({
        'langkah': '$action${ref.isEmpty ? '' : ' $ref'}${action == 'tunggu' ? ' ${step['detik'] ?? 1} dtk' : ''}',
        'galat': ?problem,
        if (after.difference(before).isNotEmpty) 'menyala': (after.difference(before).toList()..sort()),
        if (before.difference(after).isNotEmpty) 'padam': (before.difference(after).toList()..sort()),
      });
      before = after;
    }
    final outputs = def().plcOutputs.where(bits.contains).toList();
    final report = {
      'langkah': log,
      'akhir': {
        'input_menyala': (on.toList()..sort()),
        'output_menyala': outputs,
        'relay_menyala': [for (final b in bits) if (b.startsWith('M') || b.startsWith('N')) b]..sort(),
        if (program.used('T').isNotEmpty) 'timer': {for (final t in program.used('T')) t: memory.timers[t]?.out ?? false ? 'ON' : 'OFF'},
        if (program.used('C').isNotEmpty) 'counter': {for (final c in program.used('C')) c: memory.counts[c] ?? 0},
      },
    };
    final problems = log.where((l) => l.containsKey('galat')).length;
    return ToolOutcome(jsonEncode(report), 'Menguji program: ${steps.length} langkah${problems > 0 ? ', $problems bermasalah' : ''}');
  }
}
