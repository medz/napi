import 'dart:convert';
import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

const _packageName = 'napi_default_uri_consumer';
const _selections = ExternalLibrary([
  ExternalClass('Point'),
  ExternalFunction('named'),
  ExternalFunction('constructed'),
]);

void main() {
  late Directory root;
  late File packages;
  late File bindings;
  late File facade;
  late File toolFacade;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('napi package default URI ');
    root = Directory(await root.resolveSymbolicLinks());
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/lib').create();
    await Directory('${root.path}/tool').create();
    await Directory('${root.path}/.dart_tool').create();
    await File('${root.path}/pubspec.yaml').writeAsString('''
name: $_packageName
environment:
  sdk: ^3.13.5
''');
    final original = File('.dart_tool/package_config.json').absolute;
    final config =
        jsonDecode(await original.readAsString()) as Map<String, dynamic>;
    final entries = config['packages'] as List<dynamic>;
    for (final entry in entries.cast<Map<String, dynamic>>()) {
      entry['rootUri'] = original.uri
          .resolve(entry['rootUri'] as String)
          .toString();
    }
    entries.add({
      'name': _packageName,
      'rootUri': '${root.uri}',
      'packageUri': 'lib/',
      'languageVersion': '3.13',
    });
    packages = File('${root.path}/.dart_tool/package_config.json');
    await packages.writeAsString(jsonEncode(config));
    bindings = File('${root.path}/lib/bindings.dart');
    await bindings.writeAsString('''
import 'package:napi/napi.dart';
@NAPI() class Point {
  final int value;
  const Point(this.value);
  const Point._(this.value);
}
const publicOrigin = Point._(7);
const _constructed = Point(11);
@NAPI() Point named([Point value = publicOrigin]) => value;
@NAPI() Point constructed([Point value = _constructed]) => value;
''');
    facade = File('${root.path}/lib/entry.dart');
    await facade.writeAsString("export 'bindings.dart';\n");
    toolFacade = File('${root.path}/tool/entry.dart');
    await toolFacade.writeAsString("export '../lib/bindings.dart';\n");
  });

  test(
    'file entrypoints retain loaded library identities for const defaults',
    () async {
      final packageBindings = Uri.parse('package:$_packageName/bindings.dart');
      for (final (input, importUri, canonical) in [
        (bindings, packageBindings, packageBindings),
        (
          facade,
          Uri.parse('package:$_packageName/entry.dart'),
          packageBindings,
        ),
        (toolFacade, toolFacade.uri, bindings.uri),
      ]) {
        for (final native in [false, true]) {
          for (final external in [false, true]) {
            final module =
                await (external
                        ? ExternalFrontend(
                            _selections,
                            packagesPath: packages.path,
                            native: native,
                          )
                        : AnnotationFrontend(
                            packagesPath: packages.path,
                            native: native,
                          ))
                    .read(input.absolute.uri);
            expect(module.source, input.absolute.uri);
            expect(module.importUri, importUri);
            final defaults = {
              for (final function in module.functions)
                function.exportName: function.parameters.single.defaultValue,
            };
            expect(
              (defaults['named'] as NamedObjectDefault).variable.library,
              canonical,
            );
            expect(
              (defaults['constructed'] as ObjectDefault).constructor.library,
              canonical,
            );
            final generated = native
                ? emitNativeDart(validateNative(module))
                : emitDart(lower(validate(module)));
            final importPattern = RegExp("import ['\"]([^'\"]+)['\"]");
            final identities = importPattern
                .allMatches(generated)
                .map((match) => match.group(1)!)
                .where(
                  (uri) =>
                      uri == packageBindings.toString() ||
                      uri == bindings.uri.toString(),
                )
                .toSet();
            expect(identities, {canonical.toString()});
          }
        }
      }
    },
  );

  test(
    'mixed file and package identities fail before generating bindings',
    () async {
      final input = File('${root.path}/tool/mixed.dart');
      await input.writeAsString('''
import 'package:napi/napi.dart';
import '../lib/bindings.dart' as local;
import 'package:$_packageName/bindings.dart' as packaged;
export '../lib/bindings.dart';
@NAPI() bool mixed(local.Point left, packaged.Point right) => identical(left, right);
''');
      await expectLater(
        AnnotationFrontend(packagesPath: packages.path).read(input.uri),
        throwsA(
          isA<BindingDiagnostic>()
              .having((error) => error.code, 'code', 'NAPI_INPUT')
              .having(
                (error) => error.message,
                'file URI',
                contains(bindings.uri.toString()),
              )
              .having(
                (error) => error.message,
                'package URI',
                contains('package:$_packageName/bindings.dart'),
              ),
        ),
      );
    },
  );

  test(
    'fresh package executes private and public constructor defaults',
    () async {
      for (final (name, input) in [('lib', bindings), ('tool', toolFacade)]) {
        await buildLibrary(
          library: input.absolute.uri,
          output: Directory('${root.path}/output_$name'),
          packagesPath: packages.path,
        );
      }
      await File('${root.path}/check.mjs').writeAsString('''
import assert from 'node:assert/strict';
import * as lib from './output_lib/module.wasm';
import * as tool from './output_tool/module.wasm';
for (const api of [lib, tool]) {
const named = api.named();
const constructed = api.constructed();
assert.equal(named.value, 7);
assert.equal(constructed.value, 11);
assert.equal(api.named(undefined), named);
assert.equal(api.constructed(undefined), constructed);
assert.equal(api.named(named), named);
assert.equal(api.constructed(constructed), constructed);
}
''');
      final result = await Process.run('node', [
        'check.mjs',
      ], workingDirectory: root.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
