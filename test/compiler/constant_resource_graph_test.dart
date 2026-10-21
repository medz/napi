import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

const _resources = '''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  const Resource(this.id);
  final int id;
  Future<void> close() async {}
}
class _Secret extends Resource { const _Secret._() : super(11); }
''';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-default-storage-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<BindingModule> read(String source) async {
    final file = await File('${directory.path}/business.dart')
        .writeAsString(source);
    return AnnotationFrontend(
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
    ).read(file.uri);
  }

  Matcher defaultDiagnostic() => isA<BindingDiagnostic>().having(
    (error) => error.code,
    'code',
    'NAPI_DEFAULT',
  );

  test(
    'stored initializer and inherited resources replace constructor guesses',
    () async {
      final module = await read('''
$_resources
@NAPI(classPolicy: ClassPolicy.value)
class Hidden {
  const Hidden() : _resource = const Resource(1);
  final Resource _resource;
  int get value => _resource.id;
}
class Parent {
  const Parent() : stored = const Resource(2);
  final Resource stored;
}
@NAPI(classPolicy: ClassPolicy.value)
class Child extends Parent { const Child(); int get value => stored.id; }
@NAPI(classPolicy: ClassPolicy.value)
class Ignored { const Ignored(Resource unused); int get value => 3; }
@NAPI() int hidden([Hidden value = const Hidden()]) => value.value;
@NAPI() int inherited([Child value = const Child()]) => value.value;
@NAPI() int ignored([Ignored value = const Ignored(Resource(3))]) => value.value;
''');
      final plan = lower(validate(module));
      final native = validateNative(module);
      for (final name in ['hidden', 'inherited']) {
        final call = plan.functions.singleWhere(
          (f) => f.binding.exportName == name,
        );
        final objects = defaultResourceObjects(
          call.parameters.single,
          module.classes,
        );
        expect(objects, hasLength(1));
        expect(objects.single.expression, isNotNull);
        expect(plan.needsResourceOperation(call), isTrue);
        expect(
          native.needsResourceOperation(
            native.functions.singleWhere((f) => f.exportName == name),
          ),
          isTrue,
        );
      }
      final ignored = plan.functions.singleWhere(
        (f) => f.binding.exportName == 'ignored',
      );
      expect(ignored.parameters.single.defaultObjects, isNotNull);
      expect(
        defaultResourceObjects(ignored.parameters.single, module.classes),
        isEmpty,
      );
    },
  );

  test('public stored fields express private implementations; unknown IR stays guarded', () async {
    final module = await read('''
$_resources
@NAPI(classPolicy: ClassPolicy.value)
class PublicPath {
  const PublicPath() : resource = const _Secret._();
  final Resource resource;
}
@NAPI() int use([PublicPath value = const PublicPath()]) => value.resource.id;
''');
    final parameter = module.functions.single.parameters.single;
    final object = defaultResourceObjects(parameter, module.classes).single;
    expect(object.fieldPath, ['resource']);
    expect(object.expression, isNotNull);
    validate(module);
    validateNative(module);
    expect(
      () => validateParameterDefault(
        ParameterBinding(
          parameter.name,
          parameter.type,
          kind: parameter.kind,
          defaultValue: parameter.defaultValue,
          defaultTypeIsAssignable: parameter.defaultTypeIsAssignable,
        ),
        module.functions.single.source,
        referenceClasses: module.classes,
        allowResourceDefaults: true,
      ),
      throwsA(defaultDiagnostic()),
    );
  });

  for (final getter in [false, true]) {
    test(
      'unnameable private resource ${getter ? 'getters' : 'fields'} stay diagnosed',
      () async {
        final module = await read('''
$_resources
@NAPI(classPolicy: ClassPolicy.value)
class Hidden {
  const Hidden() : _resource = const _Secret._();
  final Resource _resource;
  ${getter ? 'Resource get resource => _resource;' : 'int get value => _resource.id;'}
}
@NAPI() int use([Hidden value = const Hidden()]) => 1;
''');
        expect(() => validate(module), throwsA(defaultDiagnostic()));
        expect(() => validateNative(module), throwsA(defaultDiagnostic()));
      },
    );
  }

  test(
    'value field defaults require operations without public reference leaves',
    () async {
      const source =
          '''
$_resources
@NAPI(classPolicy: ClassPolicy.value)
class Hidden {
  const Hidden() : _resource = const Resource(1);
  final Resource _resource;
  int get value => _resource.id;
}
@NAPI(classPolicy: ClassPolicy.value)
class Input {
  const Input({Hidden hidden = const Hidden()}) : _hidden = hidden;
  final Hidden _hidden;
  int get value => _hidden.value;
}
@NAPI() int use(Input value) => value.value;
''';
      final module = await read(source);
      final plan = lower(validate(module));
      final call = plan.functions.single;
      expect(
        conversionGraph(call.inputs).whereType<ReferenceConversion>(),
        isEmpty,
      );
      expect(plan.needsResourceOperation(call), isTrue);
      expect(call.representation, ExportRepresentation.callableGlobal);
      final native = validateNative(module);
      expect(native.needsResourceOperation(native.functions.single), isTrue);

      final lazy = await read('''
$source
@NAPI() int Function(Input) callback() => (value) => value.value;
@NAPI() JsArray<Input> array(JsArray<Input> values) => values;
''');
      final lazyPlan = lower(validate(lazy));
      final lazyNative = validateNative(lazy);
      expect(lazyPlan.hasResourceCallbacks, isTrue);
      expect(lazyPlan.hasResourceCollections, isTrue);
      expect(lazyNative.hasResourceCallbacks, isTrue);
      expect(lazyNative.hasResourceCollections, isTrue);
    },
  );

  for (final concrete in [false, true]) {
    test(
      'stored generic resource needs ${concrete ? 'its selected alias' : 'a concrete runtime view'}',
      () async {
        final module = await read('''
import 'package:napi/napi.dart';
${concrete ? '' : "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')"}
class Resource<T> {
  const Resource();
  Future<void> close() async {}
}
${concrete ? "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') typedef IntResource = Resource<int>;" : ''}
@NAPI(classPolicy: ClassPolicy.value)
class Hidden {
  const Hidden() : _resource = const Resource<int>();
  final Resource<int> _resource;
  int get value => 1;
}
@NAPI() int use([Hidden value = const Hidden()]) => value.value;
''');
        if (concrete) {
          validate(module);
          validateNative(module);
        } else {
          expect(() => validate(module), throwsA(defaultDiagnostic()));
          expect(() => validateNative(module), throwsA(defaultDiagnostic()));
        }
      },
    );
  }
}
