import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../file_io.dart';
import '../model/device_def.dart';
import 'plc_editor.dart';
import 'theme.dart';

/// The first thing BuildLadder shows, following Zelio Soft's start-up flow: start a new program or open one, pick the
/// controller from photos, pick the programming language, then the editor opens.
class LadderStartPage extends StatefulWidget {
  const LadderStartPage({super.key, required this.app});

  final AppState app;

  @override
  State<LadderStartPage> createState() => _LadderStartPageState();
}

enum _Step { start, module, language }

/// A family of controllers shown as one tab in the module picker.
class _Family {
  const _Family(this.id, this.title, this.subtitle, this.test);

  final String id;
  final String title;
  final String subtitle;
  final bool Function(DeviceDef def) test;
}

final List<_Family> _families = [
  _Family('sr2', 'Zelio SR2 · Kompak', 'Modul ringkas dengan layar dan tombol. Tidak bisa ditambah ekstensi.', (d) => d.id.startsWith('zelio_sr2')),
  _Family('sr3', 'Zelio SR3 · Modular', 'Modul dasar yang bisa ditambah ekstensi I/O dan komunikasi.', (d) => d.id.startsWith('zelio_sr3')),
  _Family('logo', 'LOGO!', 'Modul logika kecil dengan layar dan tombol kursor.', (d) => d.id.startsWith('logo_')),
];

class _LadderStartPageState extends State<LadderStartPage> {
  _Step _step = _Step.start;
  String _family = 'sr3';
  String? _model;
  String? _error;

  AppState get app => widget.app;

  List<DeviceDef> get _plcs => app.defs.values.where((d) => d.kind == 'plc' && d.panel != null).toList();

