import 'model/project.dart';

/// Starter circuits offered when creating a project.
class CircuitTemplate {
  const CircuitTemplate(this.id, this.name, this.description, this.build, this.hint, {this.arrange = false});

  final String id;
  final String name;
  final String description;
  final Project Function() build;
  final String hint;

  /// Laid out by the automatic layout when opened (power on the left, controls on the right) instead of the
  /// positions in [build]. Set where that measured fewer crossings and shorter wires than the hand layout.
  final bool arrange;
}

const _brown = 0xFF8A5A2B;
const _black = 0xFF1F2428;
const _grey = 0xFF808890;
const _blue = 0xFF1D6FB8;
const _green = 0xFF3F8F3A;
const _controlColor = 0xFFB3261E;

class _Builder {
  _Builder(String name) : project = Project(name: name);

  final Project project;
  final Map<String, int> _ids = {};
  int _next = 1;

  void add(String tag, String defId, double x, double y, {double? time}) {
    final id = _next++;
    _ids[tag] = id;
    project.devices.add(PlacedDevice(id: id, defId: defId, tag: tag, x: x, y: y, timeSeconds: time));
  }

  /// 'TAG.TERMINAL', split at the first dot only: LOGO terminals such as Q1.1 contain one.
  TerminalRef _ref(String spec) {
    final dot = spec.indexOf('.');
    return TerminalRef(_ids[spec.substring(0, dot)]!, spec.substring(dot + 1));
  }

  void wire(String a, String b, int color, {double gauge = 1.5}) {
    project.wires.add(Wire(id: _next++, a: _ref(a), b: _ref(b), color: color, gauge: gauge));
  }

  void jumper(String a, String b) {
    project.wires.add(Wire(id: _next++, a: _ref(a), b: _ref(b), color: Wire.jumperColor, isJumper: true, gauge: 2.5));
  }
}

const _source3 = 'generic_source_ac3';
const _breaker3 = 'chint_nxb63h_3p';
const _control = 'schneider_ic60n_1p_c10';
const _contactor = 'chint_nxc32';
const _overload = 'chint_nr2_25';
const _motor = 'motor_6_terminales';
const _start = 'pulsador_verde_1no';
const _stop = 'pulsador_rojo_1nc';
const _lampGreen = 'piloto_led_verde';
const _timer = 'chint_jss48a';
const _plc = 'logo_230rce';

// Push button terminals: the green NO button switches 3-4, the red NC button 1-2.

Project buildLampExample() {
  final b = _Builder('Lampu lewat kontaktor')
    ..add('G1', 'generic_source_ac', 0, 40)
    ..add('QF1', 'schneider_acti9_ic60n_1p_c16', 280, 0)
    ..add('S1', _start, 440, 120)
    ..add('KM1', _contactor, 620, 0)
    ..add('HL1', 'piloto_led_amarillo', 940, 120);
  b
    ..wire('G1.L', 'QF1.1', _brown)
    ..wire('QF1.2', 'S1.3', _brown)
    ..wire('S1.4', 'KM1.A1', _brown)
    ..wire('QF1.2', 'KM1.1', _brown)
    ..wire('KM1.2', 'HL1.X1', _brown)
    ..wire('KM1.A2', 'G1.N', _blue)
    ..wire('HL1.X2', 'G1.N', _blue);
  return b.project;
}

/// Motor connected in delta with three jumpers across the terminal board.
void _deltaJumpers(_Builder b, String motor) {
  b
    ..jumper('$motor.U1', '$motor.W2')
    ..jumper('$motor.V1', '$motor.U2')
    ..jumper('$motor.W1', '$motor.V2');
}

