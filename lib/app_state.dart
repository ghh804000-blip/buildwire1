import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai/ai_agent.dart';
import 'ai/ai_settings.dart';
import 'ai/swarm.dart';
import 'model/device_def.dart';
import 'model/project.dart';
import 'sim/ladder.dart';
import 'sim/plc.dart';
import 'sim/solver.dart';
import 'sim/wire_router.dart';
import 'sound.dart';
import 'templates.dart';

enum StatusKind { info, running, warning, error }

Future<Map<String, DeviceDef>> loadDeviceDefs() async {
  final text = await rootBundle.loadString('assets/devices/index.json');
  final list = jsonDecode(text) as List<dynamic>;
  return {for (final item in list) (item as Map<String, dynamic>)['id'] as String: DeviceDef.fromJson(item)};
}

/// Standard conductor colors by what a net is connected to.
const Map<String, int> kLabelColors = {
  'L1': 0xFF8A5A2B,
  'L2': 0xFF1F2428,
  'L3': 0xFF808890,
  'N': 0xFF1D6FB8,
  'PE': 0xFF3F8F3A,
  'DC+': 0xFFB3261E,
  'DC-': 0xFF1F2F4D,
};

class AppState extends ChangeNotifier {
  AppState(this.defs, this._prefs, {SoundPlayer? sound, SecretStore? secrets})
      : _sound = sound ?? SoundPlayer(),
        secrets = secrets ?? SecureSecretStore(),
        _solver = Solver(defs) {
    _restore();
    aiSettings = AiSettings.load(_prefs);
    _sound.preload([for (final base in layeredLoops) ...rotorLayerNames(base)]);
  }

  static const _projectKey = 'td-project';
  static const _themeKey = 'td-dark';
  static const _soundKey = 'td-sound';
  static const _guideKey = 'bw-guide-hidden';
  static const _numbersKey = 'bw-wire-numbers';
  static const _gridSize = 10.0;
  static const _editReady = 'Siap. Klik dua terminal untuk menyambung. Pilih kabel lalu seret segmennya untuk mengatur jalur.';

  final Map<String, DeviceDef> defs;
  final SharedPreferences? _prefs;

  // ----- AI

  /// Where the user's AI is, or null until it is set up. The key lives in [secrets], never in preferences.
  AiSettings? aiSettings;
  final SecretStore secrets;

  Future<void> saveAi(AiSettings settings, String key) async {
    await secrets.writeKey(key);
    await AiSettings.save(_prefs, settings);
    aiSettings = settings;
    notifyListeners();
  }

  Future<void> forgetAi() async {
    await secrets.writeKey(null);
    await AiSettings.save(_prefs, null);
    aiSettings = null;
    notifyListeners();
  }

  /// The assistant, made on first use and kept for the whole session.
  late final AiAgent ai = AiAgent(this);

  /// The assistant's team of cursors on the canvas.
  late final Swarm swarm = Swarm(this);

  /// While the assistant works the user can only watch: the canvas, panels and shortcuts ignore input.
  bool get aiLocked => ai.busy;

  /// The assistant's state changed in a way the whole workspace shows (locking, unlocking).
  void aiChanged() => notifyListeners();

  /// Sets the camera without touching undo, for the assistant's camera.
  void setView(Offset pan, double zoom) {
    this.pan = pan;
    this.zoom = zoom;
    viewVersion.value++;
  }

  /// Bumped when only the camera moves. The canvas and the zoom readout listen to this, so panning, zooming and the
  /// assistant's camera redraw the canvas without rebuilding the whole app every frame.
  final ValueNotifier<int> viewVersion = ValueNotifier(0);

  /// Width of the assistant's panel; the user can drag its edge, even while the assistant works.
  double aiPanelWidth = 380;

  void setAiPanelWidth(double width) {
    aiPanelWidth = width.clamp(300.0, 760.0);
    notifyListeners();
  }

  /// Lets the assistant's cursors open the device library and find a device's card in it. Set by the library panel.
  LibraryBridge? library;

  final Map<String, DateTime> _lastSound = {};

  /// A sound for the assistant's cursors. A team clicking at once would stack the same click many times over in a
  /// few milliseconds, which sounds like one smeared click and overloads the Windows audio plugin, so repeats closer
  /// than 45 ms are dropped.
  void playSound(String name) {
    final now = DateTime.now();
    final last = _lastSound[name];
    if (last != null && now.difference(last).inMilliseconds < 45) return;
    _lastSound[name] = now;
    _sound.play(name, soundOn);
  }

  /// The assistant's chat panel beside the canvas.
  bool aiPanelOpen = false;

  void toggleAiPanel() {
    aiPanelOpen = !aiPanelOpen;
    notifyListeners();
  }

  // Edits made by the assistant. One request from the user becomes one undo step: [beginAiEdit] takes the snapshot,
  // the edits below change the project directly, and [endAiEdit] saves and reports.
  bool _aiEditing = false;

  void beginAiEdit() {
    if (_aiEditing) return;
    if (running) stopSimulation();
    _snapshot();
    _aiEditing = true;
  }

  void endAiEdit(String message) {
    if (!_aiEditing) return;
    _aiEditing = false;
    _clearSelection();
    _commit(message);
  }

  bool get aiEditing => _aiEditing;

  /// The assistant edits one piece at a time; rebuilding the whole workspace for each wire made frames stall. Only
  /// the canvas follows along, and [endAiEdit] refreshes everything once at the end.
  void _aiNotify() => viewVersion.value++;

  void _aiTouch() {
    if (running) stopSimulation();
    if (!_aiEditing) beginAiEdit();
  }

  PlacedDevice? deviceByTag(String tag) {
    final wanted = tag.trim().toUpperCase();
    for (final device in project.devices) {
      if (device.tag.toUpperCase() == wanted) return device;
    }
    return null;
  }

  /// Places a device, nudged right until it overlaps nothing.
  PlacedDevice aiPlaceDevice(String defId, {String? tag, double? x, double? y}) {
    final plan = aiPlanPlacement(defId, tag: tag, x: x, y: y);
    return aiCommitPlacement(defId, plan.tag, plan.rect);
  }

  /// Where a device will go and what it will be called, without adding it yet: nudged right past devices already on
  /// the canvas and past [reserved] spots planned in the same batch.
  ({String tag, Rect rect}) aiPlanPlacement(String defId, {String? tag, double? x, double? y, List<Rect> reserved = const [], Set<String> reservedTags = const {}}) {
    final def = defs[defId]!;
    var left = _snap(x ?? _freeColumn(reserved)), top = _snap(y ?? 0);
    Rect rect() => Rect.fromLTWH(left, top, def.width, def.height);
    for (var guard = 0; guard < 200 && !def.isBackLayer; guard++) {
      final taken = [
        for (final d in project.devices)
          if (!defOf(d).isBackLayer) _deviceRect(d),
        ...reserved,
      ];
      final hit = taken.where((r) => r.deflate(1).overlaps(rect())).firstOrNull;
      if (hit == null) break;
      left = _snap(hit.right + 40);
    }
    final wanted = tag?.trim().toUpperCase() ?? '';
    final used = {for (final d in project.devices) d.tag, ...reservedTags};
    var name = wanted;
    if (name.isEmpty || used.contains(name)) {
      var number = 1;
      while (used.contains('${def.designator}$number')) {
        number++;
      }
      name = '${def.designator}$number';
    }
    return (tag: name, rect: rect());
  }

  PlacedDevice aiCommitPlacement(String defId, String tag, Rect rect) {
    _aiTouch();
    final def = defs[defId]!;
    final device = PlacedDevice(id: project.nextId(), defId: defId, tag: tag, x: rect.left, y: rect.top, timeSeconds: def.isTimer ? def.defaultTime : null);
    project.devices.add(device);
    _mountOnRail(device);
    _aiNotify();
    return device;
  }

  Rect deviceRect(PlacedDevice device) => _deviceRect(device);

  double _freeColumn([List<Rect> reserved = const []]) {
    final rights = [...project.devices.map(_deviceRect).map((r) => r.right), ...reserved.map((r) => r.right)];
    return rights.isEmpty ? 0 : rights.reduce(math.max) + 60;
  }

  Wire aiConnect(TerminalRef a, TerminalRef b, {int? color, double? gauge, bool jumper = false}) {
    _aiTouch();
    final wire = Wire(
      id: project.nextId(),
      a: a,
      b: b,
      isJumper: jumper,
      color: jumper ? Wire.jumperColor : (color ?? _autoColor(a, b)),
      gauge: gauge ?? (jumper ? 2.5 : 1.5),
    );
    project.wires.add(wire);
    _aiNotify();
    return wire;
  }

  void aiRemoveDevice(PlacedDevice device) {
    _aiTouch();
    project.devices.remove(device);
    project.wires.removeWhere((w) => w.a.deviceId == device.id || w.b.deviceId == device.id);
    _aiNotify();
  }

  void aiRemoveWire(Wire wire) {
    _aiTouch();
    project.wires.remove(wire);
    _aiNotify();
  }

  void aiClear() {
    _aiTouch();
    project = Project(name: project.name);
    _aiNotify();
  }

  void aiSetProgram(PlacedDevice plc, LadderProgram program) {
    _aiTouch();
    plc.data
      ..remove('program')
      ..['ladder'] = program.toJson();
    _aiNotify();
  }

  void aiSetTime(PlacedDevice device, double seconds) {
    _aiTouch();
    device.timeSeconds = seconds;
    _aiNotify();
  }

  void aiSetValue(PlacedDevice device, String key, Object value) {
    _aiTouch();
    device.data[key] = value;
    _aiNotify();
  }

  void aiRename(String name) {
    _aiTouch();
    project.name = name;
    _aiNotify();
  }
  final SoundPlayer _sound;
  final Solver _solver;

  Project project = Project();
  final Set<int> selectedDevices = {};
  int? selectedWire;
  TerminalRef? pending;
  Offset? pointer;

  /// Bends placed while drawing a wire (left-click on empty canvas), in world coordinates. The wire is drawn through
  /// them, turning vertically first at each, the same way the finished wire's route treats manual points.
  final List<Offset> pendingCorners = [];

  static const String _drawHint = 'Klik terminal tujuan. Klik kiri di tempat kosong untuk membelokkan kabel, klik kanan atau Esc untuk batal.';
  bool jumperMode = false;
  Rect? selectionBox;

  Offset pan = const Offset(48, 40);
  double zoom = 1;
  Size canvasSize = Size.zero;

  /// The welcome screen shows first. The builder opens from it, and its logo leads back.
  bool showHome = true;

  void openBuilder() {
    showHome = false;
    notifyListeners();
  }

  void openHome() {
    if (running) stopSimulation();
    showHome = true;
    notifyListeners();
  }

  bool running = false;
  Map<int, String> simStates = {};
  SimResult? simResult;
  Timer? _ticker;
  final Map<int, double> _timerStarted = {};
  final Map<int, Set<String>> _plcExternal = {};
  /// What each PLC remembers between scans (relays, timers, counters), kept from the last settled solution.
  final Map<int, PlcMemory> _plcMemory = {};
  final Map<int, double> _thermal = {};

  /// How far each overstressed device is toward exploding, from 0 to 1.
  final Map<int, double> _damage = {};

  /// Each device's own tolerance this run, so identical parts don't all fail at the same instant.
  final Map<int, double> _toughness = {};

  /// When each device exploded, in animation time.
  final Map<int, double> _explodedAt = {};
  final math.Random _random = math.Random();
  double _lastBlast = -100;
  double _blastGap = 0;
  String? _blastStatus;
  final List<TrendPoint> history = [];
  final List<String> events = [];
  double _elapsed = 0;
  int _sinceSample = 0;
  CanvasTool tool = CanvasTool.select;

  bool dark = false;
  bool soundOn = true;

  /// The how-to panel on the right is folded away once someone has read it; it comes back from its strip.
  bool guideHidden = false;

  /// Wire number markers at both ends of every wire, like printed ferrule markers in a panel.
  bool wireNumbersOn = true;
  String status = _editReady;
  StatusKind statusKind = StatusKind.info;

  final List<String> _undo = [];
  final List<String> _redo = [];
  String? _clipboard;

  bool get canUndo => _undo.isNotEmpty && !running;
  bool get canRedo => _redo.isNotEmpty && !running;

  PlacedDevice? get singleSelection => selectedDevices.length == 1 ? _device(selectedDevices.first) : null;

  bool isSelected(int id) => selectedDevices.contains(id);

  Wire? get selectedWireObject {
    for (final wire in project.wires) {
      if (wire.id == selectedWire) return wire;
    }
    return null;
  }

  PlacedDevice? _device(int? id) {
    for (final device in project.devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  String tagOf(int deviceId) => _device(deviceId)?.tag ?? '?';

  /// During simulation, clicking a device also shows it in the inspector.
  void inspect(PlacedDevice device) {
    selectedDevices
      ..clear()
      ..add(device.id);
    notifyListeners();
  }

  /// A part's definition at the size it is drawn: the catalogue entry, or a copy scaled by the part's own size.
  DeviceDef defOf(PlacedDevice device) {
    final def = defs[device.defId]!;
    final scale = scaleOf(device);
    if ((scale - 1).abs() < 0.001) return def;
    return _scaledDefs.putIfAbsent('${def.id}@$scale', () => def.scaled(scale));
  }

  final Map<String, DeviceDef> _scaledDefs = {};

  static const double minScale = 0.5, maxScale = 2.0;

  /// How big a part is drawn compared with its catalogue size (1 = 100%).
  double scaleOf(PlacedDevice device) => (device.data['scale'] as num?)?.toDouble() ?? 1;

  /// Resizes a part around its centre, in steps of 5%. Wrap a slider drag in beginControlEdit/endControlEdit so the
  /// whole drag is one undo step.
  void setDeviceScale(PlacedDevice device, double scale, {bool keepTopLeft = false}) {
    final next = ((scale.clamp(minScale, maxScale)) * 20).roundToDouble() / 20;
    if ((next - scaleOf(device)).abs() < 0.001) return;
    final centre = _deviceRect(device).center;
    final topLeft = Offset(device.x, device.y);
    if ((next - 1).abs() < 0.001) {
      device.data.remove('scale');
    } else {
      device.data['scale'] = next;
    }
    final def = defOf(device);
    device.x = keepTopLeft ? topLeft.dx : centre.dx - def.width / 2;
    device.y = keepTopLeft ? topLeft.dy : centre.dy - def.height / 2;
    notifyListeners();
  }

  String stateOf(PlacedDevice device) => running ? (simStates[device.id] ?? defOf(device).defaultState) : defOf(device).defaultState;

  /// Seconds left on a running timer, or null if it isn't counting.
  double? timerRemaining(PlacedDevice device) {
    final started = _timerStarted[device.id];
    if (started == null) return null;
    final left = timeOf(device) - (_elapsed - started);
    return left <= 1e-9 ? 0 : left;
  }

  double timeOf(PlacedDevice device) => device.timeSeconds ?? defOf(device).defaultTime;

  // ----- Persistence

  void _restore() {
    dark = _prefs?.getBool(_themeKey) ?? false;
    soundOn = _prefs?.getBool(_soundKey) ?? true;
    guideHidden = _prefs?.getBool(_guideKey) ?? false;
    wireNumbersOn = _prefs?.getBool(_numbersKey) ?? true;
    final saved = _prefs?.getString(_projectKey);
    if (saved == null) return;
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! Map<String, dynamic>) throw const FormatException('bukan-proyek');
      project = _validated(Project.fromJson(decoded));
    } on FormatException {
      project = Project();
    } on TypeError {
      project = Project();
    } on RangeError {
      project = Project();
    }
  }

