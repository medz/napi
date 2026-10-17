// Compiler-private bridge ABI, version 11. Keep generated Dart in lockstep.
// Version 11 adds canonical cleanup Promises and final-settlement retention.
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
// Future callback metadata appends true after arity. These callbacks are
// int Function(int envAddress, int callbackInfoAddress, int futureToken), and
// normally return zero; C creates the Promise before Dart validation. Cleanup
// callbacks may return a canonical Promise's napi_value pointer from slot 44.
// releaseFuture(int futureToken) acknowledges resolver handoff, or final observed
// settlement for resource leases, outside the JS resolver's Dart entry.
// Other callbacks are int Function(int envAddress, int callbackInfoAddress).
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
  bridge_snapshot_map = 35,
  bridge_create_map = 36,
  bridge_checked_insert_map = 37,
  bridge_dictionary_keys = 38,
  bridge_create_dictionary = 39,
  bridge_read_optional_own_value = 40,
  bridge_is_constructor_target = 41,
  bridge_register_reference_shape = 42,
  bridge_queue_promise_settlement = 43,
  bridge_bind_cleanup_promise = 44,
  bridge_observe_future_settlement = 45,
  bridge_api_count = 46,
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
// Creates a static instance using the captured constructor, or a neutral plain
// wrapper using a registered composite creator. No Dart business constructor is
// executed. The new lease is already retained by Dart.
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
// Snapshot genuine Map entries with captured intrinsics before any child
// conversion can reenter JS. The dense array contains key/value pairs in order;
// its entries and all returned handles belong to the current callback scope.
typedef napi_status (*BridgeSnapshotMap)(
    napi_env, napi_value input, napi_value path, uint32_t remaining,
    uint32_t depth, bool cyclic, napi_value* pairs, uint32_t* count);
typedef napi_status (*BridgeCreateMap)(napi_env, napi_value* result);
// Key and value are converted before checking JS SameValueZero equality.
// A collision throws at keyPath without overwriting the previous entry.
typedef napi_status (*BridgeCheckedInsertMap)(
    napi_env, napi_value map, napi_value key, napi_value value, napi_value keyPath);
// Capture string keys only. Values remain on the original object and their own
// data descriptors are read one child at a time with bridge_read_own_value.
typedef napi_status (*BridgeDictionaryKeys)(
    napi_env, napi_value input, napi_value path, uint32_t remaining,
    uint32_t depth, bool cyclic, napi_value* keys, uint32_t* count);
typedef napi_status (*BridgeCreateDictionary)(napi_env, napi_value* result);

// Missing own properties return napi_ok with *result == nullptr. Present data
// properties containing JS undefined/null retain their ordinary napi_value;
// accessors and reflection errors follow BridgeReadOwnValue without rereading.
typedef BridgeReadOwnValue BridgeReadOptionalOwnValue;

// Compare new.target with this Owner's captured original constructor. No JS
// property lookup or user callback participates; false for an ordinary call.
typedef napi_status (*BridgeIsConstructorTarget)(
    napi_env, napi_callback_info, uint32_t classId, bool* result);

// Register a metadata-only composite shape using the loader's private resolver.
// IDs are sorted selected class IDs. Dynamic shape IDs start after the selected
// classes. Resolution errors keep their original contextful JS exception.
typedef napi_status (*BridgeRegisterReferenceShape)(
    napi_env, uint32_t shapeId, const uint32_t* viewIds, size_t count,
    napi_value context);

// Retain a result in the private capability and queue owner-thread settlement.
// This never invokes a resolver under Dart. With reject=true, a pending JS
// exception is captured/cleared verbatim; null value without one uses a fixed
// Error fallback. Ordinary JS null/undefined have nonnull napi_value handles.
typedef napi_status (*BridgeQueuePromiseSettlement)(
    napi_env, int64_t futureToken, napi_value value, bool reject);

// Bind a freshly allocated capability to a stable raw ResourceControl identity.
// A hit discards the unexposed candidate and returns the existing weakly cached
// Promise with first=false. Dart must discard that candidate's pending record.
// A miss publishes the candidate before cleanup can reenter, first=true.
typedef napi_status (*BridgeBindCleanupPromise)(
    napi_env, int64_t futureToken, int64_t controlId, napi_value* result, bool* first);

// A call with resource leases and a potentially object-valued output requests
// final settlement acknowledgement. C observes only an actual object/function
// fulfillment, outside Dart; rejection, null and primitives retain handoff ack.
typedef napi_status (*BridgeObserveFutureSettlement)(napi_env, int64_t futureToken);
