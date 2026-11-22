import 'dart:math' as math;
import 'dart:ui';

/// BuildRelay: drawing and simulating classic relay control as a schematic (IEC symbols), with the control and the
/// power circuit on one sheet. Contacts follow the coil, timer or overload relay that carries the same tag.
///
/// Positions are in grid units; one unit is [RelaySheet.unit] canvas pixels.

/// One pole of a switching symbol: a make (NO) or break (NC) contact, a changeover, a fuse link, or an element that
/// always conducts (the heater of an overload relay).
enum PoleKind { no, nc, co, fuse, element }

class Pole {
  const Pole(this.kind, this.x);

  final PoleKind kind;

  /// Column of the pole in grid units; a changeover's common terminal is here, its NC one unit left, NO one right.
  final double x;
}

/// Kinds of symbol. The behaviour of each is in [RelaySim]; the drawing is in the editor.
class RelayType {
  const RelayType(this.id, this.name, this.category, this.prefix, this.size, this.pins,
      {this.follows, this.poles = const [], this.actuator = '', this.mark = ''});

  final String id;
  final String name;
  final String category;

  /// Tag prefix of new symbols of this kind (S, KM, QF …); empty for symbols without a tag of their own.
  final String prefix;

  /// Width and height in grid units, unrotated.
  final Size size;

  /// Pin names and their positions in grid units, unrotated.
  final Map<String, Offset> pins;

  /// For contacts: the kinds of symbol whose tag they follow (a coil, a timer, an overload relay).
  final Set<String>? follows;

  /// Switching poles, left to right; empty for symbols that do not switch.
  final List<Pole> poles;

  /// What operates the poles: push (held), latch (stays), limit (held or set), sel3 (three positions), coil, timer,
  /// tor (overload trip), breaker (on/off, opens by itself on a short); empty when nothing does.
  final String actuator;

  /// The operator drawn beside the poles: push, estop, selector, sel3, limit, timer, tor, mcb, mpcb, rcd, isolator.
  final String mark;

  bool get isContact => follows != null;
}

Map<String, Offset> _polePins(List<Pole> poles) {
  final pins = <String, Offset>{};
  for (var i = 0; i < poles.length; i++) {
    final p = poles[i];
    if (p.kind == PoleKind.co) {
      pins['${i + 1}1'] = Offset(p.x, 4);
      pins['${i + 1}2'] = Offset(p.x - 1, 0);
      pins['${i + 1}4'] = Offset(p.x + 1, 0);
    } else {
      pins['${2 * i + 1}'] = Offset(p.x, 0);
      pins['${2 * i + 2}'] = Offset(p.x, 4);
    }
  }
  return pins;
}

RelayType _switching(String id, String name, String category, String prefix, List<PoleKind> kinds,
    {String actuator = '', String mark = '', Set<String>? follows}) {
  final poles = <Pole>[];
  var x = 1.0;
  for (final k in kinds) {
    if (k == PoleKind.co) {
      poles.add(Pole(k, x + 1));
      x += 4;
    } else {
      poles.add(Pole(k, x));
      x += 2;
    }
  }
  final width = poles.map((p) => p.kind == PoleKind.co ? p.x + 2 : p.x + 1).reduce(math.max);
  return RelayType(id, name, category, prefix, Size(width, 4), _polePins(poles), follows: follows, poles: poles, actuator: actuator, mark: mark);
}

const _no = PoleKind.no, _nc = PoleKind.nc, _co = PoleKind.co, _fu = PoleKind.fuse, _el = PoleKind.element;
const _two = Size(2, 4);
const _coilPins = {'A1': Offset(1, 0), 'A2': Offset(1, 4)};
const _loadPins = {'1': Offset(1, 0), '2': Offset(1, 4)};

/// Coils whose contacts carry their tag.
const kRelayCoils = {'coil', 'relay_coil', 'impulse'};
const kRelayTimers = {'timer_on', 'timer_off', 'timer_cyc'};

/// Everything with an A1-A2 coil.
const kRelayCoilTypes = {...kRelayCoils, ...kRelayTimers};

/// Two-terminal loads that run on phase and neutral, two phases, or DC.
const kRelayLoads = {...kRelayCoilTypes, 'lamp', 'lamp_flash', 'buzzer', 'bell', 'siren', 'heater', 'valve', 'motor1'};

const kRelayMotors = {'motor1', 'motor3', 'motor3_6', 'motor_dahl', 'motor_dc'};

