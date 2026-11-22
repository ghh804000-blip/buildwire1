import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../app_state.dart';
import '../model/device_def.dart';
import '../model/project.dart';
import '../sim/ladder.dart';
import '../sim/plc.dart';
import '../sim/solver.dart';
import 'templates_dialog.dart';
import 'theme.dart';

/// Wire colors during simulation, shared with the legend in the side panel.
const Map<String, Color> kLiveColors = {
  'L1': Color(0xFFC2410C),
  'L2': Color(0xFF7C3AED),
  'L3': Color(0xFF0E7490),
  'N': Color(0xFF1D6FB8),
  'PE': Color(0xFF2E8B3D),
  'DC+': Color(0xFFD92D20),
  'DC-': Color(0xFF344054),
};

const double kRuler = 22;

class CanvasView extends StatefulWidget {
  const CanvasView({super.key, required this.app, required this.focusNode, required this.captureKey});

  final AppState app;
  final FocusNode focusNode;
  final GlobalKey captureKey;

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends State<CanvasView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onFrame);
  Duration _last = Duration.zero;

  AppState get app => widget.app;
  FocusNode get focusNode => widget.focusNode;
  GlobalKey get captureKey => widget.captureKey;

  void _onFrame(Duration elapsed) {
    final seconds = (elapsed - _last).inMicroseconds / 1000000;
    _last = elapsed;
    if (seconds > 0 && seconds < 0.5) app.animate(seconds);
  }

  void _syncTicker() {
    if (app.running && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!app.running && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    WireCache.clear();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncTicker();
    // Camera moves rebuild just the canvas.
    return ValueListenableBuilder<int>(valueListenable: app.viewVersion, builder: (context, _, _) => _canvas(context));
  }

  Widget _canvas(BuildContext context) {
    final tokens = context.tokens;
    final seatedContactors = <int>{
      for (final d in app.project.devices)
        if (d.data['seated_on'] is num) (d.data['seated_on'] as num).toInt(),
    };
    final ordered = [
      for (final rank in const [0, 1]) ...app.project.devices.where((d) => app.defOf(d).layerRank == rank),
      // Overload relays plugged under a contactor go behind it, so their pins and clips are hidden by it.
      ...app.project.devices.where(app.isSeated),
      ...app.project.devices.where((d) => app.defOf(d).layerRank == 2 && !app.isSeated(d)),
    ];
    final wire = app.selectedWireObject;
    return LayoutBuilder(
      builder: (context, constraints) {
        app.canvasSize = constraints.biggest;
        return DragTarget<String>(
          onAcceptWithDetails: (details) {
            final box = context.findRenderObject()! as RenderBox;
            app.addDevice(details.data, world: app.toWorld(box.globalToLocal(details.offset)));
          },
          builder: (context, candidates, rejected) => ClipRect(
            child: Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  app.zoomAt(event.localPosition, event.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1);
                }
              },
              child: MouseRegion(
                cursor: app.tool == CanvasTool.pan ? SystemMouseCursors.grab : MouseCursor.defer,
                onHover: (event) => app.setPointer(event.localPosition),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (details) {
                    focusNode.requestFocus();
                    final tapped = app.running ? null : app.wireAt(details.localPosition);
                    if (tapped != null && app.pending != null) {
                      // Connecting to the middle of a wire branches off it.
                      app.branchToWire(tapped, details.localPosition);
                    } else if (app.pending != null) {
                      // Drawing a wire: a click on empty canvas fixes a bend there.
                      app.addPendingCorner(details.localPosition);
                    } else {
                      tapped == null ? app.clearSelection() : app.selectWire(tapped.id);
                    }
                  },
                  // Right-click while drawing a wire drops it.
                  onSecondaryTapUp: (_) => app.cancelPending(),
                  onPanStart: (details) {
                    final selecting = app.tool == CanvasTool.select && !app.running;
                    if (selecting && !HardwareKeyboard.instance.isControlPressed) app.beginBox(details.localPosition);
                  },
                  onPanUpdate: (details) {
                    if (app.selectionBox != null) {
                      app.updateBox(details.localPosition);
                    } else {
                      app.panBy(details.delta);
                    }
                  },
                  onPanEnd: (_) => app.endBox(),
                  onPanCancel: app.endBox,
                  child: RepaintBoundary(
                    key: captureKey,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CustomPaint(painter: _GridPainter(app.pan, app.zoom, tokens)),
                        for (final device in ordered) _DeviceView(key: ValueKey('view-${device.id}'), app: app, device: device, focusNode: focusNode),
                        IgnorePointer(child: CustomPaint(painter: _WirePainter(app, tokens, MediaQuery.devicePixelRatioOf(context)))),
                        if (app.running) IgnorePointer(child: CustomPaint(painter: _LivePainter(app, tokens))),
                        if (!app.running) IgnorePointer(child: CustomPaint(painter: _StaticPartsPainter(app))),
                        for (final device in ordered)
                          if (!app.defOf(device).isBackLayer && !app.defOf(device).isJunction)
                            _TagLabel(app: app, device: device, above: seatedContactors.contains(device.id)),
                        for (final device in ordered)
                          if (app.defOf(device).meter != null) _MeterDisplay(app: app, device: device),
                        for (final device in ordered)
                          if (app.defOf(device).torPanel != null) _TorPanelView(key: ValueKey('tor-${device.id}'), app: app, device: device),
                        for (final device in ordered)
                          if (app.defOf(device).knob != null) _KnobView(key: ValueKey('knob-${device.id}'), app: app, device: device),
                        for (final device in ordered)
                          if (app.defOf(device).panel != null) _PlcPanelView(key: ValueKey('panel-${device.id}'), app: app, device: device),
                        for (final device in ordered)
                          if (app.defOf(device).timerPanel != null) _TimerPanelView(key: ValueKey('timer-panel-${device.id}'), app: app, device: device),
                        if (app.running)
                          for (final device in ordered)
                            if (app.defOf(device).isTimer && app.defOf(device).timerPanel == null) _TimerBadge(app: app, device: device),
                        if (app.running)
                          for (final device in ordered)
                            if (app.defOf(device).behavior['phases'] != null) _PhaseDots(app: app, device: device),
                        for (final device in ordered)
                          if (app.defOf(device).kind == 'hmi') _HmiScreen(app: app, device: device),
                        if (!app.running)
                          for (final device in ordered)
                            for (final terminal in app.defOf(device).terminals)
                              if (!app.isTerminalCovered(device, terminal.id)) _TerminalDot(app: app, ref: TerminalRef(device.id, terminal.id), tag: device.tag),
                        if (!app.running && wire != null && !wire.isJumper) ..._segmentHandles(wire),
                        if (!app.running && app.tool == CanvasTool.select && app.singleSelection != null)
                          _ResizeHandle(key: ValueKey('resize-${app.singleSelection!.id}'), app: app, device: app.singleSelection!),
                        if (app.selectionBox != null)
                          Positioned.fromRect(
                            rect: app.selectionBox!,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(color: tokens.accent.withValues(alpha: 0.08), border: Border.all(color: tokens.accent)),
                              ),
                            ),
                          ),
                        IgnorePointer(child: CustomPaint(painter: _RulerPainter(app.pan, app.zoom, tokens))),
                        if (app.project.isEmpty) _EmptyState(app: app),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _segmentHandles(Wire wire) {
    final points = app.wirePoints(wire);
    return [
      for (var i = 0; i < points.length - 1; i++)
        if ((points[i] - points[i + 1]).distance > 16) _SegmentHandle(app: app, wire: wire, index: i, a: points[i], b: points[i + 1]),
    ];
  }
}

class _SegmentHandle extends StatelessWidget {
  const _SegmentHandle({required this.app, required this.wire, required this.index, required this.a, required this.b});

  final AppState app;
  final Wire wire;
  final int index;
  final Offset a;
  final Offset b;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final center = (a + b) / 2;
    final horizontal = (a.dy - b.dy).abs() < 0.5;
    const hit = 22.0;
    return Positioned(
      left: center.dx - hit / 2,
      top: center.dy - hit / 2,
      width: hit,
      height: hit,
      child: Tooltip(
        message: 'Seret untuk mengatur jalur',
        child: MouseRegion(
          cursor: horizontal ? SystemMouseCursors.resizeUpDown : SystemMouseCursors.resizeLeftRight,
          child: GestureDetector(
            key: ValueKey('wire-handle-${wire.id}-$index'),
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => app.beginWireDrag(wire, index),
            onPanUpdate: (details) {
              final box = context.findAncestorRenderObjectOfType<RenderRepaintBoundary>()!;
              app.updateWireDrag(wire, app.toWorld(box.globalToLocal(details.globalPosition)));
            },
            onPanEnd: (_) => app.endWireDrag(),
            onPanCancel: app.endWireDrag,
            child: Center(
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(color: tokens.panel, border: Border.all(color: tokens.accent, width: 2), borderRadius: BorderRadius.circular(Radii.plate)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Kanvas masih kosong', style: uiText(16, tokens.text, weight: 600)),
          const SizedBox(height: 6),
          Text('Seret perangkat dari panel kiri, atau mulai dari rangkaian jadi.', style: uiText(13, tokens.textMuted)),
          const SizedBox(height: 14),
          OutlinedButton(
            key: const ValueKey('open-templates'),
            onPressed: () => showTemplatesDialog(context, app),
            child: Text('Pilih rangkaian jadi', style: uiText(13, tokens.accent, weight: 500)),
          ),
        ],
      ),
    );
  }
}

class _DeviceView extends StatefulWidget {
  const _DeviceView({super.key, required this.app, required this.device, required this.focusNode});

  final AppState app;
  final PlacedDevice device;
  final FocusNode focusNode;

  @override
  State<_DeviceView> createState() => _DeviceViewState();
}

class _DeviceViewState extends State<_DeviceView> {
  Offset _moved = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final device = widget.device;
    final tokens = context.tokens;
    final def = app.defOf(device);
    final position = app.toScreen(Offset(device.x, device.y));
    final width = def.width * app.zoom;
    final height = def.height * app.zoom;
    final selected = app.isSelected(device.id);
    final operable = app.running && (def.isClickable || def.isHold);

    return Positioned(
      left: position.dx,
      top: position.dy,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: app.running ? (operable ? SystemMouseCursors.click : SystemMouseCursors.basic) : SystemMouseCursors.move,
        child: _gestures(
          app: app,
          def: def,
          child: Container(
            key: ValueKey('device-${device.tag}'),
            foregroundDecoration: selected ? BoxDecoration(border: Border.all(color: tokens.accent, width: 2), borderRadius: BorderRadius.circular(Radii.control)) : null,
            child: _scorch(
              app.stateOf(device) == 'exploded',
              def.isRaster
                  ? Image.asset(def.assetFor(app.stateOf(device)), fit: BoxFit.fill, width: width, height: height)
                  : SvgPicture.asset(def.assetFor(app.stateOf(device)), fit: BoxFit.fill, width: width, height: height),
            ),
          ),
        ),
      ),
    );
  }

  /// An exploded part is burnt nearly black. The color filter only touches the part's own pixels, so its
  /// transparent surroundings stay clear.
  static Widget _scorch(bool burnt, Widget art) {
    if (!burnt) return art;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix([
        0.26, 0.04, 0.02, 0, 14, //
        0.03, 0.2, 0.02, 0, 8, //
        0.02, 0.02, 0.16, 0, 4, //
        0, 0, 0, 1, 0,
      ]),
      child: art,
    );
  }

  Widget _gestures({required AppState app, required DeviceDef def, required Widget child}) {
    final device = widget.device;
    if (app.running) {
      if (def.isHold) {
        // Listener reacts on pointer down with no gesture-arena delay; the empty pan handler stops the canvas panning.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (_) {},
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) {
              app.inspect(device);
              app.pressDevice(device, true);
            },
            onPointerUp: (_) => app.pressDevice(device, false),
            onPointerCancel: (_) => app.pressDevice(device, false),
            child: child,
          ),
        );
      }
      if (def.isBackLayer) return child;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          app.inspect(device);
          app.clickDevice(device);
        },
        child: child,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        widget.focusNode.requestFocus();
        // Wires are drawn over parts, so a click on a wire (a jumper between two terminals of this part, or a wire
        // passing over it) picks the wire; anywhere else on the part picks the part.
        final onCanvas = app.toScreen(Offset(device.x, device.y)) + details.localPosition;
        // While drawing a wire, a click on a part (not on a terminal) is a bend, as on empty canvas.
        if (app.pending != null) {
          app.addPendingCorner(onCanvas);
          return;
        }
        // A tighter reach than on the open canvas, so clicking the part next to one of its own wires still picks the part.
        final wire = app.wireAt(onCanvas, tolerance: 5);
        if (wire != null) {
          app.selectWire(wire.id);
        } else {
          app.selectDevice(device.id, additive: HardwareKeyboard.instance.isShiftPressed);
        }
      },
      onSecondaryTapUp: (_) => app.cancelPending(),
      onPanStart: (_) {
        widget.focusNode.requestFocus();
        app.beginMove(device.id);
        _moved = Offset.zero;
      },
      onPanUpdate: (details) {
        _moved += details.delta / app.zoom;
        app.moveSelectionBy(_moved);
      },
      onPanEnd: (_) => app.endMove(),
      onPanCancel: app.endMove,
      child: child,
    );
  }
}

