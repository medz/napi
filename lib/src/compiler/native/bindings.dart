import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import '../../runtime/cancellation.dart';
import '../../runtime/resources.dart';
import '../../runtime/retention.dart';

typedef _ReadBinaryNative = Handle Function(
  Pointer<Void>,
  Pointer<Void>,
  Int32,
);
typedef _ReadBinary = Object? Function(Pointer<Void>, Pointer<Void>, int);
typedef _WriteBinaryNative = IntPtr Function(Pointer<Void>, Handle, Int32);
typedef _WriteBinary = int Function(Pointer<Void>, Object, int);

typedef _CallbackHelperNative = Int32 Function(
  Pointer<Void>,
  Int32,
  Pointer<Pointer<Void>>,
);
typedef _CallbackHelper = int Function(
  Pointer<Void>,
  int,
  Pointer<Pointer<Void>>,
);

typedef _CallbackInfoNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Size>,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
);
typedef _CallbackInfo = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Size>,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
);
typedef _QueuePromiseNative = Int32 Function(
  Pointer<Void>,
  Int64,
  Pointer<Void>,
  Bool,
);
typedef _QueuePromise = int Function(Pointer<Void>, int, Pointer<Void>, bool);
typedef _BindCleanupNative = Int32 Function(
  Pointer<Void>,
  Int64,
  Int64,
  Pointer<Pointer<Void>>,
  Pointer<Bool>,
);
typedef _BindCleanup = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Pointer<Void>>,
  Pointer<Bool>,
);
typedef _ObserveFutureNative = Int32 Function(Pointer<Void>, Int64);
typedef _ObserveFuture = int Function(Pointer<Void>, int);
typedef _OwnHostValueNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int64>,
);
typedef _OwnHostValue = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int64>,
);
typedef _HostValueNative = Int32 Function(
  Pointer<Void>,
  Int64,
  Pointer<Pointer<Void>>,
);
typedef _HostValue = int Function(Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _ReleaseHostValueNative = Int32 Function(Pointer<Void>, Int64);
typedef _ReleaseHostValue = int Function(Pointer<Void>, int);
typedef _CallCallbackNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Int64,
  Size,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
);
typedef _CallCallback = int Function(
  Pointer<Void>,
  Pointer<Void>,
  int,
  int,
  Pointer<Pointer<Void>>,
  Pointer<Pointer<Void>>,
);
typedef _CallbackIdentityNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int64>,
);
typedef _CallbackIdentity = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int64>,
);

typedef _TypeNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int32>,
);
typedef _Type = int Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>);
typedef _GetDoubleNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Double>,
);
typedef _GetDouble = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Double>,
);
typedef _CreateDoubleNative = Int32 Function(
  Pointer<Void>,
  Double,
  Pointer<Pointer<Void>>,
);
typedef _CreateDouble = int Function(
  Pointer<Void>,
  double,
  Pointer<Pointer<Void>>,
);
typedef _GetBoolNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Bool>,
);
typedef _GetBool = int Function(Pointer<Void>, Pointer<Void>, Pointer<Bool>);
typedef _CreateBoolNative = Int32 Function(
  Pointer<Void>,
  Bool,
  Pointer<Pointer<Void>>,
);
typedef _CreateBool = int Function(Pointer<Void>, bool, Pointer<Pointer<Void>>);
typedef _SimpleNative = Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _Simple = int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _GetStringNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint16>,
  Size,
  Pointer<Size>,
);
typedef _GetString = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Uint16>,
  int,
  Pointer<Size>,
);
typedef _CreateStringNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint16>,
  Size,
  Pointer<Pointer<Void>>,
);
typedef _CreateString = int Function(
  Pointer<Void>,
  Pointer<Uint16>,
  int,
  Pointer<Pointer<Void>>,
);
typedef _NewTargetNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _NewTarget = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _WrapNative = Int32 Function(Pointer<Void>, Pointer<Void>, Int64);
typedef _Wrap = int Function(Pointer<Void>, Pointer<Void>, int);
typedef _UnwrapNative = Int64 Function(Pointer<Void>, Pointer<Void>);
typedef _Unwrap = int Function(Pointer<Void>, Pointer<Void>);
typedef _ReferenceValueNative = Int32 Function(
  Pointer<Void>,
  Int64,
  Pointer<Pointer<Void>>,
);
typedef _ReferenceValue = int Function(
  Pointer<Void>,
  int,
  Pointer<Pointer<Void>>,
);
typedef _ReferenceCreateNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Int64,
  Pointer<Pointer<Void>>,
);
typedef _ReferenceCreate = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Pointer<Void>>,
);
typedef _RegisterReferenceShapeNative = Int32 Function(
  Pointer<Void>,
  Uint32,
  Pointer<Uint32>,
  Size,
  Pointer<Void>,
);
typedef _RegisterReferenceShape = int Function(
  Pointer<Void>,
  int,
  Pointer<Uint32>,
  int,
  Pointer<Void>,
);
typedef _InspectShapeNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Bool,
  Pointer<Pointer<Void>>,
  Size,
  Pointer<Void>,
  Uint32,
  Uint32,
  Bool,
  Pointer<Uint32>,
);
typedef _InspectShape = int Function(
  Pointer<Void>,
  Pointer<Void>,
  bool,
  Pointer<Pointer<Void>>,
  int,
  Pointer<Void>,
  int,
  int,
  bool,
  Pointer<Uint32>,
);
typedef _ReadOwnValueNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _ReadOwnValue = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _StrictEqualsNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Bool>,
);
typedef _StrictEquals = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Bool>,
);
typedef _CreateContainerNative = Int32 Function(
  Pointer<Void>,
  Bool,
  Uint32,
  Pointer<Pointer<Void>>,
);
typedef _CreateContainer = int Function(
  Pointer<Void>,
  bool,
  int,
  Pointer<Pointer<Void>>,
);
typedef _DefineOwnValueNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _DefineOwnValue = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _SnapshotMapNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Uint32,
  Bool,
  Pointer<Pointer<Void>>,
  Pointer<Uint32>,
);
typedef _SnapshotMap = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  int,
  bool,
  Pointer<Pointer<Void>>,
  Pointer<Uint32>,
);
typedef _DictionaryKeysNative = _SnapshotMapNative;
typedef _DictionaryKeys = _SnapshotMap;
typedef _CheckedInsertMapNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _CheckedInsertMap = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
);
typedef _GetInt64Native = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int64>,
  Pointer<Bool>,
);
typedef _GetInt64 = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int64>,
  Pointer<Bool>,
);
typedef _CreateInt64Native = Int32 Function(
  Pointer<Void>,
  Int64,
  Pointer<Pointer<Void>>,
);
typedef _CreateInt64 = int Function(Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _GetWordsNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int32>,
  Pointer<Size>,
  Pointer<Uint64>,
);
typedef _GetWords = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Int32>,
  Pointer<Size>,
  Pointer<Uint64>,
);
typedef _CreateWordsNative = Int32 Function(
  Pointer<Void>,
  Int32,
  Size,
  Pointer<Uint64>,
  Pointer<Pointer<Void>>,
);
typedef _CreateWords = int Function(
  Pointer<Void>,
  int,
  int,
  Pointer<Uint64>,
  Pointer<Pointer<Void>>,
);
typedef _CreateErrorNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _CreateError = int Function(
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Pointer<Void>>,
);
typedef _ThrowNative = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _Throw = int Function(Pointer<Void>, Pointer<Void>);
typedef _PendingNative = Int32 Function(Pointer<Void>, Pointer<Bool>);
typedef _Pending = int Function(Pointer<Void>, Pointer<Bool>);
typedef _OptionsNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Bool,
  Pointer<Pointer<Uint8>>,
  Size,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);
