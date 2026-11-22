import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:buildwire/ai/ai_settings.dart';
import 'package:buildwire/app_state.dart';
import 'package:buildwire/main.dart';
import 'package:buildwire/model/device_def.dart';
import 'package:buildwire/model/project.dart';
import 'package:buildwire/sim/ladder.dart';
import 'package:buildwire/sim/plc.dart';
import 'package:buildwire/sim/solver.dart';
import 'package:buildwire/sound.dart';
import 'package:buildwire/templates.dart';
import 'package:buildwire/ui/canvas_view.dart';

class SilentSound extends SoundPlayer {
  final played = <String>[];
  Set<String> loops = {};
  final Map<String, (double, double)> mix = {};

  @override
  Future<void> mixLoop(String name, double volume, double rate) async => mix[name] = (volume, rate);

  @override
  Future<void> play(String name, bool enabled) async {
    if (enabled) played.add(name);
  }

  @override
  Future<void> setLoops(Set<String> names) async => loops = names;

  @override
  Future<void> preload(Iterable<String> names) async {}

  int shotsStopped = 0;

  @override
  Future<void> stopShots() async => shotsStopped++;

  /// Loops actually heard: playing and not mixed down to silence.
  Set<String> get audible => {for (final l in loops) if ((mix[l]?.$1 ?? 1) > 0.01) l};

  Iterable<String> get audibleMotor => audible.where((l) => l.startsWith('motor_run_3p_'));

  /// The speed the 3-phase motor sound is pitched at: its layers' speeds weighted by volume, 0 when silent.
  double get motorPitch {
    var sum = 0.0, weight = 0.0;
    for (final speed in AppState.rotorLayers) {
      final volume = mix['motor_run_3p_${(speed * 100).round()}']?.$1 ?? 0;
      sum += volume * volume * speed;
      weight += volume * volume;
    }
    return weight == 0 ? 0 : sum / weight;
  }

  bool get motorReady => loops.containsAll(AppState.rotorLayerNames('motor_run_3p'));
}

