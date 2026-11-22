import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// One wire to route: from terminal [a] out to [exitA], across the panel to [exitB], and in to terminal [b].
/// The two stubs (terminal to exit) are straight; the router finds the part in between.
class WireRequest {
  const WireRequest(this.id, this.a, this.exitA, this.exitB, this.b, {this.viaA = const [], this.viaB = const []});

  final int id;
  final Offset a;
  final Offset exitA;
  final Offset exitB;
  final Offset b;

  /// Bends between a terminal and its exit, for a terminal boxed in by others (a motor's lower terminal row): the
  /// stub steps around the terminal in its way. Listed from the terminal outwards.
  final List<Offset> viaA;
  final List<Offset> viaB;
}

/// Routes wires like a panel builder would: the shortest way around the parts, with few bends, few crossings, and
/// without laying a wire on top of another.
///
/// The panel is cut into a grid whose lines include every wire's exit, so ends line up with their terminals exactly.
/// Each wire is found with A* over (grid point, heading), where a step costs its length, turning costs extra, and
/// running along or across a wire that was routed before costs extra too. Short wires go first, so long wires make
/// way around them rather than the other way round.
class WireRouter {
  WireRouter(List<Rect> obstacles, {this.cell = 12, double? clearance}) : clearance = clearance ?? defaultClearance,        _obstacles = [for (final r in obstacles) r.inflate(clearance ?? defaultClearance)];

  /// Room kept free around each part unless the caller asks otherwise.
  static const double defaultClearance = 10;

  /// Grid spacing in canvas pixels.
  final double cell;

  /// Room kept free around each part.
  final double clearance;

  final List<Rect> _obstacles;

  /// Cost of one turn, in pixels of extra length it is worth avoiding.
  static const double bendCost = 50;

  /// Extra cost per pixel of running on top of a wire already routed (it is spread into a lane afterwards).
  static const double shareCost = 1;

  /// Extra cost of crossing a wire already routed.
  static const double crossCost = 90;

  /// Routes all wires; a wire that cannot be routed is missing from the result.
  Map<int, List<Offset>> routeAll(List<WireRequest> wires) {
    bool finite(Offset p) => p.dx.isFinite && p.dy.isFinite;
    if (wires.isEmpty ||
        _obstacles.any((r) => !r.left.isFinite || !r.top.isFinite || !r.right.isFinite || !r.bottom.isFinite) ||
        wires.any((w) => !finite(w.a) || !finite(w.exitA) || !finite(w.exitB) || !finite(w.b) || w.viaA.any((p) => !finite(p)) || w.viaB.any((p) => !finite(p)))) {
      return {};
    }
    final grid = _Grid.build(_obstacles, wires, cell);
    if (grid.count == 0 || grid.count > 100000) return {};
    final ordered = [...wires]..sort((p, q) => _manhattan(p.exitA, p.exitB).compareTo(_manhattan(q.exitA, q.exitB)));
    final out = <int, List<Offset>>{};
    for (final wire in ordered) {
      final path = _route(grid, wire);
      if (path == null) continue;
      out[wire.id] = path;
    }
    return out;
  }

  static double _manhattan(Offset p, Offset q) => (p.dx - q.dx).abs() + (p.dy - q.dy).abs();

  /// Heading of a straight step: 0 right, 1 down, 2 left, 3 up, or -1 for no step.
  static int _heading(Offset from, Offset to) {
    final dx = to.dx - from.dx, dy = to.dy - from.dy;
    if (dx.abs() < 0.01 && dy.abs() < 0.01) return -1;
    if (dy.abs() < 0.01) return dx > 0 ? 0 : 2;
    if (dx.abs() < 0.01) return dy > 0 ? 1 : 3;
    return -1;
  }

