import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:buildwire/ai/ai_settings.dart';
import 'package:buildwire/app_state.dart';
import 'package:buildwire/model/device_def.dart';
import 'package:buildwire/model/project.dart';
import 'package:buildwire/sim/ladder.dart';
import 'package:buildwire/sim/plc.dart';
import 'package:buildwire/sim/zm2.dart';
import 'package:buildwire/sound.dart';
import 'package:buildwire/main.dart';
import 'package:buildwire/ui/plc_editor.dart';
import 'package:flutter/material.dart';
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

LadderProgram parse(List<String> lines, {Map<String, LadderTimer>? timers, Map<String, LadderCounter>? counters}) {
  // Each line: five cells separated by spaces then "-> COIL"; '.' is an empty cell.
  final program = LadderProgram(timers: timers, counters: counters);
  for (final line in lines) {
    final parts = line.split('->');
    final cells = parts.first.trim().split(RegExp(r'\s+')).map((c) => LadderCell.parse(c == '.' ? '' : c)).toList();
    while (cells.length < 5) {
      cells.add(const LadderCell.empty());
    }
    program.rows.add(LadderRow(cells: cells, coil: parts.length > 1 ? LadderCoil.parse(parts[1].trim()) : null));
  }
  return program;
}

/// Scans [program] through a sequence of input sets, keeping memory like the app does.
class Runner {
  Runner(this.program);
  final LadderProgram program;
  PlcMemory memory = PlcMemory();
  double now = 0;

  Set<String> scan(Set<String> inputs, {double advance = 0}) {
    now += advance;
    final result = scanLadder(program, inputs: inputs, memory: memory, now: now);
    memory = result.memory;
    return result.bits;
  }
}