/// Supply, main breaker and control breaker along the top row.
void _supply(_Builder b) {
  b
    ..add('G1', _source3, 0, 0)
    ..add('QF1', _breaker3, 380, 0)
    ..add('F2', _control, 660, 0);
  b
    ..wire('G1.L1', 'QF1.1', _brown, gauge: 2.5)
    ..wire('G1.L2', 'QF1.3', _black, gauge: 2.5)
    ..wire('G1.L3', 'QF1.5', _grey, gauge: 2.5)
    ..wire('QF1.2', 'F2.1', _controlColor);
}

/// Main contacts of [km] fed straight from QF1.
void _feed(_Builder b, String km) {
  b
    ..wire('QF1.2', '$km.1', _brown, gauge: 2.5)
    ..wire('QF1.4', '$km.3', _black, gauge: 2.5)
    ..wire('QF1.6', '$km.5', _grey, gauge: 2.5);
}

/// Contactor [km] into the overload relay F1.
void _contactorToOverload(_Builder b, String km) {
  b
    ..wire('$km.2', 'F1.1', _brown, gauge: 2.5)
    ..wire('$km.4', 'F1.3', _black, gauge: 2.5)
    ..wire('$km.6', 'F1.5', _grey, gauge: 2.5);
}

/// Overload relay F1 to the motor M1, with its earth.
void _overloadToMotor(_Builder b) {
  b
    ..wire('F1.2', 'M1.U1', _brown, gauge: 2.5)
    ..wire('F1.4', 'M1.V1', _black, gauge: 2.5)
    ..wire('F1.6', 'M1.W1', _grey, gauge: 2.5)
    ..wire('G1.PE', 'M1.PE', _green, gauge: 2.5);
}

Project buildDol() {
  final b = _Builder('DOL: start-stop motor');
  _supply(b);
  b
    ..add('S0', _stop, 820, 120)
    ..add('S1', _start, 960, 120)
    ..add('HL1', _lampGreen, 1100, 100)
    ..add('KM1', _contactor, 0, 460)
    ..add('F1', _overload, 300, 500)
    ..add('M1', _motor, 560, 460);
  _feed(b, 'KM1');
  _contactorToOverload(b, 'KM1');
  _overloadToMotor(b);
  b
    ..wire('F2.2', 'F1.95', _controlColor)
    ..wire('F1.96', 'S0.1', _controlColor)
    ..wire('S0.2', 'S1.3', _controlColor)
    ..wire('S1.4', 'KM1.A1', _controlColor)
    ..wire('S0.2', 'KM1.13', _controlColor)
    ..wire('KM1.14', 'S1.4', _controlColor)
    ..wire('KM1.14', 'HL1.X1', _controlColor)
    ..wire('KM1.A2', 'G1.N', _blue)
    ..wire('HL1.X2', 'G1.N', _blue);
  _deltaJumpers(b, 'M1');
  return b.project;
}

Project buildReversing() {
  final b = _Builder('Motor bolak-balik dengan interlock');
  _supply(b);
  b
    ..add('S0', _stop, 820, 120)
    ..add('S1', _start, 960, 120)
    ..add('S2', _start, 1100, 120)
    ..add('KM1', _contactor, 0, 460)
    ..add('KM2', _contactor, 300, 460)
    ..add('F1', _overload, 600, 500)
    ..add('M1', _motor, 860, 460);
  _feed(b, 'KM1');
  b
    // KM2 swaps L1 and L3 to reverse rotation.
    ..wire('QF1.2', 'KM2.5', _brown, gauge: 2.5)
    ..wire('QF1.4', 'KM2.3', _black, gauge: 2.5)
    ..wire('QF1.6', 'KM2.1', _grey, gauge: 2.5);
  _contactorToOverload(b, 'KM1');
  _contactorToOverload(b, 'KM2');
  _overloadToMotor(b);
  b
    ..wire('F2.2', 'F1.95', _controlColor)
    ..wire('F1.96', 'S0.1', _controlColor)
    // Forward branch: start or self-hold, through KM2's NC interlock, to KM1's coil.
    ..wire('S0.2', 'S1.3', _controlColor)
    ..wire('S0.2', 'KM1.13', _controlColor)
    ..wire('S1.4', 'KM1.14', _controlColor)
    ..wire('KM1.14', 'KM2.21', _controlColor)
    ..wire('KM2.22', 'KM1.A1', _controlColor)
    // Reverse branch: start or self-hold, through KM1's NC interlock, to KM2's coil.
    ..wire('S0.2', 'S2.3', _controlColor)
    ..wire('S0.2', 'KM2.13', _controlColor)
    ..wire('S2.4', 'KM2.14', _controlColor)
    ..wire('KM2.14', 'KM1.21', _controlColor)
    ..wire('KM1.22', 'KM2.A1', _controlColor)
    ..wire('KM1.A2', 'G1.N', _blue)
    ..wire('KM2.A2', 'G1.N', _blue);
  _deltaJumpers(b, 'M1');
  return b.project;
}

