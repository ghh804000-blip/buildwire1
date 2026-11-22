import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../app_state.dart';
import '../model/device_def.dart';
import '../model/project.dart';
import '../sim/solver.dart';
import 'canvas_view.dart';
import 'hmi_editor.dart';
import 'plc_editor.dart';
import 'theme.dart';

const Map<String, String> kCategoryNames = {
  'sources': 'Sumber',
  'protection': 'Proteksi',
  'control': 'Kontrol',
  'contactors': 'Kontaktor',
  'relays': 'Relay dan timer',
  'automation': 'PLC dan HMI',
  'sensors': 'Sensor',
  'loads': 'Beban',
  'terminals': 'Terminal dan busbar',
  'meters': 'Alat ukur',
  'structure': 'Struktur panel',
};

/// Order of the library groups, from supply to load. Groups not listed follow alphabetically.
const List<String> kGroupOrder = [
  'Sumber AC/DC', 'Power supply DC', 'Trafo',
  'MCB', 'MCCB', 'MPCB', 'RCCB', 'Overload relay (TOR)', 'Relay proteksi fasa',
  'Kontaktor', 'Kontak bantu', 'Relay', 'Timer', 'Relay safety',
  'Tombol tekan', 'Tombol darurat', 'Selektor', 'Saklar', 'Lampu indikator dan buzzer',
  'PLC', 'Inverter (VFD)', 'Sensor', 'Alat ukur',
  'Motor', 'Beban', 'Stopkontak', 'Komponen pasif',
  'Terminal', 'Busbar dan distribusi', 'Rel DIN', 'Box panel',
];

/// The library group a device is listed under.
String groupOf(DeviceDef def) => def.group ?? def.categoryLabel ?? kCategoryNames[def.category] ?? def.category;

const Map<String, String> kStateNames = {
  'on': 'Menyala',
  'off': 'Mati',
  'open': 'Terbuka',
  'closed': 'Tertutup',
  'tripped': 'Trip',
  'exploded': 'MELEDAK (rusak)',
  'pressed': 'Ditekan',
  'released': 'Dilepas',
  'stopped': 'Berhenti',
  'run_fwd': 'Berputar maju',
  'run_rev': 'Berputar mundur',
  'timing': 'Menghitung',
  'timing_off': 'Menghitung',
  'normal': 'Normal',
  'latched': 'Terkunci',
  'left': 'Posisi 1',
  'right': 'Posisi 2',
  'center': 'Posisi 0',
  'run': 'Berjalan',
  'stop': 'STOP',
};

/// A control value with a slider and readout. Live controls also work during simulation.
class ControlSlider extends StatelessWidget {
  const ControlSlider({super.key, required this.app, required this.device, required this.control});

