import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/painting.dart' show HSVColor;
import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../model/project.dart';

/// How a cursor looks while it works.
enum CursorShape { arrow, grab, cross, ibeam, watch }

/// One member of the assistant's team, drawn as a named cursor on the canvas. Positions are in world coordinates.
class SwarmCursor {
  SwarmCursor({required this.name, required this.color, required this.leader, required Offset at}) : pos = at;

  final String name;
  final Color color;

  /// The leader runs the tests and leads the others while the model thinks.
  final bool leader;

  Offset pos;
  CursorShape shape = CursorShape.arrow;

  /// 1 right after a click, fading back to 0: the cursor dips while pressing.
  double press = 0;

  /// A short line under the name, such as "mengamati KM2".
  String? note;

  /// A device being dragged in: its id, drawn as a see-through ghost under the cursor.
  String? carrying;

  /// A wire being pulled from this terminal to the cursor, and its color.
  TerminalRef? pulling;
  int pullColor = 0xFFB3261E;

  bool busy = false;

  /// Opacity, for arriving and leaving.
  double alpha = 0;
  bool leaving = false;

  _Move? _move;
  final double _seed = math.Random().nextDouble() * 1000;
}

class _Move {
  _Move(this.from, this.to, this.bend, this.duration, this.drag) : done = Completer<void>();

  final Offset from;
  final Offset to;

  /// Sideways bulge of the path, so moves curve like a hand instead of running on rails.
  final Offset bend;
  final double duration;
  final bool drag;
  double t = 0;
  final Completer<void> done;
}

/// PLC code being typed into a card above the PLC.
class SwarmCard {
  SwarmCard(this.deviceId, this.lines);

  final int deviceId;
  final List<String> lines;
  int shown = 0;
  double fade = 1;

  int get total => lines.fold(0, (sum, line) => sum + line.length + 1);
}

/// The assistant's team of cursors and the camera that follows their work.
///
/// Every edit the assistant makes goes through here when a canvas is on screen: a cursor travels, presses, drags,
/// and only then is the change applied, so what the user sees is what happened. With no canvas (tests, or before the
/// workspace opens) [animated] is false and the tools apply changes at once.
class Swarm extends ChangeNotifier {
  Swarm(this.app);

  final AppState app;
  final List<SwarmCursor> cursors = [];
  final math.Random _random = math.Random();

  /// How many overlays are on screen. A count, not a flag: when the canvas rebuilds, the new overlay attaches before
  /// the old one detaches.
  int _attached = 0;
  bool get animated => _attached > 0;

  void attach() => _attached++;
  void detach() {
    _attached = (_attached - 1).clamp(0, 1 << 30);
    // Nothing will drive the moves any more: let whoever waits on them carry on rather than hang.
    if (_attached == 0) _releaseMoves();
  }

  void _releaseMoves() {
    for (final cursor in cursors) {
      final move = cursor._move;
      if (move == null) continue;
      cursor.pos = move.to;
      cursor._move = null;
      if (!move.done.isCompleted) move.done.complete();
    }
  }

  /// The model is thinking: idle cursors circle their leader.
  bool thinking = false;
  bool cancelled = false;

  SwarmCard? card;

  /// A selection box being dragged, in world coordinates.
  Rect? selection;

  double _time = 0;
  Rect? _cameraTarget;

  /// The canvas's top-left corner in global coordinates, kept current by the overlay. Cursors live in world
  /// coordinates; a spot in the device library, left of the canvas, simply has a negative world x.
  Offset canvasOrigin = Offset.zero;

  Offset worldOfGlobal(Offset global) => app.toWorld(global - canvasOrigin);

  static const int maxTeam = 16;

  static const List<Color> palette = [
    Color(0xFFF24E1E), Color(0xFFA259FF), Color(0xFF1ABCFE), Color(0xFF0ACF83), Color(0xFFFF7262), //
    Color(0xFFFFB020), Color(0xFF7B61FF), Color(0xFFE91E8C), Color(0xFF00B5AD), Color(0xFF3D7BFF),
  ];

  static const List<String> _fallbackNames = [
    'Bima', 'Sari', 'Joko', 'Ratna', 'Dimas', 'Laras', 'Tegar', 'Nadia', 'Raka', 'Wulan', 'Bayu', 'Intan', 'Gilang', 'Putri', //
    'Ucok', 'Mega', 'Danu', 'Kirana', 'Arya', 'Tiwi',
  ];

