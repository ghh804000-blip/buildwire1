import 'dart:math' as math;

import '../model/device_def.dart';
import '../model/project.dart';
import 'ladder.dart';
import 'plc.dart';

enum SimFault { none, shortCircuitTripped, shortCircuitUnprotected, unstable }

enum WarningCode { overvoltage, wrongSupply, undervoltage, singlePhasing, motorUnconnected, motorNoEarth, wrongFrequency }

/// Why a device is being destroyed.
enum DamageCause { overvoltage, wrongSupply, lowFrequency, highFrequency, lockedRotor, shortCircuit }

/// A device pushed past its rating. Held there continuously, it fails and explodes after [seconds].
class Stress {
  const Stress(this.seconds, this.cause, {this.volts = 0, this.rated = 0, this.hertz = 0});

  final double seconds;
  final DamageCause cause;

  /// What the device saw, and what it is rated for, for the explanation shown to people.
  final double volts;
  final double rated;
  final double hertz;
}

/// The state of a device that has exploded. It conducts nothing and stays this way until the simulation restarts.
const String kExploded = 'exploded';

class SimWarning {
  const SimWarning(this.deviceId, this.code);

  final int deviceId;
  final WarningCode code;
}

/// A voltage between two nets.
class Reading {
  const Reading(this.volts, this.supply, [this.hertz = 0, double? signed]) : _signed = signed;

  static const zero = Reading(0, 'none');

  final num volts;
  final String supply;
  final double hertz;
  final double? _signed;

  /// For DC, the voltage of the first terminal minus the second: negative when the polarity is reversed.
  double get signed => _signed ?? volts.toDouble();
}

/// Whether a device rated for [rated] accepts this kind of supply: 'both' takes AC or DC.
bool supplyMatches(RatedPair rated, Reading reading) => rated.supply == 'both' || reading.supply == rated.supply;

/// The voltage a DC label stands for: "DC-" is 0 V, "DC+24" is 24 V. Null for anything that is not DC.
double? dcVoltsOf(String? label) {
  if (label == null) return null;
  if (label == 'DC-') return 0;
  if (label.startsWith('DC+')) return double.tryParse(label.substring(3)) ?? 24;
  return null;
}

/// The label for a DC supply's positive terminal at [volts].
String dcPlusLabel(double volts) {
  final rounded = (volts * 10).roundToDouble() / 10;
  return 'DC+${rounded == rounded.roundToDouble() ? rounded.round() : rounded}';
}

/// What a device sees at the moment.
class Measure {
  const Measure({this.volts = 0, this.amps = 0, this.watts = 0, this.hertz = 0});

  final double volts;
  final double amps;
  final double watts;
  final double hertz;
}

class SimResult {
  const SimResult({
    required this.states,
    required this.potentials,
    required this.fault,
    required this.warnings,
    required this.readings,
    required this.measures,
    required this.plcTimers,
    this.plcMemory = const {},
    required this.wireAmps,
    required this.starMotors,
    this.channels = const {},
    this.stress = const {},
    this.trippedDeviceId,
  });

  /// Devices running past their rating right now, keyed by device id.
  final Map<int, Stress> stress;

  /// Extra meter readings per device, keyed like "L1-L2": the voltage between two of its terminals.
  final Map<int, Map<String, double>> channels;

  /// Signed current per wire id, positive from the wire's end a to end b.
  final Map<int, double> wireAmps;

  /// Motors currently connected in star.
  final Set<int> starMotors;

  final Map<int, String> states;

  /// Keyed by [TerminalRef.key]: 'L1', 'L2', 'L3', 'N', 'PE', 'DC+', 'DC-' or 'short'. Missing means no potential.
  final Map<String, String> potentials;
  final SimFault fault;
  final List<SimWarning> warnings;
  final Map<int, Reading> readings;
  final Map<int, Measure> measures;

  /// Per PLC, the timer coils that are energized and their presets.
  final Map<int, Map<String, double>> plcTimers;

  /// What each running PLC remembers after this solution, for the app to keep until the next one.
  final Map<int, PlcMemory> plcMemory;
  final int? trippedDeviceId;

  String? at(TerminalRef ref) => potentials[ref.key];
}

/// External bits and finished timers for the PLCs in a project.
/// A PLC's real-time clock: the computer's time plus the offset set from its keypad (Set Clock).
DateTime plcClock(PlacedDevice plc, DateTime wall) => wall.add(Duration(seconds: (plc.data['rtc_offset_s'] as num?)?.round() ?? 0));