typedef _Options = int Function(
  Pointer<Void>,
  Pointer<Void>,
  bool,
  Pointer<Pointer<Uint8>>,
  int,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  Pointer<Uint8>,
);
typedef _ConstructorTargetNative = Int32 Function(
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<Bool>,
);
typedef _ConstructorTarget = int Function(
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<Bool>,
);

typedef _CallocNative = Pointer<Void> Function(Size, Size);
typedef _Calloc = Pointer<Void> Function(int, int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);

final _libc = DynamicLibrary.process();
final _calloc = _libc.lookupFunction<_CallocNative, _Calloc>('calloc');
final _free = _libc.lookupFunction<_FreeNative, _Free>('free');

Pointer<T> _allocate<T extends NativeType>(int count, int bytes) {
  final result = _calloc(count == 0 ? 1 : count, bytes);
  if (result == nullptr) throw StateError('Native allocation failed');
  return result.cast<T>();
}

Pointer<Uint8> _utf8(String value) {
  final bytes = utf8.encode(value);
  final result = _allocate<Uint8>(bytes.length + 1, 1);
  result.asTypedList(bytes.length).setAll(0, bytes);
  return result;
}

final class NapiTypeError implements Exception {
  final String message;
  NapiTypeError(this.message);
  @override
  String toString() => message;
}

final class NapiRangeError implements Exception {
  final String message;
  NapiRangeError(this.message);
  @override
  String toString() => message;
}

final class NapiCall {
  final Pointer<Void> env;
  final Pointer<Void> info;
  final Pointer<Void> self;
  final List<Pointer<Void>> arguments;
  final int argumentCount;
  NapiCall(this.env, this.info, this.self, this.arguments, this.argumentCount);
}

final class NapiOptions {
  final List<Pointer<Void>> values;
  final List<bool> present;
  NapiOptions(this.values, this.present);
}

final class _ReferenceLease {
  final int id;
  final int classId;
  const _ReferenceLease(this.id, this.classId);
}

// This record owns Dart values, never borrowed Node handles or callback info.
// C acknowledges after calling the JS resolver, which can reenter Dart.
final class _PendingFuture {
  List<Object?> roots = const [];
  OperationLease? operation;
  bool claimed = false;
}

/// Compiler-private ownership of an arbitrary JS value in one native isolate.
/// Strong cross-heap cycles require an explicit ownership break.
final class NativeHostValue {
  final NapiApi _api;
  int _slot;
  NativeHostValue._(this._api, this._slot);

  /// Release once from this owner's active Dart callback or event pump.
  void release() {
    if (_slot == 0) return;
    _api._check(_api._releaseHostValue(_api._hostEnv!, _slot));
    _slot = 0;
    _api._hostFinalizer.detach(this);
  }
}

// A caught JS throw owns its payload independently of the borrowed call frame.
// Dart may retain and rethrow it after that frame's handles have expired.
final class _NativeJsException implements Exception {
  final NativeHostValue value;
  _NativeJsException(this.value);
}

// The source signal owns only a weak host listener. Ordinary Dart reachability
// owns this control and its source; waiting for abort never creates a strong
// pending callback entry.
final class _NativeAbortSignal extends NapiAbortSignal {
  final NapiApi _api;
  final Pointer<Void> _env;
  final NativeHostValue _control;
  late final _NativeSignalEntry _entry;
  _NativeAbortSignal(this._api, this._env, this._control);

  T _command<T>(
    int operation,
    T Function(Pointer<Void>, Pointer<Void>) read, [
    int token = 0,
  ]) => _api._invokeCallback(
    _env,
    nullptr,
    2,
    (env, arguments) {
      arguments[0] = Pointer.fromAddress(
        _api.integerResult(env, operation, 'signal operation'),
      );
      arguments[1] = Pointer.fromAddress(
        _api.integerResult(env, token, 'signal token'),
      );
    },
    read,
    owned: _control,
  );

  @override
  bool get aborted =>
      _command(0, (env, value) => _api.boolean(env, value, 'signal.aborted'));

  @override
  void throwIfAborted() => _command<void>(1, (_, _) {});

  @override
  void armAbort() {
    final token = _api._nextCallback++;
    if (token > 9007199254740991) {
      throw StateError('Native callback token space exhausted');
    }
    _entry.delivery = token;
    (_api._signalDeliveries ??= {})[token] = _entry;
    try {
      _command<void>(2, (_, _) {}, token);
    } catch (_) {
      _api._signalDeliveries!.remove(token);
      _entry.delivery = 0;
      rethrow;
    }
  }

  @override
  void disarmAbort() {
    _api._signalDeliveries?.remove(_entry.delivery);
    _entry.delivery = 0;
    _command<void>(3, (_, _) {});
  }
}

final class _NativeSignalEntry {
  final int identity;
  final WeakReference<_NativeAbortSignal> target;
  int delivery = 0;
  _NativeSignalEntry(this.identity, _NativeAbortSignal signal)
    : target = WeakReference(signal);
}

// The typed adapter owns this handle by ordinary Dart reachability. The weak
// identity cache never owns the adapter or the JavaScript function.
final class NativeCallback {
  final NapiApi _api;
  final Pointer<Void> _env;
  final NativeHostValue _function;
  NativeCallback._(this._api, this._env, this._function);

  T invoke<T>(
    int argc,
    void Function(Pointer<Void>, Pointer<Pointer<Void>>) write,
    T Function(Pointer<Void>, Pointer<Void>) read,
  ) => _api._invokeCallback(_env, nullptr, argc, write, read, owned: _function);

  Future<T> invokeFuture<T>(
    Function adapter,
    int argc,
    void Function(Pointer<Void>, Pointer<Pointer<Void>>) write,
    T Function(Pointer<Void>, Pointer<Void>) read,
  ) {
    final completion = Completer<T>();
    final token = _api._nextCallback++;
    if (token > 9007199254740991) {
      throw StateError('Native callback token space exhausted');
    }
    _api._pendingCallbacks[token] = _NativeCallbackPending(adapter, (
      env,
      value,
      rejected,
    ) {
      try {
        if (rejected) throw _NativeJsException(_api.ownHostValue(env, value));
        completion.complete(read(env, value));
      } catch (error, stack) {
        completion.completeError(_api._callbackError(env, error), stack);
      }
    });
    try {
      final observer = _api._getCallbackHelper(_env, 1);
      _api._invokeCallback<void>(_env, observer, argc + 2, (env, args) {
        _api._borrowHostValue(env, _function, args);
        args[1] = Pointer.fromAddress(
          _api.integerResult(env, token, 'callback token'),
        );
        write(env, args + 2);
      }, (_, _) {});
    } catch (_) {
      _api._pendingCallbacks.remove(token);
      rethrow;
    }
    return completion.future;
  }
}

final class _NativeCallbackPending {
  final Function adapter;
  final void Function(Pointer<Void>, Pointer<Void>, bool) complete;
  _NativeCallbackPending(this.adapter, this.complete);
}

final class _NativeCallbackCacheEntry {
  final WeakReference<Function> adapter;
  final int generation;
  _NativeCallbackCacheEntry(Function value, this.generation)
    : adapter = WeakReference(value);
}

