import 'dart:math' as math;

import 'plc.dart';

/// Zelio numbers its items 1-9 then letters, skipping I, M and O: Q1..Q9, QA, QB … , T1..TV.
const String kLadderIndex = '123456789ABCDEFGHJKLNPQRSTUVWXYZ';

/// Item names for a letter, e.g. ladderNames('M', 28) = M1..M9, MA..MV.
List<String> ladderNames(String letter, int count) => [for (var i = 0; i < count && i < kLadderIndex.length; i++) '$letter${kLadderIndex[i]}'];

/// One contact cell. An empty cell blocks; a wire conducts; a contact conducts while its bit is on (or off for NC).
class LadderCell {
  const LadderCell.empty({this.down = false}) : ref = null, wire = false, nc = false;
  const LadderCell.wire({this.down = false}) : ref = null, wire = true, nc = false;
  const LadderCell.contact(String this.ref, {this.nc = false, this.down = false}) : wire = false;

  /// I1, Q1, M1, T1, C1, Z1 … for a contact; null for a wire or an empty cell.
  final String? ref;
  final bool wire;
  final bool nc;

  /// A vertical link from this cell's right edge down to the row below.
  final bool down;

  bool get isEmpty => ref == null && !wire;

  LadderCell withDown(bool value) => ref != null ? LadderCell.contact(ref!, nc: nc, down: value) : (wire ? LadderCell.wire(down: value) : LadderCell.empty(down: value));

  /// Short text: '' empty, '-' wire, 'I1' or '!I1', with '|' at the end for a vertical link down.
  String get text => '${ref != null ? '${nc ? '!' : ''}$ref' : (wire ? '-' : '')}${down ? '|' : ''}';

  static LadderCell parse(String text) {
    var t = text.trim();
    final down = t.endsWith('|');
    if (down) t = t.substring(0, t.length - 1);
    if (t.isEmpty) return LadderCell.empty(down: down);
    if (t == '-') return LadderCell.wire(down: down);
    final nc = t.startsWith('!');
    return LadderCell.contact((nc ? t.substring(1) : t).toUpperCase(), nc: nc, down: down);
  }
}

/// What a coil does to its target, in Zelio notation: `[Q1` coil, `^Q1` impulse (toggle), `SQ1` set, `RQ1` reset,
/// `TT1` timer command, `RT1` timer reset, `CC1` count, `DC1` count direction (down while on), `RC1` counter reset.
class LadderCoil {
  const LadderCoil(this.fn, this.ref);

  final String fn;
  final String ref;

  String get text => '$fn$ref';

  static LadderCoil? parse(String? text) {
    final t = text?.trim().toUpperCase() ?? '';
    if (t.length < 2) return null;
    final fn = t[0];
    final ref = t.substring(1);
    if (!'[^SRTCD'.contains(fn)) return null;
    return LadderCoil(fn, ref);
  }

  static const Map<String, String> labels = {
    '[': 'Koil', '^': 'Impuls (toggle)', 'S': 'Set (kunci)', 'R': 'Reset', 'T': 'Perintah timer', 'C': 'Hitung', 'D': 'Arah hitung (turun)',
  };
}

class LadderRow {
  LadderRow({List<LadderCell>? cells, this.coil, this.comment = ''}) : cells = cells ?? List.filled(LadderProgram.columns, const LadderCell.empty());

  final List<LadderCell> cells;
  LadderCoil? coil;
  String comment;

  bool get isEmpty => coil == null && comment.isEmpty && cells.every((c) => c.isEmpty && !c.down);

  LadderRow copy() => LadderRow(cells: [...cells], coil: coil, comment: comment);
}

/// Zelio timer functions. Times in seconds; [preset2] is the second time of AC, L and I.
class LadderTimer {
  LadderTimer({this.function = 'A', this.preset = 3, this.preset2 = 1});

  String function;
  double preset;
  double preset2;

