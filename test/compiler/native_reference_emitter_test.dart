import 'dart:io';

import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;
const _source = '''
import 'package:napi/napi.dart';
@NAPI() DartBox identity(DartBox box) => box;
@NAPI() DartBox? optional([DartBox? box]) => box;
@NAPI() DartBox? named({DartBox? box = null}) => box;
@NAPI(name: 'Box')
class DartBox {
  DartBox(this.value);
  @NAPI(name: 'copy')
  DartBox.copied(DartBox other) : value = other.value;
  final int value;
  DartBox echo(DartBox other) => other;
  DartBox? _link;
  DartBox? get link => _link;
  set link(DartBox? next) { _link = next; }
  static DartBox accept(DartBox other) => other;
}
@NAPI()
class Shared {
  factory Shared([int value = 9]) => _shared;
  Shared._(this.value);
  @NAPI(name: 'constructor')
  factory Shared.cached() => _shared;
  static final Shared _shared = Shared._(9);
  final int value;
}
@NAPI(name: 'FactoryOnly')
class DartOnly {
  DartOnly.named(this.box);
  final DartBox box;
}
@NAPI(name: 'AbstractFactory')
abstract class DartFactory {
  factory DartFactory(DartBox box) = _Factory;
  DartBox get box;
}
class _Factory implements DartFactory {
  _Factory(this.box);
  final DartBox box;
}
@NAPI()
class RefBase {
  RefBase();
  RefBase echo(RefBase other) => other;
}
@NAPI()
class RefChild extends RefBase {
  RefChild();
}
@NAPI() RefBase identityBase(RefBase value) => value;
''';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'napi-native-reference-emitter-',
    );
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<NativeModulePlan> read() async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString(_source);
    return validateNative(
      await AnnotationFrontend(
        packagesPath: _packages,
        native: true,
      ).read(input.uri),
    );
  }

  test(
    'native reference plans preserve selected identities and constructors',
    () async {
      final plan = await read();
      final input = plan.functions.first.inputs.single as ReferenceConversion;
      final output = plan.functions.first.output as ReferenceConversion;
      expect(input.classId, 0);
      expect(input.classBinding.exportName, 'Box');
      expect(input.dartType, 'target.DartBox');
      expect(output.classId, input.classId);
      expect(plan.functions[1].inputs.single.nullable, isTrue);

      final box = plan.classes[0];
      final copy = box.members.singleWhere((call) => call.exportName == 'copy');
      expect(copy.kind, NativeCallKind.method);
      expect(copy.isStatic, isTrue);
      expect((copy.output as ReferenceConversion).classId, 0);
      expect(box.constructor.classId, 0);
      expect(box.hasPublicConstructor, isTrue);

      final shared = plan.classes[1];
      expect(shared.constructor.classId, 1);
      expect(shared.hasPublicConstructor, isTrue);
      expect(shared.constructor.member!.isFactory, isTrue);
      expect(
        shared.members
            .singleWhere((call) => call.exportName == 'constructor')
            .isStatic,
        isTrue,
      );

      final only = plan.classes[2];
      expect(only.hasPublicConstructor, isFalse);
      expect(only.constructor.member, isNull);
      expect(only.constructor.classId, 2);
      expect(only.members.first.isStatic, isTrue);
      expect((only.members.first.output as ReferenceConversion).classId, 2);
      expect(plan.classes[3].constructor.member!.isFactory, isTrue);
    },
  );

  test('native reference emission checks owners before Dart types and business calls', () async {
    final plan = await read();
    final dart = emitNativeDart(plan);
    expect(
      dart,
      contains(
        'final object0 = _api.ownerValue(call.env, raw0, "identity.box", 0);',
      ),
    );
    expect(dart, contains('if (object0 is! target.DartBox)'));
    expect(
      dart.indexOf('ownerValue(call.env, raw0, "identity.box", 0)'),
      lessThan(dart.indexOf('target.identity(a0)')),
    );
    expect(
      dart,
      contains('_api.referenceResult(call.env, value, 0, "identity result")'),
    );
    expect(
      dart,
      contains('_api.ownerValue(call.env, call.self, "Box.echo", 0)'),
    );
    expect(dart, contains('target.DartBox.copied(a0)'));
    expect(dart, contains('"staticMethod", "copy"'));
    expect(dart, contains('_api.wrap(call, target.Shared(a0), 1, "Shared")'));
    expect(dart, contains('target.Shared.cached()'));
    expect(
      dart,
      contains('FactoryOnly: no selected public unnamed constructor'),
    );
    expect(dart, isNot(contains('target.DartOnly()')));
    expect(dart, contains('target.DartOnly.named(a0)'));
    expect(
      dart,
      contains(
        '_api.referenceResult(call.env, value, 2, "FactoryOnly.named result")',
      ),
    );

    final types = emitNativeDeclarations(plan);
    expect(types, contains('identity(box: Box): Box;'));
    expect(types, contains('optional: (box?: Box | null) => Box | null;'));
    expect(
      types,
      contains(
        'named: (options?: { box?: Box | null | undefined }) => Box | null;',
      ),
    );
    expect(types, contains('static copy(other: Box): Box;'));
    expect(types, contains('get link(): Box | null;'));
    expect(types, contains('set link(next: Box | null);'));
    expect(types, contains('constructor(value?: number);'));
    expect(types, contains('static ["constructor"](): Shared;'));
    expect(
      types,
      contains('export declare class FactoryOnly {\n  private constructor();'),
    );
    expect(types, contains('static named(box: Box): FactoryOnly;'));
  });

  test(
    'reference inputs and receivers require the selected public class brand',
    () async {
      final plan = await read();
      final input =
          plan.functions
                  .singleWhere((call) => call.exportName == 'identityBase')
                  .inputs
                  .single
              as ReferenceConversion;
      final base = plan.classes[4];
      final child = plan.classes[5];
      expect(input.classId, base.constructor.classId);
      expect(input.classId, isNot(child.constructor.classId));
      expect(base.members.single.classId, input.classId);
      final dart = emitNativeDart(plan);
      expect(
        dart,
        contains('_api.ownerValue(call.env, raw0, "identityBase.value", 4)'),
      );
      expect(
        dart,
        contains('_api.ownerValue(call.env, call.self, "RefBase.echo", 4)'),
      );
      expect(dart, contains('if (object0 is! target.RefBase)'));
      expect(dart, contains('if (object is! target.RefBase)'));
    },
  );

  test('native reference declarations accept class APIs and reject private new', () async {
    final plan = await read();
    await File('${directory.path}/module.d.mts')
        .writeAsString(emitNativeDeclarations(plan));
    final consumer = File('${directory.path}/consumer.mts');
    await consumer.writeAsString('''
import { Box, Shared, FactoryOnly, AbstractFactory, identity, optional, named } from './module.mjs';
const box = new Box(1);
const copied: Box = Box.copy(box);
const same: Box = identity(box);
const nullable: Box | null = optional(null);
const absent: Box | null = optional(undefined);
named({ box: undefined });
box.link = copied;
const shared: Shared = Shared['constructor']();
const instance: Shared = new Shared();
const only: FactoryOnly = FactoryOnly.named(box);
const factory: AbstractFactory = new AbstractFactory(box);
// @ts-expect-error No selected unnamed constructor is public.
new FactoryOnly();
// @ts-expect-error A selected class argument is required.
identity(1);
void [same, nullable, absent, shared, instance, only, factory];
''');
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    expect(File(tsc).existsSync(), isTrue);
    final compilation = await Process.run('node', [
      tsc,
      '--ignoreConfig',
      '--strict',
      '--exactOptionalPropertyTypes',
      '--noEmit',
      '--target',
      'ES2022',
      '--module',
      'NodeNext',
      '--moduleResolution',
      'NodeNext',
      consumer.path,
    ]);
    expect(
      compilation.exitCode,
      0,
      reason: '${compilation.stdout}${compilation.stderr}',
    );
  });

  test('reference arguments, results and constructor mappings compile as native AOT', () async {
    final plan = await read();
    final entry = File('${directory.path}/entry.dart');
    await entry.writeAsString(emitNativeDart(plan));
    final compilation = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'aot-snapshot',
      '--packages=$_packages',
      entry.path,
      '--output=${directory.path}/module.aot',
    ]);
    expect(
      compilation.exitCode,
      0,
      reason: '${compilation.stdout}${compilation.stderr}',
    );
    expect(File('${directory.path}/module.aot').existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
