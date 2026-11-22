import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../file_io.dart';
import '../ui/canvas_view.dart' show kLiveColors;
import '../ui/theme.dart';
import 'relay_model.dart';

const String kRelayEditorName = 'BuildRelay';

/// Opens BuildRelay on an empty sheet. There are no ready-made circuits: students draw every diagram themselves.
Future<void> showBuildRelay(BuildContext context) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RelayEditor()));

/// Drawing and simulating relay control as a schematic: supplies, buttons, contacts, coils, timers, protection and
/// loads, joined by wires drawn point to point. Run it, press the buttons, and watch contacts, coils, lamps and motors.
class RelayEditor extends StatefulWidget {
  const RelayEditor({super.key, this.initial});

  /// A sheet to start from instead of an empty one (used by tests; people always start empty).
  final RelaySheet? initial;

  @override
  State<RelayEditor> createState() => _RelayEditorState();
}

class _RelayEditorState extends State<RelayEditor> {
  RelaySheet sheet = RelaySheet();
  String fileName = 'diagram';
  bool dirty = false;
  final _undo = <String>[];
  final _redo = <String>[];
  final _focus = FocusNode(debugLabel: 'relay');
  final _canvasKey = GlobalKey();
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  // View: screen = world * zoom + pan, world = grid units * RelaySheet.unit.
  Offset pan = const Offset(60, 40);
  double zoom = 1;

  // Editing.
  int? selectedSymbol;
  int? selectedWire;
  String? placing;
  Offset? pointer;
  RelayEnd? pending;
  final List<Offset> corners = [];
  int? _dragging;
  Offset _dragStart = Offset.zero;
  (int, int) _dragOrigin = (0, 0);
  String? _dragBefore;
  bool _panning = false;

  // Simulation.
  RelaySim? sim;
  RelayResult? result;
  final _clock = Stopwatch();
  Timer? _ticker;
  int? _held;
  final Map<int, int> _sel3Last = {};