  SwarmCursor? get leader => cursors.where((c) => c.leader && !c.leaving).firstOrNull;
  List<SwarmCursor> get members => cursors.where((c) => !c.leaving).toList();
  bool get needsTick => cursors.isNotEmpty || card != null || selection != null || _cameraTarget != null;

  /// Where a newcomer enters: just inside the canvas's left edge, as if coming from the device library.
  Offset _entry([double? y]) {
    final size = app.canvasSize == Size.zero ? const Size(800, 600) : app.canvasSize;
    return app.toWorld(Offset(-24, y ?? size.height * (0.3 + _random.nextDouble() * 0.4)));
  }

  /// Forms the team: the first name leads. Called by the model through the team tool, or with made-up names.
  List<SwarmCursor> formTeam(List<String> names) {
    if (!animated) {
      _releaseMoves();
      cursors.clear();
    } else {
      for (final cursor in cursors) {
        cursor.leaving = true;
      }
    }
    final unique = <String>[];
    for (final raw in names) {
      final name = raw.trim();
      if (name.isNotEmpty && !unique.contains(name) && unique.length < maxTeam) unique.add(name.length > 18 ? name.substring(0, 18) : name);
    }
    while (unique.length < 2) {
      final name = _fallbackNames[_random.nextInt(_fallbackNames.length)];
      if (!unique.contains(name)) unique.add(name);
    }
    final offset = _random.nextInt(palette.length);
    final team = [
      for (var i = 0; i < unique.length; i++)
        SwarmCursor(name: unique[i], color: _colorFor(i, offset, unique.length), leader: i == 0, at: _entry()),
    ];
    cursors.addAll(team);
    notifyListeners();
    return team;
  }

  /// The palette for up to ten; beyond that, hues spread evenly around the wheel so no two look alike.
  Color _colorFor(int index, int offset, int size) {
    if (size <= palette.length) return palette[(offset + index * 3) % palette.length];
    return HSVColor.fromAHSV(1, (offset * 36 + index * 360 / size) % 360, 0.72, 0.92).toColor();
  }

  /// A team of made-up names when the model didn't name one, sized by how much there is to do.
  void ensureTeam({int work = 4}) {
    if (members.isNotEmpty) return;
    final size = (3 + work ~/ 5).clamp(3, 12);
    final names = [..._fallbackNames]..shuffle(_random);
    formTeam(names.take(size).toList());
  }

  void begin() {
    cancelled = false;
    thinking = true;
    notifyListeners();
  }

  /// Sends everyone off the canvas and clears the stage.
  void finish() {
    thinking = false;
    _cameraTarget = null;
    if (!animated) {
      _releaseMoves();
      cursors.clear();
      card = null;
      selection = null;
      notifyListeners();
      return;
    }
    for (final cursor in cursors) {
      cursor.leaving = true;
      cursor.note = null;
      cursor.carrying = null;
      cursor.pulling = null;
      final exit = _entry(app.toScreen(cursor.pos).dy);
      _startMove(cursor, exit, drag: false, speed: 1.4);
    }
    notifyListeners();
  }

  void cancel() {
    cancelled = true;
    _releaseMoves();
  }

  // ----- Camera

  /// Points the camera at the area being built, easing there over the next frames.
  void focus(Iterable<Rect> rects) {
    final list = rects.toList();
    if (list.isEmpty) return;
    _cameraTarget = list.reduce((a, b) => a.expandToInclude(b));
    notifyListeners();
  }

  void _stepCamera(double dt) {
    final target = _cameraTarget;
    final size = app.canvasSize;
    if (target == null || size == Size.zero) return;
    const margin = 70.0;
    final zoom = math.min(1.0, math.min((size.width - margin * 2) / math.max(target.width, 1), (size.height - margin * 2) / math.max(target.height, 1))).clamp(0.2, 1.0);
    final pan = Offset(size.width / 2 - target.center.dx * zoom, size.height / 2 - target.center.dy * zoom);
    final k = 1 - math.exp(-dt * 3.2);
    final nextZoom = app.zoom + (zoom - app.zoom) * k;
    final nextPan = Offset.lerp(app.pan, pan, k)!;
    if ((nextZoom - app.zoom).abs() < 0.0005 && (nextPan - app.pan).distance < 0.3) return;
    app.setView(nextPan, nextZoom);
  }

