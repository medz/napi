import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/defaults.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_aot_adapter.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

const _resource = '''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  const Resource(this.id);
  final int id;
  void close() {}
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Handle {
  const Handle._();
  int get id;
  void close();
}
class _Handle extends Handle {
  const _Handle(this.id) : super._();
  final int id;
  void close() {}
}
''';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-default-storage-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<ParameterBinding> read(String source) async {
    final input = await File('${directory.path}/business.dart')
        .writeAsString(source);
    final module = await AnnotationFrontend(packagesPath: packages)
        .read(input.uri);
    return module.functions.single.parameters.single;
  }

  String source(DefaultObjectBinding object) => constantDefaultSource(
    object.expression!,
    declarationSource: (declaration) => declaration.name,
  );
  DefaultObjectBinding handle(ParameterBinding parameter) => parameter
      .defaultObjects!
      .singleWhere((object) => object.type.declaration.name == '_Handle');

  test('stored initializers replace ignored constructor arguments', () async {
    final parameter = await read('''
$_resource
@NAPI(classPolicy: ClassPolicy.value)
class Value {
  const Value(Object ignored) : held = const Resource(1);
  final Resource held;
}
@NAPI() int take([Value value = const Value(Resource(9))]) => value.held.id;
''');
    final objects = parameter.defaultObjects!;
    expect(objects.map((object) => object.type.declaration.name), [
      'Value',
      'Resource',
    ]);
    expect(source(objects.last), 'const Resource(1)');
    expect(source(objects.last), isNot(contains('(9)')));
  });

  test(
    'inherited state is scanned without inventing a superclass object',
    () async {
      final parameter = await read('''
$_resource
class Child extends Resource { const Child(super.id); }
@NAPI() int take([Resource value = const Child(7)]) => value.id;
''');
      final objects = parameter.defaultObjects!;
      expect(objects.map((object) => object.type.declaration.name), ['Child']);
      expect(
        objects.single.supertypes.any(
          (type) => type.declaration.name == 'Resource',
        ),
        isTrue,
      );
      expect(source(objects.single), 'const Child(7)');
    },
  );

  test(
    'a public const exposes real nullable fields through its interface',
    () async {
      final parameter = await read('''
$_resource
@NAPI(classPolicy: ClassPolicy.value)
abstract class Value { Handle? get held; }
class _Value implements Value {
  const _Value(this.held);
  final Handle? held;
}
const Value origin = _Value(_Handle(3));
@NAPI() int take([Value value = origin]) => value.held!.id;
''');
      final leaf = handle(parameter);
      expect(source(leaf), 'origin');
      expect(leaf.fieldPath, ['held!']);
    },
  );

  test('a private stored leaf can use its own public const binding', () async {
    final parameter = await read('''
$_resource
const publicHandle = _Handle(4);
@NAPI(classPolicy: ClassPolicy.value)
class Value {
  const Value() : _held = publicHandle;
  final Handle _held;
  int get id => _held.id;
}
@NAPI() int take([Value value = const Value()]) => value.id;
''');
    final leaf = handle(parameter);
    expect(source(leaf), 'publicHandle');
    expect(leaf.fieldPath, isEmpty);
  });

  test('a later public alias can name an equal private stored leaf', () async {
    final parameter = await read('''
$_resource
const publicHandle = _Handle(4);
@NAPI(classPolicy: ClassPolicy.value)
class Value {
  const Value() : _first = const _Handle(4), _second = publicHandle;
  final Handle _first;
  final Handle _second;
}
@NAPI() int take([Value value = const Value()]) => 1;
''');
    final leaf = handle(parameter);
    expect(source(leaf), 'publicHandle');
  });

  test(
    'nullable public const resource leaves compile in both backends',
    () async {
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  const Resource._();
  void close() {}
}
const Resource? defaultResource = Resource._();
@NAPI(classPolicy: ClassPolicy.value)
class Value {
  const Value({this.owner = defaultResource});
  final Resource? owner;
}
class _PrivateResource extends Resource { const _PrivateResource() : super._(); }
@NAPI(classPolicy: ClassPolicy.value)
class Root {
  const Root(this.held);
  final Resource? held;
}
const Root? publicRoot = Root(_PrivateResource());
@NAPI(classPolicy: ClassPolicy.value)
class NestedValue {
  const NestedValue({this.root = publicRoot});
  final Root? root;
}
@NAPI() bool take(Value value) => value.owner != null;
@NAPI() bool optional([Resource? value = defaultResource]) => value != null;
@NAPI() bool nested(NestedValue value) => value.root?.held != null;
@NAPI() bool optionalRoot([Root? value = publicRoot]) => value?.held != null;
''');
      for (final native in [false, true]) {
        final module = await AnnotationFrontend(
          packagesPath: packages,
          native: native,
        ).read(input.uri);
        final constructor = module.classes
            .singleWhere((binding) => binding.exportName == 'Value')
            .members
            .singleWhere((member) => member.kind == MemberKind.constructor);
        final leaf = constructor.parameters.single.defaultObjects!.single;
        expect(leaf.type.nullability, TypeNullability.nonNullable);
        expect(source(leaf), 'defaultResource');
        expect(leaf.expression, isA<NamedObjectDefault>());
        expect(leaf.expressionNullable, isTrue);
        expect(leaf.fieldPath, isEmpty);
        final nested = module.classes
            .singleWhere((binding) => binding.exportName == 'NestedValue')
            .members
            .singleWhere((member) => member.kind == MemberKind.constructor)
            .parameters
            .single
            .defaultObjects!
            .singleWhere(
              (object) => object.type.declaration.name == '_PrivateResource',
            );
        expect(source(nested), 'publicRoot');
        expect(nested.expressionNullable, isTrue);
        expect(nested.fieldPath, ['held!']);
        final generated = native
            ? emitNativeDart(validateNative(module))
            : emitDart(lower(validate(module)));
        final entry = await File(
          '${directory.path}/entry-${native ? 'native' : 'wasm'}.dart',
        ).writeAsString(generated);
        if (native) {
          await DartAotAdapter().compile(
            sourcePath: entry.path,
            outputPath: '${directory.path}/module.aot',
            packagesPath: packages,
          );
        } else {
          await DartSdkAdapter().compile(
            sourcePath: entry.path,
            outputPath: '${directory.path}/module.wasm',
            packagesPath: packages,
          );
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'an overriding business getter does not expose inherited storage',
    () async {
      final parameter = await read('''
$_resource
class Parent {
  const Parent(this.held);
  final Handle held;
}
@NAPI(classPolicy: ClassPolicy.value)
class Value extends Parent {
  const Value() : super(const _Handle(5));
  Handle get held => throw StateError('must not run');
}
@NAPI() int take([Value value = const Value()]) => 1;
''');
      expect(handle(parameter).expression, isNull);
    },
  );

  test(
    'enum, Set and function helpers are scanned without running code',
    () async {
      final parameter = await read('''
$_resource
enum Kind { first }
int _seed() => throw StateError('must not run');
@NAPI(classPolicy: ClassPolicy.value)
class Value {
  const Value() : _helper = (Kind.first, const {Resource(6)}, _seed);
  final Object _helper;
  Resource get computed => throw StateError('must not run');
}
@NAPI() int take([Value value = const Value()]) => 1;
''');
      final objects = parameter.defaultObjects!;
      expect(
        objects.any((object) => object.type.declaration.name == 'Kind'),
        isTrue,
      );
      final resource = objects.singleWhere(
        (object) => object.type.declaration.name == 'Resource',
      );
      expect(source(resource), 'const Resource(6)');
      expect(resource.fieldPath, isEmpty);
    },
  );

  for (final (name, body) in [
    (
      'private stored field',
      '''
@NAPI(classPolicy: ClassPolicy.value)
class Value {
  const Value() : _held = const _Handle(7);
  final Handle _held;
}
@NAPI() int take([Value value = const Value()]) => 1;
''',
    ),
    (
      'missing interface field',
      '''
@NAPI(classPolicy: ClassPolicy.value) abstract class Value {}
class _Value implements Value {
  const _Value(this.held);
  final Handle held;
}
const Value origin = _Value(_Handle(8));
@NAPI() int take([Value value = origin]) => 1;
''',
    ),
  ]) {
    test('$name retains an inaccessible leaf instead of dropping it', () async {
      final parameter = await read('$_resource\n$body');
      expect(parameter.defaultObjects, isNotNull);
      expect(handle(parameter).expression, isNull);
    });
  }

  test(
    'nullable public const roots expose their known non-null storage',
    () async {
      final parameter = await read('''
$_resource
@NAPI(classPolicy: ClassPolicy.value) abstract class Value { Handle get held; }
class _Value implements Value {
  const _Value(this.held);
  final Handle held;
}
const Value? origin = _Value(_Handle(9));
@NAPI() int take([Value? value = origin]) => 1;
''');
      final leaf = handle(parameter);
      expect(source(leaf), 'origin');
      expect(leaf.expressionNullable, isTrue);
      expect(leaf.fieldPath, ['held']);
    },
  );

  test('scalar defaults distinguish a completed scan from no default', () async {
    final scalar = await read(
      "import 'package:napi/napi.dart'; @NAPI() int take([int value = 7]) => value;",
    );
    final required = await read(
      "import 'package:napi/napi.dart'; @NAPI() int take(int value) => value;",
    );
    expect(scalar.defaultObjects, isEmpty);
    expect(required.defaultObjects, isNull);
  });
}