  List<Offset>? _route(_Grid g, WireRequest w) {
    final start = g.node(w.exitA), goal = g.node(w.exitB);
    if (start < 0 || goal < 0) return null;
    // The stubs set the heading leaving the first part and arriving at the second; turning off them costs a bend.
    final startHeading = _heading(w.viaA.isEmpty ? w.a : w.viaA.last, w.exitA);
    final goalHeading = _heading(w.exitB, w.viaB.isEmpty ? w.b : w.viaB.last);
    final n = g.count;
    final cost = Float64List(n * 4)..fillRange(0, n * 4, double.infinity);
    final from = Int32List(n * 4)..fillRange(0, n * 4, -1);
    final heap = _Heap();
    final gx = g.xOf(goal), gy = g.yOf(goal);
    double estimate(int node) => (g.xOf(node) - gx).abs() + (g.yOf(node) - gy).abs();

    for (var h = 0; h < 4; h++) {
      final s = start * 4 + h;
      // Leaving against the stub would fold the wire back over itself.
      if (startHeading >= 0 && h == (startHeading + 2) % 4) continue;
      cost[s] = startHeading >= 0 && h != startHeading ? bendCost : 0;
      heap.push(cost[s] + estimate(start), s);
    }
    var best = -1;
    while (heap.isNotEmpty) {
      final state = heap.pop();
      final node = state >> 2, heading = state & 3;
      final here = cost[state];
      if (node == goal) {
        best = state;
        break;
      }
      for (var h = 0; h < 4; h++) {
        if (h == (heading + 2) % 4) continue;
        final next = g.neighbour(node, h);
        if (next < 0) continue;
        if (g.blocked[next] == 1 && next != goal) continue;
        final length = g.distance(node, next);
        var step = length;
        if (h != heading) step += bendCost;
        final horizontal = h == 0 || h == 2;
        final edge = g.edgeIndex(node, h);
        step += g.edgeUse[edge] * length * shareCost;
        // Crossing: the next point carries a wire running the other way.
        if ((g.nodeUse[next] & (horizontal ? 2 : 1)) != 0) step += crossCost;
        if (next == goal && goalHeading >= 0 && h != goalHeading) step += bendCost;
        final s = next * 4 + h;
        final total = here + step;
        if (total < cost[s]) {
          cost[s] = total;
          from[s] = state;
          heap.push(total + estimate(next), s);
        }
      }
    }
    if (best < 0) return null;

    // Walk back, mark what the wire uses so later wires steer clear, and keep only the corners.
    final nodes = <int>[];
    for (var s = best; s >= 0; s = from[s]) {
      nodes.add(s >> 2);
    }
    final points = <Offset>[w.a, ...w.viaA, w.exitA];
    for (var i = nodes.length - 1; i >= 0; i--) {
      final node = nodes[i];
      if (i < nodes.length - 1) {
        final prev = nodes[i + 1];
        final h = g.headingBetween(prev, node);
        g.edgeUse[g.edgeIndex(prev, h)]++;
        final bit = h == 0 || h == 2 ? 1 : 2;
        g.nodeUse[prev] |= bit;
        g.nodeUse[node] |= bit;
      }
      points.add(g.point(node));
    }
    points
      ..add(w.exitB)
      ..addAll(w.viaB.reversed)
      ..add(w.b);
    return _corners(points);
  }

  /// Drops repeated points and points in the middle of a straight run.
  static List<Offset> _corners(List<Offset> points) {
    final out = <Offset>[];
    for (final p in points) {
      if (out.isNotEmpty && (out.last - p).distance < 0.01) continue;
      if (out.length >= 2) {
        final a = out[out.length - 2], b = out.last;
        final straight = ((a.dx - b.dx).abs() < 0.01 && (b.dx - p.dx).abs() < 0.01) || ((a.dy - b.dy).abs() < 0.01 && (b.dy - p.dy).abs() < 0.01);
        if (straight) out.removeLast();
      }
      out.add(p);
    }
    // The ends must stay exactly on their terminals even if a stub had no length.
    if (out.first != points.first) out.insert(0, points.first);
    if (out.last != points.last) out.add(points.last);
    return out;
  }
}

