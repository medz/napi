/// Raw Node-API FFI bindings.
///
/// Calls preserve native status codes, pointer types and ownership rules.
library;

import 'dart:ffi';

import 'package:meta/meta.dart' show experimental;

import '../src/_internal/annotations.dart';

@Available(napi: 1)
final class NapiEnvHandle extends Opaque {}

@Available(napi: 1)
typedef NapiEnv = Pointer<NapiEnvHandle>;

@Available(napi: 1)
final class NapiValueHandle extends Opaque {}

@Available(napi: 1)
typedef NapiValue = Pointer<NapiValueHandle>;

@Available(napi: 1)
final class NapiRefHandle extends Opaque {}

@Available(napi: 1)
typedef NapiRef = Pointer<NapiRefHandle>;

@Available(napi: 1)
final class NapiDeferredHandle extends Opaque {}

@Available(napi: 1)
typedef NapiDeferred = Pointer<NapiDeferredHandle>;

@Available(napi: 1)
final class NapiHandleScopeHandle extends Opaque {}

@Available(napi: 1)
typedef NapiHandleScope = Pointer<NapiHandleScopeHandle>;

@Available(napi: 1)
final class NapiEscapableHandleScopeHandle extends Opaque {}

@Available(napi: 1)
typedef NapiEscapableHandleScope = Pointer<NapiEscapableHandleScopeHandle>;

@Available(napi: 1)
final class NapiCallbackInfoHandle extends Opaque {}

@Available(napi: 1)
typedef NapiCallbackInfo = Pointer<NapiCallbackInfoHandle>;

@Available(napi: 1)
final class NapiAsyncWorkHandle extends Opaque {}

@Available(napi: 1)
typedef NapiAsyncWork = Pointer<NapiAsyncWorkHandle>;

@Available(napi: 1)
final class NapiAsyncContextHandle extends Opaque {}

@Available(napi: 1)
typedef NapiAsyncContext = Pointer<NapiAsyncContextHandle>;

@Available(napi: 1)
enum NapiStatus {
  ok,
  invalidArg,
  objectExpected,
  stringExpected,
  nameExpected,
  functionExpected,
  numberExpected,
  booleanExpected,
  arrayExpected,
  genericFailure,
  pendingException,
  cancelled,
  escapeCalledTwice,
  handleScopeMismatch,
  callbackScopeMismatch,
  queueFull,
  closing,
  bigintExpected,
  dateExpected,
  arraybufferExpected,
  detachableArraybufferExpected,
  wouldDeadlock,
  noExternalBuffersAllowed,
  cannotRunJs,
}

@Available(napi: 1)
enum NapiValueType {
  undefined,
  nullValue,
  boolean,
  number,
  string,
  symbol,
  object,
  function,
  external,
  bigint,
}

@Available(napi: 1)
enum NapiTypedArrayType {
  int8Array,
  uint8Array,
  uint8ClampedArray,
  int16Array,
  uint16Array,
  int32Array,
  uint32Array,
  float32Array,
  float64Array,
  bigint64Array,
  biguint64Array,
  @Available(napi: 1, node: '>=24.13.1 <25.0.0 || >=25.5.0')
  float16Array,
}

@Available(napi: 1)
const int napiDefault = 0;

@Available(napi: 1)
const int napiWritable = 1 << 0;

@Available(napi: 1)
const int napiEnumerable = 1 << 1;

@Available(napi: 1)
const int napiConfigurable = 1 << 2;

@Available(napi: 1)
const int napiStatic = 1 << 10;

// SIZE_MAX is represented by -1 when passed through Size.
@Available(napi: 1)
const int napiAutoLength = -1;

@Available(napi: 1)
typedef NapiCallback = NapiValue Function(NapiEnv env, NapiCallbackInfo info);

@Available(napi: 1)
typedef NapiFinalize =
    Void Function(NapiEnv env, Pointer<Void> data, Pointer<Void> hint);

@Available(napi: 1)
typedef NapiAsyncExecuteCallback =
    Void Function(NapiEnv env, Pointer<Void> data);

@Available(napi: 1)
typedef NapiAsyncCompleteCallback =
    Void Function(NapiEnv env, Int32 status, Pointer<Void> data);

@Available(napi: 1)
typedef NapiAddonRegisterFunc =
    NapiValue Function(NapiEnv env, NapiValue exports);

@Available(napi: 1)
typedef NodeApiAddonGetApiVersionFunc = Int32 Function();

@Available(napi: 1)
final class NapiPropertyDescriptor extends Struct {
  external Pointer<Char> utf8name;
  external NapiValue name;
  external Pointer<NativeFunction<NapiCallback>> method;
  external Pointer<NativeFunction<NapiCallback>> getter;
  external Pointer<NativeFunction<NapiCallback>> setter;
  external NapiValue value;
  @Int32()
  external int attributes;
  external Pointer<Void> data;
}

@Available(napi: 1)
final class NapiExtendedErrorInfo extends Struct {
  external Pointer<Char> errorMessage;
  external Pointer<Void> engineReserved;
  @Uint32()
  external int engineErrorCode;
  @Int32()
  external int errorCode;
}

@Available(napi: 1)
final class NapiNodeVersion extends Struct {
  @Uint32()
  external int major;
  @Uint32()
  external int minor;
  @Uint32()
  external int patch;
  external Pointer<Char> release;
}

@Available(napi: 2)
final class UvLoop extends Opaque {}

@Available(napi: 3)
final class NapiCallbackScopeHandle extends Opaque {}

@Available(napi: 3)
typedef NapiCallbackScope = Pointer<NapiCallbackScopeHandle>;

@Available(napi: 3)
typedef NapiCleanupHook = Void Function(Pointer<Void> argument);

@Available(napi: 4)
final class NapiThreadsafeFunctionHandle extends Opaque {}

@Available(napi: 4)
typedef NapiThreadsafeFunction = Pointer<NapiThreadsafeFunctionHandle>;

@Available(napi: 4)
enum NapiThreadsafeFunctionCallMode { nonblocking, blocking }

@Available(napi: 4)
enum NapiThreadsafeFunctionReleaseMode { release, abort }

@Available(napi: 4)
typedef NapiThreadsafeFunctionCallJs =
    Void Function(
      NapiEnv env,
      NapiValue callback,
      Pointer<Void> context,
      Pointer<Void> data,
    );

@Available(napi: 6)
enum NapiKeyCollectionMode { includePrototypes, ownOnly }

@Available(napi: 6)
enum NapiKeyConversion { keepNumbers, numbersToStrings }

