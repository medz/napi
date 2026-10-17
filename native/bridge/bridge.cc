// Generic Node-API bridge for Dart AOT bindings and owner-thread event delivery.
#include <node_api.h>
#include <uv.h>
#include <algorithm>
#include <atomic>
#include <dlfcn.h>
#include <deque>
#include <limits>
#include <cstdint>
#include <cmath>
#include <cstdio>
#include <cerrno>
#include <cstring>
#include <cstdlib>
#include <mutex>
#include <new>
#include <map>
#include <set>
#include <string>
#include <vector>
#include "runtime.h"
#include "expected_runtime.h"
#include "abi.h"

static std::once_flag initialize_once;
static std::string initialize_error;

struct Owner;
struct Callback {
  Owner* owner;
  Dart_PersistentHandle closure;
  int64_t class_id = -1;
  bool returns_future = false;
};
struct Property {
  Callback* getter = nullptr;
  Callback* setter = nullptr;
  int64_t getter_arity = 0;
  int64_t setter_arity = 0;
};
struct Wrapper {
  Owner* owner;
  int64_t id;
  napi_ref reference = nullptr;
  Wrapper* next_release = nullptr;
};
struct Adoption {
  uint32_t class_id;
  int64_t id;
  bool consumed = false;
};
struct PendingFuture {
  napi_ref capability;
  bool queued = false;
  bool reject = false;
  bool observed = false;
  bool release_queued = false;
};
struct CleanupPromise {
  Owner* owner;
  int64_t id;
  napi_ref reference = nullptr;
};
// A JS callback can outlive a failed load or the uv_close callback. Its finalizer
// owns this sentinel; teardown invalidates the owner without invoking JS.
struct FutureRelease {
  Owner* owner;
};
struct ReferenceShape {
  std::vector<uint32_t> views;
  napi_ref creator;
};
enum MapIntrinsic { map_constructor, map_size, map_entries, map_next,
                    map_has, map_set, map_intrinsic_count };
struct Owner {
  explicit Owner(napi_env value) : env(value) {}
  napi_env env;
  NapiDart_Isolate* isolate = nullptr;
  bool closing = false;
  uv_async_t wakeup = {};
  bool wakeup_initialized = false;
  bool pump_scheduled = false;
  std::atomic<uint64_t> messages{0};
  napi_ref async_resource = nullptr;
  napi_async_context async_context = nullptr;
  napi_async_cleanup_hook_handle cleanup_hook = nullptr;
  Dart_PersistentHandle release_owner = nullptr;
  Dart_PersistentHandle release_future = nullptr;
  napi_ref promise_factory = nullptr;
  napi_ref promise_observer = nullptr;
  napi_ref release_callback = nullptr;
  FutureRelease* future_release = nullptr;
  int64_t next_future = 1;
  std::map<int64_t, PendingFuture> futures;
  std::map<int64_t, CleanupPromise*> cleanup_promises;
  std::deque<int64_t> settlements;
  std::deque<int64_t> future_releases;
  bool flushing_futures = false;
  std::vector<Callback*> callbacks;
  std::vector<Property*> properties;
  std::vector<napi_ref> constructors;
  napi_ref reference_resolver = nullptr;
  std::map<uint32_t, ReferenceShape> reference_shapes;
  bool resolving_reference_shape = false;
  std::set<Wrapper*> wrappers;
  std::map<int64_t, Wrapper*> references;
  Wrapper* pending_releases = nullptr;
  Adoption* adoption = nullptr;
  napi_ref maps[map_intrinsic_count] = {};
  napi_ref dictionary_create = nullptr;
  int64_t next_host_value = 1;
  std::map<int64_t, napi_ref> host_values;
};
static thread_local Owner* active_owner = nullptr;

static napi_value fail(napi_env env, const char* message) {
  bool pending = false;
  napi_is_exception_pending(env, &pending);
  if (!pending) napi_throw_type_error(env, nullptr, message);
  return nullptr;
}
static napi_value fail_error(napi_env env, const char* message) {
  bool pending = false;
  napi_is_exception_pending(env, &pending);
  if (!pending) napi_throw_error(env, nullptr, message);
  return nullptr;
}

// Only the owner thread adjusts libuv liveness. A queued microtask drain keeps
// Node alive even when Dart has no live port and never sent a notification.
static void schedule_pump(Owner* owner) {
  if (owner->closing || owner->pump_scheduled) return;
  owner->pump_scheduled = true;
  uv_ref(reinterpret_cast<uv_handle_t*>(&owner->wakeup));
  uv_async_send(&owner->wakeup);
}

struct Scope {
  Owner* owner;
  Owner* previous;
  bool schedule;
  bool entered = false;
  explicit Scope(Owner* value, bool report = true, bool schedule_after = true)
      : owner(value), previous(active_owner), schedule(schedule_after) {
    char* error = nullptr;
    if (!NapiDart_EnterIsolate(owner->isolate, &error)) {
      if (report) fail(owner->env, error ? error : "Cannot enter Dart isolate");
      NapiDart_FreeError(error);
      return;
    }
    entered = true;
    Dart_EnterScope();
    active_owner = owner;
  }
  ~Scope() {
    if (!entered) return;
    active_owner = previous;
    Dart_ExitScope();
    char* error = nullptr;
    if (!NapiDart_ExitIsolate(owner->isolate, &error)) {
      // A balanced scope cannot fail the runtime's owner/entry checks. Stop
      // rather than continue with an unknown current-isolate state.
      std::fprintf(stderr, "NapiDart_ExitIsolate failed: %s\n", error ? error : "unknown error");
      NapiDart_FreeError(error);
      std::abort();
    }
    if (!previous && schedule) schedule_pump(owner);
  }
};

static void release(Owner* owner, int64_t id) {
  Dart_Handle arg = Dart_NewInteger(id);
  // Finalizers cannot raise a useful JS exception. Teardown releases the whole
  // isolate even if a user release hook unexpectedly fails.
  (void)Dart_InvokeClosure(
      Dart_HandleFromPersistent(owner->release_owner), 1, &arg);
}

static void drain_releases(Owner* owner) {
  auto pending = owner->pending_releases;
  owner->pending_releases = nullptr;
  while (pending) {
    auto next = pending->next_release;
    release(owner, pending->id);
    delete pending;
    pending = next;
  }
}

static void defer_release(Owner* owner, Wrapper* wrapper) {
  wrapper->next_release = owner->pending_releases;
  owner->pending_releases = wrapper;
}

static void notify_message(void* data) {
  auto owner = static_cast<Owner*>(data);
  // uv_async coalesces wakeups, but Dart requires one HandleMessage call per
  // notification. ShutdownIsolate joins notifications before uv_close begins.
  owner->messages.fetch_add(1, std::memory_order_relaxed);
  uv_async_send(&owner->wakeup);
}

static void report_async_error(napi_env env, const std::string& message) {
  bool pending = false;
  napi_value exception = nullptr;
  napi_is_exception_pending(env, &pending);
  if (pending) {
    napi_get_and_clear_last_exception(env, &exception);
  } else if (!message.empty()) {
    napi_value text;
    if (napi_create_string_utf8(env, message.data(), message.size(), &text) == napi_ok)
      napi_create_error(env, nullptr, text, &exception);
  }
  // This may invoke an uncaughtException handler and reenter a Dart export.
  // All Dart entries/scopes must already have ended.
  if (exception) napi_fatal_exception(env, exception);
}

// A normal reference owns the private [promise, resolve, reject, payload] array.
// Unlike napi_deferred it can be deleted without invoking JS during teardown.
static napi_status create_future(Owner* owner, int64_t* token, napi_value* promise) {
  auto env = owner->env;
  if (!owner->promise_factory || owner->next_future == std::numeric_limits<int64_t>::max()) {
    fail_error(env, "Cannot create native Promise capability");
    return napi_generic_failure;
  }
  napi_value factory, receiver, capability;
  auto status = napi_get_reference_value(env, owner->promise_factory, &factory);
  if (status == napi_ok) status = napi_get_undefined(env, &receiver);
  if (status == napi_ok) status = napi_call_function(env, receiver, factory, 0, nullptr, &capability);
  bool array = false, genuine = false;
  if (status == napi_ok) status = napi_is_array(env, capability, &array);
  if (status == napi_ok && array) status = napi_get_element(env, capability, 0, promise);
  if (status == napi_ok && array) status = napi_is_promise(env, *promise, &genuine);
  for (uint32_t i = 1; status == napi_ok && genuine && i <= 2; ++i) {
    napi_value resolver;
    napi_valuetype type;
    status = napi_get_element(env, capability, i, &resolver);
    if (status == napi_ok) status = napi_typeof(env, resolver, &type);
    if (status == napi_ok && type != napi_function) genuine = false;
  }
  if (status != napi_ok) return status;
  if (!array || !genuine) {
    fail_error(env, "Invalid native Promise capability");
    return napi_invalid_arg;
  }
  napi_ref reference = nullptr;
  status = napi_create_reference(env, capability, 1, &reference);
  if (status != napi_ok) return status;
  try {
    *token = owner->next_future++;
    owner->futures.emplace(*token, PendingFuture{reference});
  } catch (const std::bad_alloc&) {
    napi_delete_reference(env, reference);
    fail_error(env, "Cannot retain native Promise capability");
    return napi_generic_failure;
  }
  return napi_ok;
}

static napi_status queue_future(Owner* owner, int64_t token, napi_value value, bool reject) {
  auto env = owner->env;
  auto found = owner->futures.find(token);
  if (found == owner->futures.end() || found->second.queued) return napi_invalid_arg;
  auto& future = found->second;
  // A null C pointer requests capture of the pending exception. JS null and
  // undefined are nonnull napi_values, and preserve their exact rejection value.
  if (reject) {
    bool pending = false;
    auto status = napi_is_exception_pending(env, &pending);
    if (status != napi_ok) return status;
    if (pending) {
      status = napi_get_and_clear_last_exception(env, &value);
      if (status != napi_ok) return status;
    }
    if (!value) {
      napi_value text;
      status = napi_create_string_utf8(env, "Dart Future failed (error description unavailable)",
                                       NAPI_AUTO_LENGTH, &text);
      if (status == napi_ok) status = napi_create_error(env, nullptr, text, &value);
      if (status != napi_ok) return status;
    }
  }
  if (!value) return napi_invalid_arg;
  napi_value capability;
  auto status = napi_get_reference_value(env, future.capability, &capability);
  if (status != napi_ok) return status;
  napi_property_descriptor payload = {"3", nullptr, nullptr, nullptr, nullptr,
                                      value, napi_default_jsproperty, nullptr};
  status = napi_define_properties(env, capability, 1, &payload);
  if (status != napi_ok) return status;
  try {
    owner->settlements.push_back(token);
  } catch (const std::bad_alloc&) {
    fail_error(env, "Cannot queue native Promise settlement");
    return napi_generic_failure;
  }
  future.queued = true;
  future.reject = reject;
  schedule_pump(owner);
  return napi_ok;
}

