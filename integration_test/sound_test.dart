import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:buildwire/app_state.dart';
import 'package:buildwire/main.dart';
import 'package:buildwire/model/project.dart';
import 'package:buildwire/sound.dart';
import 'package:buildwire/templates.dart';

/// Runs on the real Windows app with the real audio plugin.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a running motor really plays and loops past the end of its file', (tester) async {
    final sound = SoundPlayer();
    final app = AppState(await loadDeviceDefs(), null, sound: sound);
    await tester.pumpWidget(BuildWireApp(app: app));
    await tester.pump();

    app.applyTemplate(kTemplates.firstWhere((t) => t.id == 'dol'));
    await tester.pump();
    PlacedTag(app).operate();
    await tester.pump();

    expect(sound.activeLoops, containsAll(['motor_run_3p_100', 'contactor_hum']));

    // The motor file lasts 3 seconds. Sample across its end.
    final samples = <int>[];
    for (var i = 0; i < 12 && samples.length < 9; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final position = await sound.loopPosition('motor_run_3p_100');
      // The file takes about a second to load. Once playing, the position must stay available.
      if (position != null) {
        samples.add(position.inMilliseconds);
      } else {
        expect(samples, isEmpty, reason: 'position must stay available once playing');
      }
    }
    debugPrint('motor loop positions ms: $samples');
    expect(samples.length, greaterThanOrEqualTo(8));
    expect(samples.toSet().length, greaterThan(5), reason: 'position must advance');
    final wrapped = [for (var i = 1; i < samples.length; i++) samples[i] < samples[i - 1]].contains(true);
    expect(wrapped, isTrue, reason: 'position must wrap around when the file ends');
    expect(samples.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(3100));

    // Slowing the loop must really slow playback, or a coasting motor would not sound like one.
    await sound.mixLoop('motor_run_3p_100', 0.6, 0.6);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final before = (await sound.loopPosition('motor_run_3p_100'))!.inMilliseconds;
    final clock = Stopwatch()..start();
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    final after = (await sound.loopPosition('motor_run_3p_100'))!.inMilliseconds;
    final moved = (after - before + 3000) % 3000;
    final ratio = moved / clock.elapsedMilliseconds;
    debugPrint('slowed loop moved ${moved}ms, ratio $ratio');
    expect(ratio, inInclusiveRange(0.45, 0.8));

    app.stopSimulation();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(sound.activeLoops, isEmpty);
    await tester.pump();
  });

  testWidgets('a pump plays its own loop, separate from the motor sound', (tester) async {
    final sound = SoundPlayer();
    final app = AppState(await loadDeviceDefs(), null, sound: sound);
    await tester.pumpWidget(BuildWireApp(app: app));
    await tester.pump();
    app.project.devices
      ..add(PlacedDevice(id: 1, defId: 'generic_source_ac', tag: 'G1', x: 0, y: 0))
      ..add(PlacedDevice(id: 2, defId: 'wirescad_tank_pump_process_rig', tag: 'TK1', x: 400, y: 0));
    app.project.wires
      ..add(Wire(id: 10, a: TerminalRef(1, 'L'), b: TerminalRef(2, 'U1')))
      ..add(Wire(id: 11, a: TerminalRef(2, 'U2'), b: TerminalRef(1, 'N')));
    app.startSimulation();
    await tester.pump();
    expect(app.stateOf(app.project.devices[1]), 'on');
    expect(sound.activeLoops, containsAll(AppState.rotorLayerNames('pump_run')));
    expect(sound.activeLoops.where((l) => l.startsWith('motor_run')), isEmpty);
    final samples = <int>[];
    for (var i = 0; i < 10 && samples.length < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final position = await sound.loopPosition('pump_run_100');
      if (position != null) samples.add(position.inMilliseconds);
    }
    debugPrint('pump loop positions ms: $samples');
    expect(samples.toSet().length, greaterThanOrEqualTo(4), reason: 'the pump loop really plays');
    app.stopSimulation();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tester.pump();
  });

  testWidgets('a chain of explosions, with the simulation stopped and restarted mid-blast, does not crash the audio plugin', (tester) async {
    final sound = SoundPlayer();
    final app = AppState(await loadDeviceDefs(), null, sound: sound);
    await tester.pumpWidget(BuildWireApp(app: app));
    await tester.pump();

    app.project.devices.add(PlacedDevice(id: 1, defId: 'generic_source_ac3', tag: 'G1', x: 40, y: 40));
    for (var i = 0; i < 6; i++) {
      final id = 2 + i;
      app.project.devices.add(PlacedDevice(id: id, defId: 'piloto_led_rojo', tag: 'H${i + 1}', x: 60.0 + 70 * i, y: 300));
      app.project.wires.add(Wire(id: 20 + i * 2, a: TerminalRef(1, 'L1'), b: TerminalRef(id, 'X1')));
      app.project.wires.add(Wire(id: 21 + i * 2, a: TerminalRef(1, 'L2'), b: TerminalRef(id, 'X2')));
    }

    var blasts = 0;
    for (var round = 0; round < 4; round++) {
      app.startSimulation();
      await tester.pump();
      // Real time, so the plugin's own callbacks interleave with the explosions.
      for (var tick = 0; tick < 25; tick++) {
        app.advance(0.1);
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      blasts += app.project.devices.where((d) => app.stateOf(d) == 'exploded').length;
      // Stop in the middle of the blasts and the crackle, then go again straight away.
      app.stopSimulation();
      await tester.pump();
    }
    expect(blasts, greaterThan(8));
    // Plenty of overlapping one-shots at once.
    for (var i = 0; i < 30; i++) {
      sound.play('explosion', true);
      sound.play('breaker_trip', true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await sound.stopShots();
    expect(sound.activeLoops, isEmpty);
  });
}

class PlacedTag {
  PlacedTag(this.app);

  final AppState app;

  void operate() {
    app.startSimulation();
    app.clickDevice(app.project.devices.firstWhere((d) => d.tag == 'QF1'));
    app.clickDevice(app.project.devices.firstWhere((d) => d.tag == 'F2'));
    final start = app.project.devices.firstWhere((d) => d.tag == 'S1');
    app.pressDevice(start, true);
    app.pressDevice(start, false);
  }
}