@Available(napi: 6)
const int napiKeyAllProperties = 0;

@Available(napi: 6)
const int napiKeyWritable = 1 << 0;

@Available(napi: 6)
const int napiKeyEnumerable = 1 << 1;

@Available(napi: 6)
const int napiKeyConfigurable = 1 << 2;

@Available(napi: 6)
const int napiKeySkipStrings = 1 << 3;

@Available(napi: 6)
const int napiKeySkipSymbols = 1 << 4;

@Available(napi: 8)
final class NapiAsyncCleanupHookHandleHandle extends Opaque {}

@Available(napi: 8)
typedef NapiAsyncCleanupHookHandle = Pointer<NapiAsyncCleanupHookHandleHandle>;

@Available(napi: 8)
const int napiDefaultMethod = napiWritable | napiConfigurable;

@Available(napi: 8)
const int napiDefaultJsproperty =
    napiWritable | napiEnumerable | napiConfigurable;

@Available(napi: 8)
typedef NapiAsyncCleanupHook =
    Void Function(NapiAsyncCleanupHookHandle handle, Pointer<Void> data);

@Available(napi: 8)
final class NapiTypeTag extends Struct {
  @Uint64()
  external int lower;
  @Uint64()
  external int upper;
}

/// An environment restricted to APIs that may run during garbage collection.
///
/// Dart FFI does not enforce the native pointer's const qualification.
@experimental
typedef NodeApiBasicEnv = NapiEnv;

/// A finalizer that may only call APIs accepting [NodeApiBasicEnv].
@experimental
typedef NodeApiBasicFinalize =
    Void Function(NodeApiBasicEnv env, Pointer<Void> data, Pointer<Void> hint);

/// May run on any thread, even after the originating environment is destroyed.
@experimental
typedef NodeApiNoenvFinalize =
    Void Function(Pointer<Void> data, Pointer<Void> hint);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<Pointer<NapiExtendedErrorInfo>>)>(
  symbol: 'napi_get_last_error_info',
)
external int napiGetLastErrorInfo(
  NapiEnv env,
  Pointer<Pointer<NapiExtendedErrorInfo>> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<NapiValue>)>(
  symbol: 'napi_get_undefined',
)
external int napiGetUndefined(NapiEnv env, Pointer<NapiValue> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<NapiValue>)>(symbol: 'napi_get_null')
external int napiGetNull(NapiEnv env, Pointer<NapiValue> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<NapiValue>)>(symbol: 'napi_get_global')
external int napiGetGlobal(NapiEnv env, Pointer<NapiValue> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Bool, Pointer<NapiValue>)>(
  symbol: 'napi_get_boolean',
)
external int napiGetBoolean(NapiEnv env, bool value, Pointer<NapiValue> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<NapiValue>)>(
  symbol: 'napi_create_object',
)
external int napiCreateObject(NapiEnv env, Pointer<NapiValue> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<NapiValue>)>(
  symbol: 'napi_create_array',
)
external int napiCreateArray(NapiEnv env, Pointer<NapiValue> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Size, Pointer<NapiValue>)>(
  symbol: 'napi_create_array_with_length',
)
external int napiCreateArrayWithLength(
  NapiEnv env,
  int length,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Double, Pointer<NapiValue>)>(
  symbol: 'napi_create_double',
)
external int napiCreateDouble(
  NapiEnv env,
  double value,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Int32, Pointer<NapiValue>)>(
  symbol: 'napi_create_int32',
)
external int napiCreateInt32(NapiEnv env, int value, Pointer<NapiValue> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Uint32, Pointer<NapiValue>)>(
  symbol: 'napi_create_uint32',
)
external int napiCreateUint32(
  NapiEnv env,
  int value,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Int64, Pointer<NapiValue>)>(
  symbol: 'napi_create_int64',
)
external int napiCreateInt64(NapiEnv env, int value, Pointer<NapiValue> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<Char>, Size, Pointer<NapiValue>)>(
  symbol: 'napi_create_string_latin1',
)
external int napiCreateStringLatin1(
  NapiEnv env,
  Pointer<Char> str,
  int length,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<Char>, Size, Pointer<NapiValue>)>(
  symbol: 'napi_create_string_utf8',
)
external int napiCreateStringUtf8(
  NapiEnv env,
  Pointer<Char> str,
  int length,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<Uint16>, Size, Pointer<NapiValue>)>(
  symbol: 'napi_create_string_utf16',
)
external int napiCreateStringUtf16(
  NapiEnv env,
  Pointer<Uint16> str,
  int length,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<NapiValue>)>(
  symbol: 'napi_create_symbol',
)
external int napiCreateSymbol(
  NapiEnv env,
  NapiValue description,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    Pointer<Char>,
    Size,
    Pointer<NativeFunction<NapiCallback>>,
    Pointer<Void>,
    Pointer<NapiValue>,
  )