  bool get simulating => sim != null;
  double get _now => _clock.elapsedMilliseconds / 1000;

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) sheet = widget.initial!;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _focus.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------------------------------------ coordinates

  Offset gridOf(Offset screen) => (screen - pan) / (zoom * RelaySheet.unit);
  Offset screenOf(Offset grid) => grid * (zoom * RelaySheet.unit) + pan;
  Offset _snap(Offset grid) => Offset(grid.dx.roundToDouble(), grid.dy.roundToDouble());

  RelayEnd? pinAt(Offset screen) {
    RelayEnd? best;
    var bestDistance = 10.0;
    for (final s in sheet.symbols) {
      for (final name in s.def.pins.keys) {
        final d = (screenOf(s.pin(name)) - screen).distance;
        if (d < bestDistance) {
          bestDistance = d;
          best = RelayEnd(s.id, name);
        }
      }
    }
    return best;
  }

  RelaySymbol? symbolAt(Offset screen) {
    final g = gridOf(screen);
    for (final s in sheet.symbols.reversed) {
      if (s.type == 'node') continue;
      if (s.rect.inflate(0.2).contains(g)) return s;
    }
    return null;
  }

  RelayWire? wireAt(Offset screen) {
    for (final w in sheet.wires.reversed) {
      final points = sheet.path(w).map(screenOf).toList();
      for (var i = 0; i + 1 < points.length; i++) {
        if (_distance(screen, points[i], points[i + 1]) <= 6) return w;
      }
    }
    return null;
  }

  static double _distance(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final length = ab.dx * ab.dx + ab.dy * ab.dy;
    if (length == 0) return (p - a).distance;
    final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / length).clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }

  // ------------------------------------------------------------------------------------------------ editing

  void _snapshot() {
    _undo.add(jsonEncode(sheet.toJson()));
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
    dirty = true;
  }

  void _clearTransient() {
    pending = null;
    corners.clear();
    placing = null;
    _dragging = null;
    _dragBefore = null;
    _panning = false;
    _held = null;
    _sel3Last.clear();
  }

  void _restore(String text) {
    sheet = RelaySheet.fromJson(jsonDecode(text) as Map<String, dynamic>);
    selectedSymbol = null;
    selectedWire = null;
    _clearTransient();
  }

  void undo() {
    if (_undo.isEmpty || simulating) return;
    _redo.add(jsonEncode(sheet.toJson()));
    setState(() => _restore(_undo.removeLast()));
  }

  void redo() {
    if (_redo.isEmpty || simulating) return;
    _undo.add(jsonEncode(sheet.toJson()));
    setState(() => _restore(_redo.removeLast()));
  }

  /// A new symbol of [type] with its top-left at grid point [at]: tagged like a panel drawing, contacts taking the
  /// tag of the last coil, timer or overload relay they can follow.
  void place(String item, Offset at) {
    final (type, preset) = _item(item);
    final def = kRelayTypeById[type]!;
    _snapshot();
    var tag = sheet.nextTag(def.prefix);
    if (def.isContact) {
      final owner = sheet.symbols.lastWhere((s) => def.follows!.contains(s.type), orElse: () => RelaySymbol(id: -1, type: 'node', tag: '', x: 0, y: 0));
      tag = owner.id >= 0 ? owner.tag : '${def.prefix}1';
    }
    final params = <String, dynamic>{};
    if (type == 'supply') {
      const order = ['L1', 'N', 'L2', 'L3', 'PE'];
      final used = {for (final s in sheet.symbols.where((s) => s.type == 'supply')) s.supply};
      params['supply'] = preset ?? order.firstWhere((l) => !used.contains(l), orElse: () => 'L1');
    }
    if (kRelayTimers.contains(type)) params['seconds'] = type == 'timer_cyc' ? 1.0 : 3.0;
    if (type == 'text') params['text'] = 'Teks';
    final symbol = RelaySymbol(id: sheet.nextId(), type: type, tag: tag, x: at.dx.round(), y: at.dy.round(), params: params);
    sheet.symbols.add(symbol);
    selectedSymbol = symbol.id;
    selectedWire = null;
  }

  /// A palette item is a symbol type, or for supplies the type and its label: 'supply:N'.
  static (String, String?) _item(String item) {
    final colon = item.indexOf(':');
    return colon < 0 ? (item, null) : (item.substring(0, colon), item.substring(colon + 1));
  }

  void _placeAtScreen(String type, Offset screen) {
    final def = kRelayTypeById[_item(type).$1]!;
    final g = gridOf(screen);
    setState(() => place(type, _snap(Offset(g.dx - def.size.width / 2, g.dy - def.size.height / 2))));
  }

  void _finishWire(RelayEnd to) {
    final from = pending!;
    pending = null;
    if (from == to) {
      corners.clear();
      return;
    }
    if (sheet.wires.any((w) => (w.a == from && w.b == to) || (w.a == to && w.b == from))) {
      corners.clear();
      return;
    }
    _snapshot();
    sheet.wires.add(RelayWire(id: sheet.nextId(), a: from, b: to, bends: List.of(corners)));
    corners.clear();
  }

  /// Ends a wire on the middle of another: a junction goes there and the other wire is split at it.
  void _branch(RelayWire wire, Offset screen) {
    final from = pending!;
    final path = sheet.path(wire);
    final g = gridOf(screen);
    var best = path.first;
    var bestSeg = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i + 1 < path.length; i++) {
      final a = path[i], b = path[i + 1];
      final ab = b - a;
      final length = ab.dx * ab.dx + ab.dy * ab.dy;
      final t = length == 0 ? 0.0 : (((g - a).dx * ab.dx + (g - a).dy * ab.dy) / length).clamp(0.0, 1.0);
      final p = a + ab * t;
      if ((p - g).distance < bestDistance) {
        bestDistance = (p - g).distance;
        best = p;
        bestSeg = i;
      }
    }
    final at = _snap(best);
    final bendsA = [for (var i = 1; i <= bestSeg; i++) if ((path[i] - at).distance > 0.001) path[i]];
    final bendsB = [for (var i = bestSeg + 1; i < path.length - 1; i++) if ((path[i] - at).distance > 0.001) path[i]];
    _snapshot();
    final node = RelaySymbol(id: sheet.nextId(), type: 'node', tag: '', x: at.dx.round(), y: at.dy.round());
    sheet.symbols.add(node);
    final here = RelayEnd(node.id, '1');
    sheet.wires.remove(wire);
    sheet.wires
      ..add(RelayWire(id: sheet.nextId(), a: wire.a, b: here, bends: bendsA))
      ..add(RelayWire(id: sheet.nextId(), a: here, b: wire.b, bends: bendsB))
      ..add(RelayWire(id: sheet.nextId(), a: from, b: here, bends: List.of(corners)));
    pending = null;
    corners.clear();
  }

  void deleteSelection() {
    if (simulating) return;
    if (selectedSymbol != null) {
      _snapshot();
      final id = selectedSymbol!;
      sheet.wires.removeWhere((w) => w.touches(id));
      sheet.symbols.removeWhere((s) => s.id == id);
      selectedSymbol = null;
    } else if (selectedWire != null) {
      _snapshot();
      sheet.wires.removeWhere((w) => w.id == selectedWire);
      selectedWire = null;
    }
    setState(() {});
  }

  /// A copy of the selected symbol two units down and right: a coil gets the next tag, a contact keeps its coil's.
  void duplicateSelection() {
    final s = selectedSymbol == null ? null : sheet.symbol(selectedSymbol!);
    if (s == null || simulating || s.type == 'node') return;
    _snapshot();
    final copy = RelaySymbol(
      id: sheet.nextId(),
      type: s.type,
      tag: s.def.isContact || s.def.prefix.isEmpty ? s.tag : sheet.nextTag(s.def.prefix),
      x: s.x + 2,
      y: s.y + 2,
      rotation: s.rotation,
      params: Map.of(s.params),
    );
    setState(() {
      sheet.symbols.add(copy);
      selectedSymbol = copy.id;
    });
  }

  void rotateSelection() {
    final s = selectedSymbol == null ? null : sheet.symbol(selectedSymbol!);
    if (s == null || simulating || s.type == 'node') return;
    _snapshot();
    setState(() => s.rotation = (s.rotation + 1) % 4);
  }

  void _cancel() {
    setState(() {
      if (pending != null) {
        pending = null;
        corners.clear();
      } else if (placing != null) {
        placing = null;
      } else {
        selectedSymbol = null;
        selectedWire = null;
      }
    });
  }

  // ------------------------------------------------------------------------------------------------ pointer

  void _down(PointerDownEvent e) {
    _focus.requestFocus();
    final p = e.localPosition;
    if (e.buttons & kSecondaryMouseButton != 0) {
      _cancel();
      return;
    }
    if (e.buttons & kMiddleMouseButton != 0) {
      _panning = true;
      return;
    }
    if (simulating) {
      final s = symbolAt(p);
      if (s != null) _operate(s, true);
      return;
    }
    if (placing != null) {
      _placeAtScreen(placing!, p);
      placing = null;
      return;
    }
    final pin = pinAt(p);
    if (pin != null) {
      setState(() {
        if (pending == null) {
          pending = pin;
          corners.clear();
          selectedSymbol = null;
          selectedWire = null;
        } else {
          _finishWire(pin);
        }
      });
      return;
    }
    if (pending != null) {
      final wire = wireAt(p);
      setState(() {
        if (wire != null) {
          _branch(wire, p);
        } else {
          final bend = _snap(gridOf(p));
          if (corners.isEmpty || corners.last != bend) corners.add(bend);
        }
      });
      return;
    }
    final s = symbolAt(p);
    if (s != null) {
      setState(() {
        selectedSymbol = s.id;
        selectedWire = null;
      });
      _dragging = s.id;
      _dragStart = gridOf(p);
      _dragOrigin = (s.x, s.y);
      _dragBefore = jsonEncode(sheet.toJson());
      return;
    }
    final w = wireAt(p);
    setState(() {
      selectedWire = w?.id;
      selectedSymbol = null;
    });
    if (w == null) _panning = true;
  }

  void _move(PointerMoveEvent e) {
    pointer = e.localPosition;
    if (_panning) {
      setState(() => pan += e.delta);
      return;
    }
    final id = _dragging;
    if (id == null) return;
    final s = sheet.symbol(id);
    if (s == null) {
      _dragging = null;
      _dragBefore = null;
      return;
    }
    final d = gridOf(e.localPosition) - _dragStart;
    setState(() {
      s.x = _dragOrigin.$1 + d.dx.round();
      s.y = _dragOrigin.$2 + d.dy.round();
    });
  }

  void _up(PointerEvent e) {
    _panning = false;
    if (_held != null) {
      final id = _held!;
      _held = null;
      if (simulating) {
        final s = sheet.symbol(id);
        if (s != null) _operate(s, false);
      }
    }
    if (_dragging != null) {
      final s = sheet.symbol(_dragging!);
      final changed = s != null && (s.x, s.y) != _dragOrigin && _dragBefore != null;
      final before = _dragBefore;
      _dragging = null;
      _dragBefore = null;
      if (changed) {
        setState(() {
          _undo.add(before!);
          if (_undo.length > 100) _undo.removeAt(0);
          _redo.clear();
          dirty = true;
        });
      }
    }
  }

  void _zoomAt(Offset focus, double factor) {
    final next = (zoom * factor).clamp(0.35, 3.0);
    final world = (focus - pan) / zoom;
    setState(() {
      zoom = next;
      pan = focus - world * zoom;
    });
  }

  // ------------------------------------------------------------------------------------------------ simulation

  void toggleSim() {
    if (simulating) {
      _ticker?.cancel();
      _clock.stop();
      setState(() {
        sim = null;
        result = null;
        _clearTransient();
      });
      return;
    }
    setState(() {
      _clearTransient();
      sim = RelaySim(sheet);
      _clock
        ..reset()
        ..start();
      result = sim!.solve(0);
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  void _tick() {
    if (!mounted || sim == null) return;
    final needs = sim!.ticking || sheet.symbols.any((s) => s.type == 'lamp_flash' || s.type == 'motor1' || s.type == 'motor3');
    if (!needs) return;
    setState(() => result = sim!.solve(_now));
  }

  /// A click on a symbol while running: buttons press while held; selectors, emergency stops and limit switches
  /// latch; breakers switch on and off (and reset after a trip); fuses are replaced; an overload relay trips and resets.
  void _operate(RelaySymbol s, bool down) {
    final run = sim!;
    final actuator = s.type == 'tor' ? 'tor' : s.def.actuator;
    switch (actuator) {
      case 'push':
        down ? run.pressed.add(s.id) : run.pressed.remove(s.id);
        _held = down ? s.id : null;
      case 'latch' || 'limit':
        if (!down) return;
        run.toggled.contains(s.id) ? run.toggled.remove(s.id) : run.toggled.add(s.id);
      case 'sel3':
        if (!down) return;
        // 0, 1, 0, 2, 0: a 1-0-2 selector is turned through its middle position.
        final position = run.positions[s.id] ?? 0;
        if (position == 0) {
          final next = (_sel3Last[s.id] ?? 2) == 1 ? 2 : 1;
          run.positions[s.id] = next;
          _sel3Last[s.id] = next;
        } else {
          run.positions[s.id] = 0;
        }
      case 'breaker':
        if (!down) return;
        run.open.contains(s.id) ? run.open.remove(s.id) : run.open.add(s.id);
      case 'tor':
        if (!down) return;
        run.tripped.contains(s.tag) ? run.tripped.remove(s.tag) : run.tripped.add(s.tag);
      default:
        return;
    }
    setState(() => result = run.solve(_now));
  }

  // ------------------------------------------------------------------------------------------------ files

  Future<void> _save() async {
    try {
      if (await saveRelayFile(fileName, const JsonEncoder.withIndent('  ').convert(sheet.toJson()))) {
        if (!mounted) return;
        setState(() => dirty = false);
        _messenger.currentState?.showSnackBar(const SnackBar(content: Text('Diagram disimpan.')));
      }
    } catch (error) {
      _messenger.currentState?.showSnackBar(SnackBar(content: Text('Gagal menyimpan: $error')));
    }
  }

  Future<void> _open() async {
    try {
      final picked = await pickRelayFile();
      if (!mounted || picked == null) return;
      final loaded = RelaySheet.fromJson(jsonDecode(picked.$2) as Map<String, dynamic>);
      if (simulating) toggleSim();
      _snapshot();
      setState(() {
        sheet = loaded;
        fileName = picked.$1.replaceAll(RegExp(r'\.bwrelay$', caseSensitive: false), '');
        selectedSymbol = null;
        selectedWire = null;
        _clearTransient();
        dirty = false;
      });
    } on FormatException catch (error) {
      _messenger.currentState?.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      _messenger.currentState?.showSnackBar(SnackBar(content: Text('File tidak bisa dibuka: $error')));
    }
  }

  void _newSheet() {
    if (simulating) toggleSim();
    if (sheet.symbols.isEmpty) return;
    _snapshot();
    setState(() {
      sheet = RelaySheet();
      fileName = 'diagram';
      selectedSymbol = null;
      selectedWire = null;
      _clearTransient();
    });
    _messenger.currentState?.showSnackBar(const SnackBar(content: Text('Lembar baru. Tekan Ctrl+Z untuk mengembalikan yang tadi.')));
  }

  // ------------------------------------------------------------------------------------------------ build

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (key == LogicalKeyboardKey.escape) {
      _cancel();
    } else if (key == LogicalKeyboardKey.delete || key == LogicalKeyboardKey.backspace) {
      deleteSelection();
    } else if (key == LogicalKeyboardKey.keyR && !ctrl) {
      rotateSelection();
    } else if (ctrl && key == LogicalKeyboardKey.keyD) {
      duplicateSelection();
    } else if (ctrl && key == LogicalKeyboardKey.keyZ) {
      undo();
    } else if (ctrl && key == LogicalKeyboardKey.keyY) {
      redo();
    } else if (ctrl && key == LogicalKeyboardKey.keyS) {
      _save();
    } else if (ctrl && key == LogicalKeyboardKey.keyO) {
      _open();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ScaffoldMessenger(
      key: _messenger,
      child: Scaffold(
        backgroundColor: tokens.canvas,
        body: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Column(
            children: [
              _header(tokens),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Kept in place while running (dimmed, not clickable) so the sheet does not jump sideways.
                    SizedBox(
                      width: 232,
                      child: IgnorePointer(ignoring: simulating, child: Opacity(opacity: simulating ? 0.35 : 1, child: _palette(tokens))),
                    ),
                    Expanded(child: _canvas(tokens)),
                    SizedBox(width: 270, child: _side(tokens)),
                  ],
                ),
              ),
              _status(tokens),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(Tokens tokens) => Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(color: tokens.panel, border: Border(bottom: BorderSide(color: tokens.border))),
        child: Row(
          children: [
            const Nameplate(kRelayEditorName, size: 16),
            const SizedBox(width: 12),
            Flexible(child: Text('$fileName${dirty ? ' *' : ''}', overflow: TextOverflow.ellipsis, style: uiText(13, tokens.textMuted))),
            if (simulating) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: tokens.run.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(Radii.plate)),
                child: Text('Simulasi berjalan', style: plateText(14, tokens.run, weight: 700)),
              ),
            ],
            const Spacer(),
            IconButton(key: const ValueKey('relay-new'), tooltip: 'Lembar baru', onPressed: _newSheet, icon: const Icon(Icons.note_add_outlined, size: 20)),
            IconButton(key: const ValueKey('relay-open'), tooltip: 'Buka (Ctrl+O)', onPressed: _open, icon: const Icon(Icons.folder_open_outlined, size: 20)),
            IconButton(key: const ValueKey('relay-save'), tooltip: 'Simpan (Ctrl+S)', onPressed: _save, icon: const Icon(Icons.save_outlined, size: 20)),
            const SizedBox(width: 4),
            IconButton(tooltip: 'Urungkan (Ctrl+Z)', onPressed: _undo.isEmpty || simulating ? null : undo, icon: const Icon(Icons.undo, size: 20)),
            IconButton(tooltip: 'Ulangi (Ctrl+Y)', onPressed: _redo.isEmpty || simulating ? null : redo, icon: const Icon(Icons.redo, size: 20)),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: const ValueKey('relay-simulate'),
              onPressed: sheet.symbols.isEmpty ? null : toggleSim,
              style: simulating ? FilledButton.styleFrom(backgroundColor: tokens.error, foregroundColor: Colors.white, iconColor: Colors.white) : null,
              icon: Icon(simulating ? Icons.stop : Icons.play_arrow, size: 18),
              label: Text(simulating ? 'Hentikan' : 'Simulasi'),
            ),
            const SizedBox(width: 6),
            IconButton(key: const ValueKey('relay-close'), tooltip: 'Tutup', onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
          ],
        ),
      );

  Widget _palette(Tokens tokens) {
    final groups = <String, List<RelayType>>{};
    for (final t in kRelayTypes) {
      groups.putIfAbsent(t.category, () => []).add(t);
    }
    return Container(
      decoration: BoxDecoration(color: tokens.panel, border: Border(right: BorderSide(color: tokens.border))),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
        children: [
          for (final entry in groups.entries) ...[
            Padding(padding: const EdgeInsets.fromLTRB(4, 10, 4, 6), child: Text(entry.key, style: uiText(12, tokens.textMuted, weight: 650))),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final t in entry.value)
                  for (final id in t.id == 'supply' ? [for (final l in kRelaySupplies) 'supply:$l'] : [t.id])
                    _PaletteItem(type: t, id: id, armed: placing == id, onTap: () => setState(() => placing = placing == id ? null : id)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _canvas(Tokens tokens) => DragTarget<String>(
        onAcceptWithDetails: (details) {
          final box = _canvasKey.currentContext!.findRenderObject()! as RenderBox;
          _placeAtScreen(details.data, box.globalToLocal(details.offset));
        },
        builder: (context, candidates, rejected) => ClipRect(
          child: MouseRegion(
            cursor: simulating
                ? SystemMouseCursors.click
                : placing != null || pending != null
                    ? SystemMouseCursors.precise
                    : MouseCursor.defer,
            onHover: (e) {
              final changed = pending != null || placing != null || pinAt(e.localPosition) != null || pinAt(pointer ?? Offset.zero) != null;
              pointer = e.localPosition;
              if (changed) setState(() {});
            },
            child: Listener(
              key: const ValueKey('relay-canvas'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _up,
              onPointerSignal: (e) {
                if (e is PointerScrollEvent) _zoomAt(e.localPosition, e.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1);
              },
              child: CustomPaint(
                key: _canvasKey,
                size: Size.infinite,
                painter: _SheetPainter(this, tokens, Theme.of(context).brightness == Brightness.dark),
              ),
            ),
          ),
        ),
      );

  Widget _side(Tokens tokens) {
    final children = <Widget>[];
    Widget label(String text) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(text, style: uiText(12, tokens.textMuted, weight: 650)));
    if (simulating) {
      final r = result!;
      children.add(Text('Simulasi', style: uiText(15, tokens.text, weight: 700)));
      children.add(const SizedBox(height: 4));
      children.add(Text('Klik tombol untuk menekan, selektor dan MCB untuk memutar atau mematikan, overload relay untuk trip dan reset.',
          style: uiText(12.5, tokens.textMuted, height: 1.4)));
      if (r.short) {
        children.add(const SizedBox(height: 12));
        children.add(Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: tokens.error.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(Radii.control)),
          child: Text('Korsleting tanpa MCB atau fuse yang bisa memutusnya.', style: uiText(13, tokens.error, weight: 600)),
        ));
      }
      final coils = sheet.symbols.where((s) => kRelayCoilTypes.contains(s.type)).toList();
      if (coils.isNotEmpty) {
        children.add(label('Koil'));
        for (final c in coils) {
          final on = r.energized.contains(c.tag);
          var text = '${c.tag}  ${on ? 'ON' : 'off'}';
          if (c.type.startsWith('timer')) {
            final t = sim!.timerElapsed(c.tag, _now);
            text += t == null ? '' : '   ${t.clamp(0, c.seconds).toStringAsFixed(1)} / ${c.seconds.toStringAsFixed(1)} dtk';
          }
          children.add(Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(text, style: uiText(13, on ? tokens.run : tokens.text, weight: 600))));
        }
      }
      final motors = sheet.symbols.where((s) => kRelayMotors.contains(s.type)).toList();
      if (motors.isNotEmpty) {
        children.add(label('Motor'));
        for (final m in motors) {
          final dir = r.motors[m.id];
          final mode = switch (r.motorModes[m.id]) { 'Y' => ', bintang', 'Δ' => ', segitiga', '1' => ', kecepatan rendah', '2' => ', kecepatan tinggi', _ => '' };
          children.add(Text('${m.tag}  ${dir == null ? 'berhenti' : dir > 0 ? 'berputar maju$mode' : 'berputar mundur$mode'}',
              style: uiText(13, dir == null ? tokens.text : tokens.run, weight: 600)));
        }
      }
      if (r.warnings.isNotEmpty || sim!.events.isNotEmpty) {
        children.add(label('Catatan'));
        for (final w in [...sim!.events, ...r.warnings]) {
          children.add(Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(w, style: uiText(12.5, tokens.warning, height: 1.35))));
        }
      }
    } else if (selectedSymbol != null && sheet.symbol(selectedSymbol!) != null) {
      final s = sheet.symbol(selectedSymbol!)!;
      children.add(Text(s.def.name, style: uiText(15, tokens.text, weight: 700)));
      if (s.def.prefix.isNotEmpty) {
        children.add(label(s.def.isContact ? 'Tag (ikut ${s.def.follows!.contains('tor') ? 'overload relay' : s.def.follows!.contains('timer_on') ? 'timer' : 'koil'})' : 'Tag'));
        children.add(_TagField(key: ValueKey('tag-${s.id}'), text: s.tag, onSubmit: (v) {
          if (v.trim().isEmpty || v.trim() == s.tag) return;
          _snapshot();
          setState(() => s.tag = v.trim().toUpperCase());
        }));
        if (s.def.isContact) {
          final owners = sheet.symbols.where((o) => s.def.follows!.contains(o.type)).map((o) => o.tag).toSet().toList()..sort();
          if (owners.isNotEmpty) {
            children.add(const SizedBox(height: 8));
            children.add(Wrap(spacing: 6, runSpacing: 6, children: [
              for (final tag in owners)
                ChoiceChip(
                  label: Text(tag),
                  selected: s.tag == tag,
                  onSelected: (_) {
                    _snapshot();
                    setState(() => s.tag = tag);
                  },
                ),
            ]));
          }
        }
      }
      if (s.type == 'supply') {
        children.add(label('Sumber'));
        children.add(Wrap(spacing: 6, runSpacing: 6, children: [
          for (final l in kRelaySupplies)
            ChoiceChip(
              label: Text(l),
              selected: s.supply == l,
              onSelected: (_) {
                _snapshot();
                setState(() => s.params['supply'] = l);
              },
            ),
        ]));
      }
      if (s.type == 'text') {
        children.add(label('Teks'));
        children.add(_TagField(key: ValueKey('text-${s.id}'), text: s.text, onSubmit: (v) {
          if (v.trim().isEmpty || v.trim() == s.text) return;
          _snapshot();
          setState(() => s.params['text'] = v.trim());
        }));
      }
      if (kRelayTimers.contains(s.type)) {
        children.add(label('Waktu (detik)'));
        children.add(_TagField(key: ValueKey('sec-${s.id}'), text: s.seconds.toStringAsFixed(1), numeric: true, onSubmit: (v) {
          final value = double.tryParse(v.replaceAll(',', '.'));
          if (value == null || !value.isFinite || value <= 0) return;
          _snapshot();
          setState(() => s.params['seconds'] = value);
        }));
      }
      // Where this coil's contacts are, like the contact table under a coil in a panel drawing.
      if (kRelayCoilTypes.contains(s.type) || s.type == 'tor') {
        final contacts = sheet.symbols.where((o) => o.def.isContact && o.def.follows!.contains(s.type) && o.tag == s.tag).toList();
        children.add(label('Kontak dengan tag ${s.tag}'));
        children.add(Text(
          contacts.isEmpty ? 'Belum ada.' : contacts.map((c) => c.def.name).join('\n'),
          style: uiText(12.5, tokens.text, height: 1.45),
        ));
      }
      children.add(const SizedBox(height: 16));
      children.add(Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(onPressed: rotateSelection, icon: const Icon(Icons.rotate_90_degrees_cw_outlined, size: 16), label: const Text('Putar (R)')),
        OutlinedButton.icon(
          key: const ValueKey('relay-duplicate'),
          onPressed: duplicateSelection,
          icon: const Icon(Icons.copy_outlined, size: 16),
          label: const Text('Duplikat (Ctrl+D)'),
        ),
        OutlinedButton.icon(onPressed: deleteSelection, icon: const Icon(Icons.delete_outline, size: 16), label: const Text('Hapus')),
      ]));
    } else if (selectedWire != null) {
      children.add(Text('Kabel', style: uiText(15, tokens.text, weight: 700)));
      children.add(const SizedBox(height: 12));
      children.add(OutlinedButton.icon(onPressed: deleteSelection, icon: const Icon(Icons.delete_outline, size: 16), label: const Text('Hapus (Del)')));
    } else {
      children.add(Text('Cara pakai', style: uiText(15, tokens.text, weight: 700)));
      for (final (title, text) in const [
        ('Menaruh simbol', 'Klik simbol di kiri lalu klik di lembar, atau seret ke lembar.'),
        ('Menyambung', 'Klik titik ujung simbol, lalu titik tujuan. Klik kiri di tempat kosong untuk membelokkan, klik di tengah kabel untuk bercabang, klik kanan untuk batal.'),
        ('Tag', 'Kontak mengikuti koil, timer, atau overload relay dengan tag yang sama, misalnya KM1.'),
        ('Mengatur', 'R memutar, Ctrl+D menduplikat, Del menghapus, scroll untuk zoom, seret tempat kosong untuk menggeser lembar.'),
        ('Simulasi', 'Tekan Simulasi, lalu klik tombol dan saklar di lembar. Tombol tekan aktif selama ditahan; selektor, tombol darurat dan limit switch tetap di posisinya; MCB, fuse, RCD dan overload relay bisa dimatikan atau di-trip lalu dinyalakan lagi.'),
      ]) {
        children.add(label(title));
        children.add(Text(text, style: uiText(12.5, tokens.text, height: 1.45)));
      }
    }
    return Container(
      decoration: BoxDecoration(color: tokens.panel, border: Border(left: BorderSide(color: tokens.border))),
      child: ListView(padding: const EdgeInsets.all(16), children: children),
    );
  }

  Widget _status(Tokens tokens) {
    final hint = simulating
        ? 'Klik tombol dan saklar di lembar untuk mengoperasikan rangkaian.'
        : pending != null
            ? 'Klik titik tujuan. Klik kiri di tempat kosong untuk membelokkan, klik kanan untuk batal.'
            : placing != null
                ? 'Klik di lembar untuk menaruh ${_item(placing!).$2 == null ? kRelayTypeById[placing]!.name : 'sumber ${_item(placing!).$2}'}. Klik kanan untuk batal.'
                : '${sheet.symbols.where((s) => s.type != 'node').length} simbol, ${sheet.wires.length} kabel';
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(color: tokens.panel, border: Border(top: BorderSide(color: tokens.border))),
      child: Row(
        children: [
          Expanded(child: Text(hint, overflow: TextOverflow.ellipsis, style: uiText(12, tokens.textMuted))),
          Text('${(zoom * 100).round()}%', style: uiText(12, tokens.textMuted)),
        ],
      ),
    );
  }
}

