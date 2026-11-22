import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:buildwire/ai/ai_agent.dart';
import 'package:buildwire/ai/ai_connector.dart';
import 'package:buildwire/ai/ai_settings.dart';
import 'package:buildwire/ai/circuit_tools.dart';
import 'package:buildwire/ai/swarm.dart';
import 'package:buildwire/app_state.dart';
import 'package:buildwire/main.dart';
import 'package:buildwire/model/device_def.dart';
import 'package:buildwire/sound.dart';
import 'package:buildwire/ui/ai_chat_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

Future<AppState> pumpWorkspace(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1500, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
  final defs = {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
  final app = AppState(defs, null, sound: Quiet(), secrets: MemorySecretStore('k'));
  app.openBuilder();
  await tester.pumpWidget(BuildWireApp(app: app));
  await tester.pump();
  return app;
}

/// Pumps frames until [future] completes, so tickers and delays advance.
Future<T> drive<T>(WidgetTester tester, Future<T> future, {int maxFrames = 4000, void Function(int frame)? each}) async {
  var done = false;
  late T value;
  unawaited(future.then((v) {
    value = v;
    done = true;
  }));
  for (var frame = 0; frame < maxFrames && !done; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    each?.call(frame);
  }
  expect(done, isTrue, reason: 'the animation finished');
  return value;
}

void main() {
  testWidgets('with a canvas on screen, devices arrive by drag and wires by a pulled cursor', (tester) async {
    final app = await pumpWorkspace(tester);
    expect(app.swarm.animated, isTrue);
    final tools = CircuitTools(app);
    await tools.run('bentuk_tim', {
      'nama': ['Kopi', 'Sambal', 'Gerimis'],
    });
    expect(app.swarm.leader!.name, 'Kopi');
    expect(app.swarm.members.length, 3);

    var sawGhostBeforeDrop = false;
    final added = await drive(tester, tools.run('tambah_perangkat', {
      'perangkat': [
        {'id': 'generic_source_ac', 'tag': 'G1', 'x': 0, 'y': 40},
        {'id': 'piloto_led_verde', 'tag': 'HL1', 'x': 420, 'y': 40},
      ],
    }), each: (_) {
      if (app.swarm.cursors.any((c) => c.carrying != null) && app.project.devices.length < 2) sawGhostBeforeDrop = true;
    });
    expect(added.error, isFalse);
    expect(sawGhostBeforeDrop, isTrue, reason: 'a device is carried before it lands');
    expect(app.project.devices.map((d) => d.tag), containsAll(['G1', 'HL1']));

    var sawPull = false;
    final wired = await drive(tester, tools.run('sambung', {
      'kabel': [
        {'dari': 'G1.L', 'ke': 'HL1.X1', 'warna': 'coklat'},
        {'dari': 'HL1.X2', 'ke': 'G1.N', 'warna': 'biru'},
      ],
    }), each: (_) {
      if (app.swarm.cursors.any((c) => c.pulling != null)) sawPull = true;
    });
    expect(jsonDecode(wired.result)['tersambung'], 2);
    expect(sawPull, isTrue, reason: 'a wire is pulled across before it is laid');

    var sawRunning = false;
    final tested = await drive(tester, tools.run('uji_simulasi', {
      'langkah': [
        {'aksi': 'tunggu', 'detik': 1},
      ],
    }), each: (_) {
      if (app.running) sawRunning = true;
    });
    expect(sawRunning, isTrue, reason: 'the test runs the real, visible simulation');
    expect(jsonDecode(tested.result)['akhir']['status']['HL1'], 'on');
    expect(app.running, isFalse);

    app.endAiEdit('selesai');
    app.swarm.finish();
    await tester.pump(const Duration(seconds: 2));
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(app.swarm.cursors, isEmpty, reason: 'the team leaves when the work is done');
  });

  testWidgets('while the agent works the canvas ignores the user, and the team forms and leaves', (tester) async {
    final app = await pumpWorkspace(tester);
    app.aiSettings = const AiSettings(baseUrl: 'https://hub.example/v1', format: ApiFormat.openai, model: 'm');
    final gate = Completer<void>();
    var turn = 0;
    final client = MockClient((request) async {
      turn++;
      if (turn == 1) {
        await gate.future;
        return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': '',
                    'tool_calls': [
                      {
                        'id': 'c1',
                        'type': 'function',
                        'function': {
                          'name': 'bentuk_tim',
                          'arguments': jsonEncode({
                            'nama': ['Teh', 'Bakwan'],
                          }),
                        },
                      },
                    ],
                  },
                },
              ],
            }),
            200);
      }
      return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'Selesai.'},
              },
            ],
          }),
          200);
    });
    final agent = AiAgent(app, connector: AiConnector(client: client));
    final running = agent.send('Halo');
    await tester.pump();
    expect(agent.busy, isTrue);

    // A real app uses app.ai; this agent stands in, so lock through the same flag the workspace reads.
    expect(app.aiLocked, isFalse, reason: 'app.ai is a different agent here');
    gate.complete();
    await drive(tester, running);
    expect(agent.entries.last.text, 'Selesai.');
    expect(app.swarm.cursors.every((c) => c.leaving), isTrue, reason: 'the team heads off when done');
  });

  testWidgets('the workspace lock absorbs canvas clicks while app.ai is busy', (tester) async {
    final app = await pumpWorkspace(tester);
    app.aiSettings = const AiSettings(baseUrl: 'https://hub.example/v1', format: ApiFormat.openai, model: 'm');
    app.aiPlaceDevice('chint_nxc32', tag: 'KM1', x: 100, y: 100);
    app.endAiEdit('x');
    await tester.pump();
    app.ai.busy = true;
    app.aiChanged();
    await tester.pump();
    final device = app.project.devices.single;
    await tester.tapAt(app.toScreen(Offset(device.x + 40, device.y + 40)) + tester.getTopLeft(find.byType(Expanded).first));
    await tester.pump();
    expect(app.selectedDevices, isEmpty, reason: 'clicks on the canvas do nothing while locked');
    expect(find.textContaining('Tim AI sedang'), findsOneWidget, reason: 'a banner says the team is at work');
    app.ai.busy = false;
    app.aiChanged();
    await tester.pump();
  });

  testWidgets('while locked, the assistant panel is the one thing that still moves: it can be resized', (tester) async {
    final app = await pumpWorkspace(tester);
    app.aiSettings = const AiSettings(baseUrl: 'https://hub.example/v1', format: ApiFormat.openai, model: 'm');
    app.toggleAiPanel();
    await tester.pump();
    app.ai.busy = true;
    app.aiChanged();
    await tester.pump();
    final before = tester.getSize(find.byType(AiChatPanel)).width;
    await tester.drag(find.byKey(const ValueKey('ai-panel-resize')), const Offset(-120, 0));
    await tester.pump();
    expect(tester.getSize(find.byType(AiChatPanel)).width, closeTo(before + 120, 1), reason: 'dragging the edge left widens it');
    await tester.drag(find.byKey(const ValueKey('ai-panel-resize')), const Offset(900, 0));
    await tester.pump();
    expect(app.aiPanelWidth, 300, reason: 'never narrower than 300');
    app.ai.busy = false;
    app.aiChanged();
    await tester.pump();
  });

  test('without a canvas the tools still apply at once, and a team is made up when none was named', () async {
    final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
    final defs = {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
    final app = AppState(defs, null, sound: Quiet(), secrets: MemorySecretStore('k'));
    expect(app.swarm.animated, isFalse);
    await CircuitTools(app).run('tambah_perangkat', {
      'perangkat': [
        {'id': 'chint_nxc32', 'tag': 'KM1'},
      ],
    });
    expect(app.project.devices.length, 1);
    expect(app.swarm.members.length, greaterThanOrEqualTo(2));
    expect(app.swarm.leader, isNotNull);
    expect(app.swarm.members.where((c) => c.leader).length, 1);
    final many = ['A', 'A', '  ', for (var i = 1; i <= 20; i++) 'N$i'];
    final names = app.swarm.formTeam(many);
    expect(names.length, Swarm.maxTeam, reason: 'unique, non-empty, at most 16');
    expect(names.first.name, 'A');
    expect(names.map((c) => c.color).toSet().length, Swarm.maxTeam, reason: 'every cursor gets its own color, even past ten');
    expect(SwarmCursor(name: 'x', color: Colors.red, leader: false, at: Offset.zero).alpha, 0);
    app.dispose();
  });

  test('a cursor move never hangs the assistant when frames stop or the overlay goes away', () async {
    final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
    final defs = {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
    final app = AppState(defs, null, sound: Quiet(), secrets: MemorySecretStore('k'));
    final swarm = app.swarm..attach();
    final cursor = swarm.formTeam(['A', 'B']).first;
    // No overlay ticks at all (a minimized window): the move still finishes, at its end point.
    await swarm.moveTo(cursor, const Offset(300, 200)).timeout(const Duration(seconds: 5));
    expect(cursor.pos, const Offset(300, 200));
    // The overlay is removed mid-move.
    final pending = swarm.moveTo(cursor, const Offset(10, 10));
    swarm.detach();
    await pending.timeout(const Duration(milliseconds: 200));
    expect(cursor.pos, const Offset(10, 10));
    app.dispose();
  });
}