/// Private Node-API table used by generated AOT entrypoints.
/// Every temporary native buffer is scoped to one call; no global scratch state.
final class NapiApi {
  final Pointer<Pointer<Void>> _table;
  final int Function(Object, String)? referenceClass;
  final List<int> Function(Object)? referenceViews;
  final List<Set<int>> classMemberships;
  NapiApi(
    int address,
    int tableCount, {
    this.referenceClass,
    this.referenceViews,
    this.classMemberships = const [],
  }) : _table = Pointer.fromAddress(address) {
    if (address == 0 || tableCount != 57) {
      throw StateError('Incompatible native bridge ABI (expected 57 slots).');
    }
  }
  late final _CallbackInfo _callbackInfo = _table[0]
      .cast<NativeFunction<_CallbackInfoNative>>()
      .asFunction<_CallbackInfo>();
  late final _Type _type = _table[1]
      .cast<NativeFunction<_TypeNative>>()
      .asFunction<_Type>();
  late final _GetDouble _getDouble = _table[2]
      .cast<NativeFunction<_GetDoubleNative>>()
      .asFunction<_GetDouble>();
  late final _CreateDouble _createDouble = _table[3]
      .cast<NativeFunction<_CreateDoubleNative>>()
      .asFunction<_CreateDouble>();
  late final _Simple _undefined = _table[6]
      .cast<NativeFunction<_SimpleNative>>()
      .asFunction<_Simple>();
  late final _Simple _null = _table[7]
      .cast<NativeFunction<_SimpleNative>>()
      .asFunction<_Simple>();
  late final _GetString _getString = _table[8]
      .cast<NativeFunction<_GetStringNative>>()
      .asFunction<_GetString>();
  late final _CreateString _createString = _table[9]
      .cast<NativeFunction<_CreateStringNative>>()
      .asFunction<_CreateString>();
  late final _NewTarget _newTarget = _table[10]
      .cast<NativeFunction<_NewTargetNative>>()
      .asFunction<_NewTarget>();
  late final _Wrap _wrap = _table[14]
      .cast<NativeFunction<_WrapNative>>()
      .asFunction<_Wrap>();
  late final _Unwrap _unwrap = _table[15]
      .cast<NativeFunction<_UnwrapNative>>()
      .asFunction<_Unwrap>();
  late final _GetBool _getBool = _table[16]
      .cast<NativeFunction<_GetBoolNative>>()
      .asFunction<_GetBool>();
  late final _CreateBool _createBool = _table[17]
      .cast<NativeFunction<_CreateBoolNative>>()
      .asFunction<_CreateBool>();
  late final _GetInt64 _getInt64 = _table[18]
      .cast<NativeFunction<_GetInt64Native>>()
      .asFunction<_GetInt64>();
  late final _CreateInt64 _createInt64 = _table[19]
      .cast<NativeFunction<_CreateInt64Native>>()
      .asFunction<_CreateInt64>();
  late final _GetWords _getWords = _table[20]
      .cast<NativeFunction<_GetWordsNative>>()
      .asFunction<_GetWords>();
  late final _CreateWords _createWords = _table[21]
      .cast<NativeFunction<_CreateWordsNative>>()
      .asFunction<_CreateWords>();
  late final _CreateError _createError = _table[22]
      .cast<NativeFunction<_CreateErrorNative>>()
      .asFunction<_CreateError>();
  late final _CreateError _createTypeError = _table[23]
      .cast<NativeFunction<_CreateErrorNative>>()
      .asFunction<_CreateError>();
  late final _CreateError _createRangeError = _table[24]
      .cast<NativeFunction<_CreateErrorNative>>()
      .asFunction<_CreateError>();
  late final _Throw _throw = _table[25]
      .cast<NativeFunction<_ThrowNative>>()
      .asFunction<_Throw>();
  late final _Pending _pending = _table[26]
      .cast<NativeFunction<_PendingNative>>()
      .asFunction<_Pending>();
  late final _Options _options = _table[27]
      .cast<NativeFunction<_OptionsNative>>()
      .asFunction<_Options>();
  late final _ReferenceValue _referenceValue = _table[28]
      .cast<NativeFunction<_ReferenceValueNative>>()
      .asFunction<_ReferenceValue>();
  late final _ReferenceCreate _referenceCreate = _table[29]
      .cast<NativeFunction<_ReferenceCreateNative>>()
      .asFunction<_ReferenceCreate>();
  late final _InspectShape _inspectShape = _table[30]
      .cast<NativeFunction<_InspectShapeNative>>()
      .asFunction<_InspectShape>();
  late final _ReadOwnValue _readOwnValue = _table[31]
      .cast<NativeFunction<_ReadOwnValueNative>>()
      .asFunction<_ReadOwnValue>();
  late final _StrictEquals _strictEquals = _table[32]
      .cast<NativeFunction<_StrictEqualsNative>>()
      .asFunction<_StrictEquals>();
  late final _CreateContainer _createContainer = _table[33]
      .cast<NativeFunction<_CreateContainerNative>>()
      .asFunction<_CreateContainer>();
  late final _DefineOwnValue _defineOwnValue = _table[34]
      .cast<NativeFunction<_DefineOwnValueNative>>()
      .asFunction<_DefineOwnValue>();
  late final _SnapshotMap _snapshotMap = _table[35]
      .cast<NativeFunction<_SnapshotMapNative>>()
      .asFunction<_SnapshotMap>();
  late final _Simple _createMap = _table[36]
      .cast<NativeFunction<_SimpleNative>>()
      .asFunction<_Simple>();
  late final _CheckedInsertMap _checkedInsertMap = _table[37]
      .cast<NativeFunction<_CheckedInsertMapNative>>()
      .asFunction<_CheckedInsertMap>();
  late final _DictionaryKeys _dictionaryKeys = _table[38]
      .cast<NativeFunction<_DictionaryKeysNative>>()
      .asFunction<_DictionaryKeys>();
  late final _Simple _createDictionary = _table[39]
      .cast<NativeFunction<_SimpleNative>>()
      .asFunction<_Simple>();
  late final _ReadOwnValue _readOptionalOwnValue = _table[40]
      .cast<NativeFunction<_ReadOwnValueNative>>()
      .asFunction<_ReadOwnValue>();
  late final _ConstructorTarget _constructorTarget = _table[41]
      .cast<NativeFunction<_ConstructorTargetNative>>()
      .asFunction<_ConstructorTarget>();
  late final _RegisterReferenceShape _registerReferenceShape = _table[42]
      .cast<NativeFunction<_RegisterReferenceShapeNative>>()
      .asFunction<_RegisterReferenceShape>();
  late final _QueuePromise _queuePromise = _table[43]
      .cast<NativeFunction<_QueuePromiseNative>>()
      .asFunction<_QueuePromise>();
  late final _futures = <int, _PendingFuture>{};
  late final _BindCleanup _bindCleanup = _table[44]
      .cast<NativeFunction<_BindCleanupNative>>()
      .asFunction<_BindCleanup>();
  late final _ObserveFuture _observeFuture = _table[45]
      .cast<NativeFunction<_ObserveFutureNative>>()
      .asFunction<_ObserveFuture>();
  late final _OwnHostValue _ownHostValue = _table[46]
      .cast<NativeFunction<_OwnHostValueNative>>()
      .asFunction<_OwnHostValue>();
  late final _HostValue _hostValue = _table[47]
      .cast<NativeFunction<_HostValueNative>>()
      .asFunction<_HostValue>();
  late final _ReleaseHostValue _releaseHostValue = _table[48]
      .cast<NativeFunction<_ReleaseHostValueNative>>()
      .asFunction<_ReleaseHostValue>();
  late final _Simple _openCallbackHandles = _table[49]
      .cast<NativeFunction<_SimpleNative>>()
      .asFunction<_Simple>();
  late final _Throw _closeCallbackHandles = _table[50]
      .cast<NativeFunction<_ThrowNative>>()
      .asFunction<_Throw>();
  late final _CallCallback _callCallback = _table[51]
      .cast<NativeFunction<_CallCallbackNative>>()
      .asFunction<_CallCallback>();
  late final _Simple _takeCallbackException = _table[52]
      .cast<NativeFunction<_SimpleNative>>()
      .asFunction<_Simple>();
  late final _CallbackHelper _callbackHelper = _table[53]
      .cast<NativeFunction<_CallbackHelperNative>>()
      .asFunction<_CallbackHelper>();
  late final _CallbackIdentity _callbackIdentity = _table[54]
      .cast<NativeFunction<_CallbackIdentityNative>>()
      .asFunction<_CallbackIdentity>();
  late final _ReadBinary _readBinary = _table[55]
      .cast<NativeFunction<_ReadBinaryNative>>()
      .asFunction<_ReadBinary>();
  late final _WriteBinary _writeBinary = _table[56]
      .cast<NativeFunction<_WriteBinaryNative>>()
      .asFunction<_WriteBinary>();