class PlcInputs {
  const PlcInputs({this.external = const {}, this.memory = const {}, this.now = 0, this.stopped = const {}, this.wall});

  /// The computer's local time; each PLC's real-time clock runs from it with its own offset (see [plcClock]).
  final DateTime? wall;

  /// Bits forced from outside the program: the PLC's arrow keys (Z1-Z4) and the inspector.
  final Map<int, Set<String>> external;

  /// What each PLC remembered after the last settled solution.
  final Map<int, PlcMemory> memory;

  /// Simulation time in seconds, for the timers.
  final double now;

  /// PLCs switched to STOP from their own keypad: powered, but the program does not run.
  final Set<int> stopped;
}

/// Steady-state solver at nominal voltage.
///
/// Wires, jumpers and closed contacts join terminals into nets, and sources label nets with a phase. Loads are
/// constant impedances, sized from their rated power. Current is added along the first path found from each load back
/// to its source, so this assumes a radial network: parallel paths are not shared, and voltage drop is not calculated.
class Solver {
  const Solver(this.defs);

  final Map<String, DeviceDef> defs;

  static const int _maxIterations = 40;

  Map<int, String> initialStates(Project project) => {
        for (final device in project.devices) device.id: defs[device.defId]!.defaultState,
      };

  SimResult solve(Project project, Map<int, String> input, {PlcInputs plc = const PlcInputs()}) {
    final states = Map<int, String>.of(input);
    final seen = <String>{};
    var fault = SimFault.none;
    int? tripped;

    for (var iteration = 0; iteration < _maxIterations; iteration++) {
      var nets = _Nets.build(project, defs, states);
      if (nets.hasShort) {
        final breaker = _findBreakerToTrip(project, states);
        if (breaker == null) return _finish(project, states, nets, SimFault.shortCircuitUnprotected, null, plc);
        states[breaker] = 'tripped';
        tripped ??= breaker;
        fault = SimFault.shortCircuitTripped;
        nets = _Nets.build(project, defs, states);
        if (nets.hasShort) continue;
      }

      var changed = false;
      for (final device in project.devices) {
        final def = defs[device.defId]!;
        final next = _nextState(device, def, states[device.id]!, nets, plc);
        if (next != states[device.id]) {
          states[device.id] = next;
          changed = true;
        }
      }
      if (!changed) return _finish(project, states, nets, fault, tripped, plc);

      final signature = (states.entries.map((e) => '${e.key}=${e.value}').toList()..sort()).join(',');
      if (!seen.add(signature)) {
        return _finish(project, states, _Nets.build(project, defs, states), SimFault.unstable, null, plc);
      }
    }
    return _finish(project, states, _Nets.build(project, defs, states), SimFault.unstable, null, plc);
  }

  LadderProgram programOf(PlacedDevice device) => LadderProgram.of(device.data);

  LadderScan _scan(PlacedDevice device, String state, _Nets nets, PlcInputs plc) {
    final def = defs[device.defId]!;
    final supply = def.input!;
    final dc = supply.supply == 'dc';
    // An input is on above half the supply voltage, measured against the supply's return (N, or M / - on DC).
    final inputs = <String>{
      for (final name in def.plcInputs)
        if (dc ? nets.voltage(device.id, name, supply.b).signed >= supply.volts * 0.5 : nets.voltage(device.id, name, supply.b).volts >= supply.volts * 0.43) name,
    };
    // Without remembered state (a caller solving step by step), the outputs and relays shown in the PLC's state carry
    // over, which is what keeps a self-holding rung on.
    final memory = plc.memory[device.id] ?? PlcMemory(bits: plcBits(state).where((b) => !inputs.contains(b) && !b.startsWith('I')).toSet());
    return scanLadder(programOf(device), inputs: inputs, external: plc.external[device.id] ?? const {}, memory: memory, now: plc.now, clock: plc.wall == null ? null : plcClock(device, plc.wall!));
  }