/// Drawn above the wires with a canvas-colored backing so a wire passing under it can't make the tag unreadable.
class _TagLabel extends StatelessWidget {
  const _TagLabel({required this.app, required this.device, this.above});

  final AppState app;
  final PlacedDevice device;
  final bool? above;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final def = app.defOf(device);
    // With an overload relay plugged underneath, the tag goes above the part instead of over the relay's front.
    final placeAbove = above ?? app.hasSeatedOverload(device);
    final position = app.toScreen(Offset(device.x, placeAbove ? device.y : device.y + def.height));
    final selected = app.isSelected(device.id);
    return Positioned(
      left: position.dx - 20,
      top: placeAbove ? position.dy - 24 * app.zoom.clamp(0.6, 1.4) : position.dy + 4 * app.zoom,
      width: def.width * app.zoom + 40,
      child: IgnorePointer(
        child: Center(
          child: DecoratedBox(
            // A marker label, the way tags are printed on the strip under each part in a real panel.
            decoration: BoxDecoration(
              color: tokens.panel,
              border: Border.all(color: selected ? tokens.accent : tokens.border, width: selected ? 1.5 : 1),
              borderRadius: BorderRadius.circular(Radii.plate),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: (5 * app.zoom).clamp(3.0, 8.0)),
              child: Text(device.tag, maxLines: 1, softWrap: false, style: plateText((15 * app.zoom).clamp(10.0, 24.0), selected ? tokens.accent : tokens.text, weight: 700, height: 1.25)),
            ),
          ),
        ),
      ),
    );
  }
}

String _number(double value) {
  final fixed = value.abs() >= 100 ? value.toStringAsFixed(1) : value.toStringAsFixed(value.abs() >= 10 ? 2 : 3);
  return fixed;
}

/// A digital screen with live values, or a needle on an analog dial.
class _MeterDisplay extends StatelessWidget {
  const _MeterDisplay({required this.app, required this.device});

  final AppState app;
  final PlacedDevice device;