  /// Snapshot the freshly validated JS view before Dart business materializes.
  Object? binary(
    Pointer<Void> env,
    Pointer<Void> value,
    int kind,
    String path, {
    bool nullable = false,
  }) => _invokeCallback(
    env,
    _getCallbackHelper(env, 0),
    4,
    (env, args) {
      args[0] = value;
      args[1] = Pointer.fromAddress(integerResult(env, kind, 'binary kind'));
      args[2] = Pointer.fromAddress(booleanResult(env, nullable));
      args[3] = Pointer.fromAddress(stringResult(env, path));
    },
    (env, view) {
      if (nullable && isNull(env, view)) return null;
      final result = _readBinary(env, view, kind);
      if (result == null) {
        throw _callbackError(
          env,
          StateError('$path: native binary copy failed'),
        );
      }
      return result;
    },
  );

  /// Copy Dart bytes into JS-owned storage; no source pointer escapes the slot.
  int binaryResult(Pointer<Void> env, Object value, int kind, String path) {
    final bytes = kind == 0
        ? value as Uint8List
        : (value as ByteBuffer).asUint8List();
    if (bytes.lengthInBytes > 0x7fffffff) {
      throw NapiRangeError('$path: binary byte length exceeds 2147483647');
    }
    final result = _writeBinary(env, bytes, kind);
    if (result == 0) {
      throw _callbackError(env, StateError('$path: native binary copy failed'));
    }
    return result;
  }

  late final _callbackAdapters =
      <String, Map<int, _NativeCallbackCacheEntry>>{};
  late final _callbackFinalizer = Zone.root.run(
    () => Finalizer<(String, int, int)>((token) {
      final entries = _callbackAdapters[token.$1];
      if (entries?[token.$2]?.generation == token.$3) {
        entries!.remove(token.$2);
      }
    }),
  );
  var _nextCallbackAdapter = 0;
  var _nextCallback = 1;
  late final _pendingCallbacks = <int, _NativeCallbackPending>{};
  late final _signals = <int, _NativeSignalEntry>{};
  Map<int, _NativeSignalEntry>? _signalDeliveries;
  late final _signalFinalizer = Zone.root.run(
    () => Finalizer<_NativeSignalEntry>((entry) {
      if (identical(_signals[entry.identity], entry)) {
        _signals.remove(entry.identity);
      }
      if (identical(_signalDeliveries?[entry.delivery], entry)) {
        _signalDeliveries!.remove(entry.delivery);
      }
    }),
  );

  NapiAbortSignal abortSignal(
    Pointer<Void> env,
    Pointer<Void> value,
    String path,
  ) {
    if (typeOf(env, value) != 6) {
      throw NapiTypeError('$path: expected AbortSignal');
    }
    final identity = _hostIdentity(env, value);
    final previous = _signals[identity]?.target.target;
    if (previous != null) return previous;
    final control = _invokeCallback(env, _getCallbackHelper(env, 1), 3, (
      env,
      arguments,
    ) {
      arguments[0] = Pointer.fromAddress(nullResult(env));
      arguments[1] = value;
      arguments[2] = Pointer.fromAddress(stringResult(env, path));
    }, ownHostValue);
    try {
      final signal = _NativeAbortSignal(this, env, control);
      final entry = _NativeSignalEntry(identity, signal);
      signal._entry = entry;
      _signals[identity] = entry;
      _signalFinalizer.attach(signal, entry);
      return signal;
    } catch (_) {
      control.release();
      rethrow;
    }
  }

  int _hostIdentity(Pointer<Void> env, Pointer<Void> value) {
    final out = _allocate<Int64>(1, sizeOf<Int64>());
    try {
      _check(_callbackIdentity(env, value, out));
      return out.value;
    } catch (error, stack) {
      Error.throwWithStackTrace(_callbackError(env, error), stack);
    } finally {
      _free(out.cast());
    }
  }

  void checkCallback(Pointer<Void> env, Pointer<Void> value, String path) {
    if (typeOf(env, value) != 7) {
      throw NapiTypeError('$path: expected function');
    }
  }

  T callback<T extends Function>(
    Pointer<Void> env,
    Pointer<Void> value,
    String signature,
    String path,
    T Function(NativeCallback) create, {
    bool prechecked = false,
  }) {
    if (!prechecked) checkCallback(env, value, path);
    final identity = _hostIdentity(env, value);
    // Signatures are bounded by this module's declarations. Separate integer
    // keys avoid allocating a tuple on every cache hit.
    final entries = _callbackAdapters[signature] ??= {};
    final existing = entries[identity]?.adapter.target;
    if (existing != null) return existing as T;
    final function = NativeCallback._(this, env, ownHostValue(env, value));
    try {
      final adapter = create(function);
      final entry = _NativeCallbackCacheEntry(adapter, ++_nextCallbackAdapter);
      entries[identity] = entry;
      _callbackFinalizer.attach(adapter, (
        signature,
        identity,
        entry.generation,
      ));
      return adapter;
    } catch (_) {
      function._function.release();
      rethrow;
    }
  }

  /// Owner-pump entry only; no borrowed handle escapes this synchronous drain.
  Object? acceptCallback(
    int envAddress,
    int token,
    bool rejected,
    int valueAddress,
  ) {
    final env = Pointer<Void>.fromAddress(envAddress);
    if (_hostEnv != env) {
      throw StateError('Callback completed in a different environment');
    }
    final signalEntry = _signalDeliveries?.remove(token);
    if (signalEntry != null) {
      signalEntry.delivery = 0;
      final signal = signalEntry.target.target;
      signal?.notifyAbort();
      // Return the live token through the C handle scope, just like the typed
      // adapter below. The weak queue does not become a persistent Dart root.
      return signal;
    }
    final entry = _pendingCallbacks.remove(token);
    if (entry == null) return null;
    entry.complete(env, Pointer<Void>.fromAddress(valueAddress), rejected);
    // Return the typed adapter through the native root entrypoint so AOT cannot
    // discard this root as a write-only field. The Dart API handle keeps it
    // alive until the owner drain's scope exits, after payload conversion.
    return entry.adapter;
  }