class _TagField extends StatefulWidget {
  const _TagField({super.key, required this.text, required this.onSubmit, this.numeric = false});

  final String text;
  final ValueChanged<String> onSubmit;
  final bool numeric;

  @override
  State<_TagField> createState() => _TagFieldState();
}

class _TagFieldState extends State<_TagField> {
  late final _controller = TextEditingController(text: widget.text);

  @override
  void didUpdateWidget(_TagField old) {
    super.didUpdateWidget(old);
    if (widget.text != old.text && widget.text != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.text,
        selection: TextSelection.collapsed(offset: widget.text.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _controller,
        keyboardType: widget.numeric ? TextInputType.number : TextInputType.text,
        style: uiText(13, context.tokens.text),
        onSubmitted: widget.onSubmit,
        onTapOutside: (_) => widget.onSubmit(_controller.text),
      );
}

class _PaletteItem extends StatelessWidget {
  const _PaletteItem({required this.type, required this.id, required this.armed, required this.onTap});

  final RelayType type;

  /// The type, or for a supply the type and its label ('supply:N').
  final String id;
  final bool armed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tile = Container(
      width: 64,
      height: 70,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: armed ? tokens.accentSoft : tokens.canvas,
        border: Border.all(color: armed ? tokens.accent : tokens.border),
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: CustomPaint(painter: _PreviewPainter(type, tokens.text, supply: _RelayEditorState._item(id).$2)),
    );
    return Tooltip(
      message: _RelayEditorState._item(id).$2 == null ? type.name : 'Sumber ${_RelayEditorState._item(id).$2}',
      child: Draggable<String>(
        data: id,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Opacity(opacity: 0.7, child: SizedBox(width: 48, height: 52, child: CustomPaint(painter: _PreviewPainter(type, tokens.text, supply: _RelayEditorState._item(id).$2)))),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(key: ValueKey('relay-palette-$id'), onTap: onTap, child: tile),
        ),
      ),
    );
  }
}