/// Every symbol BuildRelay offers, grouped as in its palette.
final List<RelayType> kRelayTypes = [
  // Supplies
  const RelayType('supply', 'Sumber', 'Sumber', '', Size(2, 2), {'1': Offset(1, 2)}),
  const RelayType('supply3', 'Sumber 3 fasa L1 L2 L3', 'Sumber', '', Size(6, 2), {'L1': Offset(1, 2), 'L2': Offset(3, 2), 'L3': Offset(5, 2)}),
  const RelayType('supply3n', 'Sumber 3 fasa + N', 'Sumber', '', Size(8, 2), {'L1': Offset(1, 2), 'L2': Offset(3, 2), 'L3': Offset(5, 2), 'N': Offset(7, 2)}),
  const RelayType('battery', 'Baterai / sumber DC', 'Sumber', 'GB', _two, {'+': Offset(1, 0), '-': Offset(1, 4)}),
  const RelayType('psu', 'Power supply 24 VDC', 'Sumber', 'G', Size(4, 4), {'L': Offset(1, 0), 'N': Offset(3, 0), '+': Offset(1, 4), '-': Offset(3, 4)}),
  const RelayType('transformer', 'Trafo kontrol', 'Sumber', 'T', Size(4, 4), {'P1': Offset(1, 0), 'P2': Offset(3, 0), 'S1': Offset(1, 4), 'S2': Offset(3, 4)}),
  // Buttons and switches
  _switching('push_no', 'Tombol tekan NO', 'Tombol & saklar', 'S', [_no], actuator: 'push', mark: 'push'),
  _switching('push_nc', 'Tombol tekan NC', 'Tombol & saklar', 'S', [_nc], actuator: 'push', mark: 'push'),
  _switching('push_nonc', 'Tombol tekan NO + NC', 'Tombol & saklar', 'S', [_no, _nc], actuator: 'push', mark: 'push'),
  _switching('push_co', 'Tombol tekan changeover', 'Tombol & saklar', 'S', [_co], actuator: 'push', mark: 'push'),
  _switching('estop', 'Tombol darurat NC', 'Tombol & saklar', 'S', [_nc], actuator: 'latch', mark: 'estop'),
  _switching('estop_nonc', 'Tombol darurat NO + NC', 'Tombol & saklar', 'S', [_no, _nc], actuator: 'latch', mark: 'estop'),
  _switching('selector_no', 'Selektor NO', 'Tombol & saklar', 'S', [_no], actuator: 'latch', mark: 'selector'),
  _switching('selector_nc', 'Selektor NC', 'Tombol & saklar', 'S', [_nc], actuator: 'latch', mark: 'selector'),
  _switching('selector_co', 'Selektor changeover', 'Tombol & saklar', 'S', [_co], actuator: 'latch', mark: 'selector'),
  _switching('selector3', 'Selektor 3 posisi (1-0-2)', 'Tombol & saklar', 'S', [_no, _no], actuator: 'sel3', mark: 'sel3'),
  _switching('limit_no', 'Limit switch NO', 'Tombol & saklar', 'SQ', [_no], actuator: 'limit', mark: 'limit'),
  _switching('limit_nc', 'Limit switch NC', 'Tombol & saklar', 'SQ', [_nc], actuator: 'limit', mark: 'limit'),
  _switching('limit_co', 'Limit switch changeover', 'Tombol & saklar', 'SQ', [_co], actuator: 'limit', mark: 'limit'),
  // Coils and contacts
  const RelayType('coil', 'Koil kontaktor', 'Kontaktor & relay', 'KM', _two, _coilPins),
  const RelayType('relay_coil', 'Koil relay', 'Kontaktor & relay', 'K', _two, _coilPins),
  const RelayType('impulse', 'Koil relay impuls (latching)', 'Kontaktor & relay', 'K', _two, _coilPins),
  for (final n in const [1, 2, 3, 4])
    _switching(n == 3 ? 'main3' : 'main$n', 'Kontak utama NO $n kutub', 'Kontaktor & relay', 'KM', List.filled(n, _no), actuator: 'coil', follows: kRelayCoils),
  for (final n in const [1, 2, 3, 4])
    _switching('mainnc$n', 'Kontak utama NC $n kutub', 'Kontaktor & relay', 'KM', List.filled(n, _nc), actuator: 'coil', follows: kRelayCoils),
  _switching('aux_no', 'Kontak bantu NO', 'Kontaktor & relay', 'KM', [_no], actuator: 'coil', follows: kRelayCoils),
  _switching('aux_nc', 'Kontak bantu NC', 'Kontaktor & relay', 'KM', [_nc], actuator: 'coil', follows: kRelayCoils),
  _switching('aux_nonc', 'Kontak bantu NO + NC', 'Kontaktor & relay', 'KM', [_no, _nc], actuator: 'coil', follows: kRelayCoils),
  _switching('aux_co', 'Kontak bantu changeover', 'Kontaktor & relay', 'KM', [_co], actuator: 'coil', follows: kRelayCoils),
  // Timers
  const RelayType('timer_on', 'Koil timer tunda nyala', 'Timer', 'KT', _two, _coilPins),
  const RelayType('timer_off', 'Koil timer tunda padam', 'Timer', 'KT', _two, _coilPins),
  const RelayType('timer_cyc', 'Koil timer kedip (flasher)', 'Timer', 'KT', _two, _coilPins),
  _switching('timer_no', 'Kontak timer NO', 'Timer', 'KT', [_no], actuator: 'timer', mark: 'timer', follows: kRelayTimers),
  _switching('timer_nc', 'Kontak timer NC', 'Timer', 'KT', [_nc], actuator: 'timer', mark: 'timer', follows: kRelayTimers),
  _switching('timer_co', 'Kontak timer changeover', 'Timer', 'KT', [_co], actuator: 'timer', mark: 'timer', follows: kRelayTimers),
  // Protection
  for (final n in const [1, 2, 3, 4]) _switching(n == 1 ? 'fuse' : 'fuse$n', 'Fuse $n kutub', 'Proteksi', 'FU', List.filled(n, _fu), actuator: 'breaker'),
  for (final n in const [1, 2, 3, 4]) _switching('mcb$n', 'MCB $n kutub', 'Proteksi', 'QF', List.filled(n, _no), actuator: 'breaker', mark: 'mcb'),
  _switching('mpcb3', 'MPCB (pengaman motor) 3 kutub', 'Proteksi', 'Q', [_no, _no, _no], actuator: 'breaker', mark: 'mpcb'),
  _switching('rcd2', 'RCD / ELCB 2 kutub', 'Proteksi', 'Q', [_no, _no], actuator: 'breaker', mark: 'rcd'),
  _switching('rcd4', 'RCD / ELCB 4 kutub', 'Proteksi', 'Q', [_no, _no, _no, _no], actuator: 'breaker', mark: 'rcd'),
  _switching('isolator3', 'Saklar pemisah 3 kutub', 'Proteksi', 'Q', [_no, _no, _no], actuator: 'breaker', mark: 'isolator'),
  _switching('tor', 'Overload relay (elemen 3 kutub)', 'Proteksi', 'F', [_el, _el, _el]),
  _switching('tor_nc', 'Kontak overload NC (95-96)', 'Proteksi', 'F', [_nc], actuator: 'tor', mark: 'tor', follows: {'tor'}),
  _switching('tor_no', 'Kontak overload NO (97-98)', 'Proteksi', 'F', [_no], actuator: 'tor', mark: 'tor', follows: {'tor'}),
  // Loads
  const RelayType('lamp', 'Lampu', 'Beban', 'H', _two, {'X1': Offset(1, 0), 'X2': Offset(1, 4)}),
  const RelayType('lamp_flash', 'Lampu kedip', 'Beban', 'H', _two, {'X1': Offset(1, 0), 'X2': Offset(1, 4)}),
  const RelayType('buzzer', 'Buzzer', 'Beban', 'HA', _two, _loadPins),
  const RelayType('bell', 'Bel', 'Beban', 'HA', _two, _loadPins),
  const RelayType('siren', 'Sirine / horn', 'Beban', 'HA', _two, _loadPins),
  const RelayType('heater', 'Heater', 'Beban', 'E', _two, _loadPins),
  const RelayType('valve', 'Solenoid valve', 'Beban', 'Y', _two, _loadPins),
  // Motors
  const RelayType('motor1', 'Motor 1 fasa', 'Motor', 'M', Size(4, 4), {'1': Offset(2, 0), '2': Offset(2, 4)}),
  const RelayType('motor3', 'Motor 3 fasa', 'Motor', 'M', Size(6, 6), {'U': Offset(1, 0), 'V': Offset(3, 0), 'W': Offset(5, 0)}),
  const RelayType('motor3_6', 'Motor 3 fasa 6 terminal (Y/Δ)', 'Motor', 'M', Size(6, 8),
      {'U1': Offset(1, 0), 'V1': Offset(3, 0), 'W1': Offset(5, 0), 'U2': Offset(1, 8), 'V2': Offset(3, 8), 'W2': Offset(5, 8)}),
  const RelayType('motor_dahl', 'Motor Dahlander 2 kecepatan', 'Motor', 'M', Size(6, 8),
      {'1U': Offset(1, 0), '1V': Offset(3, 0), '1W': Offset(5, 0), '2U': Offset(1, 8), '2V': Offset(3, 8), '2W': Offset(5, 8)}),
  const RelayType('motor_dc', 'Motor DC', 'Motor', 'M', Size(4, 4), {'+': Offset(2, 0), '-': Offset(2, 4)}),
  // Others
  const RelayType('earth', 'Ground (PE)', 'Lain-lain', '', Size(2, 2), {'1': Offset(1, 0)}),
  const RelayType('diode', 'Dioda', 'Lain-lain', 'V', _two, {'A': Offset(1, 0), 'K': Offset(1, 4)}),
  const RelayType('text', 'Teks', 'Lain-lain', '', Size(6, 1), {}),
  // A join in the middle of wires.
  const RelayType('node', 'Titik sambung', 'Lain-lain', '', Size.zero, {'1': Offset.zero}),
];