>(symbol: 'napi_create_function')
external int napiCreateFunction(
  NapiEnv env,
  Pointer<Char> utf8name,
  int length,
  Pointer<NativeFunction<NapiCallback>> cb,
  Pointer<Void> data,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, NapiValue, Pointer<NapiValue>)>(
  symbol: 'napi_create_error',
)
external int napiCreateError(
  NapiEnv env,
  NapiValue code,
  NapiValue msg,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, NapiValue, Pointer<NapiValue>)>(
  symbol: 'napi_create_type_error',
)
external int napiCreateTypeError(
  NapiEnv env,
  NapiValue code,
  NapiValue msg,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, NapiValue, Pointer<NapiValue>)>(
  symbol: 'napi_create_range_error',
)
external int napiCreateRangeError(
  NapiEnv env,
  NapiValue code,
  NapiValue msg,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Int32>)>(
  symbol: 'napi_typeof',
)
external int napiTypeof(NapiEnv env, NapiValue value, Pointer<Int32> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Double>)>(
  symbol: 'napi_get_value_double',
)
external int napiGetValueDouble(
  NapiEnv env,
  NapiValue value,
  Pointer<Double> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Int32>)>(
  symbol: 'napi_get_value_int32',
)
external int napiGetValueInt32(
  NapiEnv env,
  NapiValue value,
  Pointer<Int32> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Uint32>)>(
  symbol: 'napi_get_value_uint32',
)
external int napiGetValueUint32(
  NapiEnv env,
  NapiValue value,
  Pointer<Uint32> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Int64>)>(
  symbol: 'napi_get_value_int64',
)
external int napiGetValueInt64(
  NapiEnv env,
  NapiValue value,
  Pointer<Int64> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_get_value_bool',
)
external int napiGetValueBool(
  NapiEnv env,
  NapiValue value,
  Pointer<Bool> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Char>, Size, Pointer<Size>)>(
  symbol: 'napi_get_value_string_latin1',
)
external int napiGetValueStringLatin1(
  NapiEnv env,
  NapiValue value,
  Pointer<Char> buf,
  int bufsize,
  Pointer<Size> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Char>, Size, Pointer<Size>)>(
  symbol: 'napi_get_value_string_utf8',
)
external int napiGetValueStringUtf8(
  NapiEnv env,
  NapiValue value,
  Pointer<Char> buf,
  int bufsize,
  Pointer<Size> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(NapiEnv, NapiValue, Pointer<Uint16>, Size, Pointer<Size>)
>(symbol: 'napi_get_value_string_utf16')
external int napiGetValueStringUtf16(
  NapiEnv env,
  NapiValue value,
  Pointer<Uint16> buf,
  int bufsize,
  Pointer<Size> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<NapiValue>)>(
  symbol: 'napi_coerce_to_bool',
)
external int napiCoerceToBool(
  NapiEnv env,
  NapiValue value,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<NapiValue>)>(
  symbol: 'napi_coerce_to_number',
)
external int napiCoerceToNumber(
  NapiEnv env,
  NapiValue value,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<NapiValue>)>(
  symbol: 'napi_coerce_to_object',
)
external int napiCoerceToObject(
  NapiEnv env,
  NapiValue value,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<NapiValue>)>(
  symbol: 'napi_coerce_to_string',
)
external int napiCoerceToString(
  NapiEnv env,
  NapiValue value,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<NapiValue>)>(
  symbol: 'napi_get_prototype',
)
external int napiGetPrototype(
  NapiEnv env,
  NapiValue object,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<NapiValue>)>(
  symbol: 'napi_get_property_names',
)
external int napiGetPropertyNames(
  NapiEnv env,
  NapiValue object,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, NapiValue, NapiValue)>(
  symbol: 'napi_set_property',
)
external int napiSetProperty(
  NapiEnv env,
  NapiValue object,
  NapiValue key,
  NapiValue value,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_has_property',
)
external int napiHasProperty(
  NapiEnv env,
  NapiValue object,
  NapiValue key,
  Pointer<Bool> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, NapiValue, Pointer<NapiValue>)>(
  symbol: 'napi_get_property',
)
external int napiGetProperty(
  NapiEnv env,
  NapiValue object,
  NapiValue key,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_delete_property',
)
external int napiDeleteProperty(
  NapiEnv env,
  NapiValue object,
  NapiValue key,
  Pointer<Bool> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_has_own_property',
)
external int napiHasOwnProperty(
  NapiEnv env,
  NapiValue object,
  NapiValue key,
  Pointer<Bool> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Char>, NapiValue)>(
  symbol: 'napi_set_named_property',
)
external int napiSetNamedProperty(
  NapiEnv env,
  NapiValue object,
  Pointer<Char> utf8name,
  NapiValue value,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Char>, Pointer<Bool>)>(
  symbol: 'napi_has_named_property',
)
external int napiHasNamedProperty(
  NapiEnv env,
  NapiValue object,
  Pointer<Char> utf8name,
  Pointer<Bool> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Char>, Pointer<NapiValue>)>(
  symbol: 'napi_get_named_property',
)
external int napiGetNamedProperty(
  NapiEnv env,
  NapiValue object,
  Pointer<Char> utf8name,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Uint32, NapiValue)>(
  symbol: 'napi_set_element',
)
external int napiSetElement(
  NapiEnv env,
  NapiValue object,
  int index,
  NapiValue value,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Uint32, Pointer<Bool>)>(
  symbol: 'napi_has_element',
)
external int napiHasElement(
  NapiEnv env,
  NapiValue object,
  int index,
  Pointer<Bool> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Uint32, Pointer<NapiValue>)>(
  symbol: 'napi_get_element',
)
external int napiGetElement(
  NapiEnv env,
  NapiValue object,
  int index,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Uint32, Pointer<Bool>)>(
  symbol: 'napi_delete_element',
)
external int napiDeleteElement(
  NapiEnv env,
  NapiValue object,
  int index,
  Pointer<Bool> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(NapiEnv, NapiValue, Size, Pointer<NapiPropertyDescriptor>)
>(symbol: 'napi_define_properties')
external int napiDefineProperties(
  NapiEnv env,
  NapiValue object,
  int propertyCount,
  Pointer<NapiPropertyDescriptor> properties,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_is_array',
)
external int napiIsArray(NapiEnv env, NapiValue value, Pointer<Bool> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Uint32>)>(
  symbol: 'napi_get_array_length',
)
external int napiGetArrayLength(
  NapiEnv env,
  NapiValue value,
  Pointer<Uint32> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_strict_equals',
)
external int napiStrictEquals(
  NapiEnv env,
  NapiValue lhs,
  NapiValue rhs,
  Pointer<Bool> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    NapiValue,
    NapiValue,
    Size,
    Pointer<NapiValue>,
    Pointer<NapiValue>,
  )
>(symbol: 'napi_call_function')
external int napiCallFunction(
  NapiEnv env,
  NapiValue recv,
  NapiValue func,
  int argc,
  Pointer<NapiValue> argv,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    NapiValue,
    Size,
    Pointer<NapiValue>,
    Pointer<NapiValue>,
  )
>(symbol: 'napi_new_instance')
external int napiNewInstance(
  NapiEnv env,
  NapiValue constructor,
  int argc,
  Pointer<NapiValue> argv,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_instanceof',
)
external int napiInstanceof(
  NapiEnv env,
  NapiValue object,
  NapiValue constructor,
  Pointer<Bool> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    NapiCallbackInfo,
    Pointer<Size>,
    Pointer<NapiValue>,
    Pointer<NapiValue>,
    Pointer<Pointer<Void>>,
  )
>(symbol: 'napi_get_cb_info')
external int napiGetCbInfo(
  NapiEnv env,
  NapiCallbackInfo cbinfo,
  Pointer<Size> argc,
  Pointer<NapiValue> argv,
  Pointer<NapiValue> thisArg,
  Pointer<Pointer<Void>> data,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiCallbackInfo, Pointer<NapiValue>)>(
  symbol: 'napi_get_new_target',
)
external int napiGetNewTarget(
  NapiEnv env,
  NapiCallbackInfo cbinfo,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    Pointer<Char>,
    Size,
    Pointer<NativeFunction<NapiCallback>>,
    Pointer<Void>,
    Size,
    Pointer<NapiPropertyDescriptor>,
    Pointer<NapiValue>,
  )
>(symbol: 'napi_define_class')
external int napiDefineClass(
  NapiEnv env,
  Pointer<Char> utf8name,
  int length,
  Pointer<NativeFunction<NapiCallback>> constructor,
  Pointer<Void> data,
  int propertyCount,
  Pointer<NapiPropertyDescriptor> properties,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    NapiValue,
    Pointer<Void>,
    Pointer<NativeFunction<NapiFinalize>>,
    Pointer<Void>,
    Pointer<NapiRef>,
  )
>(symbol: 'napi_wrap')
external int napiWrap(
  NapiEnv env,
  NapiValue jsObject,
  Pointer<Void> nativeObject,
  Pointer<NativeFunction<NapiFinalize>> finalizeCb,
  Pointer<Void> finalizeHint,
  Pointer<NapiRef> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Pointer<Void>>)>(
  symbol: 'napi_unwrap',
)
external int napiUnwrap(
  NapiEnv env,
  NapiValue jsObject,
  Pointer<Pointer<Void>> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Pointer<Void>>)>(
  symbol: 'napi_remove_wrap',
)
external int napiRemoveWrap(
  NapiEnv env,
  NapiValue jsObject,
  Pointer<Pointer<Void>> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    Pointer<Void>,
    Pointer<NativeFunction<NapiFinalize>>,
    Pointer<Void>,
    Pointer<NapiValue>,
  )
>(symbol: 'napi_create_external')
external int napiCreateExternal(
  NapiEnv env,
  Pointer<Void> data,
  Pointer<NativeFunction<NapiFinalize>> finalizeCb,
  Pointer<Void> finalizeHint,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Pointer<Void>>)>(
  symbol: 'napi_get_value_external',
)
external int napiGetValueExternal(
  NapiEnv env,
  NapiValue value,
  Pointer<Pointer<Void>> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Uint32, Pointer<NapiRef>)>(
  symbol: 'napi_create_reference',
)
external int napiCreateReference(
  NapiEnv env,
  NapiValue value,
  int initialRefcount,
  Pointer<NapiRef> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiRef)>(symbol: 'napi_delete_reference')
external int napiDeleteReference(NapiEnv env, NapiRef ref);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiRef, Pointer<Uint32>)>(
  symbol: 'napi_reference_ref',
)
external int napiReferenceRef(NapiEnv env, NapiRef ref, Pointer<Uint32> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiRef, Pointer<Uint32>)>(
  symbol: 'napi_reference_unref',
)
external int napiReferenceUnref(
  NapiEnv env,
  NapiRef ref,
  Pointer<Uint32> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiRef, Pointer<NapiValue>)>(
  symbol: 'napi_get_reference_value',
)
external int napiGetReferenceValue(
  NapiEnv env,
  NapiRef ref,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<NapiHandleScope>)>(
  symbol: 'napi_open_handle_scope',
)
external int napiOpenHandleScope(NapiEnv env, Pointer<NapiHandleScope> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiHandleScope)>(
  symbol: 'napi_close_handle_scope',
)
external int napiCloseHandleScope(NapiEnv env, NapiHandleScope scope);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<NapiEscapableHandleScope>)>(
  symbol: 'napi_open_escapable_handle_scope',
)
external int napiOpenEscapableHandleScope(
  NapiEnv env,
  Pointer<NapiEscapableHandleScope> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiEscapableHandleScope)>(
  symbol: 'napi_close_escapable_handle_scope',
)
external int napiCloseEscapableHandleScope(
  NapiEnv env,
  NapiEscapableHandleScope scope,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    NapiEscapableHandleScope,
    NapiValue,
    Pointer<NapiValue>,
  )
