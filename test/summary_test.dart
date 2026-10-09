import 'package:test/test.dart';

import '../example/requests/summary.dart';

const maxSafeInteger = 9007199254740991;

void main() {
  test('empty input returns a fresh empty list', () {
    final input = <Observation>[];
    final first = summarize(input);
    final second = summarize(input);
    expect(first, isEmpty);
    expect(second, isEmpty);
    expect(identical(first, second), isFalse);
    first.add((operation: '', calls: 1, failed: 0, totalDurationUs: 0));
    expect(second, isEmpty);
    expect(input, isEmpty);
  });

  test('repeated operations aggregate counts, failures and durations', () {
    expect(
      summarize([
        (operation: '/users', durationUs: 10, success: false),
        (operation: '/health', durationUs: 120, success: true),
        (operation: '/users', durationUs: 0, success: false),
        (operation: '/health', durationUs: 80, success: false),
        (operation: '/users', durationUs: 25, success: true),
      ]),
      [
        (operation: '/health', calls: 2, failed: 1, totalDurationUs: 200),
        (operation: '/users', calls: 3, failed: 2, totalDurationUs: 35),
      ],
    );
  });

  test('exact operation names include empty, whitespace and special keys', () {
    final input = <Observation>[
      (operation: 'toString', durationUs: 9, success: true),
      (operation: 'constructor', durationUs: 8, success: true),
      (operation: '__proto__', durationUs: 7, success: true),
      (operation: '/health ', durationUs: 6, success: true),
      (operation: '/health', durationUs: 5, success: true),
      (operation: r'$value', durationUs: 4, success: true),
      (operation: ' /health', durationUs: 3, success: true),
      (operation: ' ', durationUs: 2, success: true),
      (operation: '', durationUs: 1, success: true),
    ];
    expect(summarize(input), [
      (operation: '', calls: 1, failed: 0, totalDurationUs: 1),
      (operation: ' ', calls: 1, failed: 0, totalDurationUs: 2),
      (operation: ' /health', calls: 1, failed: 0, totalDurationUs: 3),
      (operation: r'$value', calls: 1, failed: 0, totalDurationUs: 4),
      (operation: '/health', calls: 1, failed: 0, totalDurationUs: 5),
      (operation: '/health ', calls: 1, failed: 0, totalDurationUs: 6),
      (operation: '__proto__', calls: 1, failed: 0, totalDurationUs: 7),
      (operation: 'constructor', calls: 1, failed: 0, totalDurationUs: 8),
      (operation: 'toString', calls: 1, failed: 0, totalDurationUs: 9),
    ]);
  });

  test('operation order follows UTF-16 code units without normalization', () {
    final result = summarize([
      for (final operation in [
        '\ue000',
        '\udc00',
        '😀',
        '\ud800',
        'é',
        'e\u0301',
        'a',
      ])
        (operation: operation, durationUs: 0, success: true),
    ]);
    expect(result.map((row) => row.operation), [
      'a',
      'e\u0301',
      'é',
      '\ud800',
      '😀',
      '\udc00',
      '\ue000',
    ]);
    expect(result.every((row) => row.calls == 1 && row.failed == 0), isTrue);
  });

  test('zero durations and all failed requests remain exact', () {
    expect(
      summarize([
        (operation: 'zero', durationUs: 0, success: false),
        (operation: 'zero', durationUs: 0, success: false),
      ]),
      [(operation: 'zero', calls: 2, failed: 2, totalDurationUs: 0)],
    );
  });

  test('safe integer maximum is accepted as an individual duration', () {
    expect(
      summarize([
        (operation: 'max', durationUs: maxSafeInteger, success: true),
      ]),
      [
        (
          operation: 'max',
          calls: 1,
          failed: 0,
          totalDurationUs: maxSafeInteger,
        ),
      ],
    );
  });

  test('safe integer maximum is accepted as a grouped total', () {
    expect(
      summarize([
        (operation: 'max', durationUs: maxSafeInteger - 1, success: true),
        (operation: 'max', durationUs: 1, success: false),
        (operation: 'max', durationUs: 0, success: true),
      ]),
      [
        (
          operation: 'max',
          calls: 3,
          failed: 1,
          totalDurationUs: maxSafeInteger,
        ),
      ],
    );
  });

  test('safe integer limit applies separately to each operation', () {
    expect(
      summarize([
        (operation: 'b', durationUs: maxSafeInteger, success: true),
        (operation: 'a', durationUs: maxSafeInteger, success: false),
      ]),
      [
        (operation: 'a', calls: 1, failed: 1, totalDurationUs: maxSafeInteger),
        (operation: 'b', calls: 1, failed: 0, totalDurationUs: maxSafeInteger),
      ],
    );
  });

  for (final duration in [-1, -maxSafeInteger]) {
    test('negative duration $duration is rejected', () {
      expect(
        () => summarize([
          (operation: 'valid', durationUs: 1, success: true),
          (operation: 'invalid', durationUs: duration, success: false),
        ]),
        throwsA(
          isA<RangeError>().having(
            (error) => error.message,
            'message',
            'durationUs must be nonnegative',
          ),
        ),
      );
    });
  }

  for (final duration in [maxSafeInteger + 1, 9223372036854775807]) {
    test('unsafe VM duration $duration is rejected before arithmetic', () {
      expect(
        () => summarize([
          (operation: 'invalid', durationUs: duration, success: true),
        ]),
        throwsA(
          isA<RangeError>().having(
            (error) => error.message,
            'message',
            'durationUs must be within the JavaScript safe integer range',
          ),
        ),
      );
    });
  }

  for (final durations in [
    [maxSafeInteger, 1],
    [1, maxSafeInteger],
    [maxSafeInteger - 1, 2],
  ]) {
    test('aggregate overflow $durations is rejected', () {
      expect(
        () => summarize([
          for (final duration in durations)
            (operation: 'overflow', durationUs: duration, success: true),
        ]),
        throwsA(
          isA<RangeError>().having(
            (error) => error.message,
            'message',
            'totalDurationUs must be within the JavaScript safe integer range',
          ),
        ),
      );
    });
  }

  test('input, results and later calls remain independent', () {
    final input = <Observation>[
      (operation: 'a', durationUs: 10, success: true),
    ];
    final original = List<Observation>.of(input);
    final first = summarize(input);
    final second = summarize(input);
    expect(input, original);
    expect(identical(first, second), isFalse);
    first[0] = (
      operation: 'changed',
      calls: 99,
      failed: 99,
      totalDurationUs: 99,
    );
    first.clear();
    input[0] = (operation: 'a', durationUs: 20, success: false);
    expect(second, [
      (operation: 'a', calls: 1, failed: 0, totalDurationUs: 10),
    ]);
    expect(summarize(input), [
      (operation: 'a', calls: 1, failed: 1, totalDurationUs: 20),
    ]);
  });

  test('failed calls leave input unchanged and do not poison later calls', () {
    final invalid = <Observation>[
      (operation: 'a', durationUs: maxSafeInteger, success: true),
      (operation: 'a', durationUs: 1, success: false),
    ];
    final original = List<Observation>.of(invalid);
    expect(() => summarize(invalid), throwsRangeError);
    expect(invalid, original);
    expect(summarize([(operation: 'a', durationUs: 7, success: false)]), [
      (operation: 'a', calls: 1, failed: 1, totalDurationUs: 7),
    ]);
    expect(summarize([]), isEmpty);
  });
}