  @override
  Widget build(BuildContext context) {
    final def = app.defOf(device);
    final meter = def.meter!;
    final origin = app.toScreen(Offset(device.x, device.y));
    final gauge = meter['gauge'] as Map<String, dynamic>?;
    if (gauge != null) {
      double value() {
        if (!app.running) return (gauge['min'] as num? ?? 0).toDouble();
        final now = app.shownMeasure(device);
        return gauge['value'] == 'Hz' ? now.hertz : now.volts;
      }

      final face = gauge['face'] as String?;
      return Positioned(
        left: origin.dx,
        top: origin.dy,
        width: def.width * app.zoom,
        height: def.height * app.zoom,
        child: IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The dial without its printed needle, so only the live needle shows.
              if (face != null) Image.asset('assets/devices/$face', fit: BoxFit.fill, filterQuality: FilterQuality.medium, gaplessPlayback: true),
              ListenableBuilder(
                listenable: app.animationFrame,
                builder: (context, _) => CustomPaint(painter: _NeedlePainter(value(), gauge)),
              ),
            ],
          ),
        ),
      );
    }
    final screens = def.meterScreens;
    if (screens.isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: origin.dx,
      top: origin.dy,
      width: def.width * app.zoom,
      height: def.height * app.zoom,
      child: IgnorePointer(
        child: ListenableBuilder(
          listenable: app.animationFrame,
          builder: (context, _) => LayoutBuilder(
            builder: (context, box) => Stack(
              children: [
                for (final screen in screens) _screen(screen, box.biggest),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _screen(Map<String, dynamic> screen, Size size) {
    final rect = (screen['rect'] as List<dynamic>).cast<num>();
    final style = screen['style'] as String? ?? 'lcd';
    final measure = app.running ? app.shownMeasure(device) : const Measure();
    final isPlc = style == 'plc';
    final bits = app.bitsOf(device);
    final powered = isPlc ? app.running && app.stateOf(device).startsWith('run') : measure.volts > 1;
    final lit = _color(screen['bg']) ?? const Color(0xFFC4D9EA);
    final ink = _color(screen['fg']) ?? const Color(0xFF14202C);
    // Unlit screens are drawn too, so the photo's sample digits never show through.
    final background = powered ? lit : _color(screen['off']) ?? Color.lerp(lit, const Color(0xFF39434A), style == 'seg' || style == 'tft' ? 0.9 : 0.55)!;
    final lines = (screen['lines'] as List<dynamic>? ?? const ['V']).cast<String>();
    final showUnits = style != 'seg';
    final rows = !powered
        ? const <List<String>>[]
        : isPlc
            ? [
                ['RUN'],
                ['I ${List.generate(8, (i) => bits.contains('I${i + 1}') ? '${i + 1}' : '·').join()}'],
                ['Q ${List.generate(4, (i) => bits.contains('Q${i + 1}') ? '${i + 1}' : '·').join()}'],
              ]
            : [
                for (final line in lines) [for (final field in line.split('|')) _field(field, measure, showUnits)],
              ];
    final weight = style == 'seg' ? 700 : 600;
    return Positioned(
      left: rect[0] * size.width,
      top: rect[1] * size.height,
      width: rect[2] * size.width,
      height: rect[3] * size.height,
      child: Container(
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(size.width * 0.008)),
        padding: EdgeInsets.symmetric(horizontal: rect[2] * size.width * 0.05, vertical: rect[3] * size.height * 0.04),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final row in rows)
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: isPlc ? Alignment.centerLeft : Alignment.centerRight,
                  child: Text(
                    row.join('   '),
                    maxLines: 1,
                    style: uiText(40, ink, weight: weight).copyWith(fontFeatures: const [FontFeature.tabularFigures()], height: 1),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _field(String field, Measure measure, bool units) {
    String unit(String text) => units ? ' $text' : '';
    if (field.startsWith('V:')) {
      final volts = app.simResult?.channels[device.id]?[field.substring(2)] ?? 0;
      return '${volts.toStringAsFixed(volts >= 100 ? 0 : 1)}${unit('V')}';
    }
    return switch (field) {
      'V' => '${measure.volts.toStringAsFixed(1)}${unit('V')}',
      'A' => '${_number(measure.amps)}${unit('A')}',
      'kA' => '${(measure.amps / 1000).toStringAsFixed(2)}${unit('kA')}',
      'kW' => '${(measure.watts / 1000).toStringAsFixed(3)}${unit('kW')}',
      'kWh' => '${app.energyOf(device).toStringAsFixed(4)}${unit('kWh')}',
      'Hz' => '${measure.hertz.toStringAsFixed(1)}${unit('Hz')}',
      _ => field,
    };
  }

  static Color? _color(Object? hex) {
    if (hex is! String) return null;
    return Color(int.parse(hex.replaceFirst('#', 'FF'), radix: 16));
  }
}

/// A needle on an analog dial. The dial's own scale maps values to angles (degrees, counter-clockwise from 3 o'clock).
class _NeedlePainter extends CustomPainter {
  const _NeedlePainter(this.value, this.gauge);

  final double value;
  final Map<String, dynamic> gauge;

  double get _angle {
    final points = (gauge['scale'] as List<dynamic>? ?? const []).map((p) => (p as List<dynamic>).cast<num>()).toList();
    if (points.isEmpty) {
      final min = (gauge['min'] as num? ?? 0).toDouble();
      final max = (gauge['max'] as num).toDouble();
      final t = ((value - min) / (max - min)).clamp(0.0, 1.0);
      return 210 - 240 * t;
    }
    if (value <= points.first[0]) return points.first[1].toDouble();
    for (var i = 1; i < points.length; i++) {
      if (value <= points[i][0]) {
        final t = (value - points[i - 1][0]) / (points[i][0] - points[i - 1][0]);
        return points[i - 1][1] + (points[i][1] - points[i - 1][1]) * t;
      }
    }
    return points.last[1].toDouble();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pivot = (gauge['pivot'] as List<dynamic>?)?.cast<num>();
    final center = pivot == null ? Offset(size.width * 0.5, size.height * 0.5) : Offset(pivot[0] * size.width, pivot[1] * size.height);
    final length = size.width * ((gauge['length'] as num?)?.toDouble() ?? 0.36);
    final angle = _angle * math.pi / 180;
    final tip = center + Offset(math.cos(angle), -math.sin(angle)) * length;
    final needle = gauge['needle'];
    final color = needle is String ? Color(int.parse(needle.replaceFirst('#', 'FF'), radix: 16)) : const Color(0xFF1C1C1C);
    final width = math.max(1.2, size.width * 0.009);
    // A soft shadow lifts the needle off the dial.
    canvas.drawLine(center + const Offset(1.5, 2), tip + const Offset(1.5, 2), Paint()
      ..color = const Color(0x33000000)
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round);
    canvas.drawLine(center, tip, Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round);
    if (gauge['hub'] != false) canvas.drawCircle(center, size.width * 0.022, Paint()..color = const Color(0xFF23292E));
  }

  @override
  bool shouldRepaint(_NeedlePainter old) => old.value != value;
}

/// A PLC's own screen and keypad. During simulation the keys can be pressed: they step through the I/O screens,
/// open the Stop and Set Param menus, and on the cursor-key screen act as program inputs C1-C4.
class _PlcPanelView extends StatelessWidget {
  const _PlcPanelView({super.key, required this.app, required this.device});

  final AppState app;
  final PlacedDevice device;

  @override
  Widget build(BuildContext context) {
    final def = app.defOf(device);
    final panel = def.panel!;
    final origin = app.toScreen(Offset(device.x, device.y));
    final size = Size(def.width * app.zoom, def.height * app.zoom);
    final keys = (panel['keys'] as Map<String, dynamic>? ?? const {}).cast<String, dynamic>();
    final held = app.plcPanel(device).held;
    Rect rectOf(Object? value) {
      final r = (value as List<dynamic>).cast<num>();
      return Rect.fromLTWH(r[0] * size.width, r[1] * size.height, r[2] * size.width, r[3] * size.height);
    }

    return Positioned(
      left: origin.dx,
      top: origin.dy,
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: rectOf(panel['lcd']),
            child: IgnorePointer(
              child: ListenableBuilder(
                listenable: app.animationFrame,
                builder: (context, _) => _PlcScreen(app: app, device: device, panel: panel),
              ),
            ),
          ),
          // Keys only take presses while the simulation runs, so the PLC can still be dragged when editing.
          if (app.running)
            for (final entry in keys.entries)
              Positioned.fromRect(
                rect: rectOf(entry.value),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (_) {},
                    child: Listener(
                      key: ValueKey('plc-key-${entry.key}'),
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (_) {
                        app.inspect(device);
                        app.plcKey(device, entry.key, true);
                      },
                      onPointerUp: (_) => app.plcKey(device, entry.key, false),
                      onPointerCancel: (_) => app.plcKey(device, entry.key, false),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 60),
                        decoration: BoxDecoration(
                          color: held.contains(entry.key) ? const Color(0x55000000) : Colors.transparent,
                          borderRadius: BorderRadius.circular(size.width * 0.012),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// A digital timer's front: a live 4-digit display, its OUT and RUN lights, and keys that set the time during
/// simulation. Idle it shows the setting; while timing it counts up to it; a digit being set blinks.
class _TimerPanelView extends StatelessWidget {
  const _TimerPanelView({super.key, required this.app, required this.device});

  final AppState app;
  final PlacedDevice device;

  @override
  Widget build(BuildContext context) {
    final def = app.defOf(device);
    final spec = def.timerPanel!;
    final origin = app.toScreen(Offset(device.x, device.y));
    final size = Size(def.width * app.zoom, def.height * app.zoom);
    final keys = (spec['keys'] as Map<String, dynamic>? ?? const {}).cast<String, dynamic>();
    final leds = (spec['leds'] as Map<String, dynamic>? ?? const {}).cast<String, dynamic>();
    final panel = app.timerPanel(device);
    Rect rectOf(Object? value) {
      final r = (value as List<dynamic>).cast<num>();
      return Rect.fromLTWH(r[0] * size.width, r[1] * size.height, r[2] * size.width, r[3] * size.height);
    }

    Color hex(Object? value, Color fallback) => value is String ? Color(int.parse(value.replaceFirst('#', 'FF'), radix: 16)) : fallback;
    final ink = hex(spec['fg'], const Color(0xFFFF2A1F));
    final glass = hex(spec['bg'], const Color(0xFF160606));

    return Positioned(
      left: origin.dx,
      top: origin.dy,
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: rectOf(spec['display']),
            child: IgnorePointer(
              child: ListenableBuilder(
                listenable: app.animationFrame,
                builder: (context, _) {
                  final state = app.stateOf(device);
                  final powered = app.running && (state == 'timing' || state == 'closed');
                  final elapsed = app.timerElapsed(device);
                  final editing = app.running && panel.editing;
                  final shown = editing || elapsed == null ? app.timeOf(device) : elapsed;
                  final blink = editing && (DateTime.now().millisecondsSinceEpoch ~/ 280).isOdd ? panel.digit : null;
                  return CustomPaint(
                    key: ValueKey('timer-display-${device.tag}'),
                    painter: _SevenSegPainter(
                      text: (shown.clamp(0, 999.9) * 10).round().toString().padLeft(4, '0'),
                      point: 2,
                      ink: ink,
                      glass: glass,
                      // Unpowered it still shows the setting, dimmed, so the time can be read before starting.
                      level: powered || editing ? 1 : 0.38,
                      hidden: blink,
                    ),
                  );
                },
              ),
            ),
          ),
          for (final entry in leds.entries)
            Positioned.fromRect(
              rect: rectOf((entry.value as List<dynamic>).sublist(0, 4)),
              child: IgnorePointer(
                child: Builder(builder: (context) {
                  final state = app.stateOf(device);
                  final on = app.running && (entry.key == 'out' ? state == 'closed' : state == 'timing');
                  final color = hex((entry.value as List<dynamic>)[4], ink);
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: on ? color : const Color(0xFF3B3D40),
                      borderRadius: BorderRadius.circular(size.width * 0.006),
                      boxShadow: on ? [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: size.width * 0.03)] : null,
                    ),
                  );
                }),
              ),
            ),
          // Like the PLC, keys only take presses during simulation, so the timer can still be dragged when editing.
          if (app.running)
            for (final entry in keys.entries)
              Positioned.fromRect(
                rect: rectOf(entry.value),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (_) {},
                    child: Listener(
                      key: ValueKey('timer-key-${device.tag}-${entry.key}'),
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (_) {
                        app.inspect(device);
                        app.timerKey(device, entry.key, true);
                      },
                      onPointerUp: (_) => app.timerKey(device, entry.key, false),
                      onPointerCancel: (_) => app.timerKey(device, entry.key, false),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 60),
                        decoration: BoxDecoration(
                          color: panel.held.contains(entry.key) ? const Color(0x66000000) : Colors.transparent,
                          borderRadius: BorderRadius.circular(size.width * 0.012),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// A seven-segment LED display: unlit segments faintly visible, lit ones glowing, with one decimal point.
class _SevenSegPainter extends CustomPainter {
  _SevenSegPainter({required this.text, required this.point, required this.ink, required this.glass, required this.level, this.hidden});

  final String text;

  /// The digit the decimal point follows.
  final int point;
  final Color ink;
  final Color glass;
  final double level;

  /// A digit left dark this frame, for blinking.
  final int? hidden;

  // Segments a-g per digit.
  static const _segments = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.height * 0.04)), Paint()..color = glass);
    final count = text.length;
    final padX = size.width * 0.05;
    final cell = (size.width - padX * 2) / count;
    final h = size.height * 0.74;
    final w = math.min(cell * 0.7, h * 0.55);
    final t = w * 0.17;
    final top = (size.height - h) / 2;
    final lit = ink.withValues(alpha: level);
    final unlit = ink.withValues(alpha: 0.07);
    final glow = Paint()
      ..color = ink.withValues(alpha: 0.45 * level)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, t * 0.8);

    for (var i = 0; i < count; i++) {
      final digit = int.tryParse(text[i]) ?? 0;
      final mask = i == hidden ? 0 : _segments[digit];
      final left = padX + cell * i + (cell - w) / 2 + w * 0.06;
      for (var s = 0; s < 7; s++) {
        final path = _segment(s, left, top, w, h, t);
        final on = mask & (1 << s) != 0;
        if (on) canvas.drawPath(path, glow);
        canvas.drawPath(path, Paint()..color = on ? lit : unlit);
      }
      if (i == point) {
        final dot = Offset(left + w + (cell - w) * 0.32, top + h - t * 0.5);
        canvas.drawCircle(dot, t * 0.62, glow);
        canvas.drawCircle(dot, t * 0.62, Paint()..color = lit);
      }
    }
  }

  /// One hexagonal segment. Digits lean slightly, like a real LED display.
  Path _segment(int s, double x, double y, double w, double h, double t) {
    final half = h / 2;
    final gap = t * 0.12;
    Offset p(double dx, double dy) => Offset(x + dx - (dy - half) * 0.08, y + dy);
    Path horizontal(double cy) => Path()
      ..addPolygon([
        p(t / 2 + gap, cy),
        p(t + gap, cy - t / 2),
        p(w - t - gap, cy - t / 2),
        p(w - t / 2 - gap, cy),
        p(w - t - gap, cy + t / 2),
        p(t + gap, cy + t / 2),
      ], true);
    Path vertical(double cx, double y0, double y1) => Path()
      ..addPolygon([
        p(cx, y0 + gap),
        p(cx + t / 2, y0 + t / 2 + gap),
        p(cx + t / 2, y1 - t / 2 - gap),
        p(cx, y1 - gap),
        p(cx - t / 2, y1 - t / 2 - gap),
        p(cx - t / 2, y0 + t / 2 + gap),
      ], true);
    return switch (s) {
      0 => horizontal(t / 2),
      1 => vertical(w - t / 2, t / 2, half),
      2 => vertical(w - t / 2, half, h - t / 2),
      3 => horizontal(h - t / 2),
      4 => vertical(t / 2, half, h - t / 2),
      5 => vertical(t / 2, t / 2, half),
      _ => horizontal(half),
    };
  }

  @override
  bool shouldRepaint(_SevenSegPainter old) =>
      old.text != text || old.level != level || old.hidden != hidden || old.ink != ink || old.glass != glass || old.point != point;
}

/// A dial timer's setting and countdown, shown above it during simulation. Clicking the timer turns the dial.
class _TimerBadge extends StatelessWidget {
  const _TimerBadge({required this.app, required this.device});

  final AppState app;
  final PlacedDevice device;

  @override
  Widget build(BuildContext context) {
    final def = app.defOf(device);
    final origin = app.toScreen(Offset(device.x, device.y));
    final width = def.width * app.zoom;
    return Positioned(
      left: origin.dx - 40,
      top: origin.dy - 30,
      width: width + 80,
      height: 24,
      child: IgnorePointer(
        child: Center(
          child: ListenableBuilder(
            listenable: app.animationFrame,
            builder: (context, _) {
              final elapsed = app.timerElapsed(device);
              final set = app.timeOf(device).toStringAsFixed(1);
              final counting = elapsed != null;
              final done = app.stateOf(device) == 'closed';
              return Container(
                key: ValueKey('timer-badge-${device.tag}'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xE6181B1E),
                  borderRadius: BorderRadius.circular(Radii.control),
                  border: Border.all(color: done ? const Color(0xFF3DDC84) : counting ? const Color(0xFFFFB020) : const Color(0xFF3B4046)),
                ),
                child: Text(
                  counting ? '${elapsed.toStringAsFixed(1)} / $set s' : '$set s',
                  style: uiText(11.5, Colors.white, weight: 600).copyWith(fontFeatures: const [FontFeature.tabularFigures()], height: 1.1),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The monochrome text screen of a small PLC: four lines, with lit bits shown inverted.
class _PlcScreen extends StatelessWidget {
  const _PlcScreen({required this.app, required this.device, required this.panel});

  final AppState app;
  final PlacedDevice device;
  final Map<String, dynamic> panel;

  static Color _hex(Object? value, Color fallback) => value is String ? Color(int.parse(value.replaceFirst('#', 'FF'), radix: 16)) : fallback;

  /// One screen line, as runs of text that are either plain or inverted.
  static List<(String, bool)> _plain(String text) => [(text, false)];

  List<List<(String, bool)>> _lines() {
    final state = app.plcPanel(device);
    final bits = app.bitsOf(device);
    final def = app.defOf(device);
    // One character per bit: the item's last letter or digit, inverted while on (Zelio: 1..9 A B C …).
    List<(String, bool)> bitRow(String label, List<String> refs) => [
          (label, false),
          for (final ref in refs) (ref.substring(ref.length - 1), bits.contains(ref)),
        ];
    final title = def.isZelio ? (def.name.split(' ').lastWhere((w) => w.startsWith('SR'), orElse: () => 'ZELIO')) : 'LOGO! 230RCE';
    final memory = def.isZelio ? ladderNames('M', 16) : kPlcMemory;
    List<(String, bool)> option(int index, String text) => _plain('${state.cursor == index ? '>' : ' '}$text');

    if (app.plcStopped(device) && state.menu == null) {
      return [_plain(title), _plain('  STOP'), _plain(''), _plain('>Start  [OK]')];
    }
    switch (state.menu) {
      case 'main':
        return [for (var i = 0; i < PlcPanel.mainItems.length; i++) option(i, PlcPanel.mainItems[i])];
      case 'clock':
        final hour = (state.clockMinute ~/ 60).toString().padLeft(2, '0');
        final minute = (state.clockMinute % 60).toString().padLeft(2, '0');
        return [
          _plain('Set Clock'),
          [('Hari ', false), (kPlcDays[state.clockDay - 1], state.cursor == 0)],
          [('Jam  ', false), (hour, state.cursor == 1), (':', false), (minute, state.cursor == 2)],
          _plain('◀▶ ▲▼  OK'),
        ];
      case 'confirm':
        return [_plain('Stop Prg?'), option(0, 'No'), option(1, 'Yes'), _plain('')];
      case 'params':
        final timers = app.plcTimerNames(device);
        final program = app.ladderOf(device);
        if (timers.isEmpty) return [_plain('Set Param'), _plain(''), _plain('Tidak ada'), _plain('timer (T)')];
        final first = (state.cursor - 2).clamp(0, (timers.length - 3).clamp(0, timers.length));
        return [
          _plain('Set Param'),
          for (var i = first; i < timers.length && i < first + 3; i++) option(i, '${timers[i]} ${program.timer(timers[i]).preset.toStringAsFixed(1)}s'),
        ];
      case 'edit':
        final coil = app.plcTimerNames(device)[state.cursor];
        return [_plain('Set Param $coil'), _plain(''), [('T =', false), (' ${state.editValue.toStringAsFixed(1)}s ', true)], _plain('▲▼  OK simpan')];
    }
    final page = PlcPanel.pages[state.page];
    switch (page) {
      case 'inputs':
        final ins = def.plcInputs;
        return [_plain('I:'), bitRow('', ins.take(10).toList()), ins.length > 10 ? bitRow('', ins.skip(10).toList()) : _plain(''), _plain('◀ ▶ layar')];
      case 'outputs':
        return [_plain('Q:'), bitRow('', def.plcOutputs), _plain(''), _plain('◀ ▶ layar')];
      case 'memory':
        return [_plain('M:'), bitRow('', memory.sublist(0, 8)), bitRow('', memory.sublist(8)), _plain('◀ ▶ layar')];
      case 'timers':
        final timers = app.plcTimerNames(device);
        final program = app.ladderOf(device);
        if (timers.isEmpty) return [_plain('Timer:'), _plain(''), _plain('Tidak ada'), _plain('timer (T)')];
        return [
          for (final name in timers.take(4))
            () {
              final preset = program.timer(name).preset;
              final done = app.plcTimerDone(device, name);
              final elapsed = app.plcTimerElapsed(device, name);
              final shown = (elapsed ?? (done ? preset : 0)).clamp(0, preset);
              return <(String, bool)>[('$name ${shown.toStringAsFixed(1)}/${preset.toStringAsFixed(1)}s', done)];
            }(),
        ];
      case 'clocks':
        final clocks = app.ladderOf(device).usedClocks;
        final now = app.plcClockOf(device);
        return [
          _plain('Jam: ${kPlcDays[now.weekday - 1]} ${clockText(now.hour * 60 + now.minute)}'),
          [('H ', false), for (final ref in ladderNames('H', 8)) (ref.substring(1), bits.contains(ref))],
          _plain(clocks.isEmpty ? 'Tidak ada H' : 'Dipakai: ${clocks.length}'),
          _plain('◀ ▶ layar'),
        ];
      case 'keys':
        final held = state.held;
        return [
          _plain('Tombol Z:'),
          [('▲Z1', held.contains('up')), (' ', false), ('▶Z2', held.contains('right'))],
          [('▼Z3', held.contains('down')), (' ', false), ('◀Z4', held.contains('left'))],
          _plain('ESC keluar'),
        ];
      default:
        // The real-time clock runs from this computer's clock, plus whatever was set with Set Clock.
        final now = app.plcClockOf(device);
        String two(int v) => v.toString().padLeft(2, '0');
        return [
          _plain(title),
          _plain('RUN ${two(now.hour)}:${two(now.minute)}:${two(now.second)}'),
          _plain('${kPlcDays[now.weekday - 1]} ${two(now.day)}.${two(now.month)}.${two(now.year % 100)}'),
          _plain('◀▶ ESC=menu'),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final powered = app.plcPowered(device);
    final lit = _hex(panel['bg'], const Color(0xFF9DC08B));
    final ink = _hex(panel['fg'], const Color(0xFF14240F));
    final background = powered ? lit : _hex(panel['off'], const Color(0xFF5F7466));
    return LayoutBuilder(
      builder: (context, box) {
        // Twelve characters across, four lines down, like the real screen.
        // Four lines of 1.2 line height plus the 8 % vertical padding always fit, on wide (LOGO) or short (Zelio) screens.
        final fontSize = math.min(box.maxWidth / 12 / 0.62, box.maxHeight * 0.9 / 4 / 1.25);
        final style = TextStyle(fontFamily: 'Consolas', fontFamilyFallback: const ['Courier New', 'Segoe UI Symbol', 'monospace'], fontSize: fontSize, height: 1.2, color: ink, fontWeight: FontWeight.w600);
        return Container(
          color: background,
          padding: EdgeInsets.symmetric(horizontal: box.maxWidth * 0.04, vertical: box.maxHeight * 0.04),
          child: !powered
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final line in _lines())
                      Text.rich(
                        TextSpan(children: [
                          for (final (text, inverted) in line)
                            TextSpan(text: text, style: inverted ? style.copyWith(color: lit, backgroundColor: ink) : null),
                        ]),
                        style: style,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        softWrap: false,
                      ),
                  ],
                ),
        );
      },
    );
  }
}


/// A pointer drawn on a round dial: [fraction] 0..1 of the way round a 270° sweep from bottom-left, clockwise.
class _DialPointerPainter extends CustomPainter {
  const _DialPointerPainter(this.centre, this.radius, this.fraction, this.color, {this.start = 225, this.sweep = 270});

  /// Where the scale starts (degrees, counter-clockwise from 3 o'clock) and how far it runs clockwise.
  final double start;
  final double sweep;

  final Offset centre;
  final double radius;
  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final angle = (start - sweep * fraction.clamp(0.0, 1.0)) * math.pi / 180;
    final tip = centre + Offset(math.cos(angle), -math.sin(angle)) * radius * 0.82;
    final width = math.max(2.0, radius * 0.12);
    canvas.drawLine(centre, tip, Paint()
      ..color = const Color(0xCC15191C)
      ..strokeWidth = width + 2.5
      ..strokeCap = StrokeCap.round);
    canvas.drawLine(centre, tip, Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round);
    canvas.drawCircle(centre, width * 0.9, Paint()..color = const Color(0xFF15191C));
  }

  @override
  bool shouldRepaint(_DialPointerPainter old) => old.fraction != fraction || old.centre != centre || old.radius != radius;
}

/// Turns a dial by dragging up/down or scrolling. Reports the new fraction of the range (0..1) while turning, and
/// once more when the turn ends.
class _DialHandle extends StatefulWidget {
  const _DialHandle({super.key, required this.fraction, required this.onTurn, required this.onDone, required this.tooltip, required this.label});

  final double fraction;
  final ValueChanged<double> onTurn;
  final VoidCallback onDone;
  final String tooltip;
  final String label;

  @override
  State<_DialHandle> createState() => _DialHandleState();
}

class _DialHandleState extends State<_DialHandle> {
  bool _active = false;
  double _start = 0;
  double _travel = 0;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _active = true),
      onExit: (_) => setState(() => _active = false),
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            GestureBinding.instance.pointerSignalResolver.register(event, (_) {
              widget.onTurn((widget.fraction + (event.scrollDelta.dy < 0 ? 0.04 : -0.04)).clamp(0.0, 1.0));
              widget.onDone();
            });
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) {
            _start = widget.fraction;
            _travel = 0;
          },
          // A drag of 150 px turns the dial from one end to the other; up turns it up.
          onPanUpdate: (details) {
            _travel -= details.delta.dy;
            widget.onTurn((_start + _travel / 150).clamp(0.0, 1.0));
          },
          onPanEnd: (_) => widget.onDone(),
          child: Tooltip(
            message: widget.tooltip,
            child: Align(
              alignment: Alignment.topCenter,
              child: _active
                  ? Container(
                      margin: const EdgeInsets.only(top: 2),
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: tokens.plate, borderRadius: BorderRadius.circular(Radii.plate)),
                      child: Text(widget.label, style: plateText(12, tokens.onPlate, weight: 700)),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}

/// A thermal overload relay's working front: TEST, STOP and RESET can be pressed during simulation, and the current
/// dial turns. The dial's pointer always shows the setting.
class _TorPanelView extends StatelessWidget {
  const _TorPanelView({super.key, required this.app, required this.device});

  final AppState app;
  final PlacedDevice device;

  @override
  Widget build(BuildContext context) {
    final def = app.defOf(device);
    final panel = def.torPanel!;
    final dial = panel['dial'] as Map<String, dynamic>;
    final origin = app.toScreen(Offset(device.x, device.y));
    final size = Size(def.width * app.zoom, def.height * app.zoom);
    Rect rectOf(Object? value) {
      final r = (value as List<dynamic>).cast<num>();
      return Rect.fromLTWH(r[0] * size.width, r[1] * size.height, r[2] * size.width, r[3] * size.height);
    }

    final min = (dial['min'] as num).toDouble(), max = (dial['max'] as num).toDouble();
    final amps = app.number(device, 'rated_current_a');
    final fraction = (amps - min) / (max - min);
    final centre = Offset((dial['cx'] as num) * size.width, (dial['cy'] as num) * size.height);
    final radius = (dial['r'] as num) * size.width;
    Widget key(String name, String tip) => Positioned.fromRect(
          rect: rectOf(panel[name]),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Tooltip(
              message: tip,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (_) {},
                child: Listener(
                  key: ValueKey('tor-$name-${device.tag}'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) {
                    app.inspect(device);
                    app.torKey(device, name, true);
                  },
                  onPointerUp: (_) => app.torKey(device, name, false),
                  onPointerCancel: (_) => app.torKey(device, name, false),
                ),
              ),
            ),
          ),
        );
    return Positioned(
      left: origin.dx,
      top: origin.dy,
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _DialPointerPainter(centre, radius, fraction, const Color(0xFFF2F4F5),
                    start: (dial['start'] as num?)?.toDouble() ?? 225, sweep: (dial['sweep'] as num?)?.toDouble() ?? 270),
              ),
            ),
          ),
          if (app.running) ...[
            key('test', 'TEST: uji trip'),
            key('stop', 'STOP: tahan untuk memutus 95-96'),
            key('reset', 'RESET: kembalikan setelah trip'),
            Positioned.fromRect(
              rect: rectOf(dial['rect']),
              child: _DialHandle(
                key: ValueKey('tor-dial-${device.tag}'),
                fraction: fraction,
                tooltip: 'Arus setting ${amps.toStringAsFixed(1)} A. Seret naik/turun atau scroll.',
                label: '${amps.toStringAsFixed(1)} A',
                onTurn: (f) => app.setTorCurrent(device, min + f * (max - min)),
                onDone: () {},
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// An analog timer's knob: its pointer shows the set time, and during simulation it turns by dragging or scrolling.
class _KnobView extends StatelessWidget {
  const _KnobView({super.key, required this.app, required this.device});

  final AppState app;
  final PlacedDevice device;

  @override
  Widget build(BuildContext context) {
    final def = app.defOf(device);
    final knob = def.knob!;
    final origin = app.toScreen(Offset(device.x, device.y));
    final size = Size(def.width * app.zoom, def.height * app.zoom);
    final min = (knob['min'] as num).toDouble(), max = (knob['max'] as num).toDouble();
    final log = knob['log'] == true;
    final seconds = app.timeOf(device).clamp(min, max);
    double fractionOf(double s) => log ? (math.log(s) - math.log(min)) / (math.log(max) - math.log(min)) : (s - min) / (max - min);
    double secondsOf(double f) => log ? math.exp(math.log(min) + f * (math.log(max) - math.log(min))) : min + f * (max - min);
    final centre = Offset((knob['cx'] as num) * size.width, (knob['cy'] as num) * size.height);
    final radius = (knob['r'] as num) * size.width;
    final text = seconds >= 60 ? '${(seconds / 60).toStringAsFixed(seconds % 60 == 0 ? 0 : 1)} mnt' : '${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)} dtk';
    return Positioned(
      left: origin.dx,
      top: origin.dy,
      width: size.width,
      height: size.height,
      child: Stack(
        children: [
          Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _DialPointerPainter(centre, radius, fractionOf(seconds), const Color(0xFFF2F4F5))))),
          if (app.running)
            Positioned.fromRect(
              rect: Rect.fromCircle(center: centre, radius: radius),
              child: _DialHandle(
                key: ValueKey('timer-knob-${device.tag}'),
                fraction: fractionOf(seconds),
                tooltip: 'Waktu $text. Seret naik/turun atau scroll.',
                label: text,
                onTurn: (f) => app.turnTimerKnob(device, secondsOf(f)),
                onDone: () => app.turnTimerKnob(device, app.timeOf(device), done: true),
              ),
            ),
        ],
      ),
    );
  }
}

/// The corner grip of the selected part: drag it to make the part bigger or smaller. The top-left corner stays put,
/// terminals and wires follow, and one drag is one undo step.
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({super.key, required this.app, required this.device});

  final AppState app;
  final PlacedDevice device;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  double _startScale = 1;
  Size _startSize = Size.zero;
  Offset _drag = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final tokens = context.tokens;
    final def = app.defOf(widget.device);
    final corner = app.toScreen(Offset(widget.device.x + def.width, widget.device.y + def.height));
    const size = 14.0;
    return Positioned(
      left: corner.dx - size / 2,
      top: corner.dy - size / 2,
      width: size,
      height: size,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeDownRight,
        child: Tooltip(
          message: 'Seret untuk mengubah ukuran (${(app.scaleOf(widget.device) * 100).round()}%)',
          child: GestureDetector(
            key: const ValueKey('resize-handle'),
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) {
              _startScale = app.scaleOf(widget.device);
              _startSize = Size(def.width * app.zoom, def.height * app.zoom);
              _drag = Offset.zero;
              app.beginControlEdit();
            },
            onPanUpdate: (details) {
              _drag += details.delta;
              // Grow by whichever way the corner moved further, relative to the part's size on screen.
              final grow = math.max(_drag.dx / _startSize.width, _drag.dy / _startSize.height);
              app.setDeviceScale(widget.device, _startScale * (1 + grow), keepTopLeft: true);
            },
            onPanEnd: (_) => app.endControlEdit(),
            onPanCancel: app.endControlEdit,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.panel,
                border: Border.all(color: tokens.accent, width: 2),
                borderRadius: BorderRadius.circular(Radii.plate),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PhaseDots extends StatelessWidget {
  const _PhaseDots({required this.app, required this.device});

  final AppState app;
  final PlacedDevice device;

  @override
  Widget build(BuildContext context) {
    final def = app.defOf(device);
    final result = app.simResult;
    return Stack(
      children: [
        for (var i = 0; i < def.terminals.length; i++)
          Builder(builder: (context) {
            final label = result?.at(TerminalRef(device.id, def.terminals[i].id));
            final lit = label != null && label.startsWith('L');
            final center = app.toScreen(Offset(device.x + (100 + i * 150) / 500 * def.width, device.y + 140 / 460 * def.height));
            final radius = 55 / 500 * def.width * app.zoom;
            return Positioned(
              left: center.dx - radius,
              top: center.dy - radius,
              width: radius * 2,
              height: radius * 2,
              child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: lit ? const Color(0xFFFFC53D) : const Color(0xFF59636E)))),
            );
          }),
      ],
    );
  }
}

/// The HMI's touch screen: push buttons, switches and lamps tied to PLC bits.
class _HmiScreen extends StatelessWidget {
  const _HmiScreen({required this.app, required this.device});

  final AppState app;
  final PlacedDevice device;

  @override
  Widget build(BuildContext context) {
    final def = app.defOf(device);
    final screen = (def.behavior['screen'] as List<dynamic>).cast<num>();
    final origin = app.toScreen(Offset(device.x + screen[0] * def.width, device.y + screen[1] * def.height));
    final widgets = (device.data['widgets'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    final on = app.running && app.stateOf(device) == 'on';
    final plc = app.firstPlc;
    final bits = on && plc != null ? app.bitsOf(plc) : const <String>{};
    final unit = app.zoom;
    final seen = <String>{};
    final children = <Widget>[];
    for (var i = 0; i < widgets.length; i++) {
      final widget = widgets[i];
      if (widget['type'] == 'lamp') {
        children.add(_HmiLamp(label: widget['label'] as String, lit: bits.contains(widget['ref']), unit: unit));
      } else {
        var keyName = 'hmi-${device.tag}-${widget['label']}';
        if (!seen.add(keyName)) {
          keyName = '$keyName#$i';
          while (!seen.add(keyName)) {
            keyName = '$keyName#';
          }
        }
        children.add(_HmiButton(
          key: ValueKey(keyName),
          label: widget['label'] as String,
          unit: unit,
          active: plc != null && app.plcBitForced(plc, widget['ref'] as String),
          enabled: on && plc != null,
          toggle: widget['type'] == 'toggle',
          onChange: (value) => app.setPlcBit(plc!, widget['ref'] as String, value),
        ));
      }
    }
    final body = GridView.count(
      crossAxisCount: 2,
      padding: EdgeInsets.all(8 * unit),
      mainAxisSpacing: 8 * unit,
      crossAxisSpacing: 8 * unit,
      childAspectRatio: 2.1,
      physics: const NeverScrollableScrollPhysics(),
      children: children,
    );
    return Positioned(
      left: origin.dx,
      top: origin.dy,
      width: screen[2] * def.width * app.zoom,
      height: screen[3] * def.height * app.zoom,
      child: on ? body : IgnorePointer(child: Opacity(opacity: 0.25, child: body)),
    );
  }
}

class _HmiLamp extends StatelessWidget {
  const _HmiLamp({required this.label, required this.lit, required this.unit});

  final String label;
  final bool lit;
  final double unit;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: lit ? const Color(0xFF35B56A) : const Color(0xFFCBD2D7), borderRadius: BorderRadius.circular(5 * unit)),
        alignment: Alignment.center,
        child: FittedBox(child: Padding(padding: EdgeInsets.all(4 * unit), child: Text(label, style: uiText(17, lit ? Colors.white : const Color(0xFF3F4750), weight: 600)))),
      );
}

class _HmiButton extends StatelessWidget {
  const _HmiButton({super.key, required this.label, required this.unit, required this.active, required this.enabled, required this.toggle, required this.onChange});

  final String label;
  final double unit;
  final bool active;
  final bool enabled;
  final bool toggle;
  final ValueChanged<bool> onChange;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      decoration: BoxDecoration(color: active ? const Color(0xFF0B4C8A) : const Color(0xFF0F62B0), borderRadius: BorderRadius.circular(5 * unit)),
      alignment: Alignment.center,
      child: FittedBox(child: Padding(padding: EdgeInsets.all(4 * unit), child: Text(label, style: uiText(17, Colors.white, weight: 600)))),
    );
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (_) {},
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: enabled ? (_) => onChange(toggle ? !active : true) : null,
          onPointerUp: enabled && !toggle ? (_) => onChange(false) : null,
          onPointerCancel: enabled && !toggle ? (_) => onChange(false) : null,
          child: box,
        ),
      ),
    );
  }
}

class _TerminalDot extends StatelessWidget {
  const _TerminalDot({required this.app, required this.ref, required this.tag});

  final AppState app;
  final TerminalRef ref;
  final String tag;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final center = app.toScreen(app.terminalWorld(ref));
    final hit = (30 * app.zoom).clamp(14.0, 30.0);
    final active = app.pending == ref;
    final dot = (15 * app.zoom).clamp(7.0, 22.0);
    return Positioned(
      left: center.dx - hit / 2,
      top: center.dy - hit / 2,
      width: hit,
      height: hit,
      child: Tooltip(
        message: '$tag terminal ${ref.terminal}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: ValueKey('terminal-$tag-${ref.terminal}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => app.tapTerminal(ref),
            child: Center(
              child: Container(
                width: dot,
                height: dot,
                // Idle terminals are a neutral white ring with a dark edge, readable on light and dark device photos; the
                // accent marks only the terminal picked for the next wire.
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? tokens.accent : Colors.transparent,
                  border: Border.all(color: active ? tokens.accent : const Color(0xE6FFFFFF), width: 1.6),
                  boxShadow: const [BoxShadow(color: Color(0x99000000), spreadRadius: 0.8)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws a spinning rotor on a motor or fan.
void paintRotor(Canvas canvas, Offset center, double radius, String style, double angle, double speed) {
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.rotate(angle);
  final color = Color.lerp(const Color(0xFF7B858F), const Color(0xFF35B56A), speed.clamp(0.0, 1.0))!;
  final body = Paint()..color = color;
  if (style == 'fan') {
    for (var i = 0; i < 4; i++) {
      canvas.save();
      canvas.rotate(i * math.pi / 2);
      canvas.drawOval(Rect.fromCenter(center: Offset(0, -radius * 0.56), width: radius * 0.42, height: radius * 0.92), body);
      canvas.restore();
    }
    canvas.drawCircle(Offset.zero, radius * 0.17, Paint()..color = const Color(0xFFAEB7C0));
  } else {
    canvas.drawCircle(Offset.zero, radius, body);
    final slot = Paint()
      ..color = const Color(0xFF23292E)
      ..strokeWidth = radius * 0.13
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 6; i++) {
      final a = i * math.pi / 3;
      canvas.drawLine(Offset(math.cos(a), math.sin(a)) * (radius * 0.42), Offset(math.cos(a), math.sin(a)) * (radius * 0.84), slot);
    }
    canvas.drawCircle(Offset.zero, radius * 0.28, Paint()..color = const Color(0xFFE8EDF2));
    // A mark on the shaft makes direction and slowing visible.
    canvas.drawCircle(Offset(radius * 0.13, 0), radius * 0.075, Paint()..color = const Color(0xFFB3261E));
  }
  canvas.restore();
}

Offset _rotorCenter(AppState app, PlacedDevice device, Map<String, dynamic> rotor, DeviceDef def) =>
    app.toScreen(Offset(device.x + (rotor['cx'] as num) * def.width, device.y + (rotor['cy'] as num) * def.height));

/// Motors at rest while editing.
class _StaticPartsPainter extends CustomPainter {
  const _StaticPartsPainter(this.app);

  final AppState app;

  @override
  void paint(Canvas canvas, Size size) {
    for (final device in app.project.devices) {
      final def = app.defOf(device);
      final rotor = def.rotor;
      if (rotor != null) paintRotor(canvas, _rotorCenter(app, device, rotor, def), (rotor['r'] as num) * def.width * app.zoom, rotor['style'] as String, 0, 0);
    }
  }

  @override
  bool shouldRepaint(_StaticPartsPainter old) => true;
}

/// Everything that moves during simulation: current in the wires, waveforms, rotors and lamps.
class _LivePainter extends CustomPainter {
  _LivePainter(this.app, this.tokens) : super(repaint: app.animationFrame);

  final AppState app;
  final Tokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    for (final device in app.project.devices) {
      final def = app.defOf(device);
      final rotor = def.rotor;
      if (rotor != null) {
        paintRotor(canvas, _rotorCenter(app, device, rotor, def), (rotor['r'] as num) * def.width * app.zoom, rotor['style'] as String, app.rotorAngle(device), app.rotorSpeed(device));
      }
      final glow = def.glow;
      if (glow != null) _paintGlow(canvas, device, def, glow);
      final wave = def.wave;
      if (wave != null) _paintWave(canvas, device, def, wave);
    }
    final worldRoutes = app.project.wires.isEmpty ? const <int, List<Offset>>{} : app.routesWorld();
    for (final wire in app.project.wires) {
      final flow = app.wireFlow(wire);
      if (flow.abs() > 0.002) {
        final points = [for (final p in worldRoutes[wire.id] ?? app.routeWorld(wire)) app.toScreen(p)];
        _paintFlow(canvas, wire, flow, points);
      }
    }
    _paintDamage(canvas);
  }

  /// Smoke, sparks and explosions. Drawn last so the blast covers the wires and the devices around it.
  void _paintDamage(Canvas canvas) {
    for (final device in app.project.devices) {
      final def = app.defOf(device);
      final rect = app.toScreen(Offset(device.x, device.y)) & Size(def.width * app.zoom, def.height * app.zoom);
      final since = app.explodedFor(device);
      if (since != null) {
        _paintWreck(canvas, device.id, rect, since);
        continue;
      }
      final damage = app.damageOf(device);
      if (damage > 0.25) _paintSmoke(canvas, device.id, rect, (damage - 0.25) / 0.75);
      if (damage > 0.55) _paintSparks(canvas, device.id, rect, (damage - 0.55) / 0.45);
    }
  }

  /// A repeatable pseudo-random number in 0..1, so each device's debris and smoke keep their shape between frames.
  static double _noise(int a, int b) {
    var x = (a * 73856093) ^ (b * 19349663) ^ 0x5bd1e995;
    x = ((x ^ (x >> 13)) * 1274126177) & 0x7fffffff;
    x = (x ^ (x >> 16)) & 0xffff;
    return x / 0xffff;
  }

  void _paintSmoke(Canvas canvas, int id, Rect rect, double intensity) {
    final zoom = app.zoom;
    final t = app.animTime;
    const puffs = 9;
    for (var i = 0; i < puffs; i++) {
      final life = (t / 2.4 + _noise(id, i)) % 1.0;
      final drift = math.sin(life * 3 + i) * rect.width * 0.12 * life;
      final x = rect.left + rect.width * (0.2 + 0.6 * _noise(id, i + 40)) + drift;
      final y = rect.top + rect.height * 0.35 - life * (rect.height * 0.6 + 120 * zoom);
      final radius = (5 + 30 * life) * zoom * (0.7 + 0.5 * intensity);
      final alpha = intensity * 0.5 * (1 - life) * math.min(1.0, life * 6);
      final shade = Color.lerp(const Color(0xFF1E1E1E), const Color(0xFF8A8A8A), life)!;
      if (alpha < 0.01) continue;
      // A soft puff from a radial gradient. A blur filter would look the same but costs far more every frame.
      final center = Offset(x, y);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [shade.withValues(alpha: alpha), shade.withValues(alpha: alpha * 0.5), shade.withValues(alpha: 0)], stops: const [0, 0.5, 1])
              .createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  /// Arcs that spit from an overheating part, more often the closer it is to failing.
  void _paintSparks(Canvas canvas, int id, Rect rect, double intensity) {
    final slot = (app.animTime * 14).floor();
    final zoom = app.zoom;
    for (var k = 0; k < 4; k++) {
      if (_noise(id + slot * 7, k) > 0.25 + 0.55 * intensity) continue;
      final from = Offset(rect.left + rect.width * _noise(slot, k + id), rect.top + rect.height * _noise(k + id, slot));
      final angle = _noise(slot + k, id) * math.pi * 2;
      final length = (6 + 16 * _noise(id, slot + k)) * zoom;
      final path = Path()..moveTo(from.dx, from.dy);
      var at = from;
      for (var j = 1; j <= 3; j++) {
        final bend = (_noise(slot + j, k) - 0.5) * 1.2;
        at += Offset(math.cos(angle + bend), math.sin(angle + bend)) * (length / 3);
        path.lineTo(at.dx, at.dy);
      }
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4 * zoom
            ..strokeCap = StrokeCap.round
            ..color = const Color(0xFF7FC8FF).withValues(alpha: 0.3));
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4 * zoom
            ..color = const Color(0xFFF4FBFF));
    }
  }

  void _paintWreck(Canvas canvas, int id, Rect rect, double since) {
    final zoom = app.zoom;
    final size = math.max(rect.width, rect.height);
    final center = rect.center;

    // Scorched for good: soot spreads around it and cracks run across its middle. The part itself is darkened where
    // it is drawn, which follows its outline instead of covering a box.
    final char = math.min(1.0, since * 4);
    canvas.drawCircle(
      center,
      size * 0.95,
      Paint()
        ..shader = RadialGradient(colors: [const Color(0xFF140B05).withValues(alpha: 0.55 * char), const Color(0x00140B05)])
            .createShader(Rect.fromCircle(center: center, radius: size * 0.95)),
    );
    final reach = math.min(rect.width, rect.height) * 0.08;
    final crack = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * zoom
      ..color = Colors.black.withValues(alpha: 0.85 * char);
    for (var c = 0; c < 4; c++) {
      final path = Path()..moveTo(center.dx, center.dy);
      var at = center;
      final angle = _noise(id, c + 200) * math.pi * 2;
      for (var j = 0; j < 4; j++) {
        final bend = (_noise(id, c * 10 + j + 300) - 0.5) * 1.4;
        at += Offset(math.cos(angle + bend), math.sin(angle + bend)) * reach;
        path.lineTo(at.dx, at.dy);
      }
      canvas.drawPath(path, crack);
    }

    // Embers glowing in the wreck, dying away over a few seconds.
    final embers = (1 - since / 8).clamp(0.0, 1.0);
    if (embers > 0) {
      for (var e = 0; e < 10; e++) {
        final flicker = 0.5 + 0.5 * math.sin(app.animTime * (6 + 5 * _noise(id, e + 500)) + e);
        final at = Offset(rect.left + rect.width * (0.15 + 0.7 * _noise(id, e + 400)), rect.top + rect.height * (0.15 + 0.7 * _noise(id, e + 450)));
        final r = (1.5 + 2 * _noise(id, e + 470)) * zoom;
        canvas.drawCircle(at, r * 2.2, Paint()..color = const Color(0xFFFF7A1A).withValues(alpha: 0.25 * embers * flicker));
        canvas.drawCircle(at, r, Paint()..color = const Color(0xFFFFA040).withValues(alpha: embers * flicker));
      }
    }

    // It keeps smoking, heavily at first.
    _paintSmoke(canvas, id, rect, since < 4 ? 1.0 : math.max(0.35, 1 - (since - 4) / 10));

    // The blast itself, over in about a second.
    if (since < 0.14) {
      final flash = 1 - since / 0.14;
      final radius = size * 2.6;
      canvas.drawCircle(
          center,
          radius,
          Paint()
            ..shader = RadialGradient(
              colors: [Colors.white.withValues(alpha: 0.95 * flash), const Color(0xFFFFF2C4).withValues(alpha: 0.5 * flash), const Color(0x00FFF2C4)],
              stops: const [0, 0.35, 1],
            ).createShader(Rect.fromCircle(center: center, radius: radius)));
    }
    if (since < 0.55) {
      final p = since / 0.55;
      final radius = size * (0.5 + 2.6 * p);
      canvas.drawCircle(
          center,
          radius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = (10 * (1 - p) + 1) * zoom
            ..color = Colors.white.withValues(alpha: 0.55 * (1 - p)));
    }
    if (since < 1.0) {
      final p = since;
      final grow = 1 - math.pow(1 - p, 3).toDouble();
      final radius = size * (0.35 + 1.15 * grow);
      final fade = 1 - p;
      final ball = center + Offset(0, -size * 0.25 * p);
      canvas.drawCircle(
          ball,
          radius,
          Paint()
            ..shader = RadialGradient(
              colors: [
                const Color(0xFFFFFBE0).withValues(alpha: fade),
                const Color(0xFFFFC233).withValues(alpha: 0.95 * fade),
                const Color(0xFFFF5A12).withValues(alpha: 0.8 * fade),
                const Color(0xFF7A1A05).withValues(alpha: 0.45 * fade),
                const Color(0x007A1A05),
              ],
              stops: const [0, 0.25, 0.55, 0.8, 1],
            ).createShader(Rect.fromCircle(center: ball, radius: radius)));
    }

    // Debris and sparks thrown out, falling under gravity.
    const pieces = 34;
    final gravity = 900 * zoom;
    for (var i = 0; i < pieces; i++) {
      final life = 0.6 + 0.9 * _noise(id, i + 100);
      if (since >= life) continue;
      final angle = _noise(id, i) * math.pi * 2;
      final speed = (180 + 420 * _noise(id, i + 50)) * zoom;
      final velocity = Offset(math.cos(angle), math.sin(angle) - 0.35) * speed;
      final at = center + velocity * since + Offset(0, 0.5 * gravity * since * since);
      final fade = 1 - since / life;
      if (i % 4 == 0) {
        // A dark chunk of casing, tumbling.
        final chunk = (2.5 + 4 * _noise(id, i + 150)) * zoom;
        canvas.save();
        canvas.translate(at.dx, at.dy);
        canvas.rotate(since * (8 + 10 * _noise(id, i + 160)));
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: chunk * 1.6, height: chunk), Paint()..color = const Color(0xFF2A211C).withValues(alpha: fade));
        canvas.restore();
      } else {
        final now = velocity + Offset(0, gravity * since);
        final tail = at - now * 0.03;
        final hot = Color.lerp(const Color(0xFFFFF6C8), const Color(0xFFFF6A00), since / life)!;
        canvas.drawLine(
            tail,
            at,
            Paint()
              ..strokeWidth = 2.2 * zoom
              ..strokeCap = StrokeCap.round
              ..color = hot.withValues(alpha: fade));
      }
    }
  }

  void _paintGlow(Canvas canvas, PlacedDevice device, DeviceDef def, Map<String, dynamic> glow) {
    final level = app.lampGlow(device);
    if (level < 0.01) return;
    final center = app.toScreen(Offset(device.x + (glow['cx'] as num) * def.width, device.y + (glow['cy'] as num) * def.height));
    final radius = (glow['r'] as num) * def.width * app.zoom * 1.55;
    final hex = int.parse((glow['color'] as String).substring(1), radix: 16);
    final color = Color(0xFF000000 | hex);
    canvas.drawCircle(
      center,
      radius,
      Paint()..shader = RadialGradient(colors: [color.withValues(alpha: 0.55 * level), color.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
  }

  void _paintWave(Canvas canvas, PlacedDevice device, DeviceDef def, List<double> wave) {
    final origin = app.toScreen(Offset(device.x + wave[0] * def.width, device.y + wave[1] * def.height));
    final width = wave[2] * def.width * app.zoom;
    final height = wave[3] * def.height * app.zoom;
    final rect = origin & Size(width, height);
    final volts = app.shownMeasure(device).volts;
    final hertz = app.shownMeasure(device).hertz;
    canvas.save();
    canvas.clipRect(rect);
    final mid = rect.center.dy;
    canvas.drawLine(Offset(rect.left, mid), Offset(rect.right, mid), Paint()
      ..color = const Color(0xFF3B5C47)
      ..strokeWidth = 1);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.4, 2.6 * app.zoom)
      ..strokeCap = StrokeCap.round;
    if (def.behavior['dc'] == true) {
      canvas.drawLine(Offset(rect.left, mid - height * 0.28), Offset(rect.right, mid - height * 0.28), line..color = const Color(0xFF7CF2A6));
      canvas.restore();
      return;
    }
    final phases = (def.behavior['wave_phases'] as num?)?.toInt() ?? 1;
    const colors = [Color(0xFFF2A33A), Color(0xFFB58CFF), Color(0xFF4FD1E8)];
    // The wave moves slowly enough to see. Its shape follows the real voltage and frequency.
    final amplitude = height * 0.4 * (volts <= 0 ? 0.0 : math.min(1.0, volts / 300 + 0.25));
    final cycles = 2.2 * (hertz <= 0 ? 1.0 : (hertz / 50).clamp(0.4, 2.0));
    for (var p = 0; p < phases; p++) {
      final path = Path();
      for (var i = 0; i <= 80; i++) {
        final t = i / 80;
        final y = mid - amplitude * math.sin(2 * math.pi * (cycles * t - app.animTime * 0.9) + p * 2 * math.pi / 3);
        final x = rect.left + width * t;
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(path, line..color = colors[p]);
    }
    canvas.restore();
  }

  /// Light travelling along the wire. In AC each bead swells and shrinks as the wave passes; in DC they are even.
  void _paintFlow(Canvas canvas, Wire wire, double flow, List<Offset> points) {
    final lengths = <double>[0];
    for (var i = 0; i < points.length - 1; i++) {
      lengths.add(lengths.last + (points[i + 1] - points[i]).distance);
    }
    final total = lengths.last;
    if (total < 2) return;
    final spacing = math.max(16.0, 34 * app.zoom);
    final strength = (0.35 + 0.65 * math.min(1.0, flow.abs() * 4)).clamp(0.0, 1.0);
    final isDc = app.wireIsDc(wire);
    final fade = math.min(1.0, flow.abs() * 18);
    final base = 2.7 * app.zoom.clamp(0.55, 1.5);
    final head = app.wirePhase(wire) * app.zoom % spacing;
    final bead = Paint()..color = const Color(0xFFFFEFB0).withValues(alpha: 0.95 * strength * fade);
    final halo = Paint()..color = const Color(0xFFFFD27A).withValues(alpha: 0.28 * strength * fade);
    var segment = 0;
    for (var s = head; s < total; s += spacing) {
      while (segment < points.length - 2 && s > lengths[segment + 1]) {
        segment++;
      }
      final span = lengths[segment + 1] - lengths[segment];
      final t = span == 0 ? 0.0 : (s - lengths[segment]) / span;
      final at = Offset.lerp(points[segment], points[segment + 1], t)!;
      final swell = isDc ? 1.0 : 0.55 + 0.75 * (0.5 + 0.5 * math.sin(2 * math.pi * (s / (150 * app.zoom) - app.animTime * 1.1)));
      canvas.drawCircle(at, base * swell * 2.1, halo);
      canvas.drawCircle(at, base * swell, bead);
    }
  }

  @override
  bool shouldRepaint(_LivePainter old) => true;
}

class _GridPainter extends CustomPainter {
  const _GridPainter(this.pan, this.zoom, this.tokens);

  final Offset pan;
  final double zoom;
  final Tokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = tokens.canvas);
    // One grid square is one centimetre, at 4 canvas pixels per millimetre.
    var step = 40 * zoom;
    while (step < 14) {
      step *= 2;
    }
    final fine = Paint()
      ..color = tokens.gridDot.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    final coarse = Paint()
      ..color = tokens.gridDot
      ..strokeWidth = 1;
    final startX = pan.dx % step;
    final startY = pan.dy % step;
    final firstX = ((startX - pan.dx) / step).round();
    final firstY = ((startY - pan.dy) / step).round();
    var index = firstX;
    for (var x = startX; x < size.width; x += step, index++) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), index % 5 == 0 ? coarse : fine);
    }
    index = firstY;
    for (var y = startY; y < size.height; y += step, index++) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), index % 5 == 0 ? coarse : fine);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.pan != pan || old.zoom != zoom || old.tokens != tokens;
}

class _RulerPainter extends CustomPainter {
  const _RulerPainter(this.pan, this.zoom, this.tokens);

  final Offset pan;
  final double zoom;
  final Tokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final band = Paint()..color = tokens.panel;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, kRuler), band);
    canvas.drawRect(Rect.fromLTWH(0, 0, kRuler, size.height), band);
    final edge = Paint()
      ..color = tokens.border
      ..strokeWidth = 1;
    canvas.drawLine(const Offset(0, kRuler), Offset(size.width, kRuler), edge);
    canvas.drawLine(const Offset(kRuler, 0), Offset(kRuler, size.height), edge);

    var cm = 1;
    while (cm * 40 * zoom < 7) {
      cm *= 5;
    }
    final labelEvery = cm == 1 ? (40 * zoom < 12 ? 10 : 5) : cm * 2;
    final tick = Paint()
      ..color = tokens.textMuted
      ..strokeWidth = 1;

    void text(String value, Offset at) {
      (TextPainter(text: TextSpan(text: value, style: uiText(10, tokens.textMuted)), textDirection: TextDirection.ltr)..layout()).paint(canvas, at);
    }

    final firstX = ((kRuler - pan.dx) / (40 * zoom) / cm).floor() * cm;
    for (var c = firstX; pan.dx + c * 40 * zoom < size.width; c += cm) {
      final x = pan.dx + c * 40 * zoom;
      if (x < kRuler) continue;
      final major = c % labelEvery == 0;
      canvas.drawLine(Offset(x, kRuler - (major ? 8 : 4)), Offset(x, kRuler), tick);
      if (major) text('$c', Offset(x + 2, 2));
    }
    final firstY = ((kRuler - pan.dy) / (40 * zoom) / cm).floor() * cm;
    for (var c = firstY; pan.dy + c * 40 * zoom < size.height; c += cm) {
      final y = pan.dy + c * 40 * zoom;
      if (y < kRuler) continue;
      final major = c % labelEvery == 0;
      canvas.drawLine(Offset(kRuler - (major ? 8 : 4), y), Offset(kRuler, y), tick);
      if (major) text('$c', Offset(2, y + 1));
    }
    canvas.drawRect(const Rect.fromLTWH(0, 0, kRuler, kRuler), band);
    text('cm', const Offset(3, 5));
  }

  @override
  bool shouldRepaint(_RulerPainter old) => old.pan != pan || old.zoom != zoom || old.tokens != tokens;
}

