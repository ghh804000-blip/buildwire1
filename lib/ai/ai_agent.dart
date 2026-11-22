import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import 'ai_attachment.dart';
import 'ai_connector.dart';
import 'ai_settings.dart';
import 'circuit_tools.dart';

enum ChatKind { user, assistant, tool, error, info }

/// One line in the chat panel.
class ChatEntry {
  ChatEntry(this.kind, this.text, {this.failed = false, this.attachments = const []});

  final ChatKind kind;
  final String text;

  /// Pictures and files the user sent with this message.
  final List<AiAttachment> attachments;

  /// A tool call that went wrong.
  final bool failed;
}

/// The assistant: a conversation with the user's model, which builds and tests circuits through [CircuitTools].
///
/// The history is kept in the wire format of the endpoint in use (Anthropic content blocks, or OpenAI messages with
/// tool calls), and each assistant turn is appended exactly as it came back, reasoning included, which some models
/// need to continue a tool loop. Switching endpoint, format or model starts the history over.
/// Where the assistant works: its tools, what it is told, and how its work shows on screen. The canvas is one
/// workspace (a team of cursors builds the circuit); the ladder editor is another.
abstract class AgentWorkspace {
  List<AiTool> get tools;
  String get systemPrompt;

  /// Tools that change the work, so it needs testing again; and the tool that tests it.
  Set<String> get editingTools;
  String get testTool;

  /// A line about the current state, added to each request.
  String context();

  Future<ToolOutcome> run(String name, Map<String, dynamic> input);

  void begin() {}
  void thinking(bool on) {}
  void cancel() {}

  /// After a request, whether it ended well or not.
  void end() {}
}

/// The canvas: circuit tools, the cursor team, and one undo step per request.
class CanvasWorkspace extends AgentWorkspace {
  CanvasWorkspace(this.app);

  final AppState app;
  late final CircuitTools _tools = CircuitTools(app);

  @override
  List<AiTool> get tools => CircuitTools.definitions;
  @override
  String get systemPrompt => AiAgent.systemPrompt;
  @override
  Set<String> get editingTools => CircuitTools.editing;
  @override
  String get testTool => 'uji_simulasi';
  @override
  String context() {
    final project = app.project;
    return 'Kanvas saat ini: ${project.devices.length} perangkat, ${project.wires.length} kabel, proyek "${project.name}".';
  }

  @override
  Future<ToolOutcome> run(String name, Map<String, dynamic> input) => _tools.run(name, input);

  @override
  void begin() {
    app.swarm.begin();
    app.aiChanged();
  }

  @override
  void thinking(bool on) => app.swarm.thinking = on;

  @override
  void cancel() => app.swarm.cancel();

  @override
  void end() {
    if (app.aiEditing) {
      app.endAiEdit('Rangkaian diubah oleh asisten AI. Tekan Ctrl+Z untuk mengurungkan.');
      app.fitView();
    }
    app.swarm.finish();
    app.aiChanged();
  }
}

class AiAgent extends ChangeNotifier {
  AiAgent(this.app, {AiConnector? connector, AgentWorkspace? workspace})
      : _ownsConnector = connector == null,
        _connector = connector, // ignore: prefer_initializing_formals
        workspace = workspace ?? CanvasWorkspace(app);

  final AppState app;
  final AgentWorkspace workspace;
  final bool _ownsConnector;
  AiConnector? _connector;
  AiConnector get connector => _connector ??= AiConnector(timeout: const Duration(seconds: 240));

  final List<ChatEntry> entries = [];
  final List<Map<String, Object?>> _history = [];
  String? _historyFor;

  bool busy = false;

  /// What is happening right now, for the panel.
  String? phase;
  bool _stop = false;
  bool _disposed = false;
  Completer<void>? _stopSignal;

  static const int maxSteps = 80;

  /// Times in one request the model is told to carry on after stopping early.
  static const int maxNudges = 3;

