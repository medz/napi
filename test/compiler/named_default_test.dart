import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/defaults.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

const _model = '''
import 'package:napi/napi.dart';
@NAPI() abstract class Point {
  Point._();
  int get value;
}
enum Kind { first }
int _seed() => 7;
class _Point implements Point {
  final int value;
  final Object _helper;
  const _Point._(this.value, this._helper);
}
const defaultPoint = _Point._(7, (Kind.first, <int>{1, 2}, _seed));
class Defaults {
  static const origin = _Point._(8, (Kind.first, <int>{3}, _seed));
}
''';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-named-default-');
    directory = Directory(await directory.resolveSymbolicLinks());
    addTearDown(() => directory.delete(recursive: true));
  });
  File source(String name, String contents) =>
      File('${directory.path}/$name')..writeAsStringSync(contents);
  Future<BindingModule> read(File input, {bool native = false}) =>
      AnnotationFrontend(
        packagesPath: packages,
        native: native,
      ).read(input.uri);
  Matcher rejectedDefault() => throwsA(
    isA<BindingDiagnostic>().having(
      (error) => error.code,
      'code',
      'NAPI_DEFAULT',
    ),
  );

  for (final native in [false, true]) {
    test('named defaults retain private objects and public static owners '
        '(${native ? 'native' : 'wasm'})', () async {
      final origin = source('origin.dart', '''
$_model
@NAPI() int top([Point point = defaultPoint]) => point.value;
@NAPI() int member([Point point = Defaults.origin]) => point.value;
''');
      final entry = source('entry.dart', '''
export 'origin.dart' show Point, top, member;
''');
      final module = await read(entry, native: native);
      final parameters = [
        for (final function in module.functions) function.parameters.single,
      ];
      final top = parameters[0].defaultValue as NamedObjectDefault;
      final member = parameters[1].defaultValue as NamedObjectDefault;
      expect(top.type.declaration.name, '_Point');
      expect(top.variable.library, origin.uri);
      expect(top.variable.name, 'defaultPoint');
      expect(top.variable.owner, isNull);
      expect(member.variable.name, 'origin');
      expect(member.variable.owner!.name, 'Defaults');
      expect(parameters.every((p) => p.defaultTypeIsAssignable), isTrue);
      final generated = native
          ? emitNativeDart(validateNative(module))
          : emitDart(lower(validate(module)));
      expect(generated, contains(origin.uri.toString()));
      expect(generated, contains('.defaultPoint as target.Point'));
      expect(generated, contains('.Defaults.origin as target.Point'));
      expect(generated, isNot(contains('_Point._(')));
      expect(generated, isNot(contains('Kind.first')));
      expect(generated, isNot(contains('_seed')));
    });
  }

  test(
    'private pure aliases resolve to a public const in its origin library',
    () async {
      final origin = source('origin.dart', _model);
      source('alias.dart', '''
import 'package:napi/napi.dart';
import 'origin.dart' as model;
const _first = (model.defaultPoint);
const _second = (_first);
@NAPI() int take([model.Point point = _second]) => point.value;
''');
      final entry = source('entry.dart', '''
export 'origin.dart' show Point;
export 'alias.dart' show take;
''');
      final module = await read(entry);
      final parameter = module.functions.single.parameters.single;
      final value = parameter.defaultValue as NamedObjectDefault;
      expect(parameter.defaultSource, '_second');
      expect(value.variable.library, origin.uri);
      expect(value.variable.name, 'defaultPoint');
      final generated = emitDart(lower(validate(module)));
      expect(generated, contains('.defaultPoint as target.Point'));
      expect(generated, isNot(contains('_first')));
      expect(generated, isNot(contains('_second')));
    },
  );

  test(
    'static constants with the same field name keep distinct default keys',
    () async {
      final input = source('entry.dart', '''
$_model
class First {
  static const origin = _Point._(1, Kind.first);
}
class Second {
  static const origin = _Point._(2, Kind.first);
}
@NAPI() int first([Point point = First.origin]) => point.value;
@NAPI() int second([Point point = Second.origin]) => point.value;
''');
      final module = await read(input);
      final first = module.functions[0].parameters.single;
      final second = module.functions[1].parameters.single;
      expect(
        (first.defaultValue as NamedObjectDefault).variable.name,
        (second.defaultValue as NamedObjectDefault).variable.name,
      );
      expect(parameterDefaultKey(first), isNot(parameterDefaultKey(second)));
      final generated = emitDart(lower(validate(module)));
      expect(generated, contains('.First.origin as target.Point'));
      expect(generated, contains('.Second.origin as target.Point'));
    },
  );

  for (final (name, declaration) in [
    (
      'computed private alias',
      'const _private = true ? defaultPoint : defaultPoint;',
    ),
    (
      'private const without a public origin',
      'const _private = _Point._(9, Kind.first);',
    ),
    (
      'static const with a private owner',
      'class _Private { static const origin = _Point._(9, Kind.first); } '
          'const _private = _Private.origin;',
    ),
  ]) {
    test('a $name stays diagnosed', () async {
      final input = source('entry.dart', '''
$_model
$declaration
@NAPI() int take([Point point = _private]) => point.value;
''');
      await expectLater(
        () async => validate(await read(input)),
        rejectedDefault(),
      );
    });
  }

  for (final privateConstructor in [false, true]) {
    test('${privateConstructor ? 'named' : 'constructed'} custom List objects '
        'cannot bypass container default validation', () async {
      final constructor = privateConstructor ? 'MyList._' : 'MyList';
      final input = source('entry.dart', '''
import 'package:napi/napi.dart';
@NAPI() class Base { const Base(); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class ResourceChild extends Base {
  const ResourceChild();
  void close() {}
}
class MyList implements List<Base> {
  const $constructor();
  int get length => 1;
  Base operator [](int index) => const ResourceChild();
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
const origin = $constructor();
@NAPI() int take([List<Base> values = origin]) => values.length;
''');
      for (final native in [false, true]) {
        await expectLater(read(input, native: native), rejectedDefault());
      }
    });
  }

  for (final (name, declaration) in [
    ('direct value default', '@NAPI() int take([Value value = origin]) => 7;'),
    (
      'container value default',
      '@NAPI() int take([List<Value> values = const [origin]]) => values.length;',
    ),
    (
      'value input field default',
      '''@NAPI(classPolicy: ClassPolicy.value)
class Envelope {
  final Value value;
  const Envelope({this.value = origin});
}
@NAPI() int take(Envelope input) => 7;''',
    ),
  ]) {
    test(
      '$name retains an actual resource behind an ordinary base type',
      () async {
        for (final actual in ['ResourceChild', 'Composite']) {
          final input = source('entry.dart', '''
import 'package:napi/napi.dart';
@NAPI() class Base { const Base(); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class ResourceChild extends Base {
  const ResourceChild();
  void close() {}
}
class Composite implements Base, ResourceChild {
  const Composite();
  void close() {}
}
@NAPI(classPolicy: ClassPolicy.value)
class Value {
  final Base handle;
  const Value(this.handle);
  const Value._(this.handle);
}
const origin = Value._($actual());
$declaration
''');
          for (final native in [false, true]) {
            final module = await read(input, native: native);
            final objects = [
              for (final parameter in [
                for (final function in module.functions) ...function.parameters,
                for (final binding in module.classes)
                  for (final member in binding.members)
                    if (member.kind == MemberKind.constructor)
                      ...member.parameters,
              ])
                ...defaultResourceObjects(parameter, module.classes),
            ];
            expect(objects, hasLength(1));
            expect(objects.single.type.declaration.name, actual);
            expect(objects.single.expression, isNotNull);
            if (native) {
              final plan = validateNative(module);
              expect(
                plan.needsResourceOperation(plan.functions.single),
                isTrue,
              );
              emitNativeDart(plan);
            } else {
              final plan = lower(validate(module));
              expect(
                plan.needsResourceOperation(plan.functions.single),
                isTrue,
              );
              emitDart(plan);
            }
          }
        }
      },
    );
  }

  test('a nested value field retains an actual resource subtype', () async {
    final input = source('entry.dart', '''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value)
class Base {
  final int value;
  const Base(this.value);
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class ResourceChild extends Base {
  const ResourceChild() : super(7);
  void close() {}
}
@NAPI(classPolicy: ClassPolicy.value)
class Envelope {
  final Base item;
  const Envelope(this.item);
  const Envelope._(this.item);
}
const origin = Envelope._(ResourceChild());
@NAPI() int take([Envelope value = origin]) => value.item.value;
''');
    for (final native in [false, true]) {
      final module = await read(input, native: native);
      expect(
        module.functions.single.parameters.single.defaultValue,
        isA<NamedObjectDefault>(),
      );
      expect(
        defaultResourceObjects(
          module.functions.single.parameters.single,
          module.classes,
        ).single.type.declaration.name,
        'ResourceChild',
      );
      if (native) {
        emitNativeDart(validateNative(module));
      } else {
        emitDart(lower(validate(module)));
      }
    }
  });

  test('a named const resource remains a value input field default', () async {
    final input = source('entry.dart', '''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  const Resource._();
  void close() {}
}
const resource = Resource._();
@NAPI(classPolicy: ClassPolicy.value)
class Value {
  final Resource item;
  const Value({this.item = resource});
}
@NAPI() int take(Value value) => 7;
''');
    for (final native in [false, true]) {
      final module = await read(input, native: native);
      final value = module.classes
          .singleWhere((binding) => binding.exportName == 'Value')
          .members
          .singleWhere((member) => member.kind == MemberKind.constructor)
          .parameters
          .single
          .defaultValue;
      expect(value, isA<NamedObjectDefault>());
      if (native) {
        validateNative(module);
      } else {
        validate(module);
      }
    }
  });
}
