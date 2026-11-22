import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../file_io.dart';
import '../relay/relay_editor.dart';
import '../templates.dart';
import 'plc_editor.dart';
import 'spark_wordmark.dart';
import 'theme.dart';

/// The start screen. Left: what the app is and the ways in (the canvas is the one primary action). Right: the
/// ready-made circuits as a grouped list, each with its real part and wire count.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.app});

  final AppState app;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

final Uri _site = Uri.parse('https://rifqi.id');

/// Ready-made circuits grouped the way a training workshop orders them.
const List<(String, List<String>)> _groups = [
  ('Dasar', ['lamp', 'meters']),
  ('Motor 3 fasa', ['dol', 'reversing', 'stardelta']),
  ('PLC', ['plc', 'plc_stardelta']),
  ('Kontrol DC', ['dc_control', 'dc_motor']),
];

class _HomeScreenState extends State<HomeScreen> {
  AppState get app => widget.app;

  final _focus = FocusNode(debugLabel: 'home');
  String? _error;

  /// Part and wire counts per template, read from the circuit it builds.
  late final Map<String, (int, int)> _sizes = {
    for (final t in kTemplates)
      t.id: () {
        final project = t.build();
        return (project.devices.length, project.wires.length);
      }(),
  };

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _showError(String message) {
    if (mounted) setState(() => _error = message);
  }