  String _nextState(PlacedDevice device, DeviceDef def, String state, _Nets nets, PlcInputs plc) {
    if (state == kExploded) return state;
    switch (def.kind) {
      case 'coil':
        return nets.ratedPowered(device.id, def.coil!) ? 'closed' : 'open';
      case 'timer_on':
        final powered = nets.ratedPowered(device.id, def.coil!);
        if (!powered) return 'open';
        return state == 'open' ? 'timing' : state;
      case 'timer_off':
        final powered = nets.ratedPowered(device.id, def.coil!);
        if (powered) return 'closed';
        return state == 'closed' ? 'timing_off' : state;
      case 'load':
        return nets.ratedPowered(device.id, def.load!, minRatio: def.minRatio) ? 'on' : 'off';
      case 'motor_dc':
        // Turns from a quarter of its rating up; the polarity sets the direction, the voltage its speed.
        final reading = nets.voltage(device.id, def.load!.a, def.load!.b);
        if (reading.supply != 'dc' || reading.volts < def.load!.volts * 0.25) return 'stopped';
        return reading.signed > 0 ? 'run_fwd' : 'run_rev';
      case 'sensor_pnp':
        // A target in front of it (set by clicking) switches BK to BN, but only while the sensor is powered.
        final hasTarget = state == 'target' || state == 'on';
        if (!hasTarget) return 'idle';
        final supply = nets.voltage(device.id, 'BN', 'BU');
        return supply.supply == 'dc' && supply.signed >= 10 ? 'on' : 'target';
      case 'motor3':
        return nets.motorState(device.id).state;
      case 'psu' || 'hmi':
        return nets.ratedPowered(device.id, def.input!) ? 'on' : 'off';
      case 'plc':
        if (!nets.ratedPowered(device.id, def.input!)) return 'off';
        if (plc.stopped.contains(device.id)) return 'stop';
        return plcState(_scan(device, state, nets, plc).bits);
      default:
        return state;
    }
  }

  /// Returns the first breaker that is on and whose opening clears the short. Upstream order follows placement.
  int? _findBreakerToTrip(Project project, Map<int, String> states) {
    for (final device in project.devices) {
      final def = defs[device.defId]!;
      if (!def.isProtective || states[device.id] != 'on') continue;
      final trial = Map<int, String>.of(states)..[device.id] = 'tripped';
      if (!_Nets.build(project, defs, trial).hasShort) return device.id;
    }
    return null;
  }

  /// The voltage to show for a device: across its rating for loads, line to line for a motor, line to neutral otherwise.
  Reading _deviceVoltage(PlacedDevice device, DeviceDef def, _Nets nets) {
    final rated = def.coil ?? def.load ?? def.input;
    if (rated != null) return nets.voltage(device.id, rated.a, rated.b);
    if (def.kind == 'motor3') return nets.voltage(device.id, 'U1', 'V1');
    for (final terminal in [...def.contacts.map((c) => c.a), ...def.outputs.keys]) {
      final reading = nets.toNeutral(device.id, terminal);
      if (reading.volts > 0) return reading;
    }
    return Reading.zero;
  }

