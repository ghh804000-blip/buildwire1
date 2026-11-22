import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'theme.dart';

/// The "BuildWire." wordmark on the home screen. Hovering it makes small short-circuit sparks fly from under the
/// cursor: a burst on entering, a crackle while the cursor moves or rests on the letters. Nothing moves until the
/// pointer is there, and the sparks are skipped when the system asks for reduced motion.
class SparkWordmark extends StatefulWidget {
  const SparkWordmark({super.key, this.size = 96});

  final double size;

  @override
  State<SparkWordmark> createState() => _SparkWordmarkState();
}

class _Spark {
  _Spark(this.position, this.velocity, this.life) : age = 0;

  Offset position;
  Offset velocity;
  final double life;
  double age;

  double get t => (age / life).clamp(0.0, 1.0);
}

/// A short white flash where an arc strikes.
class _Flash {
  _Flash(this.position, this.radius);

  final Offset position;
  final double radius;
  double age = 0;
  static const double life = 0.09;
}

class _SparkWordmarkState extends State<SparkWordmark> with SingleTickerProviderStateMixin {
  final _random = math.Random();
  final List<_Spark> _sparks = [];
  final List<_Flash> _flashes = [];
  final _repaint = ValueNotifier<int>(0);
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  Offset? _pointer;
  double _sinceCrackle = 0;
  double _travel = 0;

  static const int _maxSparks = 90;
  static const double _gravity = 1100;

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  bool get _calm => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  void _ensureRunning() {
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  /// Throws [count] sparks from [at], mostly upward and outward like a contact arcing.
  void _burst(Offset at, int count, {double power = 1}) {
    if (_calm) return;
    for (var i = 0; i < count && _sparks.length < _maxSparks; i++) {
      final angle = -math.pi / 2 + (_random.nextDouble() - 0.5) * math.pi * 1.5;
      final speed = (140 + _random.nextDouble() * 360) * power;
      final jitter = Offset((_random.nextDouble() - 0.5) * 8, (_random.nextDouble() - 0.5) * 6);
      _sparks.add(_Spark(at + jitter, Offset(math.cos(angle), math.sin(angle)) * speed, 0.22 + _random.nextDouble() * 0.38));
    }
    _flashes.add(_Flash(at, 6 + _random.nextDouble() * 6 * power));
    _ensureRunning();
  }

  void _tick(Duration elapsed) {
    final dt = _last == Duration.zero ? 1 / 60 : ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    for (final s in _sparks) {
      s.age += dt;
      s.velocity = Offset(s.velocity.dx * (1 - 1.8 * dt), s.velocity.dy + _gravity * dt);
      s.position += s.velocity * dt;
    }
    _sparks.removeWhere((s) => s.age >= s.life);
    for (final f in _flashes) {
      f.age += dt;
    }
    _flashes.removeWhere((f) => f.age >= _Flash.life);
    // Resting on the letters, the short keeps crackling now and then.
    final pointer = _pointer;
    if (pointer != null) {
      _sinceCrackle += dt;
      if (_sinceCrackle > 0.11 + _random.nextDouble() * 0.25) {
        _sinceCrackle = 0;
        _burst(pointer, 1 + _random.nextInt(3), power: 0.7);
      }
    }
    if (_sparks.isEmpty && _flashes.isEmpty && _pointer == null) _ticker.stop();
    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final style = plateText(widget.size, tokens.text, weight: 700, height: 0.95);
    return MouseRegion(
      onEnter: (event) {
        _pointer = event.localPosition;
        _burst(event.localPosition, 14, power: 1.15);
      },
      onHover: (event) {
        final moved = _pointer == null ? 0.0 : (event.localPosition - _pointer!).distance;
        _pointer = event.localPosition;
        // More movement, more sparks: one small burst per bit of travel.
        _travel += moved;
        if (_travel > 14) {
          _travel = 0;
          _burst(event.localPosition, 2 + _random.nextInt(3));
        }
      },
      onExit: (_) => _pointer = null,
      child: CustomPaint(
        foregroundPainter: _SparkPainter(_sparks, _flashes, _repaint, tokens.hazard, dark: Theme.of(context).brightness == Brightness.dark),
        child: Semantics(
          header: true,
          label: 'BuildWire',
          child: ExcludeSemantics(
            child: Text.rich(
              TextSpan(text: 'BuildWire', children: [TextSpan(text: '.', style: TextStyle(color: tokens.hazard))]),
              maxLines: 1,
              style: style,
            ),
          ),
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.sparks, this.flashes, Listenable repaint, this.hot, {required this.dark}) : super(repaint: repaint);

  final List<_Spark> sparks;
  final List<_Flash> flashes;
  final Color hot;

  /// On a dark page sparks are white-hot; on light steel they burn yellow to orange with a thin dark edge so they
  /// still read against the pale background.
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    for (final f in flashes) {
      final fade = 1 - f.age / _Flash.life;
      final flash = dark ? const Color(0xFFFFF6D8) : hot;
      canvas.drawCircle(f.position, f.radius * (0.6 + 0.4 * fade), Paint()..color = flash.withValues(alpha: (dark ? 0.75 : 0.55) * fade));
    }
    final line = Paint()
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final s in sparks) {
      // White-hot when fresh, cooling through yellow to orange, as a short streak along its path.
      final t = s.t;
      final fresh = dark ? const Color(0xFFFFFDF2) : const Color(0xFFFFC21A);
      final warm = dark ? const Color(0xFFFFE27A) : const Color(0xFFE06A10);
      final color = t < 0.35 ? Color.lerp(fresh, warm, t / 0.35)! : Color.lerp(warm, warm.withValues(alpha: 0), (t - 0.35) / 0.65)!;
      final tail = s.velocity * 0.022;
      final width = 2.4 * (1 - t) + 0.7;
      if (!dark) {
        canvas.drawLine(s.position - tail, s.position, line
          ..color = const Color(0xFF15191C).withValues(alpha: 0.35 * (1 - t))
          ..strokeWidth = width + 1.6);
      }
      line
        ..color = color
        ..strokeWidth = width;
      canvas.drawLine(s.position - tail, s.position, line);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) => false;
}