  final AppState app;
  final PlacedDevice device;
  final ControlDef control;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final value = device.number(control.key, control.fallback).clamp(control.min, control.max);
    final enabled = !app.running || control.live;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(control.label, style: uiText(12, tokens.textMuted, weight: 600))),
              Text('${value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1)} ${control.unit}', style: uiText(13, tokens.text, weight: 600)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3, overlayShape: SliderComponentShape.noOverlay, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Slider(
                key: ValueKey('control-${control.key}'),
                value: value,
                min: control.min,
                max: control.max,
                onChangeStart: enabled ? (_) => app.beginControlEdit() : null,
                onChanged: enabled ? (next) => app.setControl(device, control.key, next.roundToDouble()) : null,
                onChangeEnd: enabled ? (_) => app.endControlEdit() : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What a device is doing right now, with the controls that can change it.
class LiveInspector extends StatelessWidget {
  const LiveInspector({super.key, required this.app, required this.device});

  final AppState app;
  final PlacedDevice device;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final def = app.defOf(device);
    final result = app.simResult;
    final measure = app.shownMeasure(device);
    final state = app.stateOf(device);
    final base = state.split(':').first;
    final remaining = app.timerRemaining(device);
    final warnings = result?.warnings.where((w) => w.deviceId == device.id).toList() ?? const <SimWarning>[];
    final heat = app.heatOf(device);
    final live = def.controls.where((c) => c.live).toList();

    Widget info(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Row(
            children: [
              SizedBox(width: 92, child: Text(label, style: uiText(12, tokens.textMuted))),
              Expanded(child: Text(value, style: uiText(13, tokens.text, weight: 500))),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(def.name, style: uiText(15, tokens.text, weight: 600)),
        const SizedBox(height: 3),
        Text('Inspektur langsung', style: plateText(14, tokens.run, weight: 700)),
        const SizedBox(height: 12),
        info('Tag', device.tag),
        info('Kondisi', remaining == null ? (kStateNames[base] ?? base) : '${kStateNames[base] ?? base} (${remaining.toStringAsFixed(1).replaceAll('.', ',')} dtk)'),
        info('Tegangan', '${measure.volts.toStringAsFixed(1)} V'),
        info('Arus', '${measure.amps.toStringAsFixed(3)} A'),
        info('Frekuensi', '${measure.hertz.toStringAsFixed(1)} Hz'),
        info('Daya', '${(measure.watts / 1000).toStringAsFixed(3)} kW'),
        if (def.rotor != null) info('Putaran', '${(app.rotorSpeed(device) * 100).toStringAsFixed(0)} %'),
        if (def.thermal != null) info('Panas trip', '${(heat * 100).toStringAsFixed(0)} %'),
        if (app.damageOf(device) > 0 && base != 'exploded') info('Kerusakan', '${(app.damageOf(device) * 100).toStringAsFixed(0)} % menuju meledak'),
        for (final warning in warnings)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(kWarningText[warning.code]!, style: uiText(13, tokens.warning, weight: 500, height: 1.35))),
        if (live.isNotEmpty) ...[
          const SizedBox(height: 14),
          const SectionLabel('Kontrol langsung'),
          for (final control in live) ControlSlider(app: app, device: device, control: control),
        ],
        if (def.operateHint != null) ...[
          const SizedBox(height: 10),
          Text(def.operateHint!, style: uiText(12, tokens.textMuted, height: 1.4)),
        ],
        if (def.kind == 'plc' && base == 'run') ...[
          const SizedBox(height: 14),
          const SectionLabel('Bit aktif'),
          Text(app.bitsOf(device).isEmpty ? 'Tidak ada.' : (app.bitsOf(device).toList()..sort()).join(', '), style: uiText(13, tokens.text, height: 1.4)),
        ],
        if (def.terminals.isNotEmpty) ...[
          const SizedBox(height: 14),
          const SectionLabel('Potensial terminal'),
          for (final terminal in def.terminals)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                children: [
                  SizedBox(width: 50, child: Text(terminal.id, style: uiText(12, tokens.text, weight: 600))),
                  Text(result?.at(TerminalRef(device.id, terminal.id)) ?? '-', style: uiText(12, tokens.textMuted)),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

const List<(int, String)> kWireColors = [
  (0xFF8A5A2B, 'Cokelat (L1)'),
  (0xFF1F2428, 'Hitam (L2)'),
  (0xFF808890, 'Abu (L3)'),
  (0xFF1D6FB8, 'Biru (N)'),
  (0xFF3F8F3A, 'Hijau (PE)'),
  (0xFFB3261E, 'Merah (kontrol)'),
  (0xFF3F4750, 'Abu tua'),
  (0xFFB45309, 'Tembaga (jumper)'),
];

const List<double> kWireGauges = [0.75, 1, 1.5, 2.5, 4, 6, 10, 16];

String ratingLabel(String key, Object? value) => switch (key) {
      'voltage_v' || 'rated_voltage_v' => 'Tegangan: $value V',
      'coil_voltage_v' => 'Tegangan coil: $value V',
      'frequency_hz' => 'Frekuensi: $value Hz',
      'rated_current_a' => 'Arus nominal: $value A',
      'ac3_current_a' => 'Arus AC-3: $value A',
      'curve' => 'Kurva trip: $value',
      'coil_kind' => 'Jenis coil: ${value == 'ac' ? 'AC' : 'DC'}',
      'contact_form' => 'Kontak: $value',
      'instant_trip_multiple' => 'Trip seketika: ${(value as List<dynamic>).join('-')} x In',
      'residual_ma' => 'Arus sisa: $value mA',
      'power_w' => 'Daya: $value W',
      'time_s' => 'Rentang waktu: $value detik',
      'range_v' => 'Rentang: $value V',
      'range_a' => 'Rentang: $value A',
      'range_hz' => 'Rentang: $value Hz',
      'output_v' => 'Tegangan keluar: $value V DC',
      'inputs' => 'Input digital: $value',
      'outputs' => 'Output relay: $value',
      'screen_in' => 'Layar: $value inci',
      'length_mm' => 'Panjang: $value mm',
      'width_mm' => 'Lebar: $value mm',
      'height_mm' => 'Tinggi: $value mm',
      _ => '$key: $value',
    };

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: uiText(12, context.tokens.textMuted, weight: 600)),
      );
}

class LibraryPanel extends StatefulWidget {
  const LibraryPanel({super.key, required this.app});

  final AppState app;

  @override
  State<LibraryPanel> createState() => _LibraryPanelState();
}

/// Compares names so numbers sort by value: "4P" before "10P".
int naturalCompare(String a, String b) {
  final pattern = RegExp(r'\d+|\D+');
  final left = pattern.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final right = pattern.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = int.tryParse(left[i]);
    final y = int.tryParse(right[i]);
    final order = x != null && y != null ? x.compareTo(y) : left[i].compareTo(right[i]);
    if (order != 0) return order;
  }
  return left.length.compareTo(right.length);
}

class _LibraryPanelState extends State<LibraryPanel> {
  String _query = '';
  bool _symbols = false;

  /// Groups opened by the user, kept per tab. Everything starts folded so the list stays short.
  final Set<String> _open = {};

  void _toggle(String group) => setState(() => _open.contains(group) ? _open.remove(group) : _open.add(group));

  final Map<String, GlobalKey> _groupKeys = {};
  final Map<String, GlobalKey> _itemKeys = {};
  GlobalKey _groupKey(String group) => _groupKeys.putIfAbsent(group, GlobalKey.new);
  GlobalKey _itemKey(String id) => _itemKeys.putIfAbsent(id, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    widget.app.library = LibraryBridge(groupRect: _groupRect, isOpen: _isGroupOpen, reveal: _reveal);
  }

  @override
  void dispose() {
    if (widget.app.library?.reveal == _reveal) widget.app.library = null;
    super.dispose();
  }

  static Rect? _rectOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// The device tab with no search, so every group header shows.
  void _plain() {
    if (_symbols || _query.isNotEmpty) {
      setState(() {
        _symbols = false;
        _query = '';
      });
    }
  }

  String? _groupFor(String id) {
    final def = widget.app.defs[id];
    return def == null ? null : groupOf(def);
  }

  bool _isGroupOpen(String id) {
    final group = _groupFor(id);
    return group != null && _open.contains('device/$group') && !_symbols && _query.isEmpty;
  }

  Rect? _groupRect(String id) {
    _plain();
    final group = _groupFor(id);
    if (group == null) return null;
    final key = _groupKeys[group];
    final context = key?.currentContext;
    if (context == null) return null;
    final rect = _rectOf(key!);
    return rect;
  }

  /// Opens the device's group, scrolls its card into view and returns where the card is.
  Future<Rect?> _reveal(String id) async {
    _plain();
    final group = _groupFor(id);
    if (group == null || !mounted) return null;
    if (!_open.contains('device/$group')) setState(() => _open.add('device/$group'));
    await WidgetsBinding.instance.endOfFrame;
    final header = _groupKeys[group]?.currentContext;
    // Bring the group to the top of the list, then the card is in view below it.
    if (header != null && header.mounted) {
      await Scrollable.ensureVisible(header, duration: const Duration(milliseconds: 260), curve: Curves.easeOut, alignment: 0.05);
    }
    final card = _itemKeys[id]?.currentContext;
    if (card != null && card.mounted) {
      await Scrollable.ensureVisible(card, duration: const Duration(milliseconds: 200), curve: Curves.easeOut, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
    }
    if (!mounted) return null;
    return _itemKeys[id] == null ? null : _rectOf(_itemKeys[id]!);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final app = widget.app;
    final query = _query.trim().toLowerCase();
    final all = app.defs.values.where((d) => d.isSymbol == _symbols && !d.isJunction);
    final groups = <String, List<DeviceDef>>{};
    for (final def in all) {
      final group = groupOf(def);
      if (query.isEmpty || def.name.toLowerCase().contains(query) || group.toLowerCase().contains(query) || def.designator.toLowerCase() == query) {
        groups.putIfAbsent(group, () => []).add(def);
      }
    }
    final order = _symbols
        ? (groups.keys.toList()..sort())
        : [
            for (final name in kGroupOrder)
              if (groups.containsKey(name)) name,
            for (final name in groups.keys.toList()..sort())
              if (!kGroupOrder.contains(name)) name,
          ];
    for (final list in groups.values) {
      list.sort((a, b) => naturalCompare(a.name, b.name));
    }
    final tab = _symbols ? 'symbol' : 'device';
    // A search opens every matching group.
    bool isOpen(String group) => query.isNotEmpty || _open.contains('$tab/$group');
    final allOpen = order.every(isOpen);
    final deviceCount = app.defs.values.where((d) => !d.isSymbol && !d.isJunction).length;
    final symbolCount = app.defs.length - deviceCount;

    return Container(
      width: 252,
      decoration: BoxDecoration(color: tokens.panel, border: Border(right: BorderSide(color: tokens.border))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                Expanded(child: _Tab(label: 'Perangkat ($deviceCount)', active: !_symbols, onTap: () => setState(() => _symbols = false))),
                const SizedBox(width: 4),
                Expanded(child: _Tab(label: 'Simbol ($symbolCount)', active: _symbols, onTap: () => setState(() => _symbols = true))),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              key: const ValueKey('library-search'),
              onChanged: (value) => setState(() => _query = value),
              style: uiText(13, tokens.text),
              decoration: InputDecoration(
                hintText: _symbols ? 'Cari simbol' : 'Cari perangkat',
                hintStyle: uiText(13, tokens.textMuted),
                prefixIcon: Icon(Icons.search, size: 16, color: tokens.textMuted),
                prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ),
          ),
          if (_symbols)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: Text('Simbol untuk gambar skematik. Tidak ikut simulasi.', style: uiText(12, tokens.textMuted, height: 1.35)),
            ),
          Expanded(
            child: order.isEmpty
                ? Padding(padding: const EdgeInsets.all(16), child: Text('Tidak ditemukan.', style: uiText(13, tokens.textMuted)))
                : CustomScrollView(
                    slivers: [
                      if (query.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 8, 2),
                            child: Row(
                              children: [
                                Expanded(child: Text('${order.length} kelompok', style: uiText(11, tokens.textMuted))),
                                TextButton(
                                  key: const ValueKey('library-toggle-all'),
                                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: const Size(0, 26)),
                                  onPressed: () => setState(() {
                                    final keys = order.map((g) => '$tab/$g');
                                    allOpen ? _open.removeAll(keys) : _open.addAll(keys);
                                  }),
                                  child: Text(allOpen ? 'Tutup semua' : 'Buka semua', style: uiText(11, tokens.accent, weight: 600)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      for (final group in order) ...[
                        SliverToBoxAdapter(
                          child: _GroupHeader(
                            key: _symbols ? ValueKey('library-group-$group') : _groupKey(group),
                            label: group,
                            count: groups[group]!.length,
                            open: isOpen(group),
                            onTap: query.isEmpty ? () => _toggle('$tab/$group') : null,
                          ),
                        ),
                        if (isOpen(group))
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
                            sliver: SliverGrid.count(
                              crossAxisCount: 2,
                              childAspectRatio: 0.92,
                              mainAxisSpacing: 6,
                              crossAxisSpacing: 6,
                              children: [for (final def in groups[group]!) _LibraryItem(key: _symbols ? ValueKey(def.id) : _itemKey(def.id), app: app, def: def)],
                            ),
                          ),
                      ],
                      const SliverToBoxAdapter(child: SizedBox(height: 12)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// A foldable group title in the library: arrow, name and how many items it holds.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({super.key, required this.label, required this.count, required this.open, required this.onTap});

  final String label;
  final int count;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tokens.border.withValues(alpha: 0.6)))),
        child: Row(
          children: [
            AnimatedRotation(
              turns: open ? 0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(Icons.chevron_right, size: 18, color: tokens.textMuted),
            ),
            const SizedBox(width: 4),
            Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: uiText(13, tokens.text, weight: open ? 600 : 500))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: tokens.hover, borderRadius: BorderRadius.circular(Radii.control)),
              child: Text('$count', style: uiText(11, tokens.textMuted, weight: 600)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.control),
      onTap: onTap,
      child: Container(
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: active ? tokens.accentSoft : Colors.transparent, borderRadius: BorderRadius.circular(Radii.control)),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: uiText(12, active ? tokens.accent : tokens.textMuted, weight: 600)),
      ),
    );
  }
}

class _LibraryItem extends StatefulWidget {
  const _LibraryItem({super.key, required this.app, required this.def});

  final AppState app;
  final DeviceDef def;

  @override
  State<_LibraryItem> createState() => _LibraryItemState();
}

class _LibraryItemState extends State<_LibraryItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final def = widget.def;
    final enabled = !widget.app.running;
    final row = MouseRegion(
      cursor: enabled ? SystemMouseCursors.grab : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: ValueKey('library-${def.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => widget.app.addDevice(def.id) : null,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _hover && enabled ? tokens.hover : tokens.panel,
            border: Border.all(color: _hover && enabled ? tokens.accent : tokens.border),
            borderRadius: BorderRadius.circular(Radii.control),
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Column(
              children: [
                Expanded(child: def.isRaster
                    ? Image.asset(
                        def.previewAsset!,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => Image.asset(def.assetFor(def.defaultState), fit: BoxFit.contain),
                      )
                    : SvgPicture.asset(def.assetFor(def.defaultState), fit: BoxFit.contain)),
                const SizedBox(height: 5),
                SizedBox(
                  height: 30,
                  child: Text(def.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: uiText(11, tokens.text, weight: 500, height: 1.25)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!enabled) return row;
    final scale = widget.app.zoom;
    return Draggable<String>(
      data: def.id,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Opacity(
        opacity: 0.85,
        child: FractionalTranslation(
          translation: const Offset(-0.5, -0.5),
          child: SizedBox(width: def.width * scale, height: def.height * scale, child: def.isRaster
              ? Image.asset(def.assetFor(def.defaultState), fit: BoxFit.fill)
              : SvgPicture.asset(def.assetFor(def.defaultState), fit: BoxFit.fill)),
        ),
      ),
      child: row,
    );
  }
}

class PropertiesPanel extends StatelessWidget {
  const PropertiesPanel({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final device = app.singleSelection;
    final wire = app.selectedWireObject;
    final idle = !app.running && device == null && wire == null && app.selectedDevices.length <= 1;
    if (idle && app.guideHidden) {
      // Folded: a thin strip that gives the canvas the room, with the way back to the how-to.
      return Container(
        width: 40,
        alignment: Alignment.topCenter,
        padding: const EdgeInsets.only(top: 8),
        decoration: BoxDecoration(color: tokens.panel, border: Border(left: BorderSide(color: tokens.border))),
        child: IconButton(
          key: const ValueKey('guide-show'),
          tooltip: 'Tampilkan cara pakai',
          onPressed: app.toggleGuide,
          icon: Icon(Icons.help_outline, size: 19, color: tokens.textMuted),
        ),
      );
    }
    return Container(
      width: 276,
      decoration: BoxDecoration(color: tokens.panel, border: Border(left: BorderSide(color: tokens.border))),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (app.running && device != null)
            LiveInspector(key: ValueKey('live-${device.id}'), app: app, device: device)
          else if (app.running)
            _SimulationSummary(app: app)
          else if (device != null)
            _DeviceProperties(key: ValueKey('props-${device.id}-${device.tag}'), app: app, device: device)
          else if (app.selectedDevices.length > 1)
            _MultiProperties(app: app)
          else if (wire != null)
            _WireProperties(key: ValueKey('wire-${wire.id}-${wire.number}'), app: app, wire: wire)
          else
            _Guide(app: app),
        ],
      ),
    );
  }
}

class _Guide extends StatelessWidget {
  const _Guide({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    Widget step(String title, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: uiText(13, tokens.text, weight: 600)),
              const SizedBox(height: 2),
              Text(text, style: uiText(13, tokens.textMuted, height: 1.4)),
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: SectionLabel('Cara pakai')),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextButton(
                key: const ValueKey('guide-hide'),
                onPressed: app.toggleGuide,
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: const Size(0, 26)),
                child: Text('Sembunyikan', style: uiText(12, tokens.accent, weight: 600)),
              ),
            ),
          ],
        ),
        step('Menyambung', 'Klik satu terminal, lalu terminal tujuan. Klik kiri di tempat kosong untuk membelokkan kabel, klik kanan untuk batal.'),
        step('Menata', 'Alat, Tata letak otomatis: rangkaian daya di kiri, kontrol di kanan.'),
        step('Jumper', 'Pilih mode Jumper di toolbar, atau tekan J.'),
        step('Mengatur kabel', 'Klik kabel, lalu seret kotak kecil di segmennya.'),
        step('Memilih banyak', 'Seret di area kosong, atau tahan Shift sambil klik.'),
        step('Menggeser kanvas', 'Pakai alat Geser, atau Ctrl + seret. Scroll untuk zoom.'),
        step('Saat simulasi', 'Klik perangkat untuk melihat volt, ampere, dan daya.'),
        const SizedBox(height: 4),
        const SectionLabel('Proyek ini'),
        Text('${app.project.devices.length} perangkat, ${app.project.wires.length} sambungan', style: uiText(13, tokens.text)),
      ],
    );
  }
}

