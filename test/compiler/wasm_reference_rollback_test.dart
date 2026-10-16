import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/js/references.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/linker/dart_module_linker.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

void main() {
  test(
    'failed structural outputs roll back only their first reference claims',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-reference-rollback-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final packages = File('.dart_tool/package_config.json').absolute.path;
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() class Base { Base(); }
@NAPI() class Child extends Base { Child(); }
Child? _saved;
@NAPI() (Base, int) failFresh() {
  final value = Child();
  _saved = value;
  return (value, 9007199254740992);
}
@NAPI() Base expose() => _saved = Child();
@NAPI() List<Base> exposeList() {
  final value = Child();
  _saved = value;
  return [value];
}
@NAPI() (Base, int) failSaved() => (_saved!, 9007199254740992);
@NAPI() Child savedChild() => _saved!;
@NAPI() Base savedBase() => _saved!;
''');
      final plan = lower(
        validate(
          await AnnotationFrontend(packagesPath: packages).read(input.uri),
        ),
      );
      final entry = await File('${directory.path}/entry.dart')
          .writeAsString(emitDart(plan));
      final compiled = await DartSdkAdapter().compile(
        sourcePath: entry.path,
        outputPath: '${directory.path}/raw.wasm',
        packagesPath: packages,
      );
      final linked = linkDartModule(
        rawWasmBytes: await File(compiled.wasmPath).readAsBytes(),
        rawMjsText: await File(compiled.jsPath).readAsString(),
        hostSpecifier: './host.mjs',
        coreSpecifier: './core.wasm',
        additionalImports: {'napi': './boundary.mjs'},
      );
      await File('${directory.path}/core.wasm').writeAsBytes(linked.wasmBytes);
      await File('${directory.path}/module.wasm').writeAsBytes(
        buildPublicWasmFacade(
          hostSpecifier: './calls.mjs',
          exportNames: [
            for (final function in plan.functions)
              if (function.representation ==
                  ExportRepresentation.callableGlobal)
                function.binding.exportName,
            ...plan.classes.map((binding) => binding.binding.exportName),
          ],
          nativeFunctions: {
            for (final function in plan.functions)
              if (function.representation ==
                  ExportRepresentation.nativeFunction)
                function.binding.exportName: function.inputs.length,
          },
        ),
      );
      await File('${directory.path}/host.mjs')
          .writeAsString(linked.hostJavaScript);
      await File('${directory.path}/boundary.mjs')
          .writeAsString(emitBoundary(plan));
      await File('${directory.path}/calls.mjs')
          .writeAsString(emitArgumentCalls(plan));
      await File('${directory.path}/references.mjs')
          .writeAsString(emitReferences());
      await File('${directory.path}/test.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module.wasm';
assert.throws(() => api.failFresh(), error => error instanceof RangeError &&
  error.message.startsWith('failFresh result.$2: '));
const child = api.savedChild();
assert(child instanceof api.Child, 'unexposed Base claim must not poison Child');
assert.throws(() => api.savedBase(), TypeError);
const weak = (() => {
  const exposed = api.expose();
  assert(exposed instanceof api.Base);
  assert.throws(() => api.failSaved(), RangeError);
  assert.equal(api.savedBase(), exposed, 'failure preserves an already exposed claim');
  assert.throws(() => api.savedChild(), TypeError);
  return new WeakRef(exposed);
})();
let collected = false;
for (let i = 0; i < 80; i++) {
  await new Promise(resolve => setImmediate(resolve));
  global.gc();
  if (weak.deref() === undefined) { collected = true; break; }
}
assert(collected);
assert.throws(() => api.failSaved(), RangeError);
assert.throws(() => api.savedChild(), TypeError,
  'a previously exposed brand survives a dead wrapper and failed re-adoption');
assert(api.savedBase() instanceof api.Base);
assert.throws(() => api.failFresh(), RangeError);
assert(api.savedChild() instanceof api.Child, 'later fresh failure is independently rolled back');
for (const [prototype, key] of [[Array.prototype, '0'], [Object.prototype, '0'], [Object.prototype, 'pending']]) {
  const previous = Object.getOwnPropertyDescriptor(prototype, key);
  let setters = 0;
  let failedOutput;
  let unexpected;
  let recovered;
  let successfulOutput;
  Object.defineProperty(prototype, key, {
    configurable: true,
    get() { setters++; throw new Error('inherited getter invoked by reference collector'); },
    set() { setters++; throw new Error('inherited setter invoked by reference collector'); },
  });
  try {
    try { api.failFresh(); } catch (error) { failedOutput = error; }
    recovered = api.savedChild();
    successfulOutput = api.exposeList();
  } catch (error) {
    unexpected = error;
  } finally {
    if (previous) Object.defineProperty(prototype, key, previous);
    else delete prototype[key];
  }
  assert.equal(setters, 0, 'fresh claims and rollback must not invoke numeric prototype setters');
  assert.equal(unexpected, undefined);
  assert(failedOutput instanceof RangeError);
  assert(recovered instanceof api.Child);
  assert(successfulOutput[0] instanceof api.Base);
  assert.equal(api.savedBase(), successfulOutput[0]);
}
''');
      final execution = await Process.run('node', [
        '--expose-gc',
        'test.mjs',
      ], workingDirectory: directory.path);
      expect(
        execution.exitCode,
        0,
        reason: '${execution.stdout}${execution.stderr}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