/// A rectilinear grid over the panel. Lines run every [cell] pixels, plus one through every wire exit, so the grid
/// is slightly uneven; distances are always the real ones.
class _Grid {
  _Grid(this.xs, this.ys)
      : blocked = Uint8List(xs.length * ys.length),
        nodeUse = Uint8List(xs.length * ys.length),
        edgeUse = Uint16List(xs.length * ys.length * 2),
        edgeBlocked = Uint8List(xs.length * ys.length * 2);

  final List<double> xs;
  final List<double> ys;

  /// 1 where a point lies inside a part (with its clearance).
  final Uint8List blocked;

  /// Per point: bit 1 when a routed wire runs horizontally through it, bit 2 vertically.
  final Uint8List nodeUse;

  /// Per edge (two per point: to the right and down): how many routed wires run along it.
  final Uint16List edgeUse;

  /// Per edge: 1 when its middle lies inside a part, so the step would slice through a part thinner than the grid.
  final Uint8List edgeBlocked;

  int get count => xs.length * ys.length;
  int get width => xs.length;

  double xOf(int node) => xs[node % width];
  double yOf(int node) => ys[node ~/ width];
  Offset point(int node) => Offset(xOf(node), yOf(node));

  static _Grid build(List<Rect> obstacles, List<WireRequest> wires, double cell) {
    var left = double.infinity, top = double.infinity, right = -double.infinity, bottom = -double.infinity;
    void include(Offset p) {
      left = math.min(left, p.dx);
      top = math.min(top, p.dy);
      right = math.max(right, p.dx);
      bottom = math.max(bottom, p.dy);
    }

    for (final r in obstacles) {
      include(r.topLeft);
      include(r.bottomRight);
    }
    for (final w in wires) {
      include(w.exitA);
      include(w.exitB);
    }
    // Room to go around the outside of everything when there is no way through.
    const margin = 120.0;
    left -= margin;
    top -= margin;
    right += margin;
    bottom += margin;
    final spanX = right - left, spanY = bottom - top;
    if (!left.isFinite || !top.isFinite || !right.isFinite || !bottom.isFinite || !spanX.isFinite || !spanY.isFinite || cell <= 0 || !cell.isFinite) {
      return _Grid(const [], const []);
    }
    const maxNodes = 40000;
    const maxAxis = 1000;
    final step = (spanX / cell) * (spanY / cell) > maxNodes || spanX / cell > maxAxis || spanY / cell > maxAxis
        ? math.max(cell, math.max(math.max(spanX, spanY) / maxAxis, math.sqrt(spanX * spanY / maxNodes)))
        : cell;
    if (!step.isFinite || step <= 0) return _Grid(const [], const []);

    List<double> lines(double from, double to, Iterable<double> fixed) {
      final exact = fixed.where((v) => v.isFinite).toSet().toList()..sort();
      final out = <double>[...exact];
      for (var v = (from / step).floorToDouble() * step; v <= to;) {
        // A regular line too close to an exit line would make a tiny jog; the exit line stands in for it.
        if (!exact.any((e) => (e - v).abs() < step * 0.4)) out.add(v);
        final next = v + step;
        if (next <= v) break;
        v = next;
      }
      out.sort();
      return out;
    }

    final xs = lines(left, right, [for (final w in wires) ...[w.exitA.dx, w.exitB.dx]]);
    final ys = lines(top, bottom, [for (final w in wires) ...[w.exitA.dy, w.exitB.dy]]);
    if (xs.isEmpty || ys.isEmpty || xs.length * ys.length > 100000) return _Grid(const [], const []);
    final grid = _Grid(xs, ys);
    for (final r in obstacles) {
      final x0 = _lowerBound(xs, r.left), x1 = _lowerBound(xs, r.right);
      final y0 = _lowerBound(ys, r.top), y1 = _lowerBound(ys, r.bottom);
      for (var yi = y0; yi < y1 && yi < ys.length; yi++) {
        for (var xi = x0; xi < x1 && xi < xs.length; xi++) {
          if (xs[xi] > r.left && xs[xi] < r.right && ys[yi] > r.top && ys[yi] < r.bottom) grid.blocked[yi * xs.length + xi] = 1;
        }
      }
    }
    // A step between two free points can still cut through a part narrower than the grid spacing.
    for (final r in obstacles) {
      final x0 = math.max(0, _lowerBound(xs, r.left) - 1), x1 = math.min(xs.length - 1, _lowerBound(xs, r.right));
      final y0 = math.max(0, _lowerBound(ys, r.top) - 1), y1 = math.min(ys.length - 1, _lowerBound(ys, r.bottom));
      bool inside(double x, double y) => x > r.left && x < r.right && y > r.top && y < r.bottom;
      for (var yi = y0; yi <= y1; yi++) {
        for (var xi = x0; xi <= x1; xi++) {
          final node = yi * xs.length + xi;
          if (xi + 1 < xs.length && inside((xs[xi] + xs[xi + 1]) / 2, ys[yi])) grid.edgeBlocked[node * 2] = 1;
          if (yi + 1 < ys.length && inside(xs[xi], (ys[yi] + ys[yi + 1]) / 2)) grid.edgeBlocked[node * 2 + 1] = 1;
        }
      }
    }
    return grid;
  }

