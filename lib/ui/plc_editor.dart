import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ai/ai_agent.dart';
import '../ai/ladder_tools.dart';
import '../app_state.dart';
import '../file_io.dart';
import '../model/device_def.dart';
import '../model/project.dart';
import '../sim/ladder.dart';
import '../sim/plc.dart';
import '../sim/zm2.dart';
import 'ai_chat_panel.dart';
import 'ladder_start.dart';
import 'theme.dart';

/// The editor's name, shown in its title and on the home page. Kept in one place so it is easy to change.
const String kLadderEditorName = 'BuildLadder';

/// Opens the editor for a PLC on the canvas.
Future<void> showPlcEditor(BuildContext context, AppState app, PlacedDevice plc) => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
        child: LadderEditor(app: app, plc: plc),
      ),
    );

/// Opens BuildLadder on its own, from the home page: first its start page (new or open, module from photos,
/// language), then the editor to write, simulate and save programs without a circuit.
Future<void> showStandaloneLadder(BuildContext context, AppState app) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LadderStartPage(app: app)),
    );

/// The PLC model last used in the stand-alone editor, offered again on the start page.
String? lastLadderModel;

enum _Tool { select, wire, vertical, erase, contact, coil }

/// A ladder editor laid out like Zelio Soft's ladder entry: the grid of five contact columns and a coil column on
/// top, the element palette along the bottom. A palette button opens its list; drag an item onto a cell (or click
/// the item, then the cell). Click an empty cell for a wire, a cell's right edge for a vertical link.
class LadderEditor extends StatefulWidget {
  const LadderEditor({super.key, required this.app, this.plc, this.defId, this.initialFile}) : assert(plc != null || defId != null);

  /// A file picked on the start page, opened as soon as the editor shows.
  final (String, Uint8List)? initialFile;

  final AppState app;

  /// The PLC on the canvas being programmed, or null when the editor runs on its own.
  final PlacedDevice? plc;

  /// The PLC model when the editor runs on its own.
  final String? defId;

  @override
  State<LadderEditor> createState() => _LadderEditorState();
}

class _LadderEditorState extends State<LadderEditor> {
  late LadderProgram _program;
  late String _defId;
  _Tool _tool = _Tool.select;
  String _ref = 'I1';
  bool _nc = false;
  String _coilFn = '[';
  (int, int)? _selected;
  bool _dirty = false;
  final _focus = FocusNode();

  /// The editor's own messenger, so notices show inside it whether it is a dialog or a page.
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  /// The palette list that is open: 'I', 'Z' … for contacts, 'cQ', 'cM' … for coils.
  String? _openList;

  // Simulation when the editor runs on its own.
  bool _simulating = false;
  final Set<String> _simInputs = {};
  final Set<String> _simHeld = {};
  PlcMemory _simMemory = PlcMemory();
  Set<String> _simBits = {};
  final _clock = Stopwatch();
  Timer? _ticker;

  /// The assistant for this editor: it writes and tests the program open here.
  late final AiAgent _agent = AiAgent(
    app,
    workspace: LadderWorkspace(
      def: () => _def,
      read: () => _program,
      write: (program) {
        _stopSim();
        if (!mounted) return;
        setState(() {
          _program = program;
          _dirty = true;
          _selected = null;
        });
      },
    ),
  );
  bool _aiOpen = false;

  AppState get app => widget.app;
  bool get _standalone => widget.plc == null;
  DeviceDef get _def => app.defs[_defId]!;

  @override
  void initState() {
    super.initState();
    _defId = widget.plc?.defId ?? widget.defId!;
    if (_standalone) lastLadderModel = _defId;
    final file = widget.initialFile;
    if (file != null) WidgetsBinding.instance.addPostFrameCallback((_) => _openInitial(file));
    _program = _standalone ? LadderProgram() : app.ladderOf(widget.plc!).copy();
    app.addListener(_onApp);
    _agent.addListener(_onAgent);
  }