>(symbol: 'napi_escape_handle')
external int napiEscapeHandle(
  NapiEnv env,
  NapiEscapableHandleScope scope,
  NapiValue escapee,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue)>(symbol: 'napi_throw')
external int napiThrow(NapiEnv env, NapiValue error);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<Char>, Pointer<Char>)>(
  symbol: 'napi_throw_error',
)
external int napiThrowError(NapiEnv env, Pointer<Char> code, Pointer<Char> msg);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<Char>, Pointer<Char>)>(
  symbol: 'napi_throw_type_error',
)
external int napiThrowTypeError(
  NapiEnv env,
  Pointer<Char> code,
  Pointer<Char> msg,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<Char>, Pointer<Char>)>(
  symbol: 'napi_throw_range_error',
)
external int napiThrowRangeError(
  NapiEnv env,
  Pointer<Char> code,
  Pointer<Char> msg,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_is_error',
)
external int napiIsError(NapiEnv env, NapiValue value, Pointer<Bool> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<Bool>)>(
  symbol: 'napi_is_exception_pending',
)
external int napiIsExceptionPending(NapiEnv env, Pointer<Bool> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<NapiValue>)>(
  symbol: 'napi_get_and_clear_last_exception',
)
external int napiGetAndClearLastException(
  NapiEnv env,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_is_arraybuffer',
)
external int napiIsArraybuffer(
  NapiEnv env,
  NapiValue value,
  Pointer<Bool> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(NapiEnv, Size, Pointer<Pointer<Void>>, Pointer<NapiValue>)
>(symbol: 'napi_create_arraybuffer')
external int napiCreateArraybuffer(
  NapiEnv env,
  int byteLength,
  Pointer<Pointer<Void>> data,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    Pointer<Void>,
    Size,
    Pointer<NativeFunction<NapiFinalize>>,
    Pointer<Void>,
    Pointer<NapiValue>,
  )
>(symbol: 'napi_create_external_arraybuffer')
external int napiCreateExternalArraybuffer(
  NapiEnv env,
  Pointer<Void> externalData,
  int byteLength,
  Pointer<NativeFunction<NapiFinalize>> finalizeCb,
  Pointer<Void> finalizeHint,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(NapiEnv, NapiValue, Pointer<Pointer<Void>>, Pointer<Size>)
>(symbol: 'napi_get_arraybuffer_info')
external int napiGetArraybufferInfo(
  NapiEnv env,
  NapiValue arraybuffer,
  Pointer<Pointer<Void>> data,
  Pointer<Size> byteLength,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_is_typedarray',
)
external int napiIsTypedarray(
  NapiEnv env,
  NapiValue value,
  Pointer<Bool> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(NapiEnv, Int32, Size, NapiValue, Size, Pointer<NapiValue>)
>(symbol: 'napi_create_typedarray')
external int napiCreateTypedarray(
  NapiEnv env,
  int type,
  int length,
  NapiValue arraybuffer,
  int byteOffset,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    NapiValue,
    Pointer<Int32>,
    Pointer<Size>,
    Pointer<Pointer<Void>>,
    Pointer<NapiValue>,
    Pointer<Size>,
  )
>(symbol: 'napi_get_typedarray_info')
external int napiGetTypedarrayInfo(
  NapiEnv env,
  NapiValue typedarray,
  Pointer<Int32> type,
  Pointer<Size> length,
  Pointer<Pointer<Void>> data,
  Pointer<NapiValue> arraybuffer,
  Pointer<Size> byteOffset,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Size, NapiValue, Size, Pointer<NapiValue>)>(
  symbol: 'napi_create_dataview',
)
external int napiCreateDataview(
  NapiEnv env,
  int length,
  NapiValue arraybuffer,
  int byteOffset,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_is_dataview',
)
external int napiIsDataview(NapiEnv env, NapiValue value, Pointer<Bool> result);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    NapiValue,
    Pointer<Size>,
    Pointer<Pointer<Void>>,
    Pointer<NapiValue>,
    Pointer<Size>,
  )
>(symbol: 'napi_get_dataview_info')
external int napiGetDataviewInfo(
  NapiEnv env,
  NapiValue dataview,
  Pointer<Size> bytelength,
  Pointer<Pointer<Void>> data,
  Pointer<NapiValue> arraybuffer,
  Pointer<Size> byteOffset,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<Uint32>)>(symbol: 'napi_get_version')
external int napiGetVersion(NapiEnv env, Pointer<Uint32> result);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<NapiDeferred>, Pointer<NapiValue>)>(
  symbol: 'napi_create_promise',
)
external int napiCreatePromise(
  NapiEnv env,
  Pointer<NapiDeferred> deferred,
  Pointer<NapiValue> promise,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiDeferred, NapiValue)>(
  symbol: 'napi_resolve_deferred',
)
external int napiResolveDeferred(
  NapiEnv env,
  NapiDeferred deferred,
  NapiValue resolution,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiDeferred, NapiValue)>(
  symbol: 'napi_reject_deferred',
)
external int napiRejectDeferred(
  NapiEnv env,
  NapiDeferred deferred,
  NapiValue rejection,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_is_promise',
)
external int napiIsPromise(
  NapiEnv env,
  NapiValue value,
  Pointer<Bool> isPromise,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<NapiValue>)>(
  symbol: 'napi_run_script',
)
external int napiRunScript(
  NapiEnv env,
  NapiValue script,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Int64, Pointer<Int64>)>(
  symbol: 'napi_adjust_external_memory',
)
external int napiAdjustExternalMemory(
  NapiEnv env,
  int changeInBytes,
  Pointer<Int64> adjustedValue,
);

@Available(napi: 1)
@Native<Void Function(Pointer<Char>, Size, Pointer<Char>, Size)>(
  symbol: 'napi_fatal_error',
)
external void napiFatalError(
  Pointer<Char> location,
  int locationLen,
  Pointer<Char> message,
  int messageLen,
);

@Available(napi: 1)
@Native<
  Int32 Function(NapiEnv, NapiValue, NapiValue, Pointer<NapiAsyncContext>)
>(symbol: 'napi_async_init')
external int napiAsyncInit(
  NapiEnv env,
  NapiValue asyncResource,
  NapiValue asyncResourceName,
  Pointer<NapiAsyncContext> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiAsyncContext)>(symbol: 'napi_async_destroy')
external int napiAsyncDestroy(NapiEnv env, NapiAsyncContext asyncContext);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    NapiAsyncContext,
    NapiValue,
    NapiValue,
    Size,
    Pointer<NapiValue>,
    Pointer<NapiValue>,
  )