final Map<String, RelayType> kRelayTypeById = {for (final t in kRelayTypes) t.id: t};

/// Supply labels a supply symbol can carry.
const List<String> kRelaySupplies = ['L1', 'L2', 'L3', 'N', 'PE', 'DC+', 'DC-'];

class RelaySymbol {
  RelaySymbol({required this.id, required this.type, required this.tag, required this.x, required this.y, this.rotation = 0, Map<String, dynamic>? params})
      : params = params ?? {};

  final int id;
  final String type;
  String tag;
  int x;
  int y;

  /// Quarter turns clockwise, 0..3.
  int rotation;
  final Map<String, dynamic> params;

  RelayType get def => kRelayTypeById[type]!;

  /// Size in grid units after rotation.
  Size get size => rotation.isOdd ? Size(def.size.height, def.size.width) : def.size;

  /// A pin's position in grid units on the sheet.
  Offset pin(String name) {
    final p = def.pins[name]!;
    final w = def.size.width, h = def.size.height;
    final r = switch (rotation % 4) {
      1 => Offset(h - p.dy, p.dx),
      2 => Offset(w - p.dx, h - p.dy),
      3 => Offset(p.dy, w - p.dx),
      _ => p,
    };
    return Offset(x + r.dx, y + r.dy);
  }

