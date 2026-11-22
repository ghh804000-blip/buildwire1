import 'dart:convert';

import 'package:buildwire/relay/relay_editor.dart';
import 'package:buildwire/relay/relay_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'workspace_test.dart' as w;

/// Builds a sheet from symbols and wires written briefly: wire('S1.2', 'KM1.A1').
class Sheet {
  final sheet = RelaySheet();
  final _byTag = <String, RelaySymbol>{};

  RelaySymbol add(String type, String tag, {int x = 0, int y = 0, Map<String, dynamic>? params}) {
    final s = RelaySymbol(id: sheet.nextId(), type: type, tag: tag, x: x, y: y, params: params);
    sheet.symbols.add(s);
    _byTag[tag] = s;
    return s;
  }

  RelaySymbol supply(String name, String label) => add('supply', name, params: {'supply': label});

  void wire(String a, String b) {
    RelayEnd end(String ref) {
      final dot = ref.lastIndexOf('.');
      return RelayEnd(_byTag[ref.substring(0, dot)]!.id, ref.substring(dot + 1));
    }

    sheet.wires.add(RelayWire(id: sheet.nextId(), a: end(a), b: end(b)));
  }

  RelaySymbol operator [](String tag) => _byTag[tag]!;
}

/// L - QF1 - S0 (NC) - S1 (NO) parallel with KM1 13-14 - KM1 coil - N; lamp H1 on a KM1 contact.
Sheet startStop() {
  final t = Sheet()
    ..supply('L', 'L1')
    ..supply('N', 'N')
    ..add('mcb1', 'QF1')
    ..add('push_nc', 'S0')
    ..add('push_no', 'S1')
    ..add('aux_no', 'KM1')
    ..add('coil', 'KM1C')
    ..add('aux_no', 'KM1H')
    ..add('lamp', 'H1');
  t['KM1C'].tag = 'KM1';
  t['KM1H'].tag = 'KM1';
  t
    ..wire('L.1', 'QF1.1')
    ..wire('QF1.2', 'S0.1')
    ..wire('S0.2', 'S1.1')
    ..wire('S1.2', 'KM1C.A1')
    ..wire('S0.2', 'KM1.1')
    ..wire('KM1.2', 'KM1C.A1')
    ..wire('KM1C.A2', 'N.1')
    ..wire('QF1.2', 'KM1H.1')
    ..wire('KM1H.2', 'H1.X1')
    ..wire('H1.X2', 'N.1');
  return t;
}

