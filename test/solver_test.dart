import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:buildwire/model/device_def.dart';
import 'package:buildwire/model/project.dart';
import 'package:buildwire/sim/plc.dart';
import 'package:buildwire/sim/solver.dart';
import 'package:buildwire/templates.dart';

Map<String, DeviceDef> loadDefs() {
  final list = jsonDecode(File('assets/devices/index.json').readAsStringSync()) as List<dynamic>;
  return {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
}

class Circuit {
  final project = Project();
  var _next = 1;

  int add(String defId) {
    final id = _next++;
    project.devices.add(PlacedDevice(id: id, defId: defId, tag: '$defId$id', x: 0, y: 0));
    return id;
  }

  void wire(int a, String at, int b, String bt) => project.wires.add(Wire(id: _next++, a: TerminalRef(a, at), b: TerminalRef(b, bt)));
}

/// Operates a template by tag, keeping the solved states like the app does.
class Run {
  Run(this.sim, this.project) {
    states = sim.solve(project, sim.initialStates(project)).states;
  }

  final Solver sim;
  final Project project;
  late Map<int, String> states;
  late SimResult last;

  int id(String tag) => project.devices.firstWhere((d) => d.tag == tag).id;
  String state(String tag) => states[id(tag)]!;

  void set(String tag, String state) {
    states[id(tag)] = state;
    last = sim.solve(project, states);
    states = last.states;
  }

  /// Presses and releases a hold-to-operate button.
  void tap(String tag) {
    set(tag, 'on');
    set(tag, 'off');
  }
}

void main() {
  final defs = loadDefs();
  final sim = Solver(defs);

  test('meter displays fit on their device and analog faces exist', () {
    for (final def in defs.values) {
      for (final screen in def.meterScreens) {
        final rect = (screen['rect'] as List<dynamic>).cast<num>();
        expect(rect[0] >= 0 && rect[1] >= 0 && rect[0] + rect[2] <= 1 && rect[1] + rect[3] <= 1, isTrue, reason: def.id);
      }
      final ids = {for (final t in def.terminals) t.id};
      for (final pair in def.meterChannels) {
        expect(ids, containsAll(pair.split('-')), reason: def.id);
      }
      final face = (def.meter?['gauge'] as Map<String, dynamic>?)?['face'] as String?;
      if (face != null) expect(File('assets/devices/$face').existsSync(), isTrue, reason: def.id);
    }
  });

  test('a three-phase multimeter shows each line-to-line voltage', () {
    final c = Circuit();
    final g = c.add('generic_source_ac3'), m = c.add('tense_em06');
    for (final t in ['L1', 'L2', 'L3', 'N']) {
      c.wire(g, t, m, t);
    }
    final result = sim.solve(c.project, sim.initialStates(c.project));
    final lines = result.channels[m]!;
    for (final pair in ['L1-L2', 'L2-L3', 'L3-L1']) {
      expect(lines[pair], closeTo(400, 25), reason: pair);
    }
    expect(result.measures[m]!.volts, closeTo(230, 10));
  });

  test('catalog data is consistent', () {
    expect(defs.length, greaterThan(300));
    expect(defs.values.where((d) => !d.isSymbol).length, greaterThanOrEqualTo(40));
    for (final def in defs.values) {
      final ids = {for (final t in def.terminals) t.id};
      for (final contact in def.contacts) {
        expect(ids, containsAll([contact.a, contact.b]), reason: def.id);
        for (final state in contact.closedIn) {
          expect(def.states, contains(state), reason: def.id);
        }
      }
      expect(def.states, contains(def.defaultState), reason: def.id);
      for (final state in def.states) {
        expect(File(def.assetFor(state)).existsSync(), isTrue, reason: def.assetFor(state));
      }
    }
  });

  group('supply and loads', () {
    test('lamp lights line to neutral and stays off with one side open', () {
      final c = Circuit();
      final g = c.add('generic_source_ac'), l = c.add('piloto_led_verde');
      c.wire(g, 'L', l, 'X1');
      expect(sim.solve(c.project, sim.initialStates(c.project)).states[l], 'off');
      c.wire(l, 'X2', g, 'N');
      final result = sim.solve(c.project, sim.initialStates(c.project));
      expect(result.states[l], 'on');
      expect(result.at(TerminalRef(l, 'X1')), 'L1');
      expect(result.at(TerminalRef(l, 'X2')), 'N');
    });

    test('a 230 V lamp across two phases lights and warns of overvoltage', () {
      final c = Circuit();
      final g = c.add('generic_source_ac3'), l = c.add('piloto_led_rojo');
      c.wire(g, 'L1', l, 'X1');
      c.wire(g, 'L2', l, 'X2');
      final result = sim.solve(c.project, sim.initialStates(c.project));
      expect(result.states[l], 'on');
      expect(result.warnings.single.code, WarningCode.overvoltage);
    });

    test('a 230 V AC coil on 24 V DC does not pull in and warns', () {
      final c = Circuit();
      final g = c.add('generic_source_dc24'), k = c.add('chint_nxc32');
      c.wire(g, '+', k, 'A1');
      c.wire(g, '-', k, 'A2');
      final result = sim.solve(c.project, sim.initialStates(c.project));
      expect(result.states[k], 'open');
      expect(result.warnings.single.code, WarningCode.wrongSupply);
    });

    test('voltmeter reads phase, line and DC voltages', () {
      num read(String source, String a, String b) {
        final c = Circuit();
        final g = c.add(source), v = c.add('oumik_m72_voltmeter');
        c.wire(g, a, v, 'IN1');
        c.wire(g, b, v, 'IN2');
        return sim.solve(c.project, sim.initialStates(c.project)).readings[v]!.volts;
      }

      expect(read('generic_source_ac3', 'L1', 'N'), 230);
      expect(read('generic_source_ac3', 'L1', 'L3'), 400);
      expect(read('generic_source_dc24', '+', '-'), 24);
    });

    test('terminal blocks and busbars conduct, and jumpers count as connections', () {
      final c = Circuit();
      final g = c.add('generic_source_ac'), x = c.add('borne_gris'), bar = c.add('barra_de_neutro_n_minus_6t_a'), l = c.add('piloto_led_verde');
      c.wire(g, 'L', x, '1');
      c.project.wires.add(Wire(id: 90, a: TerminalRef(x, '2'), b: TerminalRef(l, 'X1'), isJumper: true));
      c.wire(g, 'N', bar, 'N');
      c.wire(bar, 'N1', l, 'X2');
      expect(sim.solve(c.project, sim.initialStates(c.project)).states[l], 'on');
    });

    test('symbols do not conduct or take part', () {
      final symbol = defs.values.firstWhere((d) => d.isSymbol && d.terminals.length >= 2);
      final c = Circuit();
      final g = c.add('generic_source_ac'), s = c.add(symbol.id), l = c.add('piloto_led_verde');
      c.wire(g, 'L', s, symbol.terminals[0].id);
      c.wire(s, symbol.terminals[1].id, l, 'X1');
      c.wire(l, 'X2', g, 'N');
      expect(sim.solve(c.project, sim.initialStates(c.project)).states[l], 'off');
    });
  });

  group('damage', () {
    /// A part fed from the adjustable source between L and N.
    (Circuit, int, int) adjustable(String part, String a, String b, {double volts = 230, double hertz = 50}) {
      final c = Circuit();
      final g = c.add('generic_source_adjustable'), p = c.add(part);
      c.project.devices.first.data['voltage'] = volts;
      c.project.devices.first.data['frequency'] = hertz;
      c.wire(g, 'L', p, a);
      c.wire(p, b, g, 'N');
      return (c, g, p);
    }

    test('parts at their rating are not stressed', () {
      final (c, _, l) = adjustable('piloto_led_verde', 'X1', 'X2');
      expect(sim.solve(c.project, sim.initialStates(c.project)).stress[l], isNull);
      final (k, _, coil) = adjustable('chint_nxc32', 'A1', 'A2', volts: 250, hertz: 60);
      expect(sim.solve(k.project, sim.initialStates(k.project)).stress[coil], isNull);
    });

    test('400 V on a 230 V lamp destroys it almost at once', () {
      final c = Circuit();
      final g = c.add('generic_source_ac3'), l = c.add('piloto_led_rojo');
      c.wire(g, 'L1', l, 'X1');
      c.wire(g, 'L2', l, 'X2');
      final stress = sim.solve(c.project, sim.initialStates(c.project)).stress[l]!;
      expect(stress.cause, DamageCause.overvoltage);
      expect(stress.seconds, lessThan(0.5));
    });

    test('more overvoltage fails faster, and up to 15% is tolerated', () {
      double? secondsAt(double volts) {
        final (c, _, l) = adjustable('piloto_led_verde', 'X1', 'X2', volts: volts);
        return sim.solve(c.project, sim.initialStates(c.project)).stress[l]?.seconds;
      }

      expect(secondsAt(260), isNull);
      expect(secondsAt(280)!, greaterThan(secondsAt(330)!));
    });

    test('100 Hz cooks a contactor coil but a lamp does not care', () {
      final (c, _, coil) = adjustable('chint_nxc32', 'A1', 'A2', hertz: 100);
      final result = sim.solve(c.project, sim.initialStates(c.project));
      expect(result.stress[coil]!.cause, DamageCause.highFrequency);
      expect(result.warnings.map((w) => w.code), contains(WarningCode.wrongFrequency));
      final (l, _, lamp) = adjustable('piloto_led_verde', 'X1', 'X2', hertz: 100);
      expect(sim.solve(l.project, sim.initialStates(l.project)).stress[lamp], isNull);
    });

    test('low frequency overheats a coil, faster the lower it goes', () {
      double secondsAt(double hertz) {
        final (c, _, coil) = adjustable('chint_nxc32', 'A1', 'A2', hertz: hertz);
        final stress = sim.solve(c.project, sim.initialStates(c.project)).stress[coil]!;
        expect(stress.cause, DamageCause.lowFrequency);
        return stress.seconds;
      }

      expect(secondsAt(35), greaterThan(secondsAt(10)));
    });

    test('an exploded part stays exploded, conducts nothing and draws nothing', () {
      final (c, _, coil) = adjustable('chint_nxc32', 'A1', 'A2');
      final result = sim.solve(c.project, {...sim.initialStates(c.project), coil: kExploded});
      expect(result.states[coil], kExploded);
      expect(result.measures[coil]!.amps, 0);
      expect(result.stress[coil], isNull);
    });

    test('an unprotected short burns the source, and its explosion ends the short', () {
      final c = Circuit();
      final g = c.add('generic_source_ac');
      c.wire(g, 'L', g, 'N');
      final result = sim.solve(c.project, sim.initialStates(c.project));
      expect(result.stress[g]!.cause, DamageCause.shortCircuit);
      expect(sim.solve(c.project, {g: kExploded}).fault, SimFault.none);
    });

    test('a motor stalled on a missing phase burns unless something stops it', () {
      final c = Circuit();
      final g = c.add('generic_source_ac3'), m = c.add('motor_6_terminales');
      c.wire(g, 'L1', m, 'U1');
      c.wire(g, 'L2', m, 'V1');
      c.wire(m, 'U2', m, 'V2');
      c.wire(m, 'V2', m, 'W2');
      expect(sim.solve(c.project, sim.initialStates(c.project)).stress[m]!.cause, DamageCause.lockedRotor);
    });
  });

  group('short circuit', () {
    test('line to neutral trips a breaker that clears it', () {
      final c = Circuit();
      final g = c.add('generic_source_ac'), q = c.add('abb_s200_s201_1p');
      c.wire(g, 'L', q, '1');
      c.wire(q, '2', g, 'N');
      final result = sim.solve(c.project, {...sim.initialStates(c.project), q: 'on'});
      expect(result.fault, SimFault.shortCircuitTripped);
      expect(result.states[q], 'tripped');
    });

    test('phase to phase and line to earth also count as shorts', () {
      final c = Circuit();
      final g = c.add('generic_source_ac3');
      c.wire(g, 'L1', g, 'L2');
      expect(sim.solve(c.project, sim.initialStates(c.project)).fault, SimFault.shortCircuitUnprotected);
      final e = Circuit();
      final h = e.add('generic_source_ac3');
      e.wire(h, 'L1', h, 'PE');
      expect(sim.solve(e.project, sim.initialStates(e.project)).fault, SimFault.shortCircuitUnprotected);
    });

    test('neutral bonded to earth is not a short', () {
      final c = Circuit();
      final g = c.add('generic_source_ac3');
      c.wire(g, 'N', g, 'PE');
      expect(sim.solve(c.project, sim.initialStates(c.project)).fault, SimFault.none);
    });
  });

  group('motor', () {
    Circuit wiredMotor(List<String> order, {bool jumpers = true}) {
      final c = Circuit();
      final g = c.add('generic_source_ac3'), m = c.add('motor_6_terminales');
      c.wire(g, order[0], m, 'U1');
      c.wire(g, order[1], m, 'V1');
      c.wire(g, order[2], m, 'W1');
      c.wire(g, 'PE', m, 'PE');
      if (jumpers) {
        c.wire(m, 'U2', m, 'V2');
        c.wire(m, 'V2', m, 'W2');
      }
      return c;
    }

    test('phase order sets rotation', () {
      final fwd = wiredMotor(['L1', 'L2', 'L3']);
      expect(sim.solve(fwd.project, sim.initialStates(fwd.project)).states[2], 'run_fwd');
      final rev = wiredMotor(['L1', 'L3', 'L2']);
      expect(sim.solve(rev.project, sim.initialStates(rev.project)).states[2], 'run_rev');
    });

    test('a motor without star or delta jumpers does not run and warns', () {
      final c = wiredMotor(['L1', 'L2', 'L3'], jumpers: false);
      final result = sim.solve(c.project, sim.initialStates(c.project));
      expect(result.states[2], 'stopped');
      expect(result.warnings.single.code, WarningCode.motorUnconnected);
    });

    test('a missing phase stops the motor and warns of single phasing', () {
      final c = Circuit();
      final g = c.add('generic_source_ac3'), m = c.add('motor_6_terminales');
      c.wire(g, 'L1', m, 'U1');
      c.wire(g, 'L2', m, 'V1');
      c.wire(m, 'U2', m, 'V2');
      c.wire(m, 'V2', m, 'W2');
      final result = sim.solve(c.project, sim.initialStates(c.project));
      expect(result.states[m], 'stopped');
      expect(result.warnings.single.code, WarningCode.singlePhasing);
    });
  });

  group('timers', () {
    test('on-delay waits in timing while powered and resets when power goes', () {
      final c = Circuit();
      final g = c.add('generic_source_ac'), t = c.add('chint_jss48a');
      c.wire(g, 'L', t, 'A1');
      c.wire(t, 'A2', g, 'N');
      final first = sim.solve(c.project, sim.initialStates(c.project));
      expect(first.states[t], 'timing');
      expect(sim.solve(c.project, {...first.states, t: 'closed'}).states[t], 'closed');
      c.project.wires.clear();
      expect(sim.solve(c.project, {g: 'on', t: 'closed'}).states[t], 'open');
    });
  });

  group('templates', () {
    test('every template refers only to existing terminals', () {
      for (final template in kTemplates) {
        final project = template.build();
        for (final wire in project.wires) {
          for (final ref in [wire.a, wire.b]) {
            final device = project.devices.firstWhere((d) => d.id == ref.deviceId);
            expect(defs[device.defId]!.terminals.map((t) => t.id), contains(ref.terminal), reason: '${template.id} ${device.tag} ${ref.terminal}');
          }
        }
      }
    });

    test('lamp example', () {
      final run = Run(sim, buildLampExample());
      run.set('QF1', 'on');
      expect(run.state('HL1'), 'off');
      run.set('S1', 'on');
      expect(run.state('KM1'), 'closed');
      expect(run.state('HL1'), 'on');
      run.set('S1', 'off');
      expect(run.state('HL1'), 'off');
    });

    test('DOL self-holds, stops, and drops out on overload', () {
      final run = Run(sim, buildDol());
      run.set('QF1', 'on');
      run.set('F2', 'on');
      expect(run.state('M1'), 'stopped');
      run.tap('S1');
      expect(run.state('KM1'), 'closed');
      expect(run.state('M1'), 'run_fwd');
      expect(run.state('HL1'), 'on');
      expect(run.last.warnings, isEmpty);
      run.tap('S0');
      expect(run.state('KM1'), 'open');
      expect(run.state('M1'), 'stopped');
      run.tap('S1');
      expect(run.state('M1'), 'run_fwd');
      run.set('F1', 'tripped');
      expect(run.state('KM1'), 'open');
      expect(run.state('M1'), 'stopped');
      run.tap('S1');
      expect(run.state('KM1'), 'open');
    });

    test('reversing runs both ways and the interlock blocks the other direction', () {
      final run = Run(sim, buildReversing());
      run.set('QF1', 'on');
      run.set('F2', 'on');
      run.tap('S1');
      expect(run.state('KM1'), 'closed');
      expect(run.state('M1'), 'run_fwd');
      run.tap('S2');
      expect(run.state('KM2'), 'open');
      expect(run.state('M1'), 'run_fwd');
      run.tap('S0');
      expect(run.state('M1'), 'stopped');
      run.tap('S2');
      expect(run.state('KM2'), 'closed');
      expect(run.state('M1'), 'run_rev');
      expect(run.last.fault, SimFault.none);
    });

    test('star-delta starts in star, then moves to delta when the timer ends', () {
      final run = Run(sim, buildStarDelta());
      run.set('QF1', 'on');
      run.set('F2', 'on');
      run.tap('S1');
      expect(run.state('KM1'), 'closed');
      expect(run.state('KT1'), 'timing');
      expect(run.state('KM3'), 'closed');
      expect(run.state('KM2'), 'open');
      expect(run.state('M1'), 'run_fwd');
      run.set('KT1', 'closed');
      expect(run.state('KM3'), 'open');
      expect(run.state('KM2'), 'closed');
      expect(run.state('M1'), 'run_fwd');
      expect(run.last.fault, SimFault.none);
      run.tap('S0');
      expect(run.state('M1'), 'stopped');
      expect(run.state('KT1'), 'open');
    });
  });

  group('current and power', () {
    test('a lamp draws its current through its breaker', () {
      final run = Run(sim, buildMeterBench());
      run.set('QF1', 'on');
      final lamp = run.last.measures[run.id('E1')]!;
      expect(lamp.volts, 230);
      expect(lamp.watts, greaterThan(0));
      expect(lamp.amps, closeTo(lamp.watts / 230, 0.001));
      expect(run.last.measures[run.id('QF1')]!.amps, closeTo(lamp.amps, 0.001));
    });

    test('the voltmeter and frequency meter read the supply', () {
      final run = Run(sim, buildMeterBench());
      run.set('QF1', 'on');
      expect(run.last.readings[run.id('PV1')]!.volts, 230);
      expect(run.last.measures[run.id('PF1')]!.hertz, 50);
    });

    test('the source supplies the load current and power, and a breaker shows its voltage', () {
      final run = Run(sim, buildMeterBench());
      run.set('QF1', 'on');
      final lamp = run.last.measures[run.id('E1')]!;
      final source = run.last.measures[run.id('PS1')]!;
      expect(source.amps, closeTo(lamp.amps, 0.001));
      expect(source.watts, closeTo(lamp.watts, 0.01));
      expect(run.last.measures[run.id('QF1')]!.volts, 230);
    });

    test('coils and electronics draw current, and a motor shows its line voltage', () {
      final run = Run(sim, buildDol());
      run.set('QF1', 'on');
      run.set('F2', 'on');
      expect(run.last.measures[run.id('F2')]!.amps, 0);
      run.tap('S1');
      final coil = run.last.measures[run.id('KM1')]!.amps;
      expect(coil, greaterThan(0));
      expect(run.last.measures[run.id('F2')]!.amps, greaterThanOrEqualTo(coil));
      expect(run.last.measures[run.id('M1')]!.volts, 400);

      final plc = Run(sim, buildPlc());
      plc.set('QF1', 'on');
      plc.set('F2', 'on');
      expect(plc.last.measures[plc.id('PLC1')]!.amps, greaterThan(0));
    });

    test('lowering an adjustable supply lowers voltage, current and power, and changes frequency', () {
      final full = Run(sim, buildMeterBench())..set('QF1', 'on');
      final fullWatts = full.last.measures[full.id('E1')]!.watts;
      final project = buildMeterBench();
      final supply = project.devices.firstWhere((d) => d.tag == 'PS1');
      supply.data['voltage'] = 115.0;
      supply.data['frequency'] = 60.0;
      final run = Run(sim, project);
      run.set('QF1', 'on');
      final lamp = run.last.measures[run.id('E1')]!;
      expect(lamp.volts, 115);
      expect(lamp.watts, closeTo(fullWatts / 4, 0.01));
      expect(run.last.measures[run.id('PF1')]!.hertz, 60);
    });

    test('a pole-to-pole path counts once per pole in a two-pole breaker', () {
      final c = Circuit();
      final g = c.add('generic_source_ac'), q = c.add('chint_nxb63h_2p'), h = c.add('foco_led');
      c.wire(g, 'L', q, '1');
      c.wire(g, 'N', q, '3');
      c.wire(q, '2', h, 'F');
      c.wire(q, '4', h, 'N');
      final result = sim.solve(c.project, {...sim.initialStates(c.project), q: 'on'});
      expect(result.measures[h]!.amps, greaterThan(0));
      expect(result.measures[q]!.amps, closeTo(result.measures[h]!.amps, 0.001));
    });

    test('a running motor loads its contactor, star draws a third of delta, and single phasing draws far more', () {
      final run = Run(sim, buildDol());
      run.set('QF1', 'on');
      run.set('F2', 'on');
      run.tap('S1');
      final amps = run.last.measures[run.id('F1')]!.amps;
      expect(amps, closeTo(4.4, 0.1));

      final star = Run(sim, buildStarDelta());
      star.set('QF1', 'on');
      star.set('F2', 'on');
      star.tap('S1');
      final starAmps = star.last.measures[star.id('M1')]!.amps;
      star.set('KT1', 'closed');
      expect(star.last.measures[star.id('M1')]!.amps, closeTo(starAmps * 3, 0.01));

      final c = Circuit();
      final g = c.add('generic_source_ac3'), m = c.add('motor_6_terminales');
      c.wire(g, 'L1', m, 'U1');
      c.wire(g, 'L2', m, 'V1');
      c.wire(m, 'U2', m, 'V2');
      c.wire(m, 'V2', m, 'W2');
      final stalled = sim.solve(c.project, sim.initialStates(c.project));
      expect(stalled.measures[m]!.amps, greaterThan(amps * 5));
    });
  });

  group('PSU', () {
    test('24 V appears only while the input is powered', () {
      final c = Circuit();
      final g = c.add('generic_source_ac'), q = c.add('schneider_ic60n_1p_c10');
      final p = c.add('power_supply_100_minus_240vac_24vdc_5a'), v = c.add('oumik_m72_voltmeter');
      c.wire(g, 'L', q, '1');
      c.wire(q, '2', p, 'L');
      c.wire(g, 'N', p, 'N');
      c.wire(p, 'DC+1', v, 'IN1');
      c.wire(p, 'DC-1', v, 'IN2');
      expect(sim.solve(c.project, sim.initialStates(c.project)).readings[v]?.volts ?? 0, 0);
      expect(sim.solve(c.project, {...sim.initialStates(c.project), q: 'on'}).readings[v]!.volts, 24);
    });
  });

  group('PLC', () {
    test('is off without power and runs its program with it', () {
      final run = Run(sim, buildPlc());
      expect(run.state('PLC1'), 'off');
      run.set('QF1', 'on');
      expect(run.state('PLC1'), 'off');
      run.set('F2', 'on');
      expect(run.state('PLC1'), startsWith('run'));
      expect(run.state('M1'), 'stopped');
    });

    test('a hardwired button starts the motor, the program self-holds, and stop works', () {
      final run = Run(sim, buildPlc());
      run.set('QF1', 'on');
      run.set('F2', 'on');
      run.tap('S1');
      expect(plcBits(run.state('PLC1')), contains('Q1'));
      expect(run.state('KM1'), 'closed');
      expect(run.state('M1'), 'run_fwd');
      run.tap('S2');
      expect(plcBits(run.state('PLC1')), isNot(contains('Q1')));
      expect(run.state('M1'), 'stopped');
    });

    test('an overload trip reaches the fault input and drops the motor', () {
      final run = Run(sim, buildPlc());
      run.set('QF1', 'on');
      run.set('F2', 'on');
      run.tap('S1');
      expect(run.state('M1'), 'run_fwd');
      run.set('F1', 'tripped');
      expect(plcBits(run.state('PLC1')), contains('I3'));
      expect(run.state('KM1'), 'open');
      expect(run.state('M1'), 'stopped');
    });

    test('scan: normally closed contacts, parallel branches, and timers', () {
      final rungs = [
        PlcRung(branches: [
          [const PlcContact('I1'), const PlcContact('I2', negated: true)],
          [const PlcContact('I3')],
        ], coil: 'Q1'),
        PlcRung(branches: [
          [const PlcContact('I4')],
        ], coil: 'T1', preset: 2),
        PlcRung(branches: [
          [const PlcContact('T1')],
        ], coil: 'Q2'),
      ];
      PlcScan scan(Set<String> inputs, {Set<String> done = const {}}) => plcScan(rungs, inputs: inputs, previous: const {}, external: const {}, timersDone: done);
      expect(scan({'I1'}).bits, contains('Q1'));
      expect(scan({'I1', 'I2'}).bits, isNot(contains('Q1')));
      expect(scan({'I2', 'I3'}).bits, contains('Q1'));
      expect(scan({'I4'}).timers['T1'], 2);
      expect(scan({'I4'}).bits, isNot(contains('Q2')));
      expect(scan({'I4'}, done: {'T1'}).bits, contains('Q2'));
      expect(scan({}, done: {'T1'}).bits, isNot(contains('Q2')));
    });
  });

  group('project file', () {
    test('survives a round trip with jumpers, route, gauge and timer', () {
      final project = buildStarDelta();
      project.wires.first
        ..points = [const WirePoint(10, 20), const WirePoint(10, 60)]
        ..number = '101';
      final copy = Project.fromJson(jsonDecode(jsonEncode(project.toJson())) as Map<String, dynamic>);
      expect(copy.devices.length, project.devices.length);
      expect(copy.wires.where((w) => w.isJumper).length, 2);
      expect(copy.wires.first.points!.last.y, 60);
      expect(copy.wires.first.number, '101');
      expect(copy.devices.firstWhere((d) => d.tag == 'KT1').timeSeconds, 5);
    });

    test('rejects another app, a newer version, and damaged content', () {
      expect(() => Project.fromJson({'app': 'Lain'}), throwsFormatException);
      expect(() => Project.fromJson({'app': 'BuildWire', 'schemaVersion': 999}), throwsFormatException);
      expect(() => Project.fromJson({'app': 'BuildWire', 'schemaVersion': 1, 'devices': 'x'}), throwsFormatException);
    });
  });
}
