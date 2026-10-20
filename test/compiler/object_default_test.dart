import 'dart:io';

import 'package:napi/napi.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/defaults.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-object-default-');
    directory = Directory(await directory.resolveSymbolicLinks());
    addTearDown(() => directory.delete(recursive: true));
  });
  File source(String name, String contents) =>
      File('${directory.path}/$name')..writeAsStringSync(contents);
  Future<BindingModule> read(
    File input, {
    bool native = false,
    ExternalLibrary? selections,
  }) => selections == null
      ? AnnotationFrontend(
          packagesPath: packages,
          native: native,
        ).read(input.uri)
      : ExternalFrontend(
          selections,
          packagesPath: packages,
          native: native,
        ).read(input.uri);
  Matcher defaultDiagnostic([String? message]) => isA<BindingDiagnostic>()
      .having((error) => error.code, 'code', 'NAPI_DEFAULT')
      .having(
        (error) => error.message,
        'message',
        message == null ? isNotEmpty : contains(message),
      );

  for (final native in [false, true]) {
    for (final external in [false, true]) {
      test(
        'private imported object defaults survive reexports '
        '(${native ? 'native' : 'wasm'}, ${external ? 'external' : 'annotation'})',
        () async {
          final token = source('token.dart', '''
class Token {
  final String text;
  const Token(this.text);
}
''');
          final point = source('point.dart', '''
import 'package:napi/napi.dart';
import 'token.dart';
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class Point {
  final int x;
  final String label;
  final Token? _token;
  const Point(this.x, {this.label = 'point'}) : _token = null;
  @NAPI(exclude: true)
  const Point.tagged(this.x, this._token) : label = 'tagged';
}
''');
          source('origin.dart', '''
import 'package:napi/napi.dart';
import 'point.dart' as model;
import 'token.dart' as tokens;
const _private = model.Point.tagged(3 + 4, tokens.Token('ready'));
@NAPI() int run([model.Point point = _private]) => point.x;
''');
          final entry = source('entry.dart', '''
export 'point.dart' show Point;
export 'origin.dart' show run;
''');
          final module = await read(
            entry,
            native: native,
            selections: external
                ? const ExternalLibrary([
                    ExternalClass(
                      'Point',
                      config: NAPI(
                        classPolicy: ClassPolicy.value,
                        valueConstructor: 'new',
                      ),
                      members: [
                        ExternalMember.constructor(
                          'tagged',
                          config: NAPI(exclude: true),
                        ),
                      ],
                    ),
                    ExternalFunction('run'),
                  ])
                : null,
          );
          final parameter = module.functions.single.parameters.single;
          expect(parameter.defaultSource, '_private');
          final value = parameter.defaultValue as ObjectDefault;
          expect(value.constructor.library, point.uri);
          expect(value.constructor.name, 'tagged');
          expect((value.positional.first as ScalarDefault).value, 7);
          expect(
            (value.positional.last as ObjectDefault).constructor.library,
            token.uri,
          );
          expect(
            constantDefaultSource(
              value,
              declarationSource: (declaration) =>
                  'defaults.${declaration.name}',
            ),
            'const defaults.Point.tagged(7, const defaults.Token("ready"))',
          );
          final generated = native
              ? emitNativeDart(validateNative(module))
              : emitDart(lower(validate(module)));
          expect(generated, contains(token.uri.toString()));
          expect(generated, contains('.Point.tagged(7, const '));
          expect(generated, contains('.Token("ready")'));
          expect(generated, isNot(contains('_private')));
        },
      );
    }

    test('redirected const defaults name the public factory '
        '(${native ? 'native' : 'wasm'})', () async {
      final input = source('entry.dart', '''
import 'package:napi/napi.dart';
@NAPI() abstract class Point {
  const factory Point(int x) = _Point;
  int get x;
}
class _Point implements Point {
  final int x;
  const _Point(this.x);
}
const _origin = Point(7);
@NAPI() int run([Point point = _origin]) => point.x;
''');
      final module = await read(input, native: native);
      final value =
          module.functions.single.parameters.single.defaultValue
              as ObjectDefault;
      expect(value.type.declaration.name, '_Point');
      expect(value.constructorType.declaration.name, 'Point');
      expect(value.constructor.owner, value.constructorType.declaration);
      expect(value.constructor.name, 'new');
      final generated = native
          ? emitNativeDart(validateNative(module))
          : emitDart(lower(validate(module)));
      expect(generated, contains('.Point(7)'));
      expect(generated, isNot(contains('._Point(')));
    });

    test('covariant defaults retain unselected public element types '
        '(${native ? 'native' : 'wasm'})', () async {
      final input = source('entry.dart', '''
import 'package:napi/napi.dart';
@NAPI() class Base {
  final int value;
  const Base(this.value);
}
class Derived extends Base {
  const Derived(super.value);
}
@NAPI() int run([
  List<Base> values = const <Derived>[Derived(7)],
  List<Base> empty = const <Derived>[],
  List<List<Base>> nested = const <List<Derived>>[<Derived>[Derived(8)]],
  Map<String, Base> points = const <String, Derived>{'point': Derived(9)},
]) => values.single.value + empty.length + nested.single.single.value +
    points['point']!.value;
''');
      final module = await read(input, native: native);
      final parameters = module.functions.single.parameters;
      expect(module.classes.map((c) => c.exportName), ['Base']);
      expect(parameters.every((p) => p.defaultTypeIsAssignable), isTrue);
      final generated = native
          ? emitNativeDart(validateNative(module))
          : emitDart(lower(validate(module)));
      expect(generated, contains('.Derived(7)'));
      final parameter = parameters.first;
      expect(
        () => validateParameterDefault(
          ParameterBinding(
            parameter.name,
            parameter.type,
            kind: parameter.kind,
            defaultValue: parameter.defaultValue,
            defaultIdentity: parameter.defaultIdentity,
          ),
          module.functions.single.source,
          referenceClasses: module.classes,
        ),
        throwsA(defaultDiagnostic()),
      );
      expect(
        () => validateParameterDefault(
          ParameterBinding(
            parameter.name,
            parameter.type,
            kind: parameter.kind,
            defaultValue: ListDefault(
              (parameter.defaultValue as ListDefault).type,
              [const ScalarDefault('wrong element')],
            ),
            defaultTypeIsAssignable: true,
          ),
          module.functions.single.source,
          referenceClasses: module.classes,
        ),
        throwsA(defaultDiagnostic()),
      );
    });

    test('direct resource defaults retain before later input conversion '
        '(${native ? 'native' : 'wasm'})', () async {
      final input = source('entry.dart', '''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Point {
  const Point();
  void close([Point other = const Point()]) {}
}
@NAPI() bool run([Point? point = const Point(), int Function()? callback]) =>
    point != null;
''');
      final module = await read(input, native: native);
      final parameter = module.functions.single.parameters.first;
      expect(
        () => validateParameterDefault(
          parameter,
          module.functions.single.source,
          referenceClasses: module.classes,
        ),
        throwsA(defaultDiagnostic()),
      );
      final generated = native
          ? emitNativeDart(validateNative(module))
          : emitDart(lower(validate(module)));
      if (native) {
        final lease = generated.indexOf(
          'if (reference0 != null) operation.retain(_resourceControl(reference0))',
        );
        expect(lease, greaterThan(0));
        expect(lease, lessThan(generated.indexOf('_api.checkCallback(')));
        expect(generated, contains('ResourceOperation(exempt: control)'));
        expect(
          generated,
          contains('operation.retain(_resourceControl(reference0))'),
        );
      }
    });
  }

  test('default comparison retains constructor library identity', () async {
    final parameters = <ParameterBinding>[];
    for (final name in ['first', 'second']) {
      final input = source('$name.dart', '''
import 'package:napi/napi.dart';
@NAPI() class Point {
  final int x;
  const Point(this.x);
}
@NAPI() int run([Point point = const Point(7)]) => point.x;
''');
      final module = await read(input);
      parameters.add(module.functions.single.parameters.single);
    }
    String syntax(ParameterBinding parameter) => constantDefaultSource(
      parameter.defaultValue!,
      declarationSource: (declaration) => declaration.name,
    );
    expect(syntax(parameters.first), syntax(parameters.last));
    expect(
      parameterDefaultKey(parameters.first),
      isNot(parameterDefaultKey(parameters.last)),
    );
  });

  for (final (name, declaration, defaultValue) in [
    (
      'private constructor',
      '''@NAPI() class Point {
  final int x;
  const Point._(this.x);
}''',
      'Point._(7)',
    ),
    (
      'function-valued constructor argument',
      '''int seed() => 7;
@NAPI() class Point {
  final int x;
  const Point(this.x);
  @NAPI(exclude: true)
  const Point.callback(int Function() callback) : x = 7;
}''',
      'Point.callback(seed)',
    ),
    (
      'enum-valued constructor argument',
      '''enum Kind { one }
@NAPI() class Point {
  final int x;
  const Point(this.x);
  @NAPI(exclude: true)
  const Point.kind(Kind kind) : x = 7;
}''',
      'Point.kind(Kind.one)',
    ),
  ]) {
    test('rejects a $name default', () async {
      final input = source('entry.dart', '''
import 'package:napi/napi.dart';
$declaration
@NAPI() bool run([Point point = const $defaultValue]) => true;
''');
      for (final native in [false, true]) {
        await expectLater(() async {
          final module = await read(input, native: native);
          if (native) {
            validateNative(module);
          } else {
            validate(module);
          }
        }, throwsA(defaultDiagnostic()));
      }
    });
  }

  for (final (name, declaration) in [
    (
      'containers',
      '@NAPI() bool run([List<Point> points = const [Point()]]) => true;',
    ),
    (
      'value constructors',
      '''@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class Holder {
  final Point point;
  const Holder({this.point = const Point()});
}''',
    ),
  ]) {
    test('resource defaults remain unsupported in $name', () async {
      final input = source('entry.dart', '''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Point {
  const Point();
  void close() {}
}
$declaration
''');
      for (final native in [false, true]) {
        final module = await read(input, native: native);
        expect(
          () => native ? validateNative(module) : validate(module),
          throwsA(defaultDiagnostic()),
        );
      }
    });
  }

  test('object constructor graphs share the constant depth limit', () async {
    final input = source(
      'entry.dart',
      [
        "import 'package:napi/napi.dart';",
        '@NAPI() class Node { final Node? next; const Node(this.next); }',
        'const n0 = Node(null);',
        for (var i = 1; i <= 65; i++) 'const n$i = Node(n${i - 1});',
        '@NAPI() bool run([Node node = n65]) => true;',
      ].join('\n'),
    );
    await expectLater(read(input), throwsA(defaultDiagnostic('depth 64')));
  });
}