  void _onAgent() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _agent
      ..removeListener(_onAgent)
      ..stop()
      ..dispose();
    _ticker?.cancel();
    app.removeListener(_onApp);
    _focus.dispose();
    super.dispose();
  }

  /// Redraws the monitor while the canvas simulation runs.
  void _onApp() {
    if (mounted && !_standalone && app.running) setState(() {});
  }

  // ----- Addresses

  bool get _zelio => _def.isZelio;

  Map<String, List<String>> get _families => {
        'I': _def.plcInputs,
        'Z': const ['Z1', 'Z2', 'Z3', 'Z4'],
        'M': _zelio ? ladderNames('M', 28) : kPlcMemory,
        'Q': _def.plcOutputs,
        'T': ladderNames('T', _zelio ? 28 : 16),
        'C': ladderNames('C', _zelio ? 28 : 16),
        'H': ladderNames('H', 8),
      };

  static const Map<String, String> _familyNames = {
    'I': 'Input', 'Z': 'Tombol panah', 'M': 'Relay bantu', 'Q': 'Output', 'T': 'Timer', 'C': 'Counter', 'H': 'Jam (jadwal)',
  };

  static const Map<String, IconData> _familyIcons = {
    'I': Icons.login, 'Z': Icons.gamepad_outlined, 'M': Icons.memory, 'Q': Icons.logout, 'T': Icons.timer_outlined, 'C': Icons.pin_outlined, 'H': Icons.schedule,
  };

  /// Coil kinds a family can drive.
  static const Map<String, List<String>> _coilKinds = {
    'Q': ['[', '^', 'S', 'R'],
    'M': ['[', '^', 'S', 'R'],
    'T': ['T', 'R'],
    'C': ['C', 'D', 'R'],
  };

  Set<String> get _bits => _standalone ? (_simulating ? _simBits : const {}) : (app.running ? app.bitsOf(widget.plc!) : const {});
  bool get _live => _standalone ? _simulating : app.running;

  // ----- Editing

  LadderRow _row(int r) {
    while (_program.rows.length <= r) {
      _program.rows.add(LadderRow());
    }
    return _program.rows[r];
  }

  void _change(VoidCallback edit) {
    if (_simulating) return;
    setState(() {
      edit();
      _dirty = true;
    });
  }

  void _placeContact(int r, int c, String ref, bool nc) {
    final row = _row(r);
    _change(() => row.cells[c] = LadderCell.contact(ref, nc: nc, down: row.cells[c].down));
    _selected = (r, c);
  }

  void _placeCoil(int r, LadderCoil coil) {
    final row = _row(r);
    _change(() {
      row.coil = coil;
      // Fill the gap between the last contact and the coil with wire, as Zelio requires.
      final last = row.cells.lastIndexWhere((c) => !c.isEmpty);
      if (last >= 0) {
        for (var c = last + 1; c < LadderProgram.columns; c++) {
          if (row.cells[c].isEmpty) row.cells[c] = LadderCell.wire(down: row.cells[c].down);
        }
      }
    });
    _selected = (r, LadderProgram.columns);
  }

  void _tapCell(int r, int c, {required bool edge}) {
    if (_simulating) return;
    final row = _row(r);
    if (c == LadderProgram.columns) {
      switch (_tool) {
        case _Tool.coil:
          _placeCoil(r, LadderCoil(_coilFn, _ref));
        case _Tool.erase:
          _change(() => row.coil = null);
        default:
          setState(() => _selected = (r, c));
      }
      return;
    }
    final cell = row.cells[c];
    if (edge || _tool == _Tool.vertical) {
      if (r >= LadderProgram.maxRows - 1) return;
      _change(() => row.cells[c] = cell.withDown(!cell.down));
      return;
    }
    switch (_tool) {
      case _Tool.contact:
        _placeContact(r, c, _ref, _nc);
      case _Tool.wire:
        _change(() => row.cells[c] = cell.wire ? LadderCell.empty(down: cell.down) : LadderCell.wire(down: cell.down));
      case _Tool.erase:
        _change(() => row.cells[c] = const LadderCell.empty());
      case _Tool.coil:
        setState(() => _selected = (r, c));
      case _Tool.select || _Tool.vertical:
        if (cell.isEmpty) {
          _change(() => row.cells[c] = LadderCell.wire(down: cell.down));
        } else {
          setState(() => _selected = (r, c));
        }
    }
  }

  void _deleteSelected() {
    final sel = _selected;
    if (sel == null) return;
    final (r, c) = sel;
    if (r >= _program.rows.length) return;
    _change(() {
      if (c == LadderProgram.columns) {
        _program.rows[r].coil = null;
      } else {
        _program.rows[r].cells[c] = const LadderCell.empty();
      }
    });
  }

  void _insertRow(int r) => _change(() {
        if (_program.rows.length < LadderProgram.maxRows) _program.rows.insert(r.clamp(0, _program.rows.length), LadderRow());
      });

  void _deleteRow(int r) => _change(() {
        if (r < _program.rows.length) _program.rows.removeAt(r);
      });

  // ----- Files

  /// Opens a BuildLadder (.bwlad) or Zelio Soft 2 (.zm2) file into the editor.
  Future<void> openBytes(String name, List<int> bytes) async {
    LadderProgram program;
    String? model;
    var note = 'Program "$name" dibuka.';
    if (name.toLowerCase().endsWith('.zm2')) {
      final result = readZm2(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
      program = result.program;
      model = result.module;
      note = 'Program Zelio ${result.module.isEmpty ? '' : '(${result.module}) '}dibuka.'
          '${result.warnings.isEmpty ? '' : ' Tidak disimulasikan: ${result.warnings.join(', ')}.'}';
    } else {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      program = LadderProgram.fromJson((json['program'] ?? json) as Map<String, dynamic>);
      model = json['plc'] as String?;
    }
    _stopSim();
    if (!mounted) return;
    setState(() {
      _program = program;
      _dirty = true;
      _selected = null;
      // On its own, the editor switches to the model the file was written for when the catalog has it.
      if (_standalone && model != null) {
        final id = app.defs.containsKey(model) ? model : 'zelio_${model.toLowerCase()}';
        if (app.defs[id]?.kind == 'plc') _defId = lastLadderModel = id;
      }
    });
    _messenger.currentState?.showSnackBar(SnackBar(content: Text('$note${_standalone ? '' : ' Tekan Kirim ke PLC untuk memakainya.'}')));
  }

  Future<void> _openInitial((String, Uint8List) file) async {
    if (!mounted) return;
    try {
      await openBytes(file.$1, file.$2);
    } on FormatException catch (error) {
      if (mounted) _messenger.currentState?.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (mounted) _messenger.currentState?.showSnackBar(SnackBar(content: Text('File tidak bisa dibuka: $error')));
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final tokens = context.tokens;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: tokens.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
        title: Text('Perubahan belum disimpan', style: uiText(17, tokens.text, weight: 700)),
        content: Text(
          _standalone
              ? 'Program ladder ini belum disimpan ke file. Buang perubahan?'
              : 'Perubahan belum dikirim ke PLC. Buang perubahan?',
          style: uiText(13, tokens.textMuted, height: 1.45),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Buang perubahan')),
        ],
      ),
    );
    return discard ?? false;
  }

  Future<void> _open() async {
    if (!await _confirmDiscard() || !mounted) return;
    try {
      final picked = await pickLadderFile();
      if (picked == null || !mounted) return;
      await openBytes(picked.$1, picked.$2);
    } on FormatException catch (error) {
      if (mounted) _messenger.currentState?.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (mounted) _messenger.currentState?.showSnackBar(SnackBar(content: Text('File tidak bisa dibuka: $error')));
    }
  }

  /// The program as a Zelio Soft 2 file for this model, or null when the model has no Zelio template (LOGO).
  Future<Uint8List?> zm2Bytes() async {
    if (!_def.isZelio) return null;
    final template = await rootBundle.load('assets/zelio/$_defId.zm2');
    return writeZm2(_program, template.buffer.asUint8List());
  }

  Future<void> _saveFile() async {
    final text = const JsonEncoder.withIndent('  ').convert({'format': 'buildladder/1', 'plc': _defId, 'program': _program.toJson()});
    Uint8List? zm2;
    String? zm2Problem;
    try {
      zm2 = await zm2Bytes();
    } on FormatException catch (error) {
      zm2Problem = error.message;
    } catch (error) {
      zm2Problem = '$error';
    }
    final String? written;
    try {
      written = await saveLadderFile(widget.plc == null ? 'program_ladder' : '${widget.plc!.tag}_ladder', zm2: zm2, bwlad: text);
    } catch (error) {
      if (mounted) _messenger.currentState?.showSnackBar(SnackBar(content: Text('Gagal menyimpan file: $error')));
      return;
    }
    if (written == null || !mounted) return;
    setState(() => _dirty = _standalone ? false : _dirty);
    final comments = _program.rows.any((r) => r.comment.isNotEmpty);
    _messenger.currentState?.showSnackBar(SnackBar(
      content: Text(written == 'zm2'
          ? 'Disimpan sebagai file Zelio Soft (.zm2).${comments ? ' Komentar baris hanya tersimpan di .bwlad.' : ''}'
          : 'Disimpan sebagai file BuildLadder (.bwlad).${zm2Problem != null ? ' Tidak bisa .zm2: $zm2Problem' : ''}'),
    ));
  }

  void _send() {
    app.setProgram(widget.plc!, _program.copy());
    setState(() => _dirty = false);
  }

  /// From the home page: put this PLC with the program on the canvas and go there.
  void _useOnCanvas() {
    final navigator = Navigator.of(context);
    app.openBuilder();
    final before = app.project.devices.length;
    app.addDevice(_defId, world: Offset(80 + before * 30.0, 80));
    final plc = app.project.devices.last;
    app.setProgram(plc, _program.copy());
    navigator.pop();
  }

  // ----- Simulation on its own

  void _toggleSim() {
    if (_simulating) {
      _stopSim();
      return;
    }
    setState(() {
      _simulating = true;
      _simInputs.clear();
      _simHeld.clear();
      _simMemory = PlcMemory();
      _clock
        ..reset()
        ..start();
      _openList = null;
    });
    _scan();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _scan());
  }

  void _stopSim() {
    _ticker?.cancel();
    _ticker = null;
    _clock.stop();
    if (mounted) setState(() => _simulating = false);
  }

  void _scan() {
    if (!mounted || !_simulating) return;
    final result = scanLadder(_program, inputs: {..._simInputs}, external: {..._simHeld}, memory: _simMemory, now: _clock.elapsedMilliseconds / 1000, clock: DateTime.now());
    final changed = result.bits.length != _simBits.length ||
        !result.bits.containsAll(_simBits) ||
        _simMemory.ticking ||
        result.memory.ticking ||
        _program.clocks.isNotEmpty;
    _simMemory = result.memory;
    _simBits = result.bits;
    if (changed) setState(() {});
  }

  // ----- Build

  static bool get _typing {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null && (context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (!await _confirmDiscard()) return;
        if (!context.mounted) return;
        Navigator.of(context).pop();
      },
      child: ScaffoldMessenger(
        key: _messenger,
        child: Scaffold(
          backgroundColor: tokens.panel,
          // The palette sits in the bottom bar so notices appear above it instead of covering it.
          bottomNavigationBar: AbsorbPointer(absorbing: _agent.busy, child: _bottomBar(tokens)),
          body: Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.delete && !_typing && !_agent.busy && !_simulating) {
                _deleteSelected();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(tokens),
                Divider(height: 1, color: tokens.border),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: AbsorbPointer(absorbing: _agent.busy, child: _grid(tokens))),
                            if (_openList != null && !_simulating) _list(tokens),
                          ],
                        ),
                      ),
                      if (_aiOpen)
                        AiChatPanel(
                          key: const ValueKey('ladder-ai-panel'),
                          app: app,
                          agent: _agent,
                          width: 380,
                          hint: 'Minta dibuatkan, diubah, diuji, atau dijelaskan…',
                          onClose: () => setState(() => _aiOpen = false),
                          intro: 'Asisten menulis program ladder langsung di editor ini, lalu mengujinya di simulator sampai benar. '
                              'Program baru dipakai setelah kamu menekan ${_standalone ? 'Simpan file atau Pakai di kanvas' : 'Kirim ke PLC'}.',
                          suggestions: const [
                            'Buat start-stop motor: I1 start, I2 stop (NC), Q1 motor, dengan self-holding',
                            'Buat star-delta: I1 start, I2 stop, Q1 line, Q2 star, Q3 delta, pindah setelah 5 detik',
                            'Lampu Q1 berkedip 1 detik selama saklar I1 menyala',
                            'Jelaskan program yang sedang terbuka',
                          ],
                        )
                      else ...[
                        VerticalDivider(width: 1, color: tokens.border),
                        SizedBox(width: 270, child: _simulating ? _simPanel(tokens) : _properties(tokens)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(Tokens tokens) {
    final plcs = app.defs.values.where((d) => d.kind == 'plc' && d.panel != null).toList()..sort((a, b) => a.name.compareTo(b.name));
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
      child: Row(
        children: [
          const Nameplate(kLadderEditorName, size: 17),
          const SizedBox(width: 12),
          if (_standalone)
            // Shrinks on narrow windows so the buttons on the right always fit.
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 300),
                child: DropdownButton<String>(
                key: const ValueKey('ladder-model'),
                isExpanded: true,
                value: _defId,
                underline: const SizedBox.shrink(),
                items: [for (final d in plcs) DropdownMenuItem(value: d.id, child: Text(d.name, overflow: TextOverflow.ellipsis, style: uiText(13, tokens.text)))],
                onChanged: _simulating ? null : (id) => setState(() => _defId = lastLadderModel = id ?? _defId),
                ),
              ),
            )
          else
            Flexible(child: Text('${widget.plc!.tag} · ${_def.name}', overflow: TextOverflow.ellipsis, style: uiText(13, tokens.textMuted, weight: 500))),
          if (_live) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: tokens.run.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(Radii.plate)),
              child: Text(_standalone ? 'Simulasi berjalan' : 'Monitor', style: plateText(14, tokens.run, weight: 700)),
            ),
          ],
          const Spacer(),
          OutlinedButton.icon(
            key: const ValueKey('ladder-ai'),
            onPressed: () => setState(() => _aiOpen = !_aiOpen),
            style: OutlinedButton.styleFrom(
              backgroundColor: _aiOpen ? tokens.hover : null,
              side: BorderSide(color: _aiOpen ? tokens.text : tokens.border),
            ),
            icon: const Icon(Icons.forum_outlined, size: 16),
            label: const Text('Asisten AI'),
          ),
          const SizedBox(width: 8),
          if (_standalone) ...[
            IconButton(
              key: const ValueKey('ladder-new'),
              tooltip: 'Program baru (pilih modul)',
              onPressed: () async {
                if (!await _confirmDiscard() || !mounted) return;
                Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => LadderStartPage(app: app)));
              },
              icon: const Icon(Icons.note_add_outlined),
            ),
            const SizedBox(width: 4),
          ],
          IconButton(key: const ValueKey('ladder-open'), tooltip: 'Buka file (.bwlad, .zm2)', onPressed: _open, icon: const Icon(Icons.folder_open_outlined, size: 20)),
          IconButton(key: const ValueKey('ladder-save-file'), tooltip: 'Simpan file', onPressed: _saveFile, icon: const Icon(Icons.save_outlined, size: 20)),
          const SizedBox(width: 8),
          if (_standalone) ...[
            OutlinedButton.icon(
              key: const ValueKey('ladder-to-canvas'),
              onPressed: _program.isEmpty ? null : _useOnCanvas,
              icon: const Icon(Icons.dashboard_customize_outlined, size: 16),
              label: const Text('Pakai di kanvas'),
            ),
            const SizedBox(width: 8),
            // Running the program is what this screen is for: the one hazard-yellow button, red while it runs.
            FilledButton.icon(
              key: const ValueKey('ladder-simulate'),
              onPressed: _toggleSim,
              style: _simulating ? FilledButton.styleFrom(backgroundColor: tokens.error, foregroundColor: Colors.white, iconColor: Colors.white) : null,
              icon: Icon(_simulating ? Icons.stop : Icons.play_arrow, size: 17),
              label: Text(_simulating ? 'Hentikan' : 'Simulasi'),
            ),
          ] else
            FilledButton.icon(
              key: const ValueKey('save-program'),
              onPressed: _dirty ? _send : null,
              icon: const Icon(Icons.upload, size: 16),
              label: const Text('Kirim ke PLC'),
            ),
          const SizedBox(width: 6),
          IconButton(
            key: const ValueKey('ladder-close'),
            tooltip: _dirty ? 'Tutup (perubahan belum disimpan)' : 'Tutup',
            onPressed: () async {
              if (!await _confirmDiscard() || !mounted) return;
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  // ----- Palette along the bottom, Zelio style

  Widget _bottomBar(Tokens tokens) {
    Widget tool(_Tool value, IconData icon, String tip, String key) => _PaletteButton(
          key: ValueKey(key),
          tip: tip,
          active: _tool == value,
          onTap: _simulating ? null : () => setState(() => _tool = value),
          child: Icon(icon, size: 18, color: _tool == value ? tokens.accent : tokens.text),
        );
    Widget family(String letter, {required bool coil}) {
      final id = coil ? 'c$letter' : letter;
      final open = _openList == id;
      final armed = (coil ? _tool == _Tool.coil : _tool == _Tool.contact) && _families[letter]!.contains(_ref);
      return _PaletteButton(
        key: ValueKey('ladder-${coil ? 'coil' : 'contact'}-$letter'),
        tip: '${coil ? 'Koil' : 'Kontak'} ${_familyNames[letter]}',
        active: open || armed,
        onTap: _simulating ? null : () => setState(() => _openList = open ? null : id),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(size: const Size(20, 14), painter: _SymbolPainter(coil: coil, color: open || armed ? tokens.accent : tokens.text)),
            const SizedBox(width: 4),
            Text(letter, style: uiText(13, open || armed ? tokens.accent : tokens.text, weight: 800)),
          ],
        ),
      );
    }

    final rows = _program.rows.where((r) => !r.isEmpty).length;
    return Container(
      decoration: BoxDecoration(color: tokens.canvas, border: Border(top: BorderSide(color: tokens.border))),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          tool(_Tool.select, Icons.near_me_outlined, 'Pilih', 'ladder-tool-select'),
          tool(_Tool.wire, Icons.horizontal_rule, 'Garis horizontal', 'ladder-tool-wire'),
          tool(_Tool.vertical, Icons.vertical_align_bottom, 'Garis vertikal (paralel)', 'ladder-tool-vertical'),
          tool(_Tool.erase, Icons.backspace_outlined, 'Hapus', 'ladder-tool-erase'),
          _divider(tokens),
          _groupLabel(tokens, 'Kontak'),
          for (final letter in _families.keys) family(letter, coil: false),
          _PaletteButton(
            key: const ValueKey('ladder-nc'),
            tip: 'Kontak normally closed',
            active: _nc,
            onTap: _simulating ? null : () => setState(() => _nc = !_nc),
            child: Text('NC', style: uiText(12.5, _nc ? tokens.accent : tokens.text, weight: 800)),
          ),
          _divider(tokens),
          _groupLabel(tokens, 'Koil'),
          for (final letter in _coilKinds.keys) family(letter, coil: true),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: tokens.panel, border: Border.all(color: tokens.border), borderRadius: BorderRadius.circular(Radii.control)),
            child: Text('$rows baris / ${LadderProgram.maxRows}', key: const ValueKey('ladder-row-count'), style: uiText(12.5, tokens.text, weight: 600)),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: BorderRadius.circular(Radii.control)),
            child: Text(_def.name.split(' ').lastWhere((w) => w.startsWith('SR') || w.contains('!'), orElse: () => _def.name),
                style: uiText(12.5, tokens.accent, weight: 700)),
          ),
        ],
      ),
    );
  }

  /// Names a group of palette buttons, so contacts and coils read apart at a glance.
  Widget _groupLabel(Tokens tokens, String text) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Text(text, style: plateText(14, tokens.textMuted, weight: 700)),
      );

  Widget _divider(Tokens tokens) => Container(width: 1, height: 26, margin: const EdgeInsets.symmetric(horizontal: 8), color: tokens.border);

  /// The open palette list: one row per item, with its symbol name; coils show their kinds side by side.
  Widget _list(Tokens tokens) {
    final id = _openList!;
    final coil = id.startsWith('c');
    final letter = coil ? id.substring(1) : id;
    final names = _families[letter]!;
    final kinds = coil ? _coilKinds[letter]! : const <String>[];
    return Container(
      height: 210,
      decoration: BoxDecoration(color: tokens.canvas, border: Border(top: BorderSide(color: tokens.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 4),
            child: Row(
              children: [
                Icon(_familyIcons[letter], size: 16, color: tokens.textMuted),
                const SizedBox(width: 6),
                Text('${coil ? 'Koil' : 'Kontak'} ${_familyNames[letter]}', style: uiText(13, tokens.text, weight: 700)),
                const SizedBox(width: 10),
                Text('Seret ke sel, atau klik lalu klik sel', style: uiText(12, tokens.textMuted)),
                const Spacer(),
                IconButton(iconSize: 18, onPressed: () => setState(() => _openList = null), icon: const Icon(Icons.close)),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: coil ? 230 : 190, mainAxisExtent: 34, crossAxisSpacing: 6, mainAxisSpacing: 4),
              itemCount: names.length,
              itemBuilder: (context, i) {
                final name = names[i];
                final symbol = _program.symbols[name];
                if (!coil) {
                  final armed = _tool == _Tool.contact && _ref == name;
                  return _DragItem(
                    key: ValueKey('item-$name'),
                    data: _Drop.contact(name),
                    label: name,
                    onTap: () => setState(() {
                      _ref = name;
                      _tool = _Tool.contact;
                    }),
                    child: _itemRow(tokens, armed, [
                      Text(name, style: uiText(13, armed ? tokens.accent : tokens.text, weight: 700)),
                      if (symbol != null) ...[const SizedBox(width: 8), Flexible(child: Text(symbol, overflow: TextOverflow.ellipsis, style: uiText(12, tokens.textMuted)))],
                    ]),
                  );
                }
                return _itemRow(tokens, false, [
                  SizedBox(width: 38, child: Text(name, style: uiText(13, tokens.text, weight: 700))),
                  for (final fn in kinds)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _DragItem(
                        key: ValueKey('coil-$fn$name'),
                        data: _Drop.coil(LadderCoil(fn, name)),
                        label: '$fn$name',
                        onTap: () => setState(() {
                          _coilFn = fn;
                          _ref = name;
                          _tool = _Tool.coil;
                        }),
                        child: Tooltip(
                          message: LadderCoil.labels[fn] ?? fn,
                          child: Container(
                            width: 30,
                            height: 26,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _tool == _Tool.coil && _ref == name && _coilFn == fn ? tokens.accentSoft : tokens.panel,
                              border: Border.all(color: tokens.border),
                              borderRadius: BorderRadius.circular(Radii.control),
                            ),
                            child: Text(fn, style: uiText(12.5, tokens.text, weight: 800)),
                          ),
                        ),
                      ),
                    ),
                  if (symbol != null) Flexible(child: Text(symbol, overflow: TextOverflow.ellipsis, style: uiText(11.5, tokens.textMuted))),
                ]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemRow(Tokens tokens, bool armed, List<Widget> children) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: armed ? tokens.accentSoft : tokens.panel,
          border: Border.all(color: armed ? tokens.accent : tokens.border),
          borderRadius: BorderRadius.circular(Radii.control),
        ),
        child: Row(children: children),
      );

  // ----- Grid

  static const double _rowHeight = 62;
  static const double _numberWidth = 46;
  static const double _commentWidth = 200;

  Widget _grid(Tokens tokens) {
    final used = _program.rows.length;
    final count = (used + 6).clamp(14, LadderProgram.maxRows);
    final bits = _bits;
    return LayoutBuilder(builder: (context, box) {
      final cellWidth = ((box.maxWidth - _numberWidth - _commentWidth) / (LadderProgram.columns + 1)).clamp(84.0, 220.0);
      Widget headerCell(String text, double width, {bool coil = false}) => Container(
            width: width,
            height: 28,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
              color: coil ? tokens.accentSoft : tokens.canvas,
              border: Border(right: BorderSide(color: tokens.border), bottom: BorderSide(color: tokens.border)),
            ),
            child: Text(text, style: uiText(12, coil ? tokens.accent : tokens.textMuted, weight: 650)),
          );
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: _numberWidth + cellWidth * (LadderProgram.columns + 1) + _commentWidth,
          child: Column(
            children: [
              Row(children: [
                headerCell('No', _numberWidth),
                for (var c = 1; c <= LadderProgram.columns; c++) headerCell('Kontak $c', cellWidth),
                headerCell('Koil', cellWidth, coil: true),
                headerCell('Komentar', _commentWidth),
              ]),
              Expanded(
                child: ListView.builder(
                  itemCount: count,
                  itemExtent: _rowHeight,
                  itemBuilder: (context, r) => _rowView(tokens, r, cellWidth, bits),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _rowView(Tokens tokens, int r, double cellWidth, Set<String> bits) {
    final row = r < _program.rows.length ? _program.rows[r] : null;
    final above = r > 0 && r - 1 < _program.rows.length ? _program.rows[r - 1] : null;
    return Row(
      children: [
        GestureDetector(
          onSecondaryTapDown: (d) => _rowMenu(d.globalPosition, r),
          child: Container(
            width: _numberWidth,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tokens.canvas,
              border: Border(right: BorderSide(color: tokens.border), bottom: BorderSide(color: tokens.border.withValues(alpha: 0.6))),
            ),
            child: Text((r + 1).toString().padLeft(3, '0'), style: uiText(12, tokens.textMuted, weight: 600)),
          ),
        ),
        for (var c = 0; c <= LadderProgram.columns; c++) _cellView(tokens, r, c, cellWidth, row, above, bits),
        Container(
          width: _commentWidth,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tokens.border.withValues(alpha: 0.6)))),
          child: Text(row?.comment ?? '', overflow: TextOverflow.ellipsis, style: uiText(12, tokens.textMuted)),
        ),
      ],
    );
  }

  Widget _cellView(Tokens tokens, int r, int c, double width, LadderRow? row, LadderRow? above, Set<String> bits) {
    final coilColumn = c == LadderProgram.columns;
    final cell = coilColumn ? null : (row?.cells[c] ?? const LadderCell.empty());
    final coil = coilColumn ? row?.coil : null;
    final up = !coilColumn && (above?.cells[c].down ?? false);
    final selected = _selected == (r, c);
    final contactLive = cell?.ref != null && bits.contains(cell!.ref!) != cell.nc;
    final coilLive = coil != null && bits.contains(coil.ref) && coil.fn != 'R' && coil.fn != 'D';
    final live = _live && (contactLive || coilLive);
    return DragTarget<_Drop>(
      onWillAcceptWithDetails: (d) => !_simulating && (d.data.coil != null) == coilColumn,
      onAcceptWithDetails: (d) => d.data.coil != null ? _placeCoil(r, d.data.coil!) : _placeContact(r, c, d.data.ref!, _nc),
      builder: (context, candidates, _) => GestureDetector(
        key: ValueKey('ladder-cell-$r-$c'),
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _tapCell(r, c, edge: !coilColumn && d.localPosition.dx > width - 12),
        onSecondaryTapDown: (d) => _cellMenu(d.globalPosition, r, c),
        child: Container(
          width: width,
          decoration: BoxDecoration(
            color: candidates.isNotEmpty ? tokens.accent.withValues(alpha: 0.18) : (selected ? tokens.warning.withValues(alpha: 0.28) : null),
            border: Border(
              right: BorderSide(color: tokens.border.withValues(alpha: coilColumn ? 1 : 0.35)),
              bottom: BorderSide(color: tokens.border.withValues(alpha: 0.6)),
            ),
          ),
          child: CustomPaint(
            size: Size(width, _rowHeight),
            painter: _CellPainter(
              cell: cell,
              coil: coil,
              up: up,
              symbol: cell?.ref != null ? _program.symbols[cell!.ref!] : (coil != null ? _program.symbols[coil.ref] : null),
              color: tokens.text,
              muted: tokens.textMuted,
              live: live ? tokens.run : null,
              guide: tokens.border,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _cellMenu(Offset at, int r, int c) async {
    if (_simulating) return;
    final row = _row(r);
    final coilColumn = c == LadderProgram.columns;
    final cell = coilColumn ? null : row.cells[c];
    setState(() => _selected = (r, c));
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        if (cell?.ref != null) ...[
          CheckedPopupMenuItem(value: 'no', checked: !cell!.nc, child: const Text('Normally open')),
          CheckedPopupMenuItem(value: 'nc', checked: cell.nc, child: const Text('Normally closed')),
          const PopupMenuDivider(),
        ],
        if (!coilColumn) CheckedPopupMenuItem(value: 'down', checked: cell!.down, child: const Text('Garis vertikal ke bawah')),
        const PopupMenuItem(value: 'clear', child: Text('Hapus')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'insert', child: Text('Sisipkan baris di atas')),
        const PopupMenuItem(value: 'delete-row', child: Text('Hapus baris')),
      ],
    );
    if (!mounted || choice == null || _simulating || r >= _program.rows.length) return;
    switch (choice) {
      case 'no' || 'nc':
        _change(() => row.cells[c] = LadderCell.contact(cell!.ref!, nc: choice == 'nc', down: cell.down));
      case 'down':
        _change(() => row.cells[c] = cell!.withDown(!cell.down));
      case 'clear':
        _deleteSelected();
      case 'insert':
        _insertRow(r);
      case 'delete-row':
        _deleteRow(r);
    }
  }

  Future<void> _rowMenu(Offset at, int r) async {
    if (_simulating) return;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: const [
        PopupMenuItem(value: 'insert', child: Text('Sisipkan baris di atas')),
        PopupMenuItem(value: 'delete-row', child: Text('Hapus baris')),
      ],
    );
    if (!mounted || choice == null || _simulating) return;
    if (choice == 'insert') _insertRow(r);
    if (choice == 'delete-row') _deleteRow(r);
  }

  // ----- Side panel

  Widget _properties(Tokens tokens) {
    final sel = _selected;
    final children = <Widget>[];
    Widget label(String text) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(text, style: uiText(12, tokens.textMuted, weight: 600)));
    if (sel == null || sel.$1 >= _program.rows.length) {
      children.addAll([
        Text('Properti', style: uiText(15, tokens.text, weight: 700)),
        const SizedBox(height: 8),
        Text(
          'Klik tombol I, Q, M, T, C atau H di bawah, lalu seret elemennya ke sel. Klik sel kosong untuk garis, tepi kanan sel untuk '
          'garis vertikal, klik kanan untuk NO/NC dan baris.${_standalone ? ' Tekan Simulasi untuk mencoba program.' : ' Program berlaku setelah Kirim ke PLC.'}',
          style: uiText(12.5, tokens.textMuted, height: 1.45),
        ),
        label('Ringkasan'),
        Text('${_program.rows.where((r) => !r.isEmpty).length} baris, ${_program.used('T').length} timer, ${_program.used('C').length} counter',
            style: uiText(13, tokens.text)),
      ]);
    } else {
      final (r, c) = sel;
      final row = _program.rows[r];
      final ref = c == LadderProgram.columns ? row.coil?.ref : row.cells[c].ref;
      children.add(Text('Baris ${r + 1}, ${c == LadderProgram.columns ? 'koil' : 'kontak ${c + 1}'}', style: uiText(15, tokens.text, weight: 700)));
      if (ref != null) {
        children.addAll([
          const SizedBox(height: 6),
          Text(c == LadderProgram.columns ? '${row.coil!.fn}$ref · ${LadderCoil.labels[row.coil!.fn]}' : '${row.cells[c].nc ? 'NC ' : ''}$ref',
              style: uiText(13, tokens.text)),
          label('Nama (simbol)'),
          _TextBox(
            key: ValueKey('symbol-$ref'),
            text: _program.symbols[ref] ?? '',
            hint: 'misalnya Start',
            onChanged: (v) => _change(() => v.trim().isEmpty ? _program.symbols.remove(ref) : _program.symbols[ref] = v.trim()),
          ),
        ]);
        if (ref.startsWith('T')) children.addAll(_timerFields(tokens, ref, label));
        if (ref.startsWith('C')) children.addAll(_counterFields(tokens, ref, label));
        if (ref.startsWith('H')) children.addAll(_clockFields(tokens, ref, label));
      }
      children.addAll([
        label('Komentar baris'),
        _TextBox(key: ObjectKey(row), text: row.comment, hint: 'Keterangan baris', onChanged: (v) => _change(() => row.comment = v)),
      ]);
    }
    return ListView(padding: const EdgeInsets.all(16), children: children);
  }

  double? _timerElapsed(String ref) => _standalone
      ? (_simulating ? ladderTimerElapsed(_simMemory.timers[ref], _clock.elapsedMilliseconds / 1000) : null)
      : (app.running ? app.plcTimerElapsed(widget.plc!, ref) : null);

  bool _timerOut(String ref) => _standalone ? (_simMemory.timers[ref]?.out ?? false) : app.plcTimerDone(widget.plc!, ref);

  int _count(String ref) => _standalone ? (_simMemory.counts[ref] ?? 0) : app.plcCount(widget.plc!, ref);

  List<Widget> _timerFields(Tokens tokens, String ref, Widget Function(String) label) {
    final timer = _program.timer(ref);
    final elapsed = _timerElapsed(ref);
    return [
      label('Fungsi timer'),
      DropdownButton<String>(
        key: ValueKey('timer-fn-$ref'),
        isExpanded: true,
        value: timer.function,
        items: [
          for (final e in LadderTimer.functions.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value, style: uiText(12.5, tokens.text), overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) => _change(() => timer.function = v ?? 'A'),
      ),
      label(timer.hasSecond ? 'Waktu 1 (detik)' : 'Waktu (detik)'),
      _NumberBox(key: ValueKey('timer-t-$ref'), value: timer.preset, onChanged: (v) => _change(() => timer.preset = v.clamp(0.1, 9999))),
      if (timer.hasSecond) ...[
        label('Waktu 2 (detik)'),
        _NumberBox(key: ValueKey('timer-t2-$ref'), value: timer.preset2, onChanged: (v) => _change(() => timer.preset2 = v.clamp(0.1, 9999))),
      ],
      if (elapsed != null) ...[
        label('Monitor'),
        Text('${elapsed.toStringAsFixed(1)} dtk${_timerOut(ref) ? ' · keluaran ON' : ''}', style: uiText(13, tokens.run, weight: 600)),
      ],
    ];
  }

  List<Widget> _counterFields(Tokens tokens, String ref, Widget Function(String) label) {
    final counter = _program.counter(ref);
    return [
      label('Nilai target (pulsa)'),
      _NumberBox(
        key: ValueKey('counter-p-$ref'),
        value: counter.preset.toDouble(),
        decimals: false,
        onChanged: (v) => _change(() => counter.preset = v.round().clamp(0, 32767)),
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: counter.toZero,
        onChanged: (v) => _change(() => counter.toZero = v ?? false),
        title: Text('Keluaran ON saat nilai mencapai 0', style: uiText(12.5, tokens.text)),
      ),
      if (_live) Text('Nilai sekarang: ${_count(ref)}', style: uiText(13, tokens.run, weight: 600)),
    ];
  }

  /// The PLC's clock while it runs: the canvas PLC's own (with its Set Clock offset), or this computer's.
  DateTime get _plcNow => _standalone ? DateTime.now() : app.plcClockOf(widget.plc!);

  bool _clockOn(String ref) => _standalone ? _simBits.contains(ref) : app.bitsOf(widget.plc!).contains(ref);

  List<Widget> _clockFields(Tokens tokens, String ref, Widget Function(String) label) {
    final clock = _program.clock(ref);
    const dayNames = ['Sen', 'Sel', 'Rab', 'Kam', 'Jum', 'Sab', 'Min'];
    return [
      Text('Kontak $ref menyala saat jam PLC berada di salah satu jadwal di bawah.', style: uiText(12, tokens.textMuted, height: 1.4)),
      for (var i = 0; i < clock.slots.length; i++) ...[
        label('Jadwal ${i + 1}'),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (var d = 1; d <= 7; d++)
              FilterChip(
                key: ValueKey('clock-$ref-$i-day-$d'),
                label: Text(dayNames[d - 1], style: uiText(11.5, tokens.text)),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: EdgeInsets.zero,
                selected: clock.slots[i].days.contains(d),
                onSelected: (on) => _change(() => on ? clock.slots[i].days.add(d) : clock.slots[i].days.remove(d)),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text('ON', style: uiText(12, tokens.textMuted, weight: 600)),
            const SizedBox(width: 6),
            Expanded(child: _TimeBox(key: ValueKey('clock-$ref-$i-on'), minute: clock.slots[i].on, onChanged: (m) => _change(() => clock.slots[i].on = m))),
            const SizedBox(width: 10),
            Text('OFF', style: uiText(12, tokens.textMuted, weight: 600)),
            const SizedBox(width: 6),
            Expanded(child: _TimeBox(key: ValueKey('clock-$ref-$i-off'), minute: clock.slots[i].off, onChanged: (m) => _change(() => clock.slots[i].off = m))),
            if (clock.slots.length > 1)
              IconButton(
                tooltip: 'Hapus jadwal',
                visualDensity: VisualDensity.compact,
                onPressed: () => _change(() => clock.slots.removeAt(i)),
                icon: const Icon(Icons.close, size: 16),
              ),
          ],
        ),
      ],
      if (clock.slots.length < LadderClock.maxSlots)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('clock-$ref-add'),
            onPressed: () => _change(() => clock.slots.add(ClockSlot())),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Tambah jadwal'),
          ),
        ),
      if (_live) ...[
        label('Monitor'),
        Text('${kPlcDays[_plcNow.weekday - 1]} ${clockText(_plcNow.hour * 60 + _plcNow.minute)} · ${_clockOn(ref) ? 'ON' : 'OFF'}',
            style: uiText(13, _clockOn(ref) ? tokens.run : tokens.text, weight: 600)),
      ],
    ];
  }

  /// While simulating on its own: inputs to switch, arrow keys to hold, outputs, timers and counters.
  Widget _simPanel(Tokens tokens) {
    Widget lamp(String ref, {required bool on, VoidCallback? onTap, String? keyName, void Function(bool)? onHold}) {
      final body = Container(
        key: keyName == null ? null : ValueKey(keyName),
        width: 54,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? tokens.run.withValues(alpha: 0.85) : tokens.canvas,
          border: Border.all(color: on ? tokens.run : tokens.border),
          borderRadius: BorderRadius.circular(Radii.control),
        ),
        child: Text(ref, style: uiText(12.5, on ? Colors.white : tokens.text, weight: 700)),
      );
      if (onHold != null) {
        return Listener(onPointerDown: (_) => onHold(true), onPointerUp: (_) => onHold(false), onPointerCancel: (_) => onHold(false), child: body);
      }
      return onTap == null ? body : InkWell(onTap: onTap, borderRadius: BorderRadius.circular(Radii.control), child: body);
    }

    Widget title(String text) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 8), child: Text(text, style: uiText(12, tokens.textMuted, weight: 650)));
    final timers = _program.used('T');
    final counters = _program.used('C');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Simulasi', style: uiText(15, tokens.text, weight: 700)),
        const SizedBox(height: 6),
        Text('Klik input untuk menyalakan atau mematikannya. Tahan tombol Z.', style: uiText(12.5, tokens.textMuted, height: 1.4)),
        title('Input'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final ref in _def.plcInputs)
            lamp(ref, on: _simInputs.contains(ref), keyName: 'sim-$ref', onTap: () {
              _simInputs.contains(ref) ? _simInputs.remove(ref) : _simInputs.add(ref);
              _scan();
              setState(() {});
            }),
        ]),
        title('Tombol panah'),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final ref in const ['Z1', 'Z2', 'Z3', 'Z4'])
            lamp(ref, on: _simHeld.contains(ref), keyName: 'sim-$ref', onHold: (down) {
              down ? _simHeld.add(ref) : _simHeld.remove(ref);
              _scan();
              setState(() {});
            }),
        ]),
        title('Output'),
        Wrap(spacing: 6, runSpacing: 6, children: [for (final ref in _def.plcOutputs) lamp(ref, on: _simBits.contains(ref))]),
        if (timers.isNotEmpty) ...[
          title('Timer'),
          for (final ref in timers)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '$ref  ${(_timerElapsed(ref) ?? (_timerOut(ref) ? _program.timer(ref).preset : 0)).clamp(0, _program.timer(ref).preset).toStringAsFixed(1)} / '
                '${_program.timer(ref).preset.toStringAsFixed(1)} dtk${_timerOut(ref) ? '  ON' : ''}',
                style: uiText(13, _timerOut(ref) ? tokens.run : tokens.text, weight: 600),
              ),
            ),
        ],
        if (_program.usedClocks.isNotEmpty) ...[
          title('Jam (${kPlcDays[_plcNow.weekday - 1]} ${clockText(_plcNow.hour * 60 + _plcNow.minute)})'),
          Wrap(spacing: 6, runSpacing: 6, children: [for (final ref in _program.usedClocks) lamp(ref, on: _simBits.contains(ref))]),
        ],
        if (counters.isNotEmpty) ...[
          title('Counter'),
          for (final ref in counters)
            Text('$ref  ${_count(ref)} / ${_program.counter(ref).preset}${_simBits.contains(ref) ? '  ON' : ''}',
                style: uiText(13, _simBits.contains(ref) ? tokens.run : tokens.text, weight: 600)),
        ],
      ],
    );
  }
}

