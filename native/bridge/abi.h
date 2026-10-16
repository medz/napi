// Compiler-private bridge ABI, version 1. Keep generated Dart in lockstep.
#pragma once
#include <node_api.h>
#include <stdint.h>

// Dart root library:
// @pragma('vm:entry-point')
// List<Object?> napiBindings(int tableAddress, int tableCount)
//   => [ ['function', jsName, callback, arity],
//        ['class', jsName, constructorCallback,
//          [ [memberKind, memberName, callback, arity], ... ], arity], ... ];
// memberKind: method/getter/setter/staticMethod/staticGetter/staticSetter.
// Getter/setter pairs share a descriptor but retain separate Dart closures.
// @pragma('vm:entry-point')
// void releaseOwner(int ownerId)
//
// Every callback is int Function(int envAddress, int callbackInfoAddress).
// Its returned int is a napi_value pointer, or zero with a pending exception.
// ownerId is a positive isolate-local integer. A wrapper must use slots 14/15
// rather than raw napi_wrap/napi_unwrap so the stable C finalizer owns tokens.
// A cross-isolate/foreign receiver returns zero and throws a TypeError.
// On ordinary JS GC releaseOwner removes the Dart strong reference; automatic
// business dispose is a separate lifetime policy, not promised by this ABI.
// Foreign-isolate reentrant GC defers release until next callback or teardown.

enum BridgeApiSlot {
  bridge_get_cb_info = 0,          // typeof(&napi_get_cb_info)
  bridge_typeof = 1,              // typeof(&napi_typeof)
  bridge_get_value_double = 2,    // typeof(&napi_get_value_double)
  bridge_create_double = 3,       // typeof(&napi_create_double)
  bridge_throw_type_error = 4,    // typeof(&napi_throw_type_error)
  bridge_throw_range_error = 5,   // typeof(&napi_throw_range_error)
  bridge_get_undefined = 6,       // typeof(&napi_get_undefined)
  bridge_get_null = 7,            // typeof(&napi_get_null)
  bridge_get_value_string_utf16 = 8, // typeof(&napi_get_value_string_utf16)
  bridge_create_string_utf16 = 9, // typeof(&napi_create_string_utf16)
  bridge_get_new_target = 10,     // typeof(&napi_get_new_target)
  bridge_napi_wrap = 11,          // typeof(&napi_wrap), reserved; use bridge ownership helpers
  bridge_napi_unwrap = 12,        // typeof(&napi_unwrap), reserved; use bridge ownership helpers
  bridge_create_int64 = 13,       // typeof(&napi_create_int64)
  bridge_owner_wrap = 14,         // BridgeOwnerWrap
  bridge_owner_unwrap = 15,       // BridgeOwnerUnwrap
  bridge_get_value_bool = 16,
  bridge_get_boolean = 17,
  bridge_get_value_bigint_int64 = 18,
  bridge_create_bigint_int64 = 19,
  bridge_get_value_bigint_words = 20,
  bridge_create_bigint_words = 21,
  bridge_create_error = 22,
  bridge_create_type_error = 23,
  bridge_create_range_error = 24,
  bridge_throw = 25,
  bridge_is_exception_pending = 26,
  bridge_read_options = 27,
  bridge_api_count = 28,
};
typedef napi_status (*BridgeOwnerWrap)(napi_env, napi_value self, int64_t ownerId);
typedef int64_t (*BridgeOwnerUnwrap)(napi_env, napi_value self);
typedef napi_status (*BridgeReadOptions)(
    napi_env, napi_value input, bool supplied, const char* const* names,
    size_t count, napi_value* values, uint8_t* present, const char* context);
