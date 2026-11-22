import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../model/project.dart';
import '../sim/plc.dart';
import 'panels.dart';
import 'theme.dart';

Future<void> showScada(BuildContext context, AppState app) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => ListenableBuilder(listenable: app, builder: (context, _) => _ScadaDialog(app: app)),
  );
}

class _ScadaDialog extends StatelessWidget {
  const _ScadaDialog({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final result = app.simResult;
    final monitored = app.project.devices.where((d) {
      final kind = app.defOf(d).kind;
      return kind == 'motor3' || kind == 'load' || kind == 'source' || app.defOf(d).thermal != null || kind == 'plc';
    }).toList();
    final plcs = app.project.devices.where((d) => app.defOf(d).kind == 'plc').toList();
    return AlertDialog(
      backgroundColor: tokens.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      contentPadding: const EdgeInsets.all(20),
      title: Row(
        children: [
          Text('SCADA', style: uiText(17, tokens.text, weight: 700)),
          const SizedBox(width: 10),
          Text(app.project.name, style: uiText(13, tokens.textMuted)),
          const Spacer(),
          _Tile(label: 'Daya total', value: '${(app.totalWatts / 1000).toStringAsFixed(2)} kW'),
          const SizedBox(width: 8),
          _Tile(label: 'Peringatan', value: '${result?.warnings.length ?? 0}'),
          const SizedBox(width: 8),
          IconButton(tooltip: 'Tutup', onPressed: () => Navigator.of(context).pop(), icon: Icon(Icons.close, color: tokens.textMuted)),
        ],
      ),
      content: SizedBox(
        width: 980,
        height: 560,
        child: !app.running
            ? Center(child: Text('Jalankan simulasi untuk melihat data langsung.', style: uiText(14, tokens.textMuted)))
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionLabel('Tren daya'),
                        Container(
                          height: 170,
                          decoration: BoxDecoration(border: Border.all(color: tokens.border), borderRadius: BorderRadius.circular(Radii.control)),
                          child: ClipRRect(borderRadius: BorderRadius.circular(Radii.control), child: CustomPaint(painter: _TrendPainter(app.history, tokens))),
                        ),
                        const SizedBox(height: 14),
                        const SectionLabel('Perangkat'),
                        Expanded(
                          child: ListView(
                            children: [
                              _row(tokens, const ['Tag', 'Kondisi', 'V', 'A', 'kW'], header: true),
                              for (final device in monitored) _deviceRow(tokens, device),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    flex: 4,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionLabel('Tag PLC'),
                        Expanded(
                          flex: 3,
                          child: plcs.isEmpty
                              ? Text('Tidak ada PLC di proyek ini.', style: uiText(13, tokens.textMuted))
                              : ListView(children: [for (final plc in plcs) _PlcTags(app: app, plc: plc)]),
                        ),
                        const SizedBox(height: 12),
                        const SectionLabel('Catatan kejadian'),
                        Expanded(
                          flex: 2,
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(border: Border.all(color: tokens.border), borderRadius: BorderRadius.circular(Radii.control)),
                            child: ListView(
                              children: [
                                for (final event in app.events) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(event, style: uiText(12, tokens.text))),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _row(Tokens tokens, List<String> cells, {bool header = false, Color? stateColor}) {
    final style = uiText(12, header ? tokens.textMuted : tokens.text, weight: header ? 600 : 400);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 70, child: Text(cells[0], overflow: TextOverflow.ellipsis, style: style.copyWith(fontWeight: FontWeight.w600))),
          Expanded(child: Text(cells[1], overflow: TextOverflow.ellipsis, style: stateColor == null ? style : style.copyWith(color: stateColor))),
          for (final cell in cells.skip(2)) SizedBox(width: 62, child: Text(cell, textAlign: TextAlign.right, style: style)),
        ],
      ),
    );
  }

  Widget _deviceRow(Tokens tokens, PlacedDevice device) {
    final measure = app.shownMeasure(device);
    final state = app.stateOf(device);
    final base = state.split(':').first;
    final color = switch (base) {
      'tripped' || 'exploded' => tokens.error,
      'run' || 'on' || 'closed' || 'run_fwd' || 'run_rev' => tokens.run,
      _ => tokens.textMuted,
    };
    return _row(
      tokens,
      [
        device.tag,
        kStateNames[base] ?? base,
        measure.volts.toStringAsFixed(0),
        measure.amps.toStringAsFixed(2),
        (measure.watts / 1000).toStringAsFixed(2),
      ],
      stateColor: color,
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: tokens.hover, borderRadius: BorderRadius.circular(Radii.control)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: uiText(10, tokens.textMuted)),
          Text(value, style: uiText(14, tokens.text, weight: 700)),
        ],
      ),
    );
  }
}

class _PlcTags extends StatelessWidget {
  const _PlcTags({required this.app, required this.plc});

  final AppState app;
  final PlacedDevice plc;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final bits = app.bitsOf(plc);
    Widget lamp(String ref) => Container(
          width: 40,
          margin: const EdgeInsets.only(right: 4, bottom: 4),
          padding: const EdgeInsets.symmetric(vertical: 3),
          alignment: Alignment.center,
          decoration: BoxDecoration(color: bits.contains(ref) ? tokens.run : tokens.hover, borderRadius: BorderRadius.circular(Radii.control)),
          child: Text(ref, style: uiText(11, bits.contains(ref) ? Colors.white : tokens.textMuted, weight: 600)),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(plc.tag, style: uiText(13, tokens.text, weight: 600)),
        const SizedBox(height: 6),
        Wrap(children: [for (final ref in kPlcInputs) lamp(ref)]),
        Wrap(children: [for (final ref in kPlcOutputs) lamp(ref)]),
        const SizedBox(height: 4),
        Text('Klik M untuk menulis dari SCADA.', style: uiText(11, tokens.textMuted)),
        const SizedBox(height: 4),
        Wrap(
          children: [
            for (final ref in kPlcMemory)
              InkWell(
                onTap: () => app.setPlcBit(plc, ref, !app.plcBitForced(plc, ref)),
                child: lamp(ref),
              ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter(this.history, this.tokens);

  final List<TrendPoint> history;
  final Tokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = tokens.border
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    if (history.length < 2) return;
    final peak = math.max(100.0, history.map((p) => p.watts).reduce(math.max) * 1.15);
    final start = history.first.seconds;
    final span = math.max(1.0, history.last.seconds - start);
    final path = Path();
    for (var i = 0; i < history.length; i++) {
      final point = history[i];
      final x = (point.seconds - start) / span * size.width;
      final y = size.height - point.watts / peak * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = tokens.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    (TextPainter(text: TextSpan(text: '${(peak / 1000).toStringAsFixed(2)} kW', style: uiText(10, tokens.textMuted)), textDirection: TextDirection.ltr)..layout()).paint(canvas, const Offset(6, 4));
  }

  @override
  bool shouldRepaint(_TrendPainter old) => true;
}
