import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../file_io.dart';
import '../model/device_def.dart';
import 'ai_chat_panel.dart';
import 'ai_settings_dialog.dart';
import 'canvas_view.dart';
import 'panels.dart';
import 'scada.dart';
import 'swarm_overlay.dart';
import 'templates_dialog.dart';
import 'theme.dart';

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.app});

  final AppState app;

  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  final FocusNode _focus = FocusNode(debugLabel: 'workspace');
  final GlobalKey _captureKey = GlobalKey();

  AppState get app => widget.app;

  @override
  void dispose() {
    WireCache.clear();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final text = await pickProjectText();
      if (text == null || !mounted) return;
      final error = app.importJson(text);
      if (error != null) app.reportStatus(error, StatusKind.error);
    } on FormatException catch (error) {
      if (mounted) app.reportStatus(error.message, StatusKind.error);
    } catch (_) {
      if (mounted) app.reportStatus('Gagal membuka file proyek. Coba lagi atau pilih file lain.', StatusKind.error);
    }
  }

  Future<void> _attempt(Future<bool> Function() action, String done) async {
    try {
      if (await action()) app.reportStatus(done, StatusKind.info);
    } catch (_) {
      app.reportStatus('Gagal menyimpan. Coba lagi atau pilih folder lain.', StatusKind.error);
    }
  }

  Future<void> _save() => _attempt(() => saveProjectText(app.project.name, app.exportJson()), 'Proyek disimpan.');

  Future<void> _exportCsv() => _attempt(() => saveCsv(app.project.name, app.exportBomCsv()), 'Daftar material diekspor.');

  Future<void> _exportPng() async {
    // Wires come from the vectors for the export, not the screen-resolution cache.
    WireCache.bypass = true;
    app.fitView();
    await WidgetsBinding.instance.endOfFrame;
    final boundary = _captureKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      WireCache.bypass = false;
      return;
    }
    await _attempt(() async {
      try {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return await savePng(app.project.name, data!.buffer.asUint8List());
      } finally {
        WireCache.bypass = false;
        app.aiChanged();
      }
    }, 'Gambar rangkaian diekspor.');
  }

  void _showMaterials() {
    final tokens = context.tokens;
    final groups = <String, List<String>>{};
    for (final device in app.project.devices) {
      groups.putIfAbsent(app.defOf(device).name, () => []).add(device.tag);
    }
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: tokens.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
        title: Text('Daftar material', style: uiText(17, tokens.text, weight: 700)),
        content: SizedBox(
          width: 520,
          height: 420,
          child: ListView(
            children: [
              if (groups.isEmpty) Text('Belum ada perangkat.', style: uiText(13, tokens.textMuted)),
              for (final entry in groups.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 9),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 34, child: Text('${entry.value.length}x', style: uiText(13, tokens.text, weight: 600))),
                      Expanded(child: Text(entry.key, style: uiText(13, tokens.text))),
                      const SizedBox(width: 12),
                      SizedBox(width: 150, child: Text(entry.value.join(', '), textAlign: TextAlign.right, style: uiText(12, tokens.textMuted))),
                    ],
                  ),
                ),
              if (app.project.wires.isNotEmpty) ...[
                const SizedBox(height: 6),
                const SectionLabel('Sambungan'),
                for (final row in app.wireSummary())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Text('${row.count}x ${row.isJumper ? 'jumper' : 'kabel'} ${row.gauge} mm²', style: uiText(13, tokens.text)),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _exportCsv();
            },
            child: const Text('Ekspor CSV'),
          ),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Tutup')),
        ],
      ),
    );
  }

  /// Shortcuts that never clash with typing, so they work even inside a text field.
  static final Set<LogicalKeyboardKey> _globalKeys = {LogicalKeyboardKey.f5, LogicalKeyboardKey.keyS, LogicalKeyboardKey.keyO, LogicalKeyboardKey.keyI};

  /// True while a text field has the keyboard: letters, Delete, Ctrl+C/V/A/Z and the rest belong to it then.
  static bool get _typing {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null && (context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  /// Runs a workspace shortcut, unless the key belongs to a text field being typed in.
  KeyEventResult _shortcut(KeyEvent event, Map<SingleActivator, VoidCallback> bindings) {
    // While the assistant works the user only watches.
    if (event is KeyUpEvent || app.aiLocked) return KeyEventResult.ignored;
    for (final entry in bindings.entries) {
      if (!entry.key.accepts(event, HardwareKeyboard.instance)) continue;
      if (_typing && !_globalKeys.contains(entry.key.trigger)) return KeyEventResult.ignored;
      entry.value();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _toggleModeKey(bool jumper) {
    if (!app.running) app.setJumperMode(jumper);
  }

  @override
  Widget build(BuildContext context) {
    Widget lock(Widget child) => ExcludeFocus(excluding: app.aiLocked, child: AbsorbPointer(absorbing: app.aiLocked, child: child));
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) => _shortcut(event, {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): app.undo,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): app.redo,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): app.redo,
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): app.selectAll,
        const SingleActivator(LogicalKeyboardKey.keyC, control: true): app.copySelection,
        const SingleActivator(LogicalKeyboardKey.keyV, control: true): app.paste,
        const SingleActivator(LogicalKeyboardKey.keyD, control: true): app.duplicateSelection,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): _open,
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () => app.zoomStep(1.2),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () => app.zoomStep(1 / 1.2),
        const SingleActivator(LogicalKeyboardKey.digit0, control: true): app.fitView,
        const SingleActivator(LogicalKeyboardKey.delete): app.deleteSelection,
        const SingleActivator(LogicalKeyboardKey.escape): app.clearSelection,
        const SingleActivator(LogicalKeyboardKey.f5): app.toggleSimulation,
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): app.toggleAiPanel,
        const SingleActivator(LogicalKeyboardKey.keyJ): () => _toggleModeKey(true),
        const SingleActivator(LogicalKeyboardKey.keyK): () => _toggleModeKey(false),
      }),
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: [
              lock(
                _Toolbar(
                  app: app,
                  onOpen: _open,
                  onSave: _save,
                  onMaterials: _showMaterials,
                  onExportPng: _exportPng,
                  onExportCsv: _exportCsv,
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    children: [
                  Row(
                    children: [
                      // While the assistant works, everything but its chat panel only shows.
                      lock(LibraryPanel(app: app)),
                      Expanded(child: lock(CanvasView(app: app, focusNode: _focus, captureKey: _captureKey))),
                      // With the assistant open, the properties panel stays only when there is room for both.
                      if (constraints.maxWidth >= 900 && (!app.aiPanelOpen || constraints.maxWidth >= 1700))
                        lock(PropertiesPanel(app: app)),
                      if (app.aiPanelOpen) AiChatPanel(app: app),
                    ],
                  ),
                  // The assistant's team works above the library and the canvas, on its own layer.
                  Positioned.fill(child: RepaintBoundary(child: SwarmOverlay(app: app, canvasKey: _captureKey))),
                    ],
                  ),
                ),
              ),
              _StatusBar(app: app),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.tooltip, required this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 19,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      padding: EdgeInsets.zero,
      color: tokens.text,
      disabledColor: tokens.textMuted.withValues(alpha: 0.4),
      hoverColor: tokens.hover,
      style: IconButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.control))),
      icon: Icon(icon),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 8), color: context.tokens.border);
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    Widget option(String label, String tip, bool jumper, Key key) {
      final active = app.jumperMode == jumper;
      return Tooltip(
        message: tip,
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: app.running ? null : () => app.setJumperMode(jumper),
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(color: active ? tokens.plate : Colors.transparent, borderRadius: BorderRadius.circular(Radii.plate)),
            child: Text(label, style: uiText(12, active ? tokens.onPlate : tokens.textMuted, weight: 600)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(border: Border.all(color: tokens.border), borderRadius: BorderRadius.circular(Radii.control)),
      child: Row(
        children: [
          option('Kabel', 'Sambung dengan kabel (K)', false, const ValueKey('mode-wire')),
          option('Jumper', 'Sambung dengan jumper (J)', true, const ValueKey('mode-jumper')),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.app, required this.onOpen, required this.onSave, required this.onMaterials, required this.onExportPng, required this.onExportCsv});

  final AppState app;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onMaterials;
  final VoidCallback onExportPng;
  final VoidCallback onExportCsv;

  Widget _menu(BuildContext context) {
    final tokens = context.tokens;
    final editing = !app.running;
    Widget item(String label, VoidCallback? onPressed, {String? shortcut, Key? key}) => MenuItemButton(
          key: key,
          onPressed: onPressed,
          trailingIcon: shortcut == null ? null : Text(shortcut, style: uiText(11, tokens.textMuted)),
          child: Text(label, style: uiText(13, tokens.text)),
        );
    Widget menu(String label, List<Widget> children) => SubmenuButton(
          menuChildren: children,
          style: MenuItemButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 9)),
          child: Text(label, style: uiText(13, tokens.text, weight: 500)),
        );
    final groups = <String, List<DeviceDef>>{};
    for (final def in app.defs.values.where((d) => !d.isSymbol && !d.isJunction)) {
      groups.putIfAbsent(groupOf(def), () => []).add(def);
    }
    return MenuBar(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(tokens.panel),
        elevation: const WidgetStatePropertyAll(0),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      children: [
        menu('File', [
          item('Proyek baru atau rangkaian jadi', editing ? () => showTemplatesDialog(context, app) : null),
          item('Buka', editing ? onOpen : null, shortcut: 'Ctrl+O'),
          item('Simpan', onSave, shortcut: 'Ctrl+S'),
          item('Ekspor gambar PNG', app.project.isEmpty ? null : onExportPng),
        ]),
        menu('Edit', [
          item('Urungkan', app.canUndo ? app.undo : null, shortcut: 'Ctrl+Z'),
          item('Ulangi', app.canRedo ? app.redo : null, shortcut: 'Ctrl+Y'),
          item('Salin', editing ? app.copySelection : null, shortcut: 'Ctrl+C'),
          item('Tempel', editing ? app.paste : null, shortcut: 'Ctrl+V'),
          item('Duplikat', editing ? app.duplicateSelection : null, shortcut: 'Ctrl+D'),
          item('Hapus', editing ? app.deleteSelection : null, shortcut: 'Del'),
          item('Pilih semua', editing ? app.selectAll : null, shortcut: 'Ctrl+A'),
        ]),
        menu('Tampilan', [
          item('Perbesar', () => app.zoomStep(1.2), shortcut: 'Ctrl+='),
          item('Perkecil', () => app.zoomStep(1 / 1.2), shortcut: 'Ctrl+-'),
          item('Muat semua', app.fitView, shortcut: 'Ctrl+0'),
          item(app.wireNumbersOn ? 'Sembunyikan nomor kabel' : 'Tampilkan nomor kabel', app.toggleWireNumbers, key: const ValueKey('toggle-wire-numbers')),
          item(app.dark ? 'Tema terang' : 'Tema gelap', app.toggleTheme),
          item(app.soundOn ? 'Matikan suara' : 'Nyalakan suara', app.toggleSound),
        ]),
        menu('Sisipkan', [
          for (final key in [...kGroupOrder, ...groups.keys.where((k) => !kGroupOrder.contains(k))])
            if (groups.containsKey(key))
              SubmenuButton(
                menuChildren: [for (final def in groups[key]!..sort((a, b) => naturalCompare(a.name, b.name))) item(def.name, editing ? () => app.addDevice(def.id) : null)],
                child: Text(key, style: uiText(13, tokens.text)),
              ),
        ]),
        menu('AI', [
          item(app.aiPanelOpen ? 'Tutup asisten' : 'Buka asisten', app.toggleAiPanel, shortcut: 'Ctrl+I', key: const ValueKey('open-ai-panel')),
          item(app.aiSettings == null ? 'Atur AI…' : 'Pengaturan AI…', () => showAiSettings(context, app), key: const ValueKey('open-ai-settings')),
        ]),
        menu('Alat', [
          item('Buka SCADA', () => showScada(context, app), key: const ValueKey('open-scada')),
          item('Rapikan semua kabel', editing ? app.resetAllRoutes : null),
          item('Tata letak otomatis', editing && app.project.devices.length > 1 ? app.autoArrange : null, key: const ValueKey('auto-arrange')),
        ]),
        menu('Output', [
          item('Daftar material', onMaterials),
          item('Ekspor CSV material', onExportCsv),
          item('Ekspor gambar PNG', app.project.isEmpty ? null : onExportPng),
        ]),
        menu('Bantuan', [
          item('Tentang', () => _showAbout(context)),
        ]),
      ],
    );
  }

  Widget _segment(BuildContext context, List<(String, IconData, bool, VoidCallback?)> options) {
    final tokens = context.tokens;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(border: Border.all(color: tokens.border), borderRadius: BorderRadius.circular(Radii.control)),
      child: Row(
        children: [
          for (final (label, icon, active, onTap) in options)
            InkWell(
              key: ValueKey('segment-$label'),
              borderRadius: BorderRadius.circular(Radii.control),
              onTap: onTap,
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 9),
                // The active position is a dark steel plate, like the marked position of a selector switch.
                decoration: BoxDecoration(color: active ? tokens.plate : Colors.transparent, borderRadius: BorderRadius.circular(Radii.plate)),
                child: Row(
                  children: [
                    Icon(icon, size: 15, color: active ? tokens.onPlate : tokens.textMuted),
                    const SizedBox(width: 5),
                    Text(label, style: uiText(12, active ? tokens.onPlate : tokens.textMuted, weight: 600)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: tokens.panel, border: Border(bottom: BorderSide(color: tokens.border))),
      child: Row(
        children: [
          Tooltip(
            message: 'Kembali ke beranda',
            child: InkWell(
              key: const ValueKey('home-button'),
              borderRadius: BorderRadius.circular(Radii.control),
              onTap: app.openHome,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(Radii.plate),
                      child: Image.asset('assets/brand/logo.png', width: 28, height: 28, filterQuality: FilterQuality.medium),
                    ),
                    const SizedBox(width: 8),
                    const Nameplate('BuildWire', size: 15),
                  ],
                ),
              ),
            ),
          ),
          const _Divider(),
          // The tools scroll in a narrow window so the Run button always stays visible.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  SizedBox(width: 170, child: _ProjectName(key: ValueKey(app.project.name), app: app)),
                  const _Divider(),
                  _menu(context),
                  const _Divider(),
                  _segment(context, [
                    ('Pilih', Icons.near_me_outlined, app.tool == CanvasTool.select, () => app.setTool(CanvasTool.select)),
                    ('Geser', Icons.pan_tool_outlined, app.tool == CanvasTool.pan, () => app.setTool(CanvasTool.pan)),
                  ]),
                  const SizedBox(width: 8),
                  _ModeSwitch(app: app),
                  const _Divider(),
                  _ToolButton(icon: Icons.undo, tooltip: 'Urungkan (Ctrl+Z)', onPressed: app.canUndo ? app.undo : null),
                  _ToolButton(icon: Icons.redo, tooltip: 'Ulangi (Ctrl+Y)', onPressed: app.canRedo ? app.redo : null),
                  _ToolButton(icon: Icons.monitor_heart_outlined, tooltip: 'SCADA', onPressed: () => showScada(context, app)),
                  _ToolButton(
                    icon: app.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                    tooltip: app.dark ? 'Tema terang' : 'Tema gelap',
                    onPressed: app.toggleTheme,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            height: 34,
            child: OutlinedButton.icon(
              key: const ValueKey('ai-button'),
              onPressed: app.toggleAiPanel,
              style: OutlinedButton.styleFrom(
                backgroundColor: app.aiPanelOpen ? tokens.hover : null,
                side: BorderSide(color: app.aiPanelOpen ? tokens.text : tokens.border),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              icon: const Icon(Icons.forum_outlined, size: 16),
              label: const Text('Asisten AI', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 34,
            child: FilledButton.icon(
              key: const ValueKey('run-button'),
              onPressed: app.project.isEmpty ? null : app.toggleSimulation,
              // The one hazard-yellow action on this screen; red while running, because then it stops the circuit.
              style: FilledButton.styleFrom(
                backgroundColor: app.running ? tokens.error : null,
                foregroundColor: app.running ? (app.dark ? tokens.onHazard : Colors.white) : null,
                iconColor: app.running ? (app.dark ? tokens.onHazard : Colors.white) : null,
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              icon: Icon(app.running ? Icons.stop : Icons.play_arrow, size: 18),
              label: Text(app.running ? 'Hentikan' : 'Jalankan', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }

  void _showAbout(BuildContext context) {
    final tokens = context.tokens;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: tokens.panel,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
        title: Row(
          children: [
            Image.asset('assets/brand/logo.png', width: 48, height: 48, filterQuality: FilterQuality.medium),
            const SizedBox(width: 10),
            const Nameplate('BuildWire', size: 18),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Versi 1.3', style: uiText(13, tokens.textMuted)),
              const SizedBox(height: 14),
              Text(
                'Simulator menghitung tegangan, arus, dan daya pada kondisi tunak dengan beban impedansi tetap. Jatuh tegangan, '
                'jalur paralel, dan beban seri belum dihitung, dan spesifikasi perangkat adalah data contoh. Untuk belajar dan '
                'latihan, bukan untuk merancang instalasi sungguhan.',
                style: uiText(13, tokens.text, height: 1.45),
              ),
              const SizedBox(height: 14),
              Text(
                'Simbol skematik dari koleksi QElectroTech elements (github.com/qelectrotech/qelectrotech-elements), '
                'lisensi CC-BY 3.0 (creativecommons.org/licenses/by/3.0), dikonversi ke SVG untuk aplikasi ini.',
                style: uiText(13, tokens.text, height: 1.45),
              ),
              const SizedBox(height: 10),
              Text('Font Inter dan Barlow Condensed berlisensi SIL Open Font License 1.1.', style: uiText(13, tokens.text, height: 1.45)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => showLicensePage(context: context, applicationName: 'BuildWire', applicationVersion: '1.0'),
            child: const Text('Lisensi'),
          ),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Tutup')),
        ],
      ),
    );
  }
}

class _ProjectName extends StatefulWidget {
  const _ProjectName({super.key, required this.app});

  final AppState app;

  @override
  State<_ProjectName> createState() => _ProjectNameState();
}

class _ProjectNameState extends State<_ProjectName> {
  late final TextEditingController _controller = TextEditingController(text: widget.app.project.name);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) {
        if (widget.app.running) {
          _controller.text = widget.app.project.name;
        } else {
          widget.app.renameProject(_controller.text);
        }
      }
    });
  }

  @override
  void didUpdateWidget(_ProjectName old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _controller.text != widget.app.project.name) {
      _controller.text = widget.app.project.name;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return TextField(
      controller: _controller,
      focusNode: _focus,
      enabled: !widget.app.running,
      style: uiText(13, tokens.text, weight: 500),
      decoration: InputDecoration(
        hintText: 'Nama proyek',
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        hintStyle: uiText(13, tokens.textMuted),
      ),
      onSubmitted: widget.app.renameProject,
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = switch (app.statusKind) {
      StatusKind.info => tokens.textMuted,
      StatusKind.running => tokens.run,
      StatusKind.warning => tokens.warning,
      StatusKind.error => tokens.error,
    };
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: tokens.panel, border: Border(top: BorderSide(color: tokens.border))),
      child: Row(
        children: [
          if (app.statusKind != StatusKind.info) ...[
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              app.status,
              key: const ValueKey('status-text'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: uiText(12, app.statusKind == StatusKind.info ? tokens.textMuted : color, weight: 500),
            ),
          ),
          // Follows the canvas too, so the counts climb while the assistant builds.
          ValueListenableBuilder<int>(
            valueListenable: app.viewVersion,
            builder: (context, _, _) =>
                Text('${app.project.devices.where((d) => !app.defOf(d).isJunction).length} perangkat, ${app.project.wires.length} sambungan', style: uiText(12, tokens.textMuted)),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 22,
            child: IconButton(iconSize: 15, padding: EdgeInsets.zero, tooltip: 'Perkecil', onPressed: () => app.zoomStep(1 / 1.2), icon: Icon(Icons.remove, color: tokens.textMuted)),
          ),
          SizedBox(
            width: 42,
            child: Center(
              child: ValueListenableBuilder<int>(
                valueListenable: app.viewVersion,
                builder: (context, _, _) => Text('${(app.zoom * 100).round()}%', style: uiText(12, tokens.textMuted)),
              ),
            ),
          ),
          SizedBox(
            width: 22,
            child: IconButton(iconSize: 15, padding: EdgeInsets.zero, tooltip: 'Perbesar', onPressed: () => app.zoomStep(1.2), icon: Icon(Icons.add, color: tokens.textMuted)),
          ),
          SizedBox(
            width: 26,
            child: IconButton(iconSize: 15, padding: EdgeInsets.zero, tooltip: 'Muat semua', onPressed: app.fitView, icon: Icon(Icons.fit_screen_outlined, color: tokens.textMuted)),
          ),
        ],
      ),
    );
  }
}