>(symbol: 'napi_make_callback')
external int napiMakeCallback(
  NapiEnv env,
  NapiAsyncContext asyncContext,
  NapiValue recv,
  NapiValue func,
  int argc,
  Pointer<NapiValue> argv,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(NapiEnv, Size, Pointer<Pointer<Void>>, Pointer<NapiValue>)
>(symbol: 'napi_create_buffer')
external int napiCreateBuffer(
  NapiEnv env,
  int length,
  Pointer<Pointer<Void>> data,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    Size,
    Pointer<Void>,
    Pointer<NativeFunction<NapiFinalize>>,
    Pointer<Void>,
    Pointer<NapiValue>,
  )
>(symbol: 'napi_create_external_buffer')
external int napiCreateExternalBuffer(
  NapiEnv env,
  int length,
  Pointer<Void> data,
  Pointer<NativeFunction<NapiFinalize>> finalizeCb,
  Pointer<Void> finalizeHint,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    Size,
    Pointer<Void>,
    Pointer<Pointer<Void>>,
    Pointer<NapiValue>,
  )
>(symbol: 'napi_create_buffer_copy')
external int napiCreateBufferCopy(
  NapiEnv env,
  int length,
  Pointer<Void> data,
  Pointer<Pointer<Void>> resultData,
  Pointer<NapiValue> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_is_buffer',
)
external int napiIsBuffer(NapiEnv env, NapiValue value, Pointer<Bool> result);

@Available(napi: 1)
@Native<
  Int32 Function(NapiEnv, NapiValue, Pointer<Pointer<Void>>, Pointer<Size>)
>(symbol: 'napi_get_buffer_info')
external int napiGetBufferInfo(
  NapiEnv env,
  NapiValue value,
  Pointer<Pointer<Void>> data,
  Pointer<Size> length,
);

@Available(napi: 1)
@Native<
  Int32 Function(
    NapiEnv,
    NapiValue,
    NapiValue,
    Pointer<NativeFunction<NapiAsyncExecuteCallback>>,
    Pointer<NativeFunction<NapiAsyncCompleteCallback>>,
    Pointer<Void>,
    Pointer<NapiAsyncWork>,
  )
>(symbol: 'napi_create_async_work')
external int napiCreateAsyncWork(
  NapiEnv env,
  NapiValue asyncResource,
  NapiValue asyncResourceName,
  Pointer<NativeFunction<NapiAsyncExecuteCallback>> execute,
  Pointer<NativeFunction<NapiAsyncCompleteCallback>> complete,
  Pointer<Void> data,
  Pointer<NapiAsyncWork> result,
);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiAsyncWork)>(
  symbol: 'napi_delete_async_work',
)
external int napiDeleteAsyncWork(NapiEnv env, NapiAsyncWork work);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiAsyncWork)>(symbol: 'napi_queue_async_work')
external int napiQueueAsyncWork(NapiEnv env, NapiAsyncWork work);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, NapiAsyncWork)>(
  symbol: 'napi_cancel_async_work',
)
external int napiCancelAsyncWork(NapiEnv env, NapiAsyncWork work);

