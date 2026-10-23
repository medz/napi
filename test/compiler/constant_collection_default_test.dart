import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  final collections = File('test/fixtures/constant_collections.dart')
      .absolute
      .uri;
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'napi-const-collections-',
    );
    addTearDown(() => directory.delete(recursive: true));
  });

  for (final native in [false, true]) {
    for (final external in [false, true]) {
      test('custom collection defaults retain their actual types '
          '($native, $external)', () async {
        final input = await File('${directory.path}/business.dart')
            .writeAsString('''
import 'package:napi/napi.dart';
import '$collections';
@NAPI() List<int> list([List<int> value = const ConstList([2, 3])]) => value;
@NAPI() Map<String, int> map({Map<String, int> value = const ConstMap({'a': 7})}) => value;
@NAPI() List<List<int>> nested([List<List<int>> value = const [ConstList([4])]]) => value;
''');
        final module = external
            ? await ExternalFrontend(
                const ExternalLibrary([
                  ExternalFunction('list'),
                  ExternalFunction('map'),
                  ExternalFunction('nested'),
                ]),
                packagesPath: packages,
                native: native,
              ).read(input.uri)
            : await AnnotationFrontend(
                packagesPath: packages,
                native: native,
              ).read(input.uri);
        validate(module);
        validateNative(module);
        final list = module.functions.first.parameters.single;
        expect(
          (list.defaultValue as ObjectDefault).type.declaration.name,
          'ConstList',
        );
        expect(list.defaultObjects, isNotNull);
        expect(list.defaultTypeIsAssignable, isTrue);
      });
    }
  }

  for (final element in ['Reference', 'Value', 'List<Reference>']) {
    test('computed Map values remain diagnosed ($element)', () async {
      final value = element == 'List<Reference>'
          ? '[Reference()]'
          : '$element()';
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
import '$collections';
@NAPI() class Reference { const Reference(); }
@NAPI(classPolicy: ClassPolicy.value) class Value { const Value(); }
@NAPI() int take([Map<String, $element> input = const ConstMap({'a': $value})]) => 7;
''');
      final module = await AnnotationFrontend(packagesPath: packages)
          .read(input.uri);
      final diagnostic = throwsA(
        isA<BindingDiagnostic>().having(
          (error) => error.code,
          'code',
          'NAPI_DEFAULT',
        ),
      );
      expect(() => validate(module), diagnostic);
      expect(() => validateNative(module), diagnostic);
    });
  }

  for (final accessible in [false, true]) {
    test(
      'custom collection resource leaves keep accessibility checks ($accessible)',
      () async {
        final input = await File('${directory.path}/business.dart')
            .writeAsString('''
import 'dart:collection';
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource { const Resource._(); void close() {} }
class Values with ListMixin<int> {
  const Values._() : ${accessible ? 'held' : '_held'} = const Resource._();
  final Resource ${accessible ? 'held' : '_held'};
  int get length => throw StateError('do not evaluate');
  set length(int value) => throw UnsupportedError('const');
  int operator [](int index) => throw StateError('do not evaluate');
  void operator []=(int index, int value) => throw UnsupportedError('const');
}
const values = Values._();
@NAPI() int take([List<int> input = values]) => 7;
''');
        final module = await AnnotationFrontend(packagesPath: packages)
            .read(input.uri);
        if (accessible) {
          validate(module);
          validateNative(module);
          final parameter = module.functions.single.parameters.single;
          final resources = defaultResourceObjects(parameter, module.classes);
          expect(resources.single.fieldPath, ['held']);
          expect(resources.single.expression, isA<NamedObjectDefault>());
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
            throwsA(
              isA<BindingDiagnostic>().having(
                (error) => error.code,
                'code',
                'NAPI_DEFAULT',
              ),
            ),
          );
        } else {
          final diagnostic = throwsA(
            isA<BindingDiagnostic>().having(
              (error) => error.code,
              'code',
              'NAPI_DEFAULT',
            ),
          );
          expect(() => validate(module), diagnostic);
          expect(() => validateNative(module), diagnostic);
        }
      },
    );
  }
}