  Rect get rect => Rect.fromLTWH(x.toDouble(), y.toDouble(), size.width, size.height);

  /// Supply label of a supply symbol.
  String get supply => params['supply'] is String ? params['supply'] as String : 'L1';

  /// Timer setting in seconds.
  double get seconds {
    final raw = params['seconds'] is num ? (params['seconds'] as num).toDouble() : 3.0;
    return raw.isFinite && raw > 0 ? raw : 3.0;
  }

  /// The words of a text symbol.
  String get text => params['text'] is String ? params['text'] as String : 'Teks';

  Map<String, dynamic> toJson() => {'id': id, 'type': type, 'tag': tag, 'x': x, 'y': y, if (rotation != 0) 'r': rotation, if (params.isNotEmpty) 'p': params};

  factory RelaySymbol.fromJson(Map<String, dynamic> json) => RelaySymbol(
        id: (json['id'] as num).toInt(),
        type: json['type'] as String,
        tag: json['tag'] as String? ?? '',
        x: (json['x'] as num).toInt(),
        y: (json['y'] as num).toInt(),
        rotation: (json['r'] as num?)?.toInt() ?? 0,
        params: (json['p'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(
              k,
              switch (k) {
                'supply' || 'text' => v as String?,
                'seconds' => v as num?,
                _ => v,
              },
            )),
      );
}

/// One end of a wire: a pin of a symbol.
class RelayEnd {
  const RelayEnd(this.symbol, this.pin);

  final int symbol;
  final String pin;

  String get key => '$symbol:$pin';

  @override
  bool operator ==(Object other) => other is RelayEnd && other.symbol == symbol && other.pin == pin;

  @override
  int get hashCode => Object.hash(symbol, pin);
}

class RelayWire {
  RelayWire({required this.id, required this.a, required this.b, List<Offset>? bends}) : bends = bends ?? [];

  final int id;
  final RelayEnd a;
  final RelayEnd b;

  /// Bend points in grid units, placed while drawing.
  final List<Offset> bends;

  bool touches(int symbol) => a.symbol == symbol || b.symbol == symbol;

  Map<String, dynamic> toJson() => {
        'id': id,
        'a': [a.symbol, a.pin],
        'b': [b.symbol, b.pin],
        if (bends.isNotEmpty) 'k': [for (final p in bends) [p.dx, p.dy]],
      };

  factory RelayWire.fromJson(Map<String, dynamic> json) {
    RelayEnd end(List<dynamic> v) => RelayEnd((v[0] as num).toInt(), '${v[1]}');
    return RelayWire(
      id: (json['id'] as num).toInt(),
      a: end(json['a'] as List<dynamic>),
      b: end(json['b'] as List<dynamic>),
      bends: [for (final p in json['k'] as List<dynamic>? ?? const []) Offset(((p as List)[0] as num).toDouble(), (p[1] as num).toDouble())],
    );
  }
}

class RelaySheet {
  RelaySheet({List<RelaySymbol>? symbols, List<RelayWire>? wires})
      : symbols = symbols ?? [],
        wires = wires ?? [];

  /// Canvas pixels per grid unit at 100% zoom.
  static const double unit = 20;

  final List<RelaySymbol> symbols;
  final List<RelayWire> wires;

  int nextId() => [0, ...symbols.map((s) => s.id), ...wires.map((w) => w.id)].reduce(math.max) + 1;

  RelaySymbol? symbol(int id) => symbols.where((s) => s.id == id).firstOrNull;

  Offset endPoint(RelayEnd end) => symbol(end.symbol)!.pin(end.pin);

  /// A wire's path in grid units: through its bends, turning vertically first at each, as it was drawn.
  List<Offset> path(RelayWire wire) {
    final points = <Offset>[endPoint(wire.a)];
    for (final next in [...wire.bends, endPoint(wire.b)]) {
      final last = points.last;
      if ((last.dx - next.dx).abs() > 0.001 && (last.dy - next.dy).abs() > 0.001) points.add(Offset(last.dx, next.dy));
      points.add(next);
    }
    return points;
  }

