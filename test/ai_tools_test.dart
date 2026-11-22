import 'dart:convert';
import 'dart:io';

import 'package:buildwire/ai/ai_agent.dart';
import 'package:buildwire/ai/ai_connector.dart';
import 'package:buildwire/ai/ai_settings.dart';
import 'package:buildwire/ai/circuit_tools.dart';
import 'package:buildwire/app_state.dart';
import 'package:buildwire/model/device_def.dart';
import 'package:buildwire/sound.dart';
import 'package:buildwire/templates.dart';
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

AppState buildApp() {
  final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
  final defs = {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
  return AppState(defs, null, sound: Quiet(), secrets: MemorySecretStore('sk-test'));
}

Map<String, dynamic> decode(String result) => jsonDecode(result) as Map<String, dynamic>;

void main() {
  test('the tools rebuild the star-delta example from scratch, and the simulator test shows it working', () async {
    final app = buildApp();
    final tools = CircuitTools(app);
    final example = decode((await tools.run('lihat_contoh', {'id': 'stardelta'})).result);
    final devices = (example['perangkat'] as List).cast<Map<String, dynamic>>();
    final wires = (example['kabel'] as List).cast<Map<String, dynamic>>();

    final added = await tools.run('tambah_perangkat', {
      'perangkat': [for (final d in devices) {'id': d['id'], 'tag': d['tag'], 'x': d['x'], 'y': d['y']}],
    });
    expect(added.error, isFalse);
    expect(app.project.devices.map((d) => d.tag), containsAll(['QF1', 'KM1', 'KM2', 'KM3', 'KT1', 'M1']));
    final connected = await tools.run('sambung', {
      'kabel': [
        for (final w in wires) {'dari': w['dari'], 'ke': w['ke'], 'warna': w['warna'], 'ukuran_mm2': w['mm2'], 'jumper': w['jumper'] ?? false},
      ],
    });
    expect(decode(connected.result)['tersambung'], wires.length, reason: connected.result);
    await tools.run('atur', {'tag': 'KT1', 'waktu_detik': 5});

    final clock = Stopwatch()..start();
    final tested = await tools.run('uji_simulasi', {
      'langkah': [
        {'aksi': 'klik', 'tag': 'QF1'},
        {'aksi': 'klik', 'tag': 'F2'},
        {'aksi': 'tekan', 'tag': 'S1'},
        {'aksi': 'tunggu', 'detik': 6},
        {'aksi': 'tekan', 'tag': 'S0'},
      ],
    });
    expect(clock.elapsedMilliseconds, lessThan(3000), reason: 'six simulated seconds pass at once');
    final report = decode(tested.result);
    final steps = (report['langkah'] as List).cast<Map<String, dynamic>>();
    expect(steps[2]['berubah']['KM3'], 'open → closed', reason: 'star first: ${steps[2]}');
    expect(steps[2]['berubah']['M1'], 'stopped → run_fwd');
    expect(steps[3]['berubah']['KM2'], 'open → closed', reason: 'delta after the timer: ${steps[3]}');
    expect(steps[3]['berubah']['KM3'], 'closed → open');
    expect(steps[4]['berubah']['M1'], 'run_fwd → stopped');
    expect(steps.any((s) => s.containsKey('korsleting') || s.containsKey('galat')), isFalse);
    expect(app.running, isFalse, reason: 'the test stops the simulation unless asked to leave it running');

    expect(app.aiEditing, isTrue);
    app.endAiEdit('selesai');
    expect(app.canUndo, isTrue);
    app.undo();
    expect(app.project.isEmpty, isTrue, reason: 'everything the assistant did is one undo step');
    app.dispose();
  });

  test('mistakes come back as errors the model can act on, naming what is valid', () async {
    final app = buildApp();
    final tools = CircuitTools(app);
    await tools.run('tambah_perangkat', {
      'perangkat': [
        {'id': 'chint_nxc32', 'tag': 'KM1', 'x': 0, 'y': 0},
        {'id': 'chint_nxc32', 'tag': 'KM1', 'x': 0, 'y': 0},
        {'id': 'tidak_ada'},
      ],
    });
    expect(app.project.devices.map((d) => d.tag), unorderedEquals(['KM1', 'KM2']), reason: 'a taken tag is replaced');
    expect(app.deviceByTag('KM2')!.x, greaterThan(app.deviceByTag('KM1')!.x), reason: 'an overlapping device is moved aside');
    final bad = await tools.run('sambung', {
      'kabel': [
        {'dari': 'KM1.X9', 'ke': 'KM2.A1'},
      ],
    });
    expect(bad.error, isTrue);
    expect(bad.result, contains('A1'), reason: 'lists the real terminals');
    final plc = await tools.run('atur_program_plc', {'tag': 'KM1', 'rung': []});
    expect(plc.error, isTrue);
    final search = decode((await tools.run('cari_perangkat', {'kata_kunci': 'kontaktor'})).result);
    expect((search['hasil'] as List).first['id'], 'chint_nxc32', reason: 'recommended devices come first');
    app.dispose();
  });

  test('PLC programs are written in the short form and read back the same way', () async {
    final app = buildApp();
    final tools = CircuitTools(app);
    await tools.run('tambah_perangkat', {
      'perangkat': [
        {'id': 'logo_230rce', 'tag': 'PLC1'},
      ],
    });
    final written = await tools.run('atur_program_plc', {
      'tag': 'PLC1',
      'rung': [
        {
          'cabang': [
            ['I1', 'I2', '!I3'],
            ['M1', 'I2', '!I3'],
          ],
          'coil': 'M1',
        },
        {
          'cabang': [
            ['M1'],
          ],
          'coil': 'T1',
          'preset': 5,
        },
      ],
    });
    expect(written.error, isFalse, reason: written.result);
    final circuit = decode((await tools.run('lihat_rangkaian', {})).result);
    final device = (circuit['perangkat'] as List).first as Map<String, dynamic>;
    // Two parallel branches of three contacts on rows 1-2, joined by a vertical link after column 3, then the timer.
    expect(device['program_ladder'], [
      '001: I1 I2 !I3| - -  ->  [M1',
      '002: M1 I2 !I3 . .',
      '003: M1 - - - -  ->  TT1',
    ]);
    expect(device['timer_plc'], {'T1': {'f': 'A', 't': 5.0}});
    app.dispose();
  });

  /// A scripted model: each request gets the next reply, and every request body is kept.
  MockClient scripted(List<Object> replies, List<Map<String, dynamic>> seen) {
    var turn = 0;
    return MockClient((request) async {
      seen.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(jsonEncode(replies[turn++]), 200, headers: {'content-type': 'application/json'});
    });
  }

  test('the agent loop in the OpenAI format: tool calls, tool results, then a final answer, as one undo step', () async {
    final app = buildApp();
    app.aiSettings = const AiSettings(baseUrl: 'https://hub.example/v1', format: ApiFormat.openai, model: 'm');
    final seen = <Map<String, dynamic>>[];
    Map<String, Object> call(String id, String name, Object args) => {
          'id': id,
          'type': 'function',
          'function': {'name': name, 'arguments': jsonEncode(args)},
        };
    final agent = AiAgent(app,
        connector: AiConnector(
            client: scripted([
          {
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': '',
                  'reasoning_content': 'pikir dulu',
                  'tool_calls': [
                    call('c1', 'tambah_perangkat', {
                      'perangkat': [
                        {'id': 'generic_source_ac', 'tag': 'G1', 'x': 0, 'y': 40},
                        {'id': 'piloto_led_verde', 'tag': 'HL1', 'x': 400, 'y': 40},
                      ],
                    }),
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': null,
                  'tool_calls': [
                    call('c2', 'sambung', {
                      'kabel': [
                        {'dari': 'G1.L', 'ke': 'HL1.X1', 'warna': 'coklat'},
                        {'dari': 'HL1.X2', 'ke': 'G1.N', 'warna': 'biru'},
                      ],
                    }),
                    call('c3', 'uji_simulasi', {'langkah': <Object>[]}),
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'Selesai. **Lampu** menyala saat simulasi dijalankan.'},
              },
            ],
          },
        ], seen)));

    await agent.send('Buatkan lampu sederhana');
    expect(agent.entries.map((e) => e.kind), [ChatKind.user, ChatKind.tool, ChatKind.tool, ChatKind.tool, ChatKind.assistant]);
    expect(agent.entries.last.text, contains('Lampu'));
    expect(app.project.devices.length, 2);
    expect(app.project.wires.length, 2);

    final second = seen[1]['messages'] as List;
    expect(second.first['role'], 'system');
    expect(second[2]['reasoning_content'], 'pikir dulu', reason: 'the assistant turn goes back as it came, reasoning included');
    expect(second[3], {'role': 'tool', 'tool_call_id': 'c1', 'content': isA<String>()});
    final third = seen[2]['messages'] as List;
    expect(third.where((m) => m['role'] == 'tool').length, 3);
    final simReport = decode(third.last['content'] as String);
    expect(simReport['akhir']['status']['HL1'], 'on', reason: 'the simulator saw the lamp lit');
    expect((seen.first['tools'] as List).length, CircuitTools.definitions.length);

    expect(app.canUndo, isTrue);
    app.undo();
    expect(app.project.isEmpty, isTrue);
    app.dispose();
  });

  test('the agent loop in the Anthropic format sends tool results as tool_result blocks', () async {
    final app = buildApp();
    app.aiSettings = const AiSettings(baseUrl: 'https://api.example/v1', format: ApiFormat.anthropic, model: 'claude-x');
    final seen = <Map<String, dynamic>>[];
    final agent = AiAgent(app,
        connector: AiConnector(
            client: scripted([
          {
            'type': 'message',
            'content': [
              {'type': 'thinking', 'thinking': 'hmm', 'signature': 'sig'},
              {'type': 'text', 'text': 'Saya lihat dulu.'},
              {'type': 'tool_use', 'id': 'tu1', 'name': 'lihat_rangkaian', 'input': <String, Object>{}},
            ],
            'stop_reason': 'tool_use',
          },
          {
            'type': 'message',
            'content': [
              {'type': 'text', 'text': 'Kanvas masih kosong.'},
            ],
            'stop_reason': 'end_turn',
          },
        ], seen)));
    await agent.send('Ada apa di kanvas?');
    final second = seen[1];
    expect(second['system'], contains('BuildWire'));
    final messages = second['messages'] as List;
    expect(messages[1]['content'][0], {'type': 'thinking', 'thinking': 'hmm', 'signature': 'sig'}, reason: 'blocks go back unchanged');
    expect(messages[2]['role'], 'user');
    expect(messages[2]['content'][0]['type'], 'tool_result');
    expect(messages[2]['content'][0]['tool_use_id'], 'tu1');
    expect(agent.entries.last.text, 'Kanvas masih kosong.');
    expect(app.canUndo, isFalse, reason: 'only looking changes nothing');
    app.dispose();
  });

  group('the agent keeps going', () {
    Map<String, Object> call(String id, String name, Object args) => {
          'id': id,
          'type': 'function',
          'function': {'name': name, 'arguments': args is String ? args : jsonEncode(args)},
        };
    Map<String, Object> reply({String content = '', List<Object>? calls, String finish = 'stop'}) => {
          'choices': [
            {
              'finish_reason': finish,
              'message': {'role': 'assistant', 'content': content, 'tool_calls': ?calls},
            },
          ],
        };
    setUp(() => AiAgent.retryDelays = const [Duration(milliseconds: 1), Duration(milliseconds: 1), Duration(milliseconds: 1)]);

    AppState openAiApp() => buildApp()..aiSettings = const AiSettings(baseUrl: 'https://hub.example/v1', format: ApiFormat.openai, model: 'm');

    test('a busy server or a dropped connection is retried instead of ending the job', () async {
      final app = openAiApp();
      var turn = 0;
      final client = MockClient((request) async {
        turn++;
        if (turn == 1) return http.Response('{"error":{"message":"overloaded"}}', 503);
        if (turn == 2) throw http.ClientException('connection reset');
        return http.Response(jsonEncode(reply(content: 'Halo, kanvas kosong.')), 200);
      });
      final agent = AiAgent(app, connector: AiConnector(client: client));
      await agent.send('halo');
      expect(turn, 3);
      expect(agent.entries.last.kind, ChatKind.assistant);
      app.dispose();
    });

    test('when the server stays down, the job stops with a way to resume', () async {
      final app = openAiApp();
      var turn = 0;
      final agent = AiAgent(app, connector: AiConnector(client: MockClient((request) async {
        turn++;
        if (turn == 1) return http.Response(jsonEncode(reply(calls: [call('c1', 'lihat_rangkaian', <String, Object>{})])), 200);
        return http.Response('{"error":"upstream error","upstream_status":502}', 502);
      })));
      await agent.send('cek');
      expect(turn, 2 + AiAgent.retryDelays.length);
      expect(agent.entries.last.kind, ChatKind.error);
      expect(agent.entries.last.text, contains('lanjutkan'));
      app.dispose();
    });

    test('a short in the simulator test comes with a hint on where to look', () async {
      final app = buildApp()..applyTemplate(kTemplates.firstWhere((t) => t.id == 'dol'));
      final tools = CircuitTools(app);
      await tools.run('sambung', {
        'kabel': [
          {'dari': 'KM1.2', 'ke': 'KM1.4'},
        ],
      });
      final outcome = await tools.run('uji_simulasi', {
        'langkah': [
          for (final tag in ['QF1', 'F2']) {'aksi': 'klik', 'tag': tag},
          {'aksi': 'tekan', 'tag': 'S1'},
        ],
      });
      final steps = decode(outcome.result)["langkah"] as List;
      final hinted = steps.where((s) => (s as Map).containsKey('petunjuk')).toList();
      expect(hinted.length, 1, reason: 'only where the short first shows up');
      expect(hinted.single['petunjuk'], contains('tekan S1'));
      expect(hinted.single['korsleting'], contains('QF1'));
      app.dispose();
    });

    test('a wrong key is not retried', () async {
      final app = openAiApp();
      var turn = 0;
      final agent = AiAgent(app, connector: AiConnector(client: MockClient((request) async {
        turn++;
        return http.Response('{"error":{"message":"bad key"}}', 401);
      })));
      await agent.send('halo');
      expect(turn, 1);
      expect(agent.entries.last.kind, ChatKind.error);
      app.dispose();
    });

    test('a cut-off tool call is not run but sent back to be redone, and stopping before testing gets a nudge', () async {
      final app = openAiApp();
      final seen = <Map<String, dynamic>>[];
      final lamp = {
        'perangkat': [
          {'id': 'generic_source_ac', 'tag': 'G1', 'x': 0, 'y': 40},
          {'id': 'piloto_led_verde', 'tag': 'HL1', 'x': 400, 'y': 40},
        ],
      };
      final agent = AiAgent(app,
          connector: AiConnector(
              client: scripted([
            reply(calls: [call('c1', 'tambah_perangkat', '{"perangkat":[{"id":"generic_so')], finish: 'length'),
            reply(calls: [call('c2', 'tambah_perangkat', lamp)]),
            reply(content: 'Sekarang saya akan menyambung kabelnya:'),
            reply(calls: [
              call('c3', 'sambung', {
                'kabel': [
                  {'dari': 'G1.L', 'ke': 'HL1.X1'},
                  {'dari': 'HL1.X2', 'ke': 'G1.N'},
                ],
              }),
            ]),
            reply(content: 'Selesai, lampu sudah terpasang.'),
            reply(calls: [call('c4', 'uji_simulasi', {'langkah': <Object>[]})]),
            reply(content: 'Sudah diuji: lampu menyala. Cara mencoba: tekan Jalankan.'),
          ], seen)));
      await agent.send('lampu');
      expect(seen.length, 7);
      final firstResult = (seen[1]['messages'] as List).last;
      expect(firstResult['content'], contains('terpotong'));
      expect(app.project.devices.length, 2, reason: 'the cut-off call placed nothing; the retry placed both');
      expect((seen[3]['messages'] as List).last['content'], contains('Lanjutkan'), reason: 'announcing is not doing');
      expect((seen[5]['messages'] as List).last['content'], contains('uji_simulasi'), reason: 'built but untested');
      expect(agent.entries.last.text, contains('Cara mencoba'));
      app.dispose();
    });

    test('announcing the next step counts as unfinished, a closing explanation does not', () {
      expect(AiAgent.soundsUnfinished('Perangkat sudah ditaruh. Sekarang saya sambung kabelnya.'), isTrue);
      expect(AiAgent.soundsUnfinished('Berikut kabelnya:'), isTrue);
      expect(AiAgent.soundsUnfinished('Rangkaian DOL selesai dan sudah diuji. Cara mencoba: klik QF1, tekan S2.'), isFalse);
      expect(AiAgent.soundsUnfinished('Kanvas berisi 5 perangkat.'), isFalse);
    });
  });

  test('every built-in template is described without errors', () async {
    final app = buildApp();
    final tools = CircuitTools(app);
    for (final template in kTemplates) {
      final outcome = await tools.run('lihat_contoh', {'id': template.id});
      expect(outcome.error, isFalse, reason: template.id);
    }
    app.dispose();
  });
}