class _MultiProperties extends StatelessWidget {
  const _MultiProperties({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${app.selectedDevices.length} perangkat dipilih', style: uiText(15, tokens.text, weight: 600)),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: OutlinedButton(onPressed: () => app.alignSelection(left: true), child: Text('Rata kiri', style: uiText(13, tokens.text, weight: 500)))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(onPressed: () => app.alignSelection(left: false), child: Text('Rata atas', style: uiText(13, tokens.text, weight: 500)))),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: OutlinedButton(onPressed: app.duplicateSelection, child: Text('Duplikat', style: uiText(13, tokens.text, weight: 500)))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(onPressed: app.deleteSelection, child: Text('Hapus', style: uiText(13, tokens.error, weight: 500)))),
          ],
        ),
      ],
    );
  }
}

class _DeviceProperties extends StatefulWidget {
  const _DeviceProperties({super.key, required this.app, required this.device});

  final AppState app;
  final PlacedDevice device;

  @override
  State<_DeviceProperties> createState() => _DevicePropertiesState();
}

class _DevicePropertiesState extends State<_DeviceProperties> {
  late final TextEditingController _tag = TextEditingController(text: widget.device.tag);
  late final TextEditingController _time = TextEditingController(text: _formatTime());
  final FocusNode _focus = FocusNode();
  final FocusNode _timeFocus = FocusNode();

