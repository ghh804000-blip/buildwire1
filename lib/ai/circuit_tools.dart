import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import '../app_state.dart';
import '../model/device_def.dart';
import '../model/project.dart';
import '../sim/ladder.dart';
import '../sim/plc.dart';
import '../sim/solver.dart';
import '../templates.dart';
import 'ai_connector.dart';
import 'swarm.dart';

/// What one tool call did: the JSON handed back to the model and a short line for the chat.
class ToolOutcome {
  const ToolOutcome(this.result, this.label, {this.error = false});

  final String result;
  final String label;
  final bool error;
}

class _Fail implements Exception {
  _Fail(this.message);
  final String message;
}

/// Wire colors the assistant can name, as the templates use them.
const Map<String, int> kWireColors = {
  'coklat': 0xFF8A5A2B,
  'hitam': 0xFF1F2428,
  'abu': 0xFF808890,
  'biru': 0xFF1D6FB8,
  'hijau': 0xFF3F8F3A,
  'merah': 0xFFB3261E,
};

/// Devices the built-in circuits use, offered first because they are known to simulate well.
const Map<String, String> kRecommendedDevices = {
  'generic_source_ac3': 'Sumber 3 fasa 400 V (L1 L2 L3 N PE)',
  'generic_source_ac': 'Sumber 1 fasa 230 V (L N)',
  'chint_nxb63h_3p': 'MCB 3 kutub, utama (1-2, 3-4, 5-6)',
  'schneider_ic60n_1p_c10': 'MCB 1 kutub untuk kontrol (1-2)',
  'schneider_acti9_ic60n_1p_c16': 'MCB 1 kutub 16 A (1-2)',
  'chint_nxc32': 'Kontaktor 3 kutub, koil A1-A2 230 V, bantu 13-14 NO dan 21-22 NC',
  'chint_nr2_25': 'Overload relay (1-2, 3-4, 5-6), kontak 95-96 NC dan 97-98 NO',
  'motor_6_terminales': 'Motor 3 fasa 6 terminal (U1 V1 W1 U2 V2 W2 PE)',
  'pulsador_verde_1no': 'Tombol tekan hijau NO (3-4)',
  'pulsador_rojo_1nc': 'Tombol tekan merah NC (1-2)',
  'piloto_led_verde': 'Lampu indikator hijau (X1-X2)',
  'piloto_led_amarillo': 'Lampu indikator kuning (X1-X2)',
  'piloto_led_rojo': 'Lampu indikator merah (X1-X2)',
  'chint_jss48a': 'Timer digital on-delay, koil A1-A2, kontak 15-18 NO tunda dan 15-16 NC tunda',
  'logo_230rce': 'PLC Siemens LOGO 230 V: L N, input I1-I8, output relay Q1.1-Q1.2 sampai Q4.1-Q4.2',
  'generic_source_dc24': 'Sumber 24 V DC (+ -)',
  'generic_source_dc_adjustable': 'Sumber DC bisa diatur 0-60 V (+ -), kontrol "voltage"',
  'power_supply_100_minus_240vac_24vdc_5a': 'Power supply 230 V AC ke 24 V DC: L N masuk, DC+1/DC+2 dan DC-1/DC-2 keluar (juga ada versi 12 V dan 48 V)',
  'schneider_rxm4ab2bd': 'Relay koil 24 V DC (A1+ A2-), 4 kontak tukar: 11-14/21-24/31-34/41-44 NO, 11-12/21-22/31-32/41-42 NC',
  'chint_nxc32_24vdc': 'Kontaktor 3 kutub dengan koil 24 V DC',
  'piloto_led_verde_24vdc': 'Lampu indikator hijau 24 V DC (X1+ X2-); juga ada merah, kuning, biru, putih 24 V DC',
  'generic_motor_dc': 'Motor DC 24 V (A1 A2): arah ikut polaritas, kecepatan ikut tegangan',
  'sensor_de_proximidad_inductivo_3_hilos_dc': 'Sensor proximity PNP 3 kabel: BN +, BU -, BK keluaran (+ saat mendeteksi); klik untuk mendekatkan benda',
  'logo_24rce': 'PLC LOGO 24 V DC: L = L+, N = M (0 V); input aktif bila diberi 24 V terhadap M',
  'zelio_sr3b261fu': 'PLC Schneider Zelio SR3B261FU 230 V: L N, input I1..I9 IA..IG, output relay Q1.1-Q1.2 sampai Q7.1-Q7.2, Q8 Q9 QA bersama terminal C',
  'zelio_sr2b121fu': 'PLC Zelio SR2B121FU 230 V (kecil): L N, input I1-I8, output relay Q1.1-Q1.2 sampai Q4.1-Q4.2',
  'zelio_sr2b121bd': 'PLC Zelio SR2B121BD 24 V DC: + -, input I1-I7 IB IC aktif bila diberi +24 V, output relay Q1-Q4 (Qn.1-Qn.2)',
};

/// The assistant's hands: it reads the catalog and the canvas, builds, and tests in the simulator.
class CircuitTools {
  CircuitTools(this.app);

  final AppState app;

  /// Tools that change the circuit, so it needs testing again afterwards.
  static const Set<String> editing = {'tambah_perangkat', 'sambung', 'hapus', 'atur_program_plc', 'atur'};

