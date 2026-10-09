import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../benchmark/run.dart' as benchmark;

void main() {
  test('unknown group is rejected before running external tools', () async {
    await expectLater(
      benchmark.main(['--group', 'unknown', '--node', '/missing-node']),
      throwsA(isA<FormatException>()),
    );
  });

  for (final group in ['records', 'batch']) {
    test('$group only imports and measures the selected family', () async {
      final work = await Directory.systemTemp.createTemp('napi-group-test-');
      try {
        // Stand-ins exercise group selection and preflight without compiling
        // Wasm or duplicating the bridge's conversion/validation tests.
        final records = File('${work.path}/records.mjs');
        const recordSource = '''
const copy = value => Object.assign(Object.create(null), value);
export const echoOne = copy, echoFour = copy, echoSixteen = copy;
export const echoOneAsync = async value => copy(value);
export const echoFourAsync = echoOneAsync, echoSixteenAsync = echoOneAsync;
''';
        await records.writeAsString(recordSource);
        final batch = File('${work.path}/batch.mjs');
        await batch.writeAsString('''
const echoFour = value => Object.assign(Object.create(null), value);
export const echoOneList = values => values.map(echoFour);
export const echoFourList = echoOneList, echoSixteenList = echoOneList;
export const echoFourListAsync = async values => echoFourList(values);
export const normalizeOne = value => {
  const result = echoFour(value);
  result.name = result.name.trim();
  return result;
};
export const normalizeFourList = values => values.map(normalizeOne);
export const sumOne = value => value.id;
export const sumFourList = values => values.reduce((sum, value) => sum + value.id, 0);
''');
        final arguments = [
          'benchmark/measure.mjs',
          '--group',
          group,
          '--records',
          records.uri.toString(),
          '--batch',
          group == 'batch' ? batch.uri.toString() : 'file:///missing-batch',
          '--wasm',
          'file:///missing-api',
          '--collections',
          'file:///missing-collections',
          '--dart-js',
          'file:///missing-dart-js',
          '--iterations',
          '1',
          '--warmup',
          '1',
          '--runs',
          '1',
        ];
        final result = await Process.run('node', arguments);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        final report = jsonDecode(result.stdout as String) as Map;
        expect(report['group'], group);
        expect(report['ownership_preflight'], startsWith('$group:'));
        expect(report.containsKey('dart_js_errors'), isFalse);
        final rows = report['cases'] as List;
        expect(rows.length, group == 'records' ? 6 : 37);
        for (final row in rows.cast<Map>()) {
          expect(
            row['case'],
            group == 'records'
                ? matches(r'^(async/)?record/echo/(1|4|16)$')
                : startsWith('batch/'),
          );
          final samples = row['ns_per_call'] as Map;
          expect(samples.keys, ['wasm', 'javascript']);
          for (final sample in samples.values.cast<Map>()) {
            expect(sample['samples'], hasLength(1));
          }
          if ((row['case'] as String).contains('single-call-loop')) {
            expect((row['input'] as Map)['outer_array_validation'], isFalse);
          }
        }
        if (group == 'batch') {
          // Keep batch APIs correct while breaking the separate scalar module
          // used by single-call-loop-echo; preflight must reject it.
          await records.writeAsString(
            recordSource.replaceFirst(
              'echoFour = copy',
              'echoFour = value => Object.assign(copy(value), { id: -1 })',
            ),
          );
          final rejected = await Process.run('node', arguments);
          expect(rejected.exitCode, isNot(0));
          expect(rejected.stderr, contains('AssertionError'));
          expect(rejected.stdout, isEmpty);
        }
      } finally {
        await work.delete(recursive: true);
      }
    });
  }
}
