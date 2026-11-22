import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ai/swarm.dart';
import '../app_state.dart';
import 'theme.dart';

/// Draws the assistant's team over the canvas and drives its animation. Never takes input.
class SwarmOverlay extends StatefulWidget {
  const SwarmOverlay({super.key, required this.app, required this.canvasKey});

  final AppState app;

  /// The canvas, to place world coordinates on screen.
  final GlobalKey canvasKey;

  @override
  State<SwarmOverlay> createState() => _SwarmOverlayState();
}

class _SwarmOverlayState extends State<SwarmOverlay> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;

  Swarm get swarm => widget.app.swarm;

  /// Where the canvas sits inside this overlay, refreshed every build.
  Offset _canvasAt = Offset.zero;
  Size _canvasSize = Size.zero;
  double _overlayHeight = 0;

  /// Overlay-local position of a world point.
  Offset _local(Offset world) => _canvasAt + widget.app.toScreen(world);

  void _measure() {
    final canvas = widget.canvasKey.currentContext?.findRenderObject();
    final self = context.findRenderObject();
    if (canvas is! RenderBox || self is! RenderBox || !canvas.hasSize || !self.hasSize) return;
    final global = canvas.localToGlobal(Offset.zero);
    swarm.canvasOrigin = global;
    _canvasAt = self.globalToLocal(global);
    _canvasSize = canvas.size;
    _overlayHeight = self.size.height;
  }

  @override
  void initState() {
    super.initState();
    swarm.attach();
    swarm.precache = _precache;
    swarm.addListener(_wake);
    _wake();
  }

  @override
  void dispose() {
    swarm.removeListener(_wake);
    swarm.detach();
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _precache(String defId) async {
    final def = widget.app.defs[defId];
    if (def == null || !mounted) return;
    final assets = [if (def.isRaster) def.assetFor(def.defaultState), ?def.previewAsset];
    await Future.wait([for (final asset in assets) precacheImage(AssetImage(asset), context, onError: (_, _) {})]);
  }

  /// Runs the ticker only while there is something to animate, so an idle canvas costs nothing.
  void _wake() {
    if (swarm.needsTick && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero ? 1 / 60 : math.min(0.05, (elapsed - _last).inMicroseconds / 1e6);
    _last = elapsed;
    if (!swarm.needsTick) {
      _ticker.stop();
      return;
    }
    swarm.tick(dt);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) => ListenableBuilder(
          listenable: swarm,
          builder: (context, _) {
            _measure();
            final height = constraints.hasBoundedHeight ? constraints.maxHeight : _overlayHeight;
            final children = <Widget>[];
            // Ghosts of devices being dragged in.
            for (final cursor in swarm.cursors) {
              final id = cursor.carrying;
              final def = id == null ? null : app.defs[id];
              if (def == null) continue;
              final center = _local(cursor.pos);
              final full = Size(def.width * app.zoom, def.height * app.zoom);
              // Card-sized over the library, growing to its real size as it crosses onto the canvas.
              final fit = 96 / math.max(full.width, full.height);
              final into = ((center.dx - _canvasAt.dx + 40) / 120).clamp(0.0, 1.0);
              final scale = fit >= 1 ? 1.0 : fit + (1 - fit) * into;
              final size = full * scale;
              final asset = def.previewAsset ?? (def.isRaster ? def.assetFor(def.defaultState) : null);
              children.add(Positioned(
                left: center.dx - size.width / 2,
                top: center.dy - size.height / 2,
                width: size.width,
                height: size.height,
                // Drawn with alpha in the paint rather than an Opacity layer: ten cursors carrying big photos at once
                // would otherwise mean ten offscreen layers a frame.
                child: DecoratedBox(
                  decoration: BoxDecoration(border: Border.all(color: cursor.color.withValues(alpha: 0.8 * cursor.alpha), width: 1.5), borderRadius: BorderRadius.circular(Radii.control)),
                  child: asset == null
                      ? const SizedBox.expand()
                      : Image.asset(asset, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.low, opacity: AlwaysStoppedAnimation(0.6 * cursor.alpha)),
                ),
              ));
            }
            children.add(Positioned.fill(child: CustomPaint(painter: _SwarmPainter(app, swarm, _local))));
            final card = swarm.card;
            if (card != null) children.add(_card(context, card, height));
            for (final cursor in swarm.cursors) {
              children.add(_label(context, cursor));
            }
            if (app.aiLocked) children.add(_banner(context));
            // Cursors may travel over the library and the canvas, never over the assistant's panel.
            return ClipRect(
              clipper: _LeftOf(_canvasAt.dx + _canvasSize.width),
              child: Stack(clipBehavior: Clip.hardEdge, children: children),
            );
          },
        ),
      ),
    );
  }

  Widget _label(BuildContext context, SwarmCursor cursor) {
    final at = _local(cursor.pos);
    return Positioned(
      left: at.dx + 16,
      top: at.dy + 18,
      child: Visibility(
        visible: cursor.alpha > 0.05,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
              decoration: BoxDecoration(
                color: cursor.color,
                borderRadius: BorderRadius.circular(Radii.control),
                border: Border.all(color: const Color(0x33000000)),
              ),
              child: Text(cursor.leader ? '★ ${cursor.name}' : cursor.name, style: uiText(11.5, Colors.white, weight: 650)),
            ),
            if (cursor.note != null)
              Container(
                margin: const EdgeInsets.only(top: 3),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xE6181B1E), borderRadius: BorderRadius.circular(Radii.control)),
                child: Text(cursor.note!, style: uiText(10.5, Colors.white)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _card(BuildContext context, SwarmCard card, double overlayHeight) {
    final app = widget.app;
    final plc = app.project.devices.where((d) => d.id == card.deviceId).firstOrNull;
    if (plc == null) return const SizedBox.shrink();
    final at = _local(Offset(plc.x, plc.y));
    var left = card.shown;
    final shown = <String>[];
    for (final line in card.lines) {
      if (left <= 0) break;
      shown.add(line.substring(0, math.min(line.length, left)));
      left -= line.length + 1;
    }
    final typing = card.shown < card.total;
    return Positioned(
      left: at.dx,
      bottom: overlayHeight - at.dy + 10,
      child: Opacity(
        opacity: card.fade.clamp(0.0, 1.0),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 420, minWidth: 220),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xF2141A20),
            borderRadius: BorderRadius.circular(Radii.control),
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 12, offset: Offset(0, 4))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Program ${plc.tag}', style: uiText(11, const Color(0xFF8FB4D8), weight: 650)),
              const SizedBox(height: 6),
              for (var i = 0; i < shown.length; i++)
                Text(
                  shown[i] + (typing && i == shown.length - 1 && (DateTime.now().millisecondsSinceEpoch ~/ 450).isEven ? '▌' : ''),
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: Color(0xFFE6EDF3), height: 1.45),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _banner(BuildContext context) {
    final tokens = context.tokens;
    final team = swarm.members;
    return Positioned(
      top: _canvasAt.dy + 10,
      left: _canvasAt.dx,
      width: _canvasSize.width,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: tokens.panel.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: tokens.border),
            boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 10, offset: Offset(0, 3))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 14, color: tokens.textMuted),
              const SizedBox(width: 6),
              Text(swarm.thinking ? 'Tim AI sedang berpikir' : 'Tim AI sedang bekerja', style: uiText(12, tokens.text, weight: 600)),
              if (team.isNotEmpty) ...[
                const SizedBox(width: 10),
                for (final cursor in team.take(16))
                  Padding(
                    padding: const EdgeInsets.only(left: 3),
                    child: Tooltip(
                      message: cursor.name,
                      child: CircleAvatar(
                        radius: 9,
                        backgroundColor: cursor.color,
                        child: Text(cursor.name.characters.first.toUpperCase(), style: uiText(9.5, Colors.white, weight: 700)),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LeftOf extends CustomClipper<Rect> {
  _LeftOf(this.right);

  final double right;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, 0, right <= 0 ? size.width : right, size.height);

  @override
  bool shouldReclip(_LeftOf oldClipper) => oldClipper.right != right;
}

class _SwarmPainter extends CustomPainter {
  _SwarmPainter(this.app, this.swarm, this.local);

  final AppState app;
  final Swarm swarm;
  final Offset Function(Offset world) local;

  @override
  void paint(Canvas canvas, Size size) {
    final box = swarm.selection;
    if (box != null) {
      final rect = Rect.fromPoints(local(box.topLeft), local(box.bottomRight));
      final lead = swarm.leader?.color ?? const Color(0xFF0D99FF);
      canvas.drawRect(rect, Paint()..color = lead.withValues(alpha: 0.12));
      canvas.drawRect(rect, Paint()
        ..color = lead
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }
    // Wires being pulled, from their first terminal to the cursor.
    for (final cursor in swarm.cursors) {
      final from = cursor.pulling;
      if (from == null) continue;
      final a = local(app.terminalWorld(from));
      final b = local(cursor.pos);
      final width = (3.2 * app.zoom).clamp(1.6, 4.5);
      canvas.drawLine(a, b, Paint()
        ..color = Colors.black.withValues(alpha: 0.18 * cursor.alpha)
        ..strokeWidth = width + 2
        ..strokeCap = StrokeCap.round);
      canvas.drawLine(a, b, Paint()
        ..color = Color(cursor.pullColor).withValues(alpha: cursor.alpha)
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round);
      canvas.drawCircle(a, width * 1.1, Paint()..color = cursor.color.withValues(alpha: cursor.alpha));
    }
    for (final cursor in swarm.cursors) {
      _cursor(canvas, local(cursor.pos), cursor);
    }
  }

  void _cursor(Canvas canvas, Offset at, SwarmCursor cursor) {
    final scale = 1 - cursor.press * 0.15;
    final fill = Paint()..color = cursor.color.withValues(alpha: cursor.alpha);
    final outline = Paint()
      ..color = Colors.white.withValues(alpha: cursor.alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round;
    // A crisp offset shadow; a blurred one per cursor was a measurable part of every frame.
    final shadow = Paint()..color = Colors.black.withValues(alpha: 0.22 * cursor.alpha);
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.scale(scale);
    if (cursor.press > 0) {
      // A soft ring where it presses.
      canvas.drawCircle(Offset.zero, 6 + (1 - cursor.press) * 16, Paint()
        ..color = cursor.color.withValues(alpha: cursor.press * 0.5 * cursor.alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
    }
    switch (cursor.shape) {
      case CursorShape.cross:
        final cross = Path()
          ..moveTo(-9, 0)
          ..lineTo(9, 0)
          ..moveTo(0, -9)
          ..lineTo(0, 9);
        canvas.drawPath(cross, Paint()
          ..color = Colors.white.withValues(alpha: cursor.alpha)
          ..strokeWidth = 4.5
          ..strokeCap = StrokeCap.round);
        canvas.drawPath(cross, Paint()
          ..color = cursor.color.withValues(alpha: cursor.alpha)
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round);
      case CursorShape.ibeam:
        final beam = Path()
          ..moveTo(-4, -10)
          ..lineTo(4, -10)
          ..moveTo(0, -10)
          ..lineTo(0, 10)
          ..moveTo(-4, 10)
          ..lineTo(4, 10);
        canvas.drawPath(beam, Paint()
          ..color = Colors.white.withValues(alpha: cursor.alpha)
          ..strokeWidth = 4.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round);
        canvas.drawPath(beam, Paint()
          ..color = cursor.color.withValues(alpha: cursor.alpha)
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round);
      case CursorShape.arrow || CursorShape.grab || CursorShape.watch:
        final arrow = Path()
          ..moveTo(0, 0)
          ..lineTo(0, 18)
          ..lineTo(4.6, 13.8)
          ..lineTo(7.8, 20.6)
          ..lineTo(10.6, 19.3)
          ..lineTo(7.5, 12.8)
          ..lineTo(13.6, 12.8)
          ..close();
        canvas.drawPath(arrow.shift(const Offset(0.8, 1.6)), shadow);
        canvas.drawPath(arrow, fill);
        canvas.drawPath(arrow, outline);
        if (cursor.shape == CursorShape.grab) {
          // A small "+" badge: carrying something.
          canvas.drawCircle(const Offset(15, 20), 5.5, Paint()..color = Colors.white.withValues(alpha: cursor.alpha));
          canvas.drawCircle(const Offset(15, 20), 4.3, fill);
          final plus = Paint()
            ..color = Colors.white.withValues(alpha: cursor.alpha)
            ..strokeWidth = 1.4;
          canvas.drawLine(const Offset(12.6, 20), const Offset(17.4, 20), plus);
          canvas.drawLine(const Offset(15, 17.6), const Offset(15, 22.4), plus);
        } else if (cursor.shape == CursorShape.watch) {
          // An eye: watching.
          canvas.drawOval(Rect.fromCenter(center: const Offset(16, 21), width: 11, height: 7), Paint()..color = Colors.white.withValues(alpha: cursor.alpha));
          canvas.drawCircle(const Offset(16, 21), 2.2, fill);
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SwarmPainter oldDelegate) => true;
}