  // ----- Motion

  void _startMove(SwarmCursor cursor, Offset to, {required bool drag, double speed = 1}) {
    final previous = cursor._move;
    if (previous != null && !previous.done.isCompleted) previous.done.complete();
    final from = cursor.pos;
    final screenDistance = (to - from).distance * app.zoom;
    final duration = (0.16 + math.sqrt(screenDistance) * 0.022).clamp(0.18, 0.95) / speed * (drag ? 1.25 : 1);
    final normal = (to - from).distance < 1 ? Offset.zero : Offset(-(to - from).dy, (to - from).dx) / (to - from).distance;
    final bend = normal * (from - to).distance * (0.04 + _random.nextDouble() * 0.1) * (_random.nextBool() ? 1 : -1);
    cursor._move = _Move(from, to, bend, duration, drag);
  }

  /// Moves a cursor and resolves when it arrives (at once when cancelled).
  Future<void> moveTo(SwarmCursor cursor, Offset to, {bool drag = false, double speed = 1}) {
    if (cancelled || !animated) {
      cursor.pos = to;
      return Future.value();
    }
    _startMove(cursor, to, drag: drag, speed: speed);
    final move = cursor._move!;
    // A move finishes on the overlay's frames. When frames stop (window minimized, overlay rebuilt), don't wait
    // forever: jump to the end a little after it should have arrived.
    return move.done.future.timeout(Duration(milliseconds: (move.duration * 1000).round() + 1500), onTimeout: () {
      if (identical(cursor._move, move)) {
        cursor.pos = move.to;
        cursor._move = null;
      }
      if (!move.done.isCompleted) move.done.complete();
    });
  }

  Future<void> wait(double seconds) => cancelled || !animated ? Future.value() : Future.delayed(Duration(milliseconds: (seconds * 1000).round()));

  static double _easeInOut(double t) => t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2;
  static double _easeOut(double t) => 1 - math.pow(1 - t, 3).toDouble();

  /// Advances every cursor, the typing card and the camera. Driven by the overlay's ticker.
  void tick(double dt) {
    _time += dt;
    final lead = leader;
    final active = members;
    for (var i = 0; i < cursors.length; i++) {
      final cursor = cursors[i];
      cursor.alpha = (cursor.alpha + (cursor.leaving ? -dt * 2.2 : dt * 3)).clamp(0.0, 1.0);
      cursor.press = math.max(0, cursor.press - dt * 6);
      final move = cursor._move;
      if (move != null) {
        move.t = math.min(1, move.t + dt / move.duration);
        final e = move.drag ? _easeInOut(move.t) : _easeOut(move.t);
        cursor.pos = Offset.lerp(move.from, move.to, e)! + move.bend * math.sin(math.pi * e);
        if (move.t >= 1) {
          cursor._move = null;
          if (!move.done.isCompleted) move.done.complete();
        }
      } else if (!cursor.busy && !cursor.leaving && lead != null) {
        // Idle: drift in a loose ring around the leader, the leader floating over the work.
        final center = _cameraTarget?.center ?? lead.pos;
        final Offset goal;
        if (cursor.leader) {
          goal = center + Offset(math.sin(_time * 0.37 + cursor._seed) * 70, math.cos(_time * 0.53 + cursor._seed) * 45) / app.zoom.clamp(0.3, 1.0);
        } else {
          final index = active.indexOf(cursor);
          final angle = _time * (thinking ? 0.9 : 0.35) + index * 2 * math.pi / math.max(1, active.length - 1);
          final radius = (thinking ? 95 : 130) + 18 * math.sin(_time * 0.8 + cursor._seed);
          goal = lead.pos + Offset(math.cos(angle), math.sin(angle)) * radius / app.zoom.clamp(0.3, 1.0);
        }
        final k = 1 - math.exp(-dt * (cursor.leader ? 1.2 : 2.4));
        cursor.pos = Offset.lerp(cursor.pos, goal, k)!;
      }
    }
    cursors.removeWhere((c) => c.leaving && c.alpha <= 0 && c._move == null);

    final typing = card;
    if (typing != null && typing.shown >= typing.total && typing.fade < 1) {
      typing.fade -= dt * 1.5;
      if (typing.fade <= 0) card = null;
    }
    _stepCamera(dt);
    notifyListeners();
  }