Project buildStarDelta() {
  final b = _Builder('Star-delta otomatis dengan timer');
  _supply(b);
  b
    ..add('S0', _stop, 820, 120)
    ..add('S1', _start, 960, 120)
    ..add('KM1', _contactor, 0, 460)
    ..add('KM2', _contactor, 300, 460)
    ..add('KM3', _contactor, 600, 460)
    ..add('M1', _motor, 900, 460)
    ..add('KT1', _timer, 1560, 460, time: 5);
  _feed(b, 'KM1');
  b
    // KM1 main: supply to U1, V1, W1.
    ..wire('KM1.2', 'M1.U1', _brown, gauge: 2.5)
    ..wire('KM1.4', 'M1.V1', _black, gauge: 2.5)
    ..wire('KM1.6', 'M1.W1', _grey, gauge: 2.5)
    // KM2 delta: U1-W2, V1-U2, W1-V2.
    ..wire('KM1.2', 'KM2.1', _brown, gauge: 2.5)
    ..wire('KM1.4', 'KM2.3', _black, gauge: 2.5)
    ..wire('KM1.6', 'KM2.5', _grey, gauge: 2.5)
    ..wire('KM2.2', 'M1.W2', _brown, gauge: 2.5)
    ..wire('KM2.4', 'M1.U2', _black, gauge: 2.5)
    ..wire('KM2.6', 'M1.V2', _grey, gauge: 2.5)
    // KM3 star: joins U2, V2, W2.
    ..wire('M1.U2', 'KM3.1', _black, gauge: 2.5)
    ..wire('M1.V2', 'KM3.3', _grey, gauge: 2.5)
    ..wire('M1.W2', 'KM3.5', _brown, gauge: 2.5)
    ..jumper('KM3.2', 'KM3.4')
    ..jumper('KM3.4', 'KM3.6')
    ..wire('G1.PE', 'M1.PE', _green, gauge: 2.5)
    // Control.
    ..wire('F2.2', 'S0.1', _controlColor)
    ..wire('S0.2', 'S1.3', _controlColor)
    ..wire('S0.2', 'KM1.13', _controlColor)
    ..wire('S1.4', 'KM1.14', _controlColor)
    ..wire('KM1.14', 'KM1.A1', _controlColor)
    ..wire('KM1.14', 'KT1.A1', _controlColor)
    // Star until the timer finishes, interlocked by KM2.
    ..wire('KM1.14', 'KT1.15', _controlColor)
    ..wire('KT1.16', 'KM2.21', _controlColor)
    ..wire('KM2.22', 'KM3.A1', _controlColor)
    // Delta after the timer, interlocked by KM3.
    ..wire('KT1.18', 'KM3.21', _controlColor)
    ..wire('KM3.22', 'KM2.A1', _controlColor)
    ..wire('KM1.A2', 'G1.N', _blue)
    ..wire('KM2.A2', 'G1.N', _blue)
    ..wire('KM3.A2', 'G1.N', _blue)
    ..wire('KT1.A2', 'G1.N', _blue);
  return b.project;
}