static napi_status queue_promise_settlement(napi_env env, int64_t token,
                                             napi_value value, bool reject) {
  auto owner = active_owner;
  if (!owner || owner->env != env || owner->closing) return napi_invalid_arg;
  return queue_future(owner, token, value, reject);
}

static void finalize_cleanup_promise(napi_env env, void* data, void*) {
  auto cached = static_cast<CleanupPromise*>(data);
  if (cached->reference) napi_delete_reference(env, cached->reference);
  if (auto owner = cached->owner) {
    auto found = owner->cleanup_promises.find(cached->id);
    if (found != owner->cleanup_promises.end() && found->second == cached)
      owner->cleanup_promises.erase(found);
  }
  delete cached;
}

// The raw ResourceControl owns the stable id, not any JS wrapper. Only a live
// Promise is reused; the cache and its finalizer never retain the Dart object.
static napi_status bind_cleanup_promise(napi_env env, int64_t token, int64_t id,
                                        napi_value* result, bool* first) {
  auto owner = active_owner;
  if (!owner || owner->env != env || owner->closing || id <= 0 || !result || !first)
    return napi_invalid_arg;
  auto candidate = owner->futures.find(token);
  if (candidate == owner->futures.end() || candidate->second.queued)
    return napi_invalid_arg;
  auto found = owner->cleanup_promises.find(id);
  if (found != owner->cleanup_promises.end()) {
    auto status = napi_get_reference_value(env, found->second->reference, result);
    if (status != napi_ok) return status;
    if (*result) {
      napi_delete_reference(env, candidate->second.capability);
      owner->futures.erase(candidate);
      *first = false;
      return napi_ok;
    }
    // Its finalizer may be delayed. Do not let it erase a replacement entry.
    found->second->owner = nullptr;
    owner->cleanup_promises.erase(found);
  }
  napi_value capability;
  auto status = napi_get_reference_value(env, candidate->second.capability, &capability);
  if (status == napi_ok) status = napi_get_element(env, capability, 0, result);
  if (status != napi_ok) return status;
  auto cached = new (std::nothrow) CleanupPromise{owner, id};
  if (!cached) return napi_generic_failure;
  try {
    owner->cleanup_promises.emplace(id, cached);
  } catch (const std::bad_alloc&) {
    delete cached;
    return napi_generic_failure;
  }
  status = napi_add_finalizer(env, *result, cached, finalize_cleanup_promise,
                              nullptr, &cached->reference);
  if (status != napi_ok) {
    owner->cleanup_promises.erase(id);
    delete cached;
    return status;
  }
  *first = true;
  return napi_ok;
}

// Merely mark under Dart. Register the host observer after leaving Dart and
// before invoking either resolver, so arbitrary JS can never reenter this scope.
static napi_status observe_future_settlement(napi_env env, int64_t token) {
  auto owner = active_owner;
  if (!owner || owner->env != env || owner->closing || !owner->promise_observer)
    return napi_invalid_arg;
  auto found = owner->futures.find(token);
  if (found == owner->futures.end() || found->second.queued) return napi_invalid_arg;
  found->second.observed = true;
  return napi_ok;
}

static napi_value release_settled_future(napi_env env, napi_callback_info info) {
  size_t count = 1;
  napi_value argument, undefined;
  void* data = nullptr;
  if (napi_get_cb_info(env, info, &count, &argument, nullptr, &data) != napi_ok || !data)
    return nullptr;
  if (napi_get_undefined(env, &undefined) != napi_ok) return nullptr;
  auto owner = static_cast<FutureRelease*>(data)->owner;
  if (!owner || owner->closing) return undefined;
  int64_t token;
  bool lossless;
  if (count != 1 || napi_get_value_bigint_int64(env, argument, &token, &lossless) != napi_ok || !lossless)
    return fail_error(env, "Invalid native settlement acknowledgement");
  auto found = owner->futures.find(token);
  if (found == owner->futures.end() || found->second.release_queued) return undefined;
  try {
    owner->future_releases.push_back(token);
  } catch (const std::bad_alloc&) {
    return fail_error(env, "Cannot queue native settlement acknowledgement");
  }
  found->second.release_queued = true;
  schedule_pump(owner);
  return undefined;
}

static napi_status initialize_promise_observer(Owner* owner, napi_value factory) {
  auto env = owner->env;
  auto sentinel = new (std::nothrow) FutureRelease{owner};
  if (!sentinel) return napi_generic_failure;
  napi_value callback, receiver, observer, observe;
  auto status = napi_create_function(env, "releaseDartOperation", NAPI_AUTO_LENGTH,
                                     release_settled_future, sentinel, &callback);
  if (status == napi_ok)
    status = napi_add_finalizer(env, callback, sentinel,
        [](napi_env, void* data, void*) {
          auto sentinel = static_cast<FutureRelease*>(data);
          if (sentinel->owner) sentinel->owner->future_release = nullptr;
          delete sentinel;
        }, nullptr, nullptr);
  if (status != napi_ok) {
    delete sentinel;
    return status;
  }
  owner->future_release = sentinel;
  status = napi_create_reference(env, callback, 1, &owner->release_callback);
  if (status != napi_ok) return status;
  status = napi_get_undefined(env, &receiver);
  if (status == napi_ok) status = napi_call_function(env, receiver, factory, 1, &callback, &observer);
  if (status == napi_ok) status = napi_get_named_property(env, observer, "observe", &observe);
  napi_valuetype type;
  if (status == napi_ok) status = napi_typeof(env, observe, &type);
  if (status == napi_ok && type != napi_function) status = napi_function_expected;
  if (status == napi_ok) status = napi_create_reference(env, observe, 1, &owner->promise_observer);
  return status;
}

// Called only with this owner's Dart scope active. The release can start Dart
// cleanup and enqueue messages, so normal pump draining follows it.
static std::string drain_future_releases(Owner* owner) {
  std::string error;
  size_t count = 0;
  while (!owner->future_releases.empty() && count++ < 64) {
    const auto token = owner->future_releases.front();
    owner->future_releases.pop_front();
    auto found = owner->futures.find(token);
    if (found == owner->futures.end()) continue;
    napi_delete_reference(owner->env, found->second.capability);
    owner->futures.erase(found);
    Dart_Handle argument = Dart_NewInteger(token);
    auto result = Dart_InvokeClosure(Dart_HandleFromPersistent(owner->release_future), 1, &argument);
    if (Dart_IsError(result) && error.empty()) error = Dart_GetError(result);
  }
  return error;
}

static void flush_futures(Owner* owner) {
  if (active_owner || owner->closing || owner->flushing_futures) return;
  owner->flushing_futures = true;
  auto env = owner->env;
  // Bound resolver work too: then getters can synchronously call more exports.
  for (size_t count = 0; count < 64 && !owner->closing && !owner->settlements.empty(); ++count) {
    const auto token = owner->settlements.front();
    owner->settlements.pop_front();
    auto found = owner->futures.find(token);
    if (found == owner->futures.end()) continue;
    const auto future = found->second;
    napi_value capability, resolver, value, receiver, ignored;
    auto status = napi_get_reference_value(env, future.capability, &capability);
    if (status == napi_ok) status = napi_get_element(env, capability, future.reject ? 2 : 1, &resolver);
    if (status == napi_ok) status = napi_get_element(env, capability, 3, &value);
    if (status == napi_ok) status = napi_get_undefined(env, &receiver);
    bool observed = false;
    if (status == napi_ok && future.observed && !future.reject) {
      napi_valuetype type;
      status = napi_typeof(env, value, &type);
      observed = status == napi_ok && (type == napi_object || type == napi_function);
    }
    if (status == napi_ok && observed) {
      napi_value observe, promise = nullptr, token_value = nullptr;
      status = napi_get_reference_value(env, owner->promise_observer, &observe);
      if (status == napi_ok) status = napi_get_element(env, capability, 0, &promise);
      if (status == napi_ok) status = napi_create_bigint_int64(env, token, &token_value);
      napi_value arguments[] = {promise, token_value};
      if (status == napi_ok) status = napi_call_function(env, receiver, observe, 2, arguments, &ignored);
    }
    if (observed && status != napi_ok) {
      // An observer failure must reject without starting thenable assimilation.
      // A partially installed observer may later acknowledge a removed token;
      // that is harmless and never releases a lease twice.
      bool pending = false;
      napi_is_exception_pending(env, &pending);
      if (pending) status = napi_get_and_clear_last_exception(env, &value);
      else {
        napi_value message;
        status = napi_create_string_utf8(env, "Cannot observe native Promise settlement", NAPI_AUTO_LENGTH, &message);
        if (status == napi_ok) status = napi_create_error(env, nullptr, message, &value);
      }
      if (status == napi_ok) status = napi_get_element(env, capability, 2, &resolver);
      observed = false;
    }
    // The observer retains the capability until actual final settlement. Other
    // calls need only local handles through resolver reentry and handoff.
    if (!observed) {
      owner->futures.erase(found);
      napi_delete_reference(env, future.capability);
    }
    if (status == napi_ok) status = napi_call_function(env, receiver, resolver, 1, &value, &ignored);
    if (owner->closing) break;
    if (status != napi_ok) {
      bool pending = false;
      napi_is_exception_pending(env, &pending);
      if (status == napi_cannot_run_js || status == napi_closing ||
          (status == napi_pending_exception && !pending)) {
        // A Worker may start stopping between the pump's initial check and a
        // resolver call. Cleanup will drop the remaining Dart roots without JS.
        owner->flushing_futures = false;
        uv_unref(reinterpret_cast<uv_handle_t*>(&owner->wakeup));
        return;
      }
    }
    if (observed) {
      if (status != napi_ok) report_async_error(env, "Cannot observe or settle native Promise");
      continue;
    }
    std::string error;
    {
      Scope scope(owner, false);
      if (scope.entered) {
        Dart_Handle arg = Dart_NewInteger(token);
        auto result = Dart_InvokeClosure(Dart_HandleFromPersistent(owner->release_future), 1, &arg);
        if (Dart_IsError(result)) error = Dart_GetError(result);
      } else {
        error = "Cannot acknowledge native Future settlement";
      }
    }
    if (status != napi_ok && error.empty()) error = "Cannot settle native Promise";
    report_async_error(env, error);
  }
  owner->flushing_futures = false;
  if (!owner->settlements.empty()) schedule_pump(owner);
}

