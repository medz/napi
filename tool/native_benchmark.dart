import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';

const _calls = 200000;
const _warmupCalls = 20000;
const _rounds = 3;

/// Bounded, process-isolated measurements of the same Dart scalar declaration.
/// Requires an existing runtime bundle and Node 24/26; installs nothing.
Future<void> main(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError(
      'Usage: dart run tool/native_benchmark.dart '
      '<runtime-bundle> <node24-executable> <node26-executable>',
    );
  }
  final runtimes = <String, String>{};
  for (final (index, major) in [24, 26].indexed) {
    final executable = args[index + 1];
    final result = await Process.run(executable, ['--version']);
    final version = result.stdout.toString().trim();
    if (result.exitCode != 0 || !version.startsWith('v$major.')) {
      throw ArgumentError('Expected Node $major at $executable: $version');
    }
    runtimes[executable] = version;
  }
  final temporary = await Directory('/private/tmp')
      .createTemp('napi-native-benchmark-');
  final root = Directory(temporary.resolveSymbolicLinksSync());
  stdout.writeln('Benchmark artifacts and results: ${root.path}');
  final source = File('${root.path}/business.dart');
  await source.writeAsString('''
import 'package:napi/napi.dart';
@NAPI()
int add(int left, int right) => left + right;
''');
  final artifacts = <String, BuiltModule>{};
  final sizes = <String, Map<String, int>>{};
  for (final target in BuildTarget.values) {
    final module = await buildLibrary(
      library: source.uri,
      output: Directory('${root.path}/${target.name}'),
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      target: target,
      nativeRuntime: target == BuildTarget.native ? Directory(args[0]) : null,
    );
    artifacts[target.name] = module;
    final files = <String, int>{};
    await for (final entity in module.directory.list(recursive: true)) {
      if (entity is File) {
        files[entity.path.substring(module.directory.path.length + 1)] =
            await entity.length();
      }
    }
    sizes[target.name] = files;
  }
  final probe = File('${root.path}/measure.mjs');
  await probe.writeAsString(_probe);
  final results = <String, Object?>{
    'scope':
        'Same synchronous Dart add(int, int); observed boundary costs only.',
    'limitations': [
      'Non-frozen local run; competing load and thermal state are uncontrolled.',
      'Cold imports use fresh Node processes; filesystem caches are uncontrolled.',
      'RSS is process resident memory after explicit GC, not a peak or heap size.',
      'Warm time includes the JavaScript loop and strict scalar conversions.',
      'No claim of a performance advantage or statistical significance.',
    ],
    'timestampUtc': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
    'processorCount': Platform.numberOfProcessors,
    'dartVersion': Platform.version,
    'artifacts': root.path,
    'nativeRuntime': jsonDecode(
      await File('${artifacts['native']!.directory.path}/runtime.json')
          .readAsString(),
    ),
    'callsPerSample': _calls,
    'warmupCallsPerSample': _warmupCalls,
    'rounds': _rounds,
    'targets': {'A': 'wasm', 'B': 'native'},
    'artifactBytes': {
      for (final entry in sizes.entries)
        entry.key: {
          'total': entry.value.values.fold(0, (sum, size) => sum + size),
          'files': entry.value,
        },
    },
  };
  final measured = <String, Object?>{};
  results['nodes'] = measured;
  final report = File('${root.path}/results.json');
  Future<void> save() => report.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(results)}\n',
  );
  await save();
  for (final runtime in runtimes.entries) {
    Future<Map<String, Object?>> sample(String target) =>
        _measure(runtime.key, probe, artifacts[target]!.entrypoint.uri);
    final same = <String, Object?>{};
    for (final target in artifacts.keys) {
      final left = await sample(target);
      final right = await sample(target);
      same[target] = {
        'samples': [left, right],
        'warmNsDifferencePercent': _difference(
          left['warmNsPerCall']! as num,
          right['warmNsPerCall']! as num,
        ),
        'coldImportDifferencePercent': _difference(
          left['coldImportMs']! as num,
          right['coldImportMs']! as num,
        ),
      };
      stdout.writeln('${runtime.value}: $target A/A complete');
    }
    final ordered = <Map<String, Object?>>[];
    final samples = {
      'wasm': <Map<String, Object?>>[],
      'native': <Map<String, Object?>>[],
    };
    final current = <String, Object?>{
      'executable': runtime.key,
      'sameTargetNoise': same,
      'balancedRuns': ordered,
    };
    measured[runtime.value] = current;
    for (var round = 1; round <= _rounds; round++) {
      for (final order in const [
        ['wasm', 'native'],
        ['native', 'wasm'],
      ]) {
        final pair = <String, Object?>{
          'round': round,
          'order': order,
          'samples': <String, Object?>{},
        };
        final pairSamples = pair['samples']! as Map<String, Object?>;
        for (final target in order) {
          final result = await sample(target);
          pairSamples[target] = result;
          samples[target]!.add(result);
        }
        ordered.add(pair);
        await save();
      }
      stdout.writeln('${runtime.value}: balanced AB/BA round $round complete');
    }
    current['summary'] = {
      for (final entry in samples.entries)
        entry.key: {
          'sampleCount': entry.value.length,
          for (final metric in const [
            'warmNsPerCall',
            'coldImportMs',
            'rssImportDeltaBytes',
            'rssSteadyBytes',
            'rssSteadyDeltaBytes',
          ])
            metric: _summary([
              for (final sample in entry.value) sample[metric]! as num,
            ]),
        },
    };
    await save();
  }
  stdout.writeln('Saved ${report.path}');
}