  Pointer<Void> _getCallbackHelper(Pointer<Void> env, int kind) =>
      Pointer.fromAddress(_result((out) => _callbackHelper(env, kind, out)));

  Object _callbackError(Pointer<Void> env, Object error) {
    if (!_hasPending(env)) return error;
    final value = Pointer<Void>.fromAddress(
      _result((out) => _takeCallbackException(env, out)),
    );
    return _NativeJsException(ownHostValue(env, value));
  }

  T _invokeCallback<T>(
    Pointer<Void> env,
    Pointer<Void> function,
    int argc,
    void Function(Pointer<Void>, Pointer<Pointer<Void>>) write,
    T Function(Pointer<Void>, Pointer<Void>) read, {
    NativeHostValue? owned,
  }) {
    // Scope and result occupy the last two slots of one temporary buffer.
    final buffer = _allocate<Pointer<Void>>(argc + 2, sizeOf<Pointer<Void>>());
    final scope = buffer + argc;
    final result = scope + 1;
    var opened = false;
    try {
      _check(_openCallbackHandles(env, scope));
      opened = true;
      try {
        if (owned != null) _checkHostValue(env, owned);
        write(env, buffer);
        _check(
          _callCallback(env, function, owned?._slot ?? 0, argc, buffer, result),
        );
        return read(env, result.value);
      } catch (error, stack) {
        Error.throwWithStackTrace(_callbackError(env, error), stack);
      }
    } finally {
      try {
        if (opened) _check(_closeCallbackHandles(env, scope.value));
      } finally {
        _free(buffer.cast());
      }
    }
  }

  Pointer<Void>? _hostEnv;
  late final _hostFinalizer = Zone.root.run(
    () => Finalizer<int>((slot) {
      // Core finalizers are ordinary owner-pump events, not C GC callbacks.
      // Never throw from a finalizer; environment teardown drops any leftovers.
      _releaseHostValue(_hostEnv!, slot);
    }),
  );
  late final _cleanupIds = Expando<int>('native resource cleanup');
  var _nextCleanup = 1;
  // Only an attached JS lease retains its Dart value. The identity cache's
  // weak keys and primitive records cannot keep either heap alive by themselves.
  final _owners = <int, Object>{};
  final _references = Expando<_ReferenceLease>('native reference lease');
  // These caches contain selected type IDs only, never business objects.
  late final _referenceShapes = <String, int>{};
  late final _shapeMemberships = <int, Set<int>>{};
  var _nextOwner = 1;

  void _check(int status) {
    if (status != 0) throw StateError('Node-API operation failed ($status)');
  }

  /// Retain without reading payload properties or coercing its value.
  NativeHostValue ownHostValue(Pointer<Void> env, Pointer<Void> value) {
    if (_hostEnv != null && _hostEnv != env) {
      throw StateError('Native host value belongs to a different environment.');
    }
    final out = _allocate<Int64>(1, sizeOf<Int64>());
    try {
      _check(_ownHostValue(env, value, out));
      _hostEnv = env;
      try {
        final owned = NativeHostValue._(this, out.value);
        _hostFinalizer.attach(owned, out.value, detach: owned);
        return owned;
      } catch (_) {
        _releaseHostValue(env, out.value);
        rethrow;
      }
    } finally {
      _free(out.cast());
    }
  }

  /// Borrow a live value only for the current Node callback's handle scope.
  Pointer<Void> hostValue(Pointer<Void> env, NativeHostValue value) {
    final out = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
    try {
      _borrowHostValue(env, value, out);
      return out.value;
    } finally {
      _free(out.cast());
    }
  }

  void _borrowHostValue(
    Pointer<Void> env,
    NativeHostValue value,
    Pointer<Pointer<Void>> out,
  ) {
    _checkHostValue(env, value);
    _check(_hostValue(env, value._slot, out));
  }

  void _checkHostValue(Pointer<Void> env, NativeHostValue value) {
    if (!identical(value._api, this) || _hostEnv != env) {
      throw StateError('Native host value belongs to a different owner.');
    }
    if (value._slot == 0) throw StateError('Native host value is released.');
  }

  int _result(int Function(Pointer<Pointer<Void>>) create) {
    final out = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
    try {
      _check(create(out));
      return out.value.address;
    } finally {
      _free(out.cast());
    }
  }

  NapiCall call(int envAddress, int infoAddress, int capacity) {
    final env = Pointer<Void>.fromAddress(envAddress);
    final info = Pointer<Void>.fromAddress(infoAddress);
    Pointer<Size> count = nullptr;
    Pointer<Pointer<Void>> arguments = nullptr;
    Pointer<Pointer<Void>> self = nullptr;
    try {
      count = _allocate<Size>(1, sizeOf<Size>());
      arguments = _allocate<Pointer<Void>>(capacity, sizeOf<Pointer<Void>>());
      self = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
      count.value = 0;
      _check(_callbackInfo(env, info, count, nullptr, self, nullptr));
      final actual = count.value;
      count.value = capacity;
      _check(_callbackInfo(env, info, count, arguments, self, nullptr));
      return NapiCall(env, info, self.value, [
        for (var i = 0; i < capacity; i++) arguments[i],
      ], actual);
    } finally {
      _free(self.cast());
      _free(arguments.cast());
      _free(count.cast());
    }
  }

  int typeOf(Pointer<Void> env, Pointer<Void> value) {
    final out = _allocate<Int32>(1, sizeOf<Int32>());
    try {
      _check(_type(env, value, out));
      return out.value;
    } finally {
      _free(out.cast());
    }
  }

  bool omittedOrUndefined(NapiCall call, int index) =>
      index >= call.argumentCount ||
      typeOf(call.env, call.arguments[index]) == 0;
  bool isNull(Pointer<Void> env, Pointer<Void> value) =>
      typeOf(env, value) == 1;
  Pointer<Void> requiredArgument(NapiCall call, int index, String path) {
    if (omittedOrUndefined(call, index)) {
      throw NapiTypeError('$path: missing required argument');
    }
    return call.arguments[index];
  }

  Pointer<Void> presentArgument(NapiCall call, int index, String path) {
    if (index >= call.argumentCount) {
      throw NapiTypeError('$path: missing required argument');
    }
    return call.arguments[index];
  }

  Pointer<Void> presentOption(NapiOptions options, int index, String path) {
    if (!options.present[index]) {
      throw NapiTypeError('$path: missing required argument');
    }
    return options.values[index];
  }

  Pointer<Void> requiredOption(
    Pointer<Void> env,
    NapiOptions options,
    int index,
    String path,
  ) {
    if (!options.present[index] || typeOf(env, options.values[index]) == 0) {
      throw NapiTypeError('$path: missing required argument');
    }
    return options.values[index];
  }

  bool defaultOption(Pointer<Void> env, NapiOptions options, int index) =>
      !options.present[index] || typeOf(env, options.values[index]) == 0;

