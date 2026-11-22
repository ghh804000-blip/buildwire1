import 'project.dart';

/// Definition of a device type from `assets/devices/index.json`. Free of Flutter imports so the solver can be tested alone.
class TerminalDef {
  const TerminalDef(this.id, this.x, this.y, this.side, this.wiringClass);

  final String id;

  /// Position as a fraction of device width and height.
  final double x;
  final double y;
  final String side;
  final String wiringClass;

  factory TerminalDef.fromJson(Map<String, dynamic> json) => TerminalDef(
        json['id'] as String,
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
        json['side'] as String,
        json['class'] as String,
      );
}

class ContactDef {
  const ContactDef(this.a, this.b, this.closedIn);

  final String a;
  final String b;
  final List<String> closedIn;

  factory ContactDef.fromJson(Map<String, dynamic> json) =>
      ContactDef(json['a'] as String, json['b'] as String, (json['closed'] as List<dynamic>).cast<String>());
}

/// A value people can change on a placed device.
class ControlDef {
  const ControlDef(this.key, this.label, this.unit, this.min, this.max, this.fallback, this.live);

  final String key;
  final String label;
  final String unit;
  final double min;
  final double max;
  final double fallback;

  /// Can be changed while the simulation runs.
  final bool live;

  factory ControlDef.fromJson(Map<String, dynamic> json) => ControlDef(
        json['key'] as String,
        json['label'] as String,
        json['unit'] as String,
        (json['min'] as num).toDouble(),
        (json['max'] as num).toDouble(),
        (json['default'] as num).toDouble(),
        json['live'] as bool? ?? false,
      );
}

/// A coil or load: two terminals and the supply it expects.
class RatedPair {
  const RatedPair(this.a, this.b, this.volts, this.supply);

  final String a;
  final String b;
  final num volts;
  final String supply;

  factory RatedPair.fromJson(Map<String, dynamic> json) =>
      RatedPair(json['a'] as String, json['b'] as String, json['volts'] as num, json['supply'] as String);
}

const List<String> kDefaultPlcInputs = ['I1', 'I2', 'I3', 'I4', 'I5', 'I6', 'I7', 'I8'];
const List<String> kDefaultPlcOutputs = ['Q1', 'Q2', 'Q3', 'Q4'];

class DeviceDef {
  const DeviceDef({
    required this.id,
    required this.name,
    required this.designator,
    required this.category,
    required this.categoryLabel,
    this.group,
    required this.widthMm,
    required this.heightMm,
    required this.ratings,
    required this.terminals,
    required this.states,
    required this.defaultState,
    required this.behavior,
    required this.sounds,
    required this.loopSounds,
    required this.isSymbol,
    required this.isRaster,
    required this.isBackLayer,
    required this.license,
    required this.source,
  });

  final String id;
  final String name;
  final String designator;
  final String category;
  final String? categoryLabel;

  /// Library group, finer than the category: MCB, MCCB, Kontaktor, ...
  final String? group;
  final double widthMm;
  final double heightMm;
  final Map<String, dynamic> ratings;
  final List<TerminalDef> terminals;
  final List<String> states;
  final String defaultState;
  final Map<String, dynamic> behavior;
  final Map<String, String> sounds;

  /// Continuous sound played while the device is in a given state.
  final Map<String, String> loopSounds;
  final bool isSymbol;
  final bool isRaster;
  final bool isBackLayer;
  final String? license;
  final String? source;

  /// Canvas pixels per millimetre at 100% zoom.
  static const double pxPerMm = 4;

  double get width => widthMm * pxPerMm;
  double get height => heightMm * pxPerMm;
  String get kind => behavior['kind'] as String;
  bool get isProtective => behavior['protective'] == true;
  bool get isSimulated => !isSymbol && kind != 'structural';
  double get defaultTime => (behavior['default_time_s'] as num?)?.toDouble() ?? 3;
  bool get isTimer => kind == 'timer_on' || kind == 'timer_off';

  /// A branch point on a wire, not a part: hidden from the library, the bill of materials and routing obstacles.
  bool get isJunction => kind == 'junction';

  /// A digital timer's display, LEDs and keys on its photo.
  Map<String, dynamic>? get timerPanel => behavior['timer_panel'] as Map<String, dynamic>?;

