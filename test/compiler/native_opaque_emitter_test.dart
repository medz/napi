import 'dart:io';

import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

const _source = '''
import 'dart:async';
import 'package:napi/napi.dart';

@NAPI()
class Router<T> {
  Router([this.value]);
  Router.from(T input) : value = input;
  T? value;
  T accept(T input) => input;
  T named({required T input}) => input;
  Router<T> same(Router<T> other) => other;
  Router<T> copy() => Router<T>(value);
  Future<int> wait(T input) => Completer<int>().future;
  static int count() => 1;
}

@NAPI()
class Empty<T> {
  Empty();
}

@NAPI() T echo<T>(T value) => value;
@NAPI() T? optional<T>([T? value]) => value;
@NAPI() T named<T>({required T value}) => value;
@NAPI() T? optionalNamed<T>(int index, {T? first, T? second, int fallback = 7}) => index == 0 ? first : second;
@NAPI() T ordered<T>(T value, int requiredSecond) => value;
@NAPI() Future<int> wait<T>(T value) => Completer<int>().future;
@NAPI() Router<T> same<T>(Router<T> value) => value;
@NAPI() B second<A, B>(A first, B second) => second;
''';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-native-opaque-');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<NativeModulePlan> plan(String source) async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString(source);
    return validateNative(
      await AnnotationFrontend(
        packagesPath: _packages,
        native: true,
      ).read(input.uri),
    );
  }

  test(
    'opaque classes and functions compile as real carrier generics',
    () async {
      final module = await plan(_source);
      final dart = emitNativeDart(module);
      expect(dart, contains('typedef _NapiHostValue = NativeHostValue;'));
      expect(dart, contains('target.Router<_NapiHostValue>(a0)'));
      expect(dart, contains('target.Router<_NapiHostValue>.from(a0)'));
      expect(dart, contains('target.Empty<_NapiHostValue>()'));
      expect(dart, contains('target.Router.count()'));
      expect(dart, contains('object is! target.Router<_NapiHostValue>'));
      expect(dart, contains('object0 is! target.Router<_NapiHostValue>'));
      expect(dart, contains('target.echo<_NapiHostValue>(a0)'));
      expect(
        dart,
        contains('target.second<_NapiHostValue, _NapiHostValue>(a0, a1)'),
      );
      expect(dart, contains('_api.retainFuture(token, [a0])'));
      expect(dart, contains('_api.retainFuture(token, [object, a0])'));
      expect(dart, contains('return _api.hostValue(call.env, value).address;'));
      expect(dart, isNot(contains(' is target.Router)')));
      expect(dart, isNot(contains('target.Router<dynamic>')));

      final entry = File('${directory.path}/entry.dart');
      await entry.writeAsString(dart);
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
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('opaque presence is checked before owning supplied values', () async {
    final module = await plan(_source);
    final dart = emitNativeDart(module);
    String body(String name) {
      final call = module.functions.singleWhere((f) => f.exportName == name);
      return dart.split('int ${call.callback}(').last.split('\n}\n').first;
    }

    final required = body('ordered');
    expect(
      required,
      contains('_api.presentArgument(call, 0, "ordered.value")'),
    );
    expect(
      required.indexOf('_api.requiredArgument(call, 1,'),
      lessThan(required.indexOf('_api.ownHostValue(call.env, raw0)')),
    );
    expect(required, isNot(contains('_api.isNull')));
    final optional = body('optional');
    expect(optional, contains('final default0 = 0 >= call.argumentCount;'));
    expect(optional, contains('a0 = null;'));
    expect(optional, isNot(contains('omittedOrUndefined')));
    expect(body('named'), contains('_api.presentOption(options, 0,'));
    final named = body('optionalNamed');
    expect(named, contains('final default1 = !options.present[0];'));
    expect(named, contains('final default2 = !options.present[1];'));
    expect(
      named,
      contains('final raw1 = default1 ? nullptr : options.values[0];'),
    );
    expect(
      named,
      contains('final raw2 = default2 ? nullptr : options.values[1];'),
    );
    expect(
      named,
      contains('final default3 = _api.defaultOption(call.env, options, 2);'),
    );
    expect(named, isNot(contains('>= call.argumentCount')));
  });

  test('ordinary modules do not emit the opaque carrier', () async {
    final dart = emitNativeDart(
      await plan('''
import 'package:napi/napi.dart';
@NAPI() int count(int value) => value;
'''),
    );
    expect(dart, isNot(contains('_NapiHostValue')));
    expect(dart, isNot(contains('ownHostValue')));
  });
}
