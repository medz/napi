import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-wasm-opaque-');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<ModulePlan> plan(String source) async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString(source);
    return lower(
      validate(
        await AnnotationFrontend(packagesPath: _packages).read(input.uri),
      ),
    );
  }

  test(
    'opaque functions and classes compile with actual carrier arguments',
    () async {
      final module = await plan('''
import 'package:napi/napi.dart';
@NAPI()
class Router<T> {
  Router([this.value]);
  Router.empty() : value = null;
  T? value;
  T identity(T next) => next;
  T? optional([T? next]) => next;
  T? named({required T? next}) => next;
  Router<T> same() => this;
  static int count() => 3;
}
@NAPI() T identity<T>(T value) => value;
@NAPI() T? optional<T>([T? value]) => value;
@NAPI() Router<T> reference<T>(Router<T> value) => value;
@NAPI() Future<int> pending<T>(T value) => Future.value(4);
''');
      final code = emitDart(module);
      expect(code, contains('final WasmExternRef? value;'));
      expect(code, contains('target.identity<_NapiHostValue>(a0)'));
      expect(code, contains('target.Router<_NapiHostValue>(a0)'));
      expect(code, contains('target.Router<_NapiHostValue>.empty()'));
      expect(code, contains('object is target.Router<_NapiHostValue>'));
      expect(code, contains('as target.Router<_NapiHostValue>'));
      expect(code, contains('target.Router.count()'));
      expect(code, isNot(contains('target.Router<_NapiHostValue>.count()')));
      expect(code, contains('a0 = _NapiHostValue(p0);'));
      expect(code, contains('return value.value;'));
      expect(
        code,
        contains('WasmAnyRef.fromObject(<Object?>[a0]).externalize()'),
      );
      final calls = emitArgumentCalls(module);
      expect(calls, contains('"opaqueRequired"'));
      expect(calls, contains('"opaqueOptional"'));
      expect(calls, contains('arguments.length === 0 ? [] : [value]'));
      final entry = File('${directory.path}/entrypoint.dart');
      await entry.writeAsString(code);
      final compiled = await DartSdkAdapter().compile(
        sourcePath: entry.path,
        outputPath: '${directory.path}/module.wasm',
        packagesPath: _packages,
      );
      expect(File(compiled.wasmPath).lengthSync(), greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'phantom opaque parameters still instantiate their Dart carrier',
    () async {
      final code = emitDart(
        await plan('''
import 'package:napi/napi.dart';
@NAPI() class Marker<T> { Marker(); }
@NAPI() int value<T>() => 3;
'''),
      );
      expect(code, contains('final class _NapiHostValue'));
      expect(code, contains('target.Marker<_NapiHostValue>()'));
      expect(code, contains('target.value<_NapiHostValue>()'));
      final entry = File('${directory.path}/entrypoint.dart');
      await entry.writeAsString(code);
      await DartSdkAdapter().compile(
        sourcePath: entry.path,
        outputPath: '${directory.path}/module.wasm',
        packagesPath: _packages,
      );
    },
  );

  test('ordinary modules do not emit opaque storage', () async {
    final code = emitDart(
      await plan('''
import 'package:napi/napi.dart';
@NAPI() int value(int number) => number;
'''),
    );
    expect(code, isNot(contains('_NapiHostValue')));
    expect(code, contains('target.value(a0)'));
  });
}
