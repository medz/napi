import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-cancellation-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<BindingModule> read(String source) async {
    final file = File('${directory.path}/entry.dart');
    await file.writeAsString("import 'package:napi/napi.dart';\n$source");
    return AnnotationFrontend(packagesPath: packages).read(file.uri);
  }

  test(
    'explicit signals share direct input mappings across both backends',
    () async {
      final module = await read('''
typedef Stop = AbortSignal;
@NAPI() bool check(Stop signal) => signal.aborted;
@NAPI() Future<int> work({required Stop signal}) async => 1;
@NAPI() Stream<int> values(Stop signal) async* { yield 1; }
@NAPI() bool optional([Stop? signal]) => signal?.aborted ?? false;
@NAPI() bool named({Stop? signal, Stop? second}) => signal == second;
@NAPI() class Saved {
  Saved(Stop signal);
  set signal(Stop value) {}
  bool observe(Stop? signal) => signal?.aborted ?? false;
}
''');
      final wasm = lower(validate(module));
      final native = validateNative(module);
      for (final inputs in [
        wasm.functions.map((call) => call.inputs.first).toList(),
        native.functions.map((call) => call.inputs.first).toList(),
      ]) {
        expect(inputs.every((input) => input is AbortSignalConversion), isTrue);
        expect(inputs.first.dartType, 'napi.AbortSignal');
        expect(inputs.first.typescriptType, 'globalThis.AbortSignal');
        expect(inputs[3].dartType, 'napi.AbortSignal?');
        expect(inputs[3].typescriptType, 'globalThis.AbortSignal | null');
      }
      expect(
        wasm.functions.every(
          (call) => call.representation == ExportRepresentation.callableGlobal,
        ),
        isTrue,
      );
      for (final declarations in [
        emitDeclarations(wasm),
        emitNativeDeclarations(native),
      ]) {
        expect(declarations, contains('(signal: globalThis.AbortSignal)'));
        expect(declarations, contains('signal: globalThis.AbortSignal'));
        expect(
          declarations,
          contains('(signal?: globalThis.AbortSignal | null)'),
        );
        expect(
          declarations,
          contains('constructor(signal: globalThis.AbortSignal)'),
        );
        expect(
          declarations,
          contains('set signal(value: globalThis.AbortSignal)'),
        );
        expect(
          declarations,
          contains(
            'globalThis.AsyncIterableIterator<number, undefined, undefined>',
          ),
        );
      }
    },
  );

  test(
    'type identity, not spelling or parameter names, selects cancellation',
    () async {
      final file = File('${directory.path}/lookalike.dart');
      await file.writeAsString('''
import 'package:napi/napi.dart' as napi;
class AbortSignal { bool get aborted => false; }
@napi.NAPI() bool wrong(AbortSignal signal) => signal.aborted;
''');
      final module = await AnnotationFrontend(packagesPath: packages)
          .read(file.uri);
      for (final validateBackend in [validate, validateNative]) {
        expect(
          () => validateBackend(module),
          throwsA(isA<BindingDiagnostic>()),
        );
      }
      final ordinary = await read(
        '@NAPI() int ordinary(int signal) => signal;',
      );
      expect(
        lower(validate(ordinary)).functions.single.inputs.single,
        isA<ScalarConversion>(),
      );
    },
  );

  test(
    'nested, output and callback signals retain explicit diagnostics',
    () async {
      for (final declaration in [
        '@NAPI() AbortSignal output(AbortSignal value) => value;',
        '@NAPI() Future<AbortSignal> output(AbortSignal value) async => value;',
        '@NAPI() Stream<AbortSignal> output(AbortSignal value) async* { yield value; }',
        '@NAPI() int nested(List<AbortSignal> values) => values.length;',
        '@NAPI() int record((AbortSignal, int) value) => value.\$2;',
        '@NAPI() int callback(void Function(AbortSignal) callback) => 1;',
        '@NAPI() int callback(AbortSignal Function() callback) => 1;',
      ]) {
        final module = await read(declaration);
        for (final validateBackend in [validate, validateNative]) {
          expect(
            () => validateBackend(module),
            throwsA(
              isA<BindingDiagnostic>().having(
                (error) => error.code,
                'code',
                'NAPI_CANCELLATION',
              ),
            ),
            reason: declaration,
          );
        }
      }
    },
  );

  test(
    'generated global signal type is safe when an export shadows its name',
    () async {
      final file = File('${directory.path}/shadow.dart');
      await file.writeAsString('''
import 'package:napi/napi.dart' as napi;
@napi.NAPI() class AbortSignal { AbortSignal(); }
@napi.NAPI() bool check(napi.AbortSignal signal) => signal.aborted;
''');
      final module = await AnnotationFrontend(packagesPath: packages)
          .read(file.uri);
      for (final declarations in [
        emitDeclarations(lower(validate(module))),
        emitNativeDeclarations(validateNative(module)),
      ]) {
        expect(declarations, contains('class AbortSignal'));
        expect(declarations, contains('(signal: globalThis.AbortSignal)'));
      }
    },
  );
}