@Available(napi: 1)
@Native<Int32 Function(NapiEnv, Pointer<Pointer<NapiNodeVersion>>)>(
  symbol: 'napi_get_node_version',
)
external int napiGetNodeVersion(
  NapiEnv env,
  Pointer<Pointer<NapiNodeVersion>> version,
);

@Available(napi: 2)
@Native<Int32 Function(NapiEnv, Pointer<Pointer<UvLoop>>)>(
  symbol: 'napi_get_uv_event_loop',
)
external int napiGetUvEventLoop(NapiEnv env, Pointer<Pointer<UvLoop>> loop);

@Available(napi: 3)
@Native<Int32 Function(NapiEnv, NapiValue)>(symbol: 'napi_fatal_exception')
external int napiFatalException(NapiEnv env, NapiValue err);

@Available(napi: 3)
@Native<
  Int32 Function(
    NapiEnv,
    Pointer<NativeFunction<NapiCleanupHook>>,
    Pointer<Void>,
  )
>(symbol: 'napi_add_env_cleanup_hook')
external int napiAddEnvCleanupHook(
  NapiEnv env,
  Pointer<NativeFunction<NapiCleanupHook>> fun,
  Pointer<Void> arg,
);

@Available(napi: 3)
@Native<
  Int32 Function(
    NapiEnv,
    Pointer<NativeFunction<NapiCleanupHook>>,
    Pointer<Void>,
  )
>(symbol: 'napi_remove_env_cleanup_hook')
external int napiRemoveEnvCleanupHook(
  NapiEnv env,
  Pointer<NativeFunction<NapiCleanupHook>> fun,
  Pointer<Void> arg,
);

@Available(napi: 3)
@Native<
  Int32 Function(
    NapiEnv,
    NapiValue,
    NapiAsyncContext,
    Pointer<NapiCallbackScope>,
  )
>(symbol: 'napi_open_callback_scope')
external int napiOpenCallbackScope(
  NapiEnv env,
  NapiValue resourceObject,
  NapiAsyncContext context,
  Pointer<NapiCallbackScope> result,
);

@Available(napi: 3)
@Native<Int32 Function(NapiEnv, NapiCallbackScope)>(
  symbol: 'napi_close_callback_scope',
)
external int napiCloseCallbackScope(NapiEnv env, NapiCallbackScope scope);

@Available(napi: 4)
@Native<
  Int32 Function(
    NapiEnv,
    NapiValue,
    NapiValue,
    NapiValue,
    Size,
    Size,
    Pointer<Void>,
    Pointer<NativeFunction<NapiFinalize>>,
    Pointer<Void>,
    Pointer<NativeFunction<NapiThreadsafeFunctionCallJs>>,
    Pointer<NapiThreadsafeFunction>,
  )
>(symbol: 'napi_create_threadsafe_function')
external int napiCreateThreadsafeFunction(
  NapiEnv env,
  NapiValue func,
  NapiValue asyncResource,
  NapiValue asyncResourceName,
  int maxQueueSize,
  int initialThreadCount,
  Pointer<Void> threadFinalizeData,
  Pointer<NativeFunction<NapiFinalize>> threadFinalizeCb,
  Pointer<Void> context,
  Pointer<NativeFunction<NapiThreadsafeFunctionCallJs>> callJsCb,
  Pointer<NapiThreadsafeFunction> result,
);

@Available(napi: 4)
@Native<Int32 Function(NapiThreadsafeFunction, Pointer<Pointer<Void>>)>(
  symbol: 'napi_get_threadsafe_function_context',
)
external int napiGetThreadsafeFunctionContext(
  NapiThreadsafeFunction func,
  Pointer<Pointer<Void>> result,
);

@Available(napi: 4)
@Native<Int32 Function(NapiThreadsafeFunction, Pointer<Void>, Int32)>(
  symbol: 'napi_call_threadsafe_function',
)
external int napiCallThreadsafeFunction(
  NapiThreadsafeFunction func,
  Pointer<Void> data,
  int isBlocking,
);

@Available(napi: 4)
@Native<Int32 Function(NapiThreadsafeFunction)>(
  symbol: 'napi_acquire_threadsafe_function',
)
external int napiAcquireThreadsafeFunction(NapiThreadsafeFunction func);

@Available(napi: 4)
@Native<Int32 Function(NapiThreadsafeFunction, Int32)>(
  symbol: 'napi_release_threadsafe_function',
)
external int napiReleaseThreadsafeFunction(
  NapiThreadsafeFunction func,
  int mode,
);

@Available(napi: 4)
@Native<Int32 Function(NapiEnv, NapiThreadsafeFunction)>(
  symbol: 'napi_unref_threadsafe_function',
)
external int napiUnrefThreadsafeFunction(
  NapiEnv env,
  NapiThreadsafeFunction func,
);

@Available(napi: 4)
@Native<Int32 Function(NapiEnv, NapiThreadsafeFunction)>(
  symbol: 'napi_ref_threadsafe_function',
)
external int napiRefThreadsafeFunction(
  NapiEnv env,
  NapiThreadsafeFunction func,
);

@Available(napi: 5)
@Native<Int32 Function(NapiEnv, Double, Pointer<NapiValue>)>(
  symbol: 'napi_create_date',
)
external int napiCreateDate(
  NapiEnv env,
  double time,
  Pointer<NapiValue> result,
);

@Available(napi: 5)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_is_date',
)
external int napiIsDate(NapiEnv env, NapiValue value, Pointer<Bool> isDate);

@Available(napi: 5)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Double>)>(
  symbol: 'napi_get_date_value',
)
external int napiGetDateValue(
  NapiEnv env,
  NapiValue value,
  Pointer<Double> result,
);

@Available(napi: 5)
@Native<
  Int32 Function(
    NapiEnv,
    NapiValue,
    Pointer<Void>,
    Pointer<NativeFunction<NapiFinalize>>,
    Pointer<Void>,
    Pointer<NapiRef>,
  )