  SimResult _finish(Project project, Map<int, String> states, _Nets nets, SimFault fault, int? tripped, PlcInputs plc) {
    final warnings = <SimWarning>[];
    final readings = <int, Reading>{};
    final channels = <int, Map<String, double>>{};
    final measures = <int, Measure>{};
    final timers = <int, Map<String, double>>{};
    final memory = <int, PlcMemory>{};
    final flow = _Flow(project, defs, states, nets);
    final stress = <int, Stress>{};
    void strain(int id, Stress? next) {
      if (next == null) return;
      final current = stress[id];
      if (current == null || next.seconds < current.seconds) stress[id] = next;
    }

    for (final device in project.devices) {
      final def = defs[device.defId]!;
      if (states[device.id] == kExploded) continue;
      // A source feeding a short with nothing to clear it burns up.
      if (fault == SimFault.shortCircuitUnprotected && (def.kind == 'source' || def.kind == 'psu')) {
        if (def.outputs.keys.any((t) => nets.labelOf(device.id, t) == 'short')) strain(device.id, const Stress(0.4, DamageCause.shortCircuit));
      }
      final rated = def.coil ?? def.load ?? def.input;
      if (rated != null) {
        final reading = nets.voltage(device.id, rated.a, rated.b);
        strain(device.id, damageFor(def, rated, reading));
        if (reading.supply == 'ac' && _frequencyClass(def) != null && (reading.hertz < 45 || reading.hertz > 65)) {
          warnings.add(SimWarning(device.id, WarningCode.wrongFrequency));
        }
        if (reading.volts > 0 && !supplyMatches(rated, reading)) {
          warnings.add(SimWarning(device.id, WarningCode.wrongSupply));
        } else if (reading.volts > rated.volts * 1.15) {
          warnings.add(SimWarning(device.id, WarningCode.overvoltage));
        } else if (reading.volts > 0 && reading.volts < rated.volts * 0.85) {
          warnings.add(SimWarning(device.id, WarningCode.undervoltage));
        }
        // A coil or electronics draws whenever it has voltage. A load only draws while it is on.
        final state = states[device.id] ?? '';
        final powered = def.load == null || state == 'on' || state.startsWith('run');
        if (reading.volts > 0 && powered && supplyMatches(rated, reading)) {
          flow.addLoad(device.id, rated.a, rated.b, reading, def.impedance(device, rated));
        }
      }
      if (def.kind == 'motor3') {
        final motor = nets.motorState(device.id);
        if (motor.singlePhasing) warnings.add(SimWarning(device.id, WarningCode.singlePhasing));
        if (motor.unconnected) warnings.add(SimWarning(device.id, WarningCode.motorUnconnected));
        if (motor.state != 'stopped' && !nets.isEarthed(device.id, 'PE')) warnings.add(SimWarning(device.id, WarningCode.motorNoEarth));
        flow.addMotor(device, def, motor, nets);
        final line = nets.voltage(device.id, 'U1', 'V1');
        if (motor.singlePhasing) strain(device.id, const Stress(10, DamageCause.lockedRotor));
        if (motor.state != 'stopped') {
          strain(device.id, _overvoltage(line.volts.toDouble(), 400));
          strain(device.id, _frequency('rotor', line.hertz, line.volts.toDouble()));
          if (line.hertz < 45 || line.hertz > 65) warnings.add(SimWarning(device.id, WarningCode.wrongFrequency));
        }
      }
      if (def.kind == 'plc' && states[device.id] != 'off' && states[device.id] != 'stop') {
        final scan = _scan(device, states[device.id]!, nets, plc);
        memory[device.id] = scan.memory;
        final program = programOf(device);
        final active = {
          for (final e in scan.memory.timers.entries)
            if (e.value.since != null || e.value.edge != null) e.key: program.timer(e.key).preset,
        };
        if (active.isNotEmpty) timers[device.id] = active;
      }
      final meter = def.meter;
      if (meter != null && meter['a'] != null) {
        final reading = nets.voltage(device.id, meter['a'] as String, meter['b'] as String);
        readings[device.id] = reading;
      }
      for (final pair in def.meterChannels) {
        final ends = pair.split('-');
        (channels[device.id] ??= {})[pair] = nets.voltage(device.id, ends[0], ends[1]).volts.toDouble();
      }
    }

    for (final device in project.devices) {
      final def = defs[device.defId]!;
      if (states[device.id] == kExploded) {
        measures[device.id] = const Measure();
        continue;
      }
      final meter = def.meter;
      var amps = flow.currentOf(device.id);
      if (meter != null && meter['a'] != null) {
        final reading = readings[device.id] ?? Reading.zero;
        final threePhase = meter['three_phase'] == true;
        final watts = flow.wattsThrough(device.id);
        measures[device.id] = Measure(volts: threePhase && reading.volts > 0 ? reading.volts.toDouble() : reading.volts.toDouble(), amps: amps, watts: watts, hertz: reading.hertz);
      } else {
        final loadAmps = flow.loadAmps[device.id];
        if (loadAmps != null) amps = loadAmps;
        final reading = _deviceVoltage(device, def, nets);
        measures[device.id] = Measure(volts: reading.volts.toDouble(), amps: amps, watts: flow.loadWatts[device.id] ?? flow.wattsThrough(device.id), hertz: reading.hertz);
      }
    }

    return SimResult(
      states: states,
      potentials: nets.potentials(project, defs),
      fault: fault,
      warnings: warnings,
      readings: readings,
      measures: measures,
      plcTimers: timers,
      plcMemory: memory,
      wireAmps: flow.wireAmps,
      starMotors: {
        for (final device in project.devices)
          if (defs[device.defId]!.kind == 'motor3' && nets.motorState(device.id).isStar && states[device.id] != 'stopped' && states[device.id] != kExploded) device.id,
      },
      channels: channels,
      stress: stress,
      trippedDeviceId: tripped,
    );
  }
}