void main() {
  group('ladder engine', () {
    test('a clock block is on inside its weekly windows, including one past midnight', () {
      final program = parse(['H1 - - - -  ->  [Q1']);
      program.clocks['H1'] = LadderClock(slots: [
        ClockSlot(days: {1, 2, 3, 4, 5}, on: 8 * 60, off: 17 * 60),
        ClockSlot(days: {6}, on: 22 * 60, off: 2 * 60),
      ]);
      bool q1(DateTime t) => scanLadder(program, inputs: const {}, now: 0, clock: t).bits.contains('Q1');
      // 2024-01-01 is a Monday.
      expect(q1(DateTime(2024, 1, 1, 7, 59)), isFalse);
      expect(q1(DateTime(2024, 1, 1, 8, 0)), isTrue);
      expect(q1(DateTime(2024, 1, 1, 16, 59)), isTrue);
      expect(q1(DateTime(2024, 1, 1, 17, 0)), isFalse);
      expect(q1(DateTime(2024, 1, 6, 10, 0)), isFalse, reason: 'Saturday is not in the first window');
      expect(q1(DateTime(2024, 1, 6, 23, 0)), isTrue, reason: 'Saturday night window');
      expect(q1(DateTime(2024, 1, 7, 1, 30)), isTrue, reason: 'runs past midnight into Sunday');
      expect(q1(DateTime(2024, 1, 7, 2, 0)), isFalse);
      expect(scanLadder(program, inputs: const {}, now: 0).bits, isNot(contains('Q1')), reason: 'no clock, no H');
      expect(LadderProgram.fromJson(program.toJson()).clocks['H1']!.slots[1].toJson(), program.clocks['H1']!.slots[1].toJson());
    });

    test('a start/stop self-hold through a vertical link', () {
      final r = Runner(parse([
        'I1| !I2 - - -  ->  [Q1',
        'Q1 . . . .',
      ]));
      expect(r.scan({}), isNot(contains('Q1')));
      expect(r.scan({'I1'}), contains('Q1'), reason: 'start pressed');
      expect(r.scan({}), contains('Q1'), reason: 'held by its own contact');
      expect(r.scan({'I2'}), isNot(contains('Q1')), reason: 'stop opens the NC contact');
      expect(r.scan({}), isNot(contains('Q1')));
    });

    test('set, reset and impulse coils', () {
      final r = Runner(parse([
        'I1 - - - -  ->  SQ1',
        'I2 - - - -  ->  RQ1',
        'I3 - - - -  ->  ^Q2',
      ]));
      expect(r.scan({'I1'}), contains('Q1'));
      expect(r.scan({}), contains('Q1'), reason: 'latched');
      expect(r.scan({'I2'}), isNot(contains('Q1')));
      expect(r.scan({'I3'}), contains('Q2'), reason: 'first press turns it on');
      expect(r.scan({'I3'}), contains('Q2'), reason: 'holding the button is one press');
      expect(r.scan({}), contains('Q2'));
      expect(r.scan({'I3'}), isNot(contains('Q2')), reason: 'second press turns it off');
    });

    test('timer functions A (on-delay), C (off-delay), B (pulse) and D (flashing)', () {
      LadderProgram one(String fn) => parse(['I1 - - - -  ->  TT1', 'T1 - - - -  ->  [Q1'], timers: {'T1': LadderTimer(function: fn, preset: 2)});
      final a = Runner(one('A'));
      expect(a.scan({'I1'}), isNot(contains('Q1')));
      expect(a.scan({'I1'}, advance: 1.5), isNot(contains('Q1')));
      expect(a.scan({'I1'}, advance: 0.6), contains('Q1'), reason: 'after 2 s');
      expect(a.scan({}, advance: 0.1), isNot(contains('Q1')), reason: 'drops with the command');

      final c = Runner(one('C'));
      expect(c.scan({'I1'}), contains('Q1'), reason: 'on at once');
      expect(c.scan({}, advance: 1), contains('Q1'), reason: 'still on after release');
      expect(c.scan({}, advance: 1.5), contains('Q1'), reason: '1.5 s after release');
      expect(c.scan({}, advance: 0.6), isNot(contains('Q1')), reason: 'off 2 s after release');

      final b = Runner(one('B'));
      expect(b.scan({'I1'}), contains('Q1'));
      expect(b.scan({'I1'}, advance: 2.1), isNot(contains('Q1')), reason: 'one 2 s pulse even while held');

      final d = Runner(one('D'));
      expect(d.scan({'I1'}), contains('Q1'));
      expect(d.scan({'I1'}, advance: 2.5), isNot(contains('Q1')), reason: 'off half of each 4 s period');
      expect(d.scan({'I1'}, advance: 2), contains('Q1'));
      expect(d.memory.ticking, isTrue, reason: 'flashing keeps the clock running');
    });

    test('a counter counts rising edges up to its preset and resets', () {
      final r = Runner(parse([
        'I1 - - - -  ->  CC1',
        'I2 - - - -  ->  RC1',
        'C1 - - - -  ->  [Q1',
      ], counters: {'C1': LadderCounter(preset: 3)}));
      for (var i = 0; i < 2; i++) {
        r.scan({'I1'});
        r.scan({});
      }
      expect(r.memory.counts['C1'], 2);
      expect(r.scan({}), isNot(contains('Q1')));
      r.scan({'I1'});
      expect(r.scan({'I1'}), contains('Q1'), reason: 'third pulse reaches the preset; holding counts once');
      expect(r.memory.counts['C1'], 3);
      expect(r.scan({'I2'}), isNot(contains('Q1')));
      expect(r.memory.counts['C1'], 0);
    });

    test('the older rung list converts to the grid and runs the same', () {
      final program = LadderProgram.fromRungs([
        PlcRung(branches: [
          [const PlcContact('I1'), const PlcContact('I2', negated: true)],
          [const PlcContact('Q1'), const PlcContact('I2', negated: true)],
        ], coil: 'Q1'),
        PlcRung(branches: [
          [const PlcContact('C1')],
        ], coil: 'T1', preset: 4),
      ]);
      expect(ladderText(program), ['001: I1 !I2| - - -  ->  [Q1', '002: Q1 !I2 . . .', '003: Z1 - - - -  ->  TT1']);
      expect(program.timer('T1').preset, 4);
      final r = Runner(program);
      expect(r.scan({'I1'}), contains('Q1'));
      expect(r.scan({}), contains('Q1'));
      expect(r.scan({'I2'}), isNot(contains('Q1')));
      expect(LadderProgram.fromJson(program.toJson()).toJson(), program.toJson(), reason: 'saves and loads unchanged');
    });
  });

  group('Zelio .zm2 files', () {
    LadderProgram open(String name) => readZm2(File('test/fixtures/zelio/$name.zm2').readAsBytesSync()).program;

    test('contacts, NC contacts, links and coils come out as drawn in Zelio Soft', () {
      final first = readZm2(File('test/fixtures/zelio/02b_i1_q1.zm2').readAsBytesSync());
      expect(first.module, 'SR3B261FU');
      expect(ladderText(first.program), ['001: I1 - - - -  ->  [Q1']);
      expect(ladderText(open('05_i2nc_q3')), ['001: !I2 - - - -  ->  [Q3']);
      expect(ladderText(open('07_paralel')), ['001: I1| - - - -  ->  [Q1', '002: Q1 . . . .']);
      expect(ladderText(open('08_set_reset')), ['001: I1 - - - -  ->  SQ1', '002: I2 - - - -  ->  RQ1']);
      expect(ladderText(open('14_toggle')).take(2), ['001: I1 - - - -  ->  [M1   (tes)', '002: M1 - - - -  ->  ^Q1'], reason: 'the row comment typed in Zelio comes along');
    });

    test('timers bring their function and time, counters their coils', () {
      final timer = open('10b_timer_c7');
      expect(ladderText(timer), ['001: I1 - - - -  ->  TT1', '002: T1 - - - -  ->  [Q1']);
      expect(timer.timer('T1').function, 'C');
      expect(timer.timer('T1').preset, 7);
      expect(ladderText(open('11_counter3')), ['001: I1 - - - -  ->  CC1', '002: C1 - - - -  ->  [Q1', '003: I2 - - - -  ->  RC1']);
    });

    test('an official Zelio example with clocks and analog comparators opens, naming what is not simulated', () {
      final file = File(r'C:\Program Files (x86)\Schneider Electric\Zelio2\ZelioSoft2 V5.4.0\Z2User\Examples\1.1 gestion_serre_ladder.zm2');
      if (!file.existsSync()) return; // only where Zelio Soft is installed
      final result = readZm2(file.readAsBytesSync());
      expect(result.module, 'SR2B121BD');
      expect(ladderText(result.program).first, '001: H3 - A2| !I1 -  ->  [Q1');
      expect(result.warnings, containsAll(['A1', 'A2', 'H1', 'H2', 'H3']));
    });

    test('written .zm2 files read back the same, on every Zelio template', () {
      final program = parse([
        'I1| !I2 - - -  ->  [Q1',
        'Q1 . . . .',
        'I3 - - - -  ->  TT2',
        'T2 - - - -  ->  SQ2',
        'I4 - - - -  ->  CC1',
        'C1 Z1 - - -  ->  RQ2',
        'IA - - - -  ->  ^M3',
      ], timers: {'T2': LadderTimer(function: 'C', preset: 7.5)}, counters: {'C1': LadderCounter(preset: 4)});
      for (final file in Directory('assets/zelio').listSync().whereType<File>()) {
        final small = file.path.contains('sr2b121');
        if (small) {
          // The small SR2B121 has no IA input; it is refused by name rather than written wrong.
          expect(() => writeZm2(program, file.readAsBytesSync()), throwsFormatException);
          continue;
        }
        final back = readZm2(writeZm2(program, file.readAsBytesSync())).program;
        expect(ladderText(back), ladderText(program), reason: file.path);
        expect(back.timer('T2').function, 'C');
        expect(back.timer('T2').preset, 7.5);
        expect(back.counter('C1').preset, 4);
      }
    });

    test('a grid written into the empty template matches what Zelio Soft wrote itself', () {
      final zelio = File('test/fixtures/zelio/07_paralel.zm2').readAsBytesSync();
      final ours = writeZm2(readZm2(zelio).program, File('assets/zelio/zelio_sr3b261fu.zm2').readAsBytesSync());
      expect(ladderText(readZm2(ours).program), ladderText(readZm2(zelio).program));
    });

    test('not a Zelio file is refused with a message', () {
      expect(() => readZm2(Uint8List.fromList(utf8.encode('hello world, not zelio'))), throwsFormatException);
    });
  });

  group('Zelio PLCs on the canvas', () {
    late AppState app;
    setUp(() {
      final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
      final defs = {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
      app = AppState(defs, null, sound: Quiet(), secrets: MemorySecretStore());
    });
    tearDown(() => app.dispose());

    test('the six models are in the catalog with their terminals and keypad', () {
      for (final id in ['zelio_sr3b261fu', 'zelio_sr3b261b', 'zelio_sr3b261bd', 'zelio_sr2b201fu', 'zelio_sr2b121fu', 'zelio_sr2b121bd']) {
        final def = app.defs[id]!;
        expect(def.kind, 'plc', reason: id);
        expect(def.isZelio, isTrue);
        final terminals = def.terminals.map((t) => t.id).toSet();
        expect(terminals, containsAll({...def.plcInputs, for (final q in def.plcOutputs) ...def.plcOutputPair(q)!}), reason: id);
        expect((def.panel!['keys'] as Map).length, 6);
      }
      expect(app.defs['zelio_sr3b261fu']!.plcInputs.last, 'IG');
      expect(app.defs['zelio_sr3b261fu']!.plcOutputs.last, 'QA');
    });

    test('an SR3B261FU: a button on I1 sets Q1, a lamp on QA through the shared C terminal follows I2', () {
      app.aiPlaceDevice('generic_source_ac', tag: 'G1', x: 0, y: 0);
      app.aiPlaceDevice('zelio_sr3b261fu', tag: 'PLC1', x: 300, y: 0);
      app.aiPlaceDevice('pulsador_verde_1no', tag: 'S1', x: 0, y: 400);
      app.aiPlaceDevice('pulsador_verde_1no', tag: 'S2', x: 150, y: 400);
      app.aiPlaceDevice('piloto_led_verde', tag: 'H1', x: 800, y: 400);
      app.aiPlaceDevice('piloto_led_rojo', tag: 'H2', x: 950, y: 400);
      app.endAiEdit('x');
      PlacedDevice d(String tag) => app.deviceByTag(tag)!;
      final g = d('G1'), plc = d('PLC1');
      for (final (a, b) in [
        (TerminalRef(g.id, 'L'), TerminalRef(plc.id, 'L')),
        (TerminalRef(g.id, 'N'), TerminalRef(plc.id, 'N')),
        (TerminalRef(g.id, 'L'), TerminalRef(d('S1').id, '3')),
        (TerminalRef(d('S1').id, '4'), TerminalRef(plc.id, 'I1')),
        (TerminalRef(g.id, 'L'), TerminalRef(d('S2').id, '3')),
        (TerminalRef(d('S2').id, '4'), TerminalRef(plc.id, 'I2')),
        (TerminalRef(g.id, 'L'), TerminalRef(plc.id, 'Q1.1')),
        (TerminalRef(plc.id, 'Q1.2'), TerminalRef(d('H1').id, 'X1')),
        (TerminalRef(d('H1').id, 'X2'), TerminalRef(g.id, 'N')),
        (TerminalRef(g.id, 'L'), TerminalRef(plc.id, 'C')),
        (TerminalRef(plc.id, 'QA'), TerminalRef(d('H2').id, 'X1')),
        (TerminalRef(d('H2').id, 'X2'), TerminalRef(g.id, 'N')),
      ]) {
        app.tapTerminal(a);
        app.tapTerminal(b);
      }
      app.setProgram(plc, parse(['I1 - - - -  ->  SQ1', 'I2 - - - -  ->  [QA']));
      app.startSimulation();
      expect(app.stateOf(plc), startsWith('run'));
      expect(app.stateOf(d('H1')), 'off');
      app.pressDevice(d('S1'), true);
      app.pressDevice(d('S1'), false);
      expect(app.stateOf(d('H1')), 'on', reason: 'set by the pulse and latched');
      app.pressDevice(d('S2'), true);
      expect(app.stateOf(d('H2')), 'on', reason: 'QA switches C to QA');
      app.pressDevice(d('S2'), false);
      expect(app.stateOf(d('H2')), 'off');
      app.stopSimulation();
    });

    test('a PLC timer runs on the app clock, including fast-forward', () {
      app.aiPlaceDevice('generic_source_ac', tag: 'G1', x: 0, y: 0);
      app.aiPlaceDevice('zelio_sr2b121fu', tag: 'PLC1', x: 300, y: 0);
      app.endAiEdit('x');
      final g = app.deviceByTag('G1')!, plc = app.deviceByTag('PLC1')!;
      for (final (a, b) in [(TerminalRef(g.id, 'L'), TerminalRef(plc.id, 'L')), (TerminalRef(g.id, 'N'), TerminalRef(plc.id, 'N')), (TerminalRef(g.id, 'L'), TerminalRef(plc.id, 'I1'))]) {
        app.tapTerminal(a);
        app.tapTerminal(b);
      }
      app.setProgram(plc, parse(['I1 - - - -  ->  TT1', 'T1 - - - -  ->  [Q1'], timers: {'T1': LadderTimer(function: 'A', preset: 3)}));
      app.startSimulation();
      expect(app.bitsOf(plc), isNot(contains('Q1')));
      app.fastForward(3.2);
      expect(app.bitsOf(plc), contains('Q1'));
      expect(app.plcTimerDone(plc, 'T1'), isTrue);
      app.stopSimulation();
    });
  });

  testWidgets('the editor places a contact and a coil and sends them to the PLC', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
    final defs = {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
    final app = AppState(defs, null, sound: Quiet(), secrets: MemorySecretStore());
    app.openBuilder();
    app.aiPlaceDevice('zelio_sr3b261fu', tag: 'PLC1', x: 0, y: 0);
    app.endAiEdit('x');
    final plc = app.deviceByTag('PLC1')!;
    await tester.pumpWidget(BuildWireApp(app: app));
    await tester.pump();
    showPlcEditor(tester.element(find.byType(Scaffold).first), app, plc);
    await tester.pumpAndSettle();
    expect(find.text(kLadderEditorName), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ladder-contact-I')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('item-IA')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ladder-cell-0-0')));
    await tester.tap(find.byKey(const ValueKey('ladder-coil-Q')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('coil-SQA')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ladder-cell-0-5')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-program')));
    await tester.pump();
    expect(ladderText(app.ladderOf(plc)), ['001: IA - - - -  ->  SQA'], reason: 'the gap to the coil fills with wire');
    expect(app.canUndo, isTrue, reason: 'sending is one undo step');
    await tester.tap(find.byKey(const ValueKey('ladder-close')));
    await tester.pumpAndSettle();
  });

  testWidgets('items drag from the bottom palette onto cells, and the home page opens the editor on its own with a simulation', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
    final defs = {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
    final app = AppState(defs, null, sound: Quiet(), secrets: MemorySecretStore());
    await tester.pumpWidget(BuildWireApp(app: app));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-ladder')));
    await tester.pumpAndSettle();
    // The start page comes first, like Zelio Soft: new program, module from its photo, then the language.
    expect(find.byType(LadderEditor), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ladder-start-new')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('ladder-start-next'))).onPressed, isNull, reason: 'a module must be picked');
    await tester.tap(find.byKey(const ValueKey('ladder-family-sr2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ladder-module-zelio_sr3b261fu')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ladder-family-sr3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ladder-module-zelio_sr3b261fu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ladder-start-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ladder-lang-ld')));
    await tester.pumpAndSettle();
    expect(find.byType(LadderEditor), findsOneWidget);

    Future<void> drag(String item, String cell) async {
      final from = tester.getCenter(find.byKey(ValueKey(item)));
      final to = tester.getCenter(find.byKey(ValueKey(cell)));
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveTo(Offset.lerp(from, to, 0.5)!);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveTo(to);
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byKey(const ValueKey('ladder-contact-I')));
    await tester.pumpAndSettle();
    await drag('item-I1', 'ladder-cell-0-0');
    await tester.tap(find.byKey(const ValueKey('ladder-coil-T')));
    await tester.pumpAndSettle();
    await drag('coil-TT1', 'ladder-cell-0-5');
    await tester.tap(find.byKey(const ValueKey('ladder-contact-T')));
    await tester.pumpAndSettle();
    await drag('item-T1', 'ladder-cell-1-0');
    await tester.tap(find.byKey(const ValueKey('ladder-coil-Q')));
    await tester.pumpAndSettle();
    await drag('coil-[Q1', 'ladder-cell-1-5');
    expect(find.text('2 baris / 240'), findsOneWidget);

    // Simulate on its own: switch I1 on, the 3 s default timer runs, then Q1 comes on.
    await tester.tap(find.byKey(const ValueKey('ladder-simulate')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sim-I1')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 3300)));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('T1  3.0 / 3.0 dtk  ON'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ladder-simulate')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('ladder-to-canvas')));
    await tester.pumpAndSettle();
    final plc = app.project.devices.single;
    expect(plc.defId, 'zelio_sr3b261fu');
    expect(ladderText(app.ladderOf(plc)), ['001: I1 - - - -  ->  TT1', '002: T1 - - - -  ->  [Q1']);
  });
}
