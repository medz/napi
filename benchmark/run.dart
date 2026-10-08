import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  var iterations = 20000;
  var warmup = 2000;
  var runs = 3;
  var buildRuns = 1;
  var node = 'node';
  String? output;
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '--help') {
      stdout.writeln('''Usage: dart run benchmark/run.dart [options]
  --node <path>          Node executable (default: node)
  --iterations <count>   Small-input calls per sample (default: 20000)
  --warmup <count>       Small-input warmup calls (default: 2000)
  --runs <count>         Runtime and cold-import samples (default: 3)
  --build-runs <count>   Builds per fixture (default: 1)
  --out <file>           Save JSON report (also printed to stdout)
Large-input and error cases use fewer calls; see each report row.
Run from the napi repository root. No timing assertions are made.''');
      return;
    }
    if (i + 1 == arguments.length) {
      throw FormatException('Missing value for ${arguments[i]}');
    }
    final option = arguments[i++];
    final value = arguments[i];
    switch (option) {
      case '--node':
        node = value;
      case '--out':
        output = value;
      case '--iterations':
        iterations = int.parse(value);
      case '--warmup':
        warmup = int.parse(value);
      case '--runs':
        runs = int.parse(value);
      case '--build-runs':
        buildRuns = int.parse(value);
      default:
        throw FormatException('Unknown option $option');
    }
  }
  if ([iterations, warmup, runs, buildRuns].any((v) => v < 1)) {
    throw const FormatException('Counts must be positive integers.');
  }
  if (!File('pubspec.yaml').existsSync() ||
      !File('benchmark/fixtures/api.dart').existsSync()) {
    throw StateError('Run from the napi repository root.');
  }
  final nodeVersion = await _run(node, ['--version']);
  final dartVersion = await _run(Platform.resolvedExecutable, ['--version']);
  final npmVersion = await _run('npm', ['--version']);
  final report = <String, Object?>{
    'schema': 1,
    'napi_version': File('pubspec.yaml')
        .readAsLinesSync()
        .firstWhere((line) => line.startsWith('version:'))
        .substring('version:'.length)
        .trim(),
    'recorded_at': DateTime.now().toUtc().toIso8601String(),
    'environment': {
      'dart': '${dartVersion.stdout}${dartVersion.stderr}'.trim(),
      'node': '${nodeVersion.stdout}'.trim(),
      'npm': '${npmVersion.stdout}'.trim(),
      'os': Platform.operatingSystemVersion,
      'dart_executable': Platform.resolvedExecutable,
      'node_executable': node,
    },
    'configuration': {
      'iterations': iterations,
      'warmup': warmup,
      'runs': runs,
      'build_runs': buildRuns,
      'dart_js_optimization': '-O2',
      'cold_import': 'fresh Node process, filesystem caches uncontrolled',
      'build_cache':
          'no result reuse; existing SDK/pub/filesystem caches uncontrolled',
    },
  };
  final work = await Directory.systemTemp.createTemp('napi-benchmark-');
  try {
    final builds = <Map<String, Object?>>[];
    for (final fixture in ['minimal', 'minimal_async', 'api', 'collections']) {
      final directory = Directory('${work.path}/$fixture');
      final times = <double>[];
      for (var run = 0; run < buildRuns; run++) {
        stderr.writeln('Building $fixture (${run + 1}/$buildRuns)...');
        final timer = Stopwatch()..start();
        await _run(Platform.resolvedExecutable, [
          'run',
          'napi:build',
          'benchmark/fixtures/$fixture.dart',
          '--name',
          '@napi/benchmark-${fixture.replaceAll('_', '-')}',
          '--out',
          directory.path,
        ]);
        times.add(timer.elapsedMicroseconds / 1000);
      }
      final sizes = <String, int>{};
      for (final name in [
        'module.wasm',
        'module.imports.mjs',
        'index.d.ts',
        'module.d.wasm.ts',
        'package.json',
      ]) {
        sizes[name] = await File('${directory.path}/$name').length();
      }
      final host = await File('${directory.path}/module.imports.mjs')
          .readAsString();
      final collectionHelpers = RegExp(
        r'^napi\.(\w+)\s*=',
        multiLine: true,
      ).allMatches(host).map((match) => match.group(1)!).toList();
      if (fixture != 'collections' && collectionHelpers.isNotEmpty) {
        throw StateError('Unexpected collection helpers in $fixture');
      }
      final packed = await _run(
        'npm',
        ['pack', '--ignore-scripts', '--json', '--pack-destination', work.path],
        directory: directory.path,
        environment: {'npm_config_cache': '${work.path}/npm-cache'},
      );
      final pack = (jsonDecode(packed.stdout as String) as List).single as Map;
      final coldImport = <double>[];
      final firstCall = <double>[];
      for (var run = 0; run < runs; run++) {
        final cold = await _run(node, [
          'benchmark/measure.mjs',
          '--cold',
          File('${directory.path}/module.wasm').uri.toString(),
          fixture == 'api' ? 'add' : 'answer',
        ]);
        final data = jsonDecode(cold.stdout as String) as Map;
        coldImport.add((data['import_ms'] as num).toDouble());
        firstCall.add((data['first_call_ms'] as num).toDouble());
      }
      builds.add({
        'fixture': fixture,
        'build_ms': _summary(times),
        'files_bytes': sizes,
        'collection_host_helpers': collectionHelpers,
        'npm_tgz_bytes': pack['size'],
        'npm_unpacked_bytes': pack['unpackedSize'],
        'cold_import_ms': _summary(coldImport),
        'first_call_ms': _summary(firstCall),
      });
    }
    report['wasm_builds'] = builds;
    stderr.writeln('Compiling the Dart JavaScript comparison (-O2)...');
    final jsFile = File('${work.path}/dart.mjs');
    final jsTimes = <double>[];
    for (var run = 0; run < buildRuns; run++) {
      final timer = Stopwatch()..start();
      await _run(Platform.resolvedExecutable, [
        'compile',
        'js',
        '-O2',
        '--no-source-maps',
        'benchmark/fixtures/javascript.dart',
        '-o',
        jsFile.path,
      ]);
      jsTimes.add(timer.elapsedMicroseconds / 1000);
    }
    report['dart_js_build'] = {
      'build_ms': _summary(jsTimes),
      'file_bytes': await jsFile.length(),
      'gzip_bytes': gzip.encode(await jsFile.readAsBytes()).length,
    };
    stderr.writeln('Measuring warmed calls, conversions, and errors...');
    final measured = await _run(node, [
      '--expose-gc',
      'benchmark/measure.mjs',
      '--wasm',
      File('${work.path}/api/module.wasm').uri.toString(),
      '--dart-js',
      jsFile.uri.toString(),
      '--collections',
      File('${work.path}/collections/module.wasm').uri.toString(),
      '--iterations',
      '$iterations',
      '--warmup',
      '$warmup',
      '--runs',
      '$runs',
    ]);
    report['runtime'] = jsonDecode(measured.stdout as String);
    final encoded = '${const JsonEncoder.withIndent('  ').convert(report)}\n';
    if (output != null) {
      final file = File(output);
      await file.parent.create(recursive: true);
      await file.writeAsString(encoded);
      stderr.writeln('Saved ${file.path}');
    }
    stdout.write(encoded);
  } finally {
    await work.delete(recursive: true);
  }
}

Future<ProcessResult> _run(
  String executable,
  List<String> arguments, {
  String? directory,
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: directory,
    environment: environment,
  );
  if (result.exitCode != 0) {
    throw StateError(
      '$executable ${arguments.join(' ')} failed (${result.exitCode}):\n${result.stdout}${result.stderr}',
    );
  }
  return result;
}

Map<String, Object> _summary(List<double> samples) {
  final sorted = [...samples]..sort();
  final mid = sorted.length ~/ 2;
  final median = sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
  return {
    'samples': samples,
    'median': median,
    'min': sorted.first,
    'max': sorted.last,
    'spread_percent': median == 0
        ? 0
        : 100 * (sorted.last - sorted.first) / median,
  };
}
