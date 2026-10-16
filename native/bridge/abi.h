// Compiler-private bridge ABI, version 3. Keep generated Dart in lockstep.
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
// classId is the zero-based class registration order, excluding function entries.
// A class without a public unnamed constructor still supplies a throwing
// callback; internal adoption bypasses it when wrapping an existing Dart value.
// @pragma('vm:entry-point')
// void releaseOwner(int ownerId)
//
// Every callback is int Function(int envAddress, int callbackInfoAddress).
// Its returned int is a napi_value pointer, or zero with a pending exception.
// ownerId is a positive isolate-local integer. A wrapper must use slots 14/15
// rather than raw napi_wrap/napi_unwrap so the stable C finalizer owns tokens.
// A cross-isolate/foreign receiver returns zero; Dart adds a pathful TypeError.
// On ordinary JS GC releaseOwner removes the Dart strong reference; automatic
// business dispose is a separate lifetime policy, not promised by this ABI.
// GC during any Dart callback defers release until a safe outer callback edge.
// A new wrapper always gets a new ownerId, including after a weak cache miss.
// Cache references remain weak; no reference policy calls business cleanup.

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
  bridge_reference_value = 28,
  bridge_reference_create = 29,
  bridge_inspect_shape = 30,
  bridge_read_own_value = 31,
  bridge_strict_equals = 32,
  bridge_create_container = 33,
  bridge_define_own_value = 34,
  bridge_api_count = 35,
};
typedef napi_status (*BridgeOwnerWrap)(napi_env, napi_value self, int64_t ownerId);
typedef int64_t (*BridgeOwnerUnwrap)(napi_env, napi_value self);
typedef napi_status (*BridgeReadOptions)(
    napi_env, napi_value input, bool supplied, const char* const* names,
    size_t count, napi_value* values, uint8_t* present, const char* context);
// A successful lookup with *result == nullptr is a cache miss. Live results are
// ordinary handles in the current Node callback scope, not owning napi_refs.
typedef napi_status (*BridgeReferenceValue)(
    napi_env, int64_t ownerId, napi_value* result);
// Creates a genuine instance using the captured constructor, without executing
// the Dart business constructor. The new lease is already retained by Dart.
typedef napi_status (*BridgeReferenceCreate)(
    napi_env, uint32_t classId, int64_t ownerId, napi_value* result);
// Node-local operations only: no schema traversal, persistent refs or C state.
// fields/key/path are JS strings (UTF-16); all handles use the callback scope.
// inspect_shape checks type/plain shape, depth/cycle flags, keys and remaining
// work. Array length is read once; own child descriptors are read during recursion.
typedef napi_status (*BridgeInspectShape)(
    napi_env, napi_value input, bool array, const napi_value* fields, size_t count,
    napi_value path, uint32_t remaining, uint32_t depth, bool cyclic,
    uint32_t* length);
typedef napi_status (*BridgeReadOwnValue)(
    napi_env, napi_value input, napi_value key, napi_value path, napi_value* result);
typedef napi_status (*BridgeCreateContainer)(
    napi_env, bool array, uint32_t length, napi_value* result);
typedef napi_status (*BridgeDefineOwnValue)(
    napi_env, napi_value container, napi_value key, napi_value value);