  void _autosave() {
    _prefs?.setString(_projectKey, jsonEncode(project.toJson()));
  }

  /// Drops anything that refers to a device type or terminal this version doesn't have.
  Project _validated(Project input) {
    input.devices.removeWhere((device) => !defs.containsKey(device.defId) || !device.x.isFinite || !device.y.isFinite);
    final deviceIds = {for (final d in input.devices) d.id};
    for (final device in input.devices) {
      final scale = device.data['scale'];
      if (scale is! num || !scale.isFinite || scale <= 0) {
        device.data.remove('scale');
      } else {
        final clamped = scale.toDouble().clamp(minScale, maxScale).toDouble();
        if ((clamped - 1).abs() < 0.001) {
          device.data.remove('scale');
        } else {
          device.data['scale'] = clamped;
        }
      }
      final seated = device.data['seated_on'];
      if (seated is! int || !deviceIds.contains(seated)) device.data.remove('seated_on');
      if (device.data.containsKey('ladder') || device.data.containsKey('program')) {
        try {
          LadderProgram.of(device.data);
        } on FormatException {
          device.data
            ..remove('ladder')
            ..remove('program');
        } on TypeError {
          device.data
            ..remove('ladder')
            ..remove('program');
        } on RangeError {
          device.data
            ..remove('ladder')
            ..remove('program');
        }
      }
    }
    bool known(TerminalRef ref) {
      for (final device in input.devices) {
        if (device.id == ref.deviceId) return defs[device.defId]!.terminals.any((t) => t.id == ref.terminal);
      }
      return false;
    }

    input.wires.removeWhere((wire) => !known(wire.a) || !known(wire.b));
    for (final wire in input.wires) {
      wire.points?.removeWhere((p) => !p.x.isFinite || !p.y.isFinite);
    }
    return input;
  }

  String exportJson() => const JsonEncoder.withIndent('  ').convert(project.toJson());