  /// The working front of a thermal overload relay: TEST, STOP and RESET areas and the current dial.
  Map<String, dynamic>? get torPanel => behavior['tor_panel'] as Map<String, dynamic>?;

  /// An analog timer's turnable knob: centre, radius and the time range it covers.
  Map<String, dynamic>? get knob => behavior['knob'] as Map<String, dynamic>?;

  bool get isOverloadRelay => group == 'Overload relay (TOR)';
  bool get isContactor => group == 'Kontaktor';

  /// The same part drawn [factor] times its catalogue size. Terminals are placed as fractions, so they follow.
  DeviceDef scaled(double factor) => DeviceDef(
        id: id,
        name: name,
        designator: designator,
        category: category,
        categoryLabel: categoryLabel,
        group: group,
        widthMm: widthMm * factor,
        heightMm: heightMm * factor,
        ratings: ratings,
        terminals: terminals,
        states: states,
        defaultState: defaultState,
        behavior: behavior,
        sounds: sounds,
        loopSounds: loopSounds,
        isSymbol: isSymbol,
        isRaster: isRaster,
        isBackLayer: isBackLayer,
        license: license,
        source: source,
      );

  bool get isDinRail => group == 'Rel DIN';

  /// Paint order: panel boxes first, then rails, then everything else.
  int get layerRank => !isBackLayer ? 2 : (isDinRail ? 1 : 0);

  List<ContactDef> get contacts => [
        for (final contact in behavior['contacts'] as List<dynamic>? ?? const [])
          ContactDef.fromJson(contact as Map<String, dynamic>),
      ];

  Map<String, String> get outputs => (behavior['outputs'] as Map<String, dynamic>? ?? const {}).cast<String, String>();

  RatedPair? get coil => behavior['coil'] == null ? null : RatedPair.fromJson(behavior['coil'] as Map<String, dynamic>);
  RatedPair? get load => behavior['load'] == null ? null : RatedPair.fromJson(behavior['load'] as Map<String, dynamic>);
  RatedPair? get input => behavior['input'] == null ? null : RatedPair.fromJson(behavior['input'] as Map<String, dynamic>);
  double get minRatio => (behavior['min_ratio'] as num?)?.toDouble() ?? 0.35;
  bool get isAdjustable => behavior['adjustable'] == true;

  /// A DC supply's output voltage: its own setting, its rating, or 24 V.
  double get dcVolts => (behavior['dc_volts'] as num?)?.toDouble() ?? (ratings['voltage_v'] as num?)?.toDouble() ?? 24;
  double? get ratedPower => (ratings['power_w'] as num?)?.toDouble();
  double? get ratedCurrent => (ratings['rated_current_a'] as num?)?.toDouble();
  Map<String, dynamic>? get thermal => behavior['thermal'] as Map<String, dynamic>?;

  /// Where a spinning rotor is drawn, as fractions of the device: cx, cy, r (of width), and its style.
  Map<String, dynamic>? get rotor => behavior['rotor'] as Map<String, dynamic>?;

  /// Where a live waveform is drawn on a source, as [x, y, width, height] fractions.
  List<double>? get wave => (behavior['wave'] as List<dynamic>?)?.map((v) => (v as num).toDouble()).toList();

  /// Where a lamp glows, as fractions: cx, cy, r (of width), and color.
  Map<String, dynamic>? get glow => behavior['glow'] as Map<String, dynamic>?;

  List<ControlDef> get controls => [
        for (final control in behavior['controls'] as List<dynamic>? ?? const []) ControlDef.fromJson(control as Map<String, dynamic>),
      ];

  /// Load impedance from rated power. Coils and electronics default to a small draw.
  double impedance(PlacedDevice device, RatedPair rated) {
    final volts = rated.volts.isFinite && rated.volts > 0 ? rated.volts : 230.0;
    final rawWatts = device.number('power_w', ratedPower ?? 15);
    final watts = rawWatts.isFinite && rawWatts > 0 ? rawWatts : 15.0;
    return volts * volts / watts;
  }
  Map<String, dynamic>? get meter => behavior['meter'] as Map<String, dynamic>?;

