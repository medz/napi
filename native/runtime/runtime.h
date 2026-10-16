// Copyright (c) 2026, the napi project authors.
// Portions adapted from Dart SDK 3.13.5 runtime/engine. See DART_LICENSE.

#ifndef NAPI_DART_RUNTIME_H_
#define NAPI_DART_RUNTIME_H_

#include "include/dart_api.h"

#if defined(_WIN32)
#if defined(NAPI_DART_RUNTIME_BUILD)
#define NAPI_DART_EXPORT DART_EXTERN_C __declspec(dllexport)
#else
#define NAPI_DART_EXPORT DART_EXTERN_C __declspec(dllimport)
#endif
#else
#define NAPI_DART_EXPORT DART_EXTERN_C __attribute__((visibility("default")))
#endif

typedef struct NapiDart_Snapshot NapiDart_Snapshot;
typedef struct NapiDart_Isolate NapiDart_Isolate;

// Called on arbitrary VM/native threads, including during CreateIsolate.
// Must only enqueue a wakeup: do not enter Dart, call runtime functions, invoke
// JS, or wait for the owner thread. The caller must count notifications and
// eventually call Dart_HandleMessage once per notification on the owner thread.
// Context must outlive CreateIsolate and remain valid until ShutdownIsolate
// returns. Queued wakeups must own a separate caller-managed lifetime token.
typedef void (*NapiDart_Notify)(void* context);

// Maintainer identity of this runtime image. Does not initialize the VM. The
// immutable static string is borrowed and must not be freed by the caller.
NAPI_DART_EXPORT const char* NapiDart_RuntimeIdentity();

// Error outputs are optional. When supplied, *error is set to null on entry;
// failures allocate a message to release with NapiDart_FreeError.
// Initializes one VM for this loaded runtime image. Thread-safe. Never retries
// a partial initialization failure. There is deliberately no global shutdown.
NAPI_DART_EXPORT bool NapiDart_Init(char** error);
NAPI_DART_EXPORT void NapiDart_FreeError(char* error);

// path must be a canonical absolute path to an immutable AOT shared library.
// Successful loads are cached by exact path, and mappings live until process
// exit. This function is thread-safe and does not initialize another VM.
NAPI_DART_EXPORT NapiDart_Snapshot* NapiDart_LoadAotSnapshot(const char* path,
                                                         char** error);

// Creates an independent root isolate/group, owned by the calling thread.
// Requires no current isolate. Returns with no current isolate. A null notify
// is suitable only for synchronous callers that handle messages themselves.
// The callback is always installed, so the VM does not run this isolate on an
// arbitrary thread. Dart-created child isolates are outside this candidate.
NAPI_DART_EXPORT NapiDart_Isolate* NapiDart_CreateIsolate(
    const NapiDart_Snapshot* snapshot,
    NapiDart_Notify notify,
    void* context,
    char** error);

// Owner thread only. Enter/Exit nest for the same isolate. They do not create
// Dart scopes: the caller must balance Dart_EnterScope/Dart_ExitScope inside
// each entry. Enter rejects a different current isolate. Never mix these
// functions with direct Dart_EnterIsolate/Dart_ExitIsolate on this isolate.
NAPI_DART_EXPORT bool NapiDart_EnterIsolate(NapiDart_Isolate* isolate,
                                         char** error);
NAPI_DART_EXPORT bool NapiDart_ExitIsolate(NapiDart_Isolate* isolate,
                                        char** error);

// Requires this isolate to be entered through NapiDart_EnterIsolate. Creates
// its own temporary scope. On error the queue may still contain microtasks;
// the caller chooses whether to continue draining after reporting the error.
NAPI_DART_EXPORT bool NapiDart_DrainMicrotasks(NapiDart_Isolate* isolate,
                                            char** error);

// Owner thread only, with no current isolate and no active entries/scopes.
// Caller must first invalidate its JS wrappers and delete its persistent Dart
// handles while entered. Stops notify calls, destroys only this isolate,
// deletes the control block and sets *isolate to null. Null is idempotent.
// Pending caller wakeups must check their own closing token before using it.
NAPI_DART_EXPORT bool NapiDart_ShutdownIsolate(NapiDart_Isolate** isolate,
                                            char** error);

#endif  // NAPI_DART_RUNTIME_H_