void main() {
  test('a start/stop circuit holds itself in through the contactor contact and drops out on stop', () {
    final t = startStop();
    final sim = RelaySim(t.sheet);
    expect(sim.solve(0).energized, isEmpty);
    sim.pressed.add(t['S1'].id);
    var r = sim.solve(0.1);
    expect(r.energized, {'KM1'});
    expect(r.loadsOn, contains(t['H1'].id), reason: 'the pilot lamp follows the contactor');
    sim.pressed.remove(t['S1'].id);
    r = sim.solve(0.2);
    expect(r.energized, {'KM1'}, reason: 'held in by its own NO contact');
    sim.pressed.add(t['S0'].id);
    r = sim.solve(0.3);
    expect(r.energized, isEmpty);
    sim.pressed.remove(t['S0'].id);
    expect(sim.solve(0.4).energized, isEmpty, reason: 'stays off after stop');
    expect(r.warnings, isEmpty);
  });

  test('an on-delay timer closes its contact after the set time', () {
    final t = Sheet()
      ..supply('L', 'L1')
      ..supply('N', 'N')
      ..add('selector_no', 'S1')
      ..add('timer_on', 'KT1', params: {'seconds': 2})
      ..add('timer_no', 'KT1C')
      ..add('lamp', 'H1');
    t['KT1C'].tag = 'KT1';
    t
      ..wire('L.1', 'S1.1')
      ..wire('S1.2', 'KT1.A1')
      ..wire('KT1.A2', 'N.1')
      ..wire('L.1', 'KT1C.1')
      ..wire('KT1C.2', 'H1.X1')
      ..wire('H1.X2', 'N.1');
    final sim = RelaySim(t.sheet);
    sim.solve(0);
    sim.toggled.add(t['S1'].id);
    expect(sim.solve(1).loadsOn, isNot(contains(t['H1'].id)));
    expect(sim.ticking, isTrue);
    expect(sim.timerElapsed('KT1', 2), closeTo(1, 0.001));
    expect(sim.solve(2.5).loadsOn, isNot(contains(t['H1'].id)), reason: '1.5 s counted of 2');
    expect(sim.solve(3.1).loadsOn, contains(t['H1'].id));
    sim.toggled.remove(t['S1'].id);
    expect(sim.solve(3.2).loadsOn, isNot(contains(t['H1'].id)), reason: 'resets with the coil');
  });

  test('a short trips the breaker feeding it, and with no breaker it is reported', () {
    final t = Sheet()
      ..supply('L', 'L1')
      ..supply('N', 'N')
      ..add('mcb1', 'QF1')
      ..add('push_no', 'S1');
    t
      ..wire('L.1', 'QF1.1')
      ..wire('QF1.2', 'S1.1')
      ..wire('S1.2', 'N.1');
    final sim = RelaySim(t.sheet);
    sim.pressed.add(t['S1'].id);
    final r = sim.solve(0);
    expect(sim.open, contains(t['QF1'].id));
    expect(r.short, isFalse);
    expect(sim.events.single, contains('QF1'));

    final bare = Sheet()
      ..supply('L', 'L1')
      ..supply('N', 'N');
    bare.wire('L.1', 'N.1');
    expect(RelaySim(bare.sheet).solve(0).short, isTrue);
  });

  test('a three-phase motor runs from main contacts, and swapping two phases reverses it', () {
    final t = Sheet()
      ..add('supply3', 'G')
      ..add('main3', 'KM1')
      ..add('motor3', 'M1')
      ..supply('L', 'L1')
      ..supply('N', 'N')
      ..add('selector_no', 'S1')
      ..add('coil', 'KM1C');
    t['KM1C'].tag = 'KM1';
    t
      ..wire('G.L1', 'KM1.1')
      ..wire('G.L2', 'KM1.3')
      ..wire('G.L3', 'KM1.5')
      ..wire('KM1.2', 'M1.U')
      ..wire('KM1.4', 'M1.V')
      ..wire('KM1.6', 'M1.W')
      ..wire('L.1', 'S1.1')
      ..wire('S1.2', 'KM1C.A1')
      ..wire('KM1C.A2', 'N.1');
    final sim = RelaySim(t.sheet);
    expect(sim.solve(0).motors, isEmpty);
    sim.toggled.add(t['S1'].id);
    expect(sim.solve(0.1).motors[t['M1'].id], 1);
    // Swap V and W.
    t.sheet.wires.removeWhere((w) => w.b.symbol == t['M1'].id && (w.b.pin == 'V' || w.b.pin == 'W'));
    t
      ..wire('KM1.4', 'M1.W')
      ..wire('KM1.6', 'M1.V');
    expect(sim.solve(0.2).motors[t['M1'].id], -1);
  });

  test('an overload trip opens 95-96 and a contact with no matching coil is flagged', () {
    final t = Sheet()
      ..supply('L', 'L1')
      ..supply('N', 'N')
      ..add('tor', 'F1')
      ..add('tor_nc', 'F1C')
      ..add('coil', 'KM1')
      ..add('aux_no', 'KM9');
    t['F1C'].tag = 'F1';
    t
      ..wire('L.1', 'F1C.1')
      ..wire('F1C.2', 'KM1.A1')
      ..wire('KM1.A2', 'N.1');
    final sim = RelaySim(t.sheet);
    final r = sim.solve(0);
    expect(r.energized, {'KM1'});
    expect(r.warnings.single, contains('KM9'));
    sim.tripped.add('F1');
    expect(sim.solve(0.1).energized, isEmpty);
  });

  test('a sheet survives saving and opening, and positions follow rotation', () {
    final t = startStop();
    t['S1']
      ..x = 10
      ..y = 4
      ..rotation = 1;
    expect(t['S1'].pin('1'), const Offset(14, 5), reason: 'a quarter turn puts the top pin on the right');
    final copy = RelaySheet.fromJson(jsonDecode(jsonEncode(t.sheet.toJson())) as Map<String, dynamic>);
    expect(copy.symbols.length, t.sheet.symbols.length);
    expect(copy.wires.length, t.sheet.wires.length);
    expect(copy.symbol(t['S1'].id)!.pin('1'), const Offset(14, 5));
    expect(() => RelaySheet.fromJson({'format': 'x'}), throwsFormatException);
  });

  test('a changeover contact switches its common from NC to NO; an impulse relay latches on one pulse and drops on the next', () {
    final t = Sheet()
      ..supply('L', 'L1')
      ..supply('N', 'N')
      ..add('push_no', 'S1')
      ..add('impulse', 'K1')
      ..add('aux_co', 'K1C')
      ..add('lamp', 'H1')
      ..add('lamp', 'H2');
    t['K1C'].tag = 'K1';
    t
      ..wire('L.1', 'S1.1')
      ..wire('S1.2', 'K1.A1')
      ..wire('K1.A2', 'N.1')
      ..wire('L.1', 'K1C.11')
      ..wire('K1C.12', 'H1.X1')
      ..wire('K1C.14', 'H2.X1')
      ..wire('H1.X2', 'N.1')
      ..wire('H2.X2', 'N.1');
    final sim = RelaySim(t.sheet);
    var r = sim.solve(0);
    expect(r.loadsOn, containsAll([t['H1'].id]));
    expect(r.loadsOn, isNot(contains(t['H2'].id)));
    for (final (time, h2) in const [(0.1, true), (0.3, false), (0.5, true)]) {
      sim.pressed.add(t['S1'].id);
      sim.solve(time);
      sim.pressed.remove(t['S1'].id);
      r = sim.solve(time + 0.1);
      expect(r.loadsOn.contains(t['H2'].id), h2, reason: 'pulse at $time');
      expect(r.loadsOn.contains(t['H1'].id), !h2);
    }
  });

  test('a six-terminal motor runs in star with U2 V2 W2 joined and in delta when they go to the other phases', () {
    final t = Sheet()
      ..add('supply3', 'G')
      ..add('motor3_6', 'M1')
      ..add('node', 'Y');
    t
      ..wire('G.L1', 'M1.U1')
      ..wire('G.L2', 'M1.V1')
      ..wire('G.L3', 'M1.W1')
      ..wire('M1.U2', 'Y.1')
      ..wire('M1.V2', 'Y.1')
      ..wire('M1.W2', 'Y.1');
    final sim = RelaySim(t.sheet);
    var r = sim.solve(0);
    expect(r.motors[t['M1'].id], 1);
    expect(r.motorModes[t['M1'].id], 'Y');
    t.sheet.wires.removeWhere((w) => w.b.symbol == t['Y'].id);
    t
      ..wire('M1.U2', 'G.L3')
      ..wire('M1.V2', 'G.L1')
      ..wire('M1.W2', 'G.L2');
    r = sim.solve(0.1);
    expect(r.motorModes[t['M1'].id], 'Δ');
    expect(r.short, isFalse);
  });

  test('a Dahlander motor runs slow on 1U 1V 1W and fast on 2U 2V 2W with 1U 1V 1W shorted', () {
    final t = Sheet()
      ..add('supply3', 'G')
      ..add('motor_dahl', 'M1')
      ..add('node', 'Y');
    t
      ..wire('G.L1', 'M1.1U')
      ..wire('G.L2', 'M1.1V')
      ..wire('G.L3', 'M1.1W');
    final sim = RelaySim(t.sheet);
    expect(sim.solve(0).motorModes[t['M1'].id], '1');
    t.sheet.wires.clear();
    t
      ..wire('G.L1', 'M1.2U')
      ..wire('G.L2', 'M1.2V')
      ..wire('G.L3', 'M1.2W')
      ..wire('M1.1U', 'Y.1')
      ..wire('M1.1V', 'Y.1')
      ..wire('M1.1W', 'Y.1');
    expect(sim.solve(0.1).motorModes[t['M1'].id], '2');
  });

  test('a control transformer and a 24 V supply feed their own circuits; a diode passes DC one way only', () {
    final t = Sheet()
      ..supply('L', 'L1')
      ..supply('N', 'N')
      ..add('transformer', 'T1')
      ..add('lamp', 'H1')
      ..add('psu', 'G1')
      ..add('diode', 'V1')
      ..add('lamp', 'H2')
      ..add('diode', 'V2')
      ..add('lamp', 'H3');
    t
      ..wire('L.1', 'T1.P1')
      ..wire('N.1', 'T1.P2')
      ..wire('T1.S1', 'H1.X1')
      ..wire('T1.S2', 'H1.X2')
      ..wire('L.1', 'G1.L')
      ..wire('N.1', 'G1.N')
      ..wire('G1.+', 'V1.A')
      ..wire('V1.K', 'H2.X1')
      ..wire('H2.X2', 'G1.-')
      ..wire('G1.+', 'V2.K')
      ..wire('V2.A', 'H3.X1')
      ..wire('H3.X2', 'G1.-');
    final r = RelaySim(t.sheet).solve(0);
    expect(r.loadsOn, contains(t['H1'].id), reason: 'the secondary has its own voltage');
    expect(r.loadsOn, contains(t['H2'].id), reason: 'forward through V1');
    expect(r.loadsOn, isNot(contains(t['H3'].id)), reason: 'V2 is reversed');
    expect(r.short, isFalse);
  });

  test('an earth fault trips the RCD rather than the MCB ahead of it', () {
    final t = Sheet()
      ..supply('L', 'L1')
      ..supply('N', 'N')
      ..add('mcb1', 'QF1')
      ..add('rcd2', 'Q1')
      ..add('push_no', 'S1')
      ..add('earth', 'PE');
    t
      ..wire('L.1', 'QF1.1')
      ..wire('QF1.2', 'Q1.1')
      ..wire('N.1', 'Q1.3')
      ..wire('Q1.2', 'S1.1')
      ..wire('S1.2', 'PE.1');
    final sim = RelaySim(t.sheet);
    sim.pressed.add(t['S1'].id);
    sim.solve(0);
    expect(sim.open, {t['Q1'].id});
    expect(sim.events.single, contains('bocor'));
  });

  test('a 1-0-2 selector closes one contact per side and a flasher timer turns its contact on and off', () {
    final t = Sheet()
      ..supply('L', 'L1')
      ..supply('N', 'N')
      ..add('selector3', 'S1')
      ..add('lamp', 'H1')
      ..add('lamp', 'H2')
      ..add('timer_cyc', 'KT1', params: {'seconds': 1})
      ..add('timer_no', 'KT1C')
      ..add('lamp', 'H3');
    t['KT1C'].tag = 'KT1';
    t
      ..wire('L.1', 'S1.1')
      ..wire('L.1', 'S1.3')
      ..wire('S1.2', 'H1.X1')
      ..wire('S1.4', 'H2.X1')
      ..wire('H1.X2', 'N.1')
      ..wire('H2.X2', 'N.1')
      ..wire('S1.2', 'KT1.A1')
      ..wire('KT1.A2', 'N.1')
      ..wire('L.1', 'KT1C.1')
      ..wire('KT1C.2', 'H3.X1')
      ..wire('H3.X2', 'N.1');
    final sim = RelaySim(t.sheet);
    expect(sim.solve(0).loadsOn, isEmpty);
    sim.positions[t['S1'].id] = 2;
    expect(sim.solve(0.1).loadsOn, {t['H2'].id});
    sim.positions[t['S1'].id] = 1;
    final on = sim.solve(1);
    expect(on.loadsOn, containsAll([t['H1'].id, t['H3'].id]), reason: 'flasher starts on');
    expect(sim.solve(1.5).loadsOn, contains(t['H3'].id), reason: 'on for the first second');
    expect(sim.solve(2.2).loadsOn, isNot(contains(t['H3'].id)), reason: 'off for the next');
    expect(sim.solve(3.1).loadsOn, contains(t['H3'].id));
  });

  testWidgets('BuildRelay opens empty from the home page; a circuit drawn there runs when its button is held', (tester) async {
    await w.pumpApp(tester, home: true);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('home-relay')));
    await tester.pumpAndSettle();
    expect(find.byType(RelayEditor), findsOneWidget);
    expect(find.text('0 simbol, 0 kabel'), findsOneWidget, reason: 'no ready-made circuit');

    // The sheet starts at pan (60, 40), 20 px per grid unit.
    final origin = tester.getTopLeft(find.byKey(const ValueKey('relay-canvas')));
    Offset at(double gx, double gy) => origin + Offset(60 + gx * 20, 40 + gy * 20);
    Future<void> put(String type, double gx, double gy) async {
      // The palette is a lazy list: scroll down until the tile is built.
      await tester.scrollUntilVisible(find.byKey(ValueKey('relay-palette-$type')), 150,
          scrollable: find.descendant(of: find.byType(RelayEditor), matching: find.byType(Scrollable)).first);
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('relay-palette-$type')));
      await tester.pump();
      await tester.tapAt(at(gx, gy));
      await tester.pump();
    }

    await put('supply:L1', 5, 4); // L1, pin at (5, 5)
    await put('supply:N', 5, 21); // N, pin at (5, 22)
    await put('push_no', 5, 9); // pins (5, 7) and (5, 11)
    await put('coil', 5, 15); // pins (5, 13) and (5, 17)
    for (final (a, b) in const [((5.0, 5.0), (5.0, 7.0)), ((5.0, 11.0), (5.0, 13.0)), ((5.0, 17.0), (5.0, 22.0))]) {
      await tester.tapAt(at(a.$1, a.$2));
      await tester.pump();
      await tester.tapAt(at(b.$1, b.$2));
      await tester.pump();
    }
    expect(find.text('4 simbol, 3 kabel'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('relay-simulate')));
    await tester.pump();
    expect(find.text('KM1  off'), findsOneWidget);
    final press = await tester.startGesture(at(5, 9));
    await tester.pump();
    expect(find.text('KM1  ON'), findsOneWidget, reason: 'held down, the button feeds the coil');
    await press.up();
    await tester.pump();
    expect(find.text('KM1  off'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('relay-simulate')));
    await tester.pump();
  });
}