  /// Waits before each retry of a request that failed for a passing reason.
  /// Proxies like InferHub answer "502 upstream error" several times in a row when the model behind them is busy,
  /// so this rides out about a minute and a half before giving up.
  static List<Duration> retryDelays = const [
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 25),
    Duration(seconds: 35),
  ];

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void reset() {
    if (busy || _disposed) return;
    entries.clear();
    _history.clear();
    _historyFor = null;
    _notify();
  }

  void stop() {
    if (!busy) return;
    _stop = true;
    final signal = _stopSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
    if (_ownsConnector) _connector?.cancelPending();
    workspace.cancel();
    phase = 'Menghentikan…';
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    if (_ownsConnector) {
      _connector?.close();
      _connector = null;
    }
    super.dispose();
  }

  /// What the model is told about attachments, added to the system prompt while the conversation has one.
  static const String attachmentGuide = '''
Pengguna bisa melampirkan gambar (foto atau gambar panel, diagram rangkaian kontrol atau daya, diagram ladder, wiring) dan file.
Kalau diminta meniru atau mengikuti gambar:
1. Baca gambarnya teliti dulu lalu tulis singkat apa yang terlihat: perangkat beserta tag (QF1, KM1, S1, H1, I1, Q1 dan seterusnya), rating yang terbaca, dan sambungan antar terminal atau isi tiap baris ladder.
2. Cocokkan tiap perangkat dengan katalog yang ada (cari dulu), pilih yang paling mirip fungsi dan ratingnya, dan sebutkan kalau ada yang diganti.
3. Rakit atau tulis sesuai gambar, dengan tag dan urutan yang sama, lalu uji dengan simulator.
4. Bagian yang tidak terbaca atau tidak jelas: tanyakan atau sebutkan asumsi yang kamu pakai. Jangan mengarang sambungan yang tidak terlihat.''';

  /// Note left in the history where an older picture was, so it is not sent again with every request.
  static String _imageNote(int count) => '[$count gambar dari pesan sebelumnya sudah dilihat dan tidak dikirim ulang]';

  static bool _isImageBlock(Object? block) => block is Map && (block['type'] == 'image' || block['type'] == 'image_url');

  Future<void> send(String text, {List<AiAttachment> attachments = const []}) async {
    var message = text.trim();
    if ((message.isEmpty && attachments.isEmpty) || busy || _disposed) return;
    if (message.isEmpty) message = 'Lihat lampiran ini.';
    final settings = app.aiSettings;
    if (settings == null) {
      entries.add(ChatEntry(ChatKind.error, 'AI belum diatur. Buka menu AI, Pengaturan AI.'));
      _notify();
      return;
    }
    final key = await app.secrets.readKey() ?? '';
    if (_disposed) return;
    final target = '${settings.baseUrl}|${settings.format.name}|${settings.model}';
    if (_historyFor != null && _historyFor != target && _history.isNotEmpty) {
      _history.clear();
      entries.add(ChatEntry(ChatKind.info, 'Model diganti ke ${settings.model}. Percakapan dimulai ulang.'));
    }
    _historyFor = target;

    busy = true;
    _stop = false;
    _stopSignal = Completer<void>();
    workspace.begin();
    entries.add(ChatEntry(ChatKind.user, message, attachments: attachments));
    // Only the newest pictures travel with each request; older ones are replaced by a note.
    if (attachments.any((a) => a.isImage)) {
      for (final old in _history) {
        if (old['role'] == 'user' && AiAttachment.hasImage(old)) {
          AiAttachment.dropImages(old, _imageNote((old['content'] as List).where(_isImageBlock).length));
        }
      }
    }
    _history.add({'role': 'user', 'content': AiAttachment.content(settings.format, '$message\n\n[${workspace.context()}]', attachments)});
    _notify();

    // Whether the canvas changed since the last simulator test, and how often the model was told to carry on.
    var untested = false;
    var nudges = 0;
    try {
      var step = 0;
      for (; step < maxSteps && !_stop && !_disposed; step++) {
        phase = step == 0 ? 'Memikirkan permintaanmu…' : 'Memikirkan langkah berikutnya…';
        workspace.thinking(true);
        _notify();
        final reply = await _ask(settings, key);
        if (reply == null || _stop || _disposed) break; // stopped while waiting to retry
        _history.add(_assistantMessage(settings.format, reply));
        if (reply.text.trim().isNotEmpty) entries.add(ChatEntry(ChatKind.assistant, reply.text.trim()));

        if (reply.toolCalls.isEmpty) {
          // Models sometimes stop mid-job: an empty reply, a cut-off one, "now I will…" without doing it, or
          // finishing without testing what they built. Tell them to carry on, a few times at most.
          final nudge = nudgeFor(reply, untested);
          if (nudge == null || nudges >= maxNudges || _stop || _disposed) break;
          nudges++;
          _history.add({'role': 'user', 'content': nudge});
          continue;
        }

        final results = <(String, ToolOutcome)>[];
        workspace.thinking(false);
        for (final call in reply.toolCalls) {
          if (_stop || _disposed) {
            results.add((call.id, const ToolOutcome('{"galat":"Dibatalkan pengguna."}', 'Dibatalkan', error: true)));
            continue;
          }
          if (call.badArguments || (reply.truncated && identical(call, reply.toolCalls.last))) {
            // Running half an instruction would build half a circuit; ask for it again in smaller pieces.
            results.add((call.id, const ToolOutcome(
                '{"galat":"Argumen panggilan ini terpotong atau bukan JSON yang utuh, jadi tidak dijalankan. Ulangi dengan isi yang lebih kecil, misalnya paling banyak 12 kabel atau 8 perangkat per panggilan."}',
                'Perintah terpotong, diulang',
                error: true)));
            continue;
          }
          phase = 'Menjalankan ${call.name.replaceAll('_', ' ')}…';
          _notify();
          final outcome = await workspace.run(call.name, call.input);
          if (!outcome.error && workspace.editingTools.contains(call.name)) untested = true;
          if (call.name == workspace.testTool && !outcome.error) untested = false;
          results.add((call.id, outcome));
          if (!_disposed) {
            entries.add(ChatEntry(ChatKind.tool, outcome.label, failed: outcome.error));
            _notify();
          }
        }
        _history.addAll(_toolResults(settings.format, results));
        _compactHistory();
      }
      if (!_disposed) {
        if (_stop) {
          entries.add(ChatEntry(ChatKind.info, 'Dihentikan.'));
        } else if (step >= maxSteps) {
          entries.add(ChatEntry(ChatKind.info, 'Berhenti setelah $maxSteps langkah. Ketik "lanjutkan" untuk meneruskan.'));
        }
      }
    } on AiError catch (error) {
      final pictures = _history.where((m) => m['role'] == 'user' && AiAttachment.hasImage(m)).toList();
      if (!error.transient && pictures.isNotEmpty) {
        // Most often the model cannot read pictures. Take them out so the conversation can go on without them.
        for (final m in pictures) {
          AiAttachment.dropImages(m, '[gambar tidak terkirim: model ini menolaknya]');
        }
        entries.add(ChatEntry(ChatKind.error,
            '${error.message}\nKemungkinan model ${settings.model} tidak bisa membaca gambar. Pilih model yang mendukung gambar di Pengaturan AI '
            '(misalnya Claude atau GPT-4o), atau jelaskan isinya dengan teks. Gambarnya sudah dikeluarkan dari percakapan.'));
        return;
      }
      // The history stays as it was, so the user can pick up where it broke off.
      final resumable = error.transient && _history.length > 1;
      entries.add(ChatEntry(ChatKind.error,
          resumable ? '${error.message}\nServer AI sedang bermasalah. Pekerjaan sejauh ini tetap tersimpan; ketik "lanjutkan" untuk meneruskan.' : error.message));
    } catch (error) {
      entries.add(ChatEntry(ChatKind.error, 'Terjadi kesalahan: $error'));
    } finally {
      _stopSignal = null;
      if (!_disposed) workspace.end();
      busy = false;
      phase = null;
      _notify();
    }
  }

  Future<AiReply?> _raceStop(Future<AiReply> future) {
    final stop = _stopSignal;
    if (_stop || _disposed || stop == null) {
      future.ignore();
      return Future.value(null);
    }
    final done = Completer<AiReply?>();
    future.then(
      (v) {
        if (!done.isCompleted) done.complete(v);
      },
      onError: (Object e, StackTrace s) {
        if (!done.isCompleted) done.completeError(e, s);
      },
    );
    stop.future.then((_) {
      if (!done.isCompleted) done.complete(null);
    });
    return done.future;
  }

  static bool _hasAttachmentText(Map<String, Object?> message) {
    final content = message['content'];
    if (content is String) return content.contains('[Lampiran ');
    if (content is List) {
      return content.any((b) => b is Map && b['type'] == 'text' && b['text'] is String && (b['text'] as String).contains('[Lampiran '));
    }
    return false;
  }

  /// One model request, retried when the endpoint is busy, the connection drops, or the answer is garbled.
  /// Returns null when the user stops while it waits.
  Future<AiReply?> _ask(AiSettings settings, String key) async {
    for (var attempt = 0;; attempt++) {
      if (_stop || _disposed) return null;
      try {
        final reply = await _raceStop(connector.chat(
            settings.baseUrl, key, settings.format, settings.model, _history,
            tools: workspace.tools,
            system: _history.any((m) => AiAttachment.hasImage(m) || _hasAttachmentText(m))
                ? '${workspace.systemPrompt}\n\n$attachmentGuide'
                : workspace.systemPrompt,
            maxTokens: 8192));
        if (reply == null || _stop || _disposed) return null;
        if (reply.valid) return reply;
        if (attempt >= retryDelays.length) throw AiError('Jawaban model tidak bisa dibaca.');
      } on AiError catch (error) {
        if (_stop || _disposed) return null;
        if (!error.transient || attempt >= retryDelays.length) rethrow;
      }
      phase = 'Koneksi bermasalah, mencoba lagi (${attempt + 1}/${retryDelays.length})…';
      _notify();
      final until = DateTime.now().add(retryDelays[attempt]);
      while (DateTime.now().isBefore(until)) {
        if (_stop || _disposed) return null;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (_stop || _disposed) return null;
    }
  }

  /// What to tell a model that answered without calling a tool, or null when it really is done.
  @visibleForTesting
  static String? nudgeFor(AiReply reply, bool untested) {
    final text = reply.text.trim();
    if (reply.truncated) {
      return 'Jawabanmu terpotong karena terlalu panjang. Lanjutkan pekerjaanmu dengan alat, dan buat penjelasan akhirnya singkat.';
    }
    if (text.isEmpty) return 'Jawabanmu kosong. Lanjutkan pekerjaanmu dengan alat, atau tulis penjelasan akhir kalau sudah selesai.';
    if (untested) {
      return 'Pekerjaan sudah diubah tetapi belum diuji sejak perubahan terakhir. Lanjutkan sekarang dengan alat uji (uji_simulasi atau uji_program) '
          '(nyalakan pengaman, operasikan tombol, cek hasil dan tombol stop). Kalau hasilnya salah, perbaiki lalu uji lagi. Baru setelah itu beri penjelasan akhir.';
    }
    if (soundsUnfinished(text)) return 'Lanjutkan langsung dengan memanggil alat yang diperlukan. Jangan hanya menuliskan rencananya.';
    return null;
  }

  /// "Sekarang saya akan menyambung kabel:" — announcing a step instead of doing it.
  @visibleForTesting
  static bool soundsUnfinished(String text) {
    final tail = text.length > 240 ? text.substring(text.length - 240) : text;
    final lower = tail.toLowerCase();
    if (RegExp(r'[:：]\s*$').hasMatch(tail)) return true;
    final announces = RegExp(r'(saya akan|aku akan|akan saya|sekarang (saya |aku )?(sambung|tambah|pasang|uji|perbaiki|cek|periksa)|selanjutnya|mari (kita )?|let me|now i will|i will now|next,? i)');
    final wrapsUp = RegExp(r'(cara mencoba|cara pakai|tekan jalankan|klik jalankan|selesai|sudah (diuji|bekerja|berhasil|jadi))');
    return announces.hasMatch(lower) && !wrapsUp.hasMatch(lower);
  }

  /// Long requests pile up big tool results (catalog searches, examples, simulator reports) that the model has
  /// already acted on. Older ones are cut down so the conversation stays within the model's memory and quick.
  void _compactHistory() {
    const keepRecent = 12, limit = 1500;
    final cutoff = _history.length - keepRecent;
    String shorten(String text) => text.length <= limit ? text : '${text.substring(0, limit)}… [dipotong; panggil alatnya lagi kalau perlu detail]';
    for (var i = 0; i < cutoff; i++) {
      final message = _history[i];
      if (message['role'] == 'tool' && message['content'] is String) {
        message['content'] = shorten(message['content'] as String);
      } else if (message['role'] == 'user' && message['content'] is List) {
        for (final block in (message['content'] as List).whereType<Map<String, Object?>>()) {
          if (block['type'] == 'tool_result' && block['content'] is String) block['content'] = shorten(block['content'] as String);
        }
      }
    }
  }

  static Map<String, Object?> _assistantMessage(ApiFormat format, AiReply reply) {
    final raw = reply.raw;
    switch (format) {
      case ApiFormat.anthropic:
        return {'role': 'assistant', 'content': (raw as Map<String, dynamic>)['content']};
      case ApiFormat.openai:
        final message = Map<String, Object?>.of(((raw as Map<String, dynamic>)['choices'] as List).first['message'] as Map<String, dynamic>);
        message['role'] = 'assistant';
        message['content'] ??= '';
        return message;
    }
  }

  static List<Map<String, Object?>> _toolResults(ApiFormat format, List<(String, ToolOutcome)> results) => switch (format) {
        ApiFormat.anthropic => [
            {
              'role': 'user',
              'content': [
                for (final (id, outcome) in results) {'type': 'tool_result', 'tool_use_id': id, 'content': outcome.result, if (outcome.error) 'is_error': true},
              ],
            },
          ],
        ApiFormat.openai => [
            for (final (id, outcome) in results) {'role': 'tool', 'tool_call_id': id, 'content': outcome.result},
          ],
      };

  static final String systemPrompt = '''
Kamu asisten di BuildWire, aplikasi desain dan simulasi panel listrik. Kamu merakit rangkaian langsung di kanvas memakai alat yang tersedia, lalu mengujinya sendiri di simulator. Jawab dalam bahasa Indonesia yang singkat dan jelas.

Pengguna menonton kamu bekerja: setiap aksi dikerjakan oleh tim kursor yang terlihat di layar.

Cara kerja:
0. Sebelum mengubah kanvas, panggil bentuk_tim sekali: karang nama-nama yang bebas dan acak untuk timmu (nama pertama ketua), jumlahnya sesuai kerumitan.
1. Pahami permintaannya. Untuk rangkaian yang mirip contoh bawaan, pelajari dulu dengan lihat_contoh.
2. Pilih perangkat, utamakan perangkat rekomendasi di bawah. Pastikan nama terminal dengan info_perangkat sebelum menyambung. Jangan menebak nama terminal.
3. Kalau pengguna minta rangkaian baru dan kanvas sudah berisi, kosongkan kanvas dulu (pengguna bisa mengurungkannya). Kalau pengguna minta mengubah, memeriksa, atau memperbaiki, lihat_rangkaian dulu lalu kerjakan pada rangkaian yang ada.
4. Taruh semua perangkat dengan rapi dalam satu panggilan tambah_perangkat, lalu sambung semua kabel dalam satu atau dua panggilan sambung.
5. WAJIB uji dengan uji_simulasi sebelum selesai: nyalakan pengaman (klik QF1, F2, dan seterusnya), operasikan tombol, tunggu timer, lalu pastikan hasilnya benar (kontaktor closed, motor run_fwd atau run_rev, lampu on, tanpa korsleting dan tanpa peringatan). Uji juga tombol stop dan proteksinya. Kalau hasilnya salah, perbaiki lalu uji lagi.
   Kalau uji gagal (korsleting, kontaktor tidak menarik), jangan mengulang uji yang sama. Cari penyebabnya: lihat langkah mana yang pertama kali berubah salah, lihat_rangkaian, periksa kabel yang menyentuh perangkat itu, lalu perbaiki kabel yang salah. Bila perlu hapus sementara kabel yang dicurigai dan uji lagi.
6. Akhiri dengan penjelasan singkat: apa yang dirakit dan cara mencobanya (urutan klik setelah menekan Jalankan). Jangan menampilkan JSON.

Konvensi kelistrikan:
- Sumber 3 fasa: L1 L2 L3 N PE. Warna kabel: L1 coklat, L2 hitam, L3 abu, N biru, PE hijau, kontrol merah. Kabel daya 2,5 mm2, kontrol 1,5 mm2.
- MCB dan pengaman lain: masuk di terminal ganjil (1, 3, 5) dari arah sumber, keluar di terminal genap (2, 4, 6).
- Kontaktor: kontak utama 1-2, 3-4, 5-6. Koil A1-A2 230 V: A1 dari rangkaian kontrol, A2 ke N. Kontak bantu 13-14 NO untuk self-holding, 21-22 NC untuk interlock.
- Rangkaian kontrol 230 V: L1 setelah MCB utama, lalu MCB kontrol 1 kutub, tombol stop NC, tombol start NO (diparalel dengan kontak 13-14 untuk self-holding), lalu koil A1. A2 ke N.
- Overload: dipasang setelah kontaktor dan sebelum motor. Kontak 95-96 NC diseri di rangkaian kontrol; 97-98 NO untuk lampu trip atau input PLC.
- Motor 6 terminal: delta dengan jumper U1-W2, V1-U2, W1-V2; bintang dengan menyatukan U2, V2, W2 (langsung atau lewat kontaktor bintang). Selalu sambung PE motor ke PE sumber.
- Tombol tekan hijau NO memakai terminal 3-4, merah NC memakai 1-2. Lampu indikator X1-X2.
- Timer on-delay: koil A1-A2; setelah waktu habis 15-18 menutup dan 15-16 membuka.
- Satu terminal beban hanya boleh diberi dari satu titik kontrol. Jangan menyatukan keluaran dua kontak yang berbeda (misalnya KM1.14 dan KM2.14, atau keluaran dua tombol) ke satu terminal lampu atau koil: itu membuat jalur bocor yang ikut menyalakan koil lain dan bisa korsleting. Pakai lampu terpisah untuk tiap keadaan, atau ambil dari kontak bantu kontaktor itu sendiri.
- PLC Zelio (Schneider): sama seperti LOGO tetapi alamatnya gaya Zelio: input I1..I9 lalu IA, IB …; output Q1..Q9, QA. Pada SR3B261 output Q8, Q9, QA berbagi terminal C (beri L ke C, Qx ke beban). Program Zelio bisa memakai koil SQ1/RQ1 (set/reset), ^Q1 (impuls), timer TT1 dengan fungsi A/C/B/D/L…, dan counter CC1/RC1.
- PLC LOGO: catu L dan N. Input I1-I8 diberi L lewat tombol. Output relay: Qn.1 diberi L, Qn.2 ke koil kontaktor. Tombol stop NC sebaiknya dibaca sebagai kontak NO di program supaya fail-safe.

Rangkaian DC:
- Simulator mengenal beberapa tegangan DC sekaligus (12, 24, 48 V, atau berapa pun dari sumber DC yang bisa diatur). DC- adalah 0 V bersama; beberapa sumber boleh berbagi minus, tapi plus dari tegangan berbeda tidak boleh disatukan.
- Perangkat 24 V DC punya akhiran "24vdc" atau "24 V DC" di namanya. Jangan beri DC ke perangkat AC atau sebaliknya.
- Warna kabel DC: + merah, - biru. Kontrol panel modern: tombol dan relay 24 V DC, lalu kontak relay menyalakan koil kontaktor 230 V.
- Motor DC: polaritas menentukan arah, tegangan menentukan kecepatan. Untuk maju-mundur pakai dua relay sebagai H-bridge dengan interlock NC.

Tata letak (piksel kanvas, x ke kanan, y ke bawah, titik kiri-atas perangkat):
- Bebas dan tidak harus rapi. Taruh perangkat di mana saja yang masuk akal, asal tidak bertumpuk (beri jarak sekitar 40 px) dan semuanya tetap berdekatan supaya mudah dilihat.
- Ukuran tiap perangkat ada di hasil cari_perangkat dan info_perangkat.

Perangkat rekomendasi (id: keterangan):
${kRecommendedDevices.entries.map((e) => '- ${e.key}: ${e.value}').join('\n')}
''';
}