/// The wires, drawn once into an image and reused for as long as nothing about them changes.
///
/// Each wire is three round-jointed strokes and two ferrules; redrawn from scratch every frame, a few dozen of them
/// cost more than the rest of the canvas together, and the assistant's cursors animate the window at 60 frames a
/// second. So the strokes are rasterized once per change (wires, routes, camera, colors, selection) and blitted.
class WireCache {
  static ui.Image? _image;
  static int _key = 0;
  static int _pendingKey = 0;

  /// Draw straight from the vectors, for exporting at a higher resolution than the screen.
  static bool bypass = false;

  static void clear() {
    _image?.dispose();
    _image = null;
    _key = 0;
    _pendingKey = 0;
  }
}

/// A wire's path with its bends rounded off, the way a real cable curves, each corner cut by at most [radius] and at
/// most half of either run beside it.
Path roundedWirePath(List<Offset> points, double radius) {
  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (var i = 1; i < points.length; i++) {
    final p = points[i];
    if (i == points.length - 1) {
      path.lineTo(p.dx, p.dy);
      break;
    }
    final before = points[i - 1], after = points[i + 1];
    final inLength = (p - before).distance, outLength = (after - p).distance;
    final r = math.min(radius, math.min(inLength, outLength) / 2);
    if (r < 0.5 || inLength == 0 || outLength == 0) {
      path.lineTo(p.dx, p.dy);
      continue;
    }
    final start = p - (p - before) / inLength * r;
    final end = p + (after - p) / outLength * r;
    path
      ..lineTo(start.dx, start.dy)
      ..quadraticBezierTo(p.dx, p.dy, end.dx, end.dy);
  }
  return path;
}

