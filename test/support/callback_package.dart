import 'dart:convert';
import 'dart:io';

import 'package:napi/src/build/native_runtime.dart';

import 'commands.dart' show run;
import 'process.dart';

Future<void> main(List<String> arguments) async {
  final root = Directory(arguments[0]);
  final native = arguments[1] == 'native';
  final configured = Platform.environment['NAPI_TEST_NATIVE_RUNTIME'];
  if (native && configured != null && configured.isEmpty) {
    throw StateError('NAPI_TEST_NATIVE_RUNTIME must not be empty.');
  }
  final bundle = native
      ? (await resolveNativeRuntime(
          runtime: configured == null ? null : Directory(configured),
          output: root,
        )).directory
      : null;
  final result = await buildCallbackPackage(root, nativeRuntime: bundle);
  await File('${root.path}/consumer-path').writeAsString(result.path);
}

Future<Directory> buildOwnedCallbackPackage(
  Directory root, {
  required bool native,
}) async {
  await runProcess(Platform.resolvedExecutable, [
    '--packages=${File('.dart_tool/package_config.json').absolute.path}',
    File('test/support/callback_package.dart').absolute.path,
    root.path,
    native ? 'native' : 'wasm',
  ], timeout: const Duration(minutes: 3));
  return Directory(await File('${root.path}/consumer-path').readAsString());
}