  static const Map<String, String> functions = {
    'A': 'A: tunda menyala (selama perintah aktif)',
    'a': 'a: tunda menyala, start/stop dengan pulsa',
    'C': 'C: tunda padam',
    'B': 'B: pulsa sekali saat perintah naik',
    'W': 'W: pulsa sekali saat perintah turun',
    'D': 'D: kedip simetris',
    'PD': 'PD: kedip simetris, start/stop dengan pulsa',
    'T': 'T: totalisator waktu',
    'AC': 'AC: tunda menyala dan tunda padam',
    'L': 'L: kedip asimetris',
    'I': 'I: kedip asimetris, start/stop dengan pulsa',
  };

  bool get hasSecond => function == 'AC' || function == 'L' || function == 'I';

  Map<String, dynamic> toJson() => {'f': function, 't': preset, if (hasSecond) 't2': preset2};

  factory LadderTimer.fromJson(Map<String, dynamic> json) =>
      LadderTimer(function: json['f'] as String? ?? 'A', preset: (json['t'] as num?)?.toDouble() ?? 3, preset2: (json['t2'] as num?)?.toDouble() ?? 1);
}

class LadderCounter {
  LadderCounter({this.preset = 5, this.toZero = false});

  int preset;

  /// Output when the value comes down to 0 (resetting loads the preset) instead of when it reaches the preset.
  bool toZero;

  Map<String, dynamic> toJson() => {'p': preset, if (toZero) 'z': true};

  factory LadderCounter.fromJson(Map<String, dynamic> json) => LadderCounter(preset: (json['p'] as num?)?.toInt() ?? 5, toZero: json['z'] == true);
}

/// One switching window of a clock block: the days it applies to and the minutes of the day it turns on and off.
/// An off time earlier than the on time runs past midnight into the next day.
class ClockSlot {
  ClockSlot({Set<int>? days, this.on = 8 * 60, this.off = 17 * 60}) : days = days ?? {1, 2, 3, 4, 5};

  /// ISO weekdays: 1 Monday … 7 Sunday.
  final Set<int> days;
  int on;
  int off;

  bool activeAt(DateTime time) {
    final minute = time.hour * 60 + time.minute;
    if (on == off) return false;
    if (on < off) return days.contains(time.weekday) && minute >= on && minute < off;
    final yesterday = time.weekday == 1 ? 7 : time.weekday - 1;
    return (days.contains(time.weekday) && minute >= on) || (days.contains(yesterday) && minute < off);
  }

  Map<String, dynamic> toJson() => {'d': (days.toList()..sort()), 'on': on, 'off': off};

  factory ClockSlot.fromJson(Map<String, dynamic> json) => ClockSlot(
        days: {for (final d in json['d'] as List<dynamic>? ?? const []) (d as num).toInt()},
        on: (json['on'] as num?)?.toInt() ?? 480,
        off: (json['off'] as num?)?.toInt() ?? 1020,
      );
}

/// A clock (time switch) block, H1-H8 on a Zelio: its contact is on while the PLC's real-time clock is inside any of
/// its windows.
class LadderClock {
  LadderClock({List<ClockSlot>? slots}) : slots = slots ?? [ClockSlot()];

  static const int maxSlots = 4;
  final List<ClockSlot> slots;

  bool activeAt(DateTime time) => slots.any((s) => s.activeAt(time));

  Map<String, dynamic> toJson() => {'s': [for (final s in slots) s.toJson()]};

  factory LadderClock.fromJson(Map<String, dynamic> json) =>
      LadderClock(slots: [for (final s in (json['s'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>()) ClockSlot.fromJson(s)]);
}

/// Day names as a PLC screen shows them, Monday first.
const List<String> kPlcDays = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];

/// "08:30" for a minute of the day.
String clockText(int minute) => '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

/// A ladder program on a Zelio-style grid: rows of five contact cells and one coil, joined by vertical links.
class LadderProgram {
  LadderProgram({
    List<LadderRow>? rows,
    Map<String, LadderTimer>? timers,
    Map<String, LadderCounter>? counters,
    Map<String, LadderClock>? clocks,
    Map<String, String>? symbols,
  })  : rows = rows ?? [],
        timers = timers ?? {},
        counters = counters ?? {},
        clocks = clocks ?? {},
        symbols = symbols ?? {};

  static const int columns = 5;
  static const int maxRows = 240;

  final List<LadderRow> rows;
  final Map<String, LadderTimer> timers;
  final Map<String, LadderCounter> counters;

  /// Clock (time switch) blocks by name, H1-H8.
  final Map<String, LadderClock> clocks;