static void pump(uv_async_t* wakeup) {
  auto owner = static_cast<Owner*>(wakeup->data);
  if (owner->closing) return;
  auto env = owner->env;
  owner->pump_scheduled = false;
  napi_handle_scope handles;
  if (napi_open_handle_scope(env, &handles) != napi_ok)
    napi_fatal_error("napi Dart pump", NAPI_AUTO_LENGTH,
                     "Cannot open Node handle scope", NAPI_AUTO_LENGTH);

  // open_callback_scope deliberately permits a stopping environment. A strict
  // identity check runs Node's can-call-JS preamble without allocating or
  // invoking user code, including while a Worker is terminating.
  napi_value resource;
  bool same = false;
  auto status = napi_get_reference_value(env, owner->async_resource, &resource);
  if (status == napi_ok) status = napi_strict_equals(env, resource, resource, &same);
  if (status != napi_ok) {
    uv_unref(reinterpret_cast<uv_handle_t*>(wakeup));
    // Node-API versions below 10 also return pending_exception for a stopping
    // environment, without an actual exception to report.
    bool pending = false;
    napi_is_exception_pending(env, &pending);
    if (pending) {
      schedule_pump(owner);
      report_async_error(env, {});
    } else if (status != napi_cannot_run_js && status != napi_closing &&
               status != napi_pending_exception) {
      napi_fatal_error("napi Dart pump", NAPI_AUTO_LENGTH,
                       "Cannot inspect Node async resource", NAPI_AUTO_LENGTH);
    }
    napi_close_handle_scope(env, handles);
    return;
  }
  napi_callback_scope callback_scope;
  if (napi_open_callback_scope(env, resource, owner->async_context,
                               &callback_scope) != napi_ok) {
    uv_unref(reinterpret_cast<uv_handle_t*>(wakeup));
    report_async_error(env, "Cannot open Node callback scope for Dart events");
    napi_close_handle_scope(env, handles);
    return;
  }

  std::string error;
  bool live = false;
  bool retry_microtasks = false;
  const uint64_t queued = owner->messages.exchange(0, std::memory_order_relaxed);
  uint64_t handled = 0;
  {
    Scope scope(owner, true, false);
    if (scope.entered) {
      auto drain = [&]() {
        bool pending = false;
        napi_is_exception_pending(env, &pending);
        if (pending) {
          retry_microtasks = true;
          return false;
        }
        drain_releases(owner);
        auto released_error = drain_future_releases(owner);
        if (error.empty()) error = released_error;
        char* failure = nullptr;
        if (!NapiDart_DrainMicrotasks(owner->isolate, &failure)) {
          if (error.empty()) error = failure ? failure : "Dart microtask failed";
          // A throwing microtask reschedules the remaining queue without a VM
          // notification. Keep one more drain alive after reporting its error.
          retry_microtasks = true;
        }
        NapiDart_FreeError(failure);
        napi_is_exception_pending(env, &pending);
        if (pending) retry_microtasks = true;
        return error.empty() && !pending;
      };
      bool ok = drain();
      // Bound each turn so a self-posting Dart port cannot starve Node timers.
      while (ok && handled < queued && handled < 64) {
        auto result = Dart_HandleMessage();
        ++handled;
        if (Dart_IsError(result)) error = Dart_GetError(result);
        // The pinned SDK normally drains inside its port dispatcher. Explicitly
        // draining also covers error paths and deferred owner-release effects.
        ok = drain();
      }
      live = Dart_HasLivePorts();
    }
  }
  if (handled < queued)
    owner->messages.fetch_add(queued - handled, std::memory_order_relaxed);
  if (retry_microtasks || owner->messages.load(std::memory_order_relaxed) ||
      !owner->settlements.empty() || !owner->future_releases.empty()) {
    schedule_pump(owner);
  } else if (live) {
    uv_ref(reinterpret_cast<uv_handle_t*>(wakeup));
  } else if (!live && !owner->pump_scheduled) {
    uv_unref(reinterpret_cast<uv_handle_t*>(wakeup));
  }
  // Update liveness before running JS. Both fatal_exception and callback-scope
  // close can reenter an export and arrange a newly referenced pump/timer.
  report_async_error(env, error);
  flush_futures(owner);
  napi_close_callback_scope(env, callback_scope);
  napi_close_handle_scope(env, handles);
}

static bool initialize_pump(Owner* owner) {
  uv_loop_t* loop = nullptr;
  if (napi_get_uv_event_loop(owner->env, &loop) != napi_ok ||
      uv_async_init(loop, &owner->wakeup, pump) != 0) return false;
  owner->wakeup_initialized = true;
  owner->wakeup.data = owner;
  uv_unref(reinterpret_cast<uv_handle_t*>(&owner->wakeup));
  napi_value resource, name;
  return napi_create_object(owner->env, &resource) == napi_ok &&
      napi_create_reference(owner->env, resource, 1, &owner->async_resource) == napi_ok &&
      napi_create_string_utf8(owner->env, "napi:Dart", NAPI_AUTO_LENGTH, &name) == napi_ok &&
      napi_async_init(owner->env, resource, name, &owner->async_context) == napi_ok;
}

static void finalize(napi_env env, void* data, void*) {
  auto wrapper = static_cast<Wrapper*>(data);
  // The wrap-returned zero-count reference belongs to this finalizer, including
  // after Owner teardown. Deleting it on a cache miss could suppress finalizing.
  if (wrapper->reference) napi_delete_reference(env, wrapper->reference);
  auto owner = wrapper->owner;
  if (owner && !owner->closing) {
    owner->wrappers.erase(wrapper);
    owner->references.erase(wrapper->id);
    if (active_owner) {
      // Even same-isolate GC can happen inside Dart -> FFI -> V8. Do not invoke
      // a Dart release closure until the outer callback reaches a safe edge.
      defer_release(owner, wrapper);
      return;
    } else {
      Scope scope(owner, false);
      if (scope.entered) {
        drain_releases(owner);
        release(owner, wrapper->id);
      } else {
        defer_release(owner, wrapper);
        return;
      }
    }
  }
  delete wrapper;
}

// Table slot 14: napi_status bridge_wrap(napi_env, napi_value, int64_t).
static napi_status bridge_wrap(napi_env env, napi_value self, int64_t id) {
  auto owner = active_owner;
  if (!owner || owner->closing || owner->env != env || id <= 0) {
    fail(env, "Invalid native owner");
    return napi_invalid_arg;
  }
  if (owner->references.count(id)) {
    fail(env, "Native owner lease is already attached");
    return napi_invalid_arg;
  }
  auto wrapper = new (std::nothrow) Wrapper{owner, id};
  if (!wrapper) {
    fail_error(env, "Cannot allocate native owner");
    return napi_generic_failure;
  }
  // Prepare both indexes before transferring token ownership to JS. A successful
  // napi_wrap is followed only by non-throwing commits.
  try {
    owner->wrappers.insert(wrapper);
    owner->references.emplace(id, wrapper);
  } catch (const std::bad_alloc&) {
    owner->wrappers.erase(wrapper);
    owner->references.erase(id);
    delete wrapper;
    fail_error(env, "Cannot index native owner");
    return napi_generic_failure;
  }
  auto status = napi_wrap(env, self, wrapper, finalize, nullptr, &wrapper->reference);
  if (status != napi_ok) {
    owner->wrappers.erase(wrapper);
    owner->references.erase(id);
    delete wrapper;
    fail(env, "Cannot attach native owner");
    return status;
  }
  return napi_ok;
}

// Table slot 15: int64_t bridge_unwrap(napi_env, napi_value).
// Returns 0 for an invalid/foreign receiver; Dart adds the precise call path.
static int64_t bridge_unwrap(napi_env env, napi_value self) {
  auto owner = active_owner;
  void* data = nullptr;
  if (!owner || owner->closing || owner->env != env ||
      napi_unwrap(env, self, &data) != napi_ok ||
      owner->wrappers.count(static_cast<Wrapper*>(data)) == 0) {
    return 0;
  }
  return static_cast<Wrapper*>(data)->id;
}

static napi_status reference_value(napi_env env, int64_t id, napi_value* result) {
  *result = nullptr;
  auto owner = active_owner;
  if (!owner || owner->closing || owner->env != env || id <= 0) {
    fail(env, "Invalid native reference lookup");
    return napi_invalid_arg;
  }
  auto found = owner->references.find(id);
  if (found == owner->references.end()) return napi_ok;
  // A weak reference can clear before its finalizer runs. Keep the old token
  // until finalization; replacement wrappers use distinct lease IDs.
  return napi_get_reference_value(env, found->second->reference, result);
}

static napi_status reference_create(napi_env env, uint32_t class_id,
                                    int64_t id, napi_value* result) {
  *result = nullptr;
  auto owner = active_owner;
  if (!owner || owner->closing || owner->env != env || id <= 0 ||
      owner->adoption) {
    fail(env, "Invalid native reference creation");
    return napi_invalid_arg;
  }
  if (class_id >= owner->constructors.size()) {
    auto shape = owner->reference_shapes.find(class_id);
    if (shape == owner->reference_shapes.end()) {
      fail(env, "Unknown native reference shape");
      return napi_invalid_arg;
    }
    napi_value creator, receiver;
    auto status = napi_get_reference_value(env, shape->second.creator, &creator);
    if (status == napi_ok) status = napi_get_undefined(env, &receiver);
    if (status == napi_ok)
      status = napi_call_function(env, receiver, creator, 0, nullptr, result);
    if (status == napi_ok) status = bridge_wrap(env, *result, id);
    return status;
  }
  napi_value constructor;
  auto status = napi_get_reference_value(env, owner->constructors[class_id], &constructor);
  if (status != napi_ok) return status;
  Adoption adoption{class_id, id};
  owner->adoption = &adoption;
  struct ResetAdoption {
    Owner* owner;
    ~ResetAdoption() { owner->adoption = nullptr; }
  } reset{owner};
  status = napi_new_instance(env, constructor, 0, nullptr, result);
  if (status == napi_ok && !adoption.consumed) {
    fail_error(env, "Native reference constructor did not adopt its lease");
    return napi_generic_failure;
  }
  return status;
}

static napi_status js_method(napi_env env, const char* owner_name,
                             const char* method_name, size_t count,
                             const napi_value* args, napi_value* result) {
  napi_value global, object, method;
  auto status = napi_get_global(env, &global);
  if (status != napi_ok) return status;
  status = napi_get_named_property(env, global, owner_name, &object);
  if (status != napi_ok) return status;
  status = napi_get_named_property(env, object, method_name, &method);
  if (status != napi_ok) return status;
  return napi_call_function(env, object, method, count, args, result);
}

// The raw Node-API predicates/prototype getter bypass Proxy semantics. Use the
// same JS operations as the Wasm boundary, preserving their pending exceptions.
static napi_status js_is_array(napi_env env, napi_value input, bool* result) {
  napi_value value;
  auto status = js_method(env, "Array", "isArray", 1, &input, &value);
  return status == napi_ok ? napi_get_value_bool(env, value, result) : status;
}

static napi_status js_prototype(napi_env env, napi_value input, napi_value* result) {
  return js_method(env, "Object", "getPrototypeOf", 1, &input, result);
}