  NapiOptions options(
    NapiCall call,
    int position,
    List<String> names,
    String context,
  ) {
    Pointer<Pointer<Uint8>> keys = nullptr;
    Pointer<Pointer<Void>> values = nullptr;
    Pointer<Uint8> present = nullptr;
    Pointer<Uint8> path = nullptr;
    try {
      keys = _allocate<Pointer<Uint8>>(names.length, sizeOf<Pointer<Uint8>>());
      values = _allocate<Pointer<Void>>(names.length, sizeOf<Pointer<Void>>());
      present = _allocate<Uint8>(names.length, 1);
      path = _utf8(context);
      for (var i = 0; i < names.length; i++) {
        keys[i] = _utf8(names[i]);
      }
      final supplied = position < call.argumentCount;
      _check(
        _options(
          call.env,
          supplied ? call.arguments[position] : nullptr,
          supplied,
          keys,
          names.length,
          values,
          present,
          path,
        ),
      );
      return NapiOptions(
        [for (var i = 0; i < names.length; i++) values[i]],
        [for (var i = 0; i < names.length; i++) present[i] != 0],
      );
    } finally {
      if (keys != nullptr) {
        for (var i = 0; i < names.length; i++) {
          if (keys[i] != nullptr) _free(keys[i].cast());
        }
      }
      _free(path.cast());
      _free(present.cast());
      _free(values.cast());
      _free(keys.cast());
    }
  }

  void _expect(
    Pointer<Void> env,
    Pointer<Void> value,
    int type,
    String name,
    String path, {
    bool nullable = false,
  }) {
    if (typeOf(env, value) != type) {
      throw NapiTypeError(
        '$path: expected a JavaScript $name${nullable ? ' or null' : ''}',
      );
    }
  }

  int integer(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, {
    bool nullable = false,
  }) {
    final number = doubleValue(env, value, path, nullable: nullable);
    if (!number.isFinite ||
        number.truncateToDouble() != number ||
        number.abs() > 9007199254740991) {
      throw NapiRangeError('$path: expected a safe integer');
    }
    return number.toInt();
  }

  double doubleValue(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, {
    bool nullable = false,
  }) {
    _expect(env, value, 3, 'number', path, nullable: nullable);
    final out = _allocate<Double>(1, sizeOf<Double>());
    try {
      _check(_getDouble(env, value, out));
      return out.value;
    } finally {
      _free(out.cast());
    }
  }

  bool boolean(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, {
    bool nullable = false,
  }) {
    _expect(env, value, 2, 'boolean', path, nullable: nullable);
    final out = _allocate<Bool>(1, sizeOf<Bool>());
    try {
      _check(_getBool(env, value, out));
      return out.value;
    } finally {
      _free(out.cast());
    }
  }

  String string(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, {
    bool nullable = false,
  }) {
    _expect(env, value, 4, 'string', path, nullable: nullable);
    final length = _allocate<Size>(1, sizeOf<Size>());
    try {
      _check(_getString(env, value, nullptr, 0, length));
      final capacity = length.value + 1;
      final buffer = _allocate<Uint16>(capacity, sizeOf<Uint16>());
      try {
        _check(_getString(env, value, buffer, capacity, length));
        return String.fromCharCodes(buffer.asTypedList(length.value));
      } finally {
        _free(buffer.cast());
      }
    } finally {
      _free(length.cast());
    }
  }

  int integerBigInt(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, {
    bool nullable = false,
  }) {
    _expect(env, value, 9, 'bigint', path, nullable: nullable);
    Pointer<Int64> out = nullptr;
    Pointer<Bool> lossless = nullptr;
    try {
      out = _allocate<Int64>(1, sizeOf<Int64>());
      lossless = _allocate<Bool>(1, sizeOf<Bool>());
      _check(_getInt64(env, value, out, lossless));
      if (!lossless.value) {
        throw NapiRangeError('$path: expected a signed 64-bit Dart int');
      }
      return out.value;
    } finally {
      _free(lossless.cast());
      _free(out.cast());
    }
  }

  BigInt bigInteger(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, {
    bool nullable = false,
  }) {
    _expect(env, value, 9, 'bigint', path, nullable: nullable);
    Pointer<Size> count = nullptr;
    Pointer<Int32> sign = nullptr;
    try {
      count = _allocate<Size>(1, sizeOf<Size>());
      sign = _allocate<Int32>(1, sizeOf<Int32>());
      _check(_getWords(env, value, nullptr, count, nullptr));
      final words = _allocate<Uint64>(count.value, sizeOf<Uint64>());
      try {
        _check(_getWords(env, value, sign, count, words));
        var result = BigInt.zero;
        for (var i = count.value - 1; i >= 0; i--) {
          final word = words[i];
          result =
              (result << 64) |
              (BigInt.from((word >> 32) & 0xffffffff) << 32) |
              BigInt.from(word & 0xffffffff);
        }
        return sign.value == 0 ? result : -result;
      } finally {
        _free(words.cast());
      }
    } finally {
      _free(sign.cast());
      _free(count.cast());
    }
  }

  int undefinedResult(Pointer<Void> env) =>
      _result((out) => _undefined(env, out));
  int nullResult(Pointer<Void> env) => _result((out) => _null(env, out));
  int integerResult(Pointer<Void> env, int value, String path) {
    if (value < -9007199254740991 || value > 9007199254740991) {
      throw NapiRangeError('$path: expected a safe integer');
    }
    return doubleResult(env, value.toDouble());
  }

  int doubleResult(Pointer<Void> env, double value) =>
      _result((out) => _createDouble(env, value, out));
  int booleanResult(Pointer<Void> env, bool value) =>
      _result((out) => _createBool(env, value, out));
  int stringResult(Pointer<Void> env, String value) {
    final units = value.codeUnits;
    final buffer = _allocate<Uint16>(units.length + 1, sizeOf<Uint16>());
    try {
      buffer.asTypedList(units.length).setAll(0, units);
      return _result((out) => _createString(env, buffer, units.length, out));
    } finally {
      _free(buffer.cast());
    }
  }

  int integerBigIntResult(Pointer<Void> env, int value) =>
      _result((out) => _createInt64(env, value, out));
  int bigIntegerResult(Pointer<Void> env, BigInt value) {
    var remaining = value.abs();
    final count = (remaining.bitLength + 63) ~/ 64;
    final words = _allocate<Uint64>(count, sizeOf<Uint64>());
    final mask = (BigInt.one << 64) - BigInt.one;
    try {
      for (var i = 0; i < count; i++) {
        words[i] = (remaining & mask).toSigned(64).toInt();
        remaining >>= 64;
      }
      return _result(
        (out) => _createWords(env, value.isNegative ? 1 : 0, count, words, out),
      );
    } finally {
      _free(words.cast());
    }
  }

  int inspectShape(
    Pointer<Void> env,
    Pointer<Void> input,
    bool array,
    List<String> fields,
    String path,
    int remaining,
    int depth,
    bool cyclic,
  ) {
    Pointer<Pointer<Void>> keys = nullptr;
    Pointer<Uint32> length = nullptr;
    try {
      keys = _allocate<Pointer<Void>>(fields.length, sizeOf<Pointer<Void>>());
      length = _allocate<Uint32>(1, sizeOf<Uint32>());
      for (var i = 0; i < fields.length; i++) {
        keys[i] = Pointer<Void>.fromAddress(stringResult(env, fields[i]));
      }
      final context = Pointer<Void>.fromAddress(stringResult(env, path));
      _check(
        _inspectShape(
          env,
          input,
          array,
          keys,
          fields.length,
          context,
          remaining,
          depth,
          cyclic,
          length,
        ),
      );
      return length.value;
    } finally {
      _free(length.cast());
      _free(keys.cast());
    }
  }

  Pointer<Void> readOwnValue(
    Pointer<Void> env,
    Pointer<Void> input,
    String key,
    String path,
  ) {
    final name = Pointer<Void>.fromAddress(stringResult(env, key));
    final context = Pointer<Void>.fromAddress(stringResult(env, path));
    return Pointer<Void>.fromAddress(
      _result((out) => _readOwnValue(env, input, name, context, out)),
    );
  }