  // ----- Work

  /// Shares [items] among the free cursors: each takes the next one when it finishes the last. Stops handing out work
  /// once cancelled.
  Future<void> share<T>(List<T> items, Future<void> Function(SwarmCursor cursor, T item) work, {bool withLeader = true}) async {
    ensureTeam(work: items.length);
    final crew = members.where((c) => withLeader || !c.leader).toList();
    if (crew.isEmpty) crew.addAll(members);
    var next = 0;
    Future<void> worker(SwarmCursor cursor, int stagger) async {
      await wait(stagger * 0.12);
      while (next < items.length && !cancelled) {
        final item = items[next++];
        cursor.busy = true;
        try {
          await work(cursor, item);
        } finally {
          cursor.busy = false;
        }
      }
    }

    await Future.wait([for (var i = 0; i < crew.length; i++) worker(crew[i], i)]);
  }

  void _click(SwarmCursor cursor) {
    cursor.press = 1;
  }

  /// Takes a device from the library on the left (opening its group if it is folded) and drags it to [target]
  /// (world). [apply] adds it on the drop.
  Future<void> placeDevice(SwarmCursor cursor, String defId, Rect target, VoidCallback apply) async {
    if (!animated || cancelled) {
      if (!cancelled) apply();
      return;
    }
    cursor.shape = CursorShape.arrow;
    final library = app.library;
    Rect? card;
    if (library != null) {
      if (!library.isOpen(defId)) {
        final header = library.groupRect(defId);
        if (header != null) {
          cursor.note = 'buka kelompok';
          await moveTo(cursor, worldOfGlobal(header.centerLeft + Offset(math.min(60, header.width * 0.3), 0)), speed: 1.3);
          if (cancelled) return;
          _click(cursor);
        }
      }
      card = await library.reveal(defId);
      cursor.note = null;
      if (cancelled) return;
    }
    if (card != null) {
      await moveTo(cursor, worldOfGlobal(card.center), speed: 1.3);
      // The library may have scrolled while the cursor travelled; land on where the card is now.
      final settled = await library!.reveal(defId);
      if (settled != null) cursor.pos = worldOfGlobal(settled.center);
    } else {
      await moveTo(cursor, _entry(app.toScreen(target.center).dy.clamp(40, math.max(60, app.canvasSize.height - 40))), speed: 1.6);
    }
    if (cancelled) return;
    await _warm(defId);
    cursor.carrying = defId;
    cursor.shape = CursorShape.grab;
    _click(cursor);
    await wait(0.08);
    await moveTo(cursor, target.center, drag: true);
    if (cancelled) {
      cursor.carrying = null;
      return;
    }
    _click(cursor);
    cursor.carrying = null;
    cursor.shape = CursorShape.arrow;
    apply();
    app.playSound('button_release');
    await wait(0.05 + _random.nextDouble() * 0.1);
  }

  /// Clicks terminal [a], pulls a wire across to [b] and clicks it. [apply] lays the wire on the second click.
  Future<void> connect(SwarmCursor cursor, TerminalRef a, TerminalRef b, int color, VoidCallback apply) async {
    if (!animated || cancelled) {
      if (!cancelled) apply();
      return;
    }
    cursor.shape = CursorShape.cross;
    await moveTo(cursor, app.terminalWorld(a));
    if (cancelled) return;
    _click(cursor);
    cursor.pulling = a;
    cursor.pullColor = color;
    await wait(0.06);
    await moveTo(cursor, app.terminalWorld(b), drag: true);
    cursor.pulling = null;
    if (cancelled) return;
    _click(cursor);
    apply();
    app.playSound('wire_connect');
    cursor.shape = CursorShape.arrow;
    await wait(0.04 + _random.nextDouble() * 0.08);
  }

  /// Points at a spot and clicks it. [apply] runs on the click.
  Future<void> clickAt(SwarmCursor cursor, Offset world, VoidCallback apply) async {
    if (!animated || cancelled) {
      if (!cancelled) apply();
      return;
    }
    cursor.shape = CursorShape.arrow;
    await moveTo(cursor, world);
    if (cancelled) return;
    _click(cursor);
    apply();
    await wait(0.08);
  }