/// What is dragged from the palette: a contact address or a coil.
class _Drop {
  const _Drop.contact(String this.ref) : coil = null;
  const _Drop.coil(LadderCoil this.coil) : ref = null;

  final String? ref;
  final LadderCoil? coil;
}

class _DragItem extends StatelessWidget {
  const _DragItem({super.key, required this.data, required this.label, required this.onTap, required this.child});

  final _Drop data;
  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Draggable<_Drop>(
      data: data,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: tokens.accent, borderRadius: BorderRadius.circular(Radii.control)),
          child: Text(label, style: uiText(13, Colors.white, weight: 700)),
        ),
      ),
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: GestureDetector(onTap: onTap, child: child)),
    );
  }
}

class _PaletteButton extends StatelessWidget {
  const _PaletteButton({super.key, required this.tip, required this.active, required this.onTap, required this.child});

  final String tip;
  final bool active;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: onTap,
          child: Container(
            height: 36,
            constraints: const BoxConstraints(minWidth: 36),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? tokens.accentSoft : tokens.panel,
              border: Border.all(color: active ? tokens.accent : tokens.border),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _TextBox extends StatefulWidget {
  const _TextBox({super.key, required this.text, required this.hint, required this.onChanged});

  final String text;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  State<_TextBox> createState() => _TextBoxState();
}

class _TextBoxState extends State<_TextBox> {
  late final _controller = TextEditingController(text: widget.text);

  @override
  void didUpdateWidget(_TextBox old) {
    super.didUpdateWidget(old);
    if (widget.text != old.text && widget.text != _controller.text) {
      _controller.value = TextEditingValue(text: widget.text, selection: TextSelection.collapsed(offset: widget.text.length));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _controller,
        decoration: InputDecoration(isDense: true, hintText: widget.hint, border: const OutlineInputBorder()),
        style: uiText(13, context.tokens.text),
        onChanged: widget.onChanged,
      );
}

/// A time of day typed as HH:MM, kept as minutes.
class _TimeBox extends StatefulWidget {
  const _TimeBox({super.key, required this.minute, required this.onChanged});

  final int minute;
  final ValueChanged<int> onChanged;

  @override
  State<_TimeBox> createState() => _TimeBoxState();
}

class _TimeBoxState extends State<_TimeBox> {
  late final _controller = TextEditingController(text: clockText(widget.minute));
  bool _bad = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit(String text) {
    final match = RegExp(r'^\s*(\d{1,2})[:.](\d{2})\s*$').firstMatch(text);
    final hour = int.tryParse(match?.group(1) ?? '');
    final minute = int.tryParse(match?.group(2) ?? '');
    final ok = hour != null && minute != null && hour < 24 && minute < 60;
    setState(() => _bad = !ok);
    if (ok) widget.onChanged(hour * 60 + minute);
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _controller,
        style: uiText(13, context.tokens.text),
        decoration: InputDecoration(isDense: true, hintText: 'HH:MM', errorText: _bad ? 'HH:MM' : null),
        onChanged: _commit,
      );
}

class _NumberBox extends StatefulWidget {
  const _NumberBox({super.key, required this.value, required this.onChanged, this.decimals = true});

  final double value;
  final ValueChanged<double> onChanged;
  final bool decimals;

  @override
  State<_NumberBox> createState() => _NumberBoxState();
}

class _NumberBoxState extends State<_NumberBox> {
  late final _controller = TextEditingController(text: widget.decimals ? widget.value.toStringAsFixed(1) : widget.value.round().toString());

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
        style: uiText(13, context.tokens.text),
        onChanged: (text) {
          final v = double.tryParse(text.replaceAll(',', '.'));
          if (v != null) widget.onChanged(v);
        },
      );
}

/// The little contact or coil symbol on the palette buttons.
class _SymbolPainter extends CustomPainter {
  const _SymbolPainter({required this.coil, required this.color});

  final bool coil;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final y = size.height / 2;
    final mid = size.width / 2;
    if (coil) {
      canvas.drawLine(Offset(0, y), Offset(mid - 5, y), paint);
      canvas.drawLine(Offset(mid + 5, y), Offset(size.width, y), paint);
      canvas.drawArc(Rect.fromCircle(center: Offset(mid, y), radius: 5), 1.9, 2.5, false, paint);
      canvas.drawArc(Rect.fromCircle(center: Offset(mid, y), radius: 5), -1.25, 2.5, false, paint);
    } else {
      canvas.drawLine(Offset(0, y), Offset(mid - 3, y), paint);
      canvas.drawLine(Offset(mid + 3, y), Offset(size.width, y), paint);
      canvas.drawLine(Offset(mid - 3, 1), Offset(mid - 3, size.height - 1), paint);
      canvas.drawLine(Offset(mid + 3, 1), Offset(mid + 3, size.height - 1), paint);
    }
  }

  @override
  bool shouldRepaint(_SymbolPainter old) => old.color != color || old.coil != coil;
}

/// One grid cell: a wire, a contact (NO or NC) or a coil, with its vertical links and its live state.
class _CellPainter extends CustomPainter {
  const _CellPainter({
    required this.cell,
    required this.coil,
    required this.up,
    required this.symbol,
    required this.color,
    required this.muted,
    required this.live,
    required this.guide,
  });