/// Start-stop motor run by a PLC: start on I1, stop on I2, overload trip on I3.
Project buildPlc() {
  final b = _Builder('PLC: start-stop motor');
  _supply(b);
  b
    ..add('PLC1', _plc, 860, 0)
    ..add('KM1', _contactor, 0, 460)
    ..add('F1', _overload, 300, 500)
    ..add('M1', _motor, 560, 460)
    ..add('S1', _start, 1240, 580)
    ..add('S2', _start, 1380, 580);
  b.project.devices.firstWhere((d) => d.tag == 'PLC1').data['program'] = [
    {
      'branches': [
        [
          {'ref': 'I1'},
        ],
        [
          {'ref': 'Q1'},
        ],
      ],
      'coil': 'M1',
    },
    {
      'branches': [
        [
          {'ref': 'M1'},
          {'ref': 'I2', 'neg': true},
          {'ref': 'I3', 'neg': true},
        ],
      ],
      'coil': 'Q1',
    },
  ];
  _feed(b, 'KM1');
  _contactorToOverload(b, 'KM1');
  _overloadToMotor(b);
  b
    ..wire('F2.2', 'PLC1.L', _controlColor)
    ..wire('G1.N', 'PLC1.N', _blue)
    ..wire('F2.2', 'S1.3', _controlColor)
    ..wire('S1.4', 'PLC1.I1', _controlColor)
    ..wire('F2.2', 'S2.3', _controlColor)
    ..wire('S2.4', 'PLC1.I2', _controlColor)
    ..wire('F2.2', 'F1.97', _controlColor)
    ..wire('F1.98', 'PLC1.I3', _controlColor)
    ..wire('F2.2', 'PLC1.Q1.1', _controlColor)
    ..wire('PLC1.Q1.2', 'KM1.A1', _controlColor)
    ..wire('KM1.A2', 'G1.N', _blue);
  _deltaJumpers(b, 'M1');
  return b.project;
}

