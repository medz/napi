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

  Future<void> checkTypes(Iterable<String> consumers) async {
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
              ...consumers,
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

  test(
    'composed collection getter views keep generic parameters in scope',
    () async {
      final backends = await declarations('''
@NAPI() class CollectionBox<T> { CollectionBox(); }
@NAPI() class CollectionReads<T> {
  JsArray<T> get opaque => throw '';
  JsArray<JsMap<String, JsArray<CollectionBox<T>>>> get nested => throw '';
  JsMap<CollectionBox<T>, int> get keys => throw '';
  JsArray<int> get scalar => throw '';
}
@NAPI() class CollectionWrites {
  set opaque(JsArray<int> value) {}
  set nested(JsArray<int> value) {}
  set keys(JsArray<int> value) {}
  set scalar(JsArray<int> value) {}
}
''');
      for (final backend in backends.entries) {
        await File('${directory.path}/${backend.key}.d.mts')
            .writeAsString(backend.value);
        await File('${directory.path}/${backend.key}-consumer.mts')
            .writeAsString('''
import * as api from './${backend.key}.mjs';
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
type Assert<T extends true> = T;
type Opaque = Assert<Equal<api.CollectionWrites['opaque'], unknown>>;
type Nested = Assert<Equal<api.CollectionWrites['nested'], unknown>>;
type Keys = Assert<Equal<api.CollectionWrites['keys'], unknown>>;
type Scalar = Assert<Equal<api.CollectionWrites['scalar'], Array<number> | undefined>>;
type Own = Assert<Equal<api.CollectionReads<string>['nested'], Array<Map<string, Array<api.CollectionBox<string>>>>>>;
const writes = new api.CollectionWrites();
writes.opaque = [1]; writes.nested = [2]; writes.keys = [3]; writes.scalar = [4];
// @ts-expect-error Unknown composed reads do not become this setter's type.
const nested: Array<number> = writes.nested;
// @ts-expect-error Broadening a composed read does not broaden the setter.
writes.opaque = ['wrong'];
void [nested];
''');
      }
      await checkTypes(
        backends.keys.map((name) => '${directory.path}/$name-consumer.mts'),
      );
    },
  );

  test(
    'root Promise resolution is sound for generic and reference then unions',
    () async {
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
@NAPI() class SetterThen<T> {
  SetterThen(T value) : _value = value;
  T _value;
  set then(T value) { _value = value; }
  T get value => _value;
  Future<SetterThen<T>> self() async => this;
}
@NAPI() class WriteBase { set inherited(int value) {} }
@NAPI() class ReadChild extends WriteBase { int get inherited => 1; }
@NAPI() class WriteGrandChild extends ReadChild {
  @override set inherited(int value) {}
}
@NAPI() class UnrelatedWrite { set related(int value) {} }
@NAPI() class UnrelatedRead { int get related => 1; }
class _Unselected implements UnrelatedWrite, UnrelatedRead {
  int get related => 2;
  set related(int value) {}
}
@NAPI() UnrelatedWrite unselected() => _Unselected();
@NAPI() class RenamedWrite {
  @NAPI(name: 'conflict') set original(int value) {}
}
@NAPI() class RenamedRead {
  @NAPI(name: 'conflict') int get different => 1;
}
@NAPI() class ReadType {}
@NAPI() class NameWrite<ReadType> { set clash(ReadType value) {} }
@NAPI() class NameRead { ReadType get clash => ReadType(); }
@NAPI() class ReadView { int get combined => 1; }
@NAPI() class WriteView { set combined(int value) {} }
@NAPI() class Combined implements ReadView, WriteView {
  int get combined => 2;
  set combined(int value) {}
}
@NAPI() class StaticSetter {
  static set then(void Function() value) { value(); }
  static int get paired => 1;
  static set paired(int value) {}
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
type Dictionary = Record<string, ResolveNumber>;
type ResolveDictionary = (resolve: (value: Dictionary) => void) => void;
type DictionaryRoot = Assert<Equal<Root<Dictionary>, Promise<Dictionary | number>>>;
type RecursiveDictionary = Assert<Equal<Root<{ then: ResolveDictionary }>, Promise<Dictionary | number>>>;
type DeepDictionary = Assert<Equal<Root<Record<string, ResolveDictionary>>, Promise<Record<string, ResolveDictionary> | Dictionary | number>>>;
type RequiredIndexedThen = Assert<Equal<Root<Dictionary & { then: ResolveNumber }>, Promise<number>>>;
type NonCallable = Assert<Equal<Box<number>, Promise<api.ThenBox<number>>>>;
type Method = Assert<Equal<ReturnType<api.ThenBox<ResolveNumber>['self']>, Promise<number>>>;
type SetterRead = Assert<Equal<api.SetterThen<ResolveNumber>['then'], unknown>>;
type SetterResult = Assert<Equal<ReturnType<api.SetterThen<ResolveNumber>['self']>, Promise<unknown>>>;
type SetterOpaque = Assert<Equal<Root<api.SetterThen<ResolveNumber>>, Promise<unknown>>>;
const setter = new api.SetterThen<ResolveNumber>(resolve => resolve(1));
setter.then = resolve => resolve(2);
const setterRead: unknown = setter.then;
const setterSelf: Promise<unknown> = setter.self();
// @ts-expect-error Composed generic getter views can fulfill an unknown value.
const wrongSetter: Promise<number> = setter.self();
// @ts-expect-error Independent read and write types must preserve setter validation.
setter.then = 'bad';
// @ts-expect-error A composed getter may change the Promise result.
const setterWrapper: Promise<typeof setter> = setter.self();
void [setterRead, setterSelf, wrongSetter, setterWrapper];
type ParentRead = Assert<Equal<api.WriteBase['inherited'], number | undefined>>;
type ChildRead = Assert<Equal<api.ReadChild['inherited'], number>>;
type GrandChildRead = Assert<Equal<api.WriteGrandChild['inherited'], number>>;
const child = new api.ReadChild();
const parent: api.WriteBase = child;
const grandParent: api.WriteBase = new api.WriteGrandChild();
parent.inherited = 2;
const combined = new api.Combined();
const readView: api.ReadView = combined;
const writeView: api.WriteView = combined;
const writeRead: number | undefined = writeView.combined;
writeView.combined = 3;
// @ts-expect-error A missing base getter can still read undefined.
const definitelyRead: number = new api.WriteBase().inherited;
// @ts-expect-error Widening reads must not weaken the inherited setter.
parent.inherited = 'bad';
// @ts-expect-error Interface composition must retain the setter input.
writeView.combined = 'bad';
type UnselectedRead = Assert<Equal<api.UnrelatedWrite['related'], number | undefined>>;
const unselectedRead: number | undefined = api.unselected().related;
// @ts-expect-error Unselected implementations may contribute a getter.
const unselectedUndefined: undefined = api.unselected().related;
type RenamedConflict = Assert<Equal<api.RenamedWrite['conflict'], undefined>>;
type GenericName = Assert<Equal<api.NameWrite<string>['clash'], unknown>>;
type StaticRead = Assert<Equal<typeof api.StaticSetter['then'], undefined>>;
type StaticResult = Assert<Equal<Root<typeof api.StaticSetter>, Promise<typeof api.StaticSetter>>>;
api.StaticSetter.then = () => {};
const staticRead: undefined = api.StaticSetter.then;
const staticResult: Promise<typeof api.StaticSetter> = api.future(api.StaticSetter);
const paired: number = api.StaticSetter.paired;
api.StaticSetter.paired = 2;
// @ts-expect-error Static setter-only then retains its callback input type.
api.StaticSetter.then = 1;
// @ts-expect-error Static setter-only then does not assimilate its write type.
const staticNever: Promise<never> = api.future(api.StaticSetter);
void [grandParent, readView, writeRead, definitelyRead, staticRead, staticResult, paired, staticNever];
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
      await checkTypes([
        for (final backend in backends.keys)
          '${directory.path}/$backend-consumer.mts',
      ]);
    },
  );

  test(
    'setter-only then stays exact without a composable getter view',
    () async {
      final backends = await declarations('''
@NAPI() Future<T> future<T>(T value) => Future.value(value);
@NAPI() class Setter<T> {
  Setter(T value) : _value = value;
  T _value;
  T get value => _value;
  set then(T value) { _value = value; }
  Future<Setter<T>> self() => Future.value(this);
}
''');
      for (final backend in backends.entries) {
        await File('${directory.path}/${backend.key}.d.mts')
            .writeAsString(backend.value);
        await File('${directory.path}/${backend.key}-consumer.mts')
            .writeAsString('''
import {Setter, future} from './${backend.key}.mjs';
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
type Assert<T extends true> = T;
type Resolve = (resolve: (value: number) => void) => void;
type Read = Assert<Equal<Setter<Resolve>['then'], undefined>>;
const setter = new Setter<Resolve>(resolve => resolve(1));
setter.then = resolve => resolve(2);
const read: undefined = setter.then;
const self: Promise<typeof setter> = setter.self();
const opaque: Promise<typeof setter> = future(setter);
// @ts-expect-error Setter-only then cannot fulfill its write type.
const wrong: Promise<number> = setter.self();
// @ts-expect-error Undefined reads do not weaken writes.
setter.then = 'bad';
void [read, self, opaque, wrong];
''');
      }
      await checkTypes([
        for (final backend in backends.keys)
          '${directory.path}/$backend-consumer.mts',
      ]);
    },
  );

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
