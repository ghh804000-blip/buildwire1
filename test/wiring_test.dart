import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:buildwire/ai/ai_settings.dart';
import 'package:buildwire/app_state.dart';
import 'package:buildwire/model/device_def.dart';
import 'package:buildwire/model/project.dart';
import 'package:buildwire/sound.dart';
import 'package:buildwire/templates.dart';
import 'package:flutter_test/flutter_test.dart';

class Quiet extends SoundPlayer {
  @override
  Future<void> play(String name, bool enabled) async {}
  @override
  Future<void> setLoops(Set<String> names) async {}
  @override
  Future<void> mixLoop(String name, double volume, double rate) async {}
  @override
  Future<void> preload(Iterable<String> names) async {}
  @override
  Future<void> stopShots() async {}
}

AppState buildApp() {
  final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
  final defs = {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
  return AppState(defs, null, sound: Quiet(), secrets: MemorySecretStore());
}

/// Pairs of straight runs from different wires lying on top of each other, split into wires that share a terminal
/// (they meet there anyway) and wires that don't.
(int, int) overlaps(AppState app) {
  final ends = {for (final w in app.project.wires) w.id: {w.a.key, w.b.key}};
  final runs = <(int, bool, double, double, double)>[];
  for (final w in app.project.wires) {
    final p = app.routeWorld(w);
    for (var k = 0; k + 1 < p.length; k++) {
      final a = p[k], b = p[k + 1];
      if ((a.dy - b.dy).abs() < 0.5 && (a.dx - b.dx).abs() > 1) runs.add((w.id, true, a.dy, math.min(a.dx, b.dx), math.max(a.dx, b.dx)));
      if ((a.dx - b.dx).abs() < 0.5 && (a.dy - b.dy).abs() > 1) runs.add((w.id, false, a.dx, math.min(a.dy, b.dy), math.max(a.dy, b.dy)));
    }
  }
  var shared = 0, other = 0;
  for (var i = 0; i < runs.length; i++) {
    for (var j = i + 1; j < runs.length; j++) {
      final p = runs[i], q = runs[j];
      if (p.$1 == q.$1 || p.$2 != q.$2 || (p.$3 - q.$3).abs() >= 2) continue;
      if (math.min(p.$5, q.$5) - math.max(p.$4, q.$4) <= 6) continue;
      if (ends[p.$1]!.intersection(ends[q.$1]!).isNotEmpty) {
        shared++;
      } else {
        other++;
      }
    }
  }
  return (shared, other);
}

void main() {
  test('wires sharing a run are spread into lanes in every built-in circuit', () {
    for (final template in kTemplates) {
      final app = buildApp()..applyTemplate(template);
      final (_, other) = overlaps(app);
      expect(other, lessThanOrEqualTo(4), reason: '${template.id}: separate wires still on top of each other');
      for (final wire in app.project.wires) {
        final route = app.routeWorld(wire);
        for (var k = 0; k + 1 < route.length; k++) {
          final a = route[k], b = route[k + 1];
          expect((a.dx - b.dx).abs() < 0.01 || (a.dy - b.dy).abs() < 0.01, isTrue, reason: '${template.id}: every run stays straight');
        }
        expect(route.first, app.terminalWorld(wire.a), reason: 'ends stay on their terminals');
        expect(route.last, app.terminalWorld(wire.b));
      }
      app.dispose();
    }
  });

  test('wires go around parts the short way instead of looping round the whole panel', () {
    for (final template in kTemplates) {
      final app = buildApp()..applyTemplate(template);
      Rect rectOf(PlacedDevice d) => Rect.fromLTWH(d.x, d.y, app.defOf(d).width, app.defOf(d).height).deflate(2);
      for (final wire in app.project.wires.where((w) => !w.isJumper)) {
        // Other parts only: near its own terminals a wire may step around a neighbouring terminal inside the part.
        final parts = [
          for (final d in app.project.devices)
            if (!app.defOf(d).isBackLayer && !app.defOf(d).isJunction && !wire.touches(d.id)) rectOf(d),
        ];
        final route = app.routeWorld(wire);
        var length = 0.0;
        for (var k = 0; k + 1 < route.length; k++) {
          length += (route[k + 1] - route[k]).distance;
          // Between the two terminal stubs, no run passes through a part.
          if (k == 0 || k + 2 == route.length) continue;
          final middle = (route[k] + route[k + 1]) / 2;
          expect(parts.any((r) => r.contains(middle)), isFalse, reason: '${template.id}: wire ${wire.id} run $k crosses a part');
        }
        final direct = (route.first.dx - route.last.dx).abs() + (route.first.dy - route.last.dy).abs();
        // 3.5x leaves room for a motor's middle lower terminal, boxed in by its neighbours, which still goes round.
        expect(length, lessThan(math.max(direct, 40) * 3.5), reason: '${template.id}: wire ${wire.id} takes a long way round');
      }
      app.dispose();
    }
  });

  test('routes are worked out once per change, and follow a moved device', () {
    final app = buildApp()..applyTemplate(kTemplates.firstWhere((t) => t.id == 'dol'));
    final wire = app.project.wires.first;
    final before = app.routeWorld(wire);
    expect(identical(app.routeWorld(wire), before), isTrue, reason: 'cached');
    final device = app.project.devices.firstWhere((d) => d.id == wire.b.deviceId);
    device.x += 50;
    expect(app.routeWorld(wire).last, app.terminalWorld(wire.b));
    app.dispose();
  });

  group('branching off a wire', () {
    late AppState app;
    late PlacedDevice source, breaker, lamp1, lamp2;
    setUp(() {
      app = buildApp();
      app.aiPlaceDevice('generic_source_ac', tag: 'G1', x: 0, y: 40);
      app.aiPlaceDevice('schneider_acti9_ic60n_1p_c16', tag: 'QF1', x: 300, y: 0);
      app.aiPlaceDevice('piloto_led_verde', tag: 'H1', x: 700, y: 40);
      app.aiPlaceDevice('piloto_led_amarillo', tag: 'H2', x: 700, y: 360);
      app.endAiEdit('x');
      source = app.deviceByTag('G1')!;
      breaker = app.deviceByTag('QF1')!;
      lamp1 = app.deviceByTag('H1')!;
      lamp2 = app.deviceByTag('H2')!;
      for (final (a, b) in [
        (TerminalRef(source.id, 'L'), TerminalRef(breaker.id, '1')),
        (TerminalRef(breaker.id, '2'), TerminalRef(lamp1.id, 'X1')),
        (TerminalRef(lamp1.id, 'X2'), TerminalRef(source.id, 'N')),
        (TerminalRef(lamp2.id, 'X2'), TerminalRef(source.id, 'N')),
      ]) {
        app.tapTerminal(a);
        app.tapTerminal(b);
      }
    });
    tearDown(() => app.dispose());

    Wire feed() => app.project.wires.firstWhere((w) => w.connects(TerminalRef(breaker.id, '2'), TerminalRef(lamp1.id, 'X1')));

    test('clicking the middle of a wire while connecting puts a junction there, splits it, and the second lamp lights', () {
      final wire = feed();
      final route = app.routeWorld(wire);
      final middle = Offset.lerp(route[route.length ~/ 2 - 1], route[route.length ~/ 2], 0.5)!;
      app.tapTerminal(TerminalRef(lamp2.id, 'X1'));
      app.branchToWire(wire, app.toScreen(middle));
      final junction = app.project.devices.singleWhere((d) => app.defOf(d).isJunction);
      expect(app.project.wires.where((w) => w.touches(junction.id)).length, 3);
      expect(app.project.wires.contains(wire), isFalse, reason: 'split in two');
      expect((app.terminalWorld(TerminalRef(junction.id, 'J')) - middle).distance, lessThan(1), reason: 'where it was clicked');
      expect(app.pending, isNull);

      app.startSimulation();
      app.clickDevice(breaker);
      expect(app.stateOf(lamp1), 'on');
      expect(app.stateOf(lamp2), 'on', reason: 'fed through the branch');
      app.stopSimulation();

      app.undo();
      expect(app.project.devices.where((d) => app.defOf(d).isJunction), isEmpty, reason: 'one undo step');
      expect(app.project.wires.any((w) => w.connects(TerminalRef(breaker.id, '2'), TerminalRef(lamp1.id, 'X1'))), isTrue);
    });

    test('deleting a junction that only joins two wires makes them one wire again', () {
      final wire = feed();
      final route = app.routeWorld(wire);
      app.tapTerminal(TerminalRef(lamp2.id, 'X1'));
      app.branchToWire(wire, app.toScreen(route[route.length ~/ 2]));
      final junction = app.project.devices.singleWhere((d) => app.defOf(d).isJunction);
      // Remove the branch first: the junction is left joining the two halves.
      app.selectWire(app.project.wires.firstWhere((w) => w.touches(junction.id) && w.touches(lamp2.id)).id);
      app.deleteSelection();
      app.selectDevice(junction.id);
      app.deleteSelection();
      expect(app.project.devices.where((d) => app.defOf(d).isJunction), isEmpty);
      expect(app.project.wires.any((w) => w.connects(TerminalRef(breaker.id, '2'), TerminalRef(lamp1.id, 'X1'))), isTrue);
    });

    test('junctions stay out of the library and the material list', () {
      final route = app.routeWorld(feed());
      app.tapTerminal(TerminalRef(lamp2.id, 'X1'));
      app.branchToWire(feed(), app.toScreen(route[1]));
      expect(app.exportBomCsv(), isNot(contains('Junction')));
      expect(app.defs.values.where((d) => d.isJunction).single.id, 'generic_junction');
    });
  });
}
