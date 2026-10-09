import 'package:napi/napi.dart';

typedef Observation = ({String operation, int durationUs, bool success});
typedef Summary = ({
  String operation,
  int calls,
  int failed,
  int totalDurationUs,
});

const _maxSafeInteger = 9007199254740991;

/// Counts requests per exact operation name in UTF-16 code-unit order.
/// Durations and each operation's total must fit a nonnegative safe JS integer.
@napi
List<Summary> summarize(List<Observation> observations) {
  final groups = <String, _Counts>{};
  for (final observation in observations) {
    final duration = observation.durationUs;
    if (duration < 0) {
      throw RangeError('durationUs must be nonnegative');
    }
    if (duration > _maxSafeInteger) {
      throw RangeError(
        'durationUs must be within the JavaScript safe integer range',
      );
    }
    final counts = groups[observation.operation] ??= _Counts();
    if (duration > _maxSafeInteger - counts.totalDurationUs) {
      throw RangeError(
        'totalDurationUs must be within the JavaScript safe integer range',
      );
    }
    counts.calls++;
    if (!observation.success) counts.failed++;
    counts.totalDurationUs += duration;
  }
  final entries = groups.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return [
    for (final entry in entries)
      (
        operation: entry.key,
        calls: entry.value.calls,
        failed: entry.value.failed,
        totalDurationUs: entry.value.totalDurationUs,
      ),
  ];
}

final class _Counts {
  int calls = 0;
  int failed = 0;
  int totalDurationUs = 0;
}