class _WirePainter extends CustomPainter {
  const _WirePainter(this.app, this.tokens, this.pixelRatio);

  final AppState app;
  final Tokens tokens;
  final double pixelRatio;

  @override
  void paint(Canvas canvas, Size size) {
    final worldRoutes = app.project.wires.isEmpty ? const <int, List<Offset>>{} : app.routesWorld();
    final routes = [
      for (final wire in app.project.wires)
        [for (final point in worldRoutes[wire.id] ?? app.routeWorld(wire)) app.toScreen(point)],
    ];
    final result = app.simResult;
    final key = Object.hashAll([
      size,
      pixelRatio,
      app.zoom,
      app.dark,
      app.selectedWire,
      app.running,
      tokens.hashCode,
      for (var i = 0; i < routes.length; i++) ...[
        app.project.wires[i].id,
        app.project.wires[i].color,
        app.project.wires[i].isJumper,
        app.project.wires[i].number,
        if (app.wireNumbersOn) app.wireLabel(app.project.wires[i]),
        if (app.running && result != null) result.at(app.project.wires[i].a),
        ...routes[i],
      ],
    ]);
    final cached = WireCache._image;
    if (!WireCache.bypass && cached != null && key == WireCache._key) {
      _blit(canvas, cached);
    } else if (WireCache.bypass || size.isEmpty || key != WireCache._pendingKey) {
      if (!WireCache.bypass && !size.isEmpty) WireCache._pendingKey = key;
      _wires(canvas, routes);
    } else {
      final recorder = ui.PictureRecorder();
      final offscreen = Canvas(recorder)..scale(pixelRatio);
      _wires(offscreen, routes);
      final picture = recorder.endRecording();
      final image = picture.toImageSync((size.width * pixelRatio).ceil(), (size.height * pixelRatio).ceil());
      picture.dispose();
      WireCache._image?.dispose();
      WireCache._image = image;
      WireCache._key = key;
      _blit(canvas, image);
    }
    final pending = app.pending;
    final pointer = app.pointer;
    if (pending != null && pointer != null) {
      final start = app.toScreen(app.terminalWorld(pending));
      if (app.jumperMode) {
        _stroke(canvas, [start, pointer], tokens.accent, 3);
      } else {
        // Through the bends placed so far, then on to the pointer, turning vertically first like the finished wire.
        final path = <Offset>[start];
        for (final next in [...app.pendingCorners.map(app.toScreen), pointer]) {
          final last = path.last;
          if ((last.dx - next.dx).abs() > 0.5 && (last.dy - next.dy).abs() > 0.5) path.add(Offset(last.dx, next.dy));
          path.add(next);
        }
        _stroke(canvas, path, tokens.accent, 2);
        for (final corner in app.pendingCorners) {
          canvas.drawCircle(app.toScreen(corner), 3.5, Paint()..color = tokens.accent);
        }
      }
    }
  }