// Capture the realm's Map operations once. Instance overrides and foreign Map
// prototypes never participate in conversion. These builtin references share
// the Owner's existing environment cleanup; they retain no business objects.
static napi_status capture_maps(Owner* owner) {
  const auto env = owner->env;
  napi_value global, prototype, descriptor, empty, iterator;
  napi_value values[map_intrinsic_count];
  auto status = napi_get_global(env, &global);
  if (status != napi_ok) return status;
  status = napi_get_named_property(env, global, "Map", &values[map_constructor]);
  if (status != napi_ok) return status;
  status = napi_get_named_property(env, values[map_constructor], "prototype", &prototype);
  if (status != napi_ok) return status;
  napi_value size_key;
  status = napi_create_string_utf8(env, "size", NAPI_AUTO_LENGTH, &size_key);
  if (status != napi_ok) return status;
  napi_value descriptor_args[] = {prototype, size_key};
  status = js_method(env, "Object", "getOwnPropertyDescriptor", 2, descriptor_args, &descriptor);
  if (status != napi_ok) return status;
  status = napi_get_named_property(env, descriptor, "get", &values[map_size]);
  if (status != napi_ok) return status;
  status = napi_get_named_property(env, prototype, "entries", &values[map_entries]);
  if (status != napi_ok) return status;
  status = napi_get_named_property(env, prototype, "has", &values[map_has]);
  if (status != napi_ok) return status;
  status = napi_get_named_property(env, prototype, "set", &values[map_set]);
  if (status != napi_ok) return status;
  status = napi_new_instance(env, values[map_constructor], 0, nullptr, &empty);
  if (status != napi_ok) return status;
  status = napi_call_function(env, empty, values[map_entries], 0, nullptr, &iterator);
  if (status != napi_ok) return status;
  status = napi_get_named_property(env, iterator, "next", &values[map_next]);
  if (status != napi_ok) return status;
  for (size_t i = 0; i < map_intrinsic_count; ++i) {
    napi_valuetype type;
    status = napi_typeof(env, values[i], &type);
    if (status != napi_ok) return status;
    if (type != napi_function) {
      fail_error(env, "Cannot capture Map intrinsics");
      return napi_invalid_arg;
    }
    status = napi_create_reference(env, values[i], 1, &owner->maps[i]);
    if (status != napi_ok) return status;
  }
  return napi_ok;
}

static napi_status capture_dictionary(Owner* owner) {
  napi_value global, object, create;
  auto status = napi_get_global(owner->env, &global);
  if (status != napi_ok) return status;
  status = napi_get_named_property(owner->env, global, "Object", &object);
  if (status != napi_ok) return status;
  status = napi_get_named_property(owner->env, object, "create", &create);
  if (status != napi_ok) return status;
  napi_valuetype type;
  status = napi_typeof(owner->env, create, &type);
  if (status != napi_ok) return status;
  if (type != napi_function) {
    fail_error(owner->env, "Cannot capture Dictionary constructor");
    return napi_invalid_arg;
  }
  return napi_create_reference(owner->env, create, 1, &owner->dictionary_create);
}

static napi_status map_function(napi_env env, MapIntrinsic intrinsic, napi_value* result) {
  if (!active_owner || active_owner->env != env || active_owner->closing) {
    fail_error(env, "Map operation requires its active Dart isolate");
    return napi_invalid_arg;
  }
  return napi_get_reference_value(env, active_owner->maps[intrinsic], result);
}

static napi_status map_call(napi_env env, MapIntrinsic intrinsic,
                            napi_value receiver, size_t count,
                            const napi_value* args, napi_value* result) {
  napi_value function;
  const auto status = map_function(env, intrinsic, &function);
  return status == napi_ok ? napi_call_function(env, receiver, function, count, args, result) : status;
}

static napi_status utf16(napi_env env, napi_value value, std::u16string* result) {
  size_t length;
  auto status = napi_get_value_string_utf16(env, value, nullptr, 0, &length);
  if (status != napi_ok) return status;
  result->resize(length + 1);
  status = napi_get_value_string_utf16(env, value, result->data(), result->size(), &length);
  if (status == napi_ok) result->resize(length);
  return status;
}

static napi_status structure_error(napi_env env, const std::u16string& path,
                                   const char16_t* message, bool range = false) {
  const auto text = path + u": " + message;
  napi_value string, error;
  auto status = napi_create_string_utf16(env, text.data(), text.size(), &string);
  if (status != napi_ok) return status;
  status = range ? napi_create_range_error(env, nullptr, string, &error)
                 : napi_create_type_error(env, nullptr, string, &error);
  if (status != napi_ok) return status;
  status = napi_throw(env, error);
  // Throwing successfully sets a pending JS exception; Dart must stop reading
  // this argument rather than treating napi_ok as a converted empty container.
  return status == napi_ok ? napi_pending_exception : status;
}

static napi_status display_key(napi_env env, napi_value key, std::u16string* result) {
  napi_valuetype type;
  auto status = napi_typeof(env, key, &type);
  if (status != napi_ok) return status;
  if (type != napi_string) {
    // String(symbol) is defined; Node-API's ToString coercion throws instead.
    napi_value global, string_function, text;
    status = napi_get_global(env, &global);
    if (status != napi_ok) return status;
    status = napi_get_named_property(env, global, "String", &string_function);
    if (status != napi_ok) return status;
    status = napi_call_function(env, global, string_function, 1, &key, &text);
    if (status != napi_ok) return status;
    key = text;
  }
  return utf16(env, key, result);
}

static napi_status plain_shape(napi_env env, napi_value input, bool array,
                               bool* result) {
  napi_value prototype, global, constructor, expected, null_value;
  auto status = js_prototype(env, input, &prototype);
  if (status != napi_ok) return status;
  status = napi_get_null(env, &null_value);
  if (status != napi_ok) return status;
  status = napi_strict_equals(env, prototype, null_value, result);
  if (status != napi_ok || *result) return status;
  status = napi_get_global(env, &global);
  if (status != napi_ok) return status;
  status = napi_get_named_property(env, global, array ? "Array" : "Object", &constructor);
  if (status != napi_ok) return status;
  status = napi_get_named_property(env, constructor, "prototype", &expected);
  return status == napi_ok ? napi_strict_equals(env, prototype, expected, result) : status;
}

static bool array_index(const std::u16string& key, uint32_t length) {
  if (key.empty() || (key.size() > 1 && key[0] == u'0')) return false;
  uint64_t index = 0;
  for (auto unit : key) {
    if (unit < u'0' || unit > u'9') return false;
    index = index * 10 + (unit - u'0');
    if (index >= length) return false;
  }
  return index < length;
}

static napi_status inspect_shape(
    napi_env env, napi_value input, bool array, const napi_value* fields,
    size_t count, napi_value path_value, uint32_t remaining, uint32_t depth,
    bool cyclic, uint32_t* length) {
  *length = 0;
  try {
    std::u16string path;
    auto status = utf16(env, path_value, &path);
    if (status != napi_ok) return status;
    napi_valuetype type;
    status = napi_typeof(env, input, &type);
    if (status != napi_ok) return status;
    if (!array && type != napi_object)
      return structure_error(env, path, u"expected a record object");
    bool is_array;
    status = js_is_array(env, input, &is_array);
    if (status != napi_ok) return status;
    if (array && !is_array) return structure_error(env, path, u"expected an Array");
    napi_value null_value;
    status = napi_get_null(env, &null_value);
    if (status != napi_ok) return status;
    bool is_null;
    status = napi_strict_equals(env, input, null_value, &is_null);
    if (status != napi_ok) return status;
    if (!array && (is_array || is_null))
      return structure_error(env, path, u"expected a record object");
    // Wasm checks Array type before depth/cycle, but a record's prototype first.
    if (array) {
      if (depth >= 64) return structure_error(env, path, u"structural depth limit (64) exceeded", true);
      if (cyclic) return structure_error(env, path, u"cyclic structural value");
    }
    bool plain;
    status = plain_shape(env, input, array, &plain);
    if (status != napi_ok) return status;
    if (!plain) return structure_error(env, path, array ? u"expected a plain Array" : u"expected a plain record object");
    if (!array) {
      if (depth >= 64) return structure_error(env, path, u"structural depth limit (64) exceeded", true);
      if (cyclic) return structure_error(env, path, u"cyclic structural value");
    }
    if (array) {
      napi_value value;
      status = napi_get_named_property(env, input, "length", &value);
      if (status != napi_ok) return status;
      status = napi_typeof(env, value, &type);
      if (status != napi_ok) return status;
      double size = -1;
      if (type == napi_number) {
        status = napi_get_value_double(env, value, &size);
        if (status != napi_ok) return status;
      }
      if (!std::isfinite(size) || size < 0 || size > UINT32_MAX || std::floor(size) != size)
        return structure_error(env, path + u".length", u"expected an Array length");
      *length = static_cast<uint32_t>(size);
      if (*length > remaining)
        return structure_error(env, path, u"structural work limit (10000) exceeded", true);
    } else {
      *length = static_cast<uint32_t>(count);
    }
    std::set<std::u16string> names;
    for (size_t i = 0; i < count; i++) {
      std::u16string field;
      status = utf16(env, fields[i], &field);
      if (status != napi_ok) return status;
      names.insert(std::move(field));
    }
    napi_value keys;
    status = napi_get_all_property_names(env, input, napi_key_own_only,
        napi_key_all_properties, napi_key_numbers_to_strings, &keys);
    if (status != napi_ok) return status;
    uint32_t properties;
    status = napi_get_array_length(env, keys, &properties);
    if (status != napi_ok) return status;
    for (uint32_t i = 0; i < properties; i++) {
      napi_value key;
      status = napi_get_element(env, keys, i, &key);
      if (status != napi_ok) return status;
      status = napi_typeof(env, key, &type);
      if (status != napi_ok) return status;
      std::u16string name;
      status = display_key(env, key, &name);
      if (status != napi_ok) return status;
      if (array && type == napi_string && name == u"length") continue;
      if (!array && i >= remaining)
        return structure_error(env, path + u"." + name, u"structural work limit (10000) exceeded", true);
      if (type != napi_string ||
          (array ? !array_index(name, *length) : !names.count(name)))
        return structure_error(env, path + u"." + name, array ? u"unknown Array property" : u"unknown record field");
    }
    return napi_ok;
  } catch (const std::bad_alloc&) {
    fail_error(env, "Cannot inspect structural value");
    return napi_generic_failure;
  }
}

static napi_status read_own_value_impl(napi_env env, napi_value input, napi_value key,
                                       napi_value path_value, napi_value* result,
                                       bool optional) {
  *result = nullptr;
  try {
    napi_value args[] = {input, key};
    napi_value descriptor;
    auto status = js_method(env, "Object", "getOwnPropertyDescriptor", 2, args, &descriptor);
    if (status != napi_ok) return status;
    napi_valuetype type;
    status = napi_typeof(env, descriptor, &type);
    if (status != napi_ok) return status;
    if (optional && type == napi_undefined) return napi_ok;
    bool data = false;
    if (type == napi_object) {
      napi_value value_key;
      status = napi_create_string_utf8(env, "value", NAPI_AUTO_LENGTH, &value_key);
      if (status != napi_ok) return status;
      status = napi_has_own_property(env, descriptor, value_key, &data);
      if (status != napi_ok) return status;
    }
    if (!data) {
      std::u16string path;
      status = utf16(env, path_value, &path);
      return status == napi_ok ? structure_error(env, path, u"expected an own data property") : status;
    }
    return napi_get_named_property(env, descriptor, "value", result);
  } catch (const std::bad_alloc&) {
    fail_error(env, "Cannot read structural value");
    return napi_generic_failure;
  }
}

static napi_status read_own_value(napi_env env, napi_value input, napi_value key,
                                  napi_value path_value, napi_value* result) {
  return read_own_value_impl(env, input, key, path_value, result, false);
}