/// How a device with this rating suffers the voltage it sees, or null when it is safe.
Stress? damageFor(DeviceDef def, RatedPair rated, Reading reading) {
  final volts = reading.volts.toDouble();
  if (volts <= 0) return null;
  if (!supplyMatches(rated, reading)) {
    // Mains on DC electronics destroys them at once. DC on an AC coil has no reactance to limit it, so it cooks.
    if (volts < rated.volts * 0.5) return null;
    return Stress(rated.supply == 'dc' ? 0.5 : 2.0, DamageCause.wrongSupply, volts: volts, rated: rated.volts.toDouble());
  }
  final over = _overvoltage(volts, rated.volts.toDouble());
  final freq = reading.supply == 'ac' ? _frequency(_frequencyClass(def), reading.hertz, volts) : null;
  if (over == null) return freq;
  if (freq == null) return over;
  return freq.seconds < over.seconds ? freq : over;
}

/// Up to 15% over rating is tolerated. Beyond that it fails faster the further over it is:
/// about 4 s at +16%, 1.2 s at +30%, and almost at once at 400 V on a 230 V part.
Stress? _overvoltage(double volts, double rated) {
  if (rated <= 0 || volts <= rated * 1.15) return null;
  final seconds = (1.2 * math.pow(0.3 / (volts / rated - 1), 2)).clamp(0.3, 30.0).toDouble();
  return Stress(seconds, DamageCause.overvoltage, volts: volts, rated: rated);
}

/// Which way a device suffers off-frequency supply: iron cores and rotors care, resistive loads do not.
String? _frequencyClass(DeviceDef def) {
  if (def.kind == 'motor3' || def.rotor != null) return 'rotor';
  if (def.kind == 'coil' || def.isTimer) return 'coil';
  if (def.kind == 'psu' || def.kind == 'plc' || def.kind == 'hmi') return 'electronics';
  return null;
}

/// Rated for 50/60 Hz, tolerated from 45 to 65 Hz.
/// Lower: an inductor's reactance falls with frequency, so the current climbs and the winding overheats.
/// Higher: a motor overspeeds and flies apart, and a coil's iron heats from eddy losses. Electronics rectify the
/// supply first, so high frequency does them no harm, but very low frequency overloads their input capacitors.
Stress? _frequency(String? kind, double hertz, double volts) {
  if (kind == null || hertz <= 0 || volts <= 0 || (hertz >= 45 && hertz <= 65)) return null;
  double? seconds;
  if (hertz < 45) {
    final off = (45 - hertz) / 45;
    seconds = kind == 'electronics' ? (6 / off).clamp(1.5, 60.0) : (2 / off).clamp(0.6, 40.0);
  } else {
    final off = (hertz - 65) / 65;
    if (kind == 'rotor') seconds = (1.5 / off).clamp(0.8, 40.0);
    if (kind == 'coil') seconds = (5 / off).clamp(2.0, 60.0);
  }
  if (seconds == null) return null;
  return Stress(seconds, hertz < 45 ? DamageCause.lowFrequency : DamageCause.highFrequency, volts: volts, hertz: hertz);
}

/// The contactor-to-relay connections of overload relays plugged under a contactor: its 2/4/6 terminals carry
/// straight on into the relay's 1/3/5 pins, with no wire drawn, as in a real starter.
Iterable<(String, String)> seatedLinks(Project project) sync* {
  for (final tor in project.devices) {
    final contactor = (tor.data['seated_on'] as num?)?.toInt();
    if (contactor == null) continue;
    yield ('$contactor:2', '${tor.id}:1');
    yield ('$contactor:4', '${tor.id}:3');
    yield ('$contactor:6', '${tor.id}:5');
  }
}

/// Adds load currents along paths back to the source.
class _Flow {
  _Flow(this.project, this.defs, this.states, this.nets) {
    for (final wire in project.wires) {
      _link(wire.a.key, wire.b.key, null, null, wire);
    }
    for (final (a, b) in seatedLinks(project)) {
      _link(a, b, null, null, null);
    }
    for (final device in project.devices) {
      final def = defs[device.defId]!;
      final state = states[device.id];
      for (final contact in def.contacts) {
        if (contact.closedIn.contains(state)) _link('${device.id}:${contact.a}', '${device.id}:${contact.b}', device.id, contact.a, null);
      }
      if (def.kind == 'plc') {
        final bits = plcBits(state);
        for (final name in def.plcOutputs) {
          final (a, b) = plcOutputTerminals(def, name);
          if (bits.contains(name)) _link('${device.id}:$a', '${device.id}:$b', device.id, name, null);
        }
      }
      def.outputs.forEach((terminal, _) => _sources.add('${device.id}:$terminal'));
    }
  }