AppState buildApp({SoundPlayer? sound}) {
  final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
  final defs = {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
  return AppState(defs, null, sound: sound ?? SilentSound());
}

Future<AppState> pumpApp(WidgetTester tester, {bool home = false}) async {
  tester.view.physicalSize = const Size(1500, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = buildApp();
  if (!home) app.openBuilder();
  await tester.pumpWidget(BuildWireApp(app: app));
  await tester.pump();
  return app;
}

PlacedDevice byTag(AppState app, String tag) => app.project.devices.firstWhere((d) => d.tag == tag);

void main() {
  testWidgets('the welcome screen opens first, leads into the project and back, and links the site', (tester) async {
    final app = await pumpApp(tester, home: true);
    await tester.pump(const Duration(milliseconds: 1200));
    expect(find.byKey(const ValueKey('home-screen')), findsOneWidget);
    expect(find.text('rifqi.id'), findsOneWidget);
    expect(find.text('Buka kanvas'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-project')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.showHome, isFalse);
    expect(find.text('Kanvas masih kosong'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.showHome, isTrue);
    expect(find.byKey(const ValueKey('home-screen')), findsOneWidget);
    app.dispose();
  });

  testWidgets('keys typed in a text field reach it instead of firing workspace shortcuts', (tester) async {
    final app = await pumpApp(tester);
    app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'lamp'));
    app.aiSettings = const AiSettings(baseUrl: 'https://hub.example/v1', format: ApiFormat.openai, model: 'm');
    app.toggleAiPanel();
    await tester.pump();
    app.selectDevice(app.project.devices.first.id);
    final devices = app.project.devices.length;

    await tester.tap(find.byKey(const ValueKey('ai-input')));
    await tester.pump();
    for (final key in [LogicalKeyboardKey.keyK, LogicalKeyboardKey.keyJ, LogicalKeyboardKey.delete]) {
      await tester.sendKeyEvent(key);
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(app.jumperMode, isFalse, reason: 'J went to the text field');
    expect(app.project.devices.length, devices, reason: 'Delete went to the text field');
    expect(app.selectedDevices.length, 1, reason: 'Ctrl+A selected text, not every device');

    // Outside a text field the shortcuts still work: clicking empty canvas gives it the keyboard back.
    await tester.tapAt(tester.getBottomRight(find.byType(CanvasView)) - const Offset(30, 30));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    expect(app.jumperMode, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    expect(app.jumperMode, isFalse);
    app.dispose();
  });

  testWidgets('a template card on the welcome screen starts that circuit in the builder', (tester) async {
    final app = await pumpApp(tester, home: true);
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.tap(find.byKey(const ValueKey('home-template-lamp')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.showHome, isFalse);
    expect(app.project.devices.length, 5);
    app.dispose();
  });

  testWidgets('choosing a template and operating it through the real widgets', (tester) async {
    final app = await pumpApp(tester);
    expect(find.text('Kanvas masih kosong'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('open-templates')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('template-lamp')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.project.devices.length, 5);

    await tester.tap(find.byKey(const ValueKey('run-button')));
    await tester.pump();
    expect(app.running, isTrue);
    expect(find.text('Hentikan'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('device-QF1')));
    await tester.pump();
    expect(app.stateOf(byTag(app, 'QF1')), 'on');

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('device-S1'))));
    await tester.pump();
    expect(app.stateOf(byTag(app, 'S1')), 'on');
    expect(app.stateOf(byTag(app, 'KM1')), 'closed');
    expect(app.stateOf(byTag(app, 'HL1')), 'on');
    await gesture.up();
    await tester.pump();
    expect(app.stateOf(byTag(app, 'HL1')), 'off');

    await tester.tap(find.byKey(const ValueKey('run-button')));
    await tester.pump();
    app.dispose();
  });

  testWidgets('the welcome screen works from the keyboard: Tab reaches each action and Enter runs it', (tester) async {
    final app = await pumpApp(tester, home: true);
    await tester.pump(const Duration(milliseconds: 300));
    // Tab until the primary action has focus; every stop on the way must be a real control.
    var reached = false;
    for (var i = 0; i < 12 && !reached; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      reached = focused != null && find.ancestor(of: find.byElementPredicate((e) => e == focused), matching: find.byKey(const ValueKey('home-project'))).evaluate().isNotEmpty;
    }
    expect(reached, isTrue, reason: 'Tab reaches "Buka kanvas"');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.showHome, isFalse, reason: 'Enter on the focused button opens the canvas');
    app.dispose();
  });

  testWidgets('clicking two terminals makes a wire with an automatic color, and undo removes it', (tester) async {
    final app = await pumpApp(tester);
    app.addDevice('generic_source_ac', world: const Offset(200, 200));
    app.addDevice('foco_led', world: const Offset(600, 200));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('terminal-G1-L')));
    await tester.pump();
    expect(app.pending, isNotNull);
    await tester.tap(find.byKey(const ValueKey('terminal-HL1-F')));
    await tester.pump();
    expect(app.project.wires.single.color, kLabelColors['L1']);
    expect(app.project.wires.single.isJumper, isFalse);

    app.undo();
    await tester.pump();
    expect(app.project.wires, isEmpty);
    app.redo();
    expect(app.project.wires.length, 1);
  });

  testWidgets('jumper mode makes a straight jumper', (tester) async {
    final app = await pumpApp(tester);
    app.addDevice('chint_nxc32', world: const Offset(400, 300));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('mode-jumper')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mode-jumper')));
    await tester.pump();
    expect(app.jumperMode, isTrue);
    await tester.tap(find.byKey(const ValueKey('terminal-KM1-2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-KM1-4')));
    await tester.pump();
    final wire = app.project.wires.single;
    expect(wire.isJumper, isTrue);
    expect(app.routeWorld(wire).length, 2);

    // The jumper lies on top of the contactor: clicking it picks the jumper, not the contactor, so Del removes it.
    await tester.tap(find.byKey(const ValueKey('mode-jumper')));
    await tester.pump();
    app.clearSelection();
    final points = app.wirePoints(wire);
    // Route points are canvas coordinates; the tap needs screen ones.
    final origin = tester.getTopLeft(find.byType(CanvasView));
    await tester.tapAt(origin + (points.first + points.last) / 2);
    await tester.pump();
    expect(app.selectedWire, wire.id);
    expect(app.selectedDevices, isEmpty);
    app.deleteSelection();
    expect(app.project.wires, isEmpty);
  });

  testWidgets('a wire is drawn like in Proteus: left-click places bends, right-click drops it', (tester) async {
    final app = await pumpApp(tester);
    app.addDevice('generic_source_ac', world: const Offset(200, 200));
    app.addDevice('foco_led', world: const Offset(700, 200));
    await tester.pump();
    final area = tester.getRect(find.byType(CanvasView));
    Offset free(double fx, double fy) => Offset(area.left + area.width * fx, area.top + area.height * fy);

    // Right-click cancels.
    await tester.tap(find.byKey(const ValueKey('terminal-G1-L')));
    await tester.pump();
    expect(app.pending, isNotNull);
    await tester.tapAt(free(0.5, 0.92), buttons: kSecondaryButton);
    await tester.pump();
    expect(app.pending, isNull);
    expect(app.project.wires, isEmpty);

    // Left-click on empty canvas adds bends; the finished wire runs through them.
    await tester.tap(find.byKey(const ValueKey('terminal-G1-L')));
    await tester.pump();
    await tester.tapAt(free(0.3, 0.9));
    await tester.pump();
    await tester.tapAt(free(0.7, 0.9));
    await tester.pump();
    expect(app.pendingCorners, hasLength(2));
    expect(app.pending, isNotNull, reason: 'clicking empty canvas no longer cancels');
    await tester.tap(find.byKey(const ValueKey('terminal-HL1-F')));
    await tester.pump();
    final wire = app.project.wires.single;
    expect(wire.points, hasLength(2));
    final route = app.routeWorld(wire);
    for (final corner in wire.points!) {
      expect(route.any((p) => (p - Offset(corner.x, corner.y)).distance < 0.01), isTrue, reason: 'the route goes through each bend');
    }
    for (var i = 0; i + 1 < route.length; i++) {
      expect((route[i].dx - route[i + 1].dx).abs() < 0.01 || (route[i].dy - route[i + 1].dy).abs() < 0.01, isTrue);
    }
    expect(app.pendingCorners, isEmpty);
  });

  test('an overload relay plugs onto a contactor, travels with it, and comes off again', () {
    final app = buildApp();
    app.addDevice('chint_nxc32', world: const Offset(400, 300));
    final contactor = app.project.devices.single;
    final socket = app.terminalWorld(TerminalRef(contactor.id, '4'));
    // Dropped a little off its seat, it snaps in under the contactor, centred on its 4/T2.
    app.addDevice('chint_nr2_25', world: socket + const Offset(30, 140));
    final tor = app.project.devices.last;
    expect((app.terminalWorld(TerminalRef(tor.id, '3')).dx - socket.dx).abs(), lessThan(1));
    expect(tor.y, lessThan(contactor.y + app.defOf(contactor).height), reason: 'its top tucks behind the contactor');
    expect(app.project.wires, isEmpty, reason: 'plugged in, not wired: no jumpers are drawn');
    expect(tor.data['seated_on'], contactor.id);
    expect(app.terminalCovered(TerminalRef(contactor.id, '2')), isFalse, reason: 'the contactor terminals still take wires');
    expect(app.terminalCovered(TerminalRef(tor.id, '1')), isTrue);
    expect(app.terminalCovered(TerminalRef(tor.id, '95')), isFalse);

    app.beginMove(contactor.id);
    app.moveSelectionBy(const Offset(200, 0));
    app.endMove();
    expect((app.terminalWorld(TerminalRef(tor.id, '3')).dx - app.terminalWorld(TerminalRef(contactor.id, '4')).dx).abs(), lessThan(1), reason: 'it rides along');

    app.beginMove(tor.id);
    app.moveSelectionBy(const Offset(0, 400));
    app.endMove();
    expect(tor.data.containsKey('seated_on'), isFalse, reason: 'pulled off, the pins no longer connect');
    expect(app.terminalCovered(TerminalRef(contactor.id, '2')), isFalse);
    app.dispose();
  });

  test('a DOL starter still runs with its overload relay plugged straight onto the contactor', () {
    final app = buildApp()..applyTemplate(kTemplates.firstWhere((t) => t.id == 'dol'));
    final km = byTag(app, 'KM1'), tor = byTag(app, 'F1');
    // Drag the relay up under the contactor: it plugs in, and the three short wires between them go.
    final seat = (app.defOf(tor).torPanel!['seat'] as num).toDouble() * app.defOf(tor).height;
    final under = Offset(app.terminalWorld(TerminalRef(km.id, '4')).dx - app.terminalWorld(TerminalRef(tor.id, '3')).dx, km.y + app.defOf(km).height - seat - tor.y);
    app.beginMove(tor.id);
    app.moveSelectionBy(under + const Offset(15, 20));
    app.endMove();
    expect(tor.data['seated_on'], km.id);
    for (final (c, t) in const [('2', '1'), ('4', '3'), ('6', '5')]) {
      expect(app.project.wires.any((w) => w.connects(TerminalRef(km.id, c), TerminalRef(tor.id, t))), isFalse);
    }
    app.startSimulation();
    app.clickDevice(byTag(app, 'QF1'));
    app.clickDevice(byTag(app, 'F2'));
    app.pressDevice(byTag(app, 'S1'), true);
    app.pressDevice(byTag(app, 'S1'), false);
    expect(app.stateOf(byTag(app, 'M1')), 'run_fwd', reason: 'power reaches the motor through the plugged-in pins');
    app.stopSimulation();
    app.dispose();
  });

  testWidgets('dragging the corner grip of a selected part resizes it, in one undo step', (tester) async {
    final app = await pumpApp(tester);
    app.addDevice('chint_nxc32', world: const Offset(400, 300));
    await tester.pump();
    final km = app.project.devices.single;
    final width = app.defOf(km).width;
    final topLeft = Offset(km.x, km.y);
    final grip = find.byKey(const ValueKey('resize-handle'));
    expect(grip, findsOneWidget);
    // Moved in small steps, as a mouse does.
    final gesture = await tester.startGesture(tester.getCenter(grip));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(10, 10));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    expect(app.scaleOf(km), greaterThan(1.2));
    expect(Offset(km.x, km.y), topLeft, reason: 'the opposite corner stays put');
    app.undo();
    expect(app.defOf(app.project.devices.single).width, width);
  });

  test('the overload relay front works: STOP opens the control circuit while held, TEST trips, RESET clears it', () {
    final app = buildApp()..applyTemplate(kTemplates.firstWhere((t) => t.id == 'dol'));
    final tor = byTag(app, 'F1');
    app.startSimulation();
    app.clickDevice(byTag(app, 'QF1'));
    app.clickDevice(byTag(app, 'F2'));
    app.pressDevice(byTag(app, 'S1'), true);
    app.pressDevice(byTag(app, 'S1'), false);
    expect(app.stateOf(byTag(app, 'KM1')), 'closed');

    app.torKey(tor, 'stop', true);
    expect(app.stateOf(tor), 'stop');
    expect(app.stateOf(byTag(app, 'KM1')), 'open', reason: '95-96 opens, so the contactor drops out');
    app.torKey(tor, 'stop', false);
    expect(app.stateOf(tor), 'normal');
    expect(app.stateOf(byTag(app, 'KM1')), 'open', reason: 'the self-hold is gone, as in a real starter');

    app.torKey(tor, 'test', true);
    expect(app.stateOf(tor), 'tripped');
    app.torKey(tor, 'reset', true);
    expect(app.stateOf(tor), 'normal');

    app.setTorCurrent(tor, 100);
    expect(app.number(tor, 'rated_current_a'), 25, reason: 'the dial stops at its printed maximum');
    app.setTorCurrent(tor, 19.3);
    expect(app.number(tor, 'rated_current_a'), 19.5, reason: 'half-amp steps');
    app.stopSimulation();
    app.dispose();
  });

  test('an analog timer knob turns within its range', () {
    final app = buildApp();
    app.addDevice('selec_800s', world: const Offset(300, 300));
    final timer = app.project.devices.single;
    app.turnTimerKnob(timer, 12.34);
    expect(app.timeOf(timer), 12);
    app.turnTimerKnob(timer, 999, done: true);
    expect(app.timeOf(timer), 60);
    app.turnTimerKnob(timer, 0);
    expect(app.timeOf(timer), 0.5);
    app.dispose();
  });

  test('a part can be resized; its terminals and wires follow, and undo puts it back', () {
    final app = buildApp()..applyTemplate(kTemplates.firstWhere((t) => t.id == 'lamp'));
    final km = byTag(app, 'KM1');
    final width = app.defOf(km).width;
    final centre = Rect.fromLTWH(km.x, km.y, width, app.defOf(km).height).center;
    final wire = app.project.wires.firstWhere((w) => w.touches(km.id));
    final end = wire.a.deviceId == km.id ? wire.a : wire.b;
    app.beginControlEdit();
    app.setDeviceScale(km, 1.5);
    app.endControlEdit();
    expect(app.defOf(km).width, closeTo(width * 1.5, 0.01));
    expect(Rect.fromLTWH(km.x, km.y, app.defOf(km).width, app.defOf(km).height).center, offsetMoreOrLessEquals(centre, epsilon: 0.01), reason: 'resized around its centre');
    final route = app.routeWorld(wire);
    expect(route.contains(app.terminalWorld(end)), isTrue, reason: 'the wire still ends on the moved terminal');
    expect(app.defs[km.defId]!.width, width, reason: 'the catalogue entry is unchanged');
    app.undo();
    expect(app.defOf(byTag(app, 'KM1')).width, width);
    app.dispose();
  });

  test('automatic layout puts the power circuit top to bottom on the left and the controls on the right', () {
    final app = buildApp()..applyTemplate(kTemplates.firstWhere((t) => t.id == 'dol'));
    final before = {for (final d in app.project.devices) d.id: Offset(d.x, d.y)};
    app.autoArrange();
    double top(String tag) => byTag(app, tag).y;
    expect(top('G1'), lessThan(top('QF1')));
    expect(top('QF1'), lessThan(top('KM1')));
    expect(top('KM1'), lessThan(top('F1')));
    expect(top('F1'), lessThan(top('M1')));
    final powerRight = ['G1', 'QF1', 'KM1', 'F1', 'M1'].map((t) => byTag(app, t).x + app.defOf(byTag(app, t)).width).reduce(math.max);
    for (final tag in ['S0', 'S1', 'HL1']) {
      expect(byTag(app, tag).x, greaterThan(powerRight), reason: '$tag sits on the control side');
    }
    expect(app.project.wires.every((w) => w.points == null), isTrue, reason: 'the router lays every wire again');
    app.undo();
    for (final d in app.project.devices) {
      expect(Offset(d.x, d.y), before[d.id], reason: 'one undo step puts everything back');
    }
    app.dispose();
  });

  testWidgets('dragging a wire segment sets a manual route, and it can be reset', (tester) async {
    final app = await pumpApp(tester);
    app.addDevice('generic_source_ac', world: const Offset(200, 200));
    app.addDevice('foco_led', world: const Offset(700, 200));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-G1-L')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('terminal-HL1-F')));
    await tester.pump();
    final wire = app.project.wires.single;
    expect(wire.points, isNull);
    final route = app.routeWorld(wire);
    final horizontal = [for (var i = 0; i < route.length - 1; i++) if ((route[i].dy - route[i + 1].dy).abs() < 0.01 && (route[i] - route[i + 1]).distance > 20) i].first;
    final before = route[horizontal].dy;

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(ValueKey('wire-handle-${wire.id}-$horizontal'))));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(wire.points, isNotNull);
    expect(app.routeWorld(wire)[horizontal].dy, greaterThan(before + 40));

    final movedRoute = app.routeWorld(wire);
    for (var i = 0; i < movedRoute.length - 1; i++) {
      final straight = (movedRoute[i].dx - movedRoute[i + 1].dx).abs() < 0.01 || (movedRoute[i].dy - movedRoute[i + 1].dy).abs() < 0.01;
      expect(straight, isTrue, reason: 'segment $i must stay orthogonal');
    }

    app.undo();
    expect(app.project.wires.single.points, isNull);
    app.redo();
    final redone = app.project.wires.single;
    expect(redone.points, isNotNull);
    app.resetWireRoute(redone);
    expect(redone.points, isNull);
  });

  testWidgets('a route survives moving a device and stays orthogonal', (tester) async {
    final app = await pumpApp(tester);
    app.applyTemplate(kTemplates.first);
    await tester.pump();
    final wire = app.project.wires.first;
    wire.points = [const WirePoint(100, -100), const WirePoint(300, -100)];
    final device = app.project.devices.firstWhere((d) => d.id == wire.a.deviceId);
    device.x += 37;
    final route = app.routeWorld(wire);
    for (var i = 0; i < route.length - 1; i++) {
      expect((route[i].dx - route[i + 1].dx).abs() < 0.01 || (route[i].dy - route[i + 1].dy).abs() < 0.01, isTrue);
    }
  });

  test('timers finish on their own through the app', () async {
    final app = buildApp();
    app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'stardelta'));
    byTag(app, 'KT1').timeSeconds = 0.25;
    app.startSimulation();
    app.clickDevice(byTag(app, 'QF1'));
    app.clickDevice(byTag(app, 'F2'));
    app.pressDevice(byTag(app, 'S1'), true);
    app.pressDevice(byTag(app, 'S1'), false);
    expect(app.stateOf(byTag(app, 'KM3')), 'closed');
    expect(app.timerRemaining(byTag(app, 'KT1')), isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(app.stateOf(byTag(app, 'KT1')), 'closed');
    expect(app.stateOf(byTag(app, 'KM2')), 'closed');
    expect(app.stateOf(byTag(app, 'KM3')), 'open');
    expect(app.timerRemaining(byTag(app, 'KT1')), isNull);
    app.stopSimulation();
    app.dispose();
  });

  test('the PLC star-delta template starts in star, changes to delta on T1, and stops on S0 or an overload trip', () async {
    final app = buildApp();
    app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'plc_stardelta'));
    final plc = byTag(app, 'PLC1');
    ((plc.data['program'] as List<dynamic>)[2] as Map<String, dynamic>)['preset'] = 0.3;
    String state(String tag) => app.stateOf(byTag(app, tag));
    app.startSimulation();
    app.clickDevice(byTag(app, 'QF1'));
    app.clickDevice(byTag(app, 'F2'));
    expect(state('KM1'), 'open', reason: 'nothing runs before start');
    app.pressDevice(byTag(app, 'S1'), true);
    app.pressDevice(byTag(app, 'S1'), false);
    expect(state('KM1'), 'closed');
    expect(state('KM2'), 'closed', reason: 'star first');
    expect(state('KM3'), 'open');
    expect(state('M1'), 'run_fwd');
    expect(app.simResult!.starMotors, contains(byTag(app, 'M1').id));
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(state('KM2'), 'open', reason: 'star drops out when T1 is done');
    expect(state('KM3'), 'closed', reason: 'then delta');
    expect(state('KM1'), 'closed');
    expect(state('M1'), 'run_fwd');
    expect(app.simResult!.starMotors, isNot(contains(byTag(app, 'M1').id)));
    expect(app.simResult!.warnings.where((w) => w.code == WarningCode.singlePhasing), isEmpty);

    app.pressDevice(byTag(app, 'S0'), true);
    app.pressDevice(byTag(app, 'S0'), false);
    expect([state('KM1'), state('KM2'), state('KM3')], everyElement('open'));

    app.pressDevice(byTag(app, 'S1'), true);
    app.pressDevice(byTag(app, 'S1'), false);
    expect(state('KM1'), 'closed');
    app.clickDevice(byTag(app, 'F1'));
    expect(state('F1'), 'tripped');
    expect([state('KM1'), state('KM2'), state('KM3')], everyElement('open'), reason: 'an overload trip stops it');
    app.stopSimulation();
    app.dispose();
  });

  test('the digital timer keys set the time one digit at a time, live and without an undo step', () {
    final app = buildApp();
    app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'stardelta'));
    final timer = byTag(app, 'KT1');
    expect(app.timeOf(timer), 5);
    app.startSimulation();
    final undoable = app.canUndo;
    void press(String key) {
      app.timerKey(timer, key, true);
      app.timerKey(timer, key, false);
    }

    press('up');
    expect(app.timeOf(timer), 6, reason: 'an arrow starts setting the ones digit and changes it');
    expect(app.timerPanel(timer).editing, isTrue);
    press('left');
    press('up');
    expect(app.timeOf(timer), 16);
    press('right');
    press('right');
    press('down');
    expect(app.timeOf(timer), closeTo(16.9, 1e-9), reason: 'tenths wrap from 0 to 9 without borrowing');
    press('set');
    expect(app.timerPanel(timer).editing, isFalse);
    expect(app.canUndo, undoable);
    app.stopSimulation();
    app.dispose();
  });

  test('clicking a dial timer during simulation turns it to the next setting', () {
    final app = buildApp();
    app.addDevice('abb_ct_c');
    final timer = app.project.devices.single;
    app.startSimulation();
    expect(app.timeOf(timer), 3);
    app.clickDevice(timer);
    expect(app.timeOf(timer), 5);
    app.timerKey(timer, 'up', true);
    for (var i = 0; i < 7; i++) {
      app.clickDevice(timer);
    }
    expect(app.timeOf(timer), 1, reason: 'wraps around after 60 s');
    app.stopSimulation();
    app.dispose();
  });

  test('the PLC keypad steps screens, stops and starts the program, and drives cursor-key inputs', () {
    final app = buildApp();
    app.addDevice('generic_source_ac', world: const Offset(200, 200));
    app.addDevice('logo_230rce', world: const Offset(700, 200));
    final source = app.project.devices[0], plc = app.project.devices[1];
    app.project.wires
      ..add(Wire(id: app.project.nextId(), a: TerminalRef(source.id, 'L'), b: TerminalRef(plc.id, 'L')))
      ..add(Wire(id: app.project.nextId(), a: TerminalRef(source.id, 'N'), b: TerminalRef(plc.id, 'N')));
    // C1 (the up key) drives Q1.
    app.setProgram(plc, LadderProgram.fromRungs([
      PlcRung(branches: [[const PlcContact('C1')]], coil: 'Q1'),
    ]));
    app.startSimulation();
    expect(app.plcPowered(plc), isTrue);
    expect(app.stateOf(plc), startsWith('run'));

    void tap(String key) {
      app.plcKey(plc, key, true);
      app.plcKey(plc, key, false);
    }

    tap('right');
    expect(PlcPanel.pages[app.plcPanel(plc).page], 'inputs');
    tap('left');
    tap('left');
    expect(PlcPanel.pages[app.plcPanel(plc).page], 'keys');
    app.plcKey(plc, 'up', true);
    expect(app.bitsOf(plc), containsAll(['Z1', 'Q1']), reason: 'the older C1-C4 key names are now Z1-Z4');
    app.plcKey(plc, 'up', false);
    expect(app.bitsOf(plc), isNot(contains('Q1')));

    tap('esc'); // Leaves the cursor-key screen.
    tap('esc'); // Opens the menu.
    expect(app.plcPanel(plc).menu, 'main');
    tap('ok'); // Stop
    tap('down'); // Yes
    tap('ok');
    expect(app.plcStopped(plc), isTrue);
    expect(app.stateOf(plc), 'stop');
    tap('ok'); // Start
    expect(app.plcStopped(plc), isFalse);
    expect(app.stateOf(plc), startsWith('run'));
    app.stopSimulation();
    app.dispose();
  });

  test('the PLC clock follows the computer, can be set from the keypad, and drives a clock block', () {
    final app = buildApp();
    app.addDevice('generic_source_ac', world: const Offset(200, 200));
    app.addDevice('logo_230rce', world: const Offset(700, 200));
    final source = app.project.devices[0], plc = app.project.devices[1];
    app.project.wires
      ..add(Wire(id: app.project.nextId(), a: TerminalRef(source.id, 'L'), b: TerminalRef(plc.id, 'L')))
      ..add(Wire(id: app.project.nextId(), a: TerminalRef(source.id, 'N'), b: TerminalRef(plc.id, 'N')));
    // Q1 on Saturdays 10:00-11:00 only.
    final program = LadderProgram()..rows.add(LadderRow(cells: [LadderCell.contact('H1'), ...List.filled(4, const LadderCell.wire())], coil: LadderCoil('[', 'Q1')));
    program.clocks['H1'] = LadderClock(slots: [ClockSlot(days: {6}, on: 600, off: 660)]);
    app.setProgram(plc, program);
    app.startSimulation();
    expect(app.plcClockOf(plc).difference(DateTime.now()).inSeconds.abs(), lessThan(5), reason: 'starts on the computer clock');

    void tap(String key) {
      app.plcKey(plc, key, true);
      app.plcKey(plc, key, false);
    }

    tap('esc');
    for (var i = 0; i < 2; i++) {
      tap('down');
    }
    tap('ok'); // Set Clock
    expect(app.plcPanel(plc).menu, 'clock');
    // Set Saturday 10:30: step the day up to SA, then the hour and minute.
    final panel = app.plcPanel(plc);
    while (panel.clockDay != 6) {
      tap('up');
    }
    tap('right');
    while (panel.clockMinute ~/ 60 != 10) {
      tap('up');
    }
    tap('right');
    while (panel.clockMinute % 60 != 30) {
      tap('up');
    }
    tap('ok');
    final now = app.plcClockOf(plc);
    expect(now.weekday, 6);
    expect(now.hour * 60 + now.minute, inInclusiveRange(630, 631));
    expect(app.bitsOf(plc), containsAll(['H1', 'Q1']), reason: 'the clock block follows the PLC clock');

    tap('esc');
    for (var i = 0; i < 3; i++) {
      tap('down');
    }
    tap('ok'); // Jam = PC
    expect(plc.data.containsKey('rtc_offset_s'), isFalse);
    app.stopSimulation();
    app.dispose();
  });

  group('protection and automation', () {
    test('a heater too big for its breaker trips on overload, slowly at first', () {
      final app = buildApp();
      app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'meters'));
      final heater = byTag(app, 'E1');
      final breaker = byTag(app, 'QF1');
      heater.data['power_w'] = 7000.0; // About 30 A on a 16 A breaker.
      app.startSimulation();
      app.clickDevice(breaker);
      expect(app.stateOf(breaker), 'on');
      app.advance(2);
      expect(app.stateOf(breaker), 'on');
      expect(app.heatOf(breaker), greaterThan(0));
      for (var i = 0; i < 20; i++) {
        app.advance(1);
      }
      expect(app.stateOf(breaker), 'tripped');
      expect(app.status, contains('beban lebih'));
      expect(app.stateOf(heater), 'off');
      app.stopSimulation();
      app.dispose();
    });

    test('a very large overload trips a breaker immediately', () {
      final app = buildApp();
      app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'meters'));
      byTag(app, 'E1').data['power_w'] = 15000.0;
      byTag(app, 'QF1').data['rated_current_a'] = 6.0;
      app.startSimulation();
      app.clickDevice(byTag(app, 'QF1'));
      app.advance(0.1);
      expect(app.stateOf(byTag(app, 'QF1')), 'tripped');
      app.stopSimulation();
      app.dispose();
    });

    test('a loss of phase overloads a motor until the overload relay trips, and the contactor drops', () {
      final app = buildApp();
      app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'dol'));
      app.project.wires.removeWhere((w) => w.a.terminal == '3' && app.tagOf(w.a.deviceId) == 'G1' || w.b.terminal == '3' && app.tagOf(w.b.deviceId) == 'QF1');
      byTag(app, 'F1').data['rated_current_a'] = 6.0;
      app.startSimulation();
      app.clickDevice(byTag(app, 'QF1'));
      app.clickDevice(byTag(app, 'F2'));
      app.pressDevice(byTag(app, 'S1'), true);
      app.pressDevice(byTag(app, 'S1'), false);
      expect(app.stateOf(byTag(app, 'KM1')), 'closed');
      expect(app.stateOf(byTag(app, 'M1')), 'stopped');
      for (var i = 0; i < 40 && app.stateOf(byTag(app, 'F1')) == 'normal'; i++) {
        app.advance(1);
      }
      expect(app.stateOf(byTag(app, 'F1')), 'tripped');
      expect(app.stateOf(byTag(app, 'KM1')), 'open');
      app.stopSimulation();
      app.dispose();
    });

    test('overvoltage blows parts up one after another, locks the controls, and only a restart repairs them', () {
      final sound = SilentSound();
      final app = buildApp(sound: sound);
      app.project.devices.add(PlacedDevice(id: 1, defId: 'generic_source_ac3', tag: 'G1', x: 0, y: 0));
      for (var i = 0; i < 3; i++) {
        final id = 2 + i;
        app.project.devices.add(PlacedDevice(id: id, defId: 'piloto_led_rojo', tag: 'H${i + 1}', x: 100.0 * i, y: 200));
        app.project.wires.add(Wire(id: 10 + i * 2, a: TerminalRef(1, 'L1'), b: TerminalRef(id, 'X1')));
        app.project.wires.add(Wire(id: 11 + i * 2, a: TerminalRef(1, 'L2'), b: TerminalRef(id, 'X2')));
      }
      final lamps = [for (var i = 1; i <= 3; i++) byTag(app, 'H$i')];
      app.startSimulation();
      expect(lamps.every((l) => app.stateOf(l) == 'on'), isTrue);

      final ticks = <int>[];
      for (var tick = 0; tick < 60; tick++) {
        final before = lamps.where((l) => app.stateOf(l) == 'exploded').length;
        app.advance(0.1);
        final after = lamps.where((l) => app.stateOf(l) == 'exploded').length;
        expect(after - before, lessThanOrEqualTo(1), reason: 'one explosion at a time');
        if (after > before) ticks.add(tick);
      }
      expect(ticks.length, 3);
      expect(sound.played.where((s) => s == 'explosion').length, 3);
      expect(app.wrecked, isTrue);
      expect(app.status, contains('meledak'));
      expect(app.events.first, contains('MELEDAK'));
      expect(app.explodedFor(lamps.first), isNotNull);
      app.animate(0.1);
      expect(sound.loops, contains('sizzle'));

      app.stopSimulation();
      expect(sound.loops, isEmpty, reason: 'stopping silences the crackle');
      expect(sound.shotsStopped, greaterThan(0), reason: 'stopping cuts the explosion sound short');
      app.startSimulation();
      expect(app.wrecked, isFalse);
      expect(lamps.every((l) => app.stateOf(l) == 'on'), isTrue);
      app.stopSimulation();
      app.dispose();
    });

    test('a coil fed at 100 Hz smokes for a while before it explodes', () {
      final app = buildApp();
      app.project.devices.add(PlacedDevice(id: 1, defId: 'generic_source_adjustable', tag: 'G1', x: 0, y: 0, data: {'frequency': 100.0}));
      app.project.devices.add(PlacedDevice(id: 2, defId: 'chint_nxc32', tag: 'KM1', x: 200, y: 0));
      app.project.wires.add(Wire(id: 3, a: TerminalRef(1, 'L'), b: TerminalRef(2, 'A1')));
      app.project.wires.add(Wire(id: 4, a: TerminalRef(2, 'A2'), b: TerminalRef(1, 'N')));
      final coil = byTag(app, 'KM1');
      app.startSimulation();
      app.advance(1);
      expect(app.stateOf(coil), 'closed');
      expect(app.damageOf(coil), greaterThan(0));
      for (var i = 0; i < 300 && app.stateOf(coil) != 'exploded'; i++) {
        app.advance(0.1);
      }
      expect(app.stateOf(coil), 'exploded');
      expect(app.status, contains('100 Hz'));
      app.stopSimulation();
      app.dispose();
    });

    test('the PLC program runs the motor from its buttons', () {
      final app = buildApp();
      app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'plc'));
      app.startSimulation();
      app.clickDevice(byTag(app, 'QF1'));
      app.clickDevice(byTag(app, 'F2'));
      final plc = app.firstPlc!;
      app.pressDevice(byTag(app, 'S1'), true);
      app.pressDevice(byTag(app, 'S1'), false);
      expect(app.bitsOf(plc), contains('Q1'));
      expect(app.stateOf(byTag(app, 'M1')), 'run_fwd');
      app.pressDevice(byTag(app, 'S2'), true);
      app.pressDevice(byTag(app, 'S2'), false);
      expect(app.stateOf(byTag(app, 'M1')), 'stopped');
      app.stopSimulation();
      app.dispose();
    });

    test('a PLC timer finishes through the app', () async {
      final app = buildApp();
      app.addDevice('generic_source_ac');
      app.addDevice('logo_230rce');
      final g = byTag(app, 'G1').id, plc = byTag(app, 'A1');
      app.project.wires
        ..add(Wire(id: 900, a: TerminalRef(g, 'L'), b: TerminalRef(plc.id, 'L')))
        ..add(Wire(id: 901, a: TerminalRef(g, 'N'), b: TerminalRef(plc.id, 'N')));
      plc.data['program'] = [
        {
          'branches': [
            [
              {'ref': 'M1'},
            ],
          ],
          'coil': 'T1',
          'preset': 0.2,
        },
        {
          'branches': [
            [
              {'ref': 'T1'},
            ],
          ],
          'coil': 'Q1',
        },
      ];
      app.startSimulation();
      app.setPlcBit(plc, 'M1', true);
      expect(app.bitsOf(plc), isNot(contains('Q1')));
      await Future<void>.delayed(const Duration(milliseconds: 450));
      app.advance(0.1);
      expect(app.bitsOf(plc), contains('Q1'));
      app.setPlcBit(plc, 'M1', false);
      expect(app.bitsOf(plc), isNot(contains('Q1')));
      app.stopSimulation();
      app.dispose();
    });

    test('live control changes during simulation are not undo steps, and edits are', () {
      final app = buildApp();
      app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'meters'));
      final supply = byTag(app, 'PS1');
      app.startSimulation();
      app.clickDevice(byTag(app, 'QF1'));
      app.setControl(supply, 'voltage', 115);
      expect(app.simResult!.measures[byTag(app, 'E1').id]!.volts, 115);
      app.stopSimulation();

      app.beginControlEdit();
      app.setControl(byTag(app, 'E1'), 'power_w', 1000);
      app.endControlEdit();
      expect(byTag(app, 'E1').data['power_w'], 1000);
      app.undo();
      expect(byTag(app, 'E1').data['power_w'], isNull);
    });
  });

  group('animation', () {
    void run(AppState app, double seconds) {
      for (var t = 0.0; t < seconds; t += 0.05) {
        app.animate(0.05);
      }
    }

    test('a motor spins up gradually, coasts down after the breaker opens, and current falls away', () {
      final app = buildApp(sound: SilentSound());
      app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'dol'));
      final motor = byTag(app, 'M1');
      app.startSimulation();
      app.clickDevice(byTag(app, 'QF1'));
      app.clickDevice(byTag(app, 'F2'));
      app.pressDevice(byTag(app, 'S1'), true);
      app.pressDevice(byTag(app, 'S1'), false);
      expect(app.rotorSpeed(motor), 0);
      run(app, 0.3);
      expect(app.rotorSpeed(motor), inExclusiveRange(0.1, 0.7));
      run(app, 5);
      expect(app.rotorSpeed(motor), greaterThan(0.97));
      final angle = app.rotorAngle(motor);
      expect(angle, greaterThan(10));
      final amps = app.shownMeasure(motor).amps;
      expect(amps, closeTo(4.4, 0.1));

      app.clickDevice(byTag(app, 'QF1'));
      expect(app.stateOf(motor), 'stopped');
      run(app, 0.25);
      expect(app.rotorSpeed(motor), greaterThan(0.8), reason: 'inertia keeps it turning');
      expect(app.shownMeasure(motor).amps, inExclusiveRange(0.1, amps), reason: 'current falls, not instantly');
      run(app, 2);
      expect(app.rotorSpeed(motor), inExclusiveRange(0.1, 0.7));
      run(app, 20);
      expect(app.rotorSpeed(motor), 0);
      expect(app.shownMeasure(motor).amps, 0);
      app.stopSimulation();
      app.dispose();
    });

    test('star runs slower than delta, and the changeover keeps one motor sound with a brief dip', () {
      final sound = SilentSound();
      final app = buildApp(sound: sound);
      app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'stardelta'));
      byTag(app, 'KT1').timeSeconds = 0.01;
      final motor = byTag(app, 'M1');
      app.startSimulation();
      app.clickDevice(byTag(app, 'QF1'));
      app.clickDevice(byTag(app, 'F2'));
      byTag(app, 'KT1').timeSeconds = 999;
      app.pressDevice(byTag(app, 'S1'), true);
      app.pressDevice(byTag(app, 'S1'), false);
      run(app, 5);
      expect(app.rotorSpeed(motor), closeTo(0.72, 0.02));
      final starPitch = sound.motorPitch;
      byTag(app, 'KT1').timeSeconds = 0.001;
      app.advance(0.1);
      expect(app.stateOf(byTag(app, 'KM2')), 'closed');
      app.animate(0.02);
      expect(app.rotorSpeed(motor), lessThan(0.72));
      expect(sound.audibleMotor.length, inInclusiveRange(1, 2), reason: 'one motor sound, crossfading at most two layers');
      run(app, 5);
      expect(app.rotorSpeed(motor), greaterThan(0.97));
      expect(sound.motorPitch, greaterThan(starPitch));
      expect(sound.played.where((p) => p.startsWith('motor')), isEmpty);
      app.stopSimulation();
      app.dispose();
    });

    test('wires carry current with a direction, and it fades after the supply opens', () {
      final app = buildApp(sound: SilentSound());
      app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'meters'));
      byTag(app, 'E1').data['power_w'] = 2000.0;
      app.startSimulation();
      app.clickDevice(byTag(app, 'QF1'));
      run(app, 2);
      final line = app.project.wires.firstWhere((w) => app.tagOf(w.a.deviceId) == 'PS1' && w.a.terminal == 'L');
      final neutral = app.project.wires.firstWhere((w) => app.tagOf(w.a.deviceId) == 'E1' && w.a.terminal == 'N');
      expect(app.wireFlow(line), closeTo(8.7, 0.3), reason: 'flows away from the source on the line side');
      expect(app.wireFlow(neutral), closeTo(8.7, 0.3), reason: 'flows back to the source on neutral');
      final phase = app.wirePhase(line);
      run(app, 0.5);
      expect(app.wirePhase(line), greaterThan(phase));
      app.clickDevice(byTag(app, 'QF1'));
      run(app, 0.3);
      expect(app.wireFlow(line), inExclusiveRange(1, 8.7));
      run(app, 10);
      expect(app.wireFlow(line), 0);
      app.stopSimulation();
      app.dispose();
    });

    test('voltmeters and frequency meters drain away after the supply opens', () {
      final app = buildApp(sound: SilentSound());
      app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'meters'));
      app.startSimulation();
      app.clickDevice(byTag(app, 'QF1'));
      run(app, 3);
      final volts = byTag(app, 'PV1');
      final hertz = byTag(app, 'PF1');
      expect(app.shownMeasure(volts).volts, closeTo(230, 1));
      expect(app.shownMeasure(hertz).hertz, closeTo(50, 0.5));

      app.clickDevice(byTag(app, 'QF1'));
      expect(app.simResult!.measures[volts.id]!.volts, 0, reason: 'the circuit itself is dead at once');
      expect(app.shownMeasure(volts).volts, closeTo(230, 1), reason: 'the display does not jump');
      run(app, 0.4);
      expect(app.shownMeasure(volts).volts, inExclusiveRange(60, 225));
      expect(app.shownMeasure(hertz).hertz, inExclusiveRange(10, 49));
      run(app, 12);
      expect(app.shownMeasure(volts).volts, 0);
      expect(app.shownMeasure(hertz).hertz, 0);
      app.stopSimulation();
      app.dispose();
    });

    test('lamps fade instead of snapping', () {
      final app = buildApp(sound: SilentSound());
      app.applyTemplate(kTemplates.first);
      final lamp = byTag(app, 'HL1');
      app.startSimulation();
      app.clickDevice(byTag(app, 'QF1'));
      app.pressDevice(byTag(app, 'S1'), true);
      app.animate(0.03);
      expect(app.lampGlow(lamp), inExclusiveRange(0.01, 0.6));
      run(app, 1);
      expect(app.lampGlow(lamp), greaterThan(0.95));
      app.stopSimulation();
      app.dispose();
    });
  });

  group('sound', () {
    test('a running motor loops, with start and stop sounds, and stopping the simulation silences it', () {
      final sound = SilentSound();
      final app = buildApp(sound: sound);
      app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'dol'));
      app.startSimulation();
      expect(sound.audible, isEmpty);
      expect(sound.motorReady, isTrue, reason: 'motor layers load silently up front, so a start is heard at once');
      app.clickDevice(byTag(app, 'QF1'));
      app.clickDevice(byTag(app, 'F2'));
      app.pressDevice(byTag(app, 'S1'), true);
      app.pressDevice(byTag(app, 'S1'), false);
      expect(sound.audible, contains('contactor_hum'));
      void run(double seconds) {
        for (var t = 0.0; t < seconds; t += 0.05) {
          app.animate(0.05);
        }
      }

      // The sound winds up with the motor: pitch and loudness rise step by step over a couple of seconds.
      final pitches = <double>[];
      final volumes = <double>[];
      for (var i = 0; i < 6; i++) {
        run(0.4);
        pitches.add(sound.motorPitch);
        volumes.add([for (final l in sound.audibleMotor) sound.mix[l]!.$1].fold(0.0, (a, b) => a + b * b));
      }
      for (var i = 1; i < pitches.length; i++) {
        expect(pitches[i], greaterThan(pitches[i - 1]), reason: 'pitch rises at each step: $pitches');
        expect(volumes[i], greaterThanOrEqualTo(volumes[i - 1] - 1e-9), reason: 'loudness never drops: $volumes');
      }
      expect(pitches.first, lessThan(0.35), reason: 'starts low: $pitches');
      run(2);
      expect(sound.motorPitch, closeTo(1, 0.03));
      expect(sound.mix['motor_run_3p_100']!.$1, greaterThan(0.9));
      app.pressDevice(byTag(app, 'S0'), true);
      app.pressDevice(byTag(app, 'S0'), false);
      run(1);
      expect(sound.audibleMotor, isNotEmpty, reason: 'still coasting');
      expect(sound.motorPitch, lessThan(0.9));
      run(18);
      expect(sound.audibleMotor, isEmpty);
      app.pressDevice(byTag(app, 'S1'), true);
      app.pressDevice(byTag(app, 'S1'), false);
      run(0.2);
      expect(sound.audibleMotor, isNotEmpty);
      app.toggleSound();
      expect(sound.loops, isEmpty);
      app.toggleSound();
      expect(sound.motorReady, isTrue);
      app.stopSimulation();
      expect(sound.loops, isEmpty);
      app.dispose();
    });

    test('a pump has its own sound, not the motor loop, and it winds up and down too', () {
      final sound = SilentSound();
      final app = buildApp(sound: sound);
      app.addDevice('generic_source_ac');
      app.addDevice('schneider_acti9_ic60n_1p_c16');
      app.addDevice('wirescad_tank_pump_process_rig');
      final source = app.project.devices[0], breaker = app.project.devices[1], pump = app.project.devices[2];
      void wire(PlacedDevice a, String at, PlacedDevice b, String bt) =>
          app.project.wires.add(Wire(id: app.project.nextId(), a: TerminalRef(a.id, at), b: TerminalRef(b.id, bt)));
      wire(source, 'L', breaker, '1');
      wire(breaker, '2', pump, 'U1');
      wire(pump, 'U2', source, 'N');
      app.startSimulation();
      expect(sound.loops, containsAll(AppState.rotorLayerNames('pump_run')), reason: 'pump layers load up front');
      app.clickDevice(breaker);
      expect(app.stateOf(pump), 'on');
      void run(double seconds) {
        for (var t = 0.0; t < seconds; t += 0.05) {
          app.animate(0.05);
        }
      }

      double pitch(String base) {
        var sum = 0.0, weight = 0.0;
        for (final speed in AppState.rotorLayers) {
          final volume = sound.mix['${base}_${(speed * 100).round()}']?.$1 ?? 0;
          sum += volume * volume * speed;
          weight += volume * volume;
        }
        return weight == 0 ? 0 : sum / weight;
      }

      run(0.4);
      final early = pitch('pump_run');
      run(0.8);
      expect(pitch('pump_run'), greaterThan(early), reason: 'pitch rises as it spins up');
      run(3);
      expect(pitch('pump_run'), closeTo(1, 0.03));
      expect(sound.mix['pump_run_100']!.$1, closeTo(AppState.loopGain['pump_run']!, 0.05), reason: 'quieter than a big motor');
      expect(sound.loops.where((l) => l.startsWith('motor_run')), isEmpty, reason: 'no motor sound for a pump');
      app.clickDevice(breaker);
      run(1);
      expect(pitch('pump_run'), lessThan(0.9), reason: 'it winds down, not cut dead');
      run(20);
      expect(sound.audible.where((l) => l.startsWith('pump_run')), isEmpty);
      app.stopSimulation();
      app.dispose();
    });

    test('other continuous and fault sounds', () {
      final sound = SilentSound();
      final app = buildApp(sound: sound);
      app.addDevice('generic_source_ac3');
      app.addDevice('motor_6_terminales');
      final g = byTag(app, 'G1').id, m = byTag(app, 'M1').id;
      void wire(int a, String at, int b, String bt) => app.project.wires.add(Wire(id: app.project.nextId(), a: TerminalRef(a, at), b: TerminalRef(b, bt)));
      wire(g, 'L1', m, 'U1');
      wire(g, 'L2', m, 'V1');
      wire(m, 'U2', m, 'V2');
      wire(m, 'V2', m, 'W2');
      app.startSimulation();
      expect(sound.loops, contains('motor_stall'));
      app.stopSimulation();

      wire(g, 'L1', g, 'N');
      app.startSimulation();
      expect(sound.played, contains('short_circuit'));
      app.stopSimulation();
      app.dispose();
    });

    test('every sound a device refers to exists as a file', () {
      final app = buildApp();
      for (final def in app.defs.values) {
        for (final name in def.loopSounds.values) {
          expect(File('assets/sounds/$name.wav').existsSync(), isTrue, reason: name);
        }
        for (final name in def.sounds.values) {
          final single = File('assets/sounds/$name.wav').existsSync();
          final takes = File('assets/sounds/${name}_1.wav').existsSync();
          expect(single || takes, isTrue, reason: name);
        }
      }
      for (final base in AppState.layeredLoops) {
        for (final layer in AppState.rotorLayerNames(base)) {
          expect(File('assets/sounds/$layer.wav').existsSync(), isTrue, reason: layer);
        }
      }
      expect(File('assets/sounds/motor_stall.wav').existsSync(), isTrue);
      expect(File('assets/sounds/short_circuit.wav').existsSync(), isTrue);
    });
  });

  test('copy and paste keeps internal wires, gives new tags, and can be undone', () {
    final app = buildApp();
    app.applyTemplate(kTemplates.first);
    app.selectAll();
    app.copySelection();
    final devices = app.project.devices.length;
    final wires = app.project.wires.length;
    app.paste();
    expect(app.project.devices.length, devices * 2);
    expect(app.project.wires.length, wires * 2);
    expect({for (final d in app.project.devices) d.tag}.length, devices * 2);
    app.undo();
    expect(app.project.devices.length, devices);
  });

  test('deleting a device removes its wires', () {
    final app = buildApp();
    app.applyTemplate(kTemplates.first);
    final before = app.project.wires.length;
    app.selectDevice(byTag(app, 'HL1').id);
    app.deleteSelection();
    expect(app.project.devices.length, 4);
    expect(app.project.wires.length, before - 2);
  });

  test('material list counts devices and connections', () {
    final app = buildApp();
    app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'stardelta'));
    final csv = app.exportBomCsv();
    expect(csv, contains('KM1 KM2 KM3'));
    expect(csv, contains('"Jumper"'));
    expect(csv, isNot(contains('wireona')));
  });

  test('an unreadable file gives an Indonesian message and keeps the project', () {
    final app = buildApp();
    app.applyTemplate(kTemplates.first);
    expect(app.importJson('bukan json'), contains('tidak bisa dibaca'));
    expect(app.project.devices.length, 5);
  });
}