  List<DeviceDef> _modelsOf(String family) {
    final match = _families.firstWhere((f) => f.id == family).test;
    return _plcs.where(match).toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  void _openEditor(String defId, {(String, Uint8List)? file}) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => LadderEditor(app: app, defId: defId, initialFile: file),
      ),
    );
  }

  Future<void> _openFile() async {
    try {
      final picked = await pickLadderFile();
      if (picked == null || !mounted) return;
      // The editor switches to the model written in the file; this is only the fallback.
      _openEditor(lastLadderModel ?? 'zelio_sr3b261fu', file: picked);
    } on Object catch (error) {
      if (mounted) setState(() => _error = 'File tidak bisa dibuka: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Scaffold(
      backgroundColor: tokens.canvas,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TitleBar(step: _step, onClose: () => Navigator.of(context).pop()),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: switch (_step) {
                  _Step.start => _startView(tokens),
                  _Step.module => _moduleView(tokens),
                  _Step.language => _languageView(tokens),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ----- Step 0: what to do

  Widget _startView(Tokens tokens) {
    final last = lastLadderModel == null ? null : app.defs[lastLadderModel!];
    return Center(
      key: const ValueKey('start'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(kLadderEditorName, style: plateText(44, tokens.text, weight: 700, height: 1)),
              const SizedBox(height: 6),
              Text('Program ladder untuk PLC kecil. Pilih mau mulai dari mana.', style: uiText(15, tokens.textMuted)),
              const SizedBox(height: 28),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  _ActionCard(
                    key: const ValueKey('ladder-start-new'),
                    icon: Icons.add_box_outlined,
                    title: 'Buat program baru',
                    body: 'Pilih modul PLC dari foto, lalu tulis program ladder.',
                    primary: true,
                    onTap: () => setState(() => _step = _Step.module),
                  ),
                  _ActionCard(
                    key: const ValueKey('ladder-start-open'),
                    icon: Icons.folder_open_outlined,
                    title: 'Buka program',
                    body: 'File BuildLadder (.bwlad) atau Zelio Soft 2 (.zm2).',
                    onTap: _openFile,
                  ),
                  if (last != null)
                    _ActionCard(
                      key: const ValueKey('ladder-start-last'),
                      icon: Icons.history,
                      title: 'Modul terakhir',
                      body: '${last.name}. Langsung ke editor dengan program kosong.',
                      onTap: () => _openEditor(last.id),
                    ),
                ],
              ),
              if (_error != null) ...[const SizedBox(height: 16), Text(_error!, style: uiText(13, tokens.error))],
            ],
          ),
        ),
      ),
    );
  }

  // ----- Step 1: pick the module from photos

  Widget _moduleView(Tokens tokens) {
    final models = _modelsOf(_family);
    final selected = models.where((d) => d.id == _model).firstOrNull;
    final family = _families.firstWhere((f) => f.id == _family);
    return Column(
      key: const ValueKey('module'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
          child: Text('Pilih modul', style: uiText(22, tokens.text, weight: 700)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in _families)
                if (_modelsOf(f.id).isNotEmpty)
                  ChoiceChip(
                    key: ValueKey('ladder-family-${f.id}'),
                    label: Text(f.title),
                    selected: f.id == _family,
                    onSelected: (_) => setState(() {
                      _family = f.id;
                      _model = null;
                    }),
                  ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 10),
          child: Text(family.subtitle, style: uiText(13, tokens.textMuted)),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final grid = GridView.builder(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 260,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.82,
                ),
                itemCount: models.length,
                itemBuilder: (context, i) => _ModuleCard(
                  def: models[i],
                  selected: models[i].id == _model,
                  onTap: () => setState(() => _model = models[i].id),
                  onOpen: () => setState(() {
                    _model = models[i].id;
                    _step = _Step.language;
                  }),
                ),
              );
              if (box.maxWidth < 900) return grid;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: grid),
                  SizedBox(width: 340, child: _ModuleDetail(def: selected)),
                ],
              );
            },
          ),
        ),
        _Footer(
          onBack: () => setState(() => _step = _Step.start),
          nextLabel: 'Lanjut',
          onNext: _model == null ? null : () => setState(() => _step = _Step.language),
          hint: _model == null ? 'Klik foto modul untuk memilih, klik sekali lagi untuk lanjut.' : app.defs[_model]!.name,
        ),
      ],
    );
  }

  // ----- Step 2: programming language

  Widget _languageView(Tokens tokens) {
    final def = app.defs[_model]!;
    return Column(
      key: const ValueKey('language'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Bahasa pemrograman', style: uiText(22, tokens.text, weight: 700)),
                    const SizedBox(height: 4),
                    Text(def.name, style: uiText(13, tokens.textMuted)),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 14,
                      runSpacing: 14,
                      children: [
                        _ActionCard(
                          key: const ValueKey('ladder-lang-ld'),
                          icon: Icons.view_week_outlined,
                          title: 'Ladder (LD)',
                          body: 'Kontak dan coil di grid lima kolom, seperti diagram kontrol relay.',
                          primary: true,
                          onTap: () => _openEditor(def.id),
                        ),
                        const _ActionCard(icon: Icons.account_tree_outlined, title: 'Blok fungsi (FBD)', body: 'Belum tersedia.', onTap: null),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        _Footer(onBack: () => setState(() => _step = _Step.module), nextLabel: 'Buka editor', onNext: () => _openEditor(def.id), hint: 'Ladder dipilih.'),
      ],
    );
  }
}