  final Project project;
  final Map<String, DeviceDef> defs;
  final Map<int, String> states;
  final _Nets nets;
  final Map<String, List<(String, int?, String?, Wire?)>> _edges = {};
  final Set<String> _sources = {};

  /// Signed current per wire id, positive from the wire's end a to end b.
  final Map<int, double> wireAmps = {};

  /// Current per contact, so each pole of a multi-pole device is counted on its own.
  final Map<int, Map<String, double>> _poles = {};
  final Map<int, double> _watts = {};
  final Map<int, double> loadAmps = {};
  final Map<int, double> loadWatts = {};

  void _link(String a, String b, int? device, String? pole, Wire? wire) {
    _edges.putIfAbsent(a, () => []).add((b, device, pole, wire));
    _edges.putIfAbsent(b, () => []).add((a, device, pole, wire));
  }

  /// Contacts on the shortest path from a terminal to a source terminal, and adds [amps] to the wires on it.
  /// On the line side current runs from the source to the load; on the return side it runs back.
  List<(int, String)> _path(String start, double amps, bool lineSide) {
    final before = <String, (String, int?, String?, Wire?)>{};
    final seen = {start};
    final queue = [start];
    String? found;
    for (var i = 0; i < queue.length && found == null; i++) {
      final key = queue[i];
      if (_sources.contains(key)) {
        found = key;
        break;
      }
      for (final (next, device, pole, wire) in _edges[key] ?? const <(String, int?, String?, Wire?)>[]) {
        if (seen.add(next)) {
          before[next] = (key, device, pole, wire);
          queue.add(next);
        }
      }
    }
    final contacts = <(int, String)>[];
    var at = found;
    while (at != null && before.containsKey(at)) {
      final (previous, device, pole, wire) = before[at]!;
      if (device != null) contacts.add((device, pole!));
      if (wire != null) {
        // `previous` is the end nearer the load.
        final fromAToB = (previous == wire.a.key) != lineSide;
        wireAmps[wire.id] = (wireAmps[wire.id] ?? 0) + (fromAToB ? amps : -amps);
      }
      at = previous;
    }
    // The source supplies this current too, counted per terminal.
    if (found != null) {
      final parts = found.split(':');
      contacts.add((int.parse(parts.first), parts.sublist(1).join(':')));
    }
    return contacts;
  }

  void _addAlong(String terminal, double amps, double watts, {required bool lineSide}) {
    final counted = <int>{};
    for (final (device, pole) in _path(terminal, amps, lineSide)) {
      final poles = _poles.putIfAbsent(device, () => {});
      poles[pole] = (poles[pole] ?? 0) + amps;
      if (counted.add(device)) _watts[device] = (_watts[device] ?? 0) + watts;
    }
  }

  void addLoad(int deviceId, String a, String b, Reading reading, double ohms) {
    final amps = reading.volts / ohms;
    final watts = reading.volts * amps;
    loadAmps[deviceId] = amps;
    loadWatts[deviceId] = watts;
    // Power is credited once, on the side toward the line. Current flows through both sides.
    final labelA = nets.labelOf(deviceId, a), labelB = nets.labelOf(deviceId, b);
    final aIsLine = labelA?.startsWith('L') == true || (dcVoltsOf(labelA) ?? -1) > (dcVoltsOf(labelB) ?? -1);
    _addAlong('$deviceId:$a', amps, aIsLine ? watts : 0, lineSide: aIsLine);
    _addAlong('$deviceId:$b', amps, aIsLine ? 0 : watts, lineSide: !aIsLine);
  }

  void addMotor(PlacedDevice device, DeviceDef def, _MotorResult motor, _Nets nets) {
    if (motor.state == 'stopped' && !motor.singlePhasing) return;
    final power = device.number('power_w', def.ratedPower ?? 2200);
    final lineVolts = nets.voltage(device.id, 'U1', 'V1').volts;
    final fullLoad = power / (1.732 * 400 * 0.85 * 0.85);
    // Star draws a third of delta's line current. A motor missing a phase stalls and draws locked-rotor current.
    final scale = motor.singlePhasing ? 6.0 : (motor.isStar ? 1 / 3 : 1.0);
    final amps = fullLoad * scale;
    loadAmps[device.id] = amps;
    final watts = motor.singlePhasing ? 0.0 : power * scale;
    loadWatts[device.id] = watts;
    if (lineVolts >= 0) {
      for (final terminal in const ['U1', 'V1', 'W1']) {
        if (nets.labelOf(device.id, terminal) != null) _addAlong('${device.id}:$terminal', amps, watts / 3, lineSide: true);
      }
    }
  }