static napi_status read_optional_own_value(napi_env env, napi_value input,
                                           napi_value key, napi_value path_value,
                                           napi_value* result) {
  return read_own_value_impl(env, input, key, path_value, result, true);
}

static napi_status create_container(napi_env env, bool array, uint32_t length,
                                    napi_value* result) {
  return array ? napi_create_array_with_length(env, length, result)
               : napi_create_object(env, result);
}

static napi_status define_own_value(napi_env env, napi_value container,
                                   napi_value key, napi_value value) {
  napi_property_descriptor property = {nullptr, key, nullptr, nullptr, nullptr,
      value, napi_default_jsproperty, nullptr};
  return napi_define_properties(env, container, 1, &property);
}

static napi_status snapshot_map(napi_env env, napi_value input, napi_value path_value,
                                uint32_t remaining, uint32_t depth, bool cyclic,
                                napi_value* pairs, uint32_t* count) {
  try {
    std::u16string path;
    auto status = utf16(env, path_value, &path);
    if (status != napi_ok) return status;
    napi_valuetype type;
    status = napi_typeof(env, input, &type);
    if (status != napi_ok) return status;
    if (type != napi_object) return structure_error(env, path, u"expected a Map");
    napi_value size_value;
    status = map_call(env, map_size, input, 0, nullptr, &size_value);
    if (status == napi_pending_exception) {
      // The captured builtin size getter checks [[MapData]] without executing
      // input properties or Proxy traps. Replace its brand error with a path.
      napi_value exception;
      status = napi_get_and_clear_last_exception(env, &exception);
      return status == napi_ok ? structure_error(env, path, u"expected a Map") : status;
    }
    if (status != napi_ok) return status;
    if (depth >= 64) return structure_error(env, path, u"structural depth limit (64) exceeded", true);
    if (cyclic) return structure_error(env, path, u"cyclic structural value");
    double size;
    status = napi_get_value_double(env, size_value, &size);
    if (status != napi_ok) return status;
    if (!std::isfinite(size) || size < 0 || size != std::floor(size))
      return structure_error(env, path + u".size", u"expected a Map size");
    if (size > remaining / 2)
      return structure_error(env, path, u"structural work limit (10000) exceeded", true);
    const auto length = static_cast<uint32_t>(size);
    napi_value result, iterator;
    status = napi_create_array_with_length(env, length * 2, &result);
    if (status != napi_ok) return status;
    status = map_call(env, map_entries, input, 0, nullptr, &iterator);
    if (status != napi_ok) return status;
    for (uint32_t i = 0; i <= length; ++i) {
      napi_value step, done_value;
      bool done;
      status = map_call(env, map_next, iterator, 0, nullptr, &step);
      if (status != napi_ok) return status;
      status = napi_get_named_property(env, step, "done", &done_value);
      if (status != napi_ok) return status;
      status = napi_get_value_bool(env, done_value, &done);
      if (status != napi_ok) return status;
      if (done != (i == length))
        return structure_error(env, path, u"Map length changed during iteration");
      if (done) break;
      napi_value pair;
      status = napi_get_named_property(env, step, "value", &pair);
      if (status != napi_ok) return status;
      for (uint32_t side = 0; side < 2; ++side) {
        napi_value value, key;
        status = napi_get_element(env, pair, side, &value);
        if (status != napi_ok) return status;
        char index[32];
        std::snprintf(index, sizeof(index), "%u", i * 2 + side);
        status = napi_create_string_utf8(env, index, NAPI_AUTO_LENGTH, &key);
        if (status != napi_ok) return status;
        status = define_own_value(env, result, key, value);
        if (status != napi_ok) return status;
      }
    }
    *pairs = result;
    *count = length;
    return napi_ok;
  } catch (const std::bad_alloc&) {
    fail_error(env, "Cannot snapshot Map entries");
    return napi_generic_failure;
  }
}

static napi_status create_map(napi_env env, napi_value* result) {
  napi_value constructor;
  const auto status = map_function(env, map_constructor, &constructor);
  return status == napi_ok ? napi_new_instance(env, constructor, 0, nullptr, result) : status;
}

static napi_status checked_insert_map(napi_env env, napi_value map, napi_value key,
                                      napi_value value, napi_value path_value) {
  napi_value has_value, ignored;
  auto status = map_call(env, map_has, map, 1, &key, &has_value);
  if (status != napi_ok) return status;
  bool has;
  status = napi_get_value_bool(env, has_value, &has);
  if (status != napi_ok) return status;
  if (has) {
    try {
      std::u16string path;
      status = utf16(env, path_value, &path);
      return status == napi_ok ? structure_error(env, path, u"duplicate converted Map key") : status;
    } catch (const std::bad_alloc&) {
      fail_error(env, "Cannot report Map key collision");
      return napi_generic_failure;
    }
  }
  napi_value args[] = {key, value};
  return map_call(env, map_set, map, 2, args, &ignored);
}

static napi_status dictionary_keys(napi_env env, napi_value input,
                                   napi_value path_value, uint32_t remaining,
                                   uint32_t depth, bool cyclic,
                                   napi_value* keys, uint32_t* count) {
  try {
    std::u16string path;
    auto status = utf16(env, path_value, &path);
    if (status != napi_ok) return status;
    napi_valuetype type;
    status = napi_typeof(env, input, &type);
    if (status != napi_ok) return status;
    if (type != napi_object)
      return structure_error(env, path, u"expected a Dictionary object");
    bool array;
    status = js_is_array(env, input, &array);
    if (status != napi_ok) return status;
    if (array) return structure_error(env, path, u"expected a Dictionary object");
    bool plain;
    status = plain_shape(env, input, false, &plain);
    if (status != napi_ok) return status;
    if (!plain) return structure_error(env, path, u"expected a plain Dictionary object");
    if (depth >= 64)
      return structure_error(env, path, u"structural depth limit (64) exceeded", true);
    if (cyclic) return structure_error(env, path, u"cyclic structural value");
    napi_value result;
    status = napi_get_all_property_names(env, input, napi_key_own_only,
        napi_key_all_properties, napi_key_numbers_to_strings, &result);
    if (status != napi_ok) return status;
    uint32_t length;
    status = napi_get_array_length(env, result, &length);
    if (status != napi_ok) return status;
    for (uint32_t i = 0; i < length; ++i) {
      napi_value key;
      status = napi_get_element(env, result, i, &key);
      if (status != napi_ok) return status;
      status = napi_typeof(env, key, &type);
      if (status != napi_ok) return status;
      if (type != napi_string)
        return structure_error(env, path, u"expected string Dictionary keys");
    }
    if (length > remaining)
      return structure_error(env, path, u"structural work limit (10000) exceeded", true);
    *keys = result;
    *count = length;
    return napi_ok;
  } catch (const std::bad_alloc&) {
    fail_error(env, "Cannot inspect Dictionary keys");
    return napi_generic_failure;
  }
}

static napi_status create_dictionary(napi_env env, napi_value* result) {
  if (!active_owner || active_owner->env != env || active_owner->closing) {
    fail_error(env, "Dictionary operation requires its active Dart isolate");
    return napi_invalid_arg;
  }
  napi_value create, global, null_value;
  auto status = napi_get_reference_value(env, active_owner->dictionary_create, &create);
  if (status != napi_ok) return status;
  status = napi_get_global(env, &global);
  if (status != napi_ok) return status;
  status = napi_get_null(env, &null_value);
  return status == napi_ok ? napi_call_function(env, global, create, 1, &null_value, result) : status;
}

static napi_status read_options(
    napi_env env, napi_value input, bool supplied, const char* const* names,
    size_t count, napi_value* values, uint8_t* present, const char* context) {
  for (size_t i = 0; i < count; i++) { values[i] = nullptr; present[i] = 0; }
  if (!supplied) return napi_ok;
  const auto reject = [&](const std::string& message) {
    fail(env, (std::string(context) + message).c_str());
    return napi_invalid_arg;
  };
#define OPTIONS_NAPI(call) do { \
    napi_status status = (call); \
    if (status != napi_ok) { reject(": cannot inspect named arguments"); return status; } \
  } while (false)
  napi_valuetype type;
  OPTIONS_NAPI(napi_typeof(env, input, &type));
  if (type == napi_undefined) return napi_ok;
  bool array = false;
  OPTIONS_NAPI(js_is_array(env, input, &array));
  napi_value null_value;
  bool is_null = false;
  OPTIONS_NAPI(napi_get_null(env, &null_value));
  OPTIONS_NAPI(napi_strict_equals(env, input, null_value, &is_null));
  if (type != napi_object || array || is_null) return reject(": expected an options object");
  napi_value global, object, prototype, plain_prototype;
  OPTIONS_NAPI(napi_get_global(env, &global));
  OPTIONS_NAPI(napi_get_named_property(env, global, "Object", &object));
  OPTIONS_NAPI(napi_get_named_property(env, object, "prototype", &plain_prototype));
  OPTIONS_NAPI(js_prototype(env, input, &prototype));
  bool plain = false;
  OPTIONS_NAPI(napi_strict_equals(env, prototype, plain_prototype, &plain));
  OPTIONS_NAPI(napi_strict_equals(env, prototype, null_value, &is_null));
  if (!plain && !is_null) return reject(": expected an options object");
  napi_value describe, properties, keys;
  OPTIONS_NAPI(napi_get_named_property(env, object, "getOwnPropertyDescriptors", &describe));
  OPTIONS_NAPI(napi_call_function(env, object, describe, 1, &input, &properties));
  OPTIONS_NAPI(napi_get_all_property_names(env, properties, napi_key_own_only,
      napi_key_all_properties, napi_key_numbers_to_strings, &keys));
  uint32_t length = 0;
  OPTIONS_NAPI(napi_get_array_length(env, keys, &length));
  napi_value value_key;
  OPTIONS_NAPI(napi_create_string_utf8(env, "value", NAPI_AUTO_LENGTH, &value_key));
  for (uint32_t i = 0; i < length; i++) {
    napi_value key;
    OPTIONS_NAPI(napi_get_element(env, keys, i, &key));
    OPTIONS_NAPI(napi_typeof(env, key, &type));
    if (type != napi_string) return reject(": unknown named argument (symbol)");
    size_t bytes = 0;
    OPTIONS_NAPI(napi_get_value_string_utf8(env, key, nullptr, 0, &bytes));
    std::vector<char> chars(bytes + 1);
    OPTIONS_NAPI(napi_get_value_string_utf8(env, key, chars.data(), chars.size(), &bytes));
    const std::string name(chars.data(), bytes);
    size_t index = 0;
    while (index < count && name != names[index]) index++;
    if (index == count) return reject(": unknown named argument " + name);
    napi_value descriptor;
    OPTIONS_NAPI(napi_get_property(env, properties, key, &descriptor));
    bool data = false;
    OPTIONS_NAPI(napi_has_own_property(env, descriptor, value_key, &data));
    if (!data) return reject("." + name + ": expected an own data property");
    OPTIONS_NAPI(napi_get_property(env, descriptor, value_key, &values[index]));
    present[index] = 1;
  }
