import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-shared-policy-');
    addTearDown(() => directory.delete(recursive: true));
  });

  test('canonical SharedBytes aliases have one common conversion', () async {
    await File('${directory.path}/exports.dart')
        .writeAsString("export 'package:napi/napi.dart' show SharedBytes;");
    final input = await File('${directory.path}/business.dart')
        .writeAsString('''
import 'package:napi/napi.dart';
import 'exports.dart' as re;
typedef Bytes = SharedBytes;
@NAPI() Bytes direct(Bytes value) => value;
@NAPI() re.SharedBytes? nullable(re.SharedBytes? value) => value;
@NAPI() List<SharedBytes> nested(List<SharedBytes> value) => value;
@NAPI() Future<SharedBytes> future(SharedBytes value) async => value;
@NAPI() Stream<SharedBytes> stream(SharedBytes value) async* { yield value; }
''');
    final module = await AnnotationFrontend(packagesPath: packages)
        .read(input.uri);
    final wasm = lower(validate(module));
    final native = validateNative(module);
    for (final conversion in [
      wasm.functions.first.inputs.single,
      native.functions.first.inputs.single,
    ]) {
      expect(conversion, isA<SharedBytesConversion>());
      expect(conversion.dartType, 'napi.SharedBytes');
      expect(
        conversion.typescriptType,
        'globalThis.Uint8Array<globalThis.ArrayBuffer>',
      );
      expect(conversionGraph([conversion]), [conversion]);
    }
    expect(
      wasm.functions.map((call) => call.output?.typescriptType),
      native.functions.map((call) => call.output?.typescriptType),
    );
    final declarations =
        emitDeclarations(wasm) + emitNativeDeclarations(native);
    expect(
      declarations,
      contains('globalThis.Uint8Array<globalThis.ArrayBuffer> | null'),
    );
    expect(
      declarations,
      contains(
        'globalThis.AsyncIterableIterator<globalThis.Uint8Array<globalThis.ArrayBuffer>',
      ),
    );
  });

  test('an unrelated class name is not promoted to SharedBytes', () async {
    final input = await File('${directory.path}/business.dart')
        .writeAsString('''
import 'package:napi/napi.dart' show NAPI;
class SharedBytes {}
@NAPI() SharedBytes value(SharedBytes input) => input;
''');
    final module = await AnnotationFrontend(packagesPath: packages)
        .read(input.uri);
    expect(() => validate(module), throwsA(isA<BindingDiagnostic>()));
    expect(() => validateNative(module), throwsA(isA<BindingDiagnostic>()));
  });

  for (final signature in [
    'void Function(SharedBytes)',
    'SharedBytes Function()',
    'Future<SharedBytes> Function()',
    'void Function(List<SharedBytes>)',
  ]) {
    test('shared callback signature remains diagnosed: $signature', () async {
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int value($signature callback) => 0;
''');
      final module = await AnnotationFrontend(packagesPath: packages)
          .read(input.uri);
      expect(
        () => validate(module),
        throwsA(
          isA<BindingDiagnostic>().having(
            (error) => error.code,
            'code',
            'NAPI_CALLBACK',
          ),
        ),
      );
      expect(() => validateNative(module), throwsA(isA<BindingDiagnostic>()));
    });
  }
}
