import 'dart:io';

import 'package:napi/napi.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'napi concrete callable ',
    );
    addTearDown(() => directory.delete(recursive: true));
  });
  File source(String text, [String name = 'entry.dart']) =>
      File('${directory.path}/$name')..writeAsStringSync(text);
  Future<BindingModule> read(File input, bool native, {String? selected}) =>
      (selected == null
              ? AnnotationFrontend(packagesPath: _packages, native: native)
              : ExternalFrontend(
                  ExternalLibrary([ExternalFunction(selected)]),
                  packagesPath: _packages,
                  native: native,
                ))
          .read(input.uri);
  Matcher diagnostic(String code) =>
      isA<BindingDiagnostic>().having((error) => error.code, 'code', code);

  const business = '''
import 'package:napi/napi.dart';
T _read<T extends num>(T value, {int count = 7}) => value;
String _kind<T>() => T.toString();
typedef ReadInteger = int Function(int value, {int count});
/// An explicit integer specialization.
@NAPI(name: 'readInteger')
const ReadInteger readInt = _read<int>;
@NAPI()
const readDouble = _read<double>;
@NAPI()
const intKind = _kind<int>;
@NAPI(bigint: true)
const readBigint = _read<int>;
class Utility {
  static T read<T>(T value, [int count = 17]) => value;
}
@NAPI()
const readText = Utility.read<String>;
''';
  for (final native in [false, true]) {
    test('closed callable signatures and defaults ($native SDK)', () async {
      final input = source(business);
      final module = await read(input, native);
      expect(module.functions, hasLength(5));
      final integer = module.functions.first;
      expect(integer.declaration.kind, DeclarationKind.variable);
      expect(integer.callPath, 'readInt');
      expect(integer.exportName, 'readInteger');
      expect(integer.typeParameters, isEmpty);
      expect(integer.result, isA<SafeIntType>());
      expect(integer.parameters.first.type, isA<SafeIntType>());
      expect(integer.parameters.last.kind, ParameterKind.optionalNamed);
      expect(integer.parameters.last.defaultValue!.value, 7);
      expect(integer.parameters.last.defaultSource, '7');
      expect(
        integer.documentation,
        contains('explicit integer specialization'),
      );
      expect(integer.source.uri, input.uri);
      expect(
        input.readAsStringSync().substring(integer.source.offset),
        startsWith('readInt'),
      );
      expect(module.functions[1].parameters.last.defaultValue!.value, 7);
      expect(module.functions[3].bigint, isTrue);
      expect(module.functions.last.parameters.last.defaultValue!.value, 17);
      final plan = lower(validate(module));
      final vm = validateNative(module);
      expect(emitDeclarations(plan), emitNativeDeclarations(vm));
      expect(emitDeclarations(plan), contains('readInteger: (value: number'));
      expect(emitDeclarations(plan), contains('readBigint: (value: bigint'));
      for (final code in [emitDart(plan), emitNativeDart(vm)]) {
        expect(code, contains('target.readInt('));
        expect(code, contains('target.readText('));
        expect(code, isNot(contains('target._read')));
        expect(code, isNot(contains('target.Utility')));
      }
      final external = await ExternalFrontend(
        const ExternalLibrary([
          ExternalFunction('readInt', config: NAPI(name: 'readInteger')),
          ExternalFunction('readDouble'),
          ExternalFunction('intKind'),
          ExternalFunction('readBigint', config: NAPI(bigint: true)),
          ExternalFunction('readText'),
        ]),
        packagesPath: _packages,
        native: native,
      ).read(input.uri);
      expect(
        emitDeclarations(lower(validate(external))),
        emitDeclarations(plan),
      );
    });

    test(
      'parts, reexports and imported static targets ($native SDK)',
      () async {
        source('''
class Utility { static T read<T>(T value, [int count = 19]) => value; }
''', 'origin.dart');
        source('''
import 'package:napi/napi.dart';
import 'origin.dart' as original;
part 'selected.dart';
''', 'library.dart');
        final part = source('''
part of 'library.dart';
@NAPI()
const selected = original.Utility.read<int>;
''', 'selected.dart');
        final input = source("export 'library.dart' show selected;");
        for (final name in [null, 'selected']) {
          final module = await read(input, native, selected: name);
          final binding = module.functions.single;
          expect(binding.callPath, 'selected');
          expect(binding.source.uri, part.uri);
          expect(binding.declaration.library.path, endsWith('/library.dart'));
          expect(binding.exportSurface, input.uri);
          expect(binding.parameters.last.defaultValue!.value, 19);
          validate(module);
          validateNative(module);
        }
      },
    );

    test(
      'resolved nested, nullable and typedef arguments ($native SDK)',
      () async {
        final input = source('''
import 'package:napi/napi.dart';
T read<T>(T value) => value;
typedef Item = ({int value, String? label});
@NAPI() const selected = read<List<Item?>>;
''');
        final module = await read(input, native);
        final list =
            module.functions.single.parameters.single.type as DeclaredType;
        final item = list.typeArguments.single as RecordTypeBinding;
        expect(item.nullability, TypeNullability.nullable);
        expect(item.named['value'], isA<SafeIntType>());
        expect(item.named['label']!.nullability, TypeNullability.nullable);
        validate(module);
        validateNative(module);
      },
    );
  }

  final invalid = <String, (String, String)>{
    'final': (
      'T read<T>(T value) => value; final selected = read<int>;',
      'NAPI_CALLABLE',
    ),
    'mutable': (
      'T read<T>(T value) => value; var selected = read<int>;',
      'NAPI_CALLABLE',
    ),
    'open': (
      'T read<T>(T value) => value; const selected = read;',
      'NAPI_CALLABLE',
    ),
    'inferred': (
      'T read<T>(T value) => value; const int Function(int) selected = read;',
      'NAPI_CALLABLE',
    ),
    'dynamic': (
      'T read<T>(T value) => value; const selected = read<dynamic>;',
      'NAPI_GENERIC',
    ),
    'open nested type': (
      'T read<T>() => throw StateError(\'\'); const selected = read<List>;',
      'NAPI_GENERIC',
    ),
    'generic function argument': (
      'String kind<T>() => T.toString(); const selected = kind<T Function<T>(T)>;',
      'NAPI_GENERIC',
    ),
    'alias chain': (
      'T read<T>(T value) => value; const other = read; const selected = other<int>;',
      'NAPI_CALLABLE',
    ),
    'constructor': (
      'class C<T> { C(); } const selected = C<int>.new;',
      'NAPI_CALLABLE',
    ),
    'closure': ('final selected = <T>(T value) => value;', 'NAPI_CALLABLE'),
    'bound instance': (
      'class C { const C(); T read<T>(T value) => value; } final selected = const C().read<int>;',
      'NAPI_CALLABLE',
    ),
    'widened result': (
      'T read<T>(T value) => value; const num Function(int) selected = read<int>;',
      'NAPI_CALLABLE',
    ),
    'dropped optional parameter': (
      'T read<T>(T value, {int count = 7}) => value; const int Function(int) selected = read<int>;',
      'NAPI_CALLABLE',
    ),
    'erased function': (
      'T read<T>(T value) => value; const Function selected = read<int>;',
      'NAPI_CALLABLE',
    ),
    'changed nullability': (
      'T read<T>(T value) => value; const int Function(int)? selected = read<int>;',
      'NAPI_CALLABLE',
    ),
    'wrong bound': (
      'T read<T extends num>(T value) => value; const selected = read<String>;',
      'NAPI_DART',
    ),
  };
  for (final MapEntry(key: name, value: (text, code)) in invalid.entries) {
    test('rejects $name in annotation and external selection', () async {
      // Put the annotation on selected, not a preceding helper declaration.
      final declaration = text.indexOf(
        RegExp(r'(?:const|final|var)[^;]*\bselected\s*='),
      );
      expect(declaration, isNonNegative);
      final input = source("import 'package:napi/napi.dart';\n$text");
      await expectLater(
        read(input, false, selected: 'selected'),
        throwsA(diagnostic(code)),
      );
      input.writeAsStringSync(
        "import 'package:napi/napi.dart';\n${text.substring(0, declaration)}@NAPI() ${text.substring(declaration)}",
      );
      await expectLater(read(input, false), throwsA(diagnostic(code)));
    });
  }

  test('direct generic methods retain their diagnostic', () async {
    final input = source('''
import 'package:napi/napi.dart';
@NAPI() class Reader { T read<T>(T value) => value; }
''');
    final module = await read(input, false);
    expect(() => validate(module), throwsA(diagnostic('NAPI_GENERIC')));
    expect(() => validateNative(module), throwsA(diagnostic('NAPI_GENERIC')));
  });
}