  /// Returns an error message, or null on success.
  String? importJson(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) throw const FormatException('bukan-proyek');
      final loaded = _validated(Project.fromJson(decoded));
      if (running) stopSimulation();
      _snapshot();
      project = loaded;
      _clearSelection();
      fitView();
      _commit('Proyek dibuka: ${project.name}');
      return null;
    } on FormatException catch (error) {
      return error.message == 'versi-baru'
          ? 'Proyek ini dibuat dengan versi BuildWire yang lebih baru.'
          : 'File ini tidak bisa dibaca. Pastikan ini file proyek BuildWire.';
    }
  }

  /// Bill of materials and wire list as CSV.
  String exportBomCsv() {
    String q(Object value) => '"${value.toString().replaceAll('"', '""')}"';
    final lines = <String>[
      [q('Bagian'), q('Tag'), q('Nama'), q('Jumlah'), q('Keterangan')].join(','),
    ];
    final groups = <String, List<PlacedDevice>>{};
    for (final device in project.devices.where((d) => !defOf(d).isJunction)) {
      groups.putIfAbsent(device.defId, () => []).add(device);
    }
    groups.forEach((defId, devices) {
      lines.add([q('Perangkat'), q(devices.map((d) => d.tag).join(' ')), q(defs[defId]!.name), q(devices.length), q(defs[defId]!.isSymbol ? 'Simbol' : '')].join(','));
    });
    for (final row in wireSummary()) {
      lines.add([q(row.isJumper ? 'Jumper' : 'Kabel'), q(''), q('${row.gauge} mm2'), q(row.count), q('')].join(','));
    }
    return lines.join('\r\n');
  }

  List<WireSummary> wireSummary() {
    final rows = <String, WireSummary>{};
    for (final wire in project.wires) {
      final key = '${wire.isJumper}-${wire.gauge}';
      rows.putIfAbsent(key, () => WireSummary(wire.isJumper, wire.gauge)).count++;
    }
    return rows.values.toList();
  }

  // ----- Undo

  void _snapshot() {
    _undo.add(jsonEncode(project.toJson()));
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
  }

  void _commit([String? message]) {
    _autosave();
    _setStatus(message ?? _editReady, StatusKind.info);
    notifyListeners();
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(jsonEncode(project.toJson()));
    _load(_undo.removeLast());
    _commit('Perubahan dibatalkan.');
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(jsonEncode(project.toJson()));
    _load(_redo.removeLast());
    _commit('Perubahan diulang.');
  }

  void _load(String snapshot) {
    project = Project.fromJson(jsonDecode(snapshot) as Map<String, dynamic>);
    _clearSelection();
  }

  void _clearSelection() {
    selectedDevices.clear();
    selectedWire = null;
    pending = null;
    pendingCorners.clear();
  }

  /// While drawing a wire, fixes a bend at the clicked point (snapped to the grid).
  void addPendingCorner(Offset screen) {
    if (pending == null || running) return;
    if (jumperMode) return; // Jumpers run straight between two terminals.
    final world = toWorld(screen);
    final point = Offset(_snap(world.dx), _snap(world.dy));
    if (pendingCorners.isNotEmpty && (pendingCorners.last - point).distance < 1) return;
    pendingCorners.add(point);
    _setStatus('${pendingCorners.length} belokan. $_drawHint', StatusKind.info);
    notifyListeners();
  }

  /// Stops drawing a wire without making it.
  void cancelPending() {
    if (pending == null) return;
    _clearSelection();
    _setStatus('Batal menyambung kabel.', StatusKind.info);
    notifyListeners();
  }

  void _setStatus(String message, StatusKind kind) {
    status = message;
    statusKind = kind;
  }

  // ----- Project

  void newProject() {
    if (running) stopSimulation();
    _snapshot();
    project = Project();
    _clearSelection();
    resetView();
    _commit('Proyek baru dibuat. Proyek sebelumnya bisa dikembalikan dengan Urungkan.');
  }

  void applyTemplate(CircuitTemplate template) {
    if (running) stopSimulation();
    _snapshot();
    project = template.build();
    if (template.arrange) _arrangeDevices();
    _clearSelection();
    fitView();
    _commit(template.hint);
  }

  void renameProject(String name) {
    if (running) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == project.name) return;
    _snapshot();
    project.name = trimmed;
    _commit();
  }

  // ----- Devices

  String _nextTag(String designator) {
    var number = 1;
    final used = {for (final device in project.devices) device.tag};
    while (used.contains('$designator$number')) {
      number++;
    }
    return '$designator$number';
  }

  void addDevice(String defId, {Offset? world}) {
    if (running) return;
    final def = defs[defId]!;
    _snapshot();
    final center = canvasSize == Size.zero ? const Offset(200, 120) : toWorld(Offset(canvasSize.width / 2, canvasSize.height / 2));
    final count = project.devices.length % 6;
    final target = world ?? center + Offset(count * 30.0, count * 30.0);
    final device = PlacedDevice(
      id: project.nextId(),
      defId: defId,
      tag: _nextTag(def.designator),
      x: _snap(target.dx - def.width / 2),
      y: _snap(target.dy - def.height / 2),
      timeSeconds: def.isTimer ? def.defaultTime : null,
    );
    project.devices.add(device);
    _mountOnRail(device);
    _seatOverload(device);
    _linkSeatedOverloads();
    selectedDevices
      ..clear()
      ..add(device.id);
    selectedWire = null;
    _commit('${def.name} ditambahkan sebagai ${device.tag}.');
  }

  double _snap(double value) => (value / _gridSize).round() * _gridSize;

  String? _dragBefore;
  Map<int, Offset> _dragOrigins = {};

  /// Devices riding on a dragged rail or panel box, mapped to the id of what carries them.
  Map<int, int> _carried = {};

  void beginMove(int deviceId) {
    if (!selectedDevices.contains(deviceId)) {
      selectedDevices
        ..clear()
        ..add(deviceId);
    }
    selectedWire = null;
    _dragBefore = jsonEncode(project.toJson());
    _carried = {};
    for (final carrier in project.devices) {
      if (!selectedDevices.contains(carrier.id) || !defOf(carrier).isBackLayer) continue;
      final area = _deviceRect(carrier);
      final isRail = defOf(carrier).isDinRail;
      for (final rider in project.devices) {
        if (selectedDevices.contains(rider.id) || _carried.containsKey(rider.id) || rider.id == carrier.id) continue;
        final riderDef = defOf(rider);
        // A box carries its rails and everything inside it; a rail carries what is clipped on it.
        if (riderDef.layerRank <= defOf(carrier).layerRank) continue;
        final onIt = isRail ? _isMountedOn(rider, carrier) : area.contains(_deviceRect(rider).center);
        if (onIt) _carried[rider.id] = carrier.id;
      }
    }
    // Things on a carried rail ride along with the box too.
    var grew = true;
    while (grew) {
      grew = false;
      for (final rail in project.devices) {
        if (!_carried.containsKey(rail.id) || !defOf(rail).isDinRail) continue;
        for (final rider in project.devices) {
          if (selectedDevices.contains(rider.id) || _carried.containsKey(rider.id) || defOf(rider).isBackLayer) continue;
          if (_isMountedOn(rider, rail)) {
            _carried[rider.id] = _carried[rail.id]!;
            grew = true;
          }
        }
      }
    }
    // An overload relay plugged under a moved or carried contactor goes with it.
    for (final contactor in project.devices) {
      if (!defOf(contactor).isContactor) continue;
      final rootCarrier = selectedDevices.contains(contactor.id) ? contactor.id : _carried[contactor.id];
      if (rootCarrier == null) continue;
      for (final tor in project.devices) {
        if (selectedDevices.contains(tor.id) || _carried.containsKey(tor.id)) continue;
        if (_isSeatedOn(tor, contactor)) _carried[tor.id] = rootCarrier;
      }
    }
    _dragOrigins = {
      for (final device in project.devices)
        if (selectedDevices.contains(device.id) || _carried.containsKey(device.id)) device.id: Offset(device.x, device.y),
    };
    notifyListeners();
  }

  void moveSelectionBy(Offset delta) {
    final movingRail = project.devices.any((d) => selectedDevices.contains(d.id) && defOf(d).isBackLayer);
    for (final device in project.devices) {
      final origin = _dragOrigins[device.id];
      if (origin == null || _carried.containsKey(device.id)) continue;
      device.x = _snap(origin.dx + delta.dx);
      device.y = _snap(origin.dy + delta.dy);
      if (!movingRail) _mountOnRail(device, ignore: selectedDevices);
      _seatOverload(device);
    }
    for (final device in project.devices) {
      final carrierId = _carried[device.id];
      if (carrierId == null) continue;
      final carrier = _device(carrierId)!;
      final carrierOrigin = _dragOrigins[carrierId]!;
      final origin = _dragOrigins[device.id]!;
      device.x = origin.dx + carrier.x - carrierOrigin.dx;
      device.y = origin.dy + carrier.y - carrierOrigin.dy;
    }
    notifyListeners();
  }

  // ----- Overload relays plugged onto contactors

  /// Where an overload relay sits plugged under a contactor: centred on its 4/T2 terminal, with the relay's pins and
  /// clips tucked behind the contactor so only its body shows below it, as on a real starter.
  Offset? _overloadSeat(PlacedDevice tor, PlacedDevice contactor) {
    final tDef = defOf(tor), cDef = defOf(contactor);
    if (!tDef.isOverloadRelay || !cDef.isContactor) return null;
    final pin = tDef.terminals.where((t) => t.id == '3').firstOrNull;
    final socket = cDef.terminals.where((t) => t.id == '4').firstOrNull;
    if (pin == null || socket == null) return null;
    final seat = (tDef.torPanel?['seat'] as num?)?.toDouble() ?? 0.2;
    return Offset(contactor.x + socket.x * cDef.width - pin.x * tDef.width, contactor.y + cDef.height - seat * tDef.height);
  }

  /// Whether an overload relay is plugged under this contactor.
  bool hasSeatedOverload(PlacedDevice contactor) =>
      defOf(contactor).isContactor && project.devices.any((d) => (d.data['seated_on'] as num?)?.toInt() == contactor.id);

  bool _isSeatedOn(PlacedDevice tor, PlacedDevice contactor) {
    final seat = _overloadSeat(tor, contactor);
    return seat != null && (Offset(tor.x, tor.y) - seat).distance < 1;
  }

  /// How close (px) an overload relay must come to its seat under a contactor to plug in.
  static const double _seatReach = 70;

  /// Snaps an overload relay onto the nearest contactor whose seat it is close to.
  void _seatOverload(PlacedDevice tor) {
    if (!defOf(tor).isOverloadRelay) return;
    Offset? best;
    var bestDistance = _seatReach;
    for (final contactor in project.devices) {
      final seat = _overloadSeat(tor, contactor);
      if (seat == null) continue;
      final distance = (Offset(tor.x, tor.y) - seat).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = seat;
      }
    }
    if (best == null) return;
    tor.x = best.dx;
    tor.y = best.dy;
  }

  /// Records which contactor each overload relay is plugged under. The connection itself is internal (the solver
  /// joins 2-1, 4-3 and 6-5), so no wire is drawn; pulling the relay off ends it.
  void _linkSeatedOverloads() {
    for (final tor in project.devices) {
      if (!defOf(tor).isOverloadRelay) continue;
      final seatedOn = project.devices.where((c) => defOf(c).isContactor && _isSeatedOn(tor, c)).firstOrNull;
      if (seatedOn == null) {
        tor.data.remove('seated_on');
      } else {
        tor.data['seated_on'] = seatedOn.id;
        // Wires that only joined the pins the relay now plugs into have nothing left to do.
        for (final (c, t) in const [('2', '1'), ('4', '3'), ('6', '5')]) {
          project.wires.removeWhere((w) => w.connects(TerminalRef(seatedOn.id, c), TerminalRef(tor.id, t)));
        }
      }
    }
  }

  /// The relay's 1/3/5 pins once it is plugged under a contactor: they are behind the contactor and cannot take a
  /// wire. The contactor's 2/4/6 stay usable; they carry straight on into the relay.
  bool isTerminalCovered(PlacedDevice device, String terminal) =>
      device.data['seated_on'] != null && const {'1', '3', '5'}.contains(terminal);

  bool terminalCovered(TerminalRef ref) {
    final device = _device(ref.deviceId);
    if (device == null) return false;
    return isTerminalCovered(device, ref.terminal);
  }

  /// Whether this part is an overload relay plugged under a contactor (it is drawn over the contactor).
  bool isSeated(PlacedDevice device) => device.data['seated_on'] != null;

  /// How far (px) from a rail's centre line a device still clips onto it.
  static const double _railReach = 48;

  /// How close (px) a device must come to a neighbour on the rail to butt up against it.
  static const double _railButt = 20;

  bool _isMountedOn(PlacedDevice device, PlacedDevice rail) {
    final rect = _deviceRect(device);
    final railRect = _deviceRect(rail);
    return (rect.center.dy - railRect.center.dy).abs() < 1 && rect.center.dx >= railRect.left && rect.center.dx <= railRect.right;
  }

  /// Clips a dropped device onto the nearest DIN rail under it and butts it against its neighbours.
  void _mountOnRail(PlacedDevice device, {Set<int> ignore = const {}}) {
    final def = defOf(device);
    if (def.isBackLayer) return;
    final rect = _deviceRect(device);
    PlacedDevice? rail;
    var best = double.infinity;
    for (final candidate in project.devices) {
      if (!defOf(candidate).isDinRail) continue;
      final railRect = _deviceRect(candidate);
      if (rect.center.dx < railRect.left || rect.center.dx > railRect.right) continue;
      final distance = (rect.center.dy - railRect.center.dy).abs();
      if (distance <= math.max(_railReach, def.height / 2) && distance < best) {
        best = distance;
        rail = candidate;
      }
    }
    if (rail == null) return;
    final railRect = _deviceRect(rail);
    device.y = railRect.center.dy - def.height / 2;
    if (def.width <= railRect.width) {
      device.x = device.x.clamp(railRect.left, railRect.right - def.width).toDouble();
    }
    // Butt up against the nearest neighbour already on this rail.
    var gap = _railButt;
    double? target;
    for (final other in project.devices) {
      if (other.id == device.id || ignore.contains(other.id) || defOf(other).isBackLayer || !_isMountedOn(other, rail)) continue;
      final otherRect = _deviceRect(other);
      final left = (device.x - otherRect.right).abs();
      if (left < gap) {
        gap = left;
        target = otherRect.right;
      }
      final right = (device.x + def.width - otherRect.left).abs();
      if (right < gap) {
        gap = right;
        target = otherRect.left - def.width;
      }
    }
    if (target != null) device.x = target;
  }

  void endMove() {
    final before = _dragBefore;
    _dragBefore = null;
    if (before == null) return;
    _linkSeatedOverloads();
    if (before == jsonEncode(project.toJson())) {
      notifyListeners();
      return;
    }
    _undo.add(before);
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
    _commit();
  }

  void selectDevice(int id, {bool additive = false}) {
    if (additive) {
      selectedDevices.contains(id) ? selectedDevices.remove(id) : selectedDevices.add(id);
    } else {
      selectedDevices
        ..clear()
        ..add(id);
    }
    selectedWire = null;
    notifyListeners();
  }

  void selectAll() {
    if (running) return;
    selectedDevices
      ..clear()
      ..addAll(project.devices.map((d) => d.id));
    selectedWire = null;
    notifyListeners();
  }

  void selectWire(int id) {
    selectedWire = id;
    selectedDevices.clear();
    notifyListeners();
  }

  void clearSelection() {
    final hadPending = pending != null;
    _clearSelection();
    if (hadPending) _setStatus(_editReady, StatusKind.info);
    notifyListeners();
  }

  void beginBox(Offset screen) {
    selectionBox = Rect.fromPoints(screen, screen);
    notifyListeners();
  }

  void updateBox(Offset screen) {
    final box = selectionBox;
    if (box == null) return;
    selectionBox = Rect.fromPoints(_boxStart(box, screen), screen);
    notifyListeners();
  }

  Offset? _boxAnchor;

  Offset _boxStart(Rect box, Offset screen) => _boxAnchor ??= box.topLeft;

  void endBox() {
    final box = selectionBox;
    selectionBox = null;
    _boxAnchor = null;
    if (box == null) return;
    final world = Rect.fromPoints(toWorld(box.topLeft), toWorld(box.bottomRight));
    selectedDevices
      ..clear()
      ..addAll(project.devices.where((d) => !defOf(d).isBackLayer && world.overlaps(_deviceRect(d))).map((d) => d.id));
    selectedWire = null;
    notifyListeners();
  }

  void deleteSelection() {
    if (running) return;
    if (selectedDevices.isNotEmpty) {
      _snapshot();
      final count = selectedDevices.length;
      final ids = Set<int>.of(selectedDevices);
      _mergeAcross(ids);
      project.wires.removeWhere((wire) => ids.contains(wire.a.deviceId) || ids.contains(wire.b.deviceId));
      project.devices.removeWhere((device) => ids.contains(device.id));
      _clearSelection();
      _commit('$count perangkat dihapus.');
    } else if (selectedWire != null) {
      _snapshot();
      final id = selectedWire!;
      project.wires.removeWhere((wire) => wire.id == id);
      _clearSelection();
      _commit('Sambungan dihapus.');
    }
  }

  void copySelection() {
    if (running || selectedDevices.isEmpty) return;
    final devices = project.devices.where((d) => selectedDevices.contains(d.id)).toList();
    final ids = {for (final device in devices) device.id};
    final wires = project.wires.where((w) => ids.contains(w.a.deviceId) && ids.contains(w.b.deviceId)).toList();
    _clipboard = jsonEncode({
      'devices': [for (final device in devices) device.toJson()],
      'wires': [for (final wire in wires) wire.toJson()],
    });
    _setStatus('${devices.length} perangkat disalin.', StatusKind.info);
    notifyListeners();
  }

  void paste() {
    final clip = _clipboard;
    if (running || clip == null) return;
    _snapshot();
    _pasteJson(jsonDecode(clip) as Map<String, dynamic>, const Offset(40, 40));
    _commit('${selectedDevices.length} perangkat ditempel.');
  }

  void duplicateSelection() {
    if (running || selectedDevices.isEmpty) return;
    copySelection();
    paste();
  }

  void _pasteJson(Map<String, dynamic> data, Offset offset) {
    final idMap = <int, int>{};
    final added = <int>{};
    final pasted = <PlacedDevice>[];
    for (final item in data['devices'] as List<dynamic>) {
      final source = PlacedDevice.fromJson(item as Map<String, dynamic>);
      final id = project.nextId();
      idMap[source.id] = id;
      final copy = PlacedDevice(
        id: id,
        defId: source.defId,
        tag: _nextTag(defs[source.defId]!.designator),
        x: source.x + offset.dx,
        y: source.y + offset.dy,
        timeSeconds: source.timeSeconds,
        data: source.data.isEmpty ? null : jsonDecode(jsonEncode(source.data)) as Map<String, dynamic>,
      );
      project.devices.add(copy);
      pasted.add(copy);
      added.add(id);
    }
    for (final copy in pasted) {
      if (!copy.data.containsKey('seated_on')) continue;
      final oldId = (copy.data['seated_on'] as num?)?.toInt();
      final newId = oldId == null ? null : idMap[oldId];
      if (newId != null) {
        copy.data['seated_on'] = newId;
      } else {
        copy.data.remove('seated_on');
      }
    }
    for (final item in data['wires'] as List<dynamic>) {
      final source = Wire.fromJson(item as Map<String, dynamic>);
      project.wires.add(Wire(
        id: project.nextId(),
        a: TerminalRef(idMap[source.a.deviceId]!, source.a.terminal),
        b: TerminalRef(idMap[source.b.deviceId]!, source.b.terminal),
        color: source.color,
        isJumper: source.isJumper,
        gauge: source.gauge,
        points: source.points?.map((p) => WirePoint(p.x + offset.dx, p.y + offset.dy)).toList(),
      ));
    }
    selectedDevices
      ..clear()
      ..addAll(added);
    selectedWire = null;
  }

  void alignSelection({required bool left}) {
    if (running || selectedDevices.length < 2) return;
    _snapshot();
    final chosen = project.devices.where((d) => selectedDevices.contains(d.id)).toList();
    final target = chosen.map((d) => left ? d.x : d.y).reduce(math.min);
    for (final device in chosen) {
      if (left) {
        device.x = target;
      } else {
        device.y = target;
      }
    }
    _commit();
  }

  void setTag(PlacedDevice device, String tag) {
    if (running) return;
    final trimmed = tag.trim();
    if (trimmed.isEmpty || trimmed == device.tag) return;
    _snapshot();
    device.tag = trimmed;
    _commit();
  }

  void setTime(PlacedDevice device, double seconds) {
    if (running || !seconds.isFinite || seconds <= 0 || seconds == device.timeSeconds) return;
    _snapshot();
    device.timeSeconds = seconds;
    _commit();
  }

  // ----- Wires and jumpers

  void setJumperMode(bool value) {
    jumperMode = value;
    pending = null;
    _setStatus(value ? 'Mode jumper. Klik dua terminal untuk menjembatani.' : 'Mode kabel. Klik dua terminal untuk menyambung.', StatusKind.info);
    notifyListeners();
  }

  void setWireColor(Wire wire, int color) {
    if (wire.color == color) return;
    _snapshot();
    wire.color = color;
    _commit();
  }

  void setWireGauge(Wire wire, double gauge) {
    if (wire.gauge == gauge) return;
    _snapshot();
    wire.gauge = gauge;
    _commit();
  }

  void setWireNumber(Wire wire, String number) {
    final trimmed = number.trim();
    if (trimmed == wire.number) return;
    _snapshot();
    wire.number = trimmed;
    _commit();
  }

  void setWireJumper(Wire wire, bool isJumper) {
    if (wire.isJumper == isJumper) return;
    _snapshot();
    wire.isJumper = isJumper;
    wire.points = null;
    wire.color = isJumper ? Wire.jumperColor : _autoColor(wire.a, wire.b);
    _commit();
  }

  void resetWireRoute(Wire wire) {
    if (wire.points == null) return;
    _snapshot();
    wire.points = null;
    _commit('Jalur kabel dirapikan otomatis.');
  }

  // ----- Automatic layout

  /// Where a part goes in the automatic layout: the power side runs top to bottom on the left (supply, protection,
  /// contactors, overload, loads), the control side on the right (buttons, lights, the rest). -1: leave it alone.
  static int _layoutRow(DeviceDef def) {
    if (def.isBackLayer || def.isJunction || def.isSymbol) return -1;
    final group = def.group ?? '';
    const supply = {'Sumber AC/DC', 'Trafo'};
    const protection = {'MCB', 'MCCB', 'MPCB', 'RCCB'};
    const switching = {'Kontaktor', 'Kontak bantu', 'Inverter (VFD)'};
    const overload = {'Overload relay (TOR)'};
    const loads = {'Motor', 'Beban', 'Stopkontak'};
    const buttons = {'Tombol tekan', 'Tombol darurat', 'Selektor', 'Saklar'};
    const lights = {'Lampu indikator dan buzzer'};
    if (supply.contains(group) || def.kind == 'source') return 0;
    if (protection.contains(group)) return 1;
    if (switching.contains(group)) return 2;
    if (overload.contains(group)) return 3;
    if (loads.contains(group) || def.kind == 'motor3' || def.rotor != null) return 4;
    if (buttons.contains(group)) return 10;
    if (lights.contains(group)) return 11;
    return 12;
  }

  /// Lays the parts out the way a panel drawing is usually read, then lets the router lay every wire again. Rows are
  /// ordered so parts sit under the parts they are wired to, which keeps wires short and straight. One undo step.
  void autoArrange() {
    if (running) return;
    if (project.devices.where((d) => _layoutRow(defOf(d)) >= 0).length < 2) return;
    _snapshot();
    _arrangeDevices();
    _clearSelection();
    fitView();
    _commit('Perangkat ditata otomatis: rangkaian daya di kiri, kontrol di kanan. Tekan Ctrl+Z untuk membatalkan.');
  }

  /// The layout itself, without an undo step: used by the menu command and by ready-made circuits that ask for it.
  void _arrangeDevices() {
    final movable = [for (final d in project.devices) if (_layoutRow(defOf(d)) >= 0) d];
    if (movable.length < 2) return;
    var left = double.infinity, top = double.infinity;
    for (final d in movable) {
      left = math.min(left, d.x);
      top = math.min(top, d.y);
    }
    final rows = <int, List<PlacedDevice>>{};
    for (final d in movable) {
      rows.putIfAbsent(_layoutRow(defOf(d)), () => []).add(d);
    }
    int byTag(PlacedDevice p, PlacedDevice q) => _naturalTag(p.tag).compareTo(_naturalTag(q.tag));
    final neighbours = <int, Set<int>>{};
    for (final w in project.wires) {
      neighbours.putIfAbsent(w.a.deviceId, () => {}).add(w.b.deviceId);
      neighbours.putIfAbsent(w.b.deviceId, () => {}).add(w.a.deviceId);
    }
    final centreX = <int, double>{};
    const gapX = 90.0, gapY = 150.0, sideGap = 220.0;

    /// Places one band of rows starting at [x0]; returns the right edge it reached.
    double band(List<int> keys, double x0) {
      var y = top;
      var right = x0;
      for (final key in keys) {
        final row = rows[key];
        if (row == null || row.isEmpty) continue;
        // Under the parts they connect to; parts with no placed neighbour keep tag order after them.
        double? bary(PlacedDevice d) {
          final xs = [for (final n in neighbours[d.id] ?? const <int>{}) if (centreX.containsKey(n)) centreX[n]!];
          return xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;
        }

        row.sort((p, q) {
          final bp = bary(p), bq = bary(q);
          if (bp != null && bq != null && (bp - bq).abs() > 1) return bp.compareTo(bq);
          if (bp != null && bq == null) return -1;
          if (bp == null && bq != null) return 1;
          return byTag(p, q);
        });
        var x = x0;
        var height = 0.0;
        for (final d in row) {
          final def = defOf(d);
          d.x = _snap(x);
          d.y = _snap(y);
          centreX[d.id] = d.x + def.width / 2;
          x += def.width + gapX;
          height = math.max(height, def.height);
        }
        right = math.max(right, x - gapX);
        y += height + gapY;
      }
      return right;
    }

    final powerRight = band(const [0, 1, 2, 3, 4], left);
    band(const [10, 11, 12], powerRight + sideGap);
    // Junctions follow: each sits at the middle of the terminals it joins, so its wires stay short.
    for (final junction in project.devices.where((d) => defOf(d).isJunction)) {
      final ends = [
        for (final w in project.wires)
          if (w.touches(junction.id)) terminalWorld(w.a.deviceId == junction.id ? w.b : w.a),
      ];
      if (ends.isEmpty) continue;
      final def = defOf(junction);
      final centre = ends.reduce((a, b) => a + b) / ends.length.toDouble();
      junction.x = _snap(centre.dx - def.width / 2);
      junction.y = _snap(centre.dy - def.height / 2);
    }
    for (final wire in project.wires) {
      wire.points = null;
    }
  }

  /// "KM10" sorts after "KM9".
  static String _naturalTag(String tag) => tag.replaceAllMapped(RegExp(r'\d+'), (m) => m.group(0)!.padLeft(4, '0'));

  void resetAllRoutes() {
    if (running || project.wires.every((wire) => wire.points == null)) return;
    _snapshot();
    for (final wire in project.wires) {
      wire.points = null;
    }
    _commit('Semua jalur kabel dirapikan otomatis.');
  }

  /// Color from the supply a new wire ends up on, following wires and always-closed contacts only.
  int autoColor(TerminalRef a, TerminalRef b) => _autoColor(a, b);

  int _autoColor(TerminalRef a, TerminalRef b) {
    final seen = <String>{a.key, b.key};
    final queue = [a.key, b.key];
    while (queue.isNotEmpty) {
      final key = queue.removeLast();
      final parts = key.split(':');
      final device = _device(int.parse(parts[0]));
      if (device == null) continue;
      final def = defOf(device);
      final label = def.outputs[parts.sublist(1).join(':')];
      if (label != null) return kLabelColors[label] ?? Wire.defaultColor;
      for (final wire in project.wires) {
        if (wire.a.key == key && seen.add(wire.b.key)) queue.add(wire.b.key);
        if (wire.b.key == key && seen.add(wire.a.key)) queue.add(wire.a.key);
      }
      if (def.kind == 'passive') {
        for (final terminal in def.terminals) {
          final next = '${device.id}:${terminal.id}';
          if (seen.add(next)) queue.add(next);
        }
      }
    }
    return Wire.defaultColor;
  }

  void tapTerminal(TerminalRef ref) {
    if (running) return;
    final start = pending;
    if (start == null) {
      pending = ref;
      pendingCorners.clear();
      selectedDevices.clear();
      selectedWire = null;
      _setStatus(_drawHint, StatusKind.info);
      notifyListeners();
      return;
    }
    if (start == ref) {
      clearSelection();
      return;
    }
    if (project.wires.any((wire) => wire.connects(start, ref))) {
      pending = null;
      _setStatus('Dua terminal itu sudah tersambung.', StatusKind.warning);
      notifyListeners();
      return;
    }
    _snapshot();
    final wire = Wire(
      id: project.nextId(),
      a: start,
      b: ref,
      isJumper: jumperMode,
      color: jumperMode ? Wire.jumperColor : _autoColor(start, ref),
      gauge: jumperMode ? 2.5 : 1.5,
    );
    // Bends placed while drawing become the wire's own route; without any, the router lays it.
    if (!jumperMode && pendingCorners.isNotEmpty) wire.points = [for (final p in pendingCorners) WirePoint(p.dx, p.dy)];
    project.wires.add(wire);
    pending = null;
    pendingCorners.clear();
    selectedWire = wire.id;
    _sound.play('wire_connect', soundOn);
    final what = jumperMode ? 'Jumper' : 'Kabel';
    _commit('$what tersambung: ${tagOf(start.deviceId)} ${start.terminal} ke ${tagOf(ref.deviceId)} ${ref.terminal}.');
  }

  /// Ends a connection on the middle of a wire: a junction goes where the wire was clicked, the wire is split in two
  /// there, and the pending terminal is wired to it.
  void branchToWire(Wire wire, Offset screen) {
    final start = pending;
    if (running || start == null) return;
    final route = routeWorld(wire);
    final world = toWorld(screen);
    var best = route.first;
    var bestDistance = double.infinity;
    for (var i = 0; i < route.length - 1; i++) {
      final a = route[i], b = route[i + 1];
      final ab = b - a;
      final length = ab.dx * ab.dx + ab.dy * ab.dy;
      final t = length == 0 ? 0.0 : (((world - a).dx * ab.dx + (world - a).dy * ab.dy) / length).clamp(0.0, 1.0);
      final point = a + ab * t;
      final distance = (point - world).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = point;
      }
    }
    _snapshot();
    final def = defs['generic_junction']!;
    final junction = PlacedDevice(id: project.nextId(), defId: def.id, tag: _nextTag(def.designator), x: best.dx - def.width / 2, y: best.dy - def.height / 2);
    project.devices.add(junction);
    final here = TerminalRef(junction.id, 'J');
    project.wires.remove(wire);
    Wire half(TerminalRef from, TerminalRef to) =>
        Wire(id: project.nextId(), a: from, b: to, color: wire.color, gauge: wire.gauge, isJumper: false, number: wire.number);
    project.wires
      ..add(half(wire.a, here))
      ..add(half(here, wire.b))
      ..add(Wire(
        id: project.nextId(),
        a: start,
        b: here,
        color: wire.color,
        gauge: wire.gauge,
        points: pendingCorners.isEmpty ? null : [for (final p in pendingCorners) WirePoint(p.dx, p.dy)],
      ));
    pending = null;
    pendingCorners.clear();
    selectedWire = null;
    _sound.play('wire_connect', soundOn);
    _commit('Kabel bercabang dari ${tagOf(start.deviceId)} ${start.terminal}.');
  }

  /// Wires a deleted junction joined become one wire again, if it joined exactly two.
  void _mergeAcross(Set<int> deleting) {
    for (final id in deleting) {
      final device = _device(id);
      if (device == null || !defOf(device).isJunction) continue;
      final attached = project.wires.where((w) => w.touches(id)).toList();
      if (attached.length != 2) continue;
      TerminalRef other(Wire w) => w.a.deviceId == id ? w.b : w.a;
      final a = other(attached[0]), b = other(attached[1]);
      if (a == b || deleting.contains(a.deviceId) || deleting.contains(b.deviceId)) continue;
      final keep = attached[0];
      project.wires
        ..removeWhere(attached.contains)
        ..add(Wire(id: project.nextId(), a: a, b: b, color: keep.color, gauge: keep.gauge, number: keep.number));
    }
  }

  void setPointer(Offset position) {
    pointer = position;
    if (pending != null) notifyListeners();
  }

  // ----- Dragging a wire segment

  List<Offset> _wireBase = const [];
  int _wireSegment = 0;

  void beginWireDrag(Wire wire, int segment) {
    _dragBefore = jsonEncode(project.toJson());
    _wireBase = routeWorld(wire);
    _wireSegment = segment;
  }

  /// Moves one segment across its own direction, adding a bend if it touches a terminal.
  void updateWireDrag(Wire wire, Offset world) {
    final points = List<Offset>.of(_wireBase);
    var i = _wireSegment;
    final horizontal = (points[i].dy - points[i + 1].dy).abs() < 0.01;
    if (i == 0) {
      points.insert(0, points.first);
      i = 1;
    }
    if (i + 1 == points.length - 1) points.add(points.last);
    if (horizontal) {
      final y = _snap(world.dy);
      points[i] = Offset(points[i].dx, y);
      points[i + 1] = Offset(points[i + 1].dx, y);
    } else {
      final x = _snap(world.dx);
      points[i] = Offset(x, points[i].dy);
      points[i + 1] = Offset(x, points[i + 1].dy);
    }
    wire.points = [for (final p in points.sublist(1, points.length - 1)) WirePoint(p.dx, p.dy)];
    notifyListeners();
  }

  void endWireDrag() => endMove();

  // ----- View

  Offset toWorld(Offset screen) => (screen - pan) / zoom;
  Offset toScreen(Offset world) => pan + world * zoom;

  void panBy(Offset delta) {
    pan += delta;
    viewVersion.value++;
  }

  void zoomAt(Offset focal, double factor) {
    final next = (zoom * factor).clamp(0.2, 3.0);
    final world = toWorld(focal);
    zoom = next;
    pan = focal - world * zoom;
    viewVersion.value++;
  }

  void zoomStep(double factor) => zoomAt(canvasSize == Size.zero ? Offset.zero : Offset(canvasSize.width / 2, canvasSize.height / 2), factor);

  void resetView() {
    zoom = 1;
    pan = const Offset(48, 40);
    notifyListeners();
  }

  void fitView() {
    if (project.devices.isEmpty || canvasSize == Size.zero) {
      resetView();
      return;
    }
    var left = double.infinity, top = double.infinity, right = -double.infinity, bottom = -double.infinity;
    for (final device in project.devices) {
      final rect = _deviceRect(device);
      left = math.min(left, rect.left);
      top = math.min(top, rect.top);
      right = math.max(right, rect.right);
      bottom = math.max(bottom, rect.bottom);
    }
    final routes = project.wires.isEmpty ? const <int, List<Offset>>{} : routesWorld();
    for (final wire in project.wires) {
      for (final point in routes[wire.id] ?? _baseRoute(wire)) {
        left = math.min(left, point.dx);
        top = math.min(top, point.dy);
        right = math.max(right, point.dx);
        bottom = math.max(bottom, point.dy);
      }
    }
    const margin = 32.0;
    final scaleX = (canvasSize.width - margin * 2) / (right - left);
    final scaleY = (canvasSize.height - margin * 2) / (bottom - top);
    zoom = math.min(1.0, math.min(scaleX, scaleY)).clamp(0.2, 3.0);
    pan = Offset(
      (canvasSize.width - (right - left) * zoom) / 2 - left * zoom,
      (canvasSize.height - (bottom - top) * zoom) / 2 - top * zoom,
    );
    notifyListeners();
  }

  Offset terminalWorld(TerminalRef ref) {
    final device = _device(ref.deviceId)!;
    final def = defOf(device);
    final terminal = def.terminals.firstWhere((t) => t.id == ref.terminal);
    return Offset(device.x + terminal.x * def.width, device.y + terminal.y * def.height);
  }

  String sideOf(TerminalRef ref) => defOf(_device(ref.deviceId)!).terminals.firstWhere((t) => t.id == ref.terminal).side;

  /// The side a wire leaves a terminal by. Usually the side the catalogue gives; but a terminal far inside a big part
  /// (the lower row of a motor's terminal box is marked "bottom" yet sits near the top of the motor) leaves by the
  /// nearest edge instead, so its wire does not loop all the way around the part. An edge is only used when the
  /// straight way out does not pass over another terminal of the same part, which would look like a connection.
  String _exitSide(TerminalRef ref) {
    final side = sideOf(ref);
    if (side == 'center') return side;
    final device = _device(ref.deviceId)!;
    final def = defOf(device);
    final rect = _deviceRect(device);
    final p = terminalWorld(ref);
    final gaps = {'top': p.dy - rect.top, 'bottom': rect.bottom - p.dy, 'left': p.dx - rect.left, 'right': rect.right - p.dx};
    final size = side == 'top' || side == 'bottom' ? rect.height : rect.width;
    if ((gaps[side] ?? 0) <= size * 0.35) return side;
    final others = [
      for (final t in def.terminals)
        if (t.id != ref.terminal) Offset(device.x + t.x * def.width, device.y + t.y * def.height),
    ];
    bool clear(String edge) => others.every((o) => switch (edge) {
          'top' => (o.dx - p.dx).abs() > 6 || o.dy >= p.dy,
          'bottom' => (o.dx - p.dx).abs() > 6 || o.dy <= p.dy,
          'left' => (o.dy - p.dy).abs() > 6 || o.dx >= p.dx,
          _ => (o.dy - p.dy).abs() > 6 || o.dx <= p.dx,
        });
    final nearest = gaps.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    for (final edge in nearest) {
      if (edge.value > size * 0.35 && edge.key != side) continue;
      if (clear(edge.key)) return edge.key;
    }
    return side;
  }

  /// How a wire leaves a terminal for the full router: the bends on the way (usually none) and the exit point past
  /// the part's edge. A terminal whose straight way out to the nearest edge passes over another terminal (the lower
  /// row of a motor's terminal box) steps around it: halfway towards that terminal, sideways into the gap between
  /// terminals, then out.
  (List<Offset>, Offset) _stub(TerminalRef ref) {
    final device = _device(ref.deviceId)!;
    final rect = _deviceRect(device);
    final p = terminalWorld(ref);
    final side = _exitSide(ref);
    final declared = sideOf(ref);
    final straight = (const <Offset>[], _exit(side, p, rect));
    if (side == 'center') return straight;
    // _exitSide fell back to the declared side only when every nearer edge was blocked; only then is a dogleg worth it.
    final gaps = {'top': p.dy - rect.top, 'bottom': rect.bottom - p.dy, 'left': p.dx - rect.left, 'right': rect.right - p.dx};
    final size = declared == 'top' || declared == 'bottom' ? rect.height : rect.width;
    if (side != declared || (gaps[declared] ?? 0) <= size * 0.35) return straight;
    final def = defOf(device);
    final others = [
      for (final t in def.terminals)
        if (t.id != ref.terminal) Offset(device.x + t.x * def.width, device.y + t.y * def.height),
    ];
    final nearest = gaps.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
    final vertical = nearest == 'top' || nearest == 'bottom';
    final toward = nearest == 'top' || nearest == 'left' ? -1.0 : 1.0;
    // The terminal in the way: the closest one along the straight line to the nearest edge.
    Offset? block;
    for (final o in others) {
      final inLine = vertical ? (o.dx - p.dx).abs() <= 6 : (o.dy - p.dy).abs() <= 6;
      final ahead = vertical ? (o.dy - p.dy) * toward > 0 : (o.dx - p.dx) * toward > 0;
      if (!inLine || !ahead) continue;
      if (block == null || (vertical ? (o.dy - p.dy).abs() < (block.dy - p.dy).abs() : (o.dx - p.dx).abs() < (block.dx - p.dx).abs())) block = o;
    }
    if (block == null) return straight;
    // Halfway to it, then sideways by half the spacing to its neighbours in that row, then out.
    final along = vertical ? (p.dy + block.dy) / 2 : (p.dx + block.dx) / 2;
    final row = [for (final o in others) if (vertical ? (o.dy - block.dy).abs() <= 6 : (o.dx - block.dx).abs() <= 6) vertical ? o.dx : o.dy];
    final here = vertical ? block.dx : block.dy;
    var spacing = double.infinity;
    for (final v in row) {
      if ((v - here).abs() > 1) spacing = math.min(spacing, (v - here).abs());
    }
    final half = spacing.isFinite ? spacing / 2 : 12.0;
    for (final sign in const [-1.0, 1.0]) {
      final across = here + sign * half;
      final ok = others.every((o) => vertical ? (o.dx - across).abs() > 4 || (o.dy - along) * toward < 0 : (o.dy - across).abs() > 4 || (o.dx - along) * toward < 0);
      if (!ok) continue;
      final bend1 = vertical ? Offset(p.dx, along) : Offset(along, p.dy);
      final bend2 = vertical ? Offset(across, along) : Offset(along, across);
      final exit = _exit(nearest, bend2, rect);
      return ([bend1, bend2], exit);
    }
    return straight;
  }

  Rect _deviceRect(PlacedDevice device) {
    final def = defOf(device);
    return Rect.fromLTWH(device.x, device.y, def.width, def.height);
  }

  Iterable<Rect> get _obstacles => project.devices.where((d) => !defOf(d).isBackLayer && !defOf(d).isJunction).map(_deviceRect);

  bool _blocks(Rect span) => _obstacles.any((rect) => rect.inflate(4).overlaps(span));

  bool _blocksHorizontal(double y, double x1, double x2) => _blocks(Rect.fromLTRB(math.min(x1, x2), y - 4, math.max(x1, x2), y + 4));

  bool _blocksVertical(double x, double y1, double y2) => _blocks(Rect.fromLTRB(x - 4, math.min(y1, y2), x + 4, math.max(y1, y2)));

  Offset _exit(String side, Offset point, Rect rect) => switch (side) {
        'center' => point,
        'top' => Offset(point.dx, rect.top - 24),
        'bottom' => Offset(point.dx, rect.bottom + 36),
        'left' => Offset(rect.left - 24, point.dy),
        _ => Offset(rect.right + 24, point.dy),
      };

  /// All wire paths in world coordinates, recomputed once whenever the geometry changes.
  Map<int, List<Offset>> routesWorld() {
    final key = _geometryKey();
    if (key != _routeKey) {
      _routeCache = _routeAll();
      _routeKey = key;
    }
    return _routeCache;
  }

  /// The wire's path in world coordinates. Jumpers run straight; other wires follow the user's route or go around
  /// devices, and runs that would lie on top of another wire are moved apart.
  List<Offset> routeWorld(Wire wire) => routesWorld()[wire.id] ?? _baseRoute(wire);

  int _routeKey = -1;
  Map<int, List<Offset>> _routeCache = const {};

  /// Changes whenever a device moves or a wire changes, so routes are worked out once per change, not per call.
  int _geometryKey() => Object.hashAll([
        // While something is dragged the quick routes are used, so the full routing runs again on release.
        _dragBefore != null,
        for (final d in project.devices) ...[d.id, d.defId, d.x, d.y, d.data['scale']],
        for (final w in project.wires) ...[w.id, w.a.key, w.b.key, w.isJumper, ...?w.points?.expand((p) => [p.x, p.y])],
      ]);

  /// Space between two wires sharing a run, in canvas pixels.
  static const double wireSpacing = 10;

  Map<int, List<Offset>> _routeAll() {
    final routes = {for (final wire in project.wires) wire.id: _baseRoute(wire)};
    final movable = {for (final wire in project.wires) if (!wire.isJumper && wire.points == null) wire.id};
    // Full routing when nothing is being dragged; the quick routes above keep dragging smooth.
    if (_dragBefore == null && movable.isNotEmpty) {
      final requests = <WireRequest>[];
      for (final wire in project.wires) {
        if (!movable.contains(wire.id)) continue;
        final a = terminalWorld(wire.a), b = terminalWorld(wire.b);
        final (viaA, exitA) = _stub(wire.a);
        final (viaB, exitB) = _stub(wire.b);
        requests.add(WireRequest(wire.id, a, exitA, exitB, b, viaA: viaA, viaB: viaB));
      }
      routes.addAll(WireRouter(_obstacles.toList()).routeAll(requests));
    }
    for (var pass = 0; pass < 2; pass++) {
      _spread(routes, movable, horizontal: true);
      _spread(routes, movable, horizontal: false);
    }
    return routes;
  }

  /// Finds straight runs lying on top of each other and moves them apart into neat lanes, like wires in a duct.
  /// Only middle runs move (never the ends at terminals), and only where the runs either side can stretch to follow.
  void _spread(Map<int, List<Offset>> routes, Set<int> movable, {required bool horizontal}) {
    final runs = <({int wire, int index, double at, double from, double to, bool fixed})>[];
    for (final entry in routes.entries) {
      final points = entry.value;
      final fixed = !movable.contains(entry.key);
      for (var k = 1; k + 2 < points.length; k++) {
        final a = points[k], b = points[k + 1];
        final along = horizontal ? (a.dx - b.dx).abs() : (a.dy - b.dy).abs();
        final across = horizontal ? (a.dy - b.dy).abs() : (a.dx - b.dx).abs();
        if (across > 0.5 || along < 1) continue;
        // The runs before and after must cross this one, so moving it only stretches them.
        bool crosses(Offset p, Offset q) => horizontal ? (p.dx - q.dx).abs() < 0.5 : (p.dy - q.dy).abs() < 0.5;
        final canMove = !fixed && crosses(points[k - 1], a) && crosses(b, points[k + 2]);
        runs.add((
          wire: entry.key,
          index: k,
          at: horizontal ? a.dy : a.dx,
          from: horizontal ? math.min(a.dx, b.dx) : math.min(a.dy, b.dy),
          to: horizontal ? math.max(a.dx, b.dx) : math.max(a.dy, b.dy),
          fixed: !canMove,
        ));
      }
    }
    if (runs.length < 2) return;
    // Group runs that overlap, directly or through others.
    final group = List<int>.generate(runs.length, (i) => i);
    int find(int i) {
      while (group[i] != i) {
        i = group[i] = group[group[i]];
      }
      return i;
    }

    for (var i = 0; i < runs.length; i++) {
      for (var j = i + 1; j < runs.length; j++) {
        final p = runs[i], q = runs[j];
        if (p.wire == q.wire || (p.at - q.at).abs() > 4) continue;
        if (math.min(p.to, q.to) - math.max(p.from, q.from) < 6) continue;
        group[find(i)] = find(j);
      }
    }
    final clusters = <int, List<int>>{};
    for (var i = 0; i < runs.length; i++) {
      clusters.putIfAbsent(find(i), () => []).add(i);
    }
    for (final members in clusters.values) {
      if (members.length < 2) continue;
      final moving = members.where((i) => !runs[i].fixed).toList()
        ..sort((i, j) {
          final order = runs[i].from.compareTo(runs[j].from);
          return order != 0 ? order : runs[i].wire.compareTo(runs[j].wire);
        });
      if (moving.isEmpty) continue;
      final anchored = moving.length < members.length;
      for (var n = 0; n < moving.length; n++) {
        // With a fixed run in the lane, the others step out to either side of it; otherwise they center on it.
        final lane = anchored ? (n ~/ 2 + 1) * (n.isEven ? 1 : -1) : n - (moving.length - 1) / 2;
        final offset = lane * wireSpacing;
        final run = runs[moving[n]];
        final points = routes[run.wire]!;
        final shift = horizontal ? Offset(0, offset) : Offset(offset, 0);
        points[run.index] += shift;
        points[run.index + 1] += shift;
      }
    }
  }

  List<Offset> _baseRoute(Wire wire) {
    final a = terminalWorld(wire.a);
    final b = terminalWorld(wire.b);
    if (wire.isJumper) return [a, b];
    final manual = wire.points;
    if (manual != null) {
      final route = <Offset>[a];
      for (final next in [...manual.map((p) => Offset(p.x, p.y)), b]) {
        final last = route.last;
        if ((last.dx - next.dx).abs() > 0.01 && (last.dy - next.dy).abs() > 0.01) route.add(Offset(last.dx, next.dy));
        route.add(next);
      }
      return route;
    }
    final sideA = _exitSide(wire.a);
    final sideB = _exitSide(wire.b);
    final rectA = _deviceRect(_device(wire.a.deviceId)!);
    final rectB = _deviceRect(_device(wire.b.deviceId)!);
    final exitA = _exit(sideA, a, rectA);
    final exitB = _exit(sideB, b, rectB);
    final lane = (wire.id % 6) * 10.0;
    bool vertical(String side) => side == 'top' || side == 'bottom';

    if (!vertical(sideA) || !vertical(sideB)) {
      // Terminals on a device's side: pick a horizontal run that clears every device, or go below them all.
      var lowest = -double.infinity;
      for (final rect in _obstacles) {
        lowest = math.max(lowest, rect.bottom);
      }
      bool clear(double y) => !_blocksHorizontal(y, exitA.dx, exitB.dx) && !_blocksVertical(exitA.dx, exitA.dy, y) && !_blocksVertical(exitB.dx, exitB.dy, y);
      final candidates = [exitA.dy, exitB.dy, rectA.top - 24 - lane, rectA.bottom + 36 + lane, rectB.bottom + 36 + lane];
      final y = candidates.firstWhere(clear, orElse: () => lowest + 36 + lane);
      return [a, exitA, Offset(exitA.dx, y), Offset(exitB.dx, y), exitB, b];
    }

    if (sideA == sideB) {
      final below = sideA == 'bottom';
      var y = below ? math.max(exitA.dy, exitB.dy) + lane : math.min(exitA.dy, exitB.dy) - lane;
      for (final rect in _obstacles) {
        if (!_blocksHorizontal(y, a.dx, b.dx)) break;
        y = below ? math.max(y, rect.bottom + 36 + lane) : math.min(y, rect.top - 24 - lane);
      }
      return [a, Offset(a.dx, y), Offset(b.dx, y), b];
    }

    // Prefer the gap between devices closest to the wire's midpoint, then go around everything.
    var right = -double.infinity;
    final middle = (a.dx + b.dx) / 2;
    final candidates = <double>[middle + lane];
    for (final rect in _obstacles) {
      right = math.max(right, rect.right);
      candidates
        ..add(rect.right + 14 + lane)
        ..add(rect.left - 14 - lane);
    }
    candidates.sort((p, q) => (p - middle).abs().compareTo((q - middle).abs()));
    final x = candidates.firstWhere(
      (candidate) => !_blocksVertical(candidate, exitA.dy, exitB.dy) && !_blocksHorizontal(exitA.dy, a.dx, candidate) && !_blocksHorizontal(exitB.dy, b.dx, candidate),
      orElse: () => right + 30 + lane,
    );
    return [a, exitA, Offset(x, exitA.dy), Offset(x, exitB.dy), exitB, b];
  }

  List<Offset> wirePoints(Wire wire) => [for (final point in routeWorld(wire)) toScreen(point)];

  Wire? wireAt(Offset screen, {double tolerance = 7}) {
    final routes = project.wires.isEmpty ? const <int, List<Offset>>{} : routesWorld();
    for (final wire in project.wires.reversed) {
      final points = [for (final point in routes[wire.id] ?? _baseRoute(wire)) toScreen(point)];
      for (var i = 0; i < points.length - 1; i++) {
        if (_distanceToSegment(screen, points[i], points[i + 1]) <= tolerance) return wire;
      }
    }
    return null;
  }

  double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lengthSquared == 0) return (p - a).distance;
    final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lengthSquared).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  // ----- Simulation

  SimResult _solve(Map<int, String> states) =>
      _solver.solve(project, states, plc: PlcInputs(external: _plcExternal, memory: _plcMemory, now: _simSeconds, stopped: _plcStopped, wall: _now()));

  /// The simulation clock in seconds, which fast-forwarding skews.
  double get _simSeconds => _now().millisecondsSinceEpoch / 1000;

  void startSimulation() {
    if (running || project.isEmpty) return;
    running = true;
    _clearSelection();
    simStates = _solver.initialStates(project);
    _timerStarted.clear();
    _plcExternal.clear();
    _plcMemory.clear();
    _plcStopped.clear();
    _plcPanels.clear();
    _timerPanels.clear();
    _thermal.clear();
    _clearDamage();
    history.clear();
    events.clear();
    _elapsed = 0;
    _skew = Duration.zero;
    _logEvent('Simulasi dimulai.');
    _apply(_solve(simStates), silent: true);
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => advance(0.1));
    notifyListeners();
  }

  void stopSimulation() {
    running = false;
    _ticker?.cancel();
    _ticker = null;
    _timerStarted.clear();
    _skew = Duration.zero;
    simStates = {};
    simResult = null;
    _lastFault = SimFault.none;
    _clearDamage();
    _resetAnimation();
    _syncLoops();
    _sound.stopShots();
    _setStatus(_editReady, StatusKind.info);
    notifyListeners();
  }

  void toggleSimulation() => running ? stopSimulation() : startSimulation();

  /// Simulated time runs ahead of the wall clock by this much after [fastForward]. Timers read [_now], so skipping
  /// ahead finishes them without waiting.
  Duration _skew = Duration.zero;
  DateTime _now() => DateTime.now().add(_skew);

  /// Moves the running simulation [seconds] ahead at once, in 0.1 s steps: timers finish, breakers heat up.
  void fastForward(double seconds) {
    for (var t = 0.0; t < seconds - 1e-9 && running; t += 0.1) {
      _skew += const Duration(milliseconds: 100);
      advance(0.1);
    }
  }

  /// Moves simulated time forward: finishes timers, heats breakers and overloads, and records the trend.
  void advance(double seconds) {
    if (!running) return;
    _elapsed += seconds;
    var changed = false;
    final next = Map<int, String>.of(simStates);
    for (final device in project.devices) {
      final started = _timerStarted[device.id];
      if (started == null) continue;
      if (_elapsed - started + 1e-9 >= timeOf(device)) {
        next[device.id] = next[device.id] == 'timing' ? 'closed' : 'open';
        changed = true;
      }
    }
    // A PLC with a timer counting runs its program again as time passes.
    final plcTicking = _plcMemory.values.any((m) => m.ticking);
    if (plcTicking) changed = true;
    final minute = _now().millisecondsSinceEpoch ~/ 60000;
    if (minute != _clockMinute) {
      _clockMinute = minute;
      if (project.devices.any((d) => defOf(d).kind == 'plc' && ladderOf(d).clocks.isNotEmpty)) changed = true;
    }
    final tripped = _heatProtection(seconds, next);
    final blast = _wear(seconds, next);
    if (changed || tripped != null || blast != null) _apply(_solve(next));
    if (tripped != null) {
      _logEvent('${tripped.tag} trip karena beban lebih.');
      _setStatus('${tripped.tag} trip karena beban lebih. Kurangi beban, matikan, lalu nyalakan lagi.', StatusKind.error);
    }
    if (blast != null) _explode(blast.$1, blast.$2);
    _sampleTrend();
    // Rising damage only refreshes the inspector twice a second; the smoke itself is drawn on the animation layer.
    final damageTick = _damage.isNotEmpty && (_elapsed * 2).floor() != ((_elapsed - seconds) * 2).floor();
    if (changed || tripped != null || blast != null || damageTick || _timerStarted.isNotEmpty || plcTicking || history.length.isEven) notifyListeners();
  }

  /// Thermal model: heat builds with the square of overcurrent, and cools below it. Breakers also trip instantly.
  PlacedDevice? _heatProtection(double seconds, Map<int, String> next) {
    final result = simResult;
    if (result == null) return null;
    PlacedDevice? tripped;
    for (final device in project.devices) {
      final def = defOf(device);
      final thermal = def.thermal;
      if (thermal == null) continue;
      if (next[device.id] != 'on' && next[device.id] != 'normal') {
        _thermal.remove(device.id);
        continue;
      }
      final rawRated = device.number('rated_current_a', def.ratedCurrent ?? 16);
      final rated = rawRated.isFinite && rawRated > 0 ? rawRated : (def.ratedCurrent ?? 16);
      if (!rated.isFinite || rated <= 0) continue;
      final ratio = (result.measures[device.id]?.amps ?? 0) / rated;
      final instant = (thermal['instant_multiple'] as num?)?.toDouble() ?? 0;
      var heat = _thermal[device.id] ?? 0;
      if (ratio > 1.13) {
        heat += seconds * (ratio * ratio - 1) / 20;
      } else {
        heat = (heat - seconds / 30).clamp(0.0, 1.0);
      }
      _thermal[device.id] = heat;
      if (heat >= 1 || (instant > 0 && ratio >= instant)) {
        next[device.id] = thermal['trip_state'] as String;
        _thermal.remove(device.id);
        tripped ??= device;
      }
    }
    return tripped;
  }

  // ----- Damage and explosions
  //
  // The solver says which devices are past their rating and how long each would survive it. Damage builds over that
  // time and cools off slowly once the stress is gone. A device that reaches full damage explodes. Only one goes off
  // at a time, a fraction of a second apart, so an overloaded panel fails in a chain.

  void _clearDamage() {
    _damage.clear();
    _toughness.clear();
    _explodedAt.clear();
    _lastBlast = -100;
    _blastStatus = null;
  }

  (PlacedDevice, Stress)? _wear(double seconds, Map<int, String> next) {
    final result = simResult;
    if (result == null) return null;
    final ready = <(PlacedDevice, Stress)>[];
    for (final device in project.devices) {
      if (next[device.id] == kExploded) continue;
      final stress = result.stress[device.id];
      var damage = _damage[device.id] ?? 0;
      if (stress == null) {
        damage -= seconds / 20;
        damage <= 0 ? _damage.remove(device.id) : _damage[device.id] = damage;
        continue;
      }
      final toughness = _toughness.putIfAbsent(device.id, () => 0.75 + _random.nextDouble() * 0.6);
      damage = math.min(1.0, damage + seconds / (stress.seconds * toughness));
      _damage[device.id] = damage;
      if (damage >= 1) ready.add((device, stress));
    }
    if (ready.isEmpty || _elapsed - _lastBlast < _blastGap) return null;
    final pick = ready[_random.nextInt(ready.length)];
    next[pick.$1.id] = kExploded;
    _damage.remove(pick.$1.id);
    _lastBlast = _elapsed;
    _blastGap = 0.35 + _random.nextDouble() * 0.55;
    return pick;
  }

  void _explode(PlacedDevice device, Stress stress) {
    _explodedAt[device.id] = _animTime;
    _sound.play('explosion', soundOn);
    final reason = _blastReason(stress);
    _logEvent('${device.tag} MELEDAK: $reason.');
    _blastStatus = '${device.tag} meledak: $reason. Hentikan simulasi, perbaiki rangkaian, lalu jalankan lagi dari awal.';
    _setStatus(_blastStatus!, StatusKind.error);
    _syncLoops();
  }

  String _blastReason(Stress stress) {
    String n(double v) => v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1).replaceAll('.', ',');
    return switch (stress.cause) {
      DamageCause.overvoltage => 'tegangan ${n(stress.volts)} V jauh di atas rating ${n(stress.rated)} V',
      DamageCause.wrongSupply => 'jenis sumber salah, ${n(stress.volts)} V masuk ke alat ${n(stress.rated)} V ${stress.volts > stress.rated ? 'AC ke DC' : 'DC ke AC'}',
      DamageCause.lowFrequency => 'frekuensi ${n(stress.hertz)} Hz terlalu rendah, arus kumparan melonjak dan terbakar',
      DamageCause.highFrequency => 'frekuensi ${n(stress.hertz)} Hz terlalu tinggi, kepanasan atau putaran lebih',
      DamageCause.lockedRotor => 'motor macet karena kehilangan fasa terlalu lama tanpa overload yang memutus',
      DamageCause.shortCircuit => 'korsleting tanpa pengaman',
    };
  }

  /// How far a device is toward exploding, from 0 to 1.
  double damageOf(PlacedDevice device) => _damage[device.id] ?? 0;

  /// Seconds since a device exploded, or null if it hasn't.
  double? explodedFor(PlacedDevice device) {
    final at = _explodedAt[device.id];
    return at == null ? null : _animTime - at;
  }

  /// Once anything has exploded the circuit is wrecked: controls stop working until the simulation is restarted.
  bool get wrecked => _explodedAt.isNotEmpty;

  /// How close a breaker or overload is to tripping, from 0 to 1.
  double heatOf(PlacedDevice device) => _thermal[device.id] ?? 0;

  void _sampleTrend() {
    final result = simResult;
    if (result == null) return;
    _sinceSample += 1;
    if (_sinceSample < 3) return;
    _sinceSample = 0;
    var watts = 0.0;
    for (final device in project.devices) {
      final kind = defOf(device).kind;
      if (kind == 'load' || kind == 'motor3' || kind == 'coil' || kind == 'plc' || kind == 'hmi') {
        watts += result.measures[device.id]?.watts ?? 0;
      }
    }
    history.add(TrendPoint(_elapsed, watts));
    if (history.length > 200) history.removeAt(0);
  }

  double get totalWatts => history.isEmpty ? 0 : history.last.watts;

  void _logEvent(String text) {
    final minutes = (_elapsed ~/ 60).toString().padLeft(2, '0');
    final secs = (_elapsed.floor() % 60).toString().padLeft(2, '0');
    events.insert(0, '$minutes:$secs  $text');
    if (events.length > 100) events.removeLast();
  }

  // ----- PLC and HMI

  PlacedDevice? get firstPlc {
    for (final device in project.devices) {
      if (defOf(device).kind == 'plc') return device;
    }
    return null;
  }

  Set<String> bitsOf(PlacedDevice plc) => plcBits(simStates[plc.id]);

  void setPlcBit(PlacedDevice plc, String ref, bool on) {
    if (!running || wrecked) return;
    final set = _plcExternal.putIfAbsent(plc.id, () => {});
    if (on ? !set.add(ref) : !set.remove(ref)) return;
    _apply(_solve(simStates));
    notifyListeners();
  }

  bool plcBitForced(PlacedDevice plc, String ref) => _plcExternal[plc.id]?.contains(ref) ?? false;

  // ----- PLC keypad and screen

  final Set<int> _plcStopped = {};
  final Map<int, PlcPanel> _plcPanels = {};

  PlcPanel plcPanel(PlacedDevice plc) => _plcPanels.putIfAbsent(plc.id, PlcPanel.new);

  /// Powered and showing something on its screen.
  bool plcPowered(PlacedDevice plc) => running && (simStates[plc.id] ?? 'off') != 'off';
  bool plcStopped(PlacedDevice plc) => _plcStopped.contains(plc.id);

  /// Seconds a PLC timer has been counting in its current phase, or null when idle.
  double? plcTimerElapsed(PlacedDevice plc, String timer) => ladderTimerElapsed(_plcMemory[plc.id]?.timers[timer], _simSeconds);

  /// The timer's output is on.
  bool plcTimerDone(PlacedDevice plc, String timer) => _plcMemory[plc.id]?.timers[timer]?.out ?? false;

  /// A counter's current value.
  int plcCount(PlacedDevice plc, String counter) => _plcMemory[plc.id]?.counts[counter] ?? 0;

  LadderProgram ladderOf(PlacedDevice plc) => _solver.programOf(plc);

  /// The timers the program drives, in order, for the Set Param screen.
  List<String> plcTimerNames(PlacedDevice plc) => ladderOf(plc).used('T');

  /// The last minute the clock blocks were evaluated in, so programs re-run when it turns.
  int _clockMinute = 0;

  /// A PLC's real-time clock: this computer's time plus whatever was set on its keypad.
  DateTime plcClockOf(PlacedDevice plc) => plcClock(plc, _now());

  /// Sets a PLC's clock to [time] (kept as an offset from this computer's clock), or back to it when null.
  void setPlcClock(PlacedDevice plc, DateTime? time) {
    if (time == null) {
      plc.data.remove('rtc_offset_s');
    } else {
      // Rounded up, so a clock set to 10:30 reads 10:30:00 straight away rather than 10:29:59.
      plc.data['rtc_offset_s'] = (time.difference(_now()).inMilliseconds / 1000).ceil();
    }
    _autosave();
    if (running) _apply(_solve(simStates));
    notifyListeners();
  }


  // ----- Timer front panels

  final Map<int, TimerPanel> _timerPanels = {};

  TimerPanel timerPanel(PlacedDevice timer) => _timerPanels.putIfAbsent(timer.id, TimerPanel.new);

  /// Seconds a timer has counted so far, or null if it isn't counting.
  double? timerElapsed(PlacedDevice timer) {
    final left = timerRemaining(timer);
    return left == null ? null : timeOf(timer) - left;
  }

  /// A live change of a timer's setting during simulation: saved, logged, not an undo step.
  void _setTimeLive(PlacedDevice timer, double seconds) {
    timer.timeSeconds = (seconds * 10).roundToDouble() / 10;
    _autosave();
    _logEvent('${timer.tag}: waktu diatur ke ${timer.timeSeconds!.toStringAsFixed(1)} dtk.');
  }

  // ----- Overload relay front and timer knobs

  /// A control on an overload relay's front was pressed or released: TEST trips it, STOP opens 95-96 for as long as
  /// it is held, RESET clears a trip (and lets the relay cool at once).
  void torKey(PlacedDevice tor, String key, bool down) {
    if (!running || wrecked) return;
    final state = simStates[tor.id] ?? defOf(tor).defaultState;
    switch (key) {
      case 'test':
        if (down && state != 'tripped') {
          _setDeviceState(tor, 'tripped');
          _logEvent('${tor.tag}: tombol TEST ditekan, relay trip.');
        }
      case 'stop':
        if (down && state == 'normal') {
          _setDeviceState(tor, 'stop');
        } else if (!down && state == 'stop') {
          _setDeviceState(tor, 'normal');
        }
      case 'reset':
        if (down && state == 'tripped') {
          _thermal.remove(tor.id);
          _setDeviceState(tor, 'normal');
          _logEvent('${tor.tag}: di-reset.');
        }
    }
  }

  /// Turns an overload relay's current dial, in 0.5 A steps within the dial's printed range.
  void setTorCurrent(PlacedDevice tor, double amps) {
    final dial = defOf(tor).torPanel?['dial'] as Map<String, dynamic>?;
    if (dial == null) return;
    final value = (amps.clamp((dial['min'] as num).toDouble(), (dial['max'] as num).toDouble()) * 2).roundToDouble() / 2;
    if (value == number(tor, 'rated_current_a')) return;
    setControl(tor, 'rated_current_a', value);
  }

  /// A control value of a part, or its default.
  double number(PlacedDevice device, String key) {
    final control = defOf(device).controls.where((c) => c.key == key).firstOrNull;
    return device.number(key, control?.fallback ?? 0);
  }

  /// Turns an analog timer's knob. While turning, only the setting changes; [done] saves it and logs the new time.
  void turnTimerKnob(PlacedDevice timer, double seconds, {bool done = false}) {
    final knob = defOf(timer).knob;
    if (knob == null) return;
    final value = seconds.clamp((knob['min'] as num).toDouble(), (knob['max'] as num).toDouble());
    timer.timeSeconds = value >= 10 ? value.roundToDouble() : (value * 10).roundToDouble() / 10;
    if (done) {
      _autosave();
      _logEvent('${timer.tag}: waktu diatur ke ${timer.timeSeconds!.toStringAsFixed(1)} dtk.');
    }
    notifyListeners();
  }

  /// Settings a dial timer clicks through, in seconds.
  static const List<double> dialSteps = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60];

  /// Clicking a dial timer turns its dial to the next setting, wrapping around.
  void _stepDialTimer(PlacedDevice timer) {
    final now = timeOf(timer);
    _setTimeLive(timer, dialSteps.firstWhere((s) => s > now + 0.05, orElse: () => dialSteps.first));
    notifyListeners();
  }

  /// A key on a digital timer's front was pressed or released. The arrows pick and change one digit of the
  /// XXX.X-second setting, which blinks while it is being set; SET finishes. The new time applies at once.
  void timerKey(PlacedDevice timer, String key, bool down) {
    final panel = timerPanel(timer);
    down ? panel.held.add(key) : panel.held.remove(key);
    if (!down || !running || wrecked) {
      notifyListeners();
      return;
    }
    final editing = panel.editing;
    if (key == 'set') {
      if (editing) {
        panel.digit = null;
      } else {
        panel.begin(TimerPanel.onesDigit);
      }
    } else if (!editing) {
      panel.begin(TimerPanel.onesDigit);
      if (key == 'up' || key == 'down') _changeDigit(timer, panel, key == 'up' ? 1 : -1);
    } else if (key == 'left' || key == 'right') {
      panel.begin((panel.digit! + (key == 'right' ? 1 : -1)) % TimerPanel.digits);
    } else {
      panel.begin(panel.digit!);
      _changeDigit(timer, panel, key == 'up' ? 1 : -1);
    }
    notifyListeners();
  }

  void _changeDigit(PlacedDevice timer, TimerPanel panel, int by) {
    final tenths = (timeOf(timer) * 10).round().clamp(1, 9999);
    final place = math.pow(10, TimerPanel.digits - 1 - panel.digit!).toInt();
    final digit = (tenths ~/ place) % 10;
    final next = (tenths + (((digit + by) % 10) - digit) * place).clamp(1, 9999);
    _setTimeLive(timer, next / 10);
  }

  static const Map<String, String> _cursorBits = {'up': 'Z1', 'right': 'Z2', 'down': 'Z3', 'left': 'Z4'};

  /// A key on the PLC's own keypad was pressed or released.
  void plcKey(PlacedDevice plc, String key, bool down) {
    final panel = plcPanel(plc);
    down ? panel.held.add(key) : panel.held.remove(key);
    if (!plcPowered(plc) || wrecked) {
      notifyListeners();
      return;
    }
    final stopped = plcStopped(plc);
    // On the cursor-key screen the arrows drive C1-C4 for as long as they are held.
    if (!stopped && panel.menu == null && panel.page == PlcPanel.keysPage && _cursorBits.containsKey(key)) {
      setPlcBit(plc, _cursorBits[key]!, down);
      return;
    }
    if (!down) {
      notifyListeners();
      return;
    }
    final vertical = key == 'up' || key == 'down';
    void move(int count) => panel.cursor = (panel.cursor + (key == 'down' ? 1 : -1)) % count;
    switch (panel.menu) {
      case null when stopped:
        if (key == 'ok') {
          _plcStopped.remove(plc.id);
          panel.page = 0;
          _apply(_solve(simStates));
          _logEvent('${plc.tag} dijalankan dari panel (RUN).');
        }
      case null:
        if (key == 'left' || key == 'right') {
          panel.page = (panel.page + (key == 'right' ? 1 : -1)) % PlcPanel.pages.length;
        } else if (key == 'esc') {
          if (panel.page == PlcPanel.keysPage) {
            panel.page = 0;
          } else {
            panel.openMenu('main');
          }
        }
      case 'main':
        if (key == 'esc') panel.menu = null;
        if (vertical) move(PlcPanel.mainItems.length);
        if (key == 'ok') {
          switch (panel.cursor) {
            case 0:
              panel.openMenu('confirm');
            case 1:
              panel.openMenu('params');
            case 2:
              final now = plcClockOf(plc);
              panel
                ..openMenu('clock')
                ..clockDay = now.weekday
                ..clockMinute = now.hour * 60 + now.minute;
            default:
              setPlcClock(plc, null);
              _logEvent('${plc.tag}: jam disamakan dengan jam komputer.');
              panel.menu = null;
          }
        }
      case 'clock':
        // Left and right pick day, hour or minute; up and down change it; OK sets the clock.
        if (key == 'left' || key == 'right') panel.cursor = (panel.cursor + (key == 'right' ? 1 : -1)) % 3;
        if (vertical) {
          final by = key == 'up' ? 1 : -1;
          switch (panel.cursor) {
            case 0:
              panel.clockDay = (panel.clockDay - 1 + by) % 7 + 1;
            case 1:
              panel.clockMinute = (panel.clockMinute + by * 60) % 1440;
            default:
              panel.clockMinute = panel.clockMinute ~/ 60 * 60 + (panel.clockMinute % 60 + by) % 60;
          }
        }
        if (key == 'esc') panel.openMenu('main', cursor: 2);
        if (key == 'ok') {
          final now = plcClockOf(plc);
          final day = DateTime(now.year, now.month, now.day).add(Duration(days: panel.clockDay - now.weekday));
          setPlcClock(plc, day.add(Duration(minutes: panel.clockMinute)));
          _logEvent('${plc.tag}: jam diatur ke ${kPlcDays[panel.clockDay - 1]} ${clockText(panel.clockMinute)}.');
          panel.menu = null;
        }
      case 'confirm':
        if (key == 'esc') panel.openMenu('main');
        if (vertical) move(2);
        if (key == 'ok') {
          if (panel.cursor == 1) {
            _plcStopped.add(plc.id);
            for (final bit in _cursorBits.values) {
              _plcExternal[plc.id]?.remove(bit);
            }
            _apply(_solve(simStates));
            _logEvent('${plc.tag} dihentikan dari panel (STOP).');
            panel.menu = null;
          } else {
            panel.openMenu('main');
          }
        }
      case 'params':
        final timers = plcTimerNames(plc);
        if (key == 'esc') panel.openMenu('main', cursor: 1);
        if (vertical && timers.isNotEmpty) move(timers.length);
        if (key == 'ok' && timers.isNotEmpty) {
          panel.editValue = ladderOf(plc).timer(timers[panel.cursor]).preset;
          panel.menu = 'edit';
        }
      case 'edit':
        final step = vertical ? 0.5 : 0.1;
        if (key == 'up' || key == 'right') panel.editValue = math.min(999, panel.editValue + step);
        if (key == 'down' || key == 'left') panel.editValue = math.max(0.1, panel.editValue - step);
        panel.editValue = (panel.editValue * 10).roundToDouble() / 10;
        if (key == 'esc') panel.menu = 'params';
        if (key == 'ok') {
          final program = ladderOf(plc);
          final timer = plcTimerNames(plc)[panel.cursor];
          program.timer(timer).preset = panel.editValue;
          plc.data
            ..remove('program')
            ..['ladder'] = program.toJson();
          _autosave();
          _apply(_solve(simStates));
          _logEvent('${plc.tag}: preset $timer diubah ke ${panel.editValue.toStringAsFixed(1)} dtk.');
          panel.menu = 'params';
        }
    }
    notifyListeners();
  }

  void setProgram(PlacedDevice plc, LadderProgram program) {
    if (running) return;
    _snapshot();
    plc.data
      ..remove('program')
      ..['ladder'] = program.toJson();
    _commit('Program ${plc.tag} disimpan.');
  }

  void setHmiWidgets(PlacedDevice hmi, List<Map<String, dynamic>> widgets) {
    if (running) return;
    _snapshot();
    hmi.data['widgets'] = widgets;
    _commit('Layar ${hmi.tag} diperbarui.');
  }

  // ----- Control values

  void beginControlEdit() {
    if (!running) _dragBefore = jsonEncode(project.toJson());
  }

  void setControl(PlacedDevice device, String key, double value) {
    if (running && wrecked) return;
    device.data[key] = value;
    if (running) _apply(_solve(simStates));
    notifyListeners();
  }

  void endControlEdit() {
    if (!running) endMove();
  }

  void setTool(CanvasTool value) {
    tool = value;
    notifyListeners();
  }


  void clickDevice(PlacedDevice device) {
    final def = defOf(device);
    if (running && !wrecked && def.isTimer && def.timerPanel == null) return _stepDialTimer(device);
    if (!running || wrecked || !def.isClickable) return;
    final map = def.operate!['map'] as Map<String, dynamic>;
    final next = map[simStates[device.id]] as String?;
    if (next != null) _setDeviceState(device, next);
  }

  void pressDevice(PlacedDevice device, bool pressed) {
    final def = defOf(device);
    if (!running || wrecked || !def.isHold) return;
    final operate = def.operate!;
    // Starter devices name both states; imported ones give a map from the resting state to the held one.
    final next = operate.containsKey('pressed')
        ? operate[pressed ? 'pressed' : 'released'] as String
        : pressed
            ? (operate['map'] as Map<String, dynamic>)[def.defaultState] as String
            : def.defaultState;
    _setDeviceState(device, next);
  }

  void _setDeviceState(PlacedDevice device, String next) {
    if (simStates[device.id] == next) return;
    final changed = Map<int, String>.of(simStates)..[device.id] = next;
    _apply(_solve(changed), operated: device.id, operatedFrom: simStates[device.id]);
    notifyListeners();
  }

  void _apply(SimResult result, {bool silent = false, int? operated, String? operatedFrom}) {
    final before = Map<int, String>.of(simStates);
    if (operated != null) before[operated] = operatedFrom!;
    simStates = result.states;
    simResult = result;
    if (!silent) {
      _playChanges(before, result.states);
      _logChanges(before, result.states);
    }
    final isShort = result.fault == SimFault.shortCircuitTripped || result.fault == SimFault.shortCircuitUnprotected;
    if (isShort && _lastFault != result.fault) {
      _sound.play('short_circuit', soundOn);
      _logEvent('Korsleting terdeteksi.');
    }
    _lastFault = result.fault;
    _syncTimers();
    _plcMemory
      ..clear()
      ..addAll(result.plcMemory);
    _syncLoops();
    switch (result.fault) {
      case SimFault.shortCircuitTripped:
        _setStatus('Korsleting. ${tagOf(result.trippedDeviceId!)} trip. Perbaiki rangkaian, matikan pengamannya, lalu nyalakan lagi.', StatusKind.error);
      case SimFault.shortCircuitUnprotected:
        _setStatus('Korsleting tanpa proteksi. Hentikan simulasi, perbaiki sambungan, dan pasang pengaman di jalur fasa.', StatusKind.error);
      case SimFault.unstable:
        _setStatus('Rangkaian tidak stabil: perangkat terus berganti kondisi.', StatusKind.warning);
      case SimFault.none:
        if (!project.devices.any((d) => defOf(d).kind == 'source')) {
          _setStatus('Belum ada sumber listrik. Hentikan simulasi, lalu tambahkan sumber.', StatusKind.warning);
        } else if (result.warnings.isNotEmpty) {
          _setStatus('Simulasi berjalan dengan ${result.warnings.length} peringatan. Lihat panel kanan.', StatusKind.warning);
        } else {
          _setStatus(_runningSummary(result), StatusKind.running);
        }
    }
    if (_blastStatus != null && result.fault == SimFault.none) _setStatus(_blastStatus!, StatusKind.error);
  }

  SimFault _lastFault = SimFault.none;

  // ----- Animation
  //
  // The solver gives each instant's settled answer. These values chase it over time, so motors have inertia and
  // readings fall away instead of jumping.

  /// Spin-up gains speed at a steady rate (share of full speed per second), then settles over [_spinSettle] seconds.
  static const double _spinUpRate = 0.45;
  static const double _spinSettle = 0.3;
  static const double _coast = 2.6;
  static const double _ampsRise = 0.18;
  static const double _ampsFall = 0.75;

  final Map<int, double> _rotorSpeed = {};
  final Map<int, double> _rotorAngle = {};
  final Map<int, int> _rotorDirection = {};
  final Map<int, double> _shownAmps = {};
  final Map<int, double> _shownWatts = {};

  /// Energy counted by each meter since the simulation started, in kWh.
  final Map<int, double> _energy = {};
  double energyOf(PlacedDevice device) => _energy[device.id] ?? 0;
  final Map<int, double> _shownVolts = {};
  final Map<int, double> _shownHertz = {};
  final Map<int, double> _wireShown = {};
  final Map<int, double> _wirePhase = {};
  final Map<int, bool> _wireIsDc = {};
  final Map<int, double> _lampGlow = {};
  final Set<int> _wasStar = {};
  double _animTime = 0;
  double _sinceMix = 0;

  /// Repaints the animated layers without rebuilding the rest of the screen.
  final ChangeNotifier animationFrame = ChangeNotifier();

  double get animTime => _animTime;
  double rotorSpeed(PlacedDevice device) => _rotorSpeed[device.id] ?? 0;
  double rotorAngle(PlacedDevice device) => _rotorAngle[device.id] ?? 0;
  double wireFlow(Wire wire) => _wireShown[wire.id] ?? 0;
  double wirePhase(Wire wire) => _wirePhase[wire.id] ?? 0;
  bool wireIsDc(Wire wire) => _wireIsDc[wire.id] ?? false;
  double lampGlow(PlacedDevice device) => _lampGlow[device.id] ?? 0;

  /// A device's reading as shown to people, easing toward its value.
  Measure shownMeasure(PlacedDevice device) {
    final raw = simResult?.measures[device.id];
    if (raw == null) return const Measure();
    return Measure(
      volts: _shownVolts[device.id] ?? raw.volts,
      amps: _shownAmps[device.id] ?? raw.amps,
      watts: _shownWatts[device.id] ?? raw.watts,
      hertz: _shownHertz[device.id] ?? raw.hertz,
    );
  }

  /// Voltage and frequency drain away when the supply is lost, but follow a live control such as a slider promptly.
  double _easeSupply(double shown, double raw, double seconds, double snap) {
    final next = _ease(shown, raw, seconds, raw == 0 ? _ampsFall : _ampsRise);
    return next < snap && raw == 0 ? 0 : next;
  }

  double _ease(double current, double target, double seconds, double tau) => target + (current - target) * math.exp(-seconds / tau);

  double _rotorTarget(PlacedDevice device, SimResult result) {
    final state = simStates[device.id];
    final def = defOf(device);
    if (def.kind == 'motor_dc') {
      if (state != 'run_fwd' && state != 'run_rev') return 0;
      final volts = result.measures[device.id]?.volts ?? def.load!.volts;
      return (volts / def.load!.volts).clamp(0.0, 1.25);
    }
    if (state == 'run_fwd' || state == 'run_rev') return result.starMotors.contains(device.id) ? 0.72 : 1.0;
    return state == 'on' ? 1.0 : 0.0;
  }

  /// Advances the animation by one frame.
  void animate(double seconds) {
    final result = simResult;
    if (!running || result == null) return;
    _animTime += seconds;
    var changing = false;

    for (final device in project.devices) {
      final def = defOf(device);
      if (def.rotor != null || spinsAudibly(def)) {
        final state = simStates[device.id];
        if (state == 'run_rev') _rotorDirection[device.id] = -1;
        if (state == 'run_fwd' || state == 'on') _rotorDirection[device.id] = 1;
        // The moment of changeover: the windings are briefly disconnected, so the rotor loses a little speed.
        final star = result.starMotors.contains(device.id);
        if (_wasStar.contains(device.id) && !star && (state == 'run_fwd' || state == 'run_rev')) {
          _rotorSpeed[device.id] = (_rotorSpeed[device.id] ?? 0) * 0.86;
        }
        star ? _wasStar.add(device.id) : _wasStar.remove(device.id);

        final target = _rotorTarget(device, result);
        final speed = _rotorSpeed[device.id] ?? 0;
        // A motor winds up steadily rather than leaping most of the way at once, so speed and sound build audibly.
        var next = target >= speed
            ? math.min(target, speed + seconds * math.min(_spinUpRate, (target - speed) / _spinSettle))
            : _ease(speed, target, seconds, _coast);
        if (next < 0.004 && target == 0) next = 0;
        _rotorSpeed[device.id] = next;
        _rotorAngle[device.id] = (_rotorAngle[device.id] ?? 0) + seconds * next * 2.4 * math.pi * 2 * (_rotorDirection[device.id] ?? 1);
        if ((next - target).abs() > 0.002) changing = true;
      }
      final raw = result.measures[device.id];
      final amps = _shownAmps[device.id] ?? 0;
      final watts = _shownWatts[device.id] ?? 0;
      final rawAmps = raw?.amps ?? 0;
      final rawWatts = raw?.watts ?? 0;
      final nextAmps = _ease(amps, rawAmps, seconds, rawAmps >= amps ? _ampsRise : _ampsFall);
      final nextWatts = _ease(watts, rawWatts, seconds, rawWatts >= watts ? _ampsRise : _ampsFall);
      _shownAmps[device.id] = nextAmps < 0.0005 && rawAmps == 0 ? 0 : nextAmps;
      _shownWatts[device.id] = nextWatts < 0.05 && rawWatts == 0 ? 0 : nextWatts;
      if (def.meter != null) _energy[device.id] = (_energy[device.id] ?? 0) + _shownWatts[device.id]! * seconds / 3.6e6;
      final nextVolts = _easeSupply(_shownVolts[device.id] ?? 0, raw?.volts ?? 0, seconds, 0.05);
      final nextHertz = _easeSupply(_shownHertz[device.id] ?? 0, raw?.hertz ?? 0, seconds, 0.05);
      _shownVolts[device.id] = nextVolts;
      _shownHertz[device.id] = nextHertz;
      if ((nextAmps - rawAmps).abs() > 0.001 || (nextVolts - (raw?.volts ?? 0)).abs() > 0.02 || (nextHertz - (raw?.hertz ?? 0)).abs() > 0.02) changing = true;
      if (def.glow != null) {
        final target = simStates[device.id] == 'on' ? 1.0 : 0.0;
        final glow = _ease(_lampGlow[device.id] ?? 0, target, seconds, target > 0 ? 0.09 : 0.2);
        _lampGlow[device.id] = glow;
      }
    }

    for (final wire in project.wires) {
      final raw = result.wireAmps[wire.id] ?? 0;
      final shown = _wireShown[wire.id] ?? 0;
      final next = _ease(shown, raw, seconds, raw.abs() >= shown.abs() ? _ampsRise : _ampsFall);
      _wireShown[wire.id] = next.abs() < 0.002 && raw == 0 ? 0 : next;
      final label = result.at(wire.a);
      if (label != null) _wireIsDc[wire.id] = label.startsWith('DC');
      // Speed rises with current, compressed so a small coil and a big motor are both visible.
      final speed = next == 0 ? 0.0 : (46 + 40 * math.log(1 + next.abs())).clamp(46.0, 210.0) * next.sign;
      _wirePhase[wire.id] = (_wirePhase[wire.id] ?? 0) + speed * seconds;
    }

    _sinceMix += seconds;
    if (_sinceMix >= 0.08) {
      _sinceMix = 0;
      _syncLoops();
      // Readouts in the side panels follow the easing; while the assistant tests, nothing is selected and only the
      // canvas needs it.
      if (changing) aiLocked ? viewVersion.value++ : notifyListeners();
    }
    animationFrame.notifyListeners();
  }

  void _mixRotorSounds() {
    final speeds = <String, double>{};
    for (final device in project.devices) {
      final def = defOf(device);
      if ((def.rotor == null && !spinsAudibly(def)) || def.loopSounds.isEmpty) continue;
      final name = def.loopSounds.values.first;
      speeds[name] = math.max(speeds[name] ?? 0, _rotorSpeed[device.id] ?? 0);
    }
    speeds.forEach((name, speed) {
      if (!layeredLoops.contains(name)) {
        _sound.mixLoop(name, math.min(1.0, speed * 4) * (0.3 + 0.7 * speed), 0.32 + 0.68 * speed);
        return;
      }
      final gain = loopGain[name] ?? 1.0;
      rotorLayerMix(speed).forEach((layer, mix) => _sound.mixLoop('${name}_${(layer * 100).round()}', mix.$1 * gain, mix.$2));
    });
  }

  /// Rotor loops that also exist rendered at these speeds (share of full), as `<name>_<percent>.wav`, made by
  /// tools/make_motor_sounds.py. Windows keeps pitch when it slows playback, so the rising pitch of a motor winding
  /// up comes from crossfading these, not from the playback rate.
  static const Set<String> layeredLoops = {'motor_run_3p', 'pump_run', 'motor_run_dc'};

  /// How loud each layered loop plays at full speed: a small pump sits below a 2.2 kW motor.
  static const Map<String, double> loopGain = {'pump_run': 0.75, 'motor_run_dc': 0.7};

  /// Machines with no rotor drawn whose sound still winds up and down, so they keep a speed of their own.
  static bool spinsAudibly(DeviceDef def) => def.loopSounds.values.any(layeredLoops.contains);
  static const List<double> rotorLayers = [0.12, 0.18, 0.26, 0.36, 0.48, 0.62, 0.78, 1.0];

  static List<String> rotorLayerNames(String base) => [for (final s in rotorLayers) '${base}_${(s * 100).round()}'];

  /// Volume and playback rate for each layer at a rotor speed: the two layers around the speed share it with an
  /// equal-power crossfade, the rest are silent. Loudness grows with speed and fades in from standstill.
  static Map<double, (double, double)> rotorLayerMix(double speed) {
    final mix = {for (final s in rotorLayers) s: (0.0, 1.0)};
    final v = speed.clamp(0.0, 1.0);
    final gain = 0.35 + 0.65 * v;
    // Playback rate stays 1: on Windows, changing it on a playing loop stalls the player and stops it looping.
    if (v <= rotorLayers.first) {
      final first = rotorLayers.first;
      mix[first] = (gain * v / first, 1.0);
      return mix;
    }
    for (var i = 0; i < rotorLayers.length - 1; i++) {
      final lo = rotorLayers[i], hi = rotorLayers[i + 1];
      if (v > hi) continue;
      final f = (v - lo) / (hi - lo);
      mix[lo] = (gain * math.cos(f * math.pi / 2), 1.0);
      mix[hi] = (gain * math.sin(f * math.pi / 2), 1.0);
      break;
    }
    return mix;
  }

  void _resetAnimation() {
    _rotorSpeed.clear();
    _rotorAngle.clear();
    _rotorDirection.clear();
    _shownAmps.clear();
    _shownWatts.clear();
    _energy.clear();
    _shownVolts.clear();
    _shownHertz.clear();
    _wireShown.clear();
    _wirePhase.clear();
    _wireIsDc.clear();
    _lampGlow.clear();
    _wasStar.clear();
    _animTime = 0;
  }

  void _logChanges(Map<int, String> before, Map<int, String> after) {
    for (final device in project.devices) {
      final from = before[device.id];
      final to = after[device.id];
      if (from == to || to == null || to == kExploded) continue;
      final kind = defOf(device).kind;
      if (kind == 'motor3' || kind == 'motor_dc' || (kind == 'load' && defOf(device).name.contains('Motor'))) {
        _logEvent('${device.tag} ${to == 'stopped' || to == 'off' ? 'berhenti' : 'berjalan'}.');
      } else if (to == 'tripped') {
        _logEvent('${device.tag} trip.');
      } else if (kind == 'coil' && defOf(device).category == 'contactors') {
        _logEvent('${device.tag} ${to == 'closed' ? 'menutup' : 'membuka'}.');
      }
    }
  }

  /// The continuous sounds the current simulation state calls for.
  Set<String> activeLoopSounds() {
    final result = simResult;
    if (!running || !soundOn || result == null) return const {};
    final names = <String>{};
    for (final device in project.devices) {
      final def = defOf(device);
      // A rotor keeps sounding while it coasts down, so its sound follows speed rather than state.
      if (def.rotor != null || spinsAudibly(def)) {
        if (def.loopSounds.isEmpty) continue;
        final base = def.loopSounds.values.first;
        if (layeredLoops.contains(base)) {
          // Every speed layer runs for the whole simulation, silent until needed, so a start is heard at once
          // instead of after the second it takes to load a file.
          names.addAll(rotorLayerNames(base));
        } else if ((_rotorSpeed[device.id] ?? 0) > 0.015 || _rotorTarget(device, result) > 0) {
          names.add(base);
        }
        continue;
      }
      final loop = def.loopSounds[simStates[device.id]];
      if (loop != null) names.add(loop);
    }
    // A motor missing a phase is energized but can't turn, so it growls.
    if (result.warnings.any((w) => w.code == WarningCode.singlePhasing)) names.add('motor_stall');
    // An overheating part fries and crackles before it goes, and the wreck keeps crackling for a moment after.
    final frying = _damage.values.any((d) => d > 0.3) || _explodedAt.values.any((at) => _animTime - at < 2.5);
    if (frying) names.add('sizzle');
    return names;
  }

  /// Mixes first, so a loop that starts now starts at its current level.
  void _syncLoops() {
    _mixRotorSounds();
    _sound.setLoops(activeLoopSounds());
  }

  void _syncTimers() {
    for (final device in project.devices) {
      final def = defOf(device);
      if (!def.isTimer) continue;
      final state = simStates[device.id];
      final counting = state == 'timing' || state == 'timing_off';
      if (counting) {
        _timerStarted.putIfAbsent(device.id, () => _elapsed);
      } else {
        _timerStarted.remove(device.id);
      }
    }
  }

  String _runningSummary(SimResult result) {
    final active = project.devices.where((d) {
      final state = result.states[d.id];
      return defOf(d).kind == 'motor3' ? state != 'stopped' : (defOf(d).kind == 'load' && state == 'on');
    }).length;
    final total = project.devices.where((d) => defOf(d).kind == 'load' || defOf(d).kind == 'motor3').length;
    return total == 0 ? 'Simulasi berjalan.' : 'Simulasi berjalan. $active dari $total beban aktif.';
  }

  void _playChanges(Map<int, String> before, Map<int, String> after) {
    for (final device in project.devices) {
      final from = before[device.id];
      final to = after[device.id];
      if (from == null || from == to) continue;
      final sound = defOf(device).sounds['${from}_to_$to'];
      if (sound != null) _sound.play(sound, soundOn);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sound.setLoops(const {});
    animationFrame.dispose();
    super.dispose();
  }

  // ----- Preferences

  void toggleTheme() {
    dark = !dark;
    _prefs?.setBool(_themeKey, dark);
    notifyListeners();
  }

  void toggleWireNumbers() {
    wireNumbersOn = !wireNumbersOn;
    _prefs?.setBool(_numbersKey, wireNumbersOn);
    notifyListeners();
  }

  /// The number shown on a wire's markers: the one typed in its properties, or else the number of its potential.
  /// Every wire on one potential (joined by wires, jumpers or junctions) carries the same number, the way panel
  /// builders mark them. A potential that starts at a supply terminal takes that terminal's name (L1, L2, L3, N, PE);
  /// the rest are numbered 1, 2, 3 from the top left.
  String wireLabel(Wire wire) {
    if (wire.number.isNotEmpty) return wire.number;
    final key = Object.hashAll([for (final w in project.wires) ...[w.id, w.a.key, w.b.key], for (final d in project.devices) ...[d.id, d.x, d.y]]);
    if (key != _netKey) {
      _netLabels = _numberNets();
      _netKey = key;
    }
    return _netLabels[wire.id] ?? '';
  }

  int _netKey = -1;
  Map<int, String> _netLabels = const {};

  Map<int, String> _numberNets() {
    final parent = <String, String>{};
    String find(String k) {
      var root = k;
      while (parent[root] != null && parent[root] != root) {
        root = parent[root]!;
      }
      parent[k] = root;
      return root;
    }

    for (final w in project.wires) {
      parent.putIfAbsent(w.a.key, () => w.a.key);
      parent.putIfAbsent(w.b.key, () => w.b.key);
      final a = find(w.a.key), b = find(w.b.key);
      if (a != b) parent[a] = b;
    }
    // Name a potential after a supply terminal on it; otherwise order potentials by their top-left terminal.
    final names = <String, String>{};
    final firstPoint = <String, Offset>{};
    for (final w in project.wires) {
      for (final end in [w.a, w.b]) {
        final net = find(end.key);
        final device = _device(end.deviceId);
        if (device == null) continue;
        final def = defOf(device);
        if (def.kind == 'source' && !names.containsKey(net)) names[net] = end.terminal;
        final p = terminalWorld(end);
        final seen = firstPoint[net];
        if (seen == null || p.dy < seen.dy - 1 || ((p.dy - seen.dy).abs() <= 1 && p.dx < seen.dx)) firstPoint[net] = p;
      }
    }
    final unnamed = firstPoint.keys.where((n) => !names.containsKey(n)).toList()
      ..sort((p, q) {
        final a = firstPoint[p]!, b = firstPoint[q]!;
        return (a.dy - b.dy).abs() > 1 ? a.dy.compareTo(b.dy) : a.dx.compareTo(b.dx);
      });
    for (var i = 0; i < unnamed.length; i++) {
      names[unnamed[i]] = '${i + 1}';
    }
    return {for (final w in project.wires) w.id: names[find(w.a.key)] ?? ''};
  }

  void toggleGuide() {
    guideHidden = !guideHidden;
    _prefs?.setBool(_guideKey, guideHidden);
    notifyListeners();
  }

  void toggleSound() {
    soundOn = !soundOn;
    _prefs?.setBool(_soundKey, soundOn);
    _syncLoops();
    notifyListeners();
  }

  void reportStatus(String message, StatusKind kind) {
    _setStatus(message, kind);
    notifyListeners();
  }
}