/// Star-delta run by the PLC, with its own timer T1 instead of a timer relay.
///
/// I1 start (NO), I2 stop (NC, so a broken wire also stops), I3 overload trip. Q1 KM1 main, Q2 KM2 star, Q3 KM3 delta.
/// The run latch M1 starts KM1 and KM2 together and T1; when T1 is done star drops out and delta pulls in, each
/// output also blocked by the other so star and delta are never on at once.
Project buildPlcStarDelta() {
  final b = _Builder('PLC: star-delta dengan timer T1');
  _supply(b);
  b
    ..add('PLC1', _plc, 860, 0)
    ..add('S1', _start, 1240, 120)
    ..add('S0', _stop, 1380, 120)
    ..add('KM1', _contactor, 0, 460)
    ..add('F1', _overload, 280, 500)
    ..add('KM2', _contactor, 520, 460)
    ..add('KM3', _contactor, 800, 460)
    ..add('M1', _motor, 1100, 460);
  Map<String, Object> no(String ref) => {'ref': ref};
  Map<String, Object> nc(String ref) => {'ref': ref, 'neg': true};
  b.project.devices.firstWhere((d) => d.tag == 'PLC1').data['program'] = [
    // Run latch: start, or already running; held only while stop is closed and the overload has not tripped.
    {
      'branches': [
        [no('I1'), no('I2'), nc('I3')],
        [no('M1'), no('I2'), nc('I3')],
      ],
      'coil': 'M1',
    },
    {
      'branches': [
        [no('M1')],
      ],
      'coil': 'Q1',
    },
    {
      'branches': [
        [no('M1')],
      ],
      'coil': 'T1',
      'preset': 5.0,
    },
    // Star until T1 is done, never with delta.
    {
      'branches': [
        [no('M1'), nc('T1'), nc('Q3')],
      ],
      'coil': 'Q2',
    },
    // Delta once T1 is done, never with star.
    {
      'branches': [
        [no('M1'), no('T1'), nc('Q2')],
      ],
      'coil': 'Q3',
    },
  ];
  _feed(b, 'KM1');
  _contactorToOverload(b, 'KM1');
  _overloadToMotor(b);
  b
    // KM3 delta: U1-W2, V1-U2, W1-V2, fed after the overload.
    ..wire('F1.2', 'KM3.1', _brown, gauge: 2.5)
    ..wire('F1.4', 'KM3.3', _black, gauge: 2.5)
    ..wire('F1.6', 'KM3.5', _grey, gauge: 2.5)
    ..wire('KM3.2', 'M1.W2', _brown, gauge: 2.5)
    ..wire('KM3.4', 'M1.U2', _black, gauge: 2.5)
    ..wire('KM3.6', 'M1.V2', _grey, gauge: 2.5)
    // KM2 star: joins U2, V2, W2.
    ..wire('M1.U2', 'KM2.1', _black, gauge: 2.5)
    ..wire('M1.V2', 'KM2.3', _grey, gauge: 2.5)
    ..wire('M1.W2', 'KM2.5', _brown, gauge: 2.5)
    ..jumper('KM2.2', 'KM2.4')
    ..jumper('KM2.4', 'KM2.6')
    // PLC supply and inputs.
    ..wire('F2.2', 'PLC1.L', _controlColor)
    ..wire('G1.N', 'PLC1.N', _blue)
    ..wire('F2.2', 'S1.3', _controlColor)
    ..wire('S1.4', 'PLC1.I1', _controlColor)
    ..wire('F2.2', 'S0.1', _controlColor)
    ..wire('S0.2', 'PLC1.I2', _controlColor)
    ..wire('F2.2', 'F1.97', _controlColor)
    ..wire('F1.98', 'PLC1.I3', _controlColor)
    // Outputs to the coils.
    ..wire('F2.2', 'PLC1.Q1.1', _controlColor)
    ..wire('PLC1.Q1.2', 'KM1.A1', _controlColor)
    ..wire('F2.2', 'PLC1.Q2.1', _controlColor)
    ..wire('PLC1.Q2.2', 'KM2.A1', _controlColor)
    ..wire('F2.2', 'PLC1.Q3.1', _controlColor)
    ..wire('PLC1.Q3.2', 'KM3.A1', _controlColor)
    ..wire('KM1.A2', 'G1.N', _blue)
    ..wire('KM2.A2', 'G1.N', _blue)
    ..wire('KM3.A2', 'G1.N', _blue);
  return b.project;
}

const _psu24 = 'power_supply_100_minus_240vac_24vdc_5a';
const _relay24 = 'schneider_rxm4ab2bd';
const _dcRed = 0xFFB3261E;
const _dcBlue = 0xFF1D3F8F;

/// A 24 V DC control circuit driving a 230 V contactor through an interface relay, as industrial panels do: the
/// operator side stays at safe extra-low voltage, and only a relay contact touches mains.
Project buildDcControl() {
  final b = _Builder('Kontrol 24 V DC untuk motor');
  _supply(b);
  b
    ..add('U1', _psu24, 800, 0)
    ..add('S0', _stop, 1060, 120)
    ..add('S1', _start, 1180, 120)
    ..add('H1', 'piloto_led_verde_24vdc', 1300, 100)
    ..add('K1', _relay24, 1460, 0)
    ..add('KM1', _contactor, 0, 460)
    ..add('F1', _overload, 300, 500)
    ..add('M1', _motor, 560, 460);
  _feed(b, 'KM1');
  _contactorToOverload(b, 'KM1');
  _overloadToMotor(b);
  _deltaJumpers(b, 'M1');
  b
    // The 24 V supply, fed from the control breaker.
    ..wire('F2.2', 'U1.L', _controlColor)
    ..wire('G1.N', 'U1.N', _blue)
    // 24 V control: overload, stop, start with self-holding, relay coil.
    ..wire('U1.DC+1', 'F1.95', _dcRed)
    ..wire('F1.96', 'S0.1', _dcRed)
    ..wire('S0.2', 'S1.3', _dcRed)
    ..wire('S1.4', 'K1.A1', _dcRed)
    ..wire('S0.2', 'K1.21', _dcRed)
    ..wire('K1.24', 'K1.A1', _dcRed)
    ..wire('K1.A2', 'U1.DC-1', _dcBlue)
    // A 24 V lamp while it runs.
    ..wire('U1.DC+2', 'K1.31', _dcRed)
    ..wire('K1.34', 'H1.X1', _dcRed)
    ..wire('H1.X2', 'U1.DC-2', _dcBlue)
    // The relay's contact switches the contactor's 230 V coil.
    ..wire('F2.2', 'K1.11', _controlColor)
    ..wire('K1.14', 'KM1.A1', _controlColor)
    ..wire('KM1.A2', 'G1.N', _blue);
  return b.project;
}