  void _blit(Canvas canvas, ui.Image image) {
    canvas.save();
    canvas.scale(1 / pixelRatio);
    canvas.drawImage(image, Offset.zero, Paint()..filterQuality = FilterQuality.none);
    canvas.restore();
  }

  void _wires(Canvas canvas, List<List<Offset>> routes) {
    final result = app.simResult;
    final scale = app.zoom.clamp(0.55, 1.6);
    for (var index = 0; index < app.project.wires.length; index++) {
      final wire = app.project.wires[index];
      final selected = wire.id == app.selectedWire;
      var color = wire.color == Wire.defaultColor && app.dark ? tokens.textMuted : Color(wire.color);
      if (wire.color == 0xFF1F2428 && app.dark) color = const Color(0xFFB8BEC4);
      var width = (wire.isJumper ? 6.0 : 5.0) * scale;
      var live = false;
      if (app.running && result != null) {
        final label = result.at(wire.a);
        if (label == 'short') {
          color = tokens.error;
          width += 2;
          live = true;
        } else if (label != null) {
          color = kLiveColors[label.startsWith('DC+') ? 'DC+' : label] ?? color;
          live = true;
        } else {
          color = tokens.deadWire;
        }
      }
      final points = routes[index];
      if (selected) _stroke(canvas, points, tokens.accent, width + 4);
      // A cable: dark jacket edge, colored core, and a soft highlight.
      _stroke(canvas, points, const Color(0xFF1B2024).withValues(alpha: 0.8), width + 1.6);
      _stroke(canvas, points, color, width);
      _stroke(canvas, points, Colors.white.withValues(alpha: live ? 0.4 : 0.26), math.max(1.0, width * 0.26));
      if (wire.isJumper) {
        final dot = Paint()..color = color;
        final radius = 6.5 * scale;
        canvas
          ..drawCircle(points.first, radius, dot)
          ..drawCircle(points.last, radius, dot);
      } else {
        _ferrule(canvas, points.first, points[1], scale, color);
        _ferrule(canvas, points.last, points[points.length - 2], scale, color);
      }
    }
    // Number markers last, so no wire runs over them. Hidden when zoomed out too far to read.
    if (app.wireNumbersOn && app.zoom >= 0.45) {
      for (var index = 0; index < app.project.wires.length; index++) {
        final wire = app.project.wires[index];
        if (wire.isJumper) continue;
        final text = app.wireLabel(wire);
        if (text.isEmpty) continue;
        final points = routes[index];
        _marker(canvas, points, text, scale);
        _marker(canvas, points.reversed.toList(), text, scale);
      }
    }
    // Junctions on top of the wires they join: a solder dot in the color of what flows through it.
    for (final device in app.project.devices) {
      if (!app.defOf(device).isJunction) continue;
      final ref = TerminalRef(device.id, 'J');
      final center = app.toScreen(app.terminalWorld(ref));
      final label = app.running ? result?.at(ref) : null;
      var color = const Color(0xFF8A939C);
      if (label != null) color = label == 'short' ? tokens.error : kLiveColors[label.startsWith('DC+') ? 'DC+' : label] ?? color;
      canvas.drawCircle(center, 7.5 * scale, Paint()..color = const Color(0xFF1B2024));
      canvas.drawCircle(center, 5 * scale, Paint()..color = color);
    }
  }

