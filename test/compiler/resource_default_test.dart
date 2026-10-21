import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/defaults.dart';
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

  for (final native in [false, true]) {
    test('built-in container defaults retain resource leaves before admission '
        '(${native ? 'native' : 'wasm'})', () async {
      final module = await read('''
@NAPI() class Child extends Resource {
  const Child([super.value = 11]);
}
const _items = <Resource?>[_default, null, Child(), _default];
@NAPI() bool containers(
  AbortSignal signal,
  int Function() callback, {
  List<Resource?>? items = _items,
  Map<Resource, Resource?> mapping = const {_default: Child(), Child(): null},
  Dictionary<Resource?> dictionary = const Dictionary({'item': _default}),
  ({Resource value, List<Resource?> items}) record = (value: _default, items: _items),
  List<Resource> empty = const <Never>[],
  required Resource supplied,
}) => identical(items, _items);
''', native: native);
      final parameters = module.functions.single.parameters;
      final items = parameters[2].defaultValue as ListDefault;
      expect(items.elements, hasLength(4));
      expect((items.elements[1] as ScalarDefault).value, isNull);
      final inherited = items.elements[2] as ObjectDefault;
      expect(inherited.type.declaration.name, 'Child');
      expect(
        inherited.supertypes.map((type) => type.declaration.name),
        contains('Resource'),
      );
      expect(parameters[3].defaultValue, isA<MapDefault>());
      expect(parameters[4].defaultValue, isA<MapDefault>());
      expect(parameters[5].defaultValue, isA<RecordDefault>());
      expect(
        constantDefaultSource(
          parameters.singleWhere((p) => p.name == 'empty').defaultValue!,
        ),
        'const <Never>[]',
      );
      if (native) {
        final plan = validateNative(module);
        final generated = emitNativeDart(plan);
        final call = plan.functions.single;
        final start = generated.indexOf('int ${call.callback}(');
        final body = generated.substring(
          start,
          generated.indexOf('\n}\n', start),
        );
        final retain = body.indexOf('operation.retain(');
        expect(retain, greaterThanOrEqualTo(0));
        expect(retain, lessThan(body.indexOf('_api.checkCallback(')));
        expect(retain, lessThan(body.indexOf('_api.abortSignal(')));
        expect(generated, contains('const <Never>[]'));
      } else {
        final plan = lower(validate(module));
        final dart = emitDart(plan);
        final javascript = emitArgumentCalls(plan);
        final call = plan.functions.single;
        final getter = '${call.coreExportName}:default:2';
        expect(dart, contains("@pragma('wasm:export', '$getter')"));
        final admission = javascript.indexOf('core["$getter"](operation)');
        expect(admission, greaterThanOrEqualTo(0));
        final body = javascript.substring(
          javascript.lastIndexOf('const call', admission),
          javascript.indexOf('\n};', admission),
        );
        final retain = body.indexOf('core["$getter"](operation)');
        final direct = body.indexOf('const reference7');
        expect(direct, greaterThanOrEqualTo(0));
        expect(direct, lessThan(retain));
        expect(retain, lessThan(body.indexOf('prepareAbortSignal(')));
        expect(retain, lessThan(body.indexOf('checkCallback(')));
        expect(body, contains('d2 ? 1 : 0'));
        expect(dart, contains('const <Never>[]'));
      }
    });
  }

  test(
    'direct references precede container defaults without callbacks',
    () async {
      final plan = lower(
        validate(
          await read('''
@NAPI() int mixed(Resource supplied, {
  List<Resource> items = const [_default],
}) => items.length;
'''),
        ),
      );
      final generated = emitArgumentCalls(plan);
      final getter = '${plan.functions.single.coreExportName}:default:1';
      final admission = generated.indexOf('core["$getter"](operation)');
      expect(admission, greaterThanOrEqualTo(0));
      final body = generated.substring(
        generated.lastIndexOf('const call', admission),
        generated.indexOf('\n};', admission),
      );
      final direct = body.indexOf('const reference0');
      expect(direct, greaterThanOrEqualTo(0));
      expect(direct, lessThan(body.indexOf('core["$getter"](operation)')));
    },
  );

  test(
    'required and null resource inputs need no Wasm default getter',
    () async {
      final plan = lower(
        validate(
          await read('''
@NAPI() Resource required(Resource resource) => resource;
@NAPI() Resource? nullable([Resource? resource]) => resource;
@NAPI() Resource? explicitNull({Resource? resource = null}) => resource;
@NAPI() List<Resource>? absentList([List<Resource>? values]) => values;
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
      '''@NAPI(classPolicy: ClassPolicy.value)
class Value {
  final Resource resource;
  const Value({this.resource = _default});
}
@NAPI() Value take(Value value) => value;''',
    ),
    (
      'value object',
      '''@NAPI(classPolicy: ClassPolicy.value)
class Value {
  final Resource resource;
  const Value(this.resource);
}
@NAPI() int take([Value value = const Value(_default)]) => value.resource.value;''',
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