  /// The largest current through any one pole of a device.
  double currentOf(int device) {
    final poles = _poles[device];
    if (poles == null || poles.isEmpty) return 0;
    return poles.values.reduce((a, b) => a > b ? a : b);
  }

  double wattsThrough(int device) => _watts[device] ?? 0;
}

class _MotorResult {
  const _MotorResult(this.state, {this.singlePhasing = false, this.unconnected = false, this.isStar = false});

  final String state;
  final bool singlePhasing;
  final bool unconnected;
  final bool isStar;
}

/// Union-find over terminals for one set of device states.
class _Nets {
  _Nets._();

  final Map<String, String> _parent = {};
  final Map<String, Set<String>> _labels = {};
  final Map<String, double> _netVolts = {};
  final Map<String, double> _netHertz = {};

  factory _Nets.build(Project project, Map<String, DeviceDef> defs, Map<int, String> states) {
    final nets = _Nets._();
    for (final wire in project.wires) {
      nets._union(wire.a.key, wire.b.key);
    }
    for (final (a, b) in seatedLinks(project)) {
      nets._union(a, b);
    }
    for (final device in project.devices) {
      final def = defs[device.defId]!;
      final state = states[device.id];
      for (final contact in def.contacts) {
        if (contact.closedIn.contains(state)) nets._union('${device.id}:${contact.a}', '${device.id}:${contact.b}');
      }
      if (def.kind == 'plc') {
        final bits = plcBits(state);
        for (final name in def.plcOutputs) {
          final (a, b) = plcOutputTerminals(def, name);
          if (bits.contains(name)) nets._union('${device.id}:$a', '${device.id}:$b');
        }
      }
    }
    for (final device in project.devices) {
      final def = defs[device.defId]!;
      if (def.kind == 'psu' && states[device.id] != 'on') continue;
      if (states[device.id] == kExploded) continue;
      def.outputs.forEach((terminal, given) {
        var label = given;
        if (label == 'DC+') {
          // Each DC supply's positive is labelled with its voltage, so 12, 24 and 48 V nets stay apart.
          final volts = def.isAdjustable ? device.number('voltage', def.dcVolts) : def.dcVolts;
          if (volts <= 0) return;
          label = dcPlusLabel(volts);
        }
        final root = nets._find('${device.id}:$terminal');
        nets._labels.putIfAbsent(root, () => {}).add(label);
        if (label.startsWith('L')) {
          nets._netVolts[root] = def.isAdjustable ? device.number('voltage', 230) : 230;
          nets._netHertz[root] = def.isAdjustable ? device.number('frequency', 50) : 50;
        }
      });
    }
    return nets;
  }

  static const _ac = {'L1', 'L2', 'L3', 'N', 'PE'};

  bool _conflict(Set<String> labels) {
    if (labels.length < 2) return false;
    final lines = labels.where((l) => l.startsWith('L')).length;
    final positives = labels.where((l) => l.startsWith('DC+')).length;
    // Positive to negative, or two supplies at different voltages tied together.
    final dc = (positives >= 1 && labels.contains('DC-')) || positives >= 2;
    final mixed = labels.any(_ac.contains) && labels.any((l) => l.startsWith('DC'));
    final lineToNeutral = lines >= 1 && (labels.contains('N') || labels.contains('PE'));
    return lines >= 2 || dc || mixed || lineToNeutral;
  }

  bool get hasShort => _labels.values.any(_conflict);

  String _find(String key) {
    var current = key;
    while (true) {
      final parent = _parent[current];
      if (parent == null || parent == current) return current;
      current = parent;
    }
  }

  void _union(String first, String second) {
    final a = _find(first);
    final b = _find(second);
    if (a != b) _parent[a] = b;
  }

  String? _labelFor(String root) {
    final labels = _labels[root];
    if (labels == null || labels.isEmpty) return null;
    if (_conflict(labels)) return 'short';
    return labels.contains('N') ? 'N' : labels.first;
  }

  /// The label on a terminal's net. N and PE together count as neutral, which is a normal TN bond.
  String? labelOf(int deviceId, String terminal) => _labelFor(_find('$deviceId:$terminal'));