  /// Points at a device and clicks it. [apply] runs on the click.
  Future<void> clickDevice(SwarmCursor cursor, PlacedDevice device, VoidCallback apply, {String? note}) async {
    if (!animated || cancelled) {
      if (!cancelled) apply();
      return;
    }
    cursor.shape = CursorShape.arrow;
    cursor.note = note;
    await moveTo(cursor, _deviceCenter(device));
    if (cancelled) return;
    _click(cursor);
    apply();
  }

  /// Holds a press on a device for [seconds], then lets go.
  Future<void> pressDevice(SwarmCursor cursor, PlacedDevice device, void Function(bool down) apply, {double seconds = 0.35, String? note}) async {
    if (!animated || cancelled) {
      if (!cancelled) {
        apply(true);
        apply(false);
      }
      return;
    }
    cursor.note = note;
    await moveTo(cursor, _deviceCenter(device));
    if (cancelled) return;
    _click(cursor);
    apply(true);
    await wait(seconds);
    apply(false);
  }

  /// Hovers over a device for [seconds] with a note, watching it.
  Future<void> watch(SwarmCursor cursor, PlacedDevice? device, double seconds, String note) async {
    if (!animated || cancelled) return;
    cursor.shape = CursorShape.watch;
    cursor.note = note;
    if (device != null) {
      await moveTo(cursor, _deviceCenter(device) + Offset(30 + _random.nextDouble() * 30, -20 - _random.nextDouble() * 30) / app.zoom.clamp(0.3, 1.0), speed: 0.8);
    }
    await wait(seconds);
    cursor.shape = CursorShape.arrow;
    cursor.note = null;
  }

  /// Types PLC code into a card above the PLC, then [apply]s it.
  Future<void> typeProgram(SwarmCursor cursor, PlacedDevice plc, List<String> lines, VoidCallback apply) async {
    if (!animated || cancelled) {
      if (!cancelled) apply();
      return;
    }
    cursor.shape = CursorShape.ibeam;
    final def = app.defOf(plc);
    await moveTo(cursor, Offset(plc.x + def.width * 0.5, plc.y - 30 / app.zoom.clamp(0.3, 1.0)));
    if (cancelled) return;
    final typing = SwarmCard(plc.id, lines);
    card = typing;
    // About 4 seconds at most, however long the program.
    final perChar = (4.0 / math.max(1, typing.total)).clamp(0.004, 0.03);
    while (typing.shown < typing.total && !cancelled) {
      typing.shown = math.min(typing.total, typing.shown + math.max(1, (0.016 / perChar).round()));
      if (_random.nextInt(9) == 0) app.playSound('button_press');
      await wait(0.016 + _random.nextDouble() * perChar);
    }
    typing.shown = typing.total;
    typing.fade = 0.99;
    cursor.shape = CursorShape.arrow;
    if (!cancelled) apply();
  }

  /// Drags a selection box over [area], then [apply] (clearing it).
  Future<void> sweep(SwarmCursor cursor, Rect area, VoidCallback apply) async {
    if (!animated || cancelled) {
      if (!cancelled) apply();
      return;
    }
    cursor.shape = CursorShape.cross;
    await moveTo(cursor, area.topLeft);
    if (cancelled) return;
    _click(cursor);
    final start = area.topLeft;
    final drag = moveTo(cursor, area.bottomRight, drag: true);
    while (cursor._move != null && !cancelled) {
      selection = Rect.fromPoints(start, cursor.pos);
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    await drag;
    selection = Rect.fromPoints(start, area.bottomRight);
    await wait(0.25);
    selection = null;
    cursor.shape = CursorShape.arrow;
    if (!cancelled) apply();
  }

  /// Device pictures already decoded, so dropping one never shows a blank frame.
  final Set<String> _warmed = {};

  /// Set by the overlay: decodes a device's picture into the image cache.
  Future<void> Function(String defId)? precache;

  Future<void> _warm(String defId) async {
    final load = precache;
    if (load == null || !_warmed.add(defId)) return;
    try {
      await load(defId).timeout(const Duration(milliseconds: 600));
    } catch (_) {}
  }

  Offset _deviceCenter(PlacedDevice device) {
    final def = app.defOf(device);
    return Offset(device.x + def.width / 2, device.y + def.height / 2);
  }

  double nextRandom() => _random.nextDouble();
}
