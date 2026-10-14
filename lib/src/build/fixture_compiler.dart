import 'dart:convert';
import 'dart:io';

import '../compiler/emit/dart/emitter.dart';
import '../compiler/emit/js/emitter.dart';
import '../compiler/emit/typescript/emitter.dart';
import '../compiler/front_end/fixture_frontend.dart';
import '../compiler/lowering/lower.dart';

/// A deliberately small executable compiler fixture, not npm packaging policy.
///
/// Outputs always go in a newly-created directory owned by this invocation.
/// Existing output directories and author source files are never cleared.
final class FixtureCompiler {
  Future<Directory> build({
    required String projectRoot,
    required String sourcePath,
    required Iterable<String> functionNames,
  }) async {
    final root = Directory(projectRoot).absolute;
    final source = File(sourcePath).absolute;
    final module = await FixtureFrontend().resolve(
      path: source.path,
      functionNames: functionNames,
    );
    final plan = lowerModule(module);
    final parent = Directory('${root.path}/.dart_tool/napi-fixtures');
    await parent.create(recursive: true);
    final output = await parent.createTemp('module-');
    await File('${output.path}/.napi-fixture-owned')
        .writeAsString('napi fixture v1\n');
    await File('${output.path}/bridge.dart').writeAsString(emitDart(plan));
    await File('${output.path}/index.mjs').writeAsString(emitJavaScript(plan));
    await File('${output.path}/index.d.mts')
        .writeAsString(emitTypeScript(plan));
    for (final name in ['bootstrap.mjs', 'errors.mjs']) {
      await File('${root.path}/assets/runtime/$name')
          .copy('${output.path}/$name');
    }
    await File('${output.path}/package.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'name': '@napi/foundation-fixture',
        'version': '0.0.0',
        'private': true,
        'type': 'module',
        'exports': {
          '.': {'types': './index.d.mts', 'import': './index.mjs'},
        },
        'files': ['*.mjs', '*.wasm', '*.d.mts'],
      }),
    );
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'wasm',
      '--no-source-maps',
      '${output.path}/bridge.dart',
      '-o',
      '${output.path}/module.wasm',
    ], workingDirectory: root.path);
    if (result.exitCode != 0) {
      throw ProcessException(
        Platform.resolvedExecutable,
        ['compile', 'wasm'],
        '${result.stdout}\n${result.stderr}',
        result.exitCode,
      );
    }
    return output;
  }
}
