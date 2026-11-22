/// A saved circuit: placed devices and the wires and jumpers between their terminals.
class TerminalRef {
  const TerminalRef(this.deviceId, this.terminal);

  final int deviceId;
  final String terminal;

  String get key => '$deviceId:$terminal';

  @override
  bool operator ==(Object other) => other is TerminalRef && other.key == key;

  @override
  int get hashCode => key.hashCode;

  Map<String, dynamic> toJson() => {'device': deviceId, 'terminal': terminal};

  factory TerminalRef.fromJson(Map<String, dynamic> json) => TerminalRef(json['device'] as int, json['terminal'] as String);
}

class PlacedDevice {
  PlacedDevice({required this.id, required this.defId, required this.tag, required this.x, required this.y, this.timeSeconds, Map<String, dynamic>? data}) : data = data ?? {};

  final int id;
  final String defId;
  String tag;
  double x;
  double y;

  /// Timer setting, for timer devices only.
  double? timeSeconds;

  /// Device settings: control values, a PLC's `program`, an HMI's `widgets`.
  final Map<String, dynamic> data;

  double number(String key, double fallback) => (data[key] as num?)?.toDouble() ?? fallback;

  Map<String, dynamic> toJson() => {'id': id, 'def': defId, 'tag': tag, 'x': x, 'y': y, if (timeSeconds != null) 'time': timeSeconds, if (data.isNotEmpty) 'data': data};

  factory PlacedDevice.fromJson(Map<String, dynamic> json) => PlacedDevice(
        id: json['id'] as int,
        defId: json['def'] as String,
        tag: json['tag'] as String,
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        timeSeconds: (json['time'] as num?)?.toDouble(),
        data: (json['data'] as Map<String, dynamic>?) == null ? null : Map<String, dynamic>.of(json['data'] as Map<String, dynamic>),
      );
}

/// A point on a manually routed wire, in canvas coordinates. Kept free of Flutter types for the solver tests.
class WirePoint {
  const WirePoint(this.x, this.y);

  final double x;
  final double y;

  List<double> toJson() => [x, y];
}

class Wire {
  Wire({required this.id, required this.a, required this.b, this.color = defaultColor, this.isJumper = false, this.gauge = 1.5, this.number = '', this.points});

  static const int defaultColor = 0xFF3F4750;
  static const int jumperColor = 0xFFB45309;

  final int id;
  final TerminalRef a;
  final TerminalRef b;
  int color;
  bool isJumper;

  /// Conductor cross-section in mm².
  double gauge;
  String number;

  /// Manual route between the terminals. Null means routed automatically.
  List<WirePoint>? points;

  bool touches(int deviceId) => a.deviceId == deviceId || b.deviceId == deviceId;

  bool connects(TerminalRef first, TerminalRef second) => (a == first && b == second) || (a == second && b == first);

  Map<String, dynamic> toJson() => {
        'id': id,
        'a': a.toJson(),
        'b': b.toJson(),
        'color': color,
        if (isJumper) 'jumper': true,
        'gauge': gauge,
        if (number.isNotEmpty) 'number': number,
        if (points != null) 'points': [for (final point in points!) point.toJson()],
      };

  factory Wire.fromJson(Map<String, dynamic> json) {
    final rawPoints = json['points'];
    List<WirePoint>? points;
    if (rawPoints != null) {
      if (rawPoints is! List<dynamic>) throw const FormatException('rusak');
      points = [];
      for (final point in rawPoints) {
        if (point is! List<dynamic> || point.length < 2 || point[0] is! num || point[1] is! num) throw const FormatException('rusak');
        final x = (point[0] as num).toDouble(), y = (point[1] as num).toDouble();
        if (!x.isFinite || !y.isFinite) throw const FormatException('rusak');
        points.add(WirePoint(x, y));
      }
    }
    return Wire(
      id: json['id'] as int,
      a: TerminalRef.fromJson(json['a'] as Map<String, dynamic>),
      b: TerminalRef.fromJson(json['b'] as Map<String, dynamic>),
      color: json['color'] as int? ?? defaultColor,
      isJumper: json['jumper'] as bool? ?? false,
      gauge: (json['gauge'] as num?)?.toDouble() ?? 1.5,
      number: json['number'] as String? ?? '',
      points: points,
    );
  }
}

class Project {
  Project({this.name = 'Proyek baru', List<PlacedDevice>? devices, List<Wire>? wires})
      : devices = devices ?? [],
        wires = wires ?? [];

  static const int schemaVersion = 2;

  String name;
  final List<PlacedDevice> devices;
  final List<Wire> wires;

  bool get isEmpty => devices.isEmpty;

  int nextId() {
    var highest = 0;
    for (final device in devices) {
      if (device.id > highest) highest = device.id;
    }
    for (final wire in wires) {
      if (wire.id > highest) highest = wire.id;
    }
    return highest + 1;
  }

  Map<String, dynamic> toJson() => {
        'app': 'BuildWire',
        'schemaVersion': schemaVersion,
        'name': name,
        'devices': [for (final device in devices) device.toJson()],
        'wires': [for (final wire in wires) wire.toJson()],
      };

  /// Throws [FormatException] for files that are not a readable project.
  factory Project.fromJson(Map<String, dynamic> json) {
    if (json['app'] != 'BuildWire' && json['app'] != 'TeknikDigital') throw const FormatException('bukan-proyek');
    final version = json['schemaVersion'];
    if (version is! int || version > schemaVersion) throw const FormatException('versi-baru');
    try {
      return Project(
        name: json['name'] as String? ?? 'Proyek',
        devices: [for (final device in json['devices'] as List<dynamic>) PlacedDevice.fromJson(device as Map<String, dynamic>)],
        wires: [for (final wire in json['wires'] as List<dynamic>) Wire.fromJson(wire as Map<String, dynamic>)],
      );
    } on TypeError {
      throw const FormatException('rusak');
    } on RangeError {
      throw const FormatException('rusak');
    }
  }
}