  /// A working keypad and screen on the device itself (a PLC), with each key's place on the photo.
  Map<String, dynamic>? get panel => behavior['panel'] as Map<String, dynamic>?;

  /// The PLC's own address list (Zelio models carry one; the LOGO uses the defaults).
  Map<String, dynamic>? get _plc => behavior['plc'] as Map<String, dynamic>?;
  bool get isZelio => _plc?['family'] == 'zelio';
  List<String> get plcInputs => [for (final v in _plc?['inputs'] as List<dynamic>? ?? kDefaultPlcInputs) '$v'];
  List<String> get plcOutputs => [for (final k in (_plc?['outputs'] as Map<String, dynamic>?)?.keys ?? kDefaultPlcOutputs) k];

  /// The two terminals an output relay switches, when the PLC lists them.
  List<String>? plcOutputPair(String output) {
    final pair = (_plc?['outputs'] as Map<String, dynamic>?)?[output] as List<dynamic>?;
    return pair == null ? null : [for (final t in pair) '$t'];
  }

  /// Display windows on a meter: where each sits, how it looks and what it shows.
  List<Map<String, dynamic>> get meterScreens {
    final m = meter;
    if (m == null) return const [];
    final screens = m['screens'] as List<dynamic>?;
    if (screens != null) return screens.cast<Map<String, dynamic>>();
    if (m['screen'] == null) return const [];
    return [
      {'rect': m['screen'], 'lines': m['show'] ?? const ['V']},
    ];
  }

  /// Terminal pairs whose voltage a meter shows on its own line, as "L1-L2".
  Set<String> get meterChannels => {
        for (final screen in meterScreens)
          for (final line in (screen['lines'] as List<dynamic>? ?? const []).cast<String>())
            for (final field in line.split('|'))
              if (field.startsWith('V:')) field.substring(2),
      };
  Map<String, dynamic>? get operate => behavior['operate'] as Map<String, dynamic>?;
  String? get operateHint => behavior['operate_hint'] as String?;

  bool get isHold => operate?['type'] == 'hold';
  bool get isClickable => operate?['type'] == 'click';

  String assetFor(String state) {
    if (isSymbol) return 'assets/symbols/$id.svg';
    // A PLC's state also carries its bits, as in "run:Q1,M2".
    final base = state.split(':').first;
    final key = states.contains(base) ? base : defaultState;
    // Check art type for file extension
    if (isRaster) return 'assets/devices/${id}__$key.webp';
    return 'assets/devices/${id}__$key.svg';
  }

  /// Library thumbnail: `<id>__preview.webp` when the device ships one (raster art only).
  String? get previewAsset => isRaster ? 'assets/devices/${id}__preview.webp' : null;

  factory DeviceDef.fromJson(Map<String, dynamic> json) {
    final size = json['size_mm'] as Map<String, dynamic>;
    return DeviceDef(
      id: json['id'] as String,
      name: json['name_id'] as String? ?? json['name'] as String,
      designator: json['designator'] as String,
      category: json['category'] as String,
      categoryLabel: json['category_label'] as String?,
      group: json['group'] as String?,
      widthMm: (size['width'] as num).toDouble(),
      heightMm: (size['height'] as num).toDouble(),
      ratings: json['ratings'] as Map<String, dynamic>,
      terminals: [
        for (final terminal in json['terminals'] as List<dynamic>) TerminalDef.fromJson(terminal as Map<String, dynamic>),
      ],
      states: (json['states'] as Map<String, dynamic>).keys.toList(),
      defaultState: json['default_state'] as String,
      behavior: json['behavior'] as Map<String, dynamic>,
      sounds: (json['sounds'] as Map<String, dynamic>).cast<String, String>(),
      loopSounds: (json['loop_sounds'] as Map<String, dynamic>? ?? const {}).cast<String, String>(),
      isSymbol: json['art'] == 'symbol',
      isRaster: json['raster'] as bool? ?? false,
      // Rails and panel boxes sit behind everything mounted on them.
      isBackLayer: json['layer'] == 'back' || (json['behavior'] as Map<String, dynamic>)['kind'] == 'structural',
      license: json['license'] as String?,
      source: json['source'] as String?,
    );
  }
}
