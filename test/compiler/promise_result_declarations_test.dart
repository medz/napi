import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  final packages = File('.dart_tool/package_config.json').absolute.path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-promise-result-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<Map<String, String>> declarations(String source) async {
    final file = File('${directory.path}/business.dart');
    await file.writeAsString("import 'package:napi/napi.dart';\n$source");
    final module = await AnnotationFrontend(packagesPath: packages)
        .read(file.uri);
    return {
      'wasm': emitDeclarations(lower(validate(module))),
      'native': emitNativeDeclarations(validateNative(module)),
    };
  }

  test(
    'scalar and structural Futures need no Promise resolution helper',
    () async {
      final backends = await declarations('''
@NAPI() Future<int> integer() async => 1;
@NAPI() Future<void> empty() async {}
@NAPI() Future<List<int>> list() async => [1];
@NAPI() Future<({int then})> record() async => (then: 1);
''');
      for (final code in backends.values) {
        expect(code, isNot(contains(r'$napiAwaited')));
        expect(code, contains('globalThis.Promise<number>'));
        expect(code, contains('globalThis.Promise<void>'));
        expect(code, contains('globalThis.Promise<Array<number>>'));
        expect(code, contains('globalThis.Promise<{ then: number }>'));
      }
    },
  );

  test('root Promise resolution is sound for generic and reference then unions', () async {
    final backends = await declarations('''
@NAPI() T identity<T>(T value) => value;
@NAPI() Future<T> future<T>(T value) => Future.value(value);
@NAPI() Future<T?> nullable<T>([T? value]) => Future.value(value);
@NAPI() class ThenBox<T> {
  ThenBox(this.then);
  T then;
  Future<ThenBox<T>> self() async => this;
}
@NAPI() class NullableThen<T> {
  NullableThen(this.then);
  T? then;
  Future<NullableThen<T>> self() async => this;
}
@NAPI() Future<ThenBox<T>> box<T>(ThenBox<T> value) async => value;
@NAPI(name: 'Promise') class PromiseBox<T> { PromiseBox(); }
@NAPI(name: 'Awaited') class AwaitedBox<T> { AwaitedBox(); }
@NAPI(name: 'Function') class FunctionBox<T> { FunctionBox(); }
@NAPI() Future<Promise> promiseName<Promise>(Promise value) => Future.value(value);
@NAPI() Future<Awaited> awaitedName<Awaited>(Awaited value) => Future.value(value);
@NAPI() Future<globalThis> globals<globalThis>(globalThis value) => Future.value(value);
''');
    for (final backend in backends.entries) {
      expect(backend.value, contains(r'globalThis.Promise<$napiAwaited<T>>'));
      expect(
        backend.value,
        contains(r'globalThis.Promise<$napiAwaited<ThenBox<T>>>'),
      );
      expect(
        backend.value,
        contains(r'globalThis.Promise<$napiAwaited<T | null>>'),
      );
      expect(
        RegExp(r'type \$napiAwaited<').allMatches(backend.value),
        hasLength(1),
      );
      await File('${directory.path}/${backend.key}.d.mts')
          .writeAsString(backend.value);
      await File('${directory.path}/${backend.key}-consumer.mts')
          .writeAsString('''
import * as api from './${backend.key}.mjs';
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
type Assert<T extends true> = T;
type ResolveNumber = (resolve: (value: number) => void) => void;
type Root<T> = ReturnType<typeof api.future<T>>;
type Box<T> = ReturnType<typeof api.box<T>>;
type Nullish = Assert<Equal<Root<null | undefined>, Promise<null | undefined>>>;
type PromiseResult = Assert<Equal<Root<Promise<number>>, Promise<number>>>;
type Thenable = Assert<Equal<Root<{ then: ResolveNumber }>, Promise<number>>>;
type Union = Assert<Equal<Box<ResolveNumber | number>, Promise<number | api.ThenBox<ResolveNumber | number>>>>;
type Nullable = Assert<Equal<Box<ResolveNumber | null>, Promise<number | api.ThenBox<ResolveNumber | null>>>>;
type NullableField = Assert<Equal<ReturnType<api.NullableThen<ResolveNumber>['self']>, Promise<number | api.NullableThen<ResolveNumber>>>>;
type Optional = { then?: ResolveNumber };
type OptionalField = Assert<Equal<Root<Optional>, Promise<number | Optional>>>;
type Unknown = Assert<Equal<Box<unknown>, Promise<unknown>>>;
type Any = Assert<Equal<Box<any>, Promise<unknown>>>;
type Never = Assert<Equal<Box<never>, Promise<never>>>;
type NeverRoot = Assert<Equal<Root<never>, Promise<never>>>;
type UnknownRoot = Assert<Equal<Root<unknown>, Promise<unknown>>>;
type AnyRoot = Assert<Equal<Root<any>, Promise<unknown>>>;
type BroadFunction = Assert<Equal<Box<Function>, Promise<unknown>>>;
type Malformed = Assert<Equal<Box<(resolve: string) => void>, Promise<never>>>;
type NoArguments = Assert<Equal<Box<() => void>, Promise<never>>>;
type Recursive = Assert<Equal<Root<Promise<{ then: (resolve: (value: Optional) => void) => void }>>, Promise<number | Optional>>>;
type NonCallable = Assert<Equal<Box<number>, Promise<api.ThenBox<number>>>>;
type Method = Assert<Equal<ReturnType<api.ThenBox<ResolveNumber>['self']>, Promise<number>>>;
type Nested = Assert<Equal<Root<Array<api.ThenBox<ResolveNumber>>>, Promise<Array<api.ThenBox<ResolveNumber>>>>>;
type Sync = Assert<Equal<ReturnType<typeof api.identity<Promise<number>>>, Promise<number>>>;
type NamePromise = Assert<Equal<ReturnType<typeof api.promiseName<Promise<number>>>, Promise<number>>>;
type NameAwaited = Assert<Equal<ReturnType<typeof api.awaitedName<Promise<number>>>, Promise<number>>>;
type NameGlobals = Assert<Equal<ReturnType<typeof api.globals<Promise<number>>>, Promise<number>>>;
const number: Promise<number> = api.box(new api.ThenBox<ResolveNumber>(resolve => resolve(1)));
const maybe: Promise<number | api.NullableThen<ResolveNumber>> = new api.NullableThen<ResolveNumber>(resolve => resolve(1)).self();
// @ts-expect-error A callable then resolves its payload; it does not return its wrapper.
const wrongWrapper: Promise<api.ThenBox<ResolveNumber>> = api.box(new api.ThenBox<ResolveNumber>(resolve => resolve(1)));
// @ts-expect-error A nullable then also allows the original object to fulfill.
const wrongNumber: Promise<number> = new api.NullableThen<ResolveNumber>(null).self();
// @ts-expect-error Unknown then may resolve an arbitrary value.
const wrongUnknown: Promise<api.ThenBox<unknown>> = api.box(new api.ThenBox<unknown>('value'));
void [number, maybe, wrongWrapper, wrongNumber, wrongUnknown];
''');
    }
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    for (final mode in ['NodeNext', 'Bundler']) {
      for (final exact in ['true', 'false']) {
        for (final indexed in ['true', 'false']) {
          final result = await Process.run(
            Platform.environment['NODE'] ?? 'node',
            [
              tsc,
              '--ignoreConfig',
              '--noEmit',
              '--strict',
              '--target',
              'ES2022',
              '--module',
              mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
              '--moduleResolution',
              mode,
              '--exactOptionalPropertyTypes',
              exact,
              '--noUncheckedIndexedAccess',
              indexed,
              for (final backend in backends.keys)
                '${directory.path}/$backend-consumer.mts',
            ],
          );
          expect(
            result.exitCode,
            0,
            reason:
                '$mode exact=$exact indexed=$indexed: ${result.stdout}${result.stderr}',
          );
        }
      }
    }
  });

  for (final source in [
    r"@NAPI(name: r'$napiAwaited') int value() => 1;",
    r"@NAPI(name: r'$napiAwaited') class Value { Value(); }",
    r'@NAPI() Future<$napiAwaited> value<$napiAwaited>($napiAwaited input) async => input;',
  ]) {
    test(
      'private Promise type cannot collide with public identifiers',
      () async {
        final file = File('${directory.path}/business.dart');
        await file.writeAsString("import 'package:napi/napi.dart';\n$source");
        final module = await AnnotationFrontend(packagesPath: packages)
            .read(file.uri);
        expect(
          () => lower(validate(module)),
          throwsA(isA<BindingDiagnostic>()),
        );
        expect(() => validateNative(module), throwsA(isA<BindingDiagnostic>()));
      },
    );
  }
}
