import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

const _resource = '''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  final int value;
  const Resource([this.value = 7]);
  void close() {}
}
const _default = Resource();
''';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-resource-default-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<BindingModule> read(String source, {bool native = false}) async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString('''
import 'package:napi/napi.dart';
$_resource
$source
''');
    return AnnotationFrontend(
      packagesPath: packages,
      native: native,
    ).read(input.uri);
  }

  for (final native in [false, true]) {
    test('direct const resource defaults are retained before signal admission '
        '(${native ? 'native' : 'wasm'})', () async {
      final module = await read('''
@NAPI() Resource take([Resource resource = _default]) => resource;
@NAPI() int admission(
  AbortSignal signal,
  int Function() callback, {
  Resource resource = _default,
}) => resource.value;
@NAPI() class Holder {
  Holder();
  Resource take({Resource resource = _default}) => resource;
}
''', native: native);
      if (native) {
        final plan = validateNative(module);
        final generated = emitNativeDart(plan);
        final call = plan.functions.singleWhere(
          (call) => call.exportName == 'admission',
        );
        final start = generated.indexOf('int ${call.callback}(');
        final body = generated.substring(
          start,
          generated.indexOf('\n}\n', start),
        );
        final defaultBranch = body.indexOf('if (default2)');
        final explicitBranch = body.indexOf('} else {', defaultBranch);
        final retain = body.indexOf(
          'operation.retain(_resourceControl(reference2))',
          defaultBranch,
        );
        expect(retain, greaterThan(defaultBranch));
        expect(retain, lessThan(explicitBranch));
        expect(retain, lessThan(body.indexOf('_api.checkCallback(')));
        expect(retain, lessThan(body.indexOf('_api.abortSignal(')));
        expect(generated, contains('target.take(a0)'));
        expect(generated, contains('object.take(resource: a0)'));
      } else {
        final plan = lower(validate(module));
        final dart = emitDart(plan);
        final javascript = emitArgumentCalls(plan);
        final call = plan.functions.singleWhere(
          (call) => call.binding.exportName == 'admission',
        );
        final getter = '${call.coreExportName}:default:2';
        expect(dart, contains("@pragma('wasm:export', '$getter')"));
        final getterCall = javascript.indexOf('core["$getter"]()');
        expect(getterCall, greaterThanOrEqualTo(0));
        final body = javascript.substring(
          javascript.lastIndexOf('const call', getterCall),
          javascript.indexOf('\n};', getterCall),
        );
        final reference = body.indexOf('const reference2');
        final retain = body.indexOf('retainResourceReference(');
        expect(retain, greaterThanOrEqualTo(reference));
        expect(retain, lessThan(body.indexOf('prepareAbortSignal(')));
        expect(retain, lessThan(body.indexOf('checkCallback(')));
        expect(body, contains('d2 ? 1 : 0'));
        expect(dart, contains('target.take(a0)'));
        expect(dart, contains('object.take(resource: a0)'));
      }
    });
  }

  test(
    'required and null resource inputs need no Wasm default getter',
    () async {
      final plan = lower(
        validate(
          await read('''
@NAPI() Resource required(Resource resource) => resource;
@NAPI() Resource? nullable([Resource? resource]) => resource;
@NAPI() Resource? explicitNull({Resource? resource = null}) => resource;
'''),
        ),
      );
      final dart = emitDart(plan);
      final javascript = emitArgumentCalls(plan);
      for (final call in plan.functions) {
        expect(dart, isNot(contains('${call.coreExportName}:default:')));
        expect(javascript, isNot(contains('${call.coreExportName}:default:')));
      }
    },
  );

  for (final (name, declaration) in [
    (
      'value constructor field',
      '''@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class Value {
  final Resource resource;
  const Value({this.resource = _default});
}
@NAPI() Value take(Value value) => value;''',
    ),
    (
      'list',
      '@NAPI() int take([List<Resource> resources = const [_default]]) => resources.length;',
    ),
    (
      'record',
      '@NAPI() int take([({Resource resource}) value = (resource: _default)]) => value.resource.value;',
    ),
  ]) {
    test('resource $name defaults remain diagnosed', () async {
      for (final native in [false, true]) {
        await expectLater(
          () async {
            final module = await read(declaration, native: native);
            if (native) {
              validateNative(module);
            } else {
              validate(module);
            }
          },
          throwsA(
            isA<BindingDiagnostic>().having(
              (error) => error.code,
              'code',
              'NAPI_DEFAULT',
            ),
          ),
        );
      }
    });
  }
}