  /// Names for addresses, e.g. I1 = "Start".
  final Map<String, String> symbols;

  bool get isEmpty => rows.every((r) => r.isEmpty);

  LadderTimer timer(String ref) => timers.putIfAbsent(ref, LadderTimer.new);
  LadderCounter counter(String ref) => counters.putIfAbsent(ref, LadderCounter.new);
  LadderClock clock(String ref) => clocks.putIfAbsent(ref, LadderClock.new);

  /// Clock blocks the program reads, in order of first use.
  List<String> get usedClocks {
    final out = <String>[];
    for (final row in rows) {
      for (final cell in row.cells) {
        final ref = cell.ref;
        if (ref != null && ref.startsWith('H') && !out.contains(ref)) out.add(ref);
      }
    }
    return out;
  }

  /// Timers and counters the program actually drives, in order of first use.
  List<String> used(String letter) {
    final out = <String>[];
    for (final row in rows) {
      final coil = row.coil;
      if (coil != null && coil.ref.startsWith(letter) && !out.contains(coil.ref)) out.add(coil.ref);
    }
    return out;
  }

  LadderProgram copy() => LadderProgram.fromJson(toJson());

  Map<String, dynamic> toJson() {
    var last = rows.length;
    while (last > 0 && rows[last - 1].isEmpty) {
      last--;
    }
    return {
      'rows': [
        for (var i = 0; i < last; i++)
          if (!rows[i].isEmpty)
            {
              'r': i,
              'c': [for (final cell in rows[i].cells) cell.text],
              if (rows[i].coil != null) 'o': rows[i].coil!.text,
              if (rows[i].comment.isNotEmpty) 'n': rows[i].comment,
            },
      ],
      if (timers.isNotEmpty) 'timers': {for (final e in timers.entries) e.key: e.value.toJson()},
      if (counters.isNotEmpty) 'counters': {for (final e in counters.entries) e.key: e.value.toJson()},
      if (clocks.isNotEmpty) 'clocks': {for (final e in clocks.entries) e.key: e.value.toJson()},
      if (symbols.isNotEmpty) 'symbols': symbols,
    };
  }

