import 'dart:io';

import 'package:napi/src/compiler/analysis/result.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  final packages = File('.dart_tool/package_config.json').absolute.path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-stream-policy-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<File> source(String text) async =>
      File('${directory.path}/business.dart')..writeAsStringSync('''
import 'dart:async';
import 'package:napi/napi.dart';
$text
''');
  Future<BindingModule> read(String text) async =>
      AnnotationFrontend(packagesPath: packages).read((await source(text)).uri);

  test(
    'Stream completion preserves payload types and external selection',
    () async {
      final file = await source('''
typedef Events<T> = Stream<T>;
@NAPI() Events<int?> values() => Stream.value(null);
@NAPI() Stream<T> payload<T>(T value) async* { yield value; }
@NAPI() Stream<void> empty() => const Stream.empty();
@NAPI() class Counter {
  Counter();
  Stream<Counter> get events => Stream.value(this);
  Stream<List<int>> batches() async* { yield [1, 2]; }
  static Stream<String> text() => Stream.value('text');
}
''');
      final annotated = await AnnotationFrontend(packagesPath: packages)
          .read(file.uri);
      final external = await ExternalFrontend(
        const ExternalLibrary([
          ExternalFunction('values'),
          ExternalFunction('payload'),
          ExternalFunction('empty'),
          ExternalClass('Counter'),
        ]),
        packagesPath: packages,
      ).read(file.uri);
      final wasm = lower(validate(annotated));
      final native = validateNative(annotated);
      expect(wasm.functions.map((f) => f.returnsStream), everyElement(isTrue));
      expect(wasm.functions.map((f) => f.returnsFuture), everyElement(isFalse));
      expect(
        wasm.functions.map((f) => f.representation),
        everyElement(ExportRepresentation.callableGlobal),
      );
      expect(wasm.functions.first.output, isA<ScalarConversion>());
      expect(wasm.functions[1].output, isA<OpaqueConversion>());
      expect(wasm.functions.last.output, isNull);
      expect(annotated.functions.first.result.alias, isNotNull);
      expect(annotated.functions[1].isGenerator, isTrue);
      expect(
        native.functions.map((f) => f.returnsStream),
        everyElement(isTrue),
      );
      expect(native.hasStreams, isTrue);
      final types = emitDeclarations(wasm);
      final nativeTypes = emitNativeDeclarations(native);
      expect(emitDeclarations(lower(validate(external))), types);
      expect(emitNativeDeclarations(validateNative(external)), nativeTypes);
      for (final declaration in [types, nativeTypes]) {
        expect(
          declaration,
          contains(
            'globalThis.AsyncIterableIterator<number | null, undefined, undefined>',
          ),
        );
        expect(
          declaration,
          contains('globalThis.AsyncIterableIterator<T, undefined, undefined>'),
        );
        expect(
          declaration,
          contains(
            'globalThis.AsyncIterableIterator<void, undefined, undefined>',
          ),
        );
        expect(
          declaration,
          contains(
            'get events(): globalThis.AsyncIterableIterator<Counter, undefined, undefined>;',
          ),
        );
        expect(
          declaration,
          contains(
            'batches(): globalThis.AsyncIterableIterator<Array<number>, undefined, undefined>;',
          ),
        );
        expect(declaration, isNot(contains(r'$napiAwaited')));
        expect(declaration, isNot(contains(r'$napiStream')));
      }
    },
  );

  test(
    'selected and inherited async generators keep their call contract',
    () async {
      final module = await read('''
@NAPI() class Parent { Stream<int> values() => Stream.value(1); }
class Middle extends Parent {
  @override Stream<int> values() async* { yield 2; }
}
@NAPI() class Child extends Middle { Child(); }
@NAPI() class SelectedChild extends Parent {
  SelectedChild();
  @override Stream<int> values() async* { yield 3; }
}
''');
      final wasm = lower(validate(module));
      final native = validateNative(module);
      expect(wasm.classes.last.members.single.returnsStream, isTrue);
      expect(native.classes.last.members.single.returnsStream, isTrue);
      expect(wasm.classes[1].shape.memberships, {0, 1});
    },
  );

  test('a source class called Stream remains an ordinary reference', () async {
    final module = await read('''
@NAPI() class Stream { Stream(); }
@NAPI() Stream identity(Stream value) => value;
''');
    final result = module.functions.single.result;
    expect(isStreamType(result), isFalse);
    expect(identical(resultPayload(result), result), isTrue);
    expect(lower(validate(module)).functions.single.returnsStream, isFalse);
    expect(validateNative(module).hasStreams, isFalse);
  });

  for (final (name, text, code) in [
    ('nullable stream', '@NAPI() Stream<int>? values() => null;', 'NAPI_TYPE'),
    (
      'stream input',
      '@NAPI() int consume(Stream<int> value) => 1;',
      'NAPI_TYPE',
    ),
    (
      'nested stream',
      '@NAPI() Stream<Stream<int>> values() => throw 1;',
      'NAPI_TYPE',
    ),
    (
      'future stream',
      '@NAPI() Future<Stream<int>> values() => throw 1;',
      'NAPI_TYPE',
    ),
    (
      'stream future',
      '@NAPI() Stream<Future<int>> values() => throw 1;',
      'NAPI_TYPE',
    ),
    (
      'nullable callback stream',
      '@NAPI() int call(Stream<int>? Function() callback) => 1;',
      'NAPI_CALLBACK',
    ),
    (
      'stream cleanup',
      "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class Owner { Stream<void> close() => const Stream.empty(); }",
      'NAPI_RESOURCE',
    ),
  ]) {
    test('$name is diagnosed on both backends', () async {
      final module = await read(text);
      for (final check in [
        () => validate(module),
        () => validateNative(module),
      ]) {
        expect(
          check,
          throwsA(isA<BindingDiagnostic>().having((e) => e.code, 'code', code)),
        );
      }
    });
  }
}