#undef OPTIONS_NAPI
  return napi_ok;
}

static napi_status is_constructor_target(napi_env env, napi_callback_info info,
                                         uint32_t class_id, bool* result) {
  *result = false;
  auto owner = active_owner;
  if (!owner || owner->closing || owner->env != env ||
      class_id >= owner->constructors.size()) {
    fail(env, "Invalid native constructor target");
    return napi_invalid_arg;
  }
  napi_value target, original;
  auto status = napi_get_new_target(env, info, &target);
  if (status != napi_ok || !target) return status;
  status = napi_get_reference_value(env, owner->constructors[class_id], &original);
  return status == napi_ok ? napi_strict_equals(env, target, original, result) : status;
}

static napi_status register_reference_shape(napi_env env, uint32_t shape_id,
    const uint32_t* views, size_t count, napi_value context) {
  auto owner = active_owner;
  if (!owner || owner->closing || owner->env != env ||
      !owner->reference_resolver || owner->resolving_reference_shape ||
      !views || count < 2 ||
      count > owner->constructors.size() ||
      shape_id < owner->constructors.size()) {
    fail(env, "Invalid native reference shape");
    return napi_invalid_arg;
  }
  for (size_t i = 0; i < count; ++i) {
    if (views[i] >= owner->constructors.size() || (i && views[i - 1] >= views[i])) {
      fail(env, "Invalid native reference views");
      return napi_invalid_arg;
    }
  }
  auto found = owner->reference_shapes.find(shape_id);
  if (found != owner->reference_shapes.end()) {
    if (found->second.views.size() == count &&
        std::equal(found->second.views.begin(), found->second.views.end(), views))
      return napi_ok;
    fail(env, "Native reference shape ID is already registered");
    return napi_invalid_arg;
  }
  if (shape_id != owner->constructors.size() + owner->reference_shapes.size()) {
    fail(env, "Invalid native reference shape ID");
    return napi_invalid_arg;
  }
  owner->resolving_reference_shape = true;
  struct ResetResolution {
    Owner* owner;
    ~ResetResolution() { owner->resolving_reference_shape = false; }
  } reset{owner};
  napi_ref retained = nullptr;
  try {
    std::vector<uint32_t> selected(views, views + count);
    napi_value resolver = nullptr, receiver = nullptr, ids = nullptr, creator = nullptr;
    auto status = napi_get_reference_value(env, owner->reference_resolver, &resolver);
    if (status == napi_ok) status = napi_get_undefined(env, &receiver);
    if (status == napi_ok) status = napi_create_array_with_length(env, count, &ids);
    for (size_t i = 0; status == napi_ok && i < count; ++i) {
      napi_value key, value;
      const auto index = std::to_string(i);
      status = napi_create_string_utf8(env, index.data(), index.size(), &key);
      if (status == napi_ok) status = napi_create_uint32(env, views[i], &value);
      if (status == napi_ok) status = define_own_value(env, ids, key, value);
    }
    napi_value args[] = {ids, context};
    if (status == napi_ok)
      status = napi_call_function(env, receiver, resolver, 2, args, &creator);
    if (status != napi_ok) return status;
    napi_valuetype type;
    status = napi_typeof(env, creator, &type);
    if (status != napi_ok) return status;
    if (type != napi_function) {
      fail(env, "Native reference resolver must return a creator");
      return napi_invalid_arg;
    }
    status = napi_create_reference(env, creator, 1, &retained);
    if (status != napi_ok) return status;
    owner->reference_shapes.emplace(shape_id,
        ReferenceShape{std::move(selected), retained});
    return napi_ok;
  } catch (const std::bad_alloc&) {
    if (retained) napi_delete_reference(env, retained);
    fail_error(env, "Cannot retain native reference shape");
    return napi_generic_failure;
  }
}

static napi_status own_host_value(napi_env env, napi_value value, int64_t* slot) {
  auto owner = active_owner;
  if (!owner || owner->env != env || owner->closing || !value || !slot ||
      owner->next_host_value == std::numeric_limits<int64_t>::max())
    return napi_invalid_arg;
  // Node-API versions below 10 cannot reference every primitive directly.
  // An inaccessible own data property also avoids inherited setters and traps.
  napi_value holder;
  auto status = napi_create_object(env, &holder);
  napi_property_descriptor property = {"value", nullptr, nullptr, nullptr,
      nullptr, value, napi_default, nullptr};
  if (status == napi_ok) status = napi_define_properties(env, holder, 1, &property);
  napi_ref reference = nullptr;
  if (status == napi_ok) status = napi_create_reference(env, holder, 1, &reference);
  if (status != napi_ok) return status;
  try {
    owner->host_values.emplace(owner->next_host_value, reference);
  } catch (const std::bad_alloc&) {
    napi_delete_reference(env, reference);
    return napi_generic_failure;
  }
  *slot = owner->next_host_value++;
  return napi_ok;
}

static napi_status host_value(napi_env env, int64_t slot, napi_value* result) {
  auto owner = active_owner;
  if (!owner || owner->env != env || owner->closing || !result)
    return napi_invalid_arg;
  auto found = owner->host_values.find(slot);
  if (found == owner->host_values.end()) return napi_invalid_arg;
  napi_value holder;
  auto status = napi_get_reference_value(env, found->second, &holder);
  return status == napi_ok
      ? napi_get_named_property(env, holder, "value", result) : status;
}

static napi_status release_host_value(napi_env env, int64_t slot) {
  auto owner = active_owner;
  if (!owner || owner->env != env || owner->closing) return napi_invalid_arg;
  auto found = owner->host_values.find(slot);
  if (found == owner->host_values.end()) return napi_ok;
  auto status = napi_delete_reference(env, found->second);
  if (status == napi_ok) owner->host_values.erase(found);
  return status;
}

static void* api_table[] = {
    reinterpret_cast<void*>(&napi_get_cb_info),
    reinterpret_cast<void*>(&napi_typeof),
    reinterpret_cast<void*>(&napi_get_value_double),
    reinterpret_cast<void*>(&napi_create_double),
    reinterpret_cast<void*>(&napi_throw_type_error),
    reinterpret_cast<void*>(&napi_throw_range_error),
    reinterpret_cast<void*>(&napi_get_undefined),
    reinterpret_cast<void*>(&napi_get_null),
    reinterpret_cast<void*>(&napi_get_value_string_utf16),
    reinterpret_cast<void*>(&napi_create_string_utf16),
    reinterpret_cast<void*>(&napi_get_new_target),
    reinterpret_cast<void*>(&napi_wrap),
    reinterpret_cast<void*>(&napi_unwrap),
    reinterpret_cast<void*>(&napi_create_int64),
    reinterpret_cast<void*>(&bridge_wrap),
    reinterpret_cast<void*>(&bridge_unwrap),
    reinterpret_cast<void*>(&napi_get_value_bool),
    reinterpret_cast<void*>(&napi_get_boolean),
    reinterpret_cast<void*>(&napi_get_value_bigint_int64),
    reinterpret_cast<void*>(&napi_create_bigint_int64),
    reinterpret_cast<void*>(&napi_get_value_bigint_words),
    reinterpret_cast<void*>(&napi_create_bigint_words),
    reinterpret_cast<void*>(&napi_create_error),
    reinterpret_cast<void*>(&napi_create_type_error),
    reinterpret_cast<void*>(&napi_create_range_error),
    reinterpret_cast<void*>(&napi_throw),
    reinterpret_cast<void*>(&napi_is_exception_pending),
    reinterpret_cast<void*>(&read_options),
    reinterpret_cast<void*>(&reference_value),
    reinterpret_cast<void*>(&reference_create),
    reinterpret_cast<void*>(&inspect_shape),
    reinterpret_cast<void*>(&read_own_value),
    reinterpret_cast<void*>(&napi_strict_equals),
    reinterpret_cast<void*>(&create_container),
    reinterpret_cast<void*>(&define_own_value),
    reinterpret_cast<void*>(&snapshot_map),
    reinterpret_cast<void*>(&create_map),
    reinterpret_cast<void*>(&checked_insert_map),
    reinterpret_cast<void*>(&dictionary_keys),
    reinterpret_cast<void*>(&create_dictionary),
    reinterpret_cast<void*>(&read_optional_own_value),
    reinterpret_cast<void*>(&is_constructor_target),
    reinterpret_cast<void*>(&register_reference_shape),
    reinterpret_cast<void*>(&queue_promise_settlement),
    reinterpret_cast<void*>(&bind_cleanup_promise),
    reinterpret_cast<void*>(&observe_future_settlement),
    reinterpret_cast<void*>(&own_host_value),
    reinterpret_cast<void*>(&host_value),
    reinterpret_cast<void*>(&release_host_value),
};
static_assert(sizeof(api_table) / sizeof(*api_table) == bridge_api_count);

static napi_value invoke(napi_env env, napi_callback_info info, Callback* callback) {
  if (!callback) return fail_error(env, "Missing Dart callback");
  auto owner = callback->owner;
  if (owner->closing) return fail(env, "Dart isolate is closed");
  if (callback->returns_future) {
    napi_value target;
    if (napi_get_new_target(env, info, &target) != napi_ok) return nullptr;
    if (target) return fail(env, "Future binding is not a constructor");
  }
  int64_t token = 0;
  napi_value promise = nullptr;
  // Creating a Promise can run async_hooks. Do it before entering this Dart call
  // and before receiver/argument validation, including for non-async producers.
  if (callback->returns_future && create_future(owner, &token, &promise) != napi_ok)
    return nullptr;
  if (active_owner && active_owner != owner) {
    fail(env, "Cannot enter a different Dart isolate reentrantly");
    if (!promise) return nullptr;
    return queue_future(owner, token, nullptr, true) == napi_ok ? promise : nullptr;
  }
  const bool outer = active_owner == nullptr;
  int64_t address = 0;
  {
    Scope scope(owner);
    if (scope.entered) {
      if (outer) drain_releases(owner);
      Dart_Handle args[3] = {
          Dart_NewInteger(reinterpret_cast<intptr_t>(env)),
          Dart_NewInteger(reinterpret_cast<intptr_t>(info))};
      if (callback->returns_future) args[2] = Dart_NewInteger(token);
      auto result = Dart_InvokeClosure(
          Dart_HandleFromPersistent(callback->closure), callback->returns_future ? 3 : 2, args);
      if (outer) drain_releases(owner);
      if (Dart_IsError(result)) fail_error(env, Dart_GetError(result));
      else {
        auto error = Dart_IntegerToInt64(result, &address);
        if (Dart_IsError(error)) fail_error(env, Dart_GetError(error));
      }
    }
  }
  if (promise) {
    bool pending = false;
    napi_is_exception_pending(env, &pending);
    if (pending && queue_future(owner, token, nullptr, true) != napi_ok) return nullptr;
    return address ? reinterpret_cast<napi_value>(static_cast<intptr_t>(address)) : promise;
  }
  if (!address) {
    bool pending = false;
    napi_is_exception_pending(env, &pending);
    if (!pending) return fail_error(env, "Dart callback returned no JS value");
  }
  return reinterpret_cast<napi_value>(address);
}