  Future<void> _openSite() async {
    try {
      if (await launchUrl(_site, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
    _showError('Browser tidak bisa dibuka. Kunjungi rifqi.id secara manual.');
  }

  Future<void> _openFile() async {
    try {
      final text = await pickProjectText();
      if (text == null || !mounted) return;
      final error = app.importJson(text);
      if (error != null) return _showError(error);
      app.openBuilder();
    } on FormatException catch (error) {
      _showError(error.message);
    } catch (_) {
      _showError('Gagal membuka file proyek. Coba lagi atau pilih file lain.');
    }
  }

  void _startEmpty() {
    app.newProject();
    app.openBuilder();
  }

  void _startTemplate(CircuitTemplate template) {
    app.applyTemplate(template);
    app.openBuilder();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    // Enter opens the canvas only when nothing else has focus; a focused button takes Enter itself.
    if ((key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) && node.hasPrimaryFocus) {
      app.openBuilder();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyO && HardwareKeyboard.instance.isControlPressed) {
      _openFile();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Material(
      color: tokens.canvas,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 940;
            final padX = wide ? 48.0 : 20.0;
            return Column(
              children: [
                _topBar(tokens, padX),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(padX, wide ? 56 : 28, padX, 32),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1120),
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(width: 380, child: _intro(tokens)),
                                  const SizedBox(width: 72),
                                  Expanded(child: _circuits(tokens)),
                                ],
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [_intro(tokens), const SizedBox(height: 40), _circuits(tokens)],
                              ),
                      ),
                    ),
                  ),
                ),
                _footer(tokens, padX),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _topBar(Tokens tokens, double padX) {
    return Container(
      height: 56,
      padding: EdgeInsets.fromLTRB(padX, 0, padX - 8, 0),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tokens.border))),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.plate),
            child: Image.asset('assets/brand/logo.png', width: 30, height: 30, filterQuality: FilterQuality.medium, semanticLabel: 'Logo BuildWire'),
          ),
          const Spacer(),
          IconButton(
            key: const ValueKey('home-theme'),
            tooltip: app.dark ? 'Tema terang' : 'Tema gelap',
            onPressed: app.toggleTheme,
            icon: Icon(app.dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, size: 20, color: tokens.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _intro(Tokens tokens) {
    final project = app.project;
    final hasWork = !project.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The wordmark alone; it scales down to fit a narrow window.
        const FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: SparkWordmark(size: 104)),
        const SizedBox(height: 28),
        FilledButton(
          key: const ValueKey('home-project'),
          onPressed: app.openBuilder,
          style: FilledButton.styleFrom(minimumSize: const Size(0, 46), padding: const EdgeInsets.symmetric(horizontal: 22)),
          child: Text(hasWork ? 'Lanjutkan proyek' : 'Buka kanvas', style: uiText(14.5, tokens.onHazard, weight: 650)),
        ),
        const SizedBox(height: 10),
        Text(
          hasWork ? '${project.name}: ${project.devices.length} perangkat, ${project.wires.length} kabel' : 'Atau tekan Enter.',
          style: uiText(12.5, tokens.textMuted),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 26),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('home-open'),
              onPressed: _openFile,
              icon: const Icon(Icons.folder_open_outlined, size: 17),
              label: const Text('Buka file'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('home-template-empty'),
              onPressed: _startEmpty,
              icon: const Icon(Icons.note_add_outlined, size: 17),
              label: const Text('Proyek kosong'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('home-ladder'),
              onPressed: () => showStandaloneLadder(context, app),
              icon: const Icon(Icons.view_week_outlined, size: 17),
              label: const Text(kLadderEditorName),
            ),
            OutlinedButton.icon(
              key: const ValueKey('home-relay'),
              onPressed: () => showBuildRelay(context),
              icon: const Icon(Icons.electrical_services_outlined, size: 17),
              label: const Text(kRelayEditorName),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 14),
          Text(_error!, style: uiText(13, tokens.error)),
        ],
      ],
    );
  }

  Widget _circuits(Tokens tokens) {
    final byId = {for (final t in kTemplates) t.id: t};
    final grouped = {for (final (_, ids) in _groups) ...ids};
    final others = kTemplates.where((t) => !grouped.contains(t.id)).map((t) => t.id).toList();
    final groups = [..._groups, if (others.isNotEmpty) ('Lainnya', others)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Rangkaian jadi', style: plateText(20, tokens.text, weight: 700)),
        const SizedBox(height: 4),
        Text('Dibuka sebagai proyek baru yang bisa langsung dijalankan dan diubah.', style: uiText(12.5, tokens.textMuted)),
        const SizedBox(height: 18),
        for (final (title, ids) in groups) ...[
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 6),
            child: Text(title, style: uiText(12, tokens.textMuted, weight: 650)),
          ),
          Container(
            decoration: BoxDecoration(
              color: tokens.panel,
              border: Border.all(color: tokens.border),
              borderRadius: BorderRadius.circular(Radii.control),
            ),
            child: Column(
              children: [
                for (var i = 0; i < ids.length; i++)
                  if (byId[ids[i]] != null) ...[
                    if (i > 0) Divider(height: 1, thickness: 1, color: tokens.border),
                    _CircuitRow(
                      key: ValueKey('home-template-${ids[i]}'),
                      template: byId[ids[i]]!,
                      size: _sizes[ids[i]]!,
                      onTap: () => _startTemplate(byId[ids[i]]!),
                    ),
                  ],
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }

  Widget _footer(Tokens tokens, double padX) {
    return Container(
      padding: EdgeInsets.fromLTRB(padX, 10, padX - 8, 10),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: tokens.border))),
      child: Row(
        children: [
          Text('Ctrl+O membuka file proyek', style: uiText(12, tokens.textMuted)),
          const Spacer(),
          TextButton(key: const ValueKey('home-site'), onPressed: _openSite, child: const Text('rifqi.id')),
        ],
      ),
    );
  }
}

/// One ready-made circuit: its name and what it teaches, with the part and wire count on a wire-marker tag.
class _CircuitRow extends StatelessWidget {
  const _CircuitRow({super.key, required this.template, required this.size, required this.onTap});

  final CircuitTemplate template;
  final (int, int) size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return InkWell(
      onTap: onTap,
      mouseCursor: SystemMouseCursors.click,
      focusColor: tokens.accentSoft,
      hoverColor: tokens.hover,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(template.name, style: uiText(14, tokens.text, weight: 600)),
                  const SizedBox(height: 3),
                  Text(template.description, style: uiText(12.5, tokens.textMuted, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            // Wire-marker style tag with the circuit's real size.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: tokens.border),
                borderRadius: BorderRadius.circular(Radii.plate),
              ),
              child: Text('${size.$1} perangkat · ${size.$2} kabel', style: plateText(13, tokens.textMuted)),
            ),
          ],
        ),
      ),
    );
  }
}
