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

  for (final group in ['all', 'records', 'batch']) {
    test('$group imports and measures its expected cases', () async {
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
export const echoPacket = value => copy({name: value.name, payload: new Uint8Array(new Uint8Array(value.payload))});
export const echoPacketPayload = value => new Uint8Array(new Uint8Array(value));
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
        final api = File('${work.path}/api.mjs');
        final collections = File('${work.path}/collections.mjs');
        final dartJs = File('${work.path}/dart-js.mjs');
        if (group == 'all') {
          await api.writeAsString('''
export const add = (a, b) => {
  if (typeof a !== 'number' || typeof b !== 'number') throw new TypeError('Expected number');
  return a + b;
};
export const identityInt = value => value;
export const echoString = value => value, stringLength = value => value.length;
export const echoBytes = value => new Uint8Array(new Uint8Array(value));
export const sumBytes = value => value.reduce((sum, byte) => sum + byte, 0);
export const addAsync = async (a, b) => add(a, b);
export const echoStringAsync = async value => echoString(value);
export const echoBytesAsync = async value => echoBytes(value);
export const fail = () => { throw new Error('benchmark failure'); };
export const failAsync = async () => fail();
''');
          await collections.writeAsString('''
export const echoList = value => [...value];
export const sumList = value => value.reduce((sum, item) => sum + item, 0);
export const echoMap = value => Object.assign(Object.create(null), value);
export const echoListAsync = async value => echoList(value);
export const echoMapAsync = async value => echoMap(value);
''');
          await dartJs.writeAsString('''
import * as api from './api.mjs';
globalThis.dartBaseline = api;
''');
        }
        final arguments = [
          'benchmark/measure.mjs',
          '--group',
          group,
          '--records',
          records.uri.toString(),
          '--batch',
          group != 'records' ? batch.uri.toString() : 'file:///missing-batch',
          '--wasm',
          group == 'all' ? api.uri.toString() : 'file:///missing-api',
          '--collections',
          group == 'all'
              ? collections.uri.toString()
              : 'file:///missing-collections',
          '--dart-js',
          group == 'all' ? dartJs.uri.toString() : 'file:///missing-dart-js',
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
        expect(
          report['ownership_preflight'],
          startsWith(group == 'all' ? 'scalar/bytes:' : '$group:'),
        );
        expect(report.containsKey('dart_js_errors'), group == 'all');
        final rows = report['cases'] as List;
        expect(rows.length, {'all': 116, 'records': 24, 'batch': 37}[group]);
        final byteRows = rows.cast<Map>().where(
          (row) => (row['case'] as String).startsWith('record/bytes/'),
        );
        expect(byteRows.length, group == 'batch' ? 0 : 18);
        for (final row in byteRows) {
          expect(
            row['case'],
            matches(
              r'^record/bytes/(echo|top-level)/(Uint8Array|Buffer|subarray)/(32|1024|65536)$',
            ),
          );
          final input = row['input'] as Map;
          final record = (row['case'] as String).startsWith(
            'record/bytes/echo/',
          );
          expect(input['ownership_copies'], 2);
          expect(input['method'], record ? 'echoPacket' : 'echoPacketPayload');
          expect(input['fields'], record ? 2 : 0);
          expect(input['name_utf16_code_units'], record ? 5 : 0);
          if (input['kind'] == 'subarray') expect(input['byte_offset'], 8);
          expect((row['ns_per_call'] as Map).keys, ['wasm', 'javascript']);
        }
        for (final row in rows.cast<Map>()) {
          if (group == 'records') {
            expect(
              row['case'],
              matches(r'^(async/)?record/echo/(1|4|16)$|^record/bytes/'),
            );
          } else if (group == 'batch') {
            expect(row['case'], startsWith('batch/'));
          }
          final samples = row['ns_per_call'] as Map;
          if (group != 'all') expect(samples.keys, ['wasm', 'javascript']);
          expect(samples.keys, containsAll(['wasm', 'javascript']));
          for (final sample in samples.values.cast<Map>()) {
            expect(sample['samples'], hasLength(1));
          }
          if ((row['case'] as String).contains('single-call-loop')) {
            expect((row['input'] as Map)['outer_array_validation'], isFalse);
          }
        }
        if (group == 'records') {
          // Payload and name consumption must remain observable; the ordinary
          // record stand-ins all return id/id0 = 42 and byte inputs start at 0.
          var expectedSink = 0;
          for (final row in rows.cast<Map>()) {
            final input = row['input'] as Map;
            final value = input.containsKey('bytes')
                ? (input['bytes'] as int) +
                      (input['name_utf16_code_units'] as int)
                : 42;
            expectedSink +=
                value *
                ((row['iterations'] as int) + (row['warmup'] as int)) *
                2;
          }
          expect(report['sink'], expectedSink);
          for (final (source, route) in [
            (
              recordSource.replaceFirst(
                'new Uint8Array(new Uint8Array(value.payload))',
                'value.payload',
              ),
              'echo',
            ),
            (
              recordSource.replaceFirst(
                'new Uint8Array(new Uint8Array(value));',
                'value;',
              ),
              'top-level',
            ),
          ]) {
            await records.writeAsString(source);
            final rejected = await Process.run('node', arguments);
            expect(rejected.exitCode, isNot(0));
            expect(rejected.stderr, contains('AssertionError'));
            expect(
              rejected.stderr,
              contains('record/bytes/$route/Uint8Array/32'),
            );
            expect(rejected.stdout, isEmpty);
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