  final LadderCell? cell;
  final LadderCoil? coil;
  final bool up;
  final String? symbol;
  final Color color;
  final Color muted;
  final Color? live;
  final Color guide;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height * 0.56;
    final ink = live ?? color;
    final line = Paint()
      ..color = ink
      ..strokeWidth = live != null ? 2.4 : 1.6
      ..style = PaintingStyle.stroke;
    final plain = Paint()
      ..color = color
      ..strokeWidth = 1.6;
    // A faint dashed guide where a wire could go, and on the right edge where a vertical link could go.
    final dots = Paint()
      ..color = guide
      ..strokeWidth = 1;
    for (var x = 4.0; x < size.width - 4; x += 8) {
      canvas.drawLine(Offset(x, y), Offset(x + 3, y), dots);
    }
    final cell = this.cell;
    final coil = this.coil;
    final right = size.width;
    if (cell != null) {
      for (var v = y; v < size.height; v += 7) {
        canvas.drawLine(Offset(right - 0.5, v), Offset(right - 0.5, v + 3), dots);
      }
    }
    if (up) canvas.drawLine(Offset(right, 0), Offset(right, y), plain);
    if (cell != null && cell.down) canvas.drawLine(Offset(right, y), Offset(right, size.height), plain);
    if (cell != null && cell.wire) canvas.drawLine(Offset(0, y), Offset(right, y), line);
    if (cell?.ref == null && coil == null) return;
    final mid = size.width / 2;
    if (coil != null) {
      canvas.drawLine(Offset(0, y), Offset(mid - 9, y), line);
      canvas.drawArc(Rect.fromCircle(center: Offset(mid, y), radius: 9), 1.9, 2.5, false, line);
      canvas.drawArc(Rect.fromCircle(center: Offset(mid, y), radius: 9), -1.25, 2.5, false, line);
      canvas.drawLine(Offset(mid + 9, y), Offset(right, y), line);
    } else {
      canvas.drawLine(Offset(0, y), Offset(mid - 5, y), line);
      canvas.drawLine(Offset(mid - 5, y - 10), Offset(mid - 5, y + 10), line);
      canvas.drawLine(Offset(mid + 5, y - 10), Offset(mid + 5, y + 10), line);
      if (cell!.nc) canvas.drawLine(Offset(mid - 9, y + 10), Offset(mid + 9, y - 10), line);
      canvas.drawLine(Offset(mid + 5, y), Offset(right, y), line);
    }
    // Zelio writes a normally closed contact in lower case (i1).
    final text = coil != null ? coil.text : (cell!.nc ? cell.ref!.toLowerCase() : cell.ref!);
    final tp = TextPainter(
      text: TextSpan(children: [
        TextSpan(text: text, style: uiText(12.5, ink, weight: 700)),
        if (symbol != null) TextSpan(text: '  $symbol', style: uiText(10.5, muted)),
      ]),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: size.width - 8);
    tp.paint(canvas, const Offset(6, 5));
  }

  @override
  bool shouldRepaint(_CellPainter old) =>
      old.cell?.text != cell?.text || old.coil?.text != coil?.text || old.up != up || old.live != live || old.symbol != symbol || old.color != color;
}