  String _formatTime() {
    final value = widget.app.timeOf(widget.device);
    return value == value.roundToDouble() ? value.toInt().toString() : value.toString();
  }

  void _applyTime() {
    final value = double.tryParse(_time.text.replaceAll(',', '.'));
    if (value == null || !value.isFinite || value <= 0 || value > 999) {
      _time.text = _formatTime();
      widget.app.reportStatus('Waktu timer harus antara 0,1 dan 999 detik.', StatusKind.warning);
      return;
    }
    widget.app.setTime(widget.device, value);
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.app.setTag(widget.device, _tag.text);
    });
    _timeFocus.addListener(() {
      if (!_timeFocus.hasFocus) _applyTime();
    });
  }

  @override
  void didUpdateWidget(_DeviceProperties old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _tag.text != widget.device.tag) {
      _tag.text = widget.device.tag;
    }
    final formatted = _formatTime();
    if (!_timeFocus.hasFocus && _time.text != formatted) {
      _time.text = formatted;
    }
  }

  @override
  void dispose() {
    _tag.dispose();
    _time.dispose();
    _focus.dispose();
    _timeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final app = widget.app;
    final def = app.defOf(widget.device);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(def.name, style: uiText(15, tokens.text, weight: 600)),
        const SizedBox(height: 16),
        const SectionLabel('Tag'),
        TextField(key: const ValueKey('tag-field'), controller: _tag, focusNode: _focus, style: uiText(13, tokens.text), onSubmitted: (value) => app.setTag(widget.device, value)),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: SectionLabel('Ukuran ${(app.scaleOf(widget.device) * 100).round()}%')),
            if ((app.scaleOf(widget.device) - 1).abs() > 0.001)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextButton(
                  key: const ValueKey('scale-reset'),
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), minimumSize: const Size(0, 24)),
                  onPressed: () {
                    app.beginControlEdit();
                    app.setDeviceScale(widget.device, 1);
                    app.endControlEdit();
                  },
                  child: Text('100%', style: uiText(12, tokens.accent, weight: 600)),
                ),
              ),
          ],
        ),
        // Bigger for parts that need to be read, smaller to fit a crowded panel; terminals and wires follow.
        Slider(
          key: const ValueKey('scale-slider'),
          min: AppState.minScale,
          max: AppState.maxScale,
          divisions: ((AppState.maxScale - AppState.minScale) * 20).round(),
          value: app.scaleOf(widget.device).clamp(AppState.minScale, AppState.maxScale),
          onChangeStart: (_) => app.beginControlEdit(),
          onChanged: (v) => app.setDeviceScale(widget.device, v),
          onChangeEnd: (_) => app.endControlEdit(),
        ),
        if (def.isTimer) ...[
          const SizedBox(height: 16),
          const SectionLabel('Waktu tunda (detik)'),
          TextField(key: const ValueKey('time-field'), controller: _time, focusNode: _timeFocus, style: uiText(13, tokens.text), keyboardType: TextInputType.number, onSubmitted: (_) => _applyTime()),
        ],
        if (def.kind == 'plc') ...[
          const SizedBox(height: 14),
          FilledButton(key: const ValueKey('open-ladder'), onPressed: () => showPlcEditor(context, app, widget.device), child: const Text('Buka editor ladder')),
        ],
        if (def.kind == 'hmi') ...[
          const SizedBox(height: 14),
          FilledButton(key: const ValueKey('open-hmi-editor'), onPressed: () => showHmiEditor(context, app, widget.device), child: const Text('Atur layar HMI')),
        ],
        if (def.controls.isNotEmpty) ...[
          const SizedBox(height: 16),
          const SectionLabel('Pengaturan'),
          for (final control in def.controls) ControlSlider(app: app, device: widget.device, control: control),
        ],
        if (def.ratings.isNotEmpty) ...[
          const SizedBox(height: 18),
          const SectionLabel('Spesifikasi'),
          for (final entry in def.ratings.entries)
            Padding(padding: const EdgeInsets.only(bottom: 5), child: Text(ratingLabel(entry.key, entry.value), style: uiText(13, tokens.text))),
          const SizedBox(height: 4),
          Text('Data contoh, bukan produk tertentu.', style: uiText(12, tokens.textMuted)),
        ],
        if (def.isSymbol) ...[
          const SizedBox(height: 16),
          Text('Simbol gambar, tidak ikut simulasi.', style: uiText(13, tokens.text, height: 1.4)),
          const SizedBox(height: 6),
          Text('Sumber: ${def.source}, lisensi ${def.license}.', style: uiText(12, tokens.textMuted, height: 1.4)),
        ],
        if (def.terminals.isNotEmpty) ...[
          const SizedBox(height: 18),
          const SectionLabel('Terminal'),
          Text(def.terminals.map((t) => t.id).join(', '), style: uiText(13, tokens.text)),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(child: OutlinedButton(onPressed: app.duplicateSelection, child: Text('Duplikat', style: uiText(13, tokens.text, weight: 500)))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(onPressed: app.deleteSelection, child: Text('Hapus', style: uiText(13, tokens.error, weight: 500)))),
          ],
        ),
      ],
    );
  }
}