enum CanvasTool { select, pan }

class TrendPoint {
  const TrendPoint(this.seconds, this.watts);

  final double seconds;
  final double watts;
}

class WireSummary {
  WireSummary(this.isJumper, this.gauge);

  final bool isJumper;
  final double gauge;
  int count = 0;
}

/// How the assistant's cursors reach into the device library: where a device's group header is, and opening that
/// group, scrolling to the device and returning where its card is. All rects are global.
class LibraryBridge {
  const LibraryBridge({required this.groupRect, required this.isOpen, required this.reveal});

  final Rect? Function(String defId) groupRect;
  final bool Function(String defId) isOpen;
  final Future<Rect?> Function(String defId) reveal;
}

/// A digital timer's setting mode and held keys. The setting shows as XXX.X seconds; [digit] is the one being set.
class TimerPanel {
  static const int digits = 4;
  static const int onesDigit = 2;

  /// Setting mode ends by itself after this long without a key press.
  static const Duration idle = Duration(seconds: 6);

  int? digit;
  DateTime _touched = DateTime.fromMillisecondsSinceEpoch(0);
  final Set<String> held = {};

  bool get editing => digit != null && DateTime.now().difference(_touched) < idle;

  void begin(int digit) {
    this.digit = digit;
    _touched = DateTime.now();
  }
}

/// What a PLC's own screen is showing and which of its keys are held.
class PlcPanel {
  /// Screens shown in RUN, stepped through with the left and right keys.
  static const List<String> pages = ['home', 'inputs', 'outputs', 'memory', 'timers', 'clocks', 'keys'];

  /// The keypad menu, opened with ESC.
  static const List<String> mainItems = ['Stop', 'Set Param', 'Set Clock', 'Jam = PC'];
  static final int keysPage = pages.indexOf('keys');

  int page = 0;

  /// null, 'main', 'confirm', 'params', 'edit' or 'clock'.
  String? menu;
  int cursor = 0;
  double editValue = 0;

  /// The clock being set: ISO weekday and minute of the day.
  int clockDay = 1;
  int clockMinute = 0;
  final Set<String> held = {};

  void openMenu(String name, {int cursor = 0}) {
    menu = name;
    this.cursor = cursor;
  }
}
