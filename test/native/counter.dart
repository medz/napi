import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:napi/sys/node.dart' as node;

final class Counter {
  Counter([this.value = 0]);

  int value;

  int increment([int step = 1]) {
    final next = value + step;
    if (next.abs() > 9007199254740991) {
      throw RangeError('Result exceeds JavaScript safe integers');
    }
    return value = next;
  }
}

final _counters = <int, Counter>{};
var _nextId = 1;

void _check(int status) {
  if (status != node.NapiStatus.ok.index) {
    throw StateError('Node-API status $status');
  }
}

int _integer(node.NapiEnv env, node.NapiValue value, Arena arena) {
  final type = arena<Int32>();
  _check(node.napiTypeof(env, value, type));
  if (type.value != node.NapiValueType.number.index) {
    throw ArgumentError('Expected a JavaScript safe integer');
  }
  final number = arena<Double>();
  _check(node.napiGetValueDouble(env, value, number));
  final result = number.value;
  if (!result.isFinite ||
      result != result.truncateToDouble() ||
      result.abs() > 9007199254740991) {
    throw ArgumentError('Expected a JavaScript safe integer');
  }
  return result.toInt();
}

node.NapiValue _number(node.NapiEnv env, int value, Arena arena) {
  final result = arena<node.NapiValue>();
  _check(node.napiCreateDouble(env, value.toDouble(), result));
  return result.value;
}

node.NapiValue _call(
  node.NapiEnv env,
  node.NapiCallbackInfo info,
  node.NapiValue Function(node.NapiValue?, node.NapiValue, Arena) body,
) => using((arena) {
  try {
    final count = arena<Size>()..value = 1;
    final argument = arena<node.NapiValue>();
    final receiver = arena<node.NapiValue>();
    _check(node.napiGetCbInfo(env, info, count, argument, receiver, nullptr));
    return body(
      count.value == 0 ? null : argument.value,
      receiver.value,
      arena,
    );
  } catch (error) {
    node.napiThrowTypeError(
      env,
      nullptr,
      error.toString().toNativeUtf8(allocator: arena).cast(),
    );
    return nullptr;
  }
});

Counter _receiver(node.NapiEnv env, node.NapiValue receiver, Arena arena) {
  final token = arena<Pointer<Void>>();
  _check(node.napiUnwrap(env, receiver, token));
  final counter = _counters[token.value.address];
  if (counter == null) throw ArgumentError('Invalid Counter receiver');
  return counter;
}

node.NapiValue _construct(node.NapiEnv env, node.NapiCallbackInfo info) =>
    _call(env, info, (argument, receiver, arena) {
      final target = arena<node.NapiValue>();
      _check(node.napiGetNewTarget(env, info, target));
      if (target.value == nullptr) throw ArgumentError('Counter requires new');
      final counter = argument == null
          ? Counter()
          : Counter(_integer(env, argument, arena));
      final id = _nextId++;
      final status = node.napiWrap(
        env,
        receiver,
        Pointer<Void>.fromAddress(id),
        nullptr,
        nullptr,
        nullptr,
      );
      _check(status);
      _counters[id] = counter;
      return receiver;
    });

node.NapiValue _increment(node.NapiEnv env, node.NapiCallbackInfo info) =>
    _call(env, info, (argument, receiver, arena) {
      final counter = _receiver(env, receiver, arena);
      final value = argument == null
          ? counter.increment()
          : counter.increment(_integer(env, argument, arena));
      return _number(env, value, arena);
    });

node.NapiValue _value(node.NapiEnv env, node.NapiCallbackInfo info) =>
    _call(env, info, (_, receiver, arena) {
      return _number(env, _receiver(env, receiver, arena).value, arena);
    });

@pragma('vm:entry-point')
int initialize(
  int envAddress,
  int exportsAddress,
  int callJsAddress,
  int ownerAddress,
  int finalizerAddress,
  int hasLivePortsAddress,
) => using((arena) {
  final env = node.NapiEnv.fromAddress(envAddress);
  final exports = node.NapiValue.fromAddress(exportsAddress);
  final properties = arena<node.NapiPropertyDescriptor>(2);
  properties[0]
    ..utf8name = 'value'.toNativeUtf8(allocator: arena).cast()
    ..getter = Pointer.fromFunction<node.NapiCallback>(_value)
    ..attributes = node.napiEnumerable;
  properties[1]
    ..utf8name = 'increment'.toNativeUtf8(allocator: arena).cast()
    ..method = Pointer.fromFunction<node.NapiCallback>(_increment)
    ..attributes = node.napiWritable | node.napiConfigurable;
  final result = arena<node.NapiValue>();
  final name = 'Counter'.toNativeUtf8(allocator: arena).cast<Char>();
  _check(
    node.napiDefineClass(
      env,
      name,
      node.napiAutoLength,
      Pointer.fromFunction<node.NapiCallback>(_construct),
      nullptr,
      2,
      properties,
      result,
    ),
  );
  _check(node.napiSetNamedProperty(env, exports, name, result.value));
  return 0;
});

@pragma('vm:entry-point')
void afterPump() {}

@pragma('vm:entry-point')
void dispose() => _counters.clear();

void main() {}