  static int _lowerBound(List<double> values, double v) {
    var lo = 0, hi = values.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (values[mid] < v) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The grid point exactly at [p] (an exit), or -1.
  int node(Offset p) {
    final xi = _lowerBound(xs, p.dx - 0.001), yi = _lowerBound(ys, p.dy - 0.001);
    if (xi >= xs.length || yi >= ys.length) return -1;
    if ((xs[xi] - p.dx).abs() > 0.01 || (ys[yi] - p.dy).abs() > 0.01) return -1;
    return yi * width + xi;
  }

  int neighbour(int node, int heading) {
    final xi = node % width, yi = node ~/ width;
    final next = switch (heading) {
      0 => xi + 1 < width ? node + 1 : -1,
      1 => yi + 1 < ys.length ? node + width : -1,
      2 => xi > 0 ? node - 1 : -1,
      _ => yi > 0 ? node - width : -1,
    };
    if (next < 0) return -1;
    return edgeBlocked[edgeIndex(node, heading)] == 1 ? -1 : next;
  }

  double distance(int a, int b) => (xOf(a) - xOf(b)).abs() + (yOf(a) - yOf(b)).abs();

  int headingBetween(int a, int b) {
    if (b == a + 1) return 0;
    if (b == a + width) return 1;
    if (b == a - 1) return 2;
    return 3;
  }

  /// Index of the edge leaving [node] in [heading]; an edge has the same index from either end.
  int edgeIndex(int node, int heading) => switch (heading) {
        0 => node * 2,
        1 => node * 2 + 1,
        2 => (node - 1) * 2,
        _ => (node - width) * 2 + 1,
      };
}

/// A binary min-heap of (priority, state).
class _Heap {
  final _keys = <double>[];
  final _values = <int>[];

  bool get isNotEmpty => _keys.isNotEmpty;

  void push(double key, int value) {
    _keys.add(key);
    _values.add(value);
    var i = _keys.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_keys[parent] <= _keys[i]) break;
      _swap(i, parent);
      i = parent;
    }
  }

  int pop() {
    final top = _values[0];
    final lastKey = _keys.removeLast(), lastValue = _values.removeLast();
    if (_keys.isNotEmpty) {
      _keys[0] = lastKey;
      _values[0] = lastValue;
      var i = 0;
      while (true) {
        final l = i * 2 + 1, r = l + 1;
        var smallest = i;
        if (l < _keys.length && _keys[l] < _keys[smallest]) smallest = l;
        if (r < _keys.length && _keys[r] < _keys[smallest]) smallest = r;
        if (smallest == i) break;
        _swap(i, smallest);
        i = smallest;
      }
    }
    return top;
  }

  void _swap(int i, int j) {
    final k = _keys[i];
    _keys[i] = _keys[j];
    _keys[j] = k;
    final v = _values[i];
    _values[i] = _values[j];
    _values[j] = v;
  }
}