Future<Map<String, Object?>> _measure(
  String node,
  File probe,
  Uri entrypoint,
) async {
  final result = await Process.run(node, [
    '--expose-gc',
    probe.path,
    entrypoint.toString(),
  ]);
  if (result.exitCode != 0) {
    throw StateError(
      'Benchmark child failed (${result.exitCode}): '
      '${result.stdout}${result.stderr}',
    );
  }
  final value = (jsonDecode(result.stdout.toString()) as Map)
      .cast<String, Object?>();
  final warnings = result.stderr.toString().trim();
  if (warnings.isNotEmpty) value['stderr'] = warnings;
  return value;
}

double _difference(num left, num right) =>
    (left - right).abs() * 200 / (left + right);

Map<String, num> _summary(List<num> values) {
  values.sort();
  final middle = values.length ~/ 2;
  return {
    'min': values.first,
    'median': values.length.isOdd
        ? values[middle]
        : (values[middle - 1] + values[middle]) / 2,
    'max': values.last,
  };
}

const _probe =
    '''
import assert from 'node:assert/strict';
global.gc();
const baselineRss = process.memoryUsage().rss;
const start = process.hrtime.bigint();
const {add} = await import(process.argv[2]);
const coldImportMs = Number(process.hrtime.bigint() - start) / 1e6;
global.gc();
const importedRss = process.memoryUsage().rss;
let warmupChecksum = 0;
for (let i = 0; i < $_warmupCalls; i++) warmupChecksum += add(i & 1023, 1);
assert(warmupChecksum > 0);
global.gc();
let checksum = 0;
const warm = process.hrtime.bigint();
for (let i = 0; i < $_calls; i++) checksum += add(i & 1023, 1);
const warmNsPerCall = Number(process.hrtime.bigint() - warm) / $_calls;
const remainder = $_calls % 1024;
assert.equal(checksum, Math.floor($_calls / 1024) * 524800 + remainder * (remainder + 1) / 2);
global.gc();
const steadyRss = process.memoryUsage().rss;
console.log(JSON.stringify({
  coldImportMs, warmNsPerCall, checksum,
  rssBaselineBytes: baselineRss,
  rssImportedBytes: importedRss,
  rssImportDeltaBytes: importedRss - baselineRss,
  rssSteadyBytes: steadyRss,
  rssSteadyDeltaBytes: steadyRss - baselineRss,
}));
''';