  /// A crimped sleeve where the wire meets a terminal.
  void _ferrule(Canvas canvas, Offset terminal, Offset next, double scale, Color color) {
    final direction = next - terminal;
    if (direction.distance < 4) return;
    final unit = direction / direction.distance;
    final length = 12 * scale;
    final center = terminal + unit * math.min(length, direction.distance / 2);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(math.atan2(unit.dy, unit.dx));
    final rect = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: length, height: 7.5 * scale), Radius.circular(1.5 * scale));
    canvas.drawRRect(rect, Paint()..color = const Color(0xFF23292E));
    canvas.drawRRect(rect.deflate(1.3 * scale), Paint()..color = color);
    canvas.restore();
  }

  /// A wire number marker near the start of [points]: a small printed sleeve on the wire, a little way past the
  /// ferrule, turned to read upright.
  void _marker(Canvas canvas, List<Offset> points, String text, double scale) {
    if (points.length < 2) return;
    // Near where the wire leaves the part: most of the way along the first run, clear of the part and its tag; on a
    // short first run, a fixed distance along the wire.
    final first = (points[1] - points[0]).distance;
    final reach = first >= 28 * scale ? first * 0.82 : 34 * scale;
    var travelled = 0.0;
    Offset? at;
    for (var i = 0; i + 1 < points.length; i++) {
      final a = points[i], b = points[i + 1];
      final length = (b - a).distance;
      if (travelled + length >= reach) {
        at = a + (b - a) * ((reach - travelled) / length);
        break;
      }
      travelled += length;
    }
    if (at == null) return;
    final painter = TextPainter(
      text: TextSpan(text: text, style: plateText((12 * app.zoom).clamp(8.0, 15.0), const Color(0xFF1F2428), weight: 700, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    final box = Rect.fromCenter(center: at, width: math.max(painter.width + 6 * scale, 14 * scale), height: painter.height + 4 * scale);
    final shape = RRect.fromRectAndRadius(box, Radius.circular(2 * scale));
    canvas.drawRRect(shape.inflate(1), Paint()..color = const Color(0xFF23292E));
    canvas.drawRRect(shape, Paint()..color = const Color(0xFFF1E6C4));
    painter.paint(canvas, box.center - Offset(painter.width / 2, painter.height / 2));
  }

  void _stroke(Canvas canvas, List<Offset> points, Color color, double width) {
    final path = roundedWirePath(points, 12 * app.zoom.clamp(0.55, 1.6));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_WirePainter old) => true;
}
