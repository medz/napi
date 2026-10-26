import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../../sys/node.dart' as node;

typedef _Wrap =
    Int32 Function(Pointer<Void>, node.NapiEnv, node.NapiValue, Int64, IntPtr);

typedef _CreateCallbackData =
    Int32 Function(
      Pointer<Void>,
      IntPtr,
      Pointer<NativeFunction<node.NapiCallback>>,
      Pointer<NativeFunction<node.NapiCallback>>,
      Pointer<Pointer<Void>>,
    );

typedef _TrackFunction =
    Int32 Function(Pointer<Void>, node.NapiValue, Pointer<Void>, Int64);

/// The fixed prefix shared with Owner in src/runtime.cc.
final class _Owner extends Struct {
  external node.NapiThreadsafeFunction threadsafe;
  external Pointer<NativeFunction<_Wrap>> wrap;
  external Pointer<NativeFunction<node.NapiCallback>> callback;
  external Pointer<NativeFunction<node.NapiCallback>> setter;
  external Pointer<NativeFunction<_CreateCallbackData>> createCallbackData;
  external Pointer<NativeFunction<_TrackFunction>> trackFunction;
}

/// The callback record prefix shared with CallbackData in src/runtime.cc.
final class _CallbackData extends Struct {
  external Pointer<Void> owner;
  @IntPtr()
  external int token;
}

final class NativeRuntime {
  NativeRuntime(
    this.env,
    int callJs,
    int owner,
    int finalizer,
    int hasLivePorts,
  ) : _owner = Pointer<_Owner>.fromAddress(owner),
      _hasLivePorts = Pointer<NativeFunction<Bool Function()>>.fromAddress(
        hasLivePorts,
      ).asFunction<bool Function()>() {
    using((arena) {
      final name = arena<Uint16>(4)..asTypedList(4).setAll(0, 'Dart'.codeUnits);
      final resource = arena<node.NapiValue>();
      _check(node.napiCreateStringUtf16(env, name, 4, resource));
      final result = arena<node.NapiThreadsafeFunction>();
      _check(
        node.napiCreateThreadsafeFunction(
          env,
          nullptr,
          nullptr,
          resource.value,
          0,
          1,
          _owner.cast(),
          Pointer<NativeFunction<node.NapiFinalize>>.fromAddress(finalizer),
          _owner.cast(),
          Pointer<
            NativeFunction<node.NapiThreadsafeFunctionCallJs>
          >.fromAddress(callJs),
          result,
        ),
      );
      // Native cleanup must own the TSFN even if later initialization throws.
      _owner.ref.threadsafe = result.value;
      _check(node.napiUnrefThreadsafeFunction(env, result.value));
    });
    _port = RawReceivePort((message) {
      if (!_closed && message is int) onFinalize?.call(message);
    })..keepIsolateAlive = false;
  }

  final node.NapiEnv env;
  final Pointer<_Owner> _owner;
  final bool Function() _hasLivePorts;
  late final RawReceivePort _port;
  void Function(int)? onFinalize;
  bool _closed = false;
  bool _wakePending = false;
  bool _referenced = false;

  int get threadsafeAddress => _owner.ref.threadsafe.address;
  int get ownerAddress => _owner.address;

  Pointer<NativeFunction<node.NapiCallback>> get callback =>
      _owner.ref.callback;
  Pointer<NativeFunction<node.NapiCallback>> get setter => _owner.ref.setter;

  int callbackToken(Pointer<Void> data) => data.cast<_CallbackData>().ref.token;

  int createCallbackData(
    int token,
    Pointer<NativeFunction<node.NapiCallback>> primary,
    Pointer<NativeFunction<node.NapiCallback>> secondary,
    Pointer<Pointer<Void>> output,
  ) => _owner.ref.createCallbackData
      .asFunction<
        int Function(
          Pointer<Void>,
          int,
          Pointer<NativeFunction<node.NapiCallback>>,
          Pointer<NativeFunction<node.NapiCallback>>,
          Pointer<Pointer<Void>>,
        )
      >()(_owner.cast(), token, primary, secondary, output);

  int wrap(node.NapiValue object, int token) => _owner.ref.wrap
      .asFunction<
        int Function(Pointer<Void>, node.NapiEnv, node.NapiValue, int, int)
      >()(_owner.cast(), env, object, _port.sendPort.nativePort, token);

  // A null function abandons an untracked callback record after creation fails.
  int trackFunction(node.NapiValue function, Pointer<Void> data) =>
      _owner.ref.trackFunction
          .asFunction<
            int Function(Pointer<Void>, node.NapiValue, Pointer<Void>, int)
          >()(
        _owner.cast(),
        function,
        data,
        function == nullptr ? 0 : _port.sendPort.nativePort,
      );

  void wake() {
    if (_closed || _wakePending) return;
    _wakePending = true;
    _updateReference();
    _check(
      node.napiCallThreadsafeFunction(
        _owner.ref.threadsafe,
        nullptr,
        node.NapiThreadsafeFunctionCallMode.nonblocking.index,
      ),
    );
  }

  void afterPump() {
    if (_closed) return;
    _wakePending = false;
    _updateReference();
  }

  void _updateReference() {
    final needed = _wakePending || _hasLivePorts();
    if (needed == _referenced) return;
    _check(
      needed
          ? node.napiRefThreadsafeFunction(env, _owner.ref.threadsafe)
          : node.napiUnrefThreadsafeFunction(env, _owner.ref.threadsafe),
    );
    _referenced = needed;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _port.close();
    onFinalize = null;
    // The embedder aborts and releases its TSFN after Dart cleanup.
  }

  static void _check(int status) {
    if (status != node.NapiStatus.ok.index) {
      throw StateError('Cannot initialize Dart event loop: Node-API $status');
    }
  }
}