/// A palette preview: the symbol in its resting state, fitted into the tile.
class _PreviewPainter extends CustomPainter {
  const _PreviewPainter(this.type, this.color, {this.supply});

  final RelayType type;
  final Color color;
  final String? supply;

  @override
  void paint(Canvas canvas, Size size) {
    final w = math.max(type.size.width, 1.0), h = math.max(type.size.height, 1.0);
    final scale = math.min(size.width / (w + 1), size.height / (h + 0.6));
    canvas.save();
    canvas.translate((size.width - w * scale) / 2, (size.height - h * scale) / 2);
    canvas.scale(scale);
    drawRelaySymbol(canvas, RelaySymbol(id: 0, type: type.id, tag: '', x: 0, y: 0, params: {'supply': ?supply}), const RelayLook(), color, preview: true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PreviewPainter old) => old.type != type || old.color != color || old.supply != supply;
}

/// The state a symbol is drawn in.
class RelayLook {
  const RelayLook({this.poles, this.on = false, this.motor = 0, this.mode, this.spin = 0, this.flash = true, this.position = 0});

  /// For switching symbols: whether each pole is operated; null draws the resting position.
  final List<bool>? poles;
  final bool on;
  final int motor;

  /// How a running motor is connected ('Y', 'Δ', speed '1' or '2').
  final String? mode;
  final double spin;
  final bool flash;