static napi_value dispatch(napi_env env, napi_callback_info info) {
  void* data = nullptr;
  if (napi_get_cb_info(env, info, nullptr, nullptr, nullptr, &data) != napi_ok)
    return fail_error(env, "Missing Dart callback");
  auto callback = static_cast<Callback*>(data);
  if (!callback) return fail_error(env, "Missing Dart callback");
  auto owner = callback->owner;
  if (auto adoption = owner->adoption) {
    napi_value self, target;
    if (active_owner != owner || owner->env != env || owner->closing ||
        adoption->consumed || callback->class_id != adoption->class_id ||
        napi_get_cb_info(env, info, nullptr, nullptr, &self, nullptr) != napi_ok ||
        napi_get_new_target(env, info, &target) != napi_ok || !target)
      return fail(env, "Invalid internal native reference adoption");
    adoption->consumed = true;
    // This captured native constructor is entered synchronously by slot 29.
    // Bypass Dart business construction while preserving V8's instance brand.
    return bridge_wrap(env, self, adoption->id) == napi_ok ? self : nullptr;
  }
  return invoke(env, info, callback);
}
static napi_value dispatch_get(napi_env env, napi_callback_info info) {
  void* data = nullptr;
  if (napi_get_cb_info(env, info, nullptr, nullptr, nullptr, &data) != napi_ok || !data)
    return fail_error(env, "Missing Dart getter");
  return invoke(env, info, static_cast<Property*>(data)->getter);
}
static napi_value dispatch_set(napi_env env, napi_callback_info info) {
  void* data = nullptr;
  if (napi_get_cb_info(env, info, nullptr, nullptr, nullptr, &data) != napi_ok || !data)
    return fail_error(env, "Missing Dart setter");
  return invoke(env, info, static_cast<Property*>(data)->setter);
}

static void destroy(Owner* owner) {
  owner->closing = true;
  // Core Finalizer callbacks are optional and do not run at isolate shutdown.
  // This owner-thread cleanup releases all remaining host roots without JS.
  for (const auto& value : owner->host_values)
    napi_delete_reference(owner->env, value.second);
  owner->host_values.clear();
  if (owner->future_release) owner->future_release->owner = nullptr;
  for (const auto& cached : owner->cleanup_promises) cached.second->owner = nullptr;
  owner->cleanup_promises.clear();
  for (auto wrapper : owner->wrappers) wrapper->owner = nullptr;
  owner->wrappers.clear();
  owner->references.clear();
  while (auto pending = owner->pending_releases) {
    owner->pending_releases = pending->next_release;
    delete pending;
  }
  for (auto constructor : owner->constructors) {
    if (constructor) napi_delete_reference(owner->env, constructor);
  }
  for (const auto& shape : owner->reference_shapes)
    napi_delete_reference(owner->env, shape.second.creator);
  if (owner->reference_resolver)
    napi_delete_reference(owner->env, owner->reference_resolver);
  for (auto function : owner->maps) {
    if (function) napi_delete_reference(owner->env, function);
  }
  if (owner->dictionary_create)
    napi_delete_reference(owner->env, owner->dictionary_create);
  for (const auto& future : owner->futures)
    napi_delete_reference(owner->env, future.second.capability);
  owner->futures.clear();
  owner->settlements.clear();
  owner->future_releases.clear();
  if (owner->promise_factory)
    napi_delete_reference(owner->env, owner->promise_factory);
  if (owner->promise_observer)
    napi_delete_reference(owner->env, owner->promise_observer);
  if (owner->release_callback)
    napi_delete_reference(owner->env, owner->release_callback);
  if (owner->isolate) {
    {
      Scope scope(owner, false);
      if (!scope.entered) {
        std::fprintf(stderr, "Cannot enter Dart isolate for cleanup\n");
        std::abort();
      }
      for (auto callback : owner->callbacks) {
        Dart_DeletePersistentHandle(callback->closure);
        delete callback;
      }
      for (auto property : owner->properties) delete property;
      if (owner->release_owner) Dart_DeletePersistentHandle(owner->release_owner);
      if (owner->release_future) Dart_DeletePersistentHandle(owner->release_future);
    }
    char* error = nullptr;
    if (!NapiDart_ShutdownIsolate(&owner->isolate, &error)) {
      std::fprintf(stderr, "NapiDart_ShutdownIsolate failed: %s\n", error ? error : "unknown error");
      NapiDart_FreeError(error);
      std::abort();
    }
  }
  if (owner->async_context)
    napi_async_destroy(owner->env, owner->async_context);
  if (owner->async_resource)
    napi_delete_reference(owner->env, owner->async_resource);
  if (owner->wakeup_initialized) {
    // The runtime has synchronously stopped all notifications. Queued libuv
    // wakeups still borrow this Owner, so only the close callback may delete it.
    uv_close(reinterpret_cast<uv_handle_t*>(&owner->wakeup), [](uv_handle_t* handle) {
      auto owner = static_cast<Owner*>(handle->data);
      auto hook = owner->cleanup_hook;
      delete owner;
      // Failed loads never registered a hook and need no live napi_env here.
      if (hook) napi_remove_async_cleanup_hook(hook);
    });
  } else {
    delete owner;
  }
}
static void cleanup(napi_async_cleanup_hook_handle, void* data) {
  destroy(static_cast<Owner*>(data));
}

static bool dart_ok(napi_env env, Dart_Handle handle) {
  if (!Dart_IsError(handle)) return true;
  fail_error(env, Dart_GetError(handle));
  return false;
}
static bool length(napi_env env, Dart_Handle list, intptr_t* out) {
  return dart_ok(env, Dart_ListLength(list, out));
}
static bool string(napi_env env, Dart_Handle value, std::string* out) {
  const char* chars = nullptr;
  if (!dart_ok(env, Dart_StringToCString(value, &chars))) return false;
  *out = chars;
  return true;
}
static bool arity(napi_env env, Dart_Handle value, int64_t* out) {
  if (!dart_ok(env, Dart_IntegerToInt64(value, out))) return false;
  if (*out < 0 || *out > 9007199254740991LL) {
    fail_error(env, "Invalid function arity metadata");
    return false;
  }
  return true;
}
static bool define_arity(napi_env env, napi_value function, int64_t arity) {
  napi_value value;
  if (napi_create_int64(env, arity, &value) != napi_ok) return false;
  napi_property_descriptor descriptor = {"length", nullptr, nullptr, nullptr,
      nullptr, value, napi_configurable, nullptr};
  return napi_define_properties(env, function, 1, &descriptor) == napi_ok;
}
static bool define_accessor_arities(napi_env env, napi_value receiver,
                                    const std::string& name, Property* callbacks) {
  napi_value global, object, describe, key, descriptor;
  if (napi_get_global(env, &global) != napi_ok ||
      napi_get_named_property(env, global, "Object", &object) != napi_ok ||
      napi_get_named_property(env, object, "getOwnPropertyDescriptor", &describe) != napi_ok ||
      napi_create_string_utf8(env, name.c_str(), name.size(), &key) != napi_ok)
    return false;
  napi_value args[] = {receiver, key};
  // Read the generated own descriptor, never receiver[name]. Accessor bodies
  // must not run while assigning their JavaScript function metadata.
  if (napi_call_function(env, object, describe, 2, args, &descriptor) != napi_ok)
    return false;
  napi_value function;
  if (callbacks->getter &&
      (napi_get_named_property(env, descriptor, "get", &function) != napi_ok ||
       !define_arity(env, function, callbacks->getter_arity))) return false;
  if (callbacks->setter &&
      (napi_get_named_property(env, descriptor, "set", &function) != napi_ok ||
       !define_arity(env, function, callbacks->setter_arity))) return false;
  return true;
}
static Callback* cache(napi_env env, Owner* owner, Dart_Handle closure) {
  if (!Dart_IsClosure(closure)) {
    fail(env, "Binding callback is not a Dart closure");
    return nullptr;
  }
  auto callback = new Callback{owner, Dart_NewPersistentHandle(closure)};
  owner->callbacks.push_back(callback);
  return callback;
}

static bool future_metadata(Owner* owner, Callback* callback, Dart_Handle entry, intptr_t fields) {
  if (fields == 4) return true;
  auto flag = Dart_ListGetAt(entry, 4);
  if (!dart_ok(owner->env, Dart_BooleanValue(flag, &callback->returns_future))) return false;
  if (callback->returns_future && !owner->promise_factory) {
    fail_error(owner->env, "Future bindings require a private Promise factory");
    return false;
  }
  return true;
}