>(symbol: 'napi_add_finalizer')
external int napiAddFinalizer(
  NapiEnv env,
  NapiValue jsObject,
  Pointer<Void> finalizeData,
  Pointer<NativeFunction<NapiFinalize>> finalizeCb,
  Pointer<Void> finalizeHint,
  Pointer<NapiRef> result,
);

@Available(napi: 6)
@Native<Int32 Function(NapiEnv, Int64, Pointer<NapiValue>)>(
  symbol: 'napi_create_bigint_int64',
)
external int napiCreateBigintInt64(
  NapiEnv env,
  int value,
  Pointer<NapiValue> result,
);

@Available(napi: 6)
@Native<Int32 Function(NapiEnv, Uint64, Pointer<NapiValue>)>(
  symbol: 'napi_create_bigint_uint64',
)
external int napiCreateBigintUint64(
  NapiEnv env,
  int value,
  Pointer<NapiValue> result,
);

@Available(napi: 6)
@Native<
  Int32 Function(NapiEnv, Int32, Size, Pointer<Uint64>, Pointer<NapiValue>)
>(symbol: 'napi_create_bigint_words')
external int napiCreateBigintWords(
  NapiEnv env,
  int signBit,
  int wordCount,
  Pointer<Uint64> words,
  Pointer<NapiValue> result,
);

@Available(napi: 6)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Int64>, Pointer<Bool>)>(
  symbol: 'napi_get_value_bigint_int64',
)
external int napiGetValueBigintInt64(
  NapiEnv env,
  NapiValue value,
  Pointer<Int64> result,
  Pointer<Bool> lossless,
);

@Available(napi: 6)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Uint64>, Pointer<Bool>)>(
  symbol: 'napi_get_value_bigint_uint64',
)
external int napiGetValueBigintUint64(
  NapiEnv env,
  NapiValue value,
  Pointer<Uint64> result,
  Pointer<Bool> lossless,
);

@Available(napi: 6)
@Native<
  Int32 Function(
    NapiEnv,
    NapiValue,
    Pointer<Int32>,
    Pointer<Size>,
    Pointer<Uint64>,
  )
>(symbol: 'napi_get_value_bigint_words')
external int napiGetValueBigintWords(
  NapiEnv env,
  NapiValue value,
  Pointer<Int32> signBit,
  Pointer<Size> wordCount,
  Pointer<Uint64> words,
);

@Available(napi: 6)
@Native<
  Int32 Function(NapiEnv, NapiValue, Int32, Int32, Int32, Pointer<NapiValue>)
>(symbol: 'napi_get_all_property_names')
external int napiGetAllPropertyNames(
  NapiEnv env,
  NapiValue object,
  int keyMode,
  int keyFilter,
  int keyConversion,
  Pointer<NapiValue> result,
);

@Available(napi: 6)
@Native<
  Int32 Function(
    NapiEnv,
    Pointer<Void>,
    Pointer<NativeFunction<NapiFinalize>>,
    Pointer<Void>,
  )
>(symbol: 'napi_set_instance_data')
external int napiSetInstanceData(
  NapiEnv env,
  Pointer<Void> data,
  Pointer<NativeFunction<NapiFinalize>> finalizeCb,
  Pointer<Void> finalizeHint,
);

@Available(napi: 6)
@Native<Int32 Function(NapiEnv, Pointer<Pointer<Void>>)>(
  symbol: 'napi_get_instance_data',
)
external int napiGetInstanceData(NapiEnv env, Pointer<Pointer<Void>> data);

@Available(napi: 7)
@Native<Int32 Function(NapiEnv, NapiValue)>(symbol: 'napi_detach_arraybuffer')
external int napiDetachArraybuffer(NapiEnv env, NapiValue arraybuffer);

@Available(napi: 7)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Bool>)>(
  symbol: 'napi_is_detached_arraybuffer',
)
external int napiIsDetachedArraybuffer(
  NapiEnv env,
  NapiValue value,
  Pointer<Bool> result,
);

@Available(napi: 8)
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<NapiTypeTag>)>(
  symbol: 'napi_type_tag_object',
)
external int napiTypeTagObject(
  NapiEnv env,
  NapiValue value,
  Pointer<NapiTypeTag> typeTag,
);

@Available(napi: 8)
@Native<
  Int32 Function(NapiEnv, NapiValue, Pointer<NapiTypeTag>, Pointer<Bool>)
>(symbol: 'napi_check_object_type_tag')
external int napiCheckObjectTypeTag(
  NapiEnv env,
  NapiValue value,
  Pointer<NapiTypeTag> typeTag,
  Pointer<Bool> result,
);

@Available(napi: 8)
@Native<Int32 Function(NapiEnv, NapiValue)>(symbol: 'napi_object_freeze')
external int napiObjectFreeze(NapiEnv env, NapiValue object);

@Available(napi: 8)
@Native<Int32 Function(NapiEnv, NapiValue)>(symbol: 'napi_object_seal')
external int napiObjectSeal(NapiEnv env, NapiValue object);

@Available(napi: 8)
@Native<
  Int32 Function(
    NapiEnv,
    Pointer<NativeFunction<NapiAsyncCleanupHook>>,
    Pointer<Void>,
    Pointer<NapiAsyncCleanupHookHandle>,
  )
>(symbol: 'napi_add_async_cleanup_hook')
external int napiAddAsyncCleanupHook(
  NapiEnv env,
  Pointer<NativeFunction<NapiAsyncCleanupHook>> hook,
  Pointer<Void> arg,
  Pointer<NapiAsyncCleanupHookHandle> removeHandle,
);

@Available(napi: 8)
@Native<Int32 Function(NapiAsyncCleanupHookHandle)>(
  symbol: 'napi_remove_async_cleanup_hook',
)
external int napiRemoveAsyncCleanupHook(
  NapiAsyncCleanupHookHandle removeHandle,
);

@Available(napi: 9)
@Native<Int32 Function(NapiEnv, Pointer<Char>, Size, Pointer<NapiValue>)>(
  symbol: 'node_api_symbol_for',
)
external int nodeApiSymbolFor(
  NapiEnv env,
  Pointer<Char> utf8description,
  int length,
  Pointer<NapiValue> result,
);

@Available(napi: 9)
@Native<Int32 Function(NapiEnv, NapiValue, NapiValue, Pointer<NapiValue>)>(
  symbol: 'node_api_create_syntax_error',
)
external int nodeApiCreateSyntaxError(
  NapiEnv env,
  NapiValue code,
  NapiValue msg,
  Pointer<NapiValue> result,
);