  static final List<AiTool> definitions = [
    AiTool(
      name: 'cari_perangkat',
      description: 'Mencari perangkat di katalog (sekitar 570 perangkat). Kembalikan id, nama, ukuran, terminal, dan ringkasan '
          'kontak. Pakai kata kunci bahasa Indonesia atau Inggris, misalnya "kontaktor", "mcb 3 kutub", "tombol", "lampu hijau", "timer".',
      schema: {
        'type': 'object',
        'properties': {
          'kata_kunci': {'type': 'string'},
          'maks': {'type': 'integer', 'description': 'Jumlah hasil, bawaan 10.'},
        },
        'required': ['kata_kunci'],
      },
    ),
    AiTool(
      name: 'info_perangkat',
      description: 'Detail lengkap satu atau beberapa perangkat dari katalog: semua terminal, kontak NO/NC, koil, rating, kontrol yang bisa diatur, cara mengoperasikan.',
      schema: {
        'type': 'object',
        'properties': {
          'id': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Id perangkat dari katalog.',
          },
        },
        'required': ['id'],
      },
    ),
    AiTool(
      name: 'lihat_rangkaian',
      description: 'Isi kanvas sekarang: perangkat (tag, id, posisi, ukuran), kabel, waktu timer, nilai yang diatur, dan program PLC.',
      schema: {'type': 'object', 'properties': <String, Object>{}},
    ),
    AiTool(
      name: 'lihat_contoh',
      description: 'Rangkaian contoh bawaan yang sudah terbukti jalan, lengkap dengan posisi, kabel, dan program PLC. Bagus sebagai acuan. '
          'id: ${kTemplates.map((t) => '${t.id} (${t.name})').join(', ')}.',
      schema: {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
      },
    ),
    AiTool(
      name: 'bentuk_tim',
      description: 'Membentuk tim kursor yang terlihat bekerja di layar pengguna. Panggil sekali di awal setiap permintaan, sebelum mengubah kanvas. '
          'Karang nama yang bebas, acak, dan unik (boleh lucu, tidak harus tokoh terkenal). Nama pertama adalah ketua, yang menguji rangkaian. '
          'Jumlah anggota sesuai kerumitan: rangkaian kecil 3-5, sedang 6-10, besar 10-16.',
      schema: {
        'type': 'object',
        'properties': {
          'nama': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Nama-nama anggota, yang pertama ketua. 2 sampai 16 nama.',
          },
        },
        'required': ['nama'],
      },
    ),
    AiTool(
      name: 'kosongkan_kanvas',
      description: 'Menghapus semua perangkat dan kabel di kanvas (bisa diurungkan pengguna). Opsional ganti nama proyek.',
      schema: {
        'type': 'object',
        'properties': {
          'nama_proyek': {'type': 'string'},
        },
      },
    ),
    AiTool(
      name: 'tambah_perangkat',
      description: 'Menaruh satu atau beberapa perangkat di kanvas. Koordinat dalam piksel kanvas, titik kiri-atas perangkat. '
          'Kalau bertumpuk dengan perangkat lain, posisinya digeser ke kanan otomatis. Tag yang sudah dipakai diganti otomatis.',
      schema: {
        'type': 'object',
        'properties': {
          'perangkat': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string', 'description': 'Id dari katalog.'},
                'tag': {'type': 'string', 'description': 'Misalnya QF1, KM1, S1, M1.'},
                'x': {'type': 'number'},
                'y': {'type': 'number'},
              },
              'required': ['id'],
            },
          },
        },
        'required': ['perangkat'],
      },
    ),
    AiTool(
      name: 'sambung',
      description: 'Menyambung kabel antar terminal. Terminal ditulis "TAG.TERMINAL", misalnya "KM1.A1" atau "PLC1.Q1.1". '
          'Warna: coklat/hitam/abu untuk L1/L2/L3, biru N, hijau PE, merah kontrol. Ukuran mm2: 2.5 daya, 1.5 kontrol. '
          'jumper=true untuk jembatan pendek (misalnya terminal motor delta atau titik bintang).',
      schema: {
        'type': 'object',
        'properties': {
          'kabel': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'dari': {'type': 'string'},
                'ke': {'type': 'string'},
                'warna': {'type': 'string', 'enum': kWireColors.keys.toList()},
                'ukuran_mm2': {'type': 'number'},
                'jumper': {'type': 'boolean'},
              },
              'required': ['dari', 'ke'],
            },
          },
        },
        'required': ['kabel'],
      },
    ),
    AiTool(
      name: 'hapus',
      description: 'Menghapus perangkat (beserta kabelnya) berdasarkan tag, dan/atau kabel tertentu.',
      schema: {
        'type': 'object',
        'properties': {
          'tag': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'kabel': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'dari': {'type': 'string'},
                'ke': {'type': 'string'},
              },
              'required': ['dari', 'ke'],
            },
          },
        },
      },
    ),
    AiTool(
      name: 'atur_program_plc',
      description: 'Mengganti seluruh program ladder sebuah PLC (LOGO atau Zelio). Tiap rung: "cabang" = daftar cabang paralel, tiap cabang = kontak seri (maks 5). '
          'Kontak: input sesuai PLC (LOGO I1-I8; Zelio I1..I9, IA..IG), output (LOGO Q1-Q4; Zelio Q1..Q9, QA), M1.. relay bantu, '
          'T1.. kontak timer, C1.. kontak counter, Z1-Z4 tombol panah PLC. Awali "!" untuk kontak NC, misalnya "!I2". '
          'Coil: "Q1" atau "M1" koil biasa, "^Q1" impuls (toggle), "SQ1"/"RQ1" set/reset (kunci), "TT1" perintah timer (isi "preset" detik dan '
          '"fungsi_timer": A tunda nyala, C tunda padam, B pulsa, D kedip, L kedip asimetris dengan "preset2", AC, T totalisator, a/PD/I start-stop pulsa), '
          '"RT1" reset timer, "CC1" hitung naik (isi "preset" jumlah hitungan), "DC1" arah turun, "RC1" reset counter. Rung dibaca dari atas ke bawah.',
      schema: {
        'type': 'object',
        'properties': {
          'tag': {'type': 'string'},
          'rung': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'cabang': {
                  'type': 'array',
                  'items': {
                    'type': 'array',
                    'items': {'type': 'string'},
                  },
                },
                'coil': {'type': 'string'},
                'preset': {'type': 'number'},
                'preset2': {'type': 'number'},
                'fungsi_timer': {'type': 'string', 'enum': ['A', 'a', 'C', 'B', 'W', 'D', 'PD', 'T', 'AC', 'L', 'I']},
                'hitung_ke_nol': {'type': 'boolean'},
              },
              'required': ['cabang', 'coil'],
            },
          },
        },
        'required': ['tag', 'rung'],
      },
    ),
    AiTool(
      name: 'atur',
      description: 'Mengatur waktu timer (detik) dan/atau nilai kontrol perangkat (misalnya daya motor power_w, arus setting overload). '
          'Nama kontrol lihat di info_perangkat.',
      schema: {
        'type': 'object',
        'properties': {
          'tag': {'type': 'string'},
          'waktu_detik': {'type': 'number'},
          'nilai': {'type': 'object', 'description': 'Pasangan nama kontrol dan angka.'},
        },
        'required': ['tag'],
      },
    ),
    AiTool(
      name: 'uji_simulasi',
      description: 'Menjalankan simulasi dari awal dan melakukan langkah-langkah, lalu melaporkan perubahan status tiap langkah, '
          'peringatan, korsleting, dan status akhir semua perangkat. Aksi: "klik" (MCB/saklar, bolak-balik), "tekan" (tombol tekan sebentar lalu lepas), '
          '"tahan" dan "lepas" (tombol ditahan), "tunggu" (detik, waktu simulasi dipercepat). WAJIB dipakai untuk memastikan rangkaian benar-benar bekerja. '
          'Setiap panggilan mulai dari keadaan awal (semua pengaman mati, overload normal) dan tidak mengubah kanvas, jadi tidak perlu "mengembalikan" apa pun setelah menguji. '
          'Masukkan semua skenario (start, stop, trip, arah lain) dalam satu panggilan bila bisa.',
      schema: {
        'type': 'object',
        'properties': {
          'langkah': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'aksi': {
                  'type': 'string',
                  'enum': ['klik', 'tekan', 'tahan', 'lepas', 'tunggu'],
                },
                'tag': {'type': 'string'},
                'detik': {'type': 'number'},
              },
              'required': ['aksi'],
            },
          },
          'biarkan_jalan': {'type': 'boolean', 'description': 'Biarkan simulasi tetap berjalan di akhir supaya pengguna bisa melihat. Bawaan false.'},
        },
        'required': ['langkah'],
      },
    ),
  ];

  /// Runs one call. Problems come back to the model as an error result it can act on, never as an exception.
  Future<ToolOutcome> run(String name, Map<String, dynamic> input) async {
    try {
      return switch (name) {
        'cari_perangkat' => _search(input),
        'info_perangkat' => _info(input),
        'lihat_rangkaian' => ToolOutcome(_encode(_circuit(app.project)), 'Melihat rangkaian'),
        'lihat_contoh' => _example(input),
        'bentuk_tim' => _team(input),
        'kosongkan_kanvas' => await _clear(input),
        'tambah_perangkat' => await _add(input),
        'sambung' => await _connect(input),
        'hapus' => await _remove(input),
        'atur_program_plc' => await _program(input),
        'atur' => await _set(input),
        'uji_simulasi' => await _simulate(input),
        _ => throw _Fail('Alat "$name" tidak ada.'),
      };
    } on _Fail catch (fail) {
      return ToolOutcome(_encode({'galat': fail.message}), fail.message, error: true);
    } catch (error) {
      return ToolOutcome(_encode({'galat': 'Masukan tidak bisa diproses: $error'}), 'Masukan tidak valid', error: true);
    }
  }

  static String _encode(Object value) => jsonEncode(value);

  // ----- Reading

  ToolOutcome _search(Map<String, dynamic> input) {
    final query = (input['kata_kunci'] as String? ?? '').toLowerCase().trim();
    final limit = ((input['maks'] as num?)?.toInt() ?? 10).clamp(1, 25);
    final words = query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) throw _Fail('kata_kunci kosong.');
    const aliases = {
      'tombol': ['pulsador', 'tombol', 'button'],
      'lampu': ['piloto', 'lampu', 'led', 'foco'],
      'sumber': ['source', 'sumber'],
      'motor': ['motor'],
      'overload': ['overload', 'thermal', 'nr2', 'tf42'],
      'tor': ['overload', 'thermal'],
      'plc': ['plc', 'logo'],
      'saklar': ['switch', 'saklar', 'interruptor', 'selector'],
      'hijau': ['verde', 'hijau', 'green'],
      'merah': ['rojo', 'merah', 'red'],
      'kuning': ['amarillo', 'kuning', 'yellow'],
    };
    final scored = <(DeviceDef, double)>[];
    for (final def in app.defs.values) {
      if (def.isSymbol || def.isJunction) continue;
      final hay = '${def.id} ${def.name} ${def.group ?? ''} ${def.categoryLabel ?? ''} ${def.kind} ${kRecommendedDevices[def.id] ?? ''}'.toLowerCase();
      var score = 0.0;
      var all = true;
      for (final word in words) {
        final options = aliases[word] ?? [word];
        final hit = options.any(hay.contains);
        if (hit) {
          score += 1;
          if ((def.group ?? '').toLowerCase().contains(word)) score += 1;
        } else {
          all = false;
        }
      }
      if (score == 0) continue;
      if (all) score += 2;
      if (kRecommendedDevices.containsKey(def.id)) score += 1.5;
      // DC variants only lead when the search asks for DC.
      final dcPart = def.id.contains('24vdc') || def.id.contains('_dc') || (def.coil?.supply ?? def.load?.supply ?? def.input?.supply) == 'dc';
      final wantsDc = query.contains('dc') || query.contains('24') || query.contains('12') || query.contains('48');
      if (dcPart && !wantsDc) score -= 1.6;
      scored.add((def, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final results = [for (final (def, _) in scored.take(limit)) describe(def, brief: true)];
    return ToolOutcome(_encode({'hasil': results, 'jumlah_cocok': scored.length}), 'Mencari "$query" (${scored.length} cocok)');
  }

  ToolOutcome _info(Map<String, dynamic> input) {
    final raw = input['id'];
    final ids = raw is List ? raw.map((e) => '$e').toList() : ['$raw'];
    final found = <Object>[];
    for (final id in ids) {
      final def = app.defs[id];
      found.add(def == null ? {'id': id, 'galat': 'tidak ada di katalog'} : describe(def));
    }
    return ToolOutcome(_encode({'perangkat': found}), 'Membaca detail ${ids.join(', ')}');
  }

  /// A device as the model needs it. Brief keeps search results small.
  Map<String, Object?> describe(DeviceDef def, {bool brief = false}) {
    final behavior = def.behavior;
    final contacts = <String>[];
    for (final contact in behavior['contacts'] as List<dynamic>? ?? const []) {
      if (contact is! Map<String, dynamic>) continue;
      final closed = (contact['closed'] as List<dynamic>? ?? const []).map((e) => '$e').toList();
      final pair = '${contact['a']}-${contact['b']}';
      if (def.kind == 'timer_on') {
        contacts.add(closed.contains('closed') ? '$pair NO tunda (menutup setelah waktu habis)' : '$pair NC tunda (membuka setelah waktu habis)');
      } else if (def.kind == 'coil') {
        contacts.add(closed.contains('closed') ? '$pair NO (menutup saat koil berenergi)' : '$pair NC (membuka saat koil berenergi)');
      } else {
        contacts.add('$pair tertutup saat: ${closed.join('/')}');
      }
    }
    final coil = def.coil;
    final operate = def.isHold ? 'tahan/tekan (tombol tekan)' : (def.isClickable ? 'klik (bolak-balik)' : null);
    return {
      'id': def.id,
      'nama': def.name,
      'kelompok': def.group,
      'awalan_tag': def.designator,
      'ukuran_px': [def.width.round(), def.height.round()],
      'jenis': def.kind,
      if (kRecommendedDevices.containsKey(def.id)) 'rekomendasi': kRecommendedDevices[def.id],
      'terminal': [for (final t in def.terminals) t.id],
      if (contacts.isNotEmpty) 'kontak': contacts,
      if (coil != null) 'koil': '${coil.a}-${coil.b} ${coil.volts.round()} V ${coil.supply}',
      'operasi': ?operate,
      if (def.isTimer) 'waktu_bawaan_detik': def.defaultTime,
      if (def.kind == 'plc')
        'plc': def.input?.supply == 'dc'
            ? 'Catu 24 V DC: L = L+, N = M (0 V). Input I1-I8 aktif bila diberi +24 V. Output relay: Qn.1-Qn.2 (kontak kering).'
            : 'Catu L-N 230 V. Input I1-I8 aktif bila diberi L. Output relay: Qn.1-Qn.2 (kontak kering, beri L di Qn.1, Qn.2 ke beban).',
      if (def.kind == 'motor_dc') 'motor_dc': 'A1 ke + memutar maju, A1 ke - memutar mundur. Kecepatan sebanding tegangan; berhenti di bawah 25% rating.',
      if (def.kind == 'sensor_pnp') 'sensor': 'BN ke +, BU ke -, BK keluaran ke beban/input. Pada uji_simulasi, klik sensor untuk mendekatkan benda logam.',
      if (!brief) ...{
        'rating': def.ratings,
        if (def.outputs.isNotEmpty) 'keluaran': def.outputs,
        if (def.controls.isNotEmpty)
          'kontrol': [
            for (final c in def.controls) {'nama': c.key, 'label': c.label, 'satuan': c.unit, 'min': c.min, 'maks': c.max, 'bawaan': c.fallback},
          ],
        if (def.operateHint != null) 'catatan': def.operateHint,
        'status': def.states,
      },
    };
  }

  static String _colorName(int color) => kWireColors.entries.where((e) => e.value == color).map((e) => e.key).firstOrNull ?? '#${color.toRadixString(16)}';

  Map<String, Object?> _circuit(Project project) {
    String tag(int id) => project.devices.where((d) => d.id == id).map((d) => d.tag).firstOrNull ?? '?';
    return {
      'nama_proyek': project.name,
      'perangkat': [
        for (final d in project.devices)
          {
            'tag': d.tag,
            'id': d.defId,
            'nama': app.defs[d.defId]?.name,
            'x': d.x.round(),
            'y': d.y.round(),
            'lebar': app.defs[d.defId]?.width.round(),
            'tinggi': app.defs[d.defId]?.height.round(),
            if (d.timeSeconds != null) 'waktu_detik': d.timeSeconds,
            if (d.data.keys.any((k) => k != 'program' && k != 'ladder'))
              'data': {for (final e in d.data.entries) if (e.key != 'program' && e.key != 'ladder') e.key: e.value},
            if (app.defs[d.defId]?.kind == 'plc' && !LadderProgram.of(d.data).isEmpty) ...{
              'program_ladder': ladderText(LadderProgram.of(d.data)),
              if (LadderProgram.of(d.data).timers.isNotEmpty)
                'timer_plc': {for (final e in LadderProgram.of(d.data).timers.entries) e.key: e.value.toJson()},
              if (LadderProgram.of(d.data).counters.isNotEmpty)
                'counter_plc': {for (final e in LadderProgram.of(d.data).counters.entries) e.key: e.value.toJson()},
            },
          },
      ],
      'kabel': [
        for (final w in project.wires)
          {
            'dari': '${tag(w.a.deviceId)}.${w.a.terminal}',
            'ke': '${tag(w.b.deviceId)}.${w.b.terminal}',
            if (w.isJumper) 'jumper': true else 'warna': _colorName(w.color),
            'mm2': w.gauge,
          },
      ],
    };
  }

  ToolOutcome _example(Map<String, dynamic> input) {
    final id = '${input['id']}';
    final template = kTemplates.where((t) => t.id == id).firstOrNull;
    if (template == null) throw _Fail('Contoh "$id" tidak ada. Pilihan: ${kTemplates.map((t) => t.id).join(', ')}.');
    return ToolOutcome(_encode({'contoh': template.name, 'cara_pakai': template.hint, ..._circuit(template.build())}), 'Mempelajari contoh "${template.name}"');
  }

  // ----- Building

  Swarm get swarm => app.swarm;

  ToolOutcome _team(Map<String, dynamic> input) {
    final names = (input['nama'] as List<dynamic>? ?? const []).map((e) => '$e').toList();
    final team = swarm.formTeam(names);
    return ToolOutcome(_encode({'ketua': team.first.name, 'anggota': [for (final c in team.skip(1)) c.name]}),
        'Membentuk tim: ${team.first.name} (ketua)${team.length > 1 ? ', ${team.skip(1).map((c) => c.name).join(', ')}' : ''}');
  }

  /// The leader, forming a made-up team first if the model didn't name one.
  SwarmCursor _leader([int work = 4]) {
    swarm.ensureTeam(work: work);
    return swarm.leader ?? swarm.members.first;
  }

  void _focusAll([Iterable<Rect> extra = const []]) => swarm.focus([...app.project.devices.map(app.deviceRect), ...extra]);

  Future<ToolOutcome> _clear(Map<String, dynamic> input) async {
    final name = input['nama_proyek'];
    if (app.project.devices.isNotEmpty) {
      final area = app.project.devices.map(app.deviceRect).reduce((a, b) => a.expandToInclude(b)).inflate(30);
      _focusAll();
      await swarm.sweep(_leader(), area, app.aiClear);
    } else {
      app.aiClear();
    }
    if (name is String && name.trim().isNotEmpty) app.aiRename(name.trim());
    return ToolOutcome(_encode({'ok': true}), 'Mengosongkan kanvas');
  }

  Future<ToolOutcome> _add(Map<String, dynamic> input) async {
    final items = (input['perangkat'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();
    if (items.isEmpty) throw _Fail('Daftar perangkat kosong.');
    final failed = <Object>[];
    final plans = <({String id, String tag, Rect rect})>[];
    for (final item in items) {
      final id = '${item['id']}';
      final def = app.defs[id];
      if (def == null || def.isSymbol) {
        failed.add({'id': id, 'galat': 'Id tidak ada di katalog. Pakai cari_perangkat.'});
        continue;
      }
      final plan = app.aiPlanPlacement(id,
          tag: item['tag'] as String?,
          x: (item['x'] as num?)?.toDouble(),
          y: (item['y'] as num?)?.toDouble(),
          reserved: [for (final p in plans) p.rect],
          reservedTags: {for (final p in plans) p.tag});
      plans.add((id: id, tag: plan.tag, rect: plan.rect));
    }
    _focusAll(plans.map((p) => p.rect));
    final placed = <String, PlacedDevice>{};
    // In no particular order, as a team of people would.
    final order = [...plans]..shuffle();
    await swarm.share(order, (cursor, plan) => swarm.placeDevice(cursor, plan.id, plan.rect, () => placed[plan.tag] = app.aiCommitPlacement(plan.id, plan.tag, plan.rect)));
    final results = <Object>[
      for (final plan in plans)
        if (placed[plan.tag] case final device?)
          {
            'tag': device.tag,
            'id': plan.id,
            'x': device.x.round(),
            'y': device.y.round(),
            'lebar': plan.rect.width.round(),
            'tinggi': plan.rect.height.round(),
            'terminal': [for (final t in app.defOf(device).terminals) t.id],
          }
        else
          {'tag': plan.tag, 'galat': 'Dibatalkan.'},
      ...failed,
    ];
    final added = placed.keys.toList();
    final skipped = results.length - added.length;
    return ToolOutcome(_encode({'hasil': results}), added.isEmpty ? 'Gagal menambah perangkat' : 'Menambah ${added.join(', ')}${skipped > 0 ? ' ($skipped gagal)' : ''}',
        error: added.isEmpty);
  }

  /// "KM1.A1" or "PLC1.Q1.1": the tag is before the first dot.
  TerminalRef _ref(String spec) {
    final text = spec.trim();
    final dot = text.indexOf('.');
    if (dot <= 0) throw _Fail('Terminal "$spec" harus berbentuk TAG.TERMINAL.');
    final device = app.deviceByTag(text.substring(0, dot));
    if (device == null) throw _Fail('Tidak ada perangkat bertag "${text.substring(0, dot)}".');
    final terminal = text.substring(dot + 1);
    final def = app.defOf(device);
    final match = def.terminals.where((t) => t.id == terminal).firstOrNull ?? def.terminals.where((t) => t.id.toLowerCase() == terminal.toLowerCase()).firstOrNull;
    if (match == null) throw _Fail('${device.tag} tidak punya terminal "$terminal". Terminalnya: ${def.terminals.map((t) => t.id).join(', ')}.');
    return TerminalRef(device.id, match.id);
  }

  Future<ToolOutcome> _connect(Map<String, dynamic> input) async {
    final items = (input['kabel'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();
    if (items.isEmpty) throw _Fail('Daftar kabel kosong.');
    final errors = <String>[];
    final jobs = <({TerminalRef a, TerminalRef b, int? color, double? gauge, bool jumper})>[];
    for (final item in items) {
      final from = '${item['dari']}', to = '${item['ke']}';
      try {
        final a = _ref(from), b = _ref(to);
        if (a == b) throw _Fail('$from tidak bisa disambung ke dirinya sendiri.');
        if (app.project.wires.any((w) => w.connects(a, b)) || jobs.any((j) => (j.a == a && j.b == b) || (j.a == b && j.b == a))) continue;
        jobs.add((a: a, b: b, color: kWireColors[(item['warna'] as String?)?.toLowerCase()], gauge: (item['ukuran_mm2'] as num?)?.toDouble(), jumper: item['jumper'] == true));
      } on _Fail catch (fail) {
        errors.add('$from → $to: ${fail.message}');
      }
    }
    _focusAll();
    var made = 0;
    await swarm.share(jobs, (cursor, job) {
      final color = job.jumper ? Wire.jumperColor : (job.color ?? app.autoColor(job.a, job.b));
      return swarm.connect(cursor, job.a, job.b, color, () {
        app.aiConnect(job.a, job.b, color: job.color, gauge: job.gauge, jumper: job.jumper);
        made++;
      });
    });
    return ToolOutcome(
      _encode({'tersambung': made, if (errors.isNotEmpty) 'galat': errors}),
      'Menyambung $made kabel${errors.isEmpty ? '' : ' (${errors.length} gagal)'}',
      error: made == 0 && errors.isNotEmpty,
    );
  }

  Future<ToolOutcome> _remove(Map<String, dynamic> input) async {
    final removed = <String>[];
    final errors = <String>[];
    final devices = <PlacedDevice>[];
    for (final tag in (input['tag'] as List<dynamic>? ?? const []).map((e) => '$e')) {
      final device = app.deviceByTag(tag);
      device == null ? errors.add('Tidak ada tag $tag.') : devices.add(device);
    }
    final wires = <Wire>[];
    for (final item in (input['kabel'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>()) {
      try {
        final a = _ref('${item['dari']}'), b = _ref('${item['ke']}');
        final wire = app.project.wires.where((w) => w.connects(a, b)).firstOrNull;
        if (wire == null) throw _Fail('Kabel ${item['dari']} → ${item['ke']} tidak ada.');
        wires.add(wire);
      } on _Fail catch (fail) {
        errors.add(fail.message);
      }
    }
    _focusAll();
    var wiresRemoved = 0;
    await swarm.share(wires, (cursor, wire) => swarm.clickAt(cursor, app.terminalWorld(wire.a), () {
          app.aiRemoveWire(wire);
          wiresRemoved++;
        }));
    await swarm.share(devices, (cursor, device) => swarm.clickDevice(cursor, device, () {
          app.aiRemoveDevice(device);
          removed.add(device.tag);
        }, note: 'hapus ${device.tag}'));
    final parts = [if (removed.isNotEmpty) removed.join(', '), if (wiresRemoved > 0) '$wiresRemoved kabel'];
    return ToolOutcome(_encode({'dihapus': removed, 'kabel_dihapus': wiresRemoved, if (errors.isNotEmpty) 'galat': errors}),
        parts.isEmpty ? 'Tidak ada yang dihapus' : 'Menghapus ${parts.join(' dan ')}', error: parts.isEmpty);
  }

  Future<ToolOutcome> _program(Map<String, dynamic> input) async {
    final device = app.deviceByTag('${input['tag']}');
    if (device == null || app.defOf(device).kind != 'plc') throw _Fail('Tidak ada PLC bertag "${input['tag']}".');
    final def = app.defOf(device);
    final zelio = def.isZelio;
    final outputs = def.plcOutputs;
    final memory = (zelio ? ladderNames('M', 28) : kPlcMemory).toSet();
    final timersNames = ladderNames('T', zelio ? 28 : 16).toSet();
    final countersNames = ladderNames('C', zelio ? 28 : 16).toSet();
    final clocks = ladderNames('H', 8).toSet();
    final valid = {...def.plcInputs, ...outputs, ...memory, ...timersNames, ...countersNames, ...clocks, 'Z1', 'Z2', 'Z3', 'Z4'};
    final program = LadderProgram();
    final items = (input['rung'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      // Coil: Q1 (or [Q1), ^Q1 impulse, SQ1 set, RQ1 reset, TT1 / RT1 timer, CC1 / DC1 / RC1 counter; T1 alone = TT1.
      var coilText = '${item['coil']}'.toUpperCase().replaceAll(' ', '');
      if (RegExp(r'^[QMN][0-9A-Z]+$').hasMatch(coilText)) coilText = '[$coilText';
      if (RegExp(r'^T[0-9A-Z]+$').hasMatch(coilText) && timersNames.contains(coilText)) coilText = 'T$coilText';
      final coil = LadderCoil.parse(coilText);
      final target = coil?.ref ?? '';
      final okCoil = coil != null &&
          switch (coil.fn) {
            '[' || '^' || 'S' => outputs.contains(target) || memory.contains(target),
            'R' => outputs.contains(target) || memory.contains(target) || timersNames.contains(target) || countersNames.contains(target),
            'T' => timersNames.contains(target),
            'C' || 'D' => countersNames.contains(target),
            _ => false,
          };
      if (!okCoil) {
        throw _Fail('Rung ${i + 1}: coil "${item['coil']}" tidak valid. Pakai ${outputs.first}-${outputs.last} atau M1.. (koil biasa), '
            '^Q1 impuls, SQ1/RQ1 set/reset, TT1/RT1 timer, CC1/DC1/RC1 counter.');
      }
      final branches = <List<PlcContact>>[];
      for (final branch in item['cabang'] as List<dynamic>? ?? const []) {
        final contacts = <PlcContact>[];
        for (final raw in branch is List ? branch : [branch]) {
          var ref = '$raw'.toUpperCase().replaceAll(' ', '');
          final negated = ref.startsWith('!') || ref.startsWith('/') || ref.startsWith('NOT');
          ref = ref.replaceFirst(RegExp(r'^(!|/|NOT)'), '');
          if (!valid.contains(ref)) {
            throw _Fail('Rung ${i + 1}: kontak "$raw" tidak valid. Input ${device.tag}: ${def.plcInputs.join(' ')}; output ${outputs.join(' ')}; '
                'M relay, T timer, C counter, H1-H8 jam, Z1-Z4 tombol panah PLC.');
          }
          contacts.add(PlcContact(ref, negated: negated));
        }
        if (contacts.length > LadderProgram.columns) throw _Fail('Rung ${i + 1}: paling banyak ${LadderProgram.columns} kontak seri per cabang.');
        if (contacts.isNotEmpty) branches.add(contacts);
      }
      if (branches.isEmpty) throw _Fail('Rung ${i + 1} tidak punya kontak.');
      final rows = LadderProgram.fromRungs([PlcRung(branches: branches, coil: 'Q1')], renameCursor: false).rows;
      rows.first.coil = coil;
      if (program.rows.length + rows.length > LadderProgram.maxRows) throw _Fail('Program terlalu panjang.');
      program.rows.addAll(rows);
      if (coil.fn == 'T') {
        final timer = program.timer(target);
        timer.preset = ((item['preset'] as num?)?.toDouble() ?? timer.preset).clamp(0.1, 9999);
        final fn = '${item['fungsi_timer'] ?? 'A'}';
        timer.function = LadderTimer.functions.containsKey(fn) ? fn : (LadderTimer.functions.containsKey(fn.toUpperCase()) ? fn.toUpperCase() : 'A');
        if (item['preset2'] is num) timer.preset2 = (item['preset2'] as num).toDouble().clamp(0.1, 9999);
      }
      if (coil.fn == 'C' && item['preset'] is num) program.counter(target).preset = (item['preset'] as num).toInt().clamp(0, 32767);
      if (coil.fn == 'C' && item['hitung_ke_nol'] == true) program.counter(target).toZero = true;
    }
    if (program.isEmpty) throw _Fail('Program kosong.');
    final lines = ladderText(program);
    _focusAll();
    await swarm.typeProgram(_leader(), device, lines, () => app.aiSetProgram(device, program));
    if (swarm.cancelled) throw _Fail('Dibatalkan.');
    return ToolOutcome(_encode({'ok': true, 'baris': lines.length}), 'Menulis program ${device.tag} (${items.length} rung)');
  }

  Future<ToolOutcome> _set(Map<String, dynamic> input) async {
    final device = app.deviceByTag('${input['tag']}');
    if (device == null) throw _Fail('Tidak ada tag "${input['tag']}".');
    final def = app.defOf(device);
    final done = <String>[];
    final changes = <VoidCallback>[];
    final seconds = (input['waktu_detik'] as num?)?.toDouble();
    if (seconds != null) {
      if (!def.isTimer) throw _Fail('${device.tag} bukan timer. Untuk timer PLC, isi preset di atur_program_plc.');
      changes.add(() => app.aiSetTime(device, seconds.clamp(0.1, 999)));
      done.add('waktu ${seconds.clamp(0.1, 999)} dtk');
    }
    final values = input['nilai'];
    if (values is Map<String, dynamic>) {
      for (final entry in values.entries) {
        final control = def.controls.where((c) => c.key == entry.key).firstOrNull;
        if (control == null) throw _Fail('${device.tag} tidak punya kontrol "${entry.key}". Ada: ${def.controls.map((c) => c.key).join(', ')}.');
        final value = (entry.value is num ? (entry.value as num).toDouble() : double.tryParse('${entry.value}'));
        if (value == null) throw _Fail('Nilai ${entry.key} harus angka.');
        changes.add(() => app.aiSetValue(device, entry.key, value.clamp(control.min, control.max)));
        done.add('${control.label} ${value.clamp(control.min, control.max)} ${control.unit}');
      }
    }
    if (done.isEmpty) throw _Fail('Tidak ada yang diatur.');
    final cursor = _leader();
    await swarm.clickDevice(cursor, device, () {
      for (final change in changes) {
        change();
      }
    }, note: 'atur ${device.tag}');
    await swarm.wait(0.5);
    cursor.note = null;
    return ToolOutcome(_encode({'ok': true, 'diatur': done}), 'Mengatur ${device.tag}: ${done.join(', ')}');
  }

  // ----- Testing

  static const Set<String> _watchable = {'coil', 'motor3', 'load', 'timer_on', 'timer_off', 'plc'};

  Future<ToolOutcome> _simulate(Map<String, dynamic> input) async {
    if (app.project.isEmpty) throw _Fail('Kanvas kosong.');
    if (app.running) app.stopSimulation();
    final animated = swarm.animated;
    final tester = _leader();
    _focusAll();
    app.startSimulation();
    if (!app.running) throw _Fail('Simulasi tidak bisa dimulai.');

    // The rest of the team spreads out to watch the parts that show results: motors first, then contactors, lamps.
    final watchers = swarm.members.where((c) => !c.leader).toList();
    final watched = [
      for (final d in app.project.devices)
        if (_watchable.contains(app.defOf(d).kind)) d,
    ]..sort((a, b) => (app.defOf(b).kind == 'motor3' ? 1 : 0).compareTo(app.defOf(a).kind == 'motor3' ? 1 : 0));
    var watching = true;
    final keep = input['biarkan_jalan'] == true;
    var completed = false;
    try {
      if (animated) {
        for (var i = 0; i < watchers.length && watched.isNotEmpty; i++) {
          final device = watched[i % watched.length];
          final watcher = watchers[i];
          watcher.busy = true;
          unawaited(swarm.watch(watcher, device, 0, 'mengamati ${device.tag}').then((_) {
            if (!watching || swarm.cancelled || watcher.leaving) return;
            watcher.shape = CursorShape.watch;
            watcher.note = 'mengamati ${device.tag}';
          }));
        }
        await swarm.wait(0.3 + swarm.nextRandom() * 0.4);
      }

      final log = <Map<String, Object?>>[];
      var before = _states();
      final steps = (input['langkah'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();
      var waited = 0.0;
      var shortSeen = false;
      for (final step in steps) {
        if (swarm.cancelled) break;
        final action = '${step['aksi']}';
        final tag = step['tag'] as String?;
        String? problem;
        if (action == 'tunggu') {
          final remaining = math.max(0.0, 600.0 - waited);
          final raw = (step['detik'] as num?)?.toDouble() ?? 1.0;
          final seconds = raw.isFinite ? raw.clamp(0.0, remaining) : 0.0;
          waited += seconds;
          if (animated) {
            // Real waiting up to 10 seconds, so timers visibly run; anything longer is skipped ahead.
            final real = math.min(seconds, 10.0);
            tester.shape = CursorShape.watch;
            for (var left = real; left > 0 && !swarm.cancelled; left -= 0.5) {
              tester.note = 'menunggu ${left.ceil()} dtk';
              await swarm.wait(math.min(0.5, left));
            }
            if (seconds > real) {
              tester.note = 'mempercepat ${(seconds - real).toStringAsFixed(0)} dtk';
              app.fastForward(seconds - real);
              await swarm.wait(0.4);
            }
            tester.note = null;
            tester.shape = CursorShape.arrow;
          } else {
            app.fastForward(seconds);
          }
        } else {
          final device = tag == null ? null : app.deviceByTag(tag);
          if (device == null) {
            problem = 'Tidak ada tag "$tag".';
          } else {
            final def = app.defOf(device);
            switch (action) {
              case 'klik' when def.isClickable:
                await swarm.clickDevice(tester, device, () => app.clickDevice(device), note: 'klik ${device.tag}');
              case 'klik' || 'tekan' when def.isHold:
                if (animated) {
                  await swarm.pressDevice(tester, device, (down) => app.pressDevice(device, down), seconds: 0.3 + swarm.nextRandom() * 0.25, note: 'tekan ${device.tag}');
                } else {
                  app.pressDevice(device, true);
                  app.fastForward(0.3);
                  app.pressDevice(device, false);
                }
              case 'tahan' when def.isHold:
                await swarm.clickDevice(tester, device, () => app.pressDevice(device, true), note: 'tahan ${device.tag}');
              case 'lepas' when def.isHold:
                await swarm.clickDevice(tester, device, () => app.pressDevice(device, false), note: 'lepas ${device.tag}');
              case 'klik' when def.isTimer:
                problem = 'Atur timer dengan alat atur, bukan klik.';
              default:
                problem = '${device.tag} tidak bisa di-$action (${def.isClickable ? 'pakai klik' : def.isHold ? 'pakai tekan/tahan' : 'tidak bisa dioperasikan'}).';
            }
          }
          if (animated) {
            // A natural pause to look at what happened, never quite the same twice.
            tester.note = 'mengamati…';
            await swarm.wait(0.35 + swarm.nextRandom() * 0.75);
            tester.note = null;
          } else {
            app.fastForward(0.2);
          }
        }
        final after = _states();
        final alarms = <String, Object?>{..._alarms()};
        final changed = {
          for (final entry in after.entries)
            if (before[entry.key] != entry.value) entry.key: '${before[entry.key]} → ${entry.value}',
        };
        // A breaker the step didn't touch going from on to tripped was tripped by a short. Once it has tripped the
        // short is gone from the live result, so it is named here or the model would never learn why.
        final trippedByShort = [
          for (final entry in changed.entries)
            if (entry.value == 'on → tripped' && entry.key != tag) entry.key,
        ];
        if (trippedByShort.isNotEmpty && !alarms.containsKey('korsleting')) {
          alarms['korsleting'] = 'Korsleting, pengaman trip (${trippedByShort.join(', ')}).';
        }
        final shorted = alarms.containsKey('korsleting') && !shortSeen;
        shortSeen = shortSeen || alarms.containsKey('korsleting');
        final label = '$action${tag == null ? '' : ' $tag'}${action == 'tunggu' ? ' ${step['detik'] ?? 1} dtk' : ''}';
        final moved = changed.keys.where((k) => !changed[k]!.endsWith('tripped')).toList();
        log.add({
          'langkah': label,
          'galat': ?problem,
          'berubah': changed,
          ...alarms,
          // Where to look first: what switched in the step that shorted.
          if (shorted)
            'petunjuk': 'Korsleting muncul pertama kali setelah "$label"${moved.isEmpty ? '' : ' (berubah: ${moved.join(', ')})'}. '
                'Kontak yang menutup karena aksi ini (tombol, kontak koil yang menarik sesaat) menyatukan dua potensial berbeda. '
                'Periksa: kontak utama yang menyatukan dua fasa, dua kontaktor yang ikut menarik bersamaan, keluaran dua kontak berbeda '
                'yang disatukan ke satu terminal, atau fasa yang langsung bertemu N.',
        });
        before = after;
      }
      final report = {'langkah': log, 'akhir': _finalReport(), if (swarm.cancelled) 'galat': 'Dibatalkan pengguna.'};
      await swarm.wait(0.5);
      completed = true;
      final problems = log.where((l) => l.containsKey('galat') || l.containsKey('korsleting') || l.containsKey('meledak')).length;
      return ToolOutcome(_encode(report), 'Menguji simulasi: ${steps.length} langkah${problems > 0 ? ', $problems bermasalah' : ''}');
    } finally {
      watching = false;
      tester.note = null;
      tester.shape = CursorShape.arrow;
      for (final watcher in watchers) {
        watcher.busy = false;
        watcher.note = null;
        watcher.shape = CursorShape.arrow;
      }
      if ((!keep || !completed) && app.running) app.stopSimulation();
    }
  }

  /// Every simulated device's state, by tag.
  Map<String, String> _states() => {
        for (final device in app.project.devices)
          if (app.defOf(device).isSimulated && app.defOf(device).kind != 'structural' && !app.defOf(device).isJunction) device.tag: app.stateOf(device),
      };

  Map<String, Object?> _alarms() {
    final result = app.simResult;
    if (result == null) return const {};
    String tag(int id) => app.tagOf(id);
    return {
      if (result.fault != SimFault.none)
        'korsleting': switch (result.fault) {
          SimFault.shortCircuitTripped => 'Korsleting, pengaman trip (${result.trippedDeviceId == null ? '?' : tag(result.trippedDeviceId!)}).',
          SimFault.shortCircuitUnprotected => 'Korsleting tanpa pengaman.',
          SimFault.unstable => 'Rangkaian tidak stabil (berosilasi).',
          SimFault.none => '',
        },
      if (result.warnings.isNotEmpty) 'peringatan': [for (final w in result.warnings) '${tag(w.deviceId)}: ${_warning(w.code)}'],
      if (app.project.devices.any((d) => app.stateOf(d) == kExploded))
        'meledak': [for (final d in app.project.devices.where((d) => app.stateOf(d) == kExploded)) d.tag],
    };
  }

  static String _warning(WarningCode code) => switch (code) {
        WarningCode.overvoltage => 'tegangan berlebih',
        WarningCode.wrongSupply => 'jenis sumber salah (AC/DC)',
        WarningCode.undervoltage => 'tegangan kurang',
        WarningCode.singlePhasing => 'motor kehilangan fasa',
        WarningCode.motorUnconnected => 'motor belum tersambung lengkap',
        WarningCode.motorNoEarth => 'motor tanpa PE',
        WarningCode.wrongFrequency => 'frekuensi salah',
      };

  Map<String, Object?> _finalReport() {
    final result = app.simResult;
    return {
      'status': _states(),
      if (result != null)
        'motor': {
          for (final d in app.project.devices.where((d) => app.defOf(d).kind == 'motor3' || app.defOf(d).name.toLowerCase().contains('motor')))
            d.tag: {
              'status': app.stateOf(d),
              if (result.starMotors.contains(d.id)) 'hubungan': 'bintang',
              'arus_a': double.parse((result.measures[d.id]?.amps ?? 0).toStringAsFixed(2)),
            },
        },
      'plc': {
        for (final d in app.project.devices.where((d) => app.defOf(d).kind == 'plc')) d.tag: app.bitsOf(d).toList()..sort(),
      },
      ..._alarms(),
      'pesan_status': app.status,
    };
  }
}