/// A DC motor run both ways by two relays wired as an H-bridge, interlocked so they can never both close. Control
/// runs from a fixed 24 V supply; the motor from an adjustable one, so its speed follows the voltage.
Project buildDcMotor() {
  final b = _Builder('Motor DC maju-mundur');
  b
    ..add('G2', 'generic_source_dc24', 0, 0)
    ..add('G1', 'generic_source_dc_adjustable', 260, 0)
    ..add('S0', _stop, 540, 120)
    ..add('S1', _start, 660, 120)
    ..add('S2', _start, 780, 120)
    ..add('H1', 'piloto_led_verde_24vdc', 920, 100)
    ..add('H2', 'piloto_led_amarillo_24vdc', 1080, 100)
    ..add('K1', _relay24, 0, 440)
    ..add('K2', _relay24, 240, 440)
    ..add('M1', 'generic_motor_dc', 560, 440);
  b
    // Control: stop, then forward or reverse, each held in by its own contact and blocked by the other relay's NC.
    ..wire('G2.+', 'S0.1', _dcRed)
    ..wire('S0.2', 'S1.3', _dcRed)
    ..wire('S1.4', 'K2.31', _dcRed)
    ..wire('K2.32', 'K1.A1', _dcRed)
    ..wire('S0.2', 'K1.41', _dcRed)
    ..wire('K1.44', 'S1.4', _dcRed)
    ..wire('K1.A2', 'G2.-', _dcBlue)
    ..wire('S0.2', 'S2.3', _dcRed)
    ..wire('S2.4', 'K1.31', _dcRed)
    ..wire('K1.32', 'K2.A1', _dcRed)
    ..wire('S0.2', 'K2.41', _dcRed)
    ..wire('K2.44', 'S2.4', _dcRed)
    ..wire('K2.A2', 'G2.-', _dcBlue)
    // H-bridge: K1 puts + on A1, K2 puts + on A2.
    ..wire('G1.+', 'K1.11', _dcRed, gauge: 2.5)
    ..wire('K1.14', 'M1.A1', _dcRed, gauge: 2.5)
    ..wire('G1.-', 'K1.21', _dcBlue, gauge: 2.5)
    ..wire('K1.24', 'M1.A2', _dcBlue, gauge: 2.5)
    ..wire('G1.+', 'K2.11', _dcRed, gauge: 2.5)
    ..wire('K2.14', 'M1.A2', _dcRed, gauge: 2.5)
    ..wire('G1.-', 'K2.21', _dcBlue, gauge: 2.5)
    ..wire('K2.24', 'M1.A1', _dcBlue, gauge: 2.5)
    // Each lamp sits on one motor lead: lit when that lead is the + one.
    ..wire('M1.A1', 'H1.X1', _dcRed)
    ..wire('H1.X2', 'G1.-', _dcBlue)
    ..wire('M1.A2', 'H2.X1', _dcRed)
    ..wire('H2.X2', 'G1.-', _dcBlue);
  return b.project;
}