  /// Position of a three-position selector.
  final int position;
}

/// Poles as drawn on the sheet while editing: everything unoperated and breakers open, as a schematic shows them;
/// fuse links intact.
List<bool> relayRestPoles(RelayType def) => [for (final p in def.poles) p.kind == PoleKind.fuse];

const _lit = Color(0xFFFFD34D);
const _runFill = Color(0x592E8B3D);

/// Draws a symbol in grid units, unrotated, with its top-left at the origin.
void drawRelaySymbol(Canvas c, RelaySymbol s, RelayLook look, Color ink, {bool preview = false}) {
  final line = Paint()
    ..color = ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.09
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final fill = Paint()..color = ink;
  void l(double x1, double y1, double x2, double y2) => c.drawLine(Offset(x1, y1), Offset(x2, y2), line);
  void dashed(double x1, double y, double x2) {
    const step = 0.18;
    for (var x = math.min(x1, x2); x < math.max(x1, x2); x += step * 2) {
      c.drawLine(Offset(x, y), Offset(math.min(x + step, math.max(x1, x2)), y), line);
    }
  }

  void text(String t, Offset centre, double size, {Color? color}) {
    final tp = TextPainter(
      text: TextSpan(text: t, style: TextStyle(fontFamily: 'Barlow Condensed', fontWeight: FontWeight.w700, fontSize: size, color: color ?? ink, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, centre - Offset(tp.width / 2, tp.height / 2));
  }

  void rect(double l, double t, double r, double b, {Paint? paint}) => c.drawRect(Rect.fromLTRB(l, t, r, b), paint ?? line);

  final def = s.def;
  if (def.poles.isNotEmpty) {
    _drawPoles(c, s, look.poles ?? relayRestPoles(def), look.position, line, l, dashed, text, rect);
    return;
  }

  void coilBody({bool on = false}) {
    l(1, 0, 1, 1.3);
    l(1, 2.7, 1, 4);
    if (on) rect(0.3, 1.3, 1.7, 2.7, paint: Paint()..color = _runFill);
    rect(0.3, 1.3, 1.7, 2.7);
  }

  void pulse(double x0, double x1, double y, double h) {
    final w = (x1 - x0) / 5;
    final p = Path()
      ..moveTo(x0, y)
      ..lineTo(x0 + w, y)
      ..lineTo(x0 + w, y - h)
      ..lineTo(x0 + 2 * w, y - h)
      ..lineTo(x0 + 2 * w, y)
      ..lineTo(x0 + 3 * w, y)
      ..lineTo(x0 + 3 * w, y - h)
      ..lineTo(x0 + 4 * w, y - h)
      ..lineTo(x0 + 4 * w, y)
      ..lineTo(x1, y);
    c.drawPath(p, line);
  }

  void motorBody(Offset centre, double radius, String kind) {
    if (look.motor != 0) c.drawCircle(centre, radius, Paint()..color = _runFill);
    c.drawCircle(centre, radius, line);
    text('M', centre - Offset(0, radius * 0.22), radius * 0.62);
    text(look.mode == null ? kind : '$kind ${look.mode}', centre + Offset(0, radius * 0.42), math.max(0.6, radius * 0.36));
    if (look.motor != 0) _spinArrow(c, centre, radius + 0.35, look.spin * look.motor * (look.mode == 'Y' || look.mode == '1' ? 0.5 : 1), line);
  }

  switch (s.type) {
    case 'supply':
      c.drawCircle(const Offset(1, 0.8), 0.75, line);
      l(1, 1.55, 1, 2);
      text(s.supply, const Offset(1, 0.82), s.supply.length > 2 ? 0.48 : 0.62);
    case 'supply3' || 'supply3n':
      for (final entry in def.pins.entries) {
        final x = entry.value.dx;
        c.drawCircle(Offset(x, 0.8), 0.7, line);
        l(x, 1.5, x, 2);
        text(entry.key, Offset(x, 0.82), 0.55);
      }
    case 'battery':
      l(1, 0, 1, 1.75);
      l(1, 2.25, 1, 4);
      l(0.3, 1.75, 1.7, 1.75);
      c.drawLine(const Offset(0.65, 2.25), const Offset(1.35, 2.25), Paint()
        ..color = ink
        ..strokeWidth = 0.2);
      text('+', const Offset(1.65, 1.25), 0.55);
    case 'psu':
      l(1, 0, 1, 0.8);
      l(3, 0, 3, 0.8);
      l(1, 3.2, 1, 4);
      l(3, 3.2, 3, 4);
      if (look.on) rect(0.3, 0.8, 3.7, 3.2, paint: Paint()..color = _runFill);
      rect(0.3, 0.8, 3.7, 3.2);
      l(0.3, 3.2, 3.7, 0.8);
      text('~', const Offset(1.0, 1.4), 0.7);
      text('24V=', const Offset(2.8, 2.6), 0.5);
    case 'transformer':
      l(1, 0, 1, 0.6);
      l(3, 0, 3, 0.6);
      l(1, 0.6, 1.5, 1.0);
      l(3, 0.6, 2.5, 1.0);
      l(1, 4, 1, 3.4);
      l(3, 4, 3, 3.4);
      l(1, 3.4, 1.5, 3.0);
      l(3, 3.4, 2.5, 3.0);
      c.drawCircle(const Offset(2, 1.55), 0.75, line);
      c.drawCircle(const Offset(2, 2.45), 0.75, line);
    case 'node':
      c.drawCircle(Offset.zero, 0.2, fill);
    case 'coil' || 'relay_coil':
      coilBody(on: look.on);
      if (s.type == 'relay_coil') text('K', const Offset(1, 2), 0.7);
    case 'impulse':
      coilBody(on: look.on);
      pulse(0.5, 1.5, 2.3, 0.6);
    case 'timer_on' || 'timer_off' || 'timer_cyc':
      coilBody(on: look.on);
      if (s.type == 'timer_on') {
        rect(0.3, 1.3, 0.75, 2.7);
        l(0.3, 1.3, 0.75, 2.7);
        l(0.3, 2.7, 0.75, 1.3);
      } else if (s.type == 'timer_off') {
        rect(0.3, 1.3, 0.75, 2.7, paint: fill);
      } else {
        rect(0.3, 1.3, 0.75, 2.7);
        pulse(0.85, 1.6, 2.25, 0.5);
      }
    case 'lamp' || 'lamp_flash':
      l(1, 0, 1, 1.25);
      l(1, 2.75, 1, 4);
      final lit = look.on && (s.type == 'lamp' || look.flash);
      if (lit) c.drawCircle(const Offset(1, 2), 0.75, Paint()..color = _lit);
      c.drawCircle(const Offset(1, 2), 0.75, line);
      l(0.47, 1.47, 1.53, 2.53);
      l(0.47, 2.53, 1.53, 1.47);
      if (s.type == 'lamp_flash') {
        l(1.75, 1.2, 1.95, 1.0);
        l(1.85, 1.45, 2.1, 1.35);
      }
    case 'buzzer':
      l(1, 0, 1, 1.4);
      l(1, 2.6, 1, 4);
      final dome = Path()
        ..moveTo(0.3, 2.6)
        ..arcToPoint(const Offset(1.7, 2.6), radius: const Radius.circular(0.7))
        ..close();
      if (look.on) c.drawPath(dome, Paint()..color = _lit);
      c.drawPath(dome, line);
    case 'bell':
      l(1, 0, 1, 1.3);
      l(1, 2.7, 1, 4);
      final bell = Path()
        ..moveTo(0.3, 2.3)
        ..arcToPoint(const Offset(1.7, 2.3), radius: const Radius.circular(0.7), clockwise: true)
        ..close();
      if (look.on) c.drawPath(bell, Paint()..color = _lit);
      c.drawPath(bell, line);
      l(0.2, 2.3, 1.8, 2.3);
      c.drawCircle(const Offset(1, 2.55), 0.15, fill);
    case 'siren':
      l(1, 0, 1, 1.3);
      l(1, 2.7, 1, 4);
      final horn = Path()
        ..moveTo(0.7, 1.3)
        ..lineTo(1.3, 1.3)
        ..lineTo(1.8, 2.7)
        ..lineTo(0.2, 2.7)
        ..close();
      if (look.on) c.drawPath(horn, Paint()..color = _lit);
      c.drawPath(horn, line);
    case 'heater':
      l(1, 0, 1, 1.0);
      l(1, 3.0, 1, 4);
      if (look.on) rect(0.55, 1.0, 1.45, 3.0, paint: Paint()..color = const Color(0xFFF97316));
      rect(0.55, 1.0, 1.45, 3.0);
      for (final y in const [1.5, 2.0, 2.5]) {
        l(0.55, y, 1.45, y);
      }
    case 'valve':
      l(1, 0, 1, 1.3);
      l(1, 2.7, 1, 4);
      if (look.on) rect(0.3, 1.3, 1.7, 2.7, paint: Paint()..color = _runFill);
      rect(0.3, 1.3, 1.7, 2.7);
      l(0.3, 2.7, 1.7, 1.3);
      text('Y', const Offset(1.95, 1.2), 0.5);
    case 'motor1':
      l(2, 0, 2, 0.6);
      l(2, 4, 2, 3.4);
      motorBody(const Offset(2, 2), 1.4, '1~');
    case 'motor3':
      l(1, 0, 1, 3.6);
      l(3, 0, 3, 1.6);
      l(5, 0, 5, 3.6);
      motorBody(const Offset(3, 3.6), 2.0, '3~');
    case 'motor3_6' || 'motor_dahl':
      for (final x in const [1.0, 3.0, 5.0]) {
        l(x, 0, x, x == 3 ? 1.7 : 2.95);
        l(x, 8, x, x == 3 ? 6.3 : 5.05);
      }
      motorBody(const Offset(3, 4), 2.3, s.type == 'motor_dahl' ? '3~ 2v' : '3~');
    case 'motor_dc':
      l(2, 0, 2, 0.6);
      l(2, 4, 2, 3.4);
      motorBody(const Offset(2, 2), 1.4, '=');
    case 'earth':
      l(1, 0, 1, 1.0);
      l(0.3, 1.0, 1.7, 1.0);
      l(0.55, 1.35, 1.45, 1.35);
      l(0.8, 1.7, 1.2, 1.7);
    case 'diode':
      l(1, 0, 1, 1.5);
      l(1, 2.5, 1, 4);
      final tri = Path()
        ..moveTo(0.45, 1.5)
        ..lineTo(1.55, 1.5)
        ..lineTo(1, 2.5)
        ..close();
      c.drawPath(tri, look.on ? fill : line);
      l(0.45, 2.5, 1.55, 2.5);
    case 'text':
      final tp = TextPainter(
        text: TextSpan(text: s.text, style: TextStyle(fontFamily: 'Barlow Condensed', fontWeight: FontWeight.w600, fontSize: 0.8, color: ink, height: 1)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(0, 0.5 - tp.height / 2));
  }
}

/// Draws the poles of a switching symbol and the operator that works them.
void _drawPoles(
  Canvas c,
  RelaySymbol s,
  List<bool> on,
  int position,
  Paint line,
  void Function(double, double, double, double) l,
  void Function(double, double, double) dashed,
  void Function(String, Offset, double, {Color? color}) text,
  void Function(double, double, double, double, {Paint? paint}) rect,
) {
  final def = s.def;
  final breakerCross = def.mark == 'mcb' || def.mark == 'mpcb';
  final mids = <Offset>[];

  /// A make (NO) or break (NC) contact on the vertical line x = cx; returns the middle of its blade.
  Offset contact(double cx, {required bool nc, required bool closed}) {
    l(cx, 0, cx, 1.25);
    l(cx, 4, cx, 2.75);
    if (nc) l(cx, 1.25, cx + 0.55, 1.25);
    final end = nc ? (closed ? Offset(cx + 0.6, 1.25) : Offset(cx - 0.55, 1.45)) : (closed ? Offset(cx, 1.25) : Offset(cx - 0.75, 1.4));
    c.drawLine(Offset(cx, 2.75), end, line);
    if (breakerCross) {
      l(cx - 0.22, 1.03, cx + 0.22, 1.47);
      l(cx - 0.22, 1.47, cx + 0.22, 1.03);
    } else if (def.mark == 'isolator') {
      l(cx - 0.25, 1.25, cx + 0.25, 1.25);
    }
    return Offset((cx + end.dx) / 2, (2.75 + end.dy) / 2);
  }

  for (var i = 0; i < def.poles.length; i++) {
    final pole = def.poles[i];
    final cx = pole.x;
    switch (pole.kind) {
      case PoleKind.no:
        mids.add(contact(cx, nc: false, closed: on[i]));
      case PoleKind.nc:
        mids.add(contact(cx, nc: true, closed: !on[i]));
      case PoleKind.co:
        l(cx, 4, cx, 2.75);
        // NC: fixed contact to the left with its hook; NO: fixed contact to the right.
        l(cx - 1, 0, cx - 1, 1.25);
        l(cx - 1, 1.25, cx - 0.45, 1.25);
        l(cx + 1, 0, cx + 1, 1.25);
        final end = on[i] ? Offset(cx + 1, 1.25) : Offset(cx - 0.4, 1.25);
        c.drawLine(Offset(cx, 2.75), end, line);
        mids.add(Offset((cx + end.dx) / 2, (2.75 + end.dy) / 2));
      case PoleKind.fuse:
        l(cx, 0, cx, 4);
        rect(cx - 0.38, 1.0, cx + 0.38, 3.0);
        if (!on[i]) {
          l(cx - 0.3, 1.8, cx + 0.3, 2.2);
          l(cx - 0.3, 2.2, cx + 0.3, 1.8);
        }
      case PoleKind.element:
        l(cx, 0, cx, 1.4);
        l(cx, 2.6, cx, 4);
        rect(cx - 0.4, 1.4, cx + 0.4, 2.6);
        l(cx, 1.4, cx, 1.8);
        l(cx, 1.8, cx + 0.25, 1.8);
        l(cx + 0.25, 1.8, cx + 0.25, 2.2);
        l(cx + 0.25, 2.2, cx, 2.2);
        l(cx, 2.2, cx, 2.6);
        if (i + 1 < def.poles.length) dashed(cx + 0.4, 2.0, def.poles[i + 1].x - 0.4);
    }
  }
  if (mids.isEmpty || def.mark.isEmpty && mids.length < 2) return;
  final y = mids.first.dy;
  // The operator sits left of the first pole, tied to every blade by a dashed line.
  const mx = 0.42;
  final wide = def.mark == 'rcd' || def.mark == 'mpcb';
  if (def.mark.isNotEmpty) dashed(wide ? 0.05 : mx, y, mids.last.dx - 0.05);
  if (def.mark.isEmpty) dashed(mids.first.dx, y, mids.last.dx - 0.05);
  switch (def.mark) {
    case 'push':
      l(mx, y - 0.3, mx - 0.23, y - 0.3);
      l(mx - 0.23, y - 0.3, mx - 0.23, y + 0.3);
      l(mx - 0.23, y + 0.3, mx, y + 0.3);
    case 'estop':
      c.drawArc(Rect.fromCircle(center: Offset(mx - 0.08, y), radius: 0.32), math.pi / 2, math.pi, false, line);
      l(mx - 0.08, y - 0.32, mx - 0.08, y + 0.32);
    case 'selector' || 'sel3':
      l(mx, y - 0.3, mx - 0.2, y - 0.3);
      l(mx - 0.2, y - 0.3, mx - 0.2, y + 0.3);
      l(mx - 0.2, y + 0.3, mx - 0.35, y + 0.45);
      if (def.mark == 'sel3') text(const ['0', '1', '2'][position.clamp(0, 2)], Offset(mx - 0.1, y - 0.8), 0.55);
    case 'limit':
      c.drawCircle(Offset(mx - 0.17, y), 0.17, line);
    case 'timer':
      c.drawArc(Rect.fromCircle(center: Offset(mx - 0.12, y), radius: 0.28), -math.pi / 2, math.pi, false, line);
    case 'tor':
      rect(mx - 0.4, y - 0.25, mx, y + 0.25);
      l(mx - 0.4, y + 0.1, mx - 0.2, y + 0.1);
      l(mx - 0.2, y + 0.1, mx - 0.2, y - 0.1);
      l(mx - 0.2, y - 0.1, mx, y - 0.1);
    case 'mcb' || 'isolator':
      rect(mx - 0.38, y - 0.22, mx, y + 0.22);
    case 'mpcb' || 'rcd':
      rect(-0.9, y - 0.4, 0.05, y + 0.4);
      text(def.mark == 'rcd' ? 'IΔ' : 'I>', Offset(-0.42, y), 0.6);
  }
}

/// A short arrow orbiting a running motor, its direction showing the way it turns.
void _spinArrow(Canvas c, Offset centre, double radius, double angle, Paint line) {
  final rect = Rect.fromCircle(center: centre, radius: radius);
  c.drawArc(rect, angle, 0.9, false, line);
  final tip = centre + Offset(math.cos(angle + 0.9), math.sin(angle + 0.9)) * radius;
  final dir = Offset(-math.sin(angle + 0.9), math.cos(angle + 0.9));
  final side = Offset(dir.dy, -dir.dx);
  c.drawLine(tip, tip - dir * 0.3 + side * 0.18, line);
  c.drawLine(tip, tip - dir * 0.3 - side * 0.18, line);
}

/// A transformer or power supply whose output carries voltage.
bool _sourceLive(RelaySymbol s, RelayResult r) {
  if (s.type == 'transformer') return r.labels['${s.id}:S1'] == 'T${s.id}a';
  if (s.type == 'psu') return r.labels['${s.id}:L'] != null && r.labels['${s.id}:N'] != null && r.labels['${s.id}:+'] == 'DC+';
  return false;
}

class _SheetPainter extends CustomPainter {
  _SheetPainter(this.e, this.tokens, this.dark);

  final _RelayEditorState e;
  final Tokens tokens;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = e.zoom * RelaySheet.unit;
    // Grid dots every unit (or every 5 when zoomed out), heavier every 5.
    if (scale >= 8) {
      final start = e.gridOf(Offset.zero), end = e.gridOf(Offset(size.width, size.height));
      final step = scale >= 12 ? 1 : 5;
      final minX = (start.dx / step).floor() * step;
      final minY = (start.dy / step).floor() * step;
      final maxX = end.dx.ceil();
      final maxY = end.dy.ceil();
      final minor = <Offset>[];
      final major = <Offset>[];
      for (var gx = minX; gx <= maxX; gx += step) {
        final sx = gx * scale + e.pan.dx;
        final majorX = gx % 5 == 0;
        for (var gy = minY; gy <= maxY; gy += step) {
          (majorX && gy % 5 == 0 ? major : minor).add(Offset(sx, gy * scale + e.pan.dy));
        }
      }
      if (minor.isNotEmpty) {
        canvas.drawPoints(PointMode.points, minor, Paint()
          ..color = tokens.gridDot
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 1.6);
      }
      if (major.isNotEmpty) {
        canvas.drawPoints(PointMode.points, major, Paint()
          ..color = tokens.gridDot
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 3.0);
      }
    }
    final r = e.result;
    final ink = tokens.text;
    // Wires, coloured by the supply on them while simulating.
    final wireWidth = (2.2 * e.zoom).clamp(1.4, 4.0);
    final endsAt = <String, int>{};
    for (final w in e.sheet.wires) {
      endsAt[w.a.key] = (endsAt[w.a.key] ?? 0) + 1;
      endsAt[w.b.key] = (endsAt[w.b.key] ?? 0) + 1;
      final points = e.sheet.path(w).map(e.screenOf).toList();
      var color = ink;
      if (r != null) {
        final label = r.labels[w.a.key];
        color = label == null ? tokens.deadWire : (label == 'short' ? tokens.error : kLiveColors[label] ?? ink);
      }
      if (w.id == e.selectedWire) {
        canvas.drawPoints(PointMode.polygon, points, Paint()
          ..color = tokens.accent
          ..strokeWidth = wireWidth + 4
          ..strokeCap = StrokeCap.round);
      }
      canvas.drawPoints(PointMode.polygon, points, Paint()
        ..color = color
        ..strokeWidth = r != null && r.labels[w.a.key] != null ? wireWidth + 1 : wireWidth
        ..strokeCap = StrokeCap.round);
    }
    // Junction dots where three or more wires meet.
    for (final s in e.sheet.symbols) {
      for (final pin in s.def.pins.keys) {
        if ((endsAt['${s.id}:$pin'] ?? 0) + (s.type == 'node' ? 0 : 1) >= 3 || (s.type == 'node' && (endsAt['${s.id}:$pin'] ?? 0) >= 3)) {
          final label = r?.labels['${s.id}:$pin'];
          canvas.drawCircle(e.screenOf(s.pin(pin)), (3.2 * e.zoom).clamp(2.5, 6.0), Paint()..color = label == null ? ink : kLiveColors[label] ?? ink);
        }
      }
    }
    // Symbols.
    final now = e._now;
    for (final s in e.sheet.symbols) {
      if (s.type == 'node') continue;
      final look = RelayLook(
        poles: r?.actuated[s.id],
        on: r != null && (r.loadsOn.contains(s.id) || (s.type == 'diode' && r.closed.contains(s.id)) || _sourceLive(s, r)),
        motor: r?.motors[s.id] ?? 0,
        mode: r?.motorModes[s.id],
        position: e.sim?.positions[s.id] ?? 0,
        spin: now * 6,
        flash: (now * 2).floor().isEven,
      );
      final selected = s.id == e.selectedSymbol;
      if (selected) {
        final rect = Rect.fromPoints(e.screenOf(s.rect.topLeft), e.screenOf(s.rect.bottomRight)).inflate(5);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), Paint()
          ..color = tokens.accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
      }
      canvas.save();
      canvas.translate(e.screenOf(Offset(s.x.toDouble(), s.y.toDouble())).dx, e.screenOf(Offset(s.x.toDouble(), s.y.toDouble())).dy);
      canvas.scale(scale);
      final w = s.def.size.width, h = s.def.size.height;
      switch (s.rotation % 4) {
        case 1:
          canvas.translate(h, 0);
          canvas.rotate(math.pi / 2);
        case 2:
          canvas.translate(w, h);
          canvas.rotate(math.pi);
        case 3:
          canvas.translate(0, w);
          canvas.rotate(3 * math.pi / 2);
      }
      // A closed contact or switch takes the colour of what flows through it, so the live path reads unbroken.
      var symbolInk = ink;
      if (r != null && r.closed.contains(s.id)) {
        final labels = {for (final pin in s.def.pins.keys) r.labels['${s.id}:$pin']}..remove(null);
        if (labels.length == 1 && kLiveColors[labels.first] != null) symbolInk = kLiveColors[labels.first]!;
      }
      drawRelaySymbol(canvas, s, look, symbolInk);
      canvas.restore();
      // The tag beside the symbol, upright whatever the rotation.
      if (s.tag.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(text: s.tag, style: plateText((13 * e.zoom).clamp(9.0, 22.0), selected ? tokens.accent : ink, weight: 700)),
          textDirection: TextDirection.ltr,
        )..layout();
        final rect = s.rect;
        final at = e.screenOf(Offset(rect.right, rect.top + rect.height / 2)) + Offset(4, -tp.height / 2);
        tp.paint(canvas, at);
        if (r != null && kRelayTimers.contains(s.type)) {
          final t = e.sim!.timerElapsed(s.tag, now);
          if (t != null) {
            final tt = TextPainter(
              text: TextSpan(text: '${t.clamp(0, s.seconds).toStringAsFixed(1)} s', style: plateText((12 * e.zoom).clamp(9.0, 18.0), tokens.run, weight: 700)),
              textDirection: TextDirection.ltr,
            )..layout();
            tt.paint(canvas, at + Offset(0, tp.height));
          }
        }
      }
    }
    // Pins while editing, the hovered one larger.
    if (r == null) {
      final hover = e.pointer == null ? null : e.pinAt(e.pointer!);
      for (final s in e.sheet.symbols) {
        if (s.type == 'node') continue;
        for (final pin in s.def.pins.keys) {
          final p = e.screenOf(s.pin(pin));
          final active = hover == RelayEnd(s.id, pin) || e.pending == RelayEnd(s.id, pin);
          canvas.drawCircle(p, active ? 5 : 2.8, Paint()
            ..color = active ? tokens.accent : tokens.panel
            ..style = PaintingStyle.fill);
          canvas.drawCircle(p, active ? 5 : 2.8, Paint()
            ..color = active ? tokens.accent : ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2);
        }
      }
    }
    // The wire being drawn, through its bends to the pointer.
    final pending = e.pending;
    if (pending != null && e.pointer != null) {
      final points = <Offset>[e.screenOf(e.sheet.endPoint(pending))];
      final target = e.pinAt(e.pointer!);
      final last = target != null ? e.screenOf(e.sheet.endPoint(target)) : e.screenOf(e._snap(e.gridOf(e.pointer!)));
      for (final next in [...e.corners.map(e.screenOf), last]) {
        final prev = points.last;
        if ((prev.dx - next.dx).abs() > 0.5 && (prev.dy - next.dy).abs() > 0.5) points.add(Offset(prev.dx, next.dy));
        points.add(next);
      }
      canvas.drawPoints(PointMode.polygon, points, Paint()
        ..color = tokens.accent
        ..strokeWidth = wireWidth
        ..strokeCap = StrokeCap.round);
    }
    // A ghost of the symbol about to be placed.
    final placing = e.placing;
    if (placing != null && e.pointer != null) {
      final (type, preset) = _RelayEditorState._item(placing);
      final def = kRelayTypeById[type]!;
      final g = e.gridOf(e.pointer!);
      final at = e._snap(Offset(g.dx - def.size.width / 2, g.dy - def.size.height / 2));
      canvas.save();
      final p = e.screenOf(at);
      canvas.translate(p.dx, p.dy);
      canvas.scale(scale);
      drawRelaySymbol(canvas, RelaySymbol(id: 0, type: type, tag: '', x: 0, y: 0, params: {'supply': ?preset}), const RelayLook(),
          tokens.accent.withValues(alpha: 0.7));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_SheetPainter old) => true;
}