@Available(napi: 9)
@Native<Int32 Function(NapiEnv, Pointer<Char>, Pointer<Char>)>(
  symbol: 'node_api_throw_syntax_error',
)
external int nodeApiThrowSyntaxError(
  NapiEnv env,
  Pointer<Char> code,
  Pointer<Char> msg,
);

@Available(napi: 9)
@Native<Int32 Function(NapiEnv, Pointer<Pointer<Char>>)>(
  symbol: 'node_api_get_module_file_name',
)
external int nodeApiGetModuleFileName(
  NapiEnv env,
  Pointer<Pointer<Char>> result,
);

@Available(napi: 10)
@Native<
  Int32 Function(
    NapiEnv,
    Pointer<Char>,
    Size,
    Pointer<NativeFunction<NapiFinalize>>,
    Pointer<Void>,
    Pointer<NapiValue>,
    Pointer<Bool>,
  )
>(symbol: 'node_api_create_external_string_latin1')
external int nodeApiCreateExternalStringLatin1(
  NapiEnv env,
  Pointer<Char> str,
  int length,
  Pointer<NativeFunction<NapiFinalize>> finalizeCallback,
  Pointer<Void> finalizeHint,
  Pointer<NapiValue> result,
  Pointer<Bool> copied,
);

@Available(napi: 10)
@Native<
  Int32 Function(
    NapiEnv,
    Pointer<Uint16>,
    Size,
    Pointer<NativeFunction<NapiFinalize>>,
    Pointer<Void>,
    Pointer<NapiValue>,
    Pointer<Bool>,
  )
>(symbol: 'node_api_create_external_string_utf16')
external int nodeApiCreateExternalStringUtf16(
  NapiEnv env,
  Pointer<Uint16> str,
  int length,
  Pointer<NativeFunction<NapiFinalize>> finalizeCallback,
  Pointer<Void> finalizeHint,
  Pointer<NapiValue> result,
  Pointer<Bool> copied,
);

@Available(napi: 10)
@Native<Int32 Function(NapiEnv, Pointer<Char>, Size, Pointer<NapiValue>)>(
  symbol: 'node_api_create_property_key_latin1',
)
external int nodeApiCreatePropertyKeyLatin1(
  NapiEnv env,
  Pointer<Char> str,
  int length,
  Pointer<NapiValue> result,
);

@Available(napi: 10)
@Native<Int32 Function(NapiEnv, Pointer<Char>, Size, Pointer<NapiValue>)>(
  symbol: 'node_api_create_property_key_utf8',
)
external int nodeApiCreatePropertyKeyUtf8(
  NapiEnv env,
  Pointer<Char> str,
  int length,
  Pointer<NapiValue> result,
);

@Available(napi: 10)
@Native<Int32 Function(NapiEnv, Pointer<Uint16>, Size, Pointer<NapiValue>)>(
  symbol: 'node_api_create_property_key_utf16',
)
external int nodeApiCreatePropertyKeyUtf16(
  NapiEnv env,
  Pointer<Uint16> str,
  int length,
  Pointer<NapiValue> result,
);

@Available(napi: 10)
@Native<Int32 Function(NapiEnv, NapiValue, Size, Size, Pointer<NapiValue>)>(
  symbol: 'node_api_create_buffer_from_arraybuffer',
)
external int nodeApiCreateBufferFromArraybuffer(
  NapiEnv env,
  NapiValue arraybuffer,
  int byteOffset,
  int byteLength,
  Pointer<NapiValue> result,
);

@experimental
@Available(node: '>=24.12.0 <25.0.0 || >=25.2.0')
@Native<
  Int32 Function(
    NapiEnv,
    NapiValue,
    Pointer<NapiValue>,
    Pointer<NapiValue>,
    Size,
    Pointer<NapiValue>,
  )
>(symbol: 'node_api_create_object_with_properties')
external int nodeApiCreateObjectWithProperties(
  NapiEnv env,
  NapiValue prototypeOrNull,
  Pointer<NapiValue> propertyNames,
  Pointer<NapiValue> propertyValues,
  int propertyCount,
  Pointer<NapiValue> result,
);

@experimental
@Available(node: '>=24.13.1 <25.0.0 || >=25.4.0')
@Native<Int32 Function(NapiEnv, NapiValue, NapiValue)>(
  symbol: 'node_api_set_prototype',
)
external int nodeApiSetPrototype(
  NapiEnv env,
  NapiValue object,
  NapiValue value,
);

@experimental
@Available(node: '>=24.16.0 <25.0.0 || >=26.1.0')
@Native<
  Int32 Function(
    NapiEnv,
    Pointer<Void>,
    Size,
    Pointer<NativeFunction<NodeApiNoenvFinalize>>,
    Pointer<Void>,
    Pointer<NapiValue>,
  )
>(symbol: 'node_api_create_external_sharedarraybuffer')
external int nodeApiCreateExternalSharedarraybuffer(
  NapiEnv env,
  Pointer<Void> externalData,
  int byteLength,
  Pointer<NativeFunction<NodeApiNoenvFinalize>> finalizeCallback,
  Pointer<Void> finalizeHint,
  Pointer<NapiValue> result,
);

@experimental
@Available(node: '>=22.21.0 <23.0.0 || >=24.9.0')
@Native<Int32 Function(NapiEnv, NapiValue, Pointer<Bool>)>(
  symbol: 'node_api_is_sharedarraybuffer',
)
external int nodeApiIsSharedarraybuffer(
  NapiEnv env,
  NapiValue value,
  Pointer<Bool> result,
);

@experimental
@Available(node: '>=22.21.0 <23.0.0 || >=24.9.0')
@Native<
  Int32 Function(NapiEnv, Size, Pointer<Pointer<Void>>, Pointer<NapiValue>)
>(symbol: 'node_api_create_sharedarraybuffer')
external int nodeApiCreateSharedarraybuffer(
  NapiEnv env,
  int byteLength,
  Pointer<Pointer<Void>> data,
  Pointer<NapiValue> result,
);

@experimental
@Available(node: '>=18.19.0 <19.0.0 || >=20.10.0')
@Native<
  Int32 Function(
    NodeApiBasicEnv,
    Pointer<NativeFunction<NapiFinalize>>,
    Pointer<Void>,
    Pointer<Void>,
  )
>(symbol: 'node_api_post_finalizer')
external int nodeApiPostFinalizer(
  NodeApiBasicEnv env,
  Pointer<NativeFunction<NapiFinalize>> finalizeCallback,
  Pointer<Void> finalizeData,
  Pointer<Void> finalizeHint,
);