  Reading voltage(int deviceId, String a, String b) => _between(_find('$deviceId:$a'), _find('$deviceId:$b'));

  Reading _between(String rootA, String rootB) {
    final a = _labelFor(rootA), b = _labelFor(rootB);
    if (a == null || b == null || a == b || a == 'short' || b == 'short') return Reading.zero;
    final dcA = dcVoltsOf(a);
    final dcB = dcVoltsOf(b);
    if (dcA != null && dcB != null) return Reading((dcA - dcB).abs(), 'dc', 0, dcA - dcB);
    if (dcA != null || dcB != null) return Reading.zero;
    final lineA = a.startsWith('L');
    final lineB = b.startsWith('L');
    // Line voltage uses the nominal 400/230 ratio, so a standard supply reads exactly 400 V.
    if (lineA && lineB) return Reading(((_netVolts[rootA] ?? 230) * 400 / 230).roundToDouble(), 'ac', _netHertz[rootA] ?? 50);
    if (lineA) return Reading(_netVolts[rootA] ?? 230, 'ac', _netHertz[rootA] ?? 50);
    if (lineB) return Reading(_netVolts[rootB] ?? 230, 'ac', _netHertz[rootB] ?? 50);
    return Reading.zero; // N to PE.
  }

  /// A terminal's voltage against neutral, or the DC supply's voltage.
  Reading toNeutral(int deviceId, String terminal) {
    final root = _find('$deviceId:$terminal');
    final label = _labelFor(root);
    if (label == null || label == 'short' || label == 'N' || label == 'PE') return Reading.zero;
    final dc = dcVoltsOf(label);
    if (dc != null) return dc == 0 ? Reading.zero : Reading(dc, 'dc', 0, dc);
    return Reading(_netVolts[root] ?? 230, 'ac', _netHertz[root] ?? 50);
  }

  /// Pulls in from a share of the rated voltage. Above rating it still works, and warns.
  bool ratedPowered(int deviceId, RatedPair rated, {double minRatio = 0.8}) {
    final reading = voltage(deviceId, rated.a, rated.b);
    return supplyMatches(rated, reading) && reading.volts >= rated.volts * minRatio;
  }

  bool isEarthed(int deviceId, String terminal) {
    final labels = _labels[_find('$deviceId:$terminal')];
    return labels != null && (labels.contains('PE') || labels.contains('N'));
  }

  _MotorResult motorState(int id) {
    String root(String terminal) => _find('$id:$terminal');
    final phases = [for (final t in const ['U1', 'V1', 'W1']) labelOf(id, t)];
    final lines = {for (final p in phases) if (p != null && p.startsWith('L')) p};
    final star = root('U2') == root('V2') && root('V2') == root('W2');
    final deltaA = root('U1') == root('W2') && root('V1') == root('U2') && root('W1') == root('V2');
    final deltaB = root('U1') == root('V2') && root('V1') == root('W2') && root('W1') == root('U2');
    final connected = star || deltaA || deltaB;
    if (lines.isEmpty) return const _MotorResult('stopped');
    if (!connected) return const _MotorResult('stopped', unconnected: true);
    if (lines.length < 3) return const _MotorResult('stopped', singlePhasing: true);
    const forward = [
      ['L1', 'L2', 'L3'],
      ['L2', 'L3', 'L1'],
      ['L3', 'L1', 'L2'],
    ];
    final isForward = forward.any((order) => order[0] == phases[0] && order[1] == phases[1] && order[2] == phases[2]);
    return _MotorResult(isForward ? 'run_fwd' : 'run_rev', isStar: star);
  }

  Map<String, String> potentials(Project project, Map<String, DeviceDef> defs) {
    final result = <String, String>{};
    for (final device in project.devices) {
      for (final terminal in defs[device.defId]!.terminals) {
        final label = labelOf(device.id, terminal.id);
        if (label != null) result['${device.id}:${terminal.id}'] = label;
      }
    }
    return result;
  }
}

/// The two terminals a PLC output relay switches: Q1A and Q1B on the starter PLC, Q1.1 and Q1.2 on a Siemens LOGO.
(String, String) plcOutputTerminals(DeviceDef def, String output) {
  final pair = def.plcOutputPair(output);
  if (pair != null && pair.length == 2) return (pair[0], pair[1]);
  if (def.terminals.any((t) => t.id == '$output.1')) return ('$output.1', '$output.2');
  return ('${output}A', '${output}B');
}