  /// The next free tag with this prefix: KM1, KM2 …
  String nextTag(String prefix) {
    if (prefix.isEmpty) return '';
    var n = 1;
    while (symbols.any((s) => s.tag == '$prefix$n' && !s.def.isContact)) {
      n++;
    }
    return '$prefix$n';
  }

  Map<String, dynamic> toJson() => {
        'format': 'buildrelay/1',
        'symbols': [for (final s in symbols) s.toJson()],
        'wires': [for (final w in wires) w.toJson()],
      };

  factory RelaySheet.fromJson(Map<String, dynamic> json) {
    if (json['format'] != 'buildrelay/1') throw const FormatException('Bukan file BuildRelay.');
    try {
      final symbols = [
        for (final s in (json['symbols'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>())
          if (kRelayTypeById.containsKey(s['type'])) RelaySymbol.fromJson(s),
      ];
      final byId = <int, RelaySymbol>{};
      for (final s in symbols) {
        if (byId.containsKey(s.id)) throw const FormatException('File BuildRelay rusak.');
        byId[s.id] = s;
      }
      final wires = [
        for (final w in (json['wires'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>()) RelayWire.fromJson(w),
      ]
          .where((w) =>
              (byId[w.a.symbol]?.def.pins.containsKey(w.a.pin) ?? false) &&
              (byId[w.b.symbol]?.def.pins.containsKey(w.b.pin) ?? false))
          .toList();
      return RelaySheet(symbols: symbols, wires: wires);
    } on TypeError {
      throw const FormatException('File BuildRelay rusak.');
    } on RangeError {
      throw const FormatException('File BuildRelay rusak.');
    } on UnsupportedError {
      throw const FormatException('File BuildRelay rusak.');
    }
  }
}

// ----------------------------------------------------------------------------------------------------------- simulation

/// What the simulation found at one moment.
class RelayResult {
  const RelayResult({
    required this.labels,
    required this.closed,
    required this.actuated,
    required this.energized,
    required this.loadsOn,
    required this.motors,
    required this.motorModes,
    required this.short,
    required this.warnings,
  });

  /// Supply label of the net each pin is on ('L1', 'N' …), keyed by [RelayEnd.key]; missing means dead.
  final Map<String, String> labels;

  /// Symbols with at least one pole conducting, by id.
  final Set<int> closed;

  /// For switching symbols: whether each pole is operated (pressed, pulled in, timed out, switched on).
  final Map<int, List<bool>> actuated;

  /// Tags of coils and timer coils that have voltage.
  final Set<String> energized;

  /// Lamps, buzzers, coils and other loads that are on, by symbol id.
  final Set<int> loadsOn;

  /// Motors that run: 1 forward, -1 reverse.
  final Map<int, int> motors;

  /// How a running motor is connected: 'Y' or 'Δ' for a six-terminal motor, '1' or '2' for the speeds of a
  /// Dahlander motor.
  final Map<int, String> motorModes;

  /// A short circuit no breaker or fuse could clear.
  final bool short;
  final List<String> warnings;
}

/// Runs a BuildRelay sheet. Holds what the user operated and the timers; [solve] works out the rest.
class RelaySim {
  RelaySim(this.sheet);

  final RelaySheet sheet;

  /// Push buttons and limit switches held down, by symbol id.
  final Set<int> pressed = {};

  /// Latching switches turned (selectors, emergency stops, limit switches set by a click), by symbol id.
  final Set<int> toggled = {};

  /// Positions of three-position selectors (0 middle, 1 left, 2 right), by symbol id.
  final Map<int, int> positions = {};

  /// Breakers switched off or tripped, and blown fuses, by symbol id.
  final Set<int> open = {};

  /// Overload relays tripped, by tag.
  final Set<String> tripped = {};

  /// Since when each timer coil has had voltage, and since when it lost it, in simulation seconds.
  final Map<String, double> _onSince = {};
  final Map<String, double> _offSince = {};

  /// Impulse relays that are latched in.
  final Set<String> _latched = {};

  Set<String> _energized = {};
  final List<String> events = [];

  /// Seconds a timer has counted, or null when it is not counting.
  double? timerElapsed(String tag, double now) {
    final timer = _timer(tag);
    if (timer == null) return null;
    if (timer.type == 'timer_off') return _offSince[tag] == null ? null : now - _offSince[tag]!;
    if (_onSince[tag] == null) return null;
    final t = now - _onSince[tag]!;
    return timer.type == 'timer_cyc' ? t % timer.seconds : t;
  }

  RelaySymbol? _timer(String tag) => sheet.symbols.where((s) => kRelayTimers.contains(s.type) && s.tag == tag).firstOrNull;

  bool _timerOut(String tag, Set<String> energized, double now) {
    final timer = _timer(tag);
    if (timer == null) return false;
    final on = energized.contains(tag);
    switch (timer.type) {
      case 'timer_on':
        final since = _onSince[tag];
        return on && since != null && now - since >= timer.seconds;
      case 'timer_cyc':
        // Flasher: on for the set time, off for the set time, starting on.
        final since = _onSince[tag] ?? now;
        return on && ((now - since) / timer.seconds).floor().isEven;
      default:
        // Off-delay: closes with the coil, opens a set time after it loses voltage.
        if (on) return true;
        final since = _offSince[tag];
        return since != null && now - since < timer.seconds;
    }
  }

  bool _isImpulse(String tag) => sheet.symbols.any((s) => s.type == 'impulse' && s.tag == tag);

  /// Whether a coil's contacts are pulled in: an ordinary coil while it has voltage, an impulse relay from one pulse
  /// to the next.
  bool _coilOn(String tag, Set<String> energized) {
    if (!_isImpulse(tag)) return energized.contains(tag);
    final pulse = energized.contains(tag) && !_energized.contains(tag);
    return _latched.contains(tag) != pulse;
  }

  /// Whether each pole of a switching symbol is operated.
  List<bool> _actuated(RelaySymbol s, Set<String> energized, double now) {
    final n = s.def.poles.length;
    if (s.def.actuator == 'sel3') {
      final position = positions[s.id] ?? 0;
      return [for (var i = 0; i < n; i++) position == i + 1];
    }
    final held = pressed.contains(s.id), turned = toggled.contains(s.id);
    final value = switch (s.def.actuator) {
      'push' => held,
      'latch' => turned,
      'limit' => held || turned,
      'coil' => _coilOn(s.tag, energized),
      'timer' => _timerOut(s.tag, energized, now),
      'tor' => tripped.contains(s.tag),
      'breaker' => !open.contains(s.id),
      _ => false,
    };
    return List.filled(n, value);
  }

  /// Pairs of pins a switching symbol joins, given which poles are operated.
  static List<(String, String)> _poleLinks(RelaySymbol s, List<bool> on) {
    final links = <(String, String)>[];
    final poles = s.def.poles;
    for (var i = 0; i < poles.length; i++) {
      final top = '${2 * i + 1}', bottom = '${2 * i + 2}';
      switch (poles[i].kind) {
        case PoleKind.no || PoleKind.fuse:
          if (on[i]) links.add((top, bottom));
        case PoleKind.nc:
          if (!on[i]) links.add((top, bottom));
        case PoleKind.element:
          links.add((top, bottom));
        case PoleKind.co:
          links.add(('${i + 1}1', on[i] ? '${i + 1}4' : '${i + 1}2'));
      }
    }
    return links;
  }

  /// Joins pins into nets and labels them with the supplies on them.
  (Map<String, String> roots, Map<String, Set<String>> labels) _nets(Map<int, List<(String, String)>> links, Map<String, String> outputs, {int? without}) {
    final parent = <String, String>{};
    String find(String k) {
      var root = k;
      while (parent[root] != null && parent[root] != root) {
        root = parent[root]!;
      }
      var node = k;
      while (parent[node] != null && parent[node] != root) {
        final next = parent[node]!;
        parent[node] = root;
        node = next;
      }
      return root;
    }

    void union(String a, String b) {
      parent.putIfAbsent(a, () => a);
      parent.putIfAbsent(b, () => b);
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[ra] = rb;
    }

    for (final w in sheet.wires) {
      union(w.a.key, w.b.key);
    }
    for (final entry in links.entries) {
      if (entry.key == without) continue;
      for (final (a, b) in entry.value) {
        union('${entry.key}:$a', '${entry.key}:$b');
      }
    }
    final labels = <String, Set<String>>{};
    void label(String key, String value) {
      parent.putIfAbsent(key, () => key);
      labels.putIfAbsent(find(key), () => {}).add(value);
    }

    for (final s in sheet.symbols) {
      switch (s.type) {
        case 'supply':
          label('${s.id}:1', s.supply);
        case 'supply3' || 'supply3n':
          for (final pin in s.def.pins.keys) {
            label('${s.id}:$pin', pin);
          }
        case 'battery':
          label('${s.id}:+', 'DC+');
          label('${s.id}:-', 'DC-');
        case 'earth':
          label('${s.id}:1', 'PE');
      }
    }
    for (final entry in outputs.entries) {
      label(entry.key, entry.value);
    }
    final roots = {for (final k in parent.keys.toList()) k: find(k)};
    return (roots, labels);
  }

  /// Two supplies on one net: phase against neutral or another phase, DC+ against DC-, or a phase or DC+ to earth.
  static bool _conflict(Set<String> labels) {
    final live = labels.where((l) => l != 'PE').toSet();
    if (live.length > 1) return true;
    return labels.contains('PE') && live.any((l) => _phase(l) || l == 'DC+');
  }

  /// Works out the state of the sheet at simulation time [now] (seconds). Breakers that clear a short are tripped
  /// and stay open. Call it again whenever something is operated or time passes.
  RelayResult solve(double now) {
    final warnings = <String>[];
    var energized = _energized;
    var diodes = <int>{};
    var sources = <int>{};
    var short = false;
    late Map<String, String> roots;
    late Map<String, Set<String>> labels;
    late Map<int, List<bool>> actuated;
    late Map<int, List<(String, String)>> links;
    var settled = false;
    for (var round = 0; round < 60; round++) {
      actuated = {for (final s in sheet.symbols) if (s.def.poles.isNotEmpty) s.id: _actuated(s, energized, now)};
      links = {
        for (final s in sheet.symbols)
          if (s.def.poles.isNotEmpty) s.id: _poleLinks(s, actuated[s.id]!),
        for (final id in diodes) id: const [('A', 'K')],
      };
      final outputs = <String, String>{};
      for (final id in sources) {
        final s = sheet.symbol(id)!;
        if (s.type == 'psu') {
          outputs['$id:+'] = 'DC+';
          outputs['$id:-'] = 'DC-';
        } else {
          outputs['$id:S1'] = 'T${id}a';
          outputs['$id:S2'] = 'T${id}b';
        }
      }
      (roots, labels) = _nets(links, outputs);
      if (labels.values.any(_conflict)) {
        // A short trips the first breaker or fuse whose opening clears it; an earth fault goes to an RCD first.
        final earthFault = labels.values.any((l) => _conflict(l) && l.contains('PE'));
        int rank(RelaySymbol s) => earthFault && s.def.mark == 'rcd' ? 0 : 1;
        final candidates = sheet.symbols.where((s) => s.def.actuator == 'breaker' && s.def.mark != 'isolator' && !open.contains(s.id)).toList()
          ..sort((a, b) => rank(a) - rank(b));
        RelaySymbol? clears;
        for (final s in candidates) {
          final (_, test) = _nets(links, outputs, without: s.id);
          if (!test.values.any(_conflict)) {
            clears = s;
            break;
          }
        }
        if (clears == null) {
          short = true;
          break;
        }
        open.add(clears.id);
        final what = clears.def.poles.first.kind == PoleKind.fuse ? 'putus' : 'trip';
        events.add('${clears.tag} $what karena ${earthFault && clears.def.mark == 'rcd' ? 'arus bocor ke tanah' : 'korsleting'}.');
        continue;
      }
      String? labelOf(RelaySymbol s, String pin) {
        final root = roots['${s.id}:$pin'];
        final set = root == null ? null : labels[root];
        return set == null || set.isEmpty ? null : set.first;
      }

      final next = <String>{};
      final nextDiodes = <int>{};
      final nextSources = <int>{};
      for (final s in sheet.symbols) {
        switch (s.type) {
          case 'coil' || 'relay_coil' || 'impulse' || 'timer_on' || 'timer_off' || 'timer_cyc':
            if (_powered(labelOf(s, 'A1'), labelOf(s, 'A2'))) next.add(s.tag);
          case 'diode':
            if (labelOf(s, 'A') == 'DC+' || labelOf(s, 'K') == 'DC-') nextDiodes.add(s.id);
          case 'psu':
            if (_powered(labelOf(s, 'L'), labelOf(s, 'N'))) nextSources.add(s.id);
          case 'transformer':
            if (_powered(labelOf(s, 'P1'), labelOf(s, 'P2'))) nextSources.add(s.id);
        }
      }
      bool same<T>(Set<T> a, Set<T> b) => a.length == b.length && a.containsAll(b);
      if (same(next, energized) && same(nextDiodes, diodes) && same(nextSources, sources)) {
        settled = true;
        break;
      }
      energized = next;
      diodes = nextDiodes;
      sources = nextSources;
    }
    if (!settled && !short) warnings.add('Rangkaian tidak stabil: ada koil yang terus berganti nyala dan padam.');

    // Impulse relays change over on each pulse.
    for (final s in sheet.symbols.where((s) => s.type == 'impulse')) {
      if (energized.contains(s.tag) && !_energized.contains(s.tag)) {
        _latched.contains(s.tag) ? _latched.remove(s.tag) : _latched.add(s.tag);
      }
    }
    // Timers start and stop counting as their coils gain and lose voltage.
    for (final s in sheet.symbols.where((s) => kRelayTimers.contains(s.type))) {
      final on = energized.contains(s.tag), was = _energized.contains(s.tag);
      if (on && !was) {
        _onSince[s.tag] = now;
        _offSince.remove(s.tag);
      } else if (!on && was) {
        _onSince.remove(s.tag);
        if (s.type == 'timer_off') _offSince[s.tag] = now;
      }
      final off = _offSince[s.tag];
      if (off != null && now - off >= s.seconds + 0.5) _offSince.remove(s.tag);
    }
    _energized = energized;

    final pinLabels = <String, String>{};
    for (final entry in roots.entries) {
      final set = labels[entry.value];
      if (set != null && set.isNotEmpty) pinLabels[entry.key] = set.length == 1 ? set.first : 'short';
    }
    String? at(RelaySymbol s, String pin) => pinLabels['${s.id}:$pin'];
    String? root(RelaySymbol s, String pin) => roots['${s.id}:$pin'];
    const order = ['L1', 'L2', 'L3'];
    int? direction(String? u, String? v, String? w) {
      final phases = [u, v, w];
      if (!phases.every(_phase) || phases.toSet().length != 3) return null;
      return (order.indexOf(v!) - order.indexOf(u!) + 3) % 3 == 1 ? 1 : -1;
    }

    bool joined(RelaySymbol s, List<String> pins) =>
        pins.every((p) => at(s, p) == null && root(s, p) != null) && pins.map((p) => root(s, p)).toSet().length == 1;

    final loadsOn = <int>{};
    final motors = <int, int>{};
    final modes = <int, String>{};
    for (final s in sheet.symbols) {
      if (kRelayLoads.contains(s.type)) {
        final pins = s.def.pins.keys.toList();
        final a = at(s, pins[0]), b = at(s, pins[1]);
        if (kRelayCoilTypes.contains(s.type) ? energized.contains(s.tag) : _powered(a, b)) {
          loadsOn.add(s.id);
          if (s.type == 'motor1') motors[s.id] = 1;
        }
        if (_phase(a) && _phase(b) && a != b && s.type != 'motor1') warnings.add('${s.tag}: kena tegangan antar fasa (400 V).');
        continue;
      }
      switch (s.type) {
        case 'motor3':
          final dir = direction(at(s, 'U'), at(s, 'V'), at(s, 'W'));
          if (dir != null) {
            motors[s.id] = dir;
          } else if ([at(s, 'U'), at(s, 'V'), at(s, 'W')].where(_phase).length == 2) {
            warnings.add('${s.tag}: hanya dapat dua fasa, motor tidak bisa jalan.');
          }
        case 'motor3_6':
          final dir = direction(at(s, 'U1'), at(s, 'V1'), at(s, 'W1'));
          if (dir == null) break;
          final star = joined(s, const ['U2', 'V2', 'W2']);
          final delta = at(s, 'U2') == at(s, 'V1') && at(s, 'V2') == at(s, 'W1') && at(s, 'W2') == at(s, 'U1') ||
              at(s, 'U2') == at(s, 'W1') && at(s, 'V2') == at(s, 'U1') && at(s, 'W2') == at(s, 'V1');
          if (star || delta) {
            motors[s.id] = dir;
            modes[s.id] = star ? 'Y' : 'Δ';
          } else {
            warnings.add('${s.tag}: ujung belitan U2 V2 W2 belum disambung bintang atau segitiga.');
          }
        case 'motor_dahl':
          final low = direction(at(s, '1U'), at(s, '1V'), at(s, '1W'));
          final high = direction(at(s, '2U'), at(s, '2V'), at(s, '2W'));
          if (high != null && joined(s, const ['1U', '1V', '1W'])) {
            motors[s.id] = high;
            modes[s.id] = '2';
          } else if (low != null && [at(s, '2U'), at(s, '2V'), at(s, '2W')].every((e) => e == null)) {
            motors[s.id] = low;
            modes[s.id] = '1';
          } else if (high != null) {
            warnings.add('${s.tag}: untuk kecepatan tinggi, 1U 1V 1W harus dihubung singkat.');
          }
        case 'motor_dc':
          final a = at(s, '+'), b = at(s, '-');
          if ({a, b}.containsAll(const {'DC+', 'DC-'}) && a != b) motors[s.id] = a == 'DC+' ? 1 : -1;
      }
    }
    // Contacts whose tag has no coil, timer or overload relay to follow.
    for (final s in sheet.symbols.where((s) => s.def.isContact)) {
      final follows = s.def.follows!;
      if (!sheet.symbols.any((o) => follows.contains(o.type) && o.tag == s.tag)) {
        final owner = follows.contains('tor') ? 'overload relay' : follows.contains('timer_on') ? 'timer' : 'koil';
        warnings.add('Kontak ${s.tag.isEmpty ? '(tanpa tag)' : s.tag}: tidak ada $owner dengan tag itu.');
      }
    }
    return RelayResult(
      labels: pinLabels,
      closed: {for (final e in links.entries) if (e.value.isNotEmpty) e.key},
      actuated: actuated,
      energized: energized,
      loadsOn: loadsOn,
      motors: motors,
      motorModes: modes,
      short: short,
      warnings: warnings.toSet().toList(),
    );
  }

  /// Whether a timer is counting, so the simulation must keep solving as time passes.
  bool get ticking => _onSince.isNotEmpty || _offSince.isNotEmpty;

  static bool _phase(String? label) => label == 'L1' || label == 'L2' || label == 'L3';

  /// A two-terminal load with these supplies on its ends has voltage: phase and neutral, two phases, DC+ and DC-, or
  /// the two ends of a transformer secondary.
  static bool _powered(String? a, String? b) {
    if (a == null || b == null || a == b || a == 'short' || b == 'short') return false;
    if (_phase(a) && (b == 'N' || _phase(b))) return true;
    if (_phase(b) && a == 'N') return true;
    if (a.startsWith('T') && b.startsWith('T') && a.substring(0, a.length - 1) == b.substring(0, b.length - 1)) return true;
    return {a, b}.containsAll(const {'DC+', 'DC-'});
  }
}