/// Build source/external callbacks once, then relocate and install both archives.
Future<Directory> buildCallbackPackage(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final backend = native ? 'native' : 'wasm';
  final canonical = await Directory(root.resolveSymbolicLinksSync())
      .createTemp('callback $backend 雪 ');
  final project = await Directory('${canonical.path}/business 中文').create();
  await File('${project.path}/pubspec.yaml').writeAsString('''
name: callback_business
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
  await File('test/fixtures/callbacks.dart')
      .copy('${project.path}/business.dart');
  await File('${project.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
import 'package:napi/napi.dart';
Future<void> main() async {
  for (final external in [false, true]) {
    await buildPackage(
      library: File('business.dart').absolute.uri,
      output: Directory(external ? 'external' : 'package'),
      metadata: {'name': external ? '@napi/callback-external' : '@napi/callback-fixture', 'version': '0.0.0'},
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
      external: external ? const ExternalLibrary([
        ExternalFunction('plainCallback'),
        ExternalFunction('plainAsyncCallback'),
        ExternalFunction('readCallbackStream'),
        ExternalFunction('readPayloadStream'),
        ExternalFunction('countCallbackStream'),
        ExternalFunction('optionalCallbackStream'),
        ExternalFunction('namedCallbackStream'),
        ExternalFunction('forwardCallbackStream'),
        ExternalFunction('callbackStreamHandles'),
        ExternalFunction('callBytes'),
        ExternalFunction('callBuffer'),
        ExternalFunction('callShared'),
        ExternalFunction('callBinaryRecord'),
        ExternalFunction('invokeBinaryRecord'),
        ExternalFunction('clearBinaryCallback'),
        ExternalFunction('callAsyncBytes'),
        ExternalFunction('callAsyncShared'),
        ExternalFunction('callAsyncBinaryRecord'),
        ExternalFunction('binaryCallbackPolicies'),
        ExternalClass('CallbackBox'),
        ExternalClass('CallbackResource', config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')),
        ExternalClass('CallbackValue', config: NAPI(classPolicy: ClassPolicy.value), members: [
          ExternalMember.getter('hashCode', config: NAPI(exclude: true)),
        ]),
        ExternalClass('CallbackNormalized', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('CallbackSelectedValue', config: NAPI(classPolicy: ClassPolicy.value), members: [
          ExternalMember.constructor('parse', config: NAPI()),
        ]),
        ExternalClass('CallbackProjection', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalClass('CallbackPayloadBox'),
        ExternalFunction('callContainers'),
        ExternalFunction('callAsyncContainers'),
        ExternalFunction('callKeyMap'),
        ExternalFunction('callNormalized'),
        ExternalFunction('selectValue'),
        ExternalFunction('callProjection'),
        ExternalFunction('readProjectionCallback'),
        ExternalFunction('callReference'),
        ExternalFunction('callNewResource'),
        ExternalFunction('callAsyncNewResource'),
        ExternalFunction('startResourceCallback'),
        ExternalFunction('callPayload'),
        ExternalFunction('callAsyncPayload'),
        ExternalFunction('rejectCallbackPayload'),
        ExternalFunction('callOptionalPositionals'),
        ExternalFunction('callNullablePositionals'),
        ExternalFunction('callOpaquePositionals'),
        ExternalFunction('callOptionalNames'),
        ExternalFunction('callNamesBA'),
        ExternalFunction('callNamesAB'),
        ExternalFunction('callMixedNames'),
        ExternalFunction('callRequiredNames'),
        ExternalFunction('callAsyncOptionalPositionals'),
        ExternalFunction('callAsyncOptionalNames'),
        ExternalFunction('callOptionalModels'),
        ExternalFunction('callbackParameterPolicies'),
        ExternalClass('CallbackFunctionValue', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalFunction('echoFunctionValue'),
        ExternalFunction('makeAdder'),
        ExternalFunction('makeOptionalAdder'),
        ExternalFunction('makeNamedAdder'),
        ExternalFunction('nullableAdder'),
        ExternalFunction('futureAdder'),
        ExternalFunction('makeAsyncAdder'),
        ExternalFunction('makeStreamAdder'),
        ExternalFunction('functionContainers'),
        ExternalFunction('useFunctionContainers'),
        ExternalFunction('transformFunction'),
        ExternalFunction('echoFunction'),
        ExternalFunction('composeFunction'),
        ExternalFunction('normalizedFunction'),
        ExternalFunction('echoNormalizedFunction'),
        ExternalFunction('positionalDefaults'),
        ExternalFunction('optionalFunction'),
        ExternalFunction('requiredFunction'),
        ExternalFunction('isCanonicalFunction'),
        ExternalFunction('capturePayload'),
        ExternalFunction('rejectFunctionResult'),
        ExternalFunction('resourceFunction'),
        ExternalFunction('asyncResourceFunction'),
        ExternalFunction('resourceStreamFunction'),
        ExternalFunction('startFunctionOnlyCallback'),
        ExternalFunction('functionHandleValues'),
        ExternalFunction('callListFunctionHandle'),
        ExternalFunction('callNestedListFunctionHandle'),
        ExternalFunction('nullableFunctionHandles'),
        ExternalFunction('asyncFunctionHandle'),
        ExternalFunction('opaqueFunctionHandles'),
        ExternalFunction('copiedFunctionHandle'),
        ExternalFunction('normalizedFunctionHandle'),
        ExternalClass('FunctionKeyMap'),
        ExternalFunction('nullableFunctionKeys'),
        ExternalFunction('asyncFunctionKeys'),
        ExternalFunction('opaqueFunctionKeys'),
        ExternalFunction('normalizedFunctionKey'),
        ExternalFunction('resourceFunctionKey'),
        ExternalFunction('callbackCleanups'),
        ExternalFunction('callHandle'),
        ExternalFunction('readCallbackHandle'),
        ExternalFunction('clearCallbackHandle'),
        ExternalFunction('callHandles'),
        ExternalFunction('callNullableHandle'),
        ExternalFunction('callAsyncHandle'),
        ExternalFunction('callWideHandle', config: NAPI(bigint: true)),
        ExternalFunction('sameHandleSignature'),
        ExternalFunction('sameWideHandleSignature', config: NAPI(bigint: true)),
        ExternalFunction('sameOpaqueHandleSignature'),
        ExternalFunction('callPayloadHandles'),
        ExternalFunction('callbackHandleOrder', config: NAPI(bigint: true)),
        ExternalFunction('callbackPressure'),
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
  final archives = <String>[];
  for (final (directory, name) in [
    ('package', 'fixture'),
    ('external', 'external'),
  ]) {
    final package = '${project.path}/$directory';
    await run('npm', ['pack', '--ignore-scripts', '--silent'], cwd: package);
    final archive = await File('$package/napi-callback-$name-0.0.0.tgz')
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
  await File('test/integration/callbacks.mjs')
      .copy('${consumer.path}/test.mjs');
  final declarations = await File('test/typescript/callbacks.mts')
      .readAsString();
  await File('${consumer.path}/consumer.mts').writeAsString(
    declarations.replaceAll('/BACKEND', native ? '/native' : '/module.wasm'),
  );
  return consumer;
}
