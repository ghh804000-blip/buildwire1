/// A small ladder program: each rung has parallel branches of series contacts, driving one coil.
class PlcContact {
  const PlcContact(this.ref, {this.negated = false});

  /// I1-I8 inputs, Q1-Q4 outputs, M1-M16 memory bits, T1-T4 timers.
  final String ref;

  /// A normally closed contact.
  final bool negated;

  Map<String, dynamic> toJson() => {'ref': ref, if (negated) 'neg': true};

  factory PlcContact.fromJson(Map<String, dynamic> json) => PlcContact(json['ref'] as String, negated: json['neg'] as bool? ?? false);
}

class PlcRung {
  PlcRung({required this.branches, required this.coil, this.preset = 3});

  List<List<PlcContact>> branches;

  /// Q, M or T.
  String coil;

  /// Seconds, for a T coil.
  double preset;

  Map<String, dynamic> toJson() => {
        'branches': [
          for (final branch in branches) [for (final contact in branch) contact.toJson()],
        ],
        'coil': coil,
        if (coil.startsWith('T')) 'preset': preset,
      };

  factory PlcRung.fromJson(Map<String, dynamic> json) => PlcRung(
        branches: [
          for (final branch in json['branches'] as List<dynamic>)
            [for (final contact in branch as List<dynamic>) PlcContact.fromJson(contact as Map<String, dynamic>)],
        ],
        coil: json['coil'] as String,
        preset: (json['preset'] as num?)?.toDouble() ?? 3,
      );
}

const List<String> kPlcInputs = ['I1', 'I2', 'I3', 'I4', 'I5', 'I6', 'I7', 'I8'];
const List<String> kPlcOutputs = ['Q1', 'Q2', 'Q3', 'Q4'];
const List<String> kPlcMemory = ['M1', 'M2', 'M3', 'M4', 'M5', 'M6', 'M7', 'M8', 'M9', 'M10', 'M11', 'M12', 'M13', 'M14', 'M15', 'M16'];
const List<String> kPlcTimers = ['T1', 'T2', 'T3', 'T4'];

/// The PLC's own arrow keys used as program inputs: C1 up, C2 right, C3 down, C4 left.
const List<String> kPlcCursorKeys = ['C1', 'C2', 'C3', 'C4'];

class PlcScan {
  const PlcScan(this.bits, this.timers);

  /// Every bit that is on after the scan.
  final Set<String> bits;

  /// Timer coils that are energized, with their presets in seconds.
  final Map<String, double> timers;
}

/// Scans rungs from top to bottom, so an earlier rung's coil is visible to later rungs in the same scan.
PlcScan plcScan(List<PlcRung> rungs, {required Set<String> inputs, required Set<String> previous, required Set<String> external, required Set<String> timersDone}) {
  final bits = <String>{...inputs, ...external};
  // Coils from the last scan stay readable, which is what makes a self-holding rung work.
  final retained = previous.where((bit) => bit.startsWith('Q') || bit.startsWith('M'));
  final current = <String>{...bits, ...retained, ...timersDone};
  final timers = <String, double>{};
  final next = <String>{...bits, ...timersDone};
  for (final rung in rungs) {
    final on = rung.branches.any((branch) => branch.isNotEmpty && branch.every((c) => current.contains(c.ref) != c.negated));
    if (rung.coil.startsWith('T')) {
      if (on) {
        timers[rung.coil] = rung.preset;
      } else {
        current.remove(rung.coil);
        next.remove(rung.coil);
      }
    } else if (on) {
      next.add(rung.coil);
      current.add(rung.coil);
    } else {
      current.remove(rung.coil);
    }
  }
  return PlcScan(next, timers);
}

String plcState(Set<String> bits) => (['run', (bits.toList()..sort()).join(',')]).join(':');

Set<String> plcBits(String? state) {
  if (state == null || !state.startsWith('run:')) return {};
  final text = state.substring(4);
  return text.isEmpty ? {} : text.split(',').toSet();
}