/// An adjustable supply and live meters, for exploring voltage and frequency.
Project buildMeterBench() {
  final b = _Builder('Bangku ukur: tegangan dan frekuensi')
    ..add('PS1', 'generic_source_adjustable', 0, 40)
    ..add('QF1', 'schneider_acti9_ic60n_1p_c16', 280, 0)
    ..add('E1', 'foco_led', 420, 20)
    ..add('PV1', 'oumik_m72_voltmeter', 700, 40)
    ..add('PF1', 'oumik_frequency_meter', 1060, 40);
  b
    ..wire('PS1.L', 'QF1.1', _brown)
    ..wire('QF1.2', 'E1.F', _brown)
    ..wire('E1.N', 'PS1.N', _blue)
    ..wire('QF1.2', 'PV1.IN1', _brown)
    ..wire('PS1.N', 'PV1.IN2', _blue)
    ..wire('QF1.2', 'PF1.IN1', _brown)
    ..wire('PS1.N', 'PF1.IN2', _blue);
  return b.project;
}

final List<CircuitTemplate> kTemplates = [
  CircuitTemplate('lamp', 'Lampu lewat kontaktor', 'Rangkaian paling dasar: MCB, tombol, kontaktor, lampu.', buildLampExample,
      'Tekan Jalankan, nyalakan QF1, lalu tahan tombol S1.'),
  CircuitTemplate('dol', 'DOL: start-stop motor', 'Motor 3 fasa dengan self-holding, overload, dan lampu indikator.', buildDol,
      'Tekan Jalankan, nyalakan QF1 dan F2, lalu klik S1. Tekan S0 untuk berhenti.', arrange: true),
  CircuitTemplate('reversing', 'Motor bolak-balik', 'Forward-reverse dengan interlock kontak NC.', buildReversing,
      'Tekan Jalankan, nyalakan QF1 dan F2. S1 maju, S2 mundur, S0 berhenti.', arrange: true),
  CircuitTemplate('stardelta', 'Star-delta otomatis', 'Start bintang, pindah ke segitiga lewat timer 5 detik.', buildStarDelta,
      'Tekan Jalankan, nyalakan QF1 dan F2, lalu klik S1 dan tunggu timer.', arrange: true),
  CircuitTemplate('plc', 'PLC', 'Start-stop motor lewat program ladder di Siemens LOGO.', buildPlc,
      'Tekan Jalankan, nyalakan QF1 dan F2, lalu klik S1 untuk start dan S2 untuk stop.', arrange: true),
  CircuitTemplate('plc_stardelta', 'PLC: star-delta', 'Star-delta lewat ladder Siemens LOGO, pakai timer T1 di dalam PLC.', buildPlcStarDelta,
      'Tekan Jalankan, nyalakan QF1 dan F2, lalu klik S1. Waktu T1 bisa diubah lewat ESC, Set Param di PLC.', arrange: true),
  CircuitTemplate('dc_control', 'Kontrol 24 V DC', 'Tombol dan relay 24 V DC menggerakkan kontaktor 230 V dan motor.', buildDcControl,
      'Tekan Jalankan, nyalakan QF1 dan F2, lalu klik S1. Rangkaian tombol hanya 24 V DC.', arrange: true),
  CircuitTemplate('dc_motor', 'Motor DC maju-mundur', 'Dua relay sebagai H-bridge dengan interlock; kecepatan ikut tegangan.', buildDcMotor,
      'Tekan Jalankan. S1 maju, S2 mundur, S0 berhenti. Klik G1 dan geser tegangannya untuk mengatur kecepatan.'),
  CircuitTemplate('meters', 'Bangku ukur', 'Sumber yang bisa diatur, lampu, voltmeter, dan frekuensi meter.', buildMeterBench,
      'Tekan Jalankan, nyalakan QF1, lalu klik PS1 dan geser slider tegangannya.'),
];