class _WireProperties extends StatefulWidget {
  const _WireProperties({super.key, required this.app, required this.wire});

  final AppState app;
  final Wire wire;

  @override
  State<_WireProperties> createState() => _WirePropertiesState();
}

class _WirePropertiesState extends State<_WireProperties> {
  late final TextEditingController _number = TextEditingController(text: widget.wire.number);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.app.setWireNumber(widget.wire, _number.text);
    });
  }

  @override
  void dispose() {
    _number.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final app = widget.app;
    final wire = widget.wire;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(wire.isJumper ? 'Jumper' : 'Kabel', style: uiText(15, tokens.text, weight: 600)),
        const SizedBox(height: 6),
        Text('${app.tagOf(wire.a.deviceId)} ${wire.a.terminal} ke ${app.tagOf(wire.b.deviceId)} ${wire.b.terminal}', style: uiText(13, tokens.textMuted)),
        const SizedBox(height: 16),
        const SectionLabel('Jenis'),
        Row(
          children: [
            Expanded(child: _Tab(label: 'Kabel', active: !wire.isJumper, onTap: () => app.setWireJumper(wire, false))),
            const SizedBox(width: 4),
            Expanded(child: _Tab(label: 'Jumper', active: wire.isJumper, onTap: () => app.setWireJumper(wire, true))),
          ],
        ),
        if (!wire.isJumper) ...[
          const SizedBox(height: 16),
          const SectionLabel('Jalur'),
          Text(wire.points == null ? 'Otomatis. Seret kotak kecil di kabel untuk mengubahnya.' : 'Diatur manual.', style: uiText(13, tokens.text, height: 1.4)),
          if (wire.points != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => app.resetWireRoute(wire), child: Text('Rapikan otomatis', style: uiText(13, tokens.text, weight: 500))),
          ],
        ],
        const SizedBox(height: 16),
        const SectionLabel('Nomor kabel'),
        TextField(controller: _number, focusNode: _focus, style: uiText(13, tokens.text), onSubmitted: (value) => app.setWireNumber(wire, value)),
        const SizedBox(height: 16),
        const SectionLabel('Penampang'),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final gauge in kWireGauges)
              SizedBox(
                width: 54,
                child: _Tab(label: '${gauge == gauge.roundToDouble() ? gauge.toInt() : gauge}', active: wire.gauge == gauge, onTap: () => app.setWireGauge(wire, gauge)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text('Satuan mm².', style: uiText(12, tokens.textMuted)),
        const SizedBox(height: 16),
        const SectionLabel('Warna'),
        for (final (color, name) in kWireColors)
          InkWell(
            borderRadius: BorderRadius.circular(Radii.control),
            onTap: () => app.setWireColor(wire, color),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              decoration: BoxDecoration(color: wire.color == color ? tokens.accentSoft : Colors.transparent, borderRadius: BorderRadius.circular(Radii.control)),
              child: Row(
                children: [
                  Container(width: 22, height: 4, decoration: BoxDecoration(color: Color(color), borderRadius: BorderRadius.circular(Radii.plate))),
                  const SizedBox(width: 10),
                  Expanded(child: Text(name, style: uiText(13, tokens.text))),
                ],
              ),
            ),
          ),
        const SizedBox(height: 16),
        OutlinedButton(onPressed: app.deleteSelection, child: Text(wire.isJumper ? 'Hapus jumper' : 'Hapus kabel', style: uiText(13, tokens.error, weight: 500))),
      ],
    );
  }
}

