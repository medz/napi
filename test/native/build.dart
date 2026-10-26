import 'dart:io';

import 'package:napi/compiler.dart';

Future<void> main(List<String> args) async {
  final source = File.fromUri(Platform.script).parent;
  final output = Directory(args.single);
  await Compiler([
    for (final (profile, entry) in [
      ('core', 'counter.dart'),
      ('regexp', 'regexp.dart'),
      ('full', 'payload.dart'),
      ('failed', 'failed_registration.dart'),
    ])
      NativeTarget(
        entry: File('${source.path}/$entry'),
        output: File('${output.path}/$profile/addon.node'),
      ),
    for (final (target, entry) in [
      ('annotated', 'annotated_functions.dart'),
      ('classes', 'annotated_classes.dart'),
    ])
      NativeTarget(
        entry: File('${source.path}/$entry'),
        output: File('${output.path}/$target/addon.node'),
        declarations: File('${output.path}/$target/addon.d.ts'),
      ),
  ]).run([]);

  final core = File('${output.path}/core/addon.node');
  final original = await core.readAsBytes();
  final temporary = await source.createTemp('.entrypoint-');
  try {
    final entry = File('${temporary.path}/addon.dart');
    for (final (declaration, expected) in [
      (
        'void register(Env env, JsObject exports) async {}',
        'must be synchronous void register(Env env, JsObject exports)',
      ),
      (
        'void register(int env, int exports) {}',
        'must declare void register(Env env, JsObject exports)',
      ),
    ]) {
      await entry.writeAsString(
        "import 'package:napi/env.dart';\n$declaration\n",
      );
      String? failure;
      try {
        await Compiler([NativeTarget(entry: entry, output: core)]).run([]);
      } on StateError catch (error) {
        failure = error.message.toString();
      }
      if (failure == null || !failure.contains(expected)) {
        throw StateError('Expected register signature rejection, got $failure');
      }
      final current = await core.readAsBytes();
      if (current.length != original.length ||
          original.indexed.any((byte) => current[byte.$1] != byte.$2)) {
        throw StateError('Invalid register entry changed the existing addon');
      }
    }
  } finally {
    await temporary.delete(recursive: true);
  }
  await Compiler([
    NativeTarget(entry: File('${source.path}/counter.dart'), output: core),
  ]).run([]);

  for (final (target, fixture, failures) in [
    (
      'annotated',
      'annotated_functions.dart',
      [
        ('@NAPI() T identity<T>(T value) => value;', 'generic functions'),
        (
          '@NAPI() int length(List<int> values) => values.length;',
          'unsupported parameter type',
        ),
        ('@NAPI() List<int> values() => [1];', 'unsupported return type'),
        (
          "@NAPI(name: 'same') int first() => 1;\n"
              "@NAPI(name: 'same') int second() => 2;",
          'Duplicate JavaScript export',
        ),
        ('@NAPI() int get value => 1;', 'Unsupported annotated declaration'),
      ],
    ),
    (
      'classes',
      'annotated_classes.dart',
      [
        (
          '@NAPI() class Base {}\n@NAPI() class Child extends Base {}',
          'Exported classes cannot inherit from or implement another exported class',
        ),
        (
          'class Hidden {}\n@NAPI() Hidden echo(Hidden value) => value;',
          'class type must be exported',
        ),
      ],
    ),
  ]) {
    final annotated = File('${output.path}/$target/addon.node');
    final declarations = File('${output.path}/$target/addon.d.ts');
    final binary = await annotated.readAsBytes();
    final types = await declarations.readAsString();
    final invalid = await source.createTemp('.annotations-');
    try {
      final entry = File('${invalid.path}/addon.dart');
      for (final (declaration, expected) in failures) {
        await entry.writeAsString(
          "import 'package:napi/napi.dart';\n$declaration\n",
        );
        String? failure;
        try {
          await Compiler([
            NativeTarget(
              entry: entry,
              output: annotated,
              declarations: declarations,
            ),
          ]).run([]);
        } on StateError catch (error) {
          failure = error.message.toString();
        }
        if (failure == null || !failure.contains(expected)) {
          throw StateError('Expected annotation rejection, got $failure');
        }
        final current = await annotated.readAsBytes();
        if (current.length != binary.length ||
            binary.indexed.any((byte) => current[byte.$1] != byte.$2) ||
            await declarations.readAsString() != types) {
          throw StateError('Invalid annotation changed the existing output');
        }
      }
    } finally {
      await invalid.delete(recursive: true);
    }
    await Compiler([
      NativeTarget(
        entry: File('${source.path}/$fixture'),
        output: annotated,
        declarations: declarations,
      ),
    ]).run([]);
  }
}