  // A missing descriptor is the only nullptr result. JS undefined is a real
  // value and remains distinct until the optional parameter policy is applied.
  Pointer<Void> readOptionalOwnValue(
    Pointer<Void> env,
    Pointer<Void> input,
    String key,
    String path,
  ) {
    final name = Pointer<Void>.fromAddress(stringResult(env, key));
    final context = Pointer<Void>.fromAddress(stringResult(env, path));
    return Pointer<Void>.fromAddress(
      _result((out) => _readOptionalOwnValue(env, input, name, context, out)),
    );
  }

  bool isUndefined(Pointer<Void> env, Pointer<Void> value) =>
      typeOf(env, value) == 0;

  bool strictEquals(
    Pointer<Void> env,
    Pointer<Void> left,
    Pointer<Void> right,
  ) {
    final result = _allocate<Bool>(1, sizeOf<Bool>());
    try {
      _check(_strictEquals(env, left, right, result));
      return result.value;
    } finally {
      _free(result.cast());
    }
  }

  int createContainer(Pointer<Void> env, bool array, int length) =>
      _result((out) => _createContainer(env, array, length, out));

  (Pointer<Void>, int) snapshotMap(
    Pointer<Void> env,
    Pointer<Void> input,
    String path,
    int remaining,
    int depth,
    bool cyclic,
  ) {
    Pointer<Pointer<Void>> pairs = nullptr;
    Pointer<Uint32> count = nullptr;
    try {
      pairs = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
      count = _allocate<Uint32>(1, sizeOf<Uint32>());
      final context = Pointer<Void>.fromAddress(stringResult(env, path));
      _check(
        _snapshotMap(
          env,
          input,
          context,
          remaining,
          depth,
          cyclic,
          pairs,
          count,
        ),
      );
      return (pairs.value, count.value);
    } finally {
      _free(count.cast());
      _free(pairs.cast());
    }
  }

  int createMap(Pointer<Void> env) => _result((out) => _createMap(env, out));

  (Pointer<Void>, int) dictionaryKeys(
    Pointer<Void> env,
    Pointer<Void> input,
    String path,
    int remaining,
    int depth,
    bool cyclic,
  ) {
    Pointer<Pointer<Void>> keys = nullptr;
    Pointer<Uint32> count = nullptr;
    try {
      keys = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
      count = _allocate<Uint32>(1, sizeOf<Uint32>());
      final context = Pointer<Void>.fromAddress(stringResult(env, path));
      _check(
        _dictionaryKeys(
          env,
          input,
          context,
          remaining,
          depth,
          cyclic,
          keys,
          count,
        ),
      );
      return (keys.value, count.value);
    } finally {
      _free(count.cast());
      _free(keys.cast());
    }
  }

  int createDictionary(Pointer<Void> env) =>
      _result((out) => _createDictionary(env, out));

  void checkedInsertMap(
    Pointer<Void> env,
    int map,
    int key,
    int value,
    String keyPath,
  ) {
    final context = Pointer<Void>.fromAddress(stringResult(env, keyPath));
    _check(
      _checkedInsertMap(
        env,
        Pointer<Void>.fromAddress(map),
        Pointer<Void>.fromAddress(key),
        Pointer<Void>.fromAddress(value),
        context,
      ),
    );
  }

  void defineOwnValue(Pointer<Void> env, int container, String key, int value) {
    final name = Pointer<Void>.fromAddress(stringResult(env, key));
    _check(
      _defineOwnValue(
        env,
        Pointer<Void>.fromAddress(container),
        name,
        Pointer<Void>.fromAddress(value),
      ),
    );
  }

  void checkNew(NapiCall call, bool required, String context) {
    final out = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
    try {
      _check(_newTarget(call.env, call.info, out));
      if (required != (out.value != nullptr)) {
        throw NapiTypeError(
          '$context: ${required ? 'constructor requires new' : 'function is not a constructor'}',
        );
      }
    } finally {
      _free(out.cast());
    }
  }

  int wrap(NapiCall call, Object object, int classId, [String? path]) =>
      _intern(call.env, object, classId, path ?? 'Native constructor', call);

  int referenceResult(
    Pointer<Void> env,
    Object object,
    int classId,
    String path, [
    List<(Object, int)>? pending,
  ]) => _intern(env, object, classId, path, null, pending);

  // A failed structural result has not exposed its newly created wrappers.
  // Keep their owners until the ordinary finalizers run, but undo only claims
  // first created by this result and still attached to the same lease.
  void rollbackReferences(List<(Object, int)> pending) {
    for (final (object, id) in pending.reversed) {
      if (_references[object]?.id == id) _references[object] = null;
    }
  }

  int _intern(
    Pointer<Void> env,
    Object object,
    int classId,
    String path,
    NapiCall? call, [
    List<(Object, int)>? pending,
  ]) {
    final cached = _references[object];
    var canonical =
        cached?.classId ?? referenceClass?.call(object, path) ?? classId;
    if (canonical < 0) canonical = _compositeShape(env, object, path);
    if (!_memberOf(canonical, classId)) {
      throw NapiTypeError('$path: object is bound to a different public class');
    }
    if (cached != null) {
      final existing = _result((out) => _referenceValue(env, cached.id, out));
      if (existing != 0) return existing;
    }
    final id = _nextOwner++;
    if (id <= 0) throw StateError('Native owner id exhausted');
    _owners[id] = object;
    try {
      final int result;
      if (call == null ||
          (canonical != classId && _isConstructorTarget(call, classId))) {
        result = _result((out) => _referenceCreate(env, canonical, id, out));
        if (result == 0) {
          throw StateError('Native reference creation failed');
        }
      } else {
        _check(_wrap(env, call.self, id));
        result = call.self.address;
      }
      if (cached == null) pending?.add((object, id));
      _references[object] = _ReferenceLease(id, canonical);
      return result;
    } catch (_) {
      _owners.remove(id);
      rethrow;
    }
  }

  int _compositeShape(Pointer<Void> env, Object object, String path) {
    final collect = referenceViews;
    if (collect == null) {
      throw NapiTypeError('$path: no unique most-specific selected class');
    }
    final views = collect(object).toSet().toList()..sort();
    if (views.length < 2 ||
        views.any((id) => id < 0 || id >= classMemberships.length)) {
      throw NapiTypeError('$path: no unique most-specific selected class');
    }
    final key = views.join(',');
    if (_referenceShapes[key] case final known?) return known;
    final shape = classMemberships.length + _shapeMemberships.length;
    if (shape > 0xffffffff) throw StateError('Native shape id exhausted');
    Pointer<Uint32> ids = nullptr;
    try {
      ids = _allocate<Uint32>(views.length, sizeOf<Uint32>());
      for (final (index, id) in views.indexed) {
        ids[index] = id;
      }
      final context = Pointer<Void>.fromAddress(stringResult(env, path));
      _check(_registerReferenceShape(env, shape, ids, views.length, context));
      // JS resolves conflicts before either Dart cache is published.
      _shapeMemberships[shape] = Set.unmodifiable(views);
      _referenceShapes[key] = shape;
      return shape;
    } finally {
      _free(ids.cast());
    }
  }

  bool _memberOf(int canonical, int requested) => classMemberships.isEmpty
      ? canonical == requested
      : canonical >= 0 &&
            (canonical < classMemberships.length
                ? classMemberships[canonical].contains(requested)
                : (_shapeMemberships[canonical]?.contains(requested) ?? false));