const Map<WarningCode, String> kWarningText = {
  WarningCode.overvoltage: 'Tegangan melebihi rating. Lebih dari 15% di atas rating, alat akan panas lalu meledak.',
  WarningCode.wrongSupply: 'Jenis sumber tidak cocok (AC atau DC). Bisa merusak alat.',
  WarningCode.undervoltage: 'Tegangan di bawah rating, tidak bekerja.',
  WarningCode.singlePhasing: 'Hanya dapat sebagian fasa, motor tidak jalan.',
  WarningCode.motorUnconnected: 'Terminal motor belum dijumper star atau delta.',
  WarningCode.motorNoEarth: 'Motor berjalan tanpa arde (PE).',
  WarningCode.wrongFrequency: 'Frekuensi di luar 45–65 Hz. Kumparan atau motor bisa panas lalu meledak.',
};

class _SimulationSummary extends StatelessWidget {
  const _SimulationSummary({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final warnings = app.simResult?.warnings ?? const <SimWarning>[];
    final shown = app.project.devices.where((d) => app.defOf(d).isSimulated && app.defOf(d).kind != 'passive');
    final hints = {
      for (final device in app.project.devices)
        if (app.defOf(device).operateHint != null) app.defOf(device).name: app.defOf(device).operateHint!,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (warnings.isNotEmpty) ...[
          const SectionLabel('Peringatan'),
          for (final warning in warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Text('${app.tagOf(warning.deviceId)}: ${kWarningText[warning.code]}', style: uiText(13, tokens.warning, weight: 500, height: 1.35)),
            ),
          const SizedBox(height: 10),
        ],
        const SectionLabel('Kondisi perangkat'),
        for (final device in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(width: 56, child: Text(device.tag, overflow: TextOverflow.ellipsis, style: uiText(13, tokens.text, weight: 600))),
                Expanded(child: Text(_stateText(device), style: uiText(13, _stateColor(tokens, app.stateOf(device).split(':').first)))),
              ],
            ),
          ),
        const SizedBox(height: 16),
        const SectionLabel('Cara mengoperasikan'),
        Text('Klik MCB dan selektor untuk mengubah posisinya. Tahan tombol tekan untuk menekannya.', style: uiText(13, tokens.text, height: 1.4)),
        for (final entry in hints.entries)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text('${entry.key}: ${entry.value}', style: uiText(13, tokens.textMuted, height: 1.4))),
        const SizedBox(height: 16),
        const SectionLabel('Warna saat simulasi'),
        for (final entry in kLiveColors.entries) _Legend(color: entry.value, label: entry.key),
        _Legend(color: tokens.deadWire, label: 'Tidak bertegangan'),
      ],
    );
  }

  String _stateText(PlacedDevice device) {
    final state = app.stateOf(device).split(':').first;
    final remaining = app.timerRemaining(device);
    final name = kStateNames[state] ?? state;
    return remaining == null ? name : '$name (${remaining.toStringAsFixed(1).replaceAll('.', ',')} dtk)';
  }

  Color _stateColor(Tokens tokens, String state) => switch (state) {
        'on' || 'closed' || 'pressed' || 'run' || 'run_fwd' || 'run_rev' => tokens.run,
        'tripped' || 'latched' || 'exploded' => tokens.error,
        'timing' || 'timing_off' => tokens.warning,
        _ => tokens.textMuted,
      };
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Container(width: 22, height: 4, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(Radii.plate))),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: uiText(13, context.tokens.text))),
          ],
        ),
      );
}
