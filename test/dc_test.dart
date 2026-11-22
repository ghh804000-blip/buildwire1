import 'dart:convert';
import 'dart:io';

import 'package:buildwire/model/device_def.dart';
import 'package:buildwire/model/project.dart';
import 'package:buildwire/sim/plc.dart';
import 'package:buildwire/sim/solver.dart';
import 'package:buildwire/templates.dart';
import 'package:flutter_test/flutter_test.dart';

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

  PlacedDevice device(int id) => project.devices.firstWhere((d) => d.id == id);

  void wire(int a, String at, int b, String bt) => project.wires.add(Wire(id: _next++, a: TerminalRef(a, at), b: TerminalRef(b, bt)));
}

void main() {
  final defs = loadDefs();
  final sim = Solver(defs);

  SimResult solve(Circuit c, [Map<int, String> set = const {}]) => sim.solve(c.project, sim.initialStates(c.project)..addAll(set));

  /// A 230 V source feeding one AC to DC supply per voltage. Returns the supplies by voltage.
  Map<int, int> supplies(Circuit c, List<int> volts) {
    final mains = c.add('generic_source_ac');
    final result = <int, int>{};
    for (final v in volts) {
      final psu = c.add('power_supply_100_minus_240vac_${v}vdc_5a');
      c.wire(mains, 'L', psu, 'L');
      c.wire(mains, 'N', psu, 'N');
      result[v] = psu;
    }
    return result;
  }

  test('12, 24 and 48 V supplies each give their own voltage, and a 24 V DC relay pulls in only where it should', () {
    final c = Circuit();
    final psus = supplies(c, [12, 24, 48]);
    final relays = <int, int>{};
    for (final entry in psus.entries) {
      final k = c.add('schneider_rxm4ab2bd');
      c.wire(entry.value, 'DC+1', k, 'A1');
      c.wire(entry.value, 'DC-1', k, 'A2');
      relays[entry.key] = k;
    }
    final result = solve(c);
    expect(result.fault, SimFault.none);
    expect(result.at(TerminalRef(psus[12]!, 'DC+1')), 'DC+12');
    expect(result.at(TerminalRef(psus[48]!, 'DC+2')), 'DC+48');
    expect(result.at(TerminalRef(psus[24]!, 'DC-1')), 'DC-');
    expect(result.states[relays[12]], 'open', reason: '12 V is too little for a 24 V coil');
    expect(result.states[relays[24]], 'closed');
    expect(result.states[relays[48]], 'closed');
    expect(result.warnings.where((w) => w.deviceId == relays[48] && w.code == WarningCode.overvoltage), isNotEmpty);
    expect(result.warnings.where((w) => w.deviceId == relays[12] && w.code == WarningCode.undervoltage), isNotEmpty);
  });

  test('supplies may share their negative, but tying +12 V to +24 V is a short', () {
    final c = Circuit();
    final psus = supplies(c, [12, 24]);
    c.wire(psus[12]!, 'DC-1', psus[24]!, 'DC-1');
    expect(solve(c).fault, SimFault.none, reason: 'a common 0 V is normal');
    c.wire(psus[12]!, 'DC+1', psus[24]!, 'DC+1');
    expect(solve(c).fault, isNot(SimFault.none));
  });

  test('a load between +24 V and +12 V sees 12 V', () {
    final c = Circuit();
    final psus = supplies(c, [12, 24]);
    final lamp = c.add('piloto_led_verde_24vdc');
    c.wire(psus[24]!, 'DC+1', lamp, 'X1');
    c.wire(lamp, 'X2', psus[12]!, 'DC+1');
    expect(solve(c).measures[lamp]!.volts, closeTo(12, 0.01));
  });

  test('a DC motor turns the way its polarity says, at a speed set by its voltage, and stops when starved', () {
    final c = Circuit();
    final g = c.add('generic_source_dc_adjustable'), m = c.add('generic_motor_dc');
    c.wire(g, '+', m, 'A1');
    c.wire(g, '-', m, 'A2');
    var result = solve(c);
    expect(result.states[m], 'run_fwd');
    expect(result.measures[m]!.volts, closeTo(24, 0.01));
    expect(result.measures[m]!.amps, closeTo(60 / 24, 0.05), reason: '60 W at 24 V');
    c.device(g).data['voltage'] = 12.0;
    result = solve(c);
    expect(result.states[m], 'run_fwd');
    expect(result.measures[m]!.volts, closeTo(12, 0.01));
    c.device(g).data['voltage'] = 3.0;
    expect(solve(c).states[m], 'stopped', reason: 'below a quarter of its rating it cannot turn');
    c.device(g).data['voltage'] = 24.0;
    c.project.wires.clear();
    c.wire(g, '+', m, 'A2');
    c.wire(g, '-', m, 'A1');
    expect(solve(c).states[m], 'run_rev', reason: 'swapping the leads reverses it');
  });

  test('a supply turned down to 0 V gives nothing at all', () {
    final c = Circuit();
    final g = c.add('generic_source_dc_adjustable'), m = c.add('generic_motor_dc');
    c.wire(g, '+', m, 'A1');
    c.wire(g, '-', m, 'A2');
    c.device(g).data['voltage'] = 0.0;
    final result = solve(c);
    expect(result.states[m], 'stopped');
    expect(result.fault, SimFault.none);
  });

  test('AC on a DC motor warns and harms it', () {
    final c = Circuit();
    final g = c.add('generic_source_ac'), m = c.add('generic_motor_dc');
    c.wire(g, 'L', m, 'A1');
    c.wire(g, 'N', m, 'A2');
    final result = solve(c);
    expect(result.states[m], 'stopped');
    expect(result.warnings.where((w) => w.code == WarningCode.wrongSupply), isNotEmpty);
    expect(result.stress[m], isNotNull);
  });

  test('a 24 V AC/DC relay now works on DC', () {
    final c = Circuit();
    final g = c.add('generic_source_dc24'), k = c.add('schneider_harmony_relay_rsl1pvbu');
    c.wire(g, '+', k, 'A1');
    c.wire(g, '-', k, 'A2');
    expect(solve(c).states[k], 'closed');
  });

  test('a PNP proximity sensor switches its output to + only with a target in front and power on BN-BU', () {
    final c = Circuit();
    final g = c.add('generic_source_dc24'), s = c.add('sensor_de_proximidad_inductivo_3_hilos_dc'), lamp = c.add('piloto_led_verde_24vdc');
    c.wire(g, '+', s, 'BN');
    c.wire(s, 'BK', lamp, 'X1');
    c.wire(lamp, 'X2', g, '-');
    var result = solve(c, {s: 'target'});
    expect(result.states[s], 'target', reason: 'BU is loose, so the sensor is off');
    expect(result.states[lamp], 'off');
    c.wire(s, 'BU', g, '-');
    result = solve(c);
    expect(result.states[s], 'idle');
    expect(result.states[lamp], 'off');
    result = solve(c, {s: 'target'});
    expect(result.states[s], 'on', reason: 'powered and a target: detected');
    expect(result.states[lamp], 'on');
    expect(result.fault, SimFault.none, reason: 'the old data shorted BN to BU through BK');
  });

  test('a 24 V DC LOGO reads inputs against M and switches 24 V loads', () {
    final c = Circuit();
    final g = c.add('generic_source_dc24'), plc = c.add('logo_24rce'), lamp = c.add('piloto_led_verde_24vdc');
    c.wire(g, '+', plc, 'L');
    c.wire(g, '-', plc, 'N');
    c.wire(g, '+', plc, 'I1');
    c.wire(g, '+', plc, 'Q1.1');
    c.wire(plc, 'Q1.2', lamp, 'X1');
    c.wire(lamp, 'X2', g, '-');
    c.device(plc).data['program'] = [
      {
        'branches': [
          [
            {'ref': 'I1'},
          ],
        ],
        'coil': 'Q1',
      },
    ];
    final result = solve(c);
    expect(plcBits(result.states[plc]), containsAll(['I1', 'Q1']));
    expect(result.states[lamp], 'on');
  });

  test('the 230 V LOGO still reads inputs at 100 V against N', () {
    final c = Circuit();
    final g = c.add('generic_source_ac'), plc = c.add('logo_230rce');
    c.wire(g, 'L', plc, 'L');
    c.wire(g, 'N', plc, 'N');
    c.wire(g, 'L', plc, 'I2');
    expect(plcBits(solve(c).states[plc]), contains('I2'));
  });

  /// Operates a template by tag, keeping the solved states like the app does.
  Map<int, String> run(Project project, Map<int, String> states, String tag, String state) {
    final id = project.devices.firstWhere((d) => d.tag == tag).id;
    return sim.solve(project, Map.of(states)..[id] = state).states;
  }

  Map<int, String> tap(Project project, Map<int, String> states, String tag) =>
      run(project, run(project, states, tag, 'on'), tag, 'off');

  String state(Project project, Map<int, String> states, String tag) => states[project.devices.firstWhere((d) => d.tag == tag).id]!;

  test('the 24 V DC control template starts a 230 V contactor through its relay, and stops on S0', () {
    final project = kTemplates.firstWhere((t) => t.id == 'dc_control').build();
    var states = sim.solve(project, sim.initialStates(project)).states;
    states = run(project, states, 'QF1', 'on');
    states = run(project, states, 'F2', 'on');
    expect(state(project, states, 'U1'), 'on', reason: 'the 24 V supply is fed from F2');
    expect(state(project, states, 'K1'), 'open');
    states = tap(project, states, 'S1');
    expect(state(project, states, 'K1'), 'closed', reason: 'held in by its own contact');
    expect(state(project, states, 'KM1'), 'closed');
    expect(state(project, states, 'M1'), 'run_fwd');
    expect(state(project, states, 'H1'), 'on');
    final result = sim.solve(project, states);
    expect(result.fault, SimFault.none);
    expect(result.warnings, isEmpty);
    final s1 = project.devices.firstWhere((d) => d.tag == 'S1').id;
    expect(result.at(TerminalRef(s1, '3')), 'DC+24', reason: 'the buttons carry only 24 V DC');
    states = tap(project, states, 'S0');
    expect(state(project, states, 'KM1'), 'open');
    expect(state(project, states, 'M1'), 'stopped');
  });

  test('the DC motor template runs forward, refuses reverse while forward, reverses after stop, and follows the voltage', () {
    final project = kTemplates.firstWhere((t) => t.id == 'dc_motor').build();
    var states = sim.solve(project, sim.initialStates(project)).states;
    expect(state(project, states, 'M1'), 'stopped');
    states = tap(project, states, 'S1');
    expect(state(project, states, 'M1'), 'run_fwd');
    expect(state(project, states, 'H1'), 'on');
    expect(state(project, states, 'H2'), 'off');
    states = tap(project, states, 'S2');
    expect(state(project, states, 'M1'), 'run_fwd', reason: 'interlocked');
    expect(state(project, states, 'K2'), 'open');
    states = tap(project, states, 'S0');
    expect(state(project, states, 'M1'), 'stopped');
    states = tap(project, states, 'S2');
    expect(state(project, states, 'M1'), 'run_rev');
    expect(state(project, states, 'H2'), 'on');
    expect(state(project, states, 'H1'), 'off');
    expect(sim.solve(project, states).fault, SimFault.none);
    final g1 = project.devices.firstWhere((d) => d.tag == 'G1');
    final m1 = project.devices.firstWhere((d) => d.tag == 'M1').id;
    g1.data['voltage'] = 12.0;
    final slower = sim.solve(project, states);
    expect(slower.states[m1], 'run_rev', reason: 'the relays run from their own 24 V supply');
    expect(slower.measures[m1]!.volts, closeTo(12, 0.01));
  });
}
