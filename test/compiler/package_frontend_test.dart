import 'dart:convert';
import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late AnnotationFrontend frontend;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('napi package sources ');
    addTearDown(() => directory.delete(recursive: true));
    final fixture = Directory('test/fixtures/frontend/package');
    await for (final entity in fixture.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart.txt')) continue;
      final relative = p.relative(entity.path, from: fixture.path);
      final destination = File(
        p.join(directory.path, relative.substring(0, relative.length - 4)),
      );
      await destination.parent.create(recursive: true);
      await entity.copy(destination.path);
    }
    await File('${directory.path}/pubspec.yaml').writeAsString('''
name: napi_frontend_consumer
environment:
  sdk: ^3.13.5
dependencies:
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
    final result = await Process.run(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: directory.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    frontend = AnnotationFrontend(
      packagesPath: '${directory.path}/.dart_tool/package_config.json',
    );
  });

  test(
    'file locations preserve package identities, parts, and reexports',
    () async {
      final entry = File('${directory.path}/lib/bindings.dart').uri;
      final module = await frontend.read(entry);
      expect(module.source, entry);
      final functions = {
        for (final f in module.functions) f.declaration.name: f,
      };
      expect(
        functions.keys,
        unorderedEquals(['scalar', 'fromPart', 'reexported']),
      );
      for (final (name, library, source) in [
        ('scalar', 'bindings.dart', 'bindings.dart'),
        ('fromPart', 'bindings.dart', 'bindings_part.dart'),
        ('reexported', 'exported.dart', 'exported.dart'),
      ]) {
        final function = functions[name]!;
        expect(
          function.declaration.library,
          Uri.parse('package:napi_frontend_consumer/$library'),
        );
        expect(function.exportSurface, entry);
        expect(function.callPath, name);
        expect(function.source.uri, File('${directory.path}/lib/$source').uri);
        expect(function.parameters.single.source!.uri, function.source.uri);
        await _expectSource(function.source, name);
        await _expectSource(function.parameters.single.source!, 'value');
      }
    },
  );

  for (final (label, body, code, token) in [
    (
      'dart_error',
      '@NAPI()\nMissingType broken() => throw 0;\n',
      'NAPI_DART',
      'MissingType',
    ),
    (
      'configuration_error',
      '@NAPI()\n@NAPI()\nint duplicate() => 0;\n',
      'NAPI_SELECTION',
      'duplicate',
    ),
    (
      'annotation_error',
      '@NAPI()\nint _private() => 0;\n',
      'NAPI_VISIBILITY',
      '@NAPI()',
    ),
    (
      'declaration_error',
      "@NAPI(name: 'bad-name')\nint invalid() => 0;\n",
      'NAPI_NAME',
      'invalid',
    ),
  ]) {
    for (final placement in ['entry', 'part', 'reexport']) {
      test('$label in package $placement uses a precise file location', () async {
        final root = Directory('${directory.path}/lib/$label/$placement');
        await root.create(recursive: true);
        final entry = File('${root.path}/entry.dart');
        final source = placement == 'entry'
            ? entry
            : File('${root.path}/origin.dart');
        if (placement == 'part') {
          await entry.writeAsString(
            "import 'package:napi/napi.dart';\npart 'origin.dart';\n",
          );
        } else if (placement == 'reexport') {
          await entry.writeAsString("export 'origin.dart';\n");
        }
        final directive = placement == 'part'
            ? "part of 'entry.dart';"
            : "import 'package:napi/napi.dart';";
        // A public selection makes reexport discovery load the origin library,
        // including invalid annotations on declarations outside its namespace.
        await source.writeAsString(
          '$directive\n@NAPI()\nint visible() => 0;\n$body',
        );
        BindingDiagnostic? diagnostic;
        try {
          await frontend.read(entry.uri);
        } on BindingDiagnostic catch (error) {
          diagnostic = error;
        }
        expect(diagnostic, isNotNull);
        expect(diagnostic!.code, code);
        expect(diagnostic.source!.uri, source.uri);
        await _expectSource(diagnostic.source!, token);
      });
    }
  }
}

Future<void> _expectSource(SourceLocation source, String token) async {
  final text = await File.fromUri(source.uri).readAsString();
  expect(text.substring(source.offset, source.offset + source.length), token);
  final prefix = text.substring(0, source.offset);
  expect(source.line, '\n'.allMatches(prefix).length + 1);
  expect(source.column, source.offset - prefix.lastIndexOf('\n'));
}