/// Title and the three steps, with the current one marked.
class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.step, required this.onClose});

  final _Step step;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    const labels = ['Mulai', 'Modul', 'Bahasa'];
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: tokens.panel,
        border: Border(bottom: BorderSide(color: tokens.border)),
      ),
      child: Row(
        children: [
          const Nameplate(kLadderEditorName, size: 16),
          const SizedBox(width: 24),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < labels.length; i++) ...[
                    if (i > 0) Icon(Icons.chevron_right, size: 16, color: tokens.textMuted),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      // The current step is a dark plate, like the switch positions in the workspace toolbar.
                      decoration: BoxDecoration(color: i == step.index ? tokens.plate : Colors.transparent, borderRadius: BorderRadius.circular(Radii.plate)),
                      child: Text(
                        '${i + 1}. ${labels[i]}',
                        style: uiText(12, i == step.index ? tokens.onPlate : (i < step.index ? tokens.text : tokens.textMuted), weight: 600),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          IconButton(key: const ValueKey('ladder-start-close'), tooltip: 'Tutup', onPressed: onClose, icon: const Icon(Icons.close)),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({super.key, required this.icon, required this.title, required this.body, required this.onTap, this.primary = false});

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: primary ? tokens.accentSoft : tokens.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          side: BorderSide(color: primary ? tokens.accent : tokens.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: onTap,
          child: SizedBox(
            width: 236,
            height: 172,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 26, color: primary ? tokens.accent : tokens.text),
                  const Spacer(),
                  Text(title, style: uiText(15, tokens.text, weight: 700)),
                  const SizedBox(height: 4),
                  Text(body, maxLines: 3, overflow: TextOverflow.ellipsis, style: uiText(12, tokens.textMuted, height: 1.35)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Supply, inputs and outputs of a controller, read from the catalog.
List<(String, String)> _specs(DeviceDef def) {
  final volts = def.ratings['voltage_v'];
  final dc = def.name.contains('DC') || def.id.endsWith('bd') || def.id.contains('24rce');
  return [
    ('Catu daya', volts == null ? '-' : '$volts V ${dc ? 'DC' : 'AC'}'),
    ('Input', '${def.plcInputs.length} (${def.plcInputs.first}–${def.plcInputs.last})'),
    ('Output', '${def.plcOutputs.length} relay (${def.plcOutputs.first}–${def.plcOutputs.last})'),
    ('Layar & tombol', 'Ada'),
  ];
}

/// The short model code shown under each photo, like "SR3B261FU".
String _code(DeviceDef def) {
  final match = RegExp(r'(SR\d[A-Z0-9]+|LOGO! ?[0-9A-Z]+)').firstMatch(def.name);
  return match?.group(0) ?? def.name;
}

class _ModuleCard extends StatefulWidget {
  const _ModuleCard({required this.def, required this.selected, required this.onTap, required this.onOpen});

  final DeviceDef def;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onOpen;

  @override
  State<_ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<_ModuleCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final def = widget.def;
    final active = widget.selected || _hover;
    // A focusable InkWell (R-32): Tab reaches it, Enter or Space picks it, and focus shows like hover does.
    return InkWell(
      key: ValueKey('ladder-module-${def.id}'),
      // A second click on the chosen module goes on, without the delay a double-tap handler adds to every click.
      onTap: widget.selected ? widget.onOpen : widget.onTap,
      onHover: (v) => setState(() => _hover = v),
      onFocusChange: (v) => setState(() => _hover = v),
      borderRadius: BorderRadius.circular(Radii.control),
      mouseCursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: widget.selected ? tokens.accentSoft : tokens.panel,
          borderRadius: BorderRadius.circular(Radii.control),
          border: Border.all(color: active ? tokens.accent : tokens.border, width: widget.selected ? 2 : 1),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Image.asset(def.previewAsset ?? def.assetFor(def.defaultState), fit: BoxFit.contain, filterQuality: FilterQuality.medium),
            ),
            const SizedBox(height: 10),
            Text(_code(def), style: plateText(18, tokens.text, weight: 700)),
            const SizedBox(height: 2),
            Text(
              '${def.plcInputs.length} input · ${def.plcOutputs.length} output · ${_specs(def).first.$2}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: uiText(12, tokens.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// The selected module, large, with its specification.
class _ModuleDetail extends StatelessWidget {
  const _ModuleDetail({required this.def});

  final DeviceDef? def;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final def = this.def;
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 4, 24, 24),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: tokens.panel,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: tokens.border),
      ),
      child: def == null
          ? Center(child: Text('Belum ada modul dipilih.', style: uiText(13, tokens.textMuted)))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Image.asset(def.assetFor('run'), fit: BoxFit.contain, filterQuality: FilterQuality.medium),
                ),
                const SizedBox(height: 14),
                Text(_code(def), style: plateText(24, tokens.text, weight: 700)),
                const SizedBox(height: 2),
                Text(def.name, style: uiText(12, tokens.textMuted)),
                const SizedBox(height: 14),
                for (final (label, value) in _specs(def))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 110, child: Text(label, style: uiText(12, tokens.textMuted))),
                        Expanded(child: Text(value, style: uiText(13, tokens.text, weight: 500))),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.onBack, required this.nextLabel, required this.onNext, required this.hint});

  final VoidCallback onBack;
  final String nextLabel;
  final VoidCallback? onNext;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: tokens.panel,
        border: Border(top: BorderSide(color: tokens.border)),
      ),
      child: Row(
        children: [
          OutlinedButton.icon(
            key: const ValueKey('ladder-start-back'),
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('Kembali'),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: uiText(13, tokens.textMuted)),
          ),
          const SizedBox(width: 16),
          FilledButton.icon(
            key: const ValueKey('ladder-start-next'),
            onPressed: onNext,
            icon: const Icon(Icons.arrow_forward, size: 16),
            label: Text(nextLabel),
          ),
        ],
      ),
    );
  }
}
