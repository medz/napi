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
      ('collections', 'annotated_collections.dart'),
      ('callbacks', 'annotated_callbacks.dart'),
      ('futures', 'annotated_futures.dart'),
      ('streams', 'annotated_streams.dart'),
      ('records', 'annotated_records.dart'),
      ('enums', 'annotated_enums.dart'),
      ('constants', 'annotated_constants.dart'),
      ('references', 'annotated_js_references.dart'),
      ('objects', 'annotated_objects.dart'),
      ('properties', 'annotated_properties.dart'),
      ('generics', 'annotated_generics.dart'),
      ('dates', 'annotated_dates.dart'),
      ('binary-views', 'annotated_binary_views.dart'),
      ('simd', 'annotated_simd.dart'),
      ('sets', 'annotated_sets.dart'),
      ('env', 'annotated_env.dart'),
      ('inheritance', 'annotated_inheritance.dart'),
      ('generic-objects', 'annotated_generic_objects.dart'),
      ('generic-callbacks', 'annotated_generic_callbacks.dart'),
    ])
      NativeTarget(
        entry: File('${source.path}/$entry'),
        output: File('${output.path}/$target/addon.node'),
        declarations: File('${output.path}/$target/addon.d.ts'),
      ),
  ]).run([]);

  await Compiler([
    for (final extension in ['cts', 'mts'])
      NativeTarget(
        entry: File('${source.path}/annotated_properties.dart'),
        output: File('${output.path}/properties-$extension/addon.node'),
        declarations: File(
          '${output.path}/properties-$extension/addon.d.$extension',
        ),
      ),
    PackageBuild(
      entry: File('${source.path}/annotated_properties.dart'),
      output: Directory('${output.path}/properties-package'),
      name: '@fixture/properties',
      version: '0.0.0',
    ),
    PackageBuild(
      entry: File('${source.path}/annotated_generics.dart'),
      output: Directory('${output.path}/generics-package'),
      name: '@fixture/generics',
      version: '0.0.0',
    ),
    PackageBuild(
      entry: File('${source.path}/annotated_inheritance.dart'),
      output: Directory('${output.path}/inheritance-package'),
      name: '@fixture/inheritance',
      version: '0.0.0',
    ),
  ]).run([]);
  await Compiler([
    PackageBuild.fromArtifacts(
      artifacts: [
        NativeArtifact(File('${output.path}/properties-package/.napi.json')),
      ],
      output: Directory('${output.path}/properties-assembled'),
      name: '@fixture/properties-assembled',
      version: '0.0.0',
    ),
  ]).run([]);

  final enumPackage = Directory('${output.path}/enums-package');
  await Compiler([
    PackageBuild(
      entry: File('${source.path}/annotated_enums.dart'),
      output: enumPackage,
      name: '@fixture/enums',
      version: '0.0.0',
    ),
  ]).run([]);
  await Compiler([
    PackageBuild.fromArtifacts(
      artifacts: [NativeArtifact(File('${enumPackage.path}/.napi.json'))],
      output: Directory('${output.path}/enums-assembled'),
      name: '@fixture/enums-assembled',
      version: '0.0.0',
    ),
  ]).run([]);

  final constantPackage = Directory('${output.path}/constants-package');
  await Compiler([
    PackageBuild(
      entry: File('${source.path}/annotated_constants.dart'),
      output: constantPackage,
      name: '@fixture/constants',
      version: '0.0.0',
    ),
  ]).run([]);

  final objectPackage = Directory('${output.path}/objects-package');
  await Compiler([
    PackageBuild(
      entry: File('${source.path}/annotated_objects.dart'),
      output: objectPackage,
      name: '@fixture/objects',
      version: '0.0.0',
    ),
  ]).run([]);
  await Compiler([
    PackageBuild.fromArtifacts(
      artifacts: [NativeArtifact(File('${objectPackage.path}/.napi.json'))],
      output: Directory('${output.path}/objects-assembled'),
      name: '@fixture/objects-assembled',
      version: '0.0.0',
    ),
  ]).run([]);
  await Compiler([
    PackageBuild.fromArtifacts(
      artifacts: [NativeArtifact(File('${constantPackage.path}/.napi.json'))],
      output: Directory('${output.path}/constants-assembled'),
      name: '@fixture/constants-assembled',
      version: '0.0.0',
    ),
  ]).run([]);

  final core = File('${output.path}/core/addon.node');
  final original = await core.readAsBytes();
  final temporary = await source.createTemp('.entrypoint-');
  try {
    final entry = File('${temporary.path}/addon.dart');
    for (final (declaration, expected, node) in [
      (
        'void register(Env env, JsObject exports) async {}',
        'must be synchronous void register(Env env, JsObject exports)',
        null,
      ),
      (
        'void register(int env, int exports) {}',
        'must declare void register(Env env, JsObject exports)',
        null,
      ),
      (
        'int initialize(int environment, int exports, int callJs, int owner, '
            'int finalizer, int hasLivePorts) => 0;\n'
            'void afterPump() {}\nvoid dispose() {}',
        '10.17.0',
        '10.16.0',
      ),
    ]) {
      await entry.writeAsString(
        "import 'package:napi/env.dart';\n$declaration\n",
      );
      String? failure;
      try {
        await Compiler([
          NativeTarget(entry: entry, output: core, node: node),
        ]).run([]);
      } on StateError catch (error) {
        failure = error.message.toString();
      }
      if (failure == null || !failure.contains(expected)) {
        throw StateError(
          'Expected entry or compatibility rejection, got $failure',
        );
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
        (
          'class Hidden {}\n@NAPI() int inspect(Hidden value) => 1;',
          'class type must be exported',
        ),
        (
          'class Hidden {}\n@NAPI() Hidden hidden() => Hidden();',
          'class type must be exported',
        ),
        (
          "@NAPI(name: 'same') int first() => 1;\n"
              "@NAPI(name: 'same') int second() => 2;",
          'Duplicate JavaScript export',
        ),
        (
          'class Hidden {} @NAPI() Hidden get value => Hidden();',
          'class type must be exported',
        ),
      ],
    ),
    (
      'classes',
      'annotated_classes.dart',
      [
        (
          "@NAPI(name: 'number') class Reject {}",
          'reserved TypeScript class name',
        ),
        (
          'class Hidden {}\n@NAPI() Hidden echo(Hidden value) => value;',
          'class type must be exported',
        ),
      ],
    ),
    (
      'generic-callbacks',
      'annotated_generic_callbacks.dart',
      [
        (
          '@NAPI() void invalid(T Function<T extends List<int>>(T) callback) {}',
          'generic bounds must preserve JavaScript values',
        ),
      ],
    ),
    (
      'inheritance',
      'annotated_inheritance.dart',
      [
        (
          '@NAPI() class Base {} '
              '@NAPI() class Child implements Base {}',
          'cannot implement an exported class',
        ),
        (
          '@NAPI.object() class Base {} '
              '@NAPI() class Child extends Base {}',
          'object mappings cannot participate in exported class inheritance',
        ),
        (
          '@NAPI() class Base { @NAPI() static int parse(int value) => value; } '
              '@NAPI() class Child extends Base { '
              '@NAPI() static String parse(String value) => value; }',
          'static export conflicts with inherited member',
        ),
      ],
    ),
    (
      'futures',
      'annotated_futures.dart',
      [
        (
          '@NAPI() int nested(Future<Future<int>> value) => 1;',
          'nested Future inputs are not supported',
        ),
        (
          '@NAPI() void invalid() async {}',
          'async void exports are not supported; return Future<void> instead',
        ),
        (
          '@NAPI() class Invalid { @NAPI() void get ignored async {} }',
          'async void exports are not supported; return Future<void> instead',
        ),
      ],
    ),
    (
      'collections',
      'annotated_collections.dart',
      [
        (
          '@NAPI() Map<int, String> invalid(Map<int, String> value) => value;',
          'Map keys must be non-nullable String',
        ),
      ],
    ),
    (
      'enums',
      'annotated_enums.dart',
      [
        (
          '@NAPI() enum Invalid { _hidden, ready }',
          'Private enum case must be explicitly annotated',
        ),
        (
          "@NAPI() enum Invalid { @NAPI(name: 'same') first, "
              "@NAPI(name: 'same') second }",
          'Duplicate JavaScript enum case',
        ),
        (
          '@NAPI() enum Invalid { ready; @NAPI() int get code => 1; }',
          'Only enum cases can be annotated',
        ),
        (
          "@NAPI(name: 'number') enum Invalid { ready }",
          'reserved TypeScript enum name',
        ),
      ],
    ),
    (
      'constants',
      'annotated_constants.dart',
      [
        (
          "@NAPI(name: 'same') const first = 1; "
              "@NAPI(name: 'same') const second = 2;",
          'Duplicate JavaScript export',
        ),
        (
          "@NAPI() int same() => 1; @NAPI(name: 'same') const value = 2;",
          'Duplicate JavaScript export',
        ),
        (
          'class Hidden {} @NAPI() final value = Hidden();',
          'class type must be exported',
        ),
      ],
    ),
    (
      'references',
      'annotated_js_references.dart',
      [
        (
          '@NAPI() JsReference<JsObject?> invalid(JsReference<JsObject?> value) => value;',
          'JsReference requires non-nullable JsObject, JsFunction or JsSymbol',
        ),
        (
          '@NAPI() JsReference<Object> invalid(JsReference<Object> value) => value;',
          'JsReference requires non-nullable JsObject, JsFunction or JsSymbol',
        ),
      ],
    ),
    (
      'objects',
      'annotated_objects.dart',
      [
        (
          '@NAPI.object() class Invalid { @NAPI() final int value = 1; } '
              '@NAPI() int inspect(Invalid value) => value.value;',
          'has no annotated input constructor',
        ),
        (
          '@NAPI.object() class Invalid { @NAPI() final int value = 1; } '
              '@NAPI() int inspect(Invalid Function() create) => create().value;',
          'has no annotated input constructor',
        ),
        (
          '@NAPI.object() class Invalid { @NAPI() Invalid(); @NAPI() Invalid.named(); }',
          'multiple annotated input constructors',
        ),
        (
          '@NAPI.object() class Invalid { @NAPI() Invalid(int _, int _); } '
              '@NAPI() Invalid inspect(Invalid value) => value;',
          'duplicate object input property',
        ),
        (
          '@NAPI.object() class Invalid { @NAPI() int method() => 1; }',
          'only instance fields and getters',
        ),
        (
          '@NAPI.object() class Invalid { @NAPI() static int value = 1; }',
          'only instance fields and getters',
        ),
        (
          '@NAPI.object() class Invalid { @NAPI() set value(int next) {} }',
          'only instance fields and getters',
        ),
      ],
    ),
    (
      'properties',
      'annotated_properties.dart',
      [
        (
          "@NAPI(name: 'left') int get value => 1; "
              "@NAPI(name: 'right') set value(int next) {}",
          'getter and setter names must agree',
        ),
        (
          "@NAPI() int count = 1; @NAPI(name: 'count') int inspect() => 1;",
          'Duplicate JavaScript export',
        ),
      ],
    ),
    (
      'generic-objects',
      'annotated_generic_objects.dart',
      [
        (
          '@NAPI.object() class GrowingThenable<T> { '
              '@NAPI() GrowingThenable(); '
              '@NAPI() void Function(void Function(GrowingThenable<List<T>>)) '
              'get then => throw UnimplementedError(); } '
              '@NAPI() Future<GrowingThenable<int>> invalid() => '
              'throw UnimplementedError();',
          'thenable resolution does not have a finite type',
        ),
        (
          '@NAPI.object() class Readout<T> { Readout(this.value); '
              '@NAPI() final T value; } '
              '@NAPI() void invalid(Readout<int> value) {}',
          'has no annotated input constructor',
        ),
        (
          '@NAPI.object() class Item { @NAPI() Item(this.value); '
              '@NAPI() final int value; } '
              '@NAPI.object() class Holder<T> { @NAPI() Holder(this.run); '
              '@NAPI() final U Function<U extends T>(U) run; } '
              '@NAPI() void invalid(Holder<Item> value) {}',
          'generic bounds must preserve JavaScript values',
        ),
        (
          '@NAPI.object() class Item { @NAPI() Item(this.value); '
              '@NAPI() final int value; } '
              '@NAPI.object() class Holder<T> { @NAPI() Holder(this.run); '
              '@NAPI() final U Function<U extends T>(U) run; } '
              '@NAPI.object() class Outer<T> { @NAPI() Outer(this.inner); '
              '@NAPI() final Holder<T> inner; } '
              '@NAPI() void invalid(Outer<Item> value) {}',
          'generic bounds must preserve JavaScript values',
        ),
        (
          '@NAPI.object() class Holder<T> { @NAPI() Holder(this.run); '
              '@NAPI() final U Function<U extends T>(U) run; } '
              '@NAPI.object() class Step<T> { '
              '@NAPI() Step({required this.holder, this.next}); '
              '@NAPI() final Holder<T> holder; '
              '@NAPI() final Step<List<T>>? next; } '
              '@NAPI() void invalid(Step<int> value) {}',
          'generic bounds must preserve JavaScript values',
        ),
      ],
    ),
    (
      'generics',
      'annotated_generics.dart',
      [
        (
          '@NAPI() T invalid<T extends List<int>>(T value) => value;',
          'generic bounds must preserve JavaScript values',
        ),
        (
          '@NAPI() class Box<T> { @NAPI() Box(this.value); @NAPI() T value; } '
              '@NAPI.object() class Point { @NAPI() Point({required this.x}); @NAPI() final int x; } '
              '@NAPI() List<Point> consume(Box<List<Point>> value) => value.value;',
          'unsupported concrete bound-class argument',
        ),
        for (final type in [
          'Thenable',
          '({void Function(void Function(int)) then})',
          'Map<String, void Function(void Function(int))>',
        ])
          (
            '@NAPI() class Box<T> { @NAPI() Box(this.value); @NAPI() T value; } '
                '@NAPI() class Holder { @NAPI() Box<Future<$type>> get value => throw UnimplementedError(); } '
                '@NAPI() class Thenable { @NAPI() void then(void Function(int) resolve) => resolve(1); }',
            'thenable Future class arguments need different input and output types',
          ),
        for (final subclass in [
          '@NAPI() class Child extends Counter { '
              '@NAPI() void then(void Function(int) resolve) => resolve(7); }',
          '@NAPI() class Child extends Counter { '
              '@NAPI() void Function(void Function(int))? get then => null; }',
          '@NAPI() class Middle extends Counter {} '
              '@NAPI() class Child extends Middle { '
              '@NAPI(name: "then") void resolve(void Function(int) callback) => callback(7); }',
          '@NAPI() class Child<T> extends Counter { '
              '@NAPI() T get then => throw UnimplementedError(); }',
        ])
          (
            '@NAPI() class Box<T> { @NAPI() Box(this.value); @NAPI() T value; } '
                '@NAPI() class Holder { @NAPI() Box<List<Future<Counter>>> get value => throw UnimplementedError(); } '
                '@NAPI() class Counter {} $subclass',
            'thenable Future class arguments need different input and output types',
          ),
        for (final type in [
          'Stream<int>',
          'List<Stream<int>>',
          'Future<Future<int>>',
          'T Function<T>(T)',
          'Stream<int> Function()',
        ])
          (
            '@NAPI() class Box<T> { @NAPI() Box(this.value); @NAPI() T value; } '
                '@NAPI() void consume(Box<$type> value) {}',
            'unsupported concrete bound-class argument',
          ),
        (
          '@NAPI() class Box<T> { @NAPI() Box(this.value); T value; '
              '@NAPI() Box<List<T>> nested() => Box([value]); }',
          'nested bound-class arguments cannot depend on erased type parameters yet',
        ),
        (
          '@NAPI() class Box<T> { @NAPI() Box(this.value); @NAPI() T value; } '
              '@NAPI() void invalid(Box<T> Function<T>(Box<T>) callback) {}',
          'bound-class arguments cannot depend on reified callback or data-class parameters yet',
        ),
      ],
    ),
    (
      'dates',
      'annotated_dates.dart',
      [
        (
          '@NAPI() T invalid<T extends DateTime>(T value) => value;',
          'generic bounds must preserve JavaScript values',
        ),
      ],
    ),
    (
      'env',
      'annotated_env.dart',
      [
        (
          "import 'package:napi/env.dart'; "
              '@NAPI() void invalid(Env? env) {}',
          'injected Env must be required and non-nullable',
        ),
        (
          "import 'package:napi/env.dart'; "
              '@NAPI() void invalid([Env? env]) {}',
          'injected Env must be required and non-nullable',
        ),
        (
          "import 'package:napi/env.dart'; "
              '@NAPI() Env invalid(Env env) => env;',
          'Env is only supported as an injected required non-nullable parameter',
        ),
        (
          "import 'package:napi/env.dart'; "
              '@NAPI() void invalid(void Function(Env) callback) {}',
          'Env is only supported as an injected required non-nullable parameter',
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
    if (target == 'collections') {
      String? failure;
      try {
        await Compiler([
          NativeTarget(
            entry: File('${source.path}/$fixture'),
            output: annotated,
            node: '>=20.3.0 <21.0.0',
          ),
        ]).run([]);
      } on StateError catch (error) {
        failure = error.message.toString();
      }
      if (failure == null || !failure.contains('22.14.0')) {
        throw StateError(
          'Expected accessor availability rejection, got $failure',
        );
      }
    }
  }
}