  factory LadderProgram.fromJson(Map<String, dynamic> json) {
    final program = LadderProgram(
      timers: {for (final e in (json['timers'] as Map<String, dynamic>? ?? const {}).entries) e.key: LadderTimer.fromJson(e.value as Map<String, dynamic>)},
      counters: {for (final e in (json['counters'] as Map<String, dynamic>? ?? const {}).entries) e.key: LadderCounter.fromJson(e.value as Map<String, dynamic>)},
      clocks: {for (final e in (json['clocks'] as Map<String, dynamic>? ?? const {}).entries) e.key: LadderClock.fromJson(e.value as Map<String, dynamic>)},
      symbols: (json['symbols'] as Map<String, dynamic>? ?? const {}).map((k, v) => MapEntry(k, '$v')),
    );
    for (final item in (json['rows'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>()) {
      final index = (item['r'] as num?)?.toInt() ?? program.rows.length;
      if (index < 0 || index >= maxRows) continue;
      while (program.rows.length <= index) {
        program.rows.add(LadderRow());
      }
      final cells = [for (final c in (item['c'] as List<dynamic>? ?? const [])) LadderCell.parse('$c')];
      while (cells.length < columns) {
        cells.add(const LadderCell.empty());
      }
      program.rows[index] = LadderRow(cells: cells.take(columns).toList(), coil: LadderCoil.parse(item['o'] as String?), comment: item['n'] as String? ?? '');
    }
    return program;
  }

  /// The program stored on a PLC: the grid when there is one, else the older rung list converted.
  static LadderProgram of(Map<String, dynamic> data) {
    final ladder = data['ladder'];
    if (ladder is Map<String, dynamic>) return LadderProgram.fromJson(ladder);
    final rungs = data['program'];
    if (rungs is List) return fromRungs([for (final r in rungs.whereType<Map<String, dynamic>>()) PlcRung.fromJson(r)]);
    return LadderProgram();
  }

  /// Converts the older rung list (parallel branches of series contacts → one coil) to the grid. When [renameCursor]
  /// is true (older saved programs), C1-C4 become Z1-Z4, and a T coil becomes an on-delay timer command.
  static LadderProgram fromRungs(List<PlcRung> rungs, {bool renameCursor = true}) {
    final program = LadderProgram();
    String rename(String ref) => renameCursor && RegExp(r'^C[1-4]$').hasMatch(ref) ? 'Z${ref.substring(1)}' : ref;
    for (final rung in rungs) {
      final branches = rung.branches.where((b) => b.isNotEmpty).toList();
      if (branches.isEmpty) continue;
      final width = branches.map((b) => b.length).reduce(math.max).clamp(1, columns);
      final start = program.rows.length;
      for (var i = 0; i < branches.length; i++) {
        final cells = <LadderCell>[];
        final branch = branches[i].take(columns).toList();
        for (var c = 0; c < columns; c++) {
          final last = i < branches.length - 1 && c == width - 1;
          if (c < branch.length) {
            cells.add(LadderCell.contact(rename(branch[c].ref), nc: branch[c].negated, down: last));
          } else if (i == 0 || c < width) {
            cells.add(c < width ? LadderCell.wire(down: last) : const LadderCell.wire());
          } else {
            cells.add(const LadderCell.empty());
          }
        }
        program.rows.add(LadderRow(cells: cells));
      }
      final coil = rung.coil;
      if (coil.startsWith('T')) {
        program.rows[start].coil = LadderCoil('T', coil);
        program.timer(coil)
          ..function = 'A'
          ..preset = rung.preset;
      } else {
        program.rows[start].coil = LadderCoil('[', coil);
      }
    }
    return program;
  }
}

/// A timer's running state, kept between scans.
class TimerRun {
  TimerRun({this.input = false, this.reset = false, this.since, this.acc = 0, this.out = false, this.running = false, this.edge});

  bool input;
  bool reset;

  /// Simulation time the current phase started.
  double? since;

  /// Accumulated on-time, for the totalizer.
  double acc;
  bool out;

  /// Started by a pulse (a, PD, I) or flashing.
  bool running;

  /// When the input last went off, for off-delays.
  double? edge;

  TimerRun copy() => TimerRun(input: input, reset: reset, since: since, acc: acc, out: out, running: running, edge: edge);
}

/// Everything a PLC remembers from one scan to the next. The solver never changes it in place: a scan works on a copy
/// and the app keeps the copy once the circuit has settled, so edges are counted once however often it re-solves.
class PlcMemory {
  PlcMemory({Set<String>? bits, Map<String, TimerRun>? timers, Map<String, int>? counts, Map<String, bool>? edges})
      : bits = bits ?? {},
        timers = timers ?? {},
        counts = counts ?? {},
        edges = edges ?? {};

  /// Q, M and N bits, plus timer and counter outputs.
  final Set<String> bits;
  final Map<String, TimerRun> timers;
  final Map<String, int> counts;

  /// Last power of each edge-triggered coil, keyed by row.
  final Map<String, bool> edges;

  PlcMemory copy() => PlcMemory(
        bits: {...bits},
        timers: {for (final e in timers.entries) e.key: e.value.copy()},
        counts: {...counts},
        edges: {...edges},
      );

  /// A timer is counting, so the scan has to run again as time passes.
  bool get ticking => timers.values.any((t) => t.since != null || t.edge != null);
}

class LadderScan {
  const LadderScan(this.bits, this.memory);

  /// Every bit that is on: inputs, keys, outputs, relays, timer and counter outputs.
  final Set<String> bits;
  final PlcMemory memory;
}

/// Runs one scan, rows top to bottom: a coil's new state is visible to the rows below it in the same scan. [now] is
/// simulation time in seconds; [clock] is the PLC's real-time clock, which drives the clock blocks (H). [memory] is not
/// changed.
LadderScan scanLadder(
  LadderProgram program, {
  required Set<String> inputs,
  Set<String> external = const {},
  PlcMemory? memory,
  required double now,
  DateTime? clock,
}) {
  final mem = (memory ?? PlcMemory()).copy();
  final bits = <String>{...mem.bits, ...inputs, ...external}..removeWhere((b) => b.startsWith('H'));
  if (clock != null) {
    for (final entry in program.clocks.entries) {
      if (entry.value.activeAt(clock)) bits.add(entry.key);
    }
  }
  bool read(String ref) => bits.contains(ref);

  final rows = program.rows;
  final timerCmd = <String, bool>{};
  var r = 0;
  while (r < rows.length) {
    // A rung: this row and the rows its vertical links reach.
    var end = r;
    while (end < rows.length - 1 && rows[end].cells.any((c) => c.down)) {
      end++;
    }
    final count = end - r + 1;
    var power = List<bool>.filled(count, true);
    for (var c = 0; c < LadderProgram.columns; c++) {
      final out = [
        for (var i = 0; i < count; i++)
          power[i] &&
              (() {
                final cell = rows[r + i].cells[c];
                if (cell.wire) return true;
                if (cell.ref == null) return false;
                return read(cell.ref!) != cell.nc;
              })(),
      ];
      // Vertical links at this column's right edge join rows: the joined node is on if any of them is.
      var i = 0;
      while (i < count) {
        var j = i;
        while (j < count - 1 && rows[r + j].cells[c].down) {
          j++;
        }
        if (j > i) {
          final any = out.sublist(i, j + 1).any((v) => v);
          for (var k = i; k <= j; k++) {
            out[k] = any;
          }
        }
        i = j + 1;
      }
      power = out;
    }
    for (var i = 0; i < count; i++) {
      final coil = rows[r + i].coil;
      if (coil != null) _drive(program, mem, bits, coil, power[i], 'r${r + i}', now, timerCmd);
    }
    r = end + 1;
  }
  // Timers whose command rung was not reached this scan still run on (flashers, off-delays).
  for (final entry in mem.timers.entries) {
    _timer(program.timer(entry.key), entry.value, now);
    entry.value.out ? bits.add(entry.key) : bits.remove(entry.key);
  }
  mem.bits
    ..clear()
    ..addAll(bits.where((b) => !inputs.contains(b) && !external.contains(b)));
  return LadderScan(bits, mem);
}

void _drive(LadderProgram program, PlcMemory mem, Set<String> bits, LadderCoil coil, bool power, String key, double now, Map<String, bool> timerCmd) {
  final ref = coil.ref;
  bool rising() {
    final before = mem.edges[key] ?? false;
    mem.edges[key] = power;
    return power && !before;
  }

  switch (coil.fn) {
    case '[':
      power ? bits.add(ref) : bits.remove(ref);
    case '^':
      if (rising()) bits.contains(ref) ? bits.remove(ref) : bits.add(ref);
    case 'S':
      if (power) bits.add(ref);
    case 'R' when ref.startsWith('T'):
      final run = mem.timers.putIfAbsent(ref, TimerRun.new);
      final wasReset = run.reset;
      run.reset = power;
      if (power) {
        run
          ..input = false
          ..since = null
          ..acc = 0
          ..out = false
          ..running = false
          ..edge = null;
      } else if (wasReset && timerCmd[ref] == true) {
        // A held TT coil above this reset row starts immediately once reset drops.
        run.input = true;
        _command(program.timer(ref), run, false, true, now);
        _timer(program.timer(ref), run, now);
      }
      run.out ? bits.add(ref) : bits.remove(ref);
    case 'R' when ref.startsWith('C'):
      if (power) {
        final setup = program.counter(ref);
        mem.counts[ref] = setup.toZero ? setup.preset : 0;
      }
      _counterOut(program, mem, bits, ref);
    case 'R':
      if (power) bits.remove(ref);
    case 'T':
      final run = mem.timers.putIfAbsent(ref, TimerRun.new);
      timerCmd[ref] = power;
      if (!run.reset) {
        final before = run.input;
        run.input = power;
        _command(program.timer(ref), run, before, power, now);
        _timer(program.timer(ref), run, now);
      } else {
        run.input = false;
      }
      run.out ? bits.add(ref) : bits.remove(ref);
    case 'C':
      if (rising()) {
        final setup = program.counter(ref);
        final down = mem.edges['dir:$ref'] ?? false;
        final value = mem.counts[ref] ?? (setup.toZero ? setup.preset : 0);
        mem.counts[ref] = down ? value - 1 : value + 1;
      }
      _counterOut(program, mem, bits, ref);
    case 'D':
      mem.edges['dir:$ref'] = power;
  }
}

void _counterOut(LadderProgram program, PlcMemory mem, Set<String> bits, String ref) {
  final setup = program.counter(ref);
  final value = mem.counts[ref] ?? (setup.toZero ? setup.preset : 0);
  final on = setup.toZero ? value <= 0 : value >= setup.preset;
  on ? bits.add(ref) : bits.remove(ref);
}

/// Reacts to the timer command changing.
void _command(LadderTimer setup, TimerRun run, bool before, bool input, double now) {
  final rise = input && !before;
  final fall = !input && before;
  switch (setup.function) {
    case 'A' || 'AC':
      if (rise) {
        run.edge = null;
        if (!run.out) run.since = now;
      }
      if (fall) {
        if (setup.function == 'AC' && run.out) {
          run.edge = now;
        } else {
          run
            ..since = null
            ..out = false;
        }
      }
    case 'C':
      if (rise) {
        run
          ..out = true
          ..since = null
          ..edge = null;
      }
      if (fall) run.since = now;
    case 'B':
      if (rise && run.since == null) {
        run
          ..out = true
          ..since = now;
      }
    case 'W':
      if (fall) {
        run
          ..out = true
          ..since = now;
      }
    case 'D' || 'L':
      if (rise) {
        run
          ..running = true
          ..out = true
          ..since = now;
      }
      if (fall) {
        run
          ..running = false
          ..out = false
          ..since = null;
      }
    case 'a':
      if (rise) {
        run.running = !run.running;
        run
          ..since = run.running ? now : null
          ..out = false;
      }
    case 'PD' || 'I':
      if (rise) {
        run.running = !run.running;
        run
          ..out = run.running
          ..since = run.running ? now : null;
      }
    case 'T':
      if (rise) run.since = now;
      if (fall && run.since != null) {
        run
          ..acc += now - run.since!
          ..since = null;
      }
  }
}

/// Advances a timer to [now].
void _timer(LadderTimer setup, TimerRun run, double now) {
  final since = run.since;
  final t1 = setup.preset;
  final t2 = setup.preset2;
  switch (setup.function) {
    case 'A' || 'a':
      if (since != null && now - since >= t1) {
        run
          ..out = true
          ..since = null;
      }
    case 'AC':
      if (run.edge != null) {
        if (now - run.edge! >= t2) {
          run
            ..out = false
            ..edge = null
            ..since = null;
        }
      } else if (since != null && now - since >= t1) {
        run
          ..out = true
          ..since = null;
      }
    case 'C' || 'B' || 'W':
      if (since != null && now - since >= t1) {
        run
          ..out = false
          ..since = null;
      }
    case 'D' || 'PD' || 'L' || 'I':
      if (since != null && run.running) {
        final on = t1;
        final off = setup.function == 'D' || setup.function == 'PD' ? t1 : t2;
        final phase = (now - since) % math.max(0.05, on + off);
        run.out = phase < on;
      }
    case 'T':
      final total = run.acc + (since != null ? now - since : 0);
      if (total >= t1 && !run.out) {
        run
          ..out = true
          ..acc = total
          ..since = null;
      }
  }
}

/// Seconds a timer has been counting in its current phase, for screens; null when idle.
double? ladderTimerElapsed(TimerRun? run, double now) {
  if (run == null) return null;
  if (run.edge != null) return now - run.edge!;
  if (run.since == null) return run.acc > 0 ? run.acc : null;
  return run.acc + now - run.since!;
}

/// The program as lines of text: `003: I1 | !I2| | - | - | -  ->  [Q1   (comment)`, one per non-empty row.
List<String> ladderText(LadderProgram program) => [
      for (var i = 0; i < program.rows.length; i++)
        if (!program.rows[i].isEmpty)
          '${(i + 1).toString().padLeft(3, '0')}: ${program.rows[i].cells.map((c) => c.text.isEmpty ? '.' : c.text).join(' ')}'
              '${program.rows[i].coil != null ? '  ->  ${program.rows[i].coil!.text}' : ''}'
              '${program.rows[i].comment.isNotEmpty ? '   (${program.rows[i].comment})' : ''}',
    ];