  bool _isConstructorTarget(NapiCall call, int classId) {
    final result = _allocate<Bool>(1, sizeOf<Bool>());
    try {
      _check(_constructorTarget(call.env, call.info, classId, result));
      return result.value;
    } finally {
      _free(result.cast());
    }
  }

  Object owner(NapiCall call) =>
      ownerValue(call.env, call.self, 'Native receiver');

  Object ownerValue(
    Pointer<Void> env,
    Pointer<Void> value,
    String path, [
    int? classId,
  ]) {
    final id = _unwrap(env, value);
    if (id == 0) throw NapiTypeError('$path: invalid native receiver');
    final object = _owners[id];
    if (object == null) {
      throw NapiTypeError('$path: native receiver was released');
    }
    final lease = _references[object];
    if (lease == null ||
        lease.id != id ||
        (classId != null && !_memberOf(lease.classId, classId))) {
      throw NapiTypeError('$path: incompatible native class');
    }
    return object;
  }

  // Do not clear the Expando here: an older lease's finalizer may arrive after
  // a replacement has been attached. The weak key dies with the Dart object.
  void releaseOwner(int id) => _owners.remove(id);

  bool _hasPending(Pointer<Void> env) {
    final out = _allocate<Bool>(1, sizeOf<Bool>());
    try {
      _check(_pending(env, out));
      return out.value;
    } finally {
      _free(out.cast());
    }
  }

  // Event admission completes conversion while the owning isolate is active.
  // The owned value survives subsequent owner-pump turns; no borrowed result
  // handle or temporary structural handle escapes this local scope.
  NativeHostValue snapshotStreamValue(
    Pointer<Void> env,
    int Function() convert,
  ) {
    final scope = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
    var opened = false;
    try {
      _check(_openCallbackHandles(env, scope));
      opened = true;
      try {
        return ownHostValue(env, Pointer.fromAddress(convert()));
      } catch (error, stack) {
        Error.throwWithStackTrace(_callbackError(env, error), stack);
      }
    } finally {
      try {
        if (opened) _check(_closeCallbackHandles(env, scope.value));
      } finally {
        _free(scope.cast());
      }
    }
  }

  int iteratorResult(
    Pointer<Void> env,
    NativeHostValue? value, {
    required bool done,
  }) {
    // The outer result cannot acquire an inherited `then`; its nested value is
    // never assimilated. The existing Promise resolver therefore settles before
    // releaseFuture acknowledges the delivery, without a public Promise reaction.
    final result = createDictionary(env);
    defineOwnValue(
      env,
      result,
      'value',
      done ? undefinedResult(env) : hostValue(env, value!).address,
    );
    defineOwnValue(env, result, 'done', booleanResult(env, done));
    return result;
  }

  void beginFuture(int token) => _futures[token] = _PendingFuture();

  void attachOperation(int token, OperationLease operation) {
    _futures[token]!.operation = operation;
  }

  void retainFuture(int token, List<Object?> values, {int? observeEnv}) {
    final pending = _futures[token]!;
    pending.roots = values;
    final operation = pending.operation;
    if (observeEnv != null &&
        operation is ResourceOperation &&
        !operation.isEmpty) {
      _check(_observeFuture(Pointer.fromAddress(observeEnv), token));
    }
  }

  List<Object?>? releaseFuture(int token) {
    final pending = _futures.remove(token);
    if (pending == null) return null;
    final roots = pending.roots;
    pending.roots = const [];
    final operation = pending.operation;
    pending.operation = null;
    operation?.release();
    // Return through the native entry point: the owning Dart handle scope keeps
    // these arguments until acknowledgement completes. A write-only Dart field
    // is insufficient because AOT can remove its stores and collect the values.
    return roots;
  }

  (int, bool) bindCleanupFuture(
    int envAddress,
    int token,
    ResourceControl control,
  ) {
    final id = _cleanupIds[control] ??= _nextCleanup++;
    if (id <= 0) throw StateError('Native cleanup identity exhausted');
    Pointer<Pointer<Void>> result = nullptr;
    Pointer<Bool> first = nullptr;
    try {
      result = _allocate<Pointer<Void>>(1, sizeOf<Pointer<Void>>());
      first = _allocate<Bool>(1, sizeOf<Bool>());
      _check(
        _bindCleanup(Pointer.fromAddress(envAddress), token, id, result, first),
      );
      if (!first.value) releaseFuture(token);
      return (result.value.address, first.value);
    } finally {
      _free(first.cast());
      _free(result.cast());
    }
  }

  void completeFuture<T>(
    int envAddress,
    int token,
    Future<T> future,
    int Function(T) convert,
    String context, {
    void Function(T, Object, StackTrace)? onFailure,
  }) {
    future.then<void>(
      (value) {
        final pending = _futures[token];
        if (pending == null || pending.claimed) return;
        // Claim before conversion: user-defined collection getters can reenter
        // even a custom Future's completion callback during traversal.
        pending.claimed = true;
        try {
          final result = convert(value);
          _check(
            _queuePromise(
              Pointer.fromAddress(envAddress),
              token,
              Pointer.fromAddress(result),
              false,
            ),
          );
        } catch (error, stack) {
          onFailure?.call(value, error, stack);
          _rejectFuture(envAddress, token, error, stack, context);
        }
      },
      onError: (Object error, StackTrace stack) {
        rejectFuture(envAddress, token, error, stack, context);
      },
    );
  }

  void rejectFuture(
    int envAddress,
    int token,
    Object error,
    StackTrace stack,
    String context,
  ) {
    final pending = _futures[token];
    if (pending == null || pending.claimed) return;
    pending.claimed = true;
    _rejectFuture(envAddress, token, error, stack, context);
  }

  void _rejectFuture(
    int envAddress,
    int token,
    Object error,
    StackTrace stack,
    String context,
  ) {
    final env = Pointer<Void>.fromAddress(envAddress);
    var value = 0;
    if (!_hasPending(env)) {
      try {
        value = _errorValue(env, error, stack: stack, context: context);
      } catch (_) {
        // Slot 43 preserves a pending JS exception, or creates a fixed fallback
        // if formatting/allocation failed without leaving one.
      }
    }
    _check(_queuePromise(env, token, Pointer.fromAddress(value), true));
  }

  int _errorValue(
    Pointer<Void> env,
    Object error, {
    StackTrace? stack,
    String? context,
  }) {
    if (error is _NativeJsException) return hostValue(env, error.value).address;
    String message;
    try {
      message = error.toString();
    } catch (_) {
      message = 'Dart operation failed (error description unavailable)';
    }
    if (context != null &&
        error is! NapiTypeError &&
        error is! NapiRangeError) {
      message = '$context: $message';
    }
    final text = Pointer<Void>.fromAddress(stringResult(env, message));
    final create = error is NapiRangeError
        ? _createRangeError
        : error is NapiTypeError
        ? _createTypeError
        : _createError;
    final exception = _result((out) => create(env, nullptr, text, out));
    if (stack != null) {
      String description;
      try {
        description = stack.toString();
      } catch (_) {
        description = 'Dart stack trace unavailable';
      }
      defineOwnValue(
        env,
        exception,
        'dartStack',
        stringResult(env, description),
      );
    }
    return exception;
  }

  int fail(int envAddress, Object error) {
    final env = Pointer<Void>.fromAddress(envAddress);
    if (_hasPending(env)) return 0;
    _check(_throw(env, Pointer.fromAddress(_errorValue(env, error))));
    return 0;
  }
}