static bool register_bindings(Owner* owner, napi_value exports) {
  auto env = owner->env;
  Scope scope(owner);
  if (!scope.entered) return false;
  auto root = Dart_RootLibrary();
  auto release_closure = Dart_GetField(
      root, Dart_NewStringFromCString("releaseOwner"));
  if (!dart_ok(env, release_closure)) return false;
  if (!Dart_IsClosure(release_closure)) {
    fail(env, "releaseOwner must be a Dart function");
    return false;
  }
  owner->release_owner = Dart_NewPersistentHandle(release_closure);
  if (owner->promise_factory) {
    auto closure = Dart_GetField(root, Dart_NewStringFromCString("releaseFuture"));
    if (!dart_ok(env, closure)) return false;
    if (!Dart_IsClosure(closure)) {
      fail(env, "releaseFuture must be a Dart function");
      return false;
    }
    owner->release_future = Dart_NewPersistentHandle(closure);
  }
  Dart_Handle args[] = {
      Dart_NewInteger(reinterpret_cast<intptr_t>(api_table)),
      Dart_NewInteger(bridge_api_count)};
  auto bindings = Dart_Invoke(root,
      Dart_NewStringFromCString("napiBindings"), 2, args);
  intptr_t count;
  if (!dart_ok(env, bindings) || !length(env, bindings, &count)) return false;
  for (intptr_t i = 0; i < count; ++i) {
    auto entry = Dart_ListGetAt(bindings, i);
    intptr_t fields;
    std::string kind, name;
    if (!length(env, entry, &fields) || fields < 3 ||
        !string(env, Dart_ListGetAt(entry, 0), &kind) ||
        !string(env, Dart_ListGetAt(entry, 1), &name)) {
      fail(env, "Invalid binding metadata");
      return false;
    }
    auto callback = cache(env, owner, Dart_ListGetAt(entry, 2));
    if (!callback) return false;
    napi_value value;
    int64_t function_arity;
    if (kind == "function" && (fields == 4 || fields == 5)) {
      if (!future_metadata(owner, callback, entry, fields)) return false;
      if (!arity(env, Dart_ListGetAt(entry, 3), &function_arity)) return false;
      if (napi_create_function(env, name.c_str(), name.size(), dispatch,
                              callback, &value) != napi_ok) return false;
    } else if (kind == "class" && fields == 5) {
      callback->class_id = static_cast<int64_t>(owner->constructors.size());
      if (!arity(env, Dart_ListGetAt(entry, 4), &function_arity)) return false;
      auto declarations = Dart_ListGetAt(entry, 3);
      intptr_t member_count;
      if (!length(env, declarations, &member_count)) return false;
      struct Member {
        std::string name;
        bool is_static;
        Callback* method = nullptr;
        Property* accessors = nullptr;
        int64_t arity = 0;
      };
      std::vector<Member> members;
      members.reserve(static_cast<size_t>(member_count));
      std::map<std::pair<bool, std::string>, size_t> indices;
      for (intptr_t j = 0; j < member_count; ++j) {
        auto declaration = Dart_ListGetAt(declarations, j);
        intptr_t parts;
        std::string member_kind, member_name;
        int64_t member_arity;
        if (!length(env, declaration, &parts) || (parts != 4 && parts != 5) ||
            !string(env, Dart_ListGetAt(declaration, 0), &member_kind) ||
            !string(env, Dart_ListGetAt(declaration, 1), &member_name) ||
            !arity(env, Dart_ListGetAt(declaration, 3), &member_arity)) {
          fail_error(env, "Invalid class member metadata");
          return false;
        }
        const bool method = member_kind == "method" || member_kind == "staticMethod";
        const bool getter = member_kind == "getter" || member_kind == "staticGetter";
        const bool setter = member_kind == "setter" || member_kind == "staticSetter";
        const bool is_static = member_kind == "staticMethod" ||
            member_kind == "staticGetter" || member_kind == "staticSetter";
        if (!method && !getter && !setter) {
          fail_error(env, "Unsupported class member metadata");
          return false;
        }
        auto member_callback = cache(env, owner, Dart_ListGetAt(declaration, 2));
        if (!member_callback || !future_metadata(owner, member_callback, declaration, parts)) return false;
        auto key = std::make_pair(is_static, member_name);
        auto found = indices.find(key);
        if (found == indices.end()) {
          indices.emplace(key, members.size());
          members.push_back({member_name, is_static});
          found = indices.find(key);
        }
        auto& member = members[found->second];
        if (method) {
          if (member.method || member.accessors) {
            fail_error(env, "Duplicate class member metadata");
            return false;
          }
          member.method = member_callback;
          member.arity = member_arity;
        } else {
          if (member.method) {
            fail_error(env, "Conflicting class member metadata");
            return false;
          }
          if (!member.accessors) {
            member.accessors = new Property();
            owner->properties.push_back(member.accessors);
          }
          Callback*& selected = getter ? member.accessors->getter : member.accessors->setter;
          if (selected) {
            fail_error(env, "Duplicate class accessor metadata");
            return false;
          }
          selected = member_callback;
          if (getter) member.accessors->getter_arity = member_arity;
          else member.accessors->setter_arity = member_arity;
        }
      }
      std::vector<napi_property_descriptor> instance_properties, static_properties;
      instance_properties.reserve(members.size());
      static_properties.reserve(members.size());
      for (auto& member : members) {
        auto attributes = static_cast<napi_property_attributes>(
            member.method ? napi_default_method : napi_configurable);
        auto& properties = member.is_static ? static_properties : instance_properties;
        properties.push_back({member.name.c_str(), nullptr,
            member.method ? dispatch : nullptr,
            member.accessors && member.accessors->getter ? dispatch_get : nullptr,
            member.accessors && member.accessors->setter ? dispatch_set : nullptr,
            nullptr, attributes,
            member.method ? static_cast<void*>(member.method) : member.accessors});
      }
      if (napi_define_class(env, name.c_str(), name.size(), dispatch, callback,
                           0, nullptr, &value) !=
          napi_ok) return false;
      try {
        owner->constructors.push_back(nullptr);
      } catch (const std::bad_alloc&) {
        fail_error(env, "Cannot retain native constructor");
        return false;
      }
      if (napi_create_reference(env, value, 1, &owner->constructors.back()) != napi_ok)
        return false;
      napi_value prototype = nullptr;
      if (!instance_properties.empty() &&
          (napi_get_named_property(env, value, "prototype", &prototype) != napi_ok ||
           napi_define_properties(env, prototype, instance_properties.size(),
                                  instance_properties.data()) != napi_ok)) return false;
      if (!static_properties.empty() &&
          napi_define_properties(env, value, static_properties.size(),
                                 static_properties.data()) != napi_ok) return false;
      for (const auto& member : members) {
        if (!member.is_static && !prototype &&
            napi_get_named_property(env, value, "prototype", &prototype) != napi_ok)
          return false;
        napi_value receiver = member.is_static ? value : prototype;
        if (member.accessors) {
          if (!define_accessor_arities(env, receiver, member.name, member.accessors))
            return false;
          continue;
        }
        napi_value method;
        if (napi_get_named_property(env, receiver,
                                    member.name.c_str(), &method) != napi_ok ||
            !define_arity(env, method, member.arity)) return false;
      }
    } else {
      fail(env, "Unsupported binding metadata");
      return false;
    }
    if (!define_arity(env, value, function_arity)) return false;
    // Define an own property: Set could execute an inherited JS setter while
    // this Dart scope is active and leak a callback from a failed load.
    napi_property_descriptor property = {name.c_str(), nullptr, nullptr,
        nullptr, nullptr, value, napi_default_jsproperty, nullptr};
    if (napi_define_properties(env, exports, 1, &property) != napi_ok)
      return false;
  }
  return true;
}

static void initialize_runtime() {
  // This identity belongs to the maintainer-built runtime/bridge pair. It is
  // independent of consumers and is checked before pinning or VM initialization.
  Dl_info location = {};
  if (!dladdr(reinterpret_cast<void*>(&NapiDart_RuntimeIdentity), &location) || !location.dli_fname) {
    initialize_error = "Cannot locate identity-qualified Dart runtime";
    return;
  }
  const char* actual = NapiDart_RuntimeIdentity();
  const bool matches = actual && std::strcmp(actual, kExpectedRuntimeId) == 0;
  const bool trace = std::getenv("NAPI_DART_TRACE_IDENTITY") != nullptr;
  if (trace) {
    std::fprintf(stderr, "NAPI_IDENTITY expected=%s actual=%s runtime=%s accepted=%d\n",
                 kExpectedRuntimeId, actual ? actual : "<null>", location.dli_fname, matches ? 1 : 0);
  }
  if (!matches) {
    initialize_error = std::string("Runtime identity mismatch before VM initialization: expected=") +
        kExpectedRuntimeId + " actual=" + (actual ? actual : "<null>") +
        " runtime=" + location.dli_fname;
    return;
  }
  // Compatible copies may resolve to an already loaded matching image. The
  // unselected on-disk copy is outside runtime semantics (pack validation owns it).
  void* resident = dlopen(location.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NODELETE);
  if (!resident) {
    initialize_error = dlerror();
    return;
  }
  if (trace) std::fprintf(stderr, "NAPI_VM_INIT runtime=%s\n", location.dli_fname);
  char* error = nullptr;
  if (!NapiDart_Init(&error)) {
    initialize_error = error ? error : "Cannot initialize Dart runtime";
    NapiDart_FreeError(error);
  }
}
static napi_value load(napi_env env, napi_callback_info info) {
  if (active_owner)
    return fail(env, "Cannot load a Dart isolate reentrantly");
  size_t argc = 5;
  napi_value args[5];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok ||
      (argc < 1 || argc > 4))
    return fail(env, "load expects a snapshot path and optional private resolver/Promise/settlement factories");
  bool has_resolver = false;
  if (argc >= 2) {
    napi_valuetype type;
    if (napi_typeof(env, args[1], &type) != napi_ok ||
        (type != napi_function && !(argc >= 3 && type == napi_null)))
      return fail(env, "Native reference resolver must be a function or null");
    has_resolver = type == napi_function;
  }
  if (argc >= 3) {
    napi_valuetype type;
    if (napi_typeof(env, args[2], &type) != napi_ok || type != napi_function)
      return fail(env, "Native Promise factory must be a function");
  }
  if (argc == 4) {
    napi_valuetype type;
    if (napi_typeof(env, args[3], &type) != napi_ok || type != napi_function)
      return fail(env, "Native settlement observer factory must be a function");
  }
  size_t size;
  if (napi_get_value_string_utf8(env, args[0], nullptr, 0, &size) != napi_ok)
    return fail(env, "Snapshot path must be a string");
  std::vector<char> path(size + 1);
  if (napi_get_value_string_utf8(env, args[0], path.data(), path.size(), &size)
          != napi_ok || path[0] != '/' || std::string(path.data()).size() != size)
    return fail(env, "Snapshot path must be absolute and contain no NUL");
  std::call_once(initialize_once, initialize_runtime);
  if (!initialize_error.empty()) return fail(env, initialize_error.c_str());
  // The runtime caches canonical immutable AOT paths and owns their mappings.
  char* canonical = realpath(path.data(), nullptr);
  if (!canonical) {
    const std::string message = std::string("Cannot resolve AOT path: ") + std::strerror(errno);
    return fail(env, message.c_str());
  }
  char* error = nullptr;
  auto snapshot = NapiDart_LoadAotSnapshot(canonical, &error);
  free(canonical);
  if (!snapshot) {
    auto result = fail(env, error ? error : "Cannot load Dart AOT snapshot");
    NapiDart_FreeError(error);
    return result;
  }
  auto owner = new Owner(env);
  if (!initialize_pump(owner)) {
    destroy(owner);
    return fail_error(env, "Cannot initialize Dart event pump");
  }
  // Notifications may arrive during creation, before isolate is assigned. The
  // callback only queues work; the Node loop cannot run it until load returns.
  owner->isolate = NapiDart_CreateIsolate(snapshot, notify_message, owner, &error);
  if (!owner->isolate) {
    auto result = fail(env, error ? error : "Cannot create Dart isolate");
    NapiDart_FreeError(error);
    destroy(owner);
    return result;
  }
  napi_value exports;
  auto status = napi_create_object(env, &exports);
  if (status == napi_ok && has_resolver)
    status = napi_create_reference(env, args[1], 1, &owner->reference_resolver);
  if (status == napi_ok && argc >= 3)
    status = napi_create_reference(env, args[2], 1, &owner->promise_factory);
  if (status == napi_ok && argc == 4)
    status = initialize_promise_observer(owner, args[3]);
  if (status != napi_ok || capture_maps(owner) != napi_ok ||
      capture_dictionary(owner) != napi_ok ||
      !register_bindings(owner, exports)) {
    destroy(owner);
    return fail(env, "Cannot register Dart bindings");
  }
  if (napi_add_async_cleanup_hook(env, cleanup, owner, &owner->cleanup_hook) != napi_ok) {
    destroy(owner);
    return fail(env, "Cannot register isolate cleanup");
  }
  return exports;
}

static napi_value init(napi_env env, napi_value exports) {
  napi_value fn;
  if (napi_create_function(env, "load", 4, load, nullptr, &fn) != napi_ok)
    return fail(env, "Cannot expose generic bridge");
  napi_property_descriptor property = {"load", nullptr, nullptr, nullptr,
      nullptr, fn, napi_default_jsproperty, nullptr};
  if (napi_define_properties(env, exports, 1, &property) != napi_ok)
    return fail(env, "Cannot expose generic bridge");
  return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, init)
