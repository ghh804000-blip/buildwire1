import 'dart:convert';
import 'dart:io';

import 'package:buildwire/ai/ai_agent.dart';
import 'package:buildwire/ai/ai_connector.dart';
import 'package:buildwire/ai/ai_settings.dart';
import 'package:buildwire/ai/ladder_tools.dart';
import 'package:buildwire/app_state.dart';
import 'package:buildwire/model/device_def.dart';
import 'package:buildwire/sim/ladder.dart';
import 'package:buildwire/sound.dart';
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

Map<String, DeviceDef> loadDefs() {
  final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
  return {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
}

void main() {
  final defs = loadDefs();
  late LadderProgram program;
  late LadderWorkspace tools;
  setUp(() {
    program = LadderProgram();
    tools = LadderWorkspace(def: () => defs['zelio_sr3b261fu']!, read: () => program, write: (p) => program = p);
  });

  Map<String, dynamic> decode(String s) => jsonDecode(s) as Map<String, dynamic>;

  test('the assistant writes a self-holding program with symbols and tests it', () async {
    final written = await tools.run('tulis_program', {
      'baris': [
        {'kontak': ['I1|', '!I2', '-', '-', '-'], 'koil': '[Q1', 'komentar': 'start/stop'},
        {'kontak': ['Q1', '', '', '', '']},
      ],
      'simbol': {'I1': 'Start', 'I2': 'Stop', 'Q1': 'Motor'},
    });
    expect(written.error, isFalse, reason: written.result);
    expect(ladderText(program), ['001: I1| !I2 - - -  ->  [Q1   (start/stop)', '002: Q1 . . . .']);
    expect(program.symbols['Q1'], 'Motor');

    final report = decode((await tools.run('uji_program', {
      'langkah': [
        {'aksi': 'tekan', 'alamat': 'I1'},
        {'aksi': 'tunggu', 'detik': 2},
        {'aksi': 'tekan', 'alamat': 'I2'},
      ],
    }))
        .result);
    final steps = report['langkah'] as List;
    expect(steps[0]['menyala'], ['Q1'], reason: 'start latches');
    expect(steps[1].containsKey('padam'), isFalse, reason: 'still on after release');
    expect(steps[2]['padam'], ['Q1'], reason: 'stop drops it');
    expect(report['akhir']['output_menyala'], isEmpty);
  });

  test('timers run on the simulated clock in tests', () async {
    await tools.run('tulis_program', {
      'baris': [
        {'kontak': ['I1', '-', '-', '-', '-'], 'koil': 'TT1'},
        {'kontak': ['T1', '-', '-', '-', '-'], 'koil': 'Q2'},
      ],
      'timer': {
        'T1': {'fungsi': 'A', 'detik': 5},
      },
    });
    expect(program.timer('T1').preset, 5);
    expect(ladderText(program).last, '002: T1 - - - -  ->  [Q2', reason: 'a bare output name becomes a normal coil');
    final steps = decode((await tools.run('uji_program', {
      'langkah': [
        {'aksi': 'nyala', 'alamat': 'I1'},
        {'aksi': 'tunggu', 'detik': 4},
        {'aksi': 'tunggu', 'detik': 1.2},
      ],
    }))
        .result)['langkah'] as List;
    expect(steps[1].containsKey('menyala'), isFalse, reason: 'not yet at 4 s');
    expect(steps[2]['menyala'], containsAll(['Q2', 'T1']), reason: 'on after 5 s');
  });

  test('addresses the model does not have are refused, naming what is valid', () async {
    final small = LadderWorkspace(def: () => defs['zelio_sr2b121fu']!, read: () => program, write: (p) => program = p);
    final outcome = await small.run('tulis_program', {
      'baris': [
        {'kontak': ['IA', '-', '-', '-', '-'], 'koil': '[Q1'},
      ],
    });
    expect(outcome.error, isTrue);
    expect(outcome.result, contains('I8'));
    final coil = await small.run('ubah_baris', {
      'baris': [
        {'no': 1, 'kontak': ['I1', '-', '-', '-', '-'], 'koil': 'TTZ'},
      ],
    });
    expect(coil.error, isTrue);
  });

  test('editing single rows leaves the others alone', () async {
    await tools.run('tulis_program', {
      'baris': [
        {'kontak': ['I1', '-', '-', '-', '-'], 'koil': '[Q1'},
        {'kontak': ['I2', '-', '-', '-', '-'], 'koil': '[Q2'},
      ],
    });
    await tools.run('ubah_baris', {
      'baris': [
        {'no': 2, 'kontak': ['I3', '-', '-', '-', '-'], 'koil': 'SQ3'},
        {'no': 4, 'kontak': ['I4', '-', '-', '-', '-'], 'koil': 'RQ3'},
      ],
    });
    expect(ladderText(program), ['001: I1 - - - -  ->  [Q1', '002: I3 - - - -  ->  SQ3', '004: I4 - - - -  ->  RQ3']);
    await tools.run('ubah_baris', {'hapus': [3]});
    expect(ladderText(program).last, '003: I4 - - - -  ->  RQ3');
  });

  test('the agent loop drives the ladder tools and nudges an untested program to be tested', () async {
    final app = AppState(defs, null, sound: Quiet(), secrets: MemorySecretStore('k'))
      ..aiSettings = const AiSettings(baseUrl: 'https://hub.example/v1', format: ApiFormat.openai, model: 'm');
    AiAgent.retryDelays = const [Duration(milliseconds: 1)];
    Map<String, Object> call(String id, String name, Object args) => {
          'id': id,
          'type': 'function',
          'function': {'name': name, 'arguments': jsonEncode(args)},
        };
    Map<String, Object> reply({String content = '', List<Object>? calls}) => {
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {'role': 'assistant', 'content': content, 'tool_calls': ?calls},
            },
          ],
        };
    final replies = [
      reply(calls: [
        call('a', 'tulis_program', {
          'baris': [
            {'kontak': ['I1', '-', '-', '-', '-'], 'koil': '[Q1'},
          ],
        }),
      ]),
      reply(content: 'Selesai.'),
      reply(calls: [
        call('b', 'uji_program', {
          'langkah': [
            {'aksi': 'nyala', 'alamat': 'I1'},
          ],
        }),
      ]),
      reply(content: 'Program sudah diuji: Q1 menyala saat I1 menyala. Tekan Kirim ke PLC untuk memakainya.'),
    ];
    final seen = <Map<String, dynamic>>[];
    var turn = 0;
    final agent = AiAgent(app,
        workspace: tools,
        connector: AiConnector(
            client: MockClient((request) async {
          seen.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(jsonEncode(replies[turn++]), 200);
        })));
    await agent.send('Q1 menyala saat I1');
    expect(seen.first['tools'].map((t) => t['function']['name']), containsAll(['tulis_program', 'uji_program']));
    expect((seen.first['messages'] as List).first['content'], contains('BuildLadder'), reason: 'its own system prompt');
    expect((seen[2]['messages'] as List).last['content'], contains('uji_program'), reason: 'told to test before finishing');
    expect(ladderText(program), ['001: I1 - - - -  ->  [Q1']);
    expect(agent.entries.last.text, contains('Kirim ke PLC'));
    expect(app.project.isEmpty, isTrue, reason: 'the canvas is not touched');
    app.dispose();
  });
}
