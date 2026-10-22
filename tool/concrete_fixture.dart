import 'dart:convert';
import 'dart:io';

import 'verify.dart' show run;

/// Verifies generated concrete generic substitutions and declarations in relocated, installed packages.
Future<void> verifyConcreteFixture(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('concrete $backend 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: concrete_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  for (final name in [
    'concrete.dart',
    'concrete_callables.dart',
    'concrete_callable_part.dart',
  ]) {
    await File('test/fixtures/$name').copy('${project.path}/$name');
  }
  await File('${project.path}/business.dart')
      .writeAsString("export 'concrete.dart';\n");
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
import 'package:napi/napi.dart';
Future<void> main() async {
  for (final external in [false, true]) {
    await buildPackage(
      library: File('business.dart').absolute.uri,
      output: Directory(external ? 'external' : 'package'),
      metadata: {'name': external ? '@napi/concrete-external' : '@napi/concrete-fixture', 'version': '0.0.0'},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      external: external ? const ExternalLibrary([
        ExternalFunction('sumIntegers'),
        ExternalFunction('sumDoubles'),
        ExternalFunction('sumBigints', config: NAPI(bigint: true)),
        ExternalFunction('intTypeName'),
        ExternalFunction('doubleTypeName'),
        ExternalFunction('typedDefault'),
        ExternalFunction('nullableInteger'),
        ExternalFunction('recordIdentity'),
        ExternalFunction('nestedIdentity'),
        ExternalFunction('laterInteger'),
        ExternalFunction('staticInteger'),
        ExternalFunction('echoInt'),
        ExternalFunction('echoDouble'),
        ExternalFunction('equivalent'),
        ExternalFunction('listCells'),
        ExternalFunction('mapCells'),
        ExternalFunction('pair'),
        ExternalFunction('createInt'),
        ExternalFunction('createDerived'),
        ExternalFunction('widenedInt'),
        ExternalFunction('ambiguousInt'),
        ExternalFunction('delayedInt'),
        ExternalFunction('saveInt'),
        ExternalFunction('savedInt'),
        ExternalFunction('pressure'),
        ExternalClass('IntPair'),
        ExternalClass('PartialChild'),
        ExternalClass('MaybeIntPair'),
        ExternalClass('NullableIntPair'),
        ExternalClass('NullableTextPair', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('NullableResourcePair', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalFunction('echoNullablePair'),
        ExternalFunction('widenNullablePair'),
        ExternalFunction('clearNullablePair'),
        ExternalFunction('echoNullableValue'),
        ExternalFunction('clearNullableResource'),
        ExternalFunction('nullableAliasArgument'),
        ExternalClass('TextPair', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('ResourcePair', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalClass('FlippedPair'),
        ExternalClass('NestedIntPair'),
        ExternalClass('NestedChild'),
        ExternalClass('NestedTextPair', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('NestedResourcePair', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalClass('NestedCallbackPair'),
        ExternalFunction('echoNestedPair'),
        ExternalFunction('appendNestedNull'),
        ExternalFunction('echoNestedValue'),
        ExternalFunction('echoPartial'),
        ExternalFunction('widenPartial'),
        ExternalFunction('echoPartialValue'),
        ExternalFunction('partialCloses'),
        ExternalFunction('echoFlipped'),
        ExternalClass('IntCrossView'),
        ExternalClass('NullableCrossView'),
        ExternalClass('NullableLeftView'),
        ExternalClass('IntRightView'),
        ExternalClass('SameAliasView'),
        ExternalFunction('crossedView'),
        ExternalFunction('compatibleView'),
        ExternalClass('IntCrossOwner', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalClass('NullableCrossOwner', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalClass('NullableLeftOwner'),
        ExternalClass('IntRightOwner'),
        ExternalClass('SameAliasOwner'),
        ExternalFunction('crossedOwner'),
        ExternalFunction('compatibleOwner'),
        ExternalFunction('createHiddenMiddleCell'),
        ExternalFunction('createMixedHiddenMiddleCell'),
        ExternalClass('NullableSessionChild'),
        ExternalFunction('createHiddenSession'),
        ExternalFunction('createMixedHiddenSession'),
        ExternalClass('NullableMiddleCell'),
        ExternalClass('DeepCell'),
        ExternalFunction('createDeepCell'),
        ExternalFunction('createMixedDeepCell'),
        ExternalClass('NullableMiddleSession', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'shutdown')),
        ExternalClass('DeepSession'),
        ExternalFunction('createDeepSession'),
        ExternalFunction('createMixedDeepSession'),
        ExternalClass('NullableChildCell'),
        ExternalClass('ExtraCellFeature'),
        ExternalFunction('createMixedChild'),
        ExternalClass('IntCellFeature'),
        ExternalClass('DoubleCellFeature'),
        ExternalClass('IntChildCell'),
        ExternalClass('DoubleChildCell'),
        ExternalClass('IntListCell'),
        ExternalClass('IntBatchChild'),
        ExternalClass('IntChildSession', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalClass('DoubleChildSession', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalFunction('createChildCell'),
        ExternalFunction('createChildSession'),
        ExternalFunction('echoCellFeature'),
        ExternalFunction('echoIntListCell'),
        ExternalClass('IntCell'),
        ExternalClass('DoubleCell'),
        ExternalClass('NullableCell'),
        ExternalClass('BatchCell'),
        ExternalClass('Leaf'),
        ExternalClass('LeafCell'),
        ExternalClass('IntNumeric'),
        ExternalClass('SelfBound'),
        ExternalClass('IntSession', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalClass('DoubleSession', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalClass('NullableSession', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'shutdown')),
        ExternalClass('TextSessionValue', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('NullableTextSession', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalFunction('createTextSession'),
        ExternalFunction('echoTextSessionValue'),
        ExternalFunction('projectTextSession'),
        ExternalFunction('delayedTextSession'),
        ExternalClass('VoidSession', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalFunction('createSession'),
        ExternalFunction('echoSession'),
        ExternalFunction('widenedSession'),
        ExternalFunction('holdSessions'),
        ExternalFunction('finishSession'),
        ExternalFunction('finishSessionCancel'),
        ExternalFunction('sessionCloses'),
        ExternalFunction('sessionShutdowns'),
        ExternalFunction('sessionCode'),
        ExternalFunction('sessionCancels'),
        ExternalFunction('sessionAlive'),
        ExternalFunction('sessionPressure'),

        ExternalClass('IntValue', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('TextValue', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('DoubleValue', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('NullableValue', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('NestedValue', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('LeafValue', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('BytesValue', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('SharedValue', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('TextProjection', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('VoidValue', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('ObjectValue', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('ValueHandle'),
        ExternalClass('ParsedInteger', config: NAPI(classPolicy: ClassPolicy.value, valueFields: {'source': 'value'})),
        ExternalClass('ParsedDouble', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalFunction('echoIntValue'),
        ExternalFunction('valueTuple'),
        ExternalFunction('nullableValue'),
        ExternalFunction('nestedValue'),
        ExternalFunction('repeatValue'),
        ExternalFunction('valueMap'),
        ExternalFunction('valueDictionary'),
        ExternalFunction('leafValue'),
        ExternalFunction('valueShadow'),
        ExternalFunction('bytesValue'),
        ExternalFunction('sharedValue'),
        ExternalFunction('parseInteger'),
        ExternalFunction('parseDouble'),
        ExternalFunction('textProjection'),
        ExternalFunction('valueMarkers'),
        ExternalFunction('echoValueHandle'),
        ExternalFunction('createValueHandle'),
        ExternalFunction('twoValues'),
        ExternalFunction('concreteValueConstructions'),
        ExternalFunction('concreteValueCalls'),
        ExternalFunction('cyclicValue'),
        ExternalFunction('delayedValue'),
        ExternalFunction('valueEvents'),
        ExternalFunction('bigintValue', config: NAPI(bigint: true)),
      ]) : null,
      ${native ? 'target: BuildTarget.native,\n      nativeRuntime: Directory(${jsonEncode(nativeRuntime.absolute.path)}),' : ''}
    );
  }
}
''');
  await run(Platform.resolvedExecutable, [
    'pub',
    'get',
    '--offline',
  ], cwd: project.path);
  await run(Platform.resolvedExecutable, [
    'run',
    'build.dart',
  ], cwd: project.path);
  final declaration = native ? 'module.d.mts' : 'module.d.wasm.ts';
  if (await File('${project.path}/package/$declaration').readAsString() !=
      await File('${project.path}/external/$declaration').readAsString()) {
    throw StateError('Annotation and external concrete declarations differ.');
  }
  final archives = <String>[];
  for (final (directory, name) in [
    ('package', 'fixture'),
    ('external', 'external'),
  ]) {
    final package = '${project.path}/$directory';
    await run('npm', ['pack', '--ignore-scripts', '--silent'], cwd: package);
    final archive = await File('$package/napi-concrete-$name-0.0.0.tgz')
        .copy('${canonical.path}/$name.tgz');
    archives.add(archive.path);
  }
  await project.delete(recursive: true);
  final consumer = await Directory('${canonical.path}/installed consumer 雪')
      .create();
  await File('${consumer.path}/package.json')
      .writeAsString('{"private":true,"type":"module"}');
  await run('npm', [
    'install',
    '--offline',
    '--ignore-scripts',
    '--no-audit',
    '--no-fund',
    ...archives,
  ], cwd: consumer.path);
  await File('test/integration/concrete.mjs').copy('${consumer.path}/test.mjs');
  final declarations = await File('test/typescript/concrete.mts')
      .readAsString();
  await run('node', ['--expose-gc', 'test.mjs'], cwd: consumer.path);
  final tsc =
      Platform.environment['NAPI_TSC'] ??
      '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
  for (final mode in ['NodeNext', 'Bundler']) {
    for (final exact in ['true', 'false']) {
      await File('${consumer.path}/consumer.mts').writeAsString(
        declarations.replaceAll(
          '/BACKEND',
          native ? '/native' : '/module.wasm',
        ),
      );
      for (final unchecked in ['true', 'false']) {
        await run('node', [
          File(tsc).absolute.path,
          '--ignoreConfig',
          '--strict',
          '--exactOptionalPropertyTypes',
          exact,
          '--noUncheckedIndexedAccess',
          unchecked,
          '--noEmit',
          '--target',
          'ES2022',
          '--module',
          mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
          '--moduleResolution',
          mode,
          '--allowArbitraryExtensions',
          'consumer.mts',
        ], cwd: consumer.path);
      }
    }
  }
  stdout.writeln('Concrete $backend fresh packages and TypeScript: passed');
}

Future<void> main(List<String> args) async {
  if (args.length > 1) {
    throw ArgumentError(
      'Usage: dart run tool/concrete_fixture.dart [native-runtime-bundle]',
    );
  }
  final root = await Directory('.dart_tool').createTemp('napi concrete ');
  stdout.writeln('Concrete verification artifacts: ${root.absolute.path}');
  await verifyConcreteFixture(
    root,
    nativeRuntime: args.isEmpty ? null : Directory(args.single),
  );
}
