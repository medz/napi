// Copyright (c) 2025, the Dart project authors. Please see the DART_AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the DART_LICENSE file.
// Copyright (c) 2026, the napi project authors.
// Initialization sequence adapted from Dart SDK 3.13.5 runtime/engine/engine.cc.

#include "runtime.h"

#include <cstdlib>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "bin/dartutils.h"
#include "bin/platform.h"
#if defined(_WIN32)
#include "bin/elf_loader.h"
#endif
#include "include/dart_embedder_api.h"
#include "platform/utils.h"

struct NapiDart_Snapshot {
  std::string uri;
  void* library = nullptr;
  const uint8_t* data = nullptr;
  const uint8_t* text = nullptr;
};

struct NapiDart_Isolate {
  const std::thread::id owner = std::this_thread::get_id();
  Dart_Isolate dart = nullptr;
  unsigned int entries = 0;
  Dart_PersistentHandle isolate_library = nullptr;
  Dart_PersistentHandle drain_name = nullptr;

  // Only notification fields cross threads. Never enter Dart while holding
  // this mutex: VM message posting may hold PortMap's lock while notifying.
  std::mutex notify_mutex;
  bool closing = false;
  NapiDart_Notify notify = nullptr;
  void* context = nullptr;
};

namespace {

struct Runtime {
  std::mutex init_mutex;
  bool attempted = false;
  bool initialized = false;
  std::string initialization_error;
  std::string executable;
  std::mutex snapshots_mutex;
  std::map<std::string, NapiDart_Snapshot*> snapshots;
};

Runtime& GetRuntime() {
  // The runtime and successfully loaded AOT mappings intentionally live for
  // the process. No destructor may tear down a VM still used by another env.
  static Runtime* runtime = new Runtime();
  return *runtime;
}

void ClearError(char** error) {
  if (error != nullptr) *error = nullptr;
}

bool Fail(char** error, const char* message) {
  if (error != nullptr) *error = dart::Utils::StrDup(message);
  return false;
}

bool TransferError(char** error, char* message) {
  if (error != nullptr) {
    *error = message;
  } else {
    free(message);
  }
  return false;
}

bool IsOwner(const NapiDart_Isolate* isolate, char** error) {
  if (isolate == nullptr) return Fail(error, "Isolate is null");
  if (isolate->owner != std::this_thread::get_id()) {
    return Fail(error, "Isolate must be used on its creating thread");
  }
  return true;
}

void NotifyMessage(Dart_Isolate dart) {
  auto* isolate = static_cast<NapiDart_Isolate*>(Dart_IsolateData(dart));
  std::lock_guard<std::mutex> lock(isolate->notify_mutex);
  if (!isolate->closing && isolate->notify != nullptr) {
    isolate->notify(isolate->context);
  }
}

void StopNotifications(NapiDart_Isolate* isolate) {
  std::lock_guard<std::mutex> lock(isolate->notify_mutex);
  isolate->closing = true;
  isolate->notify = nullptr;
  isolate->context = nullptr;
}

void DeleteInternalHandles(NapiDart_Isolate* isolate) {
  if (isolate->isolate_library != nullptr) {
    Dart_DeletePersistentHandle(isolate->isolate_library);
    isolate->isolate_library = nullptr;
  }
  if (isolate->drain_name != nullptr) {
    Dart_DeletePersistentHandle(isolate->drain_name);
    isolate->drain_name = nullptr;
  }
}

NapiDart_Isolate* FailCreation(NapiDart_Isolate* isolate,
                             Dart_Handle failure,
                             char** error) {
  Fail(error, Dart_GetError(failure));
  StopNotifications(isolate);
  Dart_SetMessageNotifyCallback(nullptr);
  DeleteInternalHandles(isolate);
  // Shutdown exits any current scope and disassociates the current isolate.
  Dart_ShutdownIsolate();
  delete isolate;
  return nullptr;
}

}  // namespace

bool NapiDart_Init(char** error) {
  ClearError(error);
  Runtime& runtime = GetRuntime();
  std::lock_guard<std::mutex> lock(runtime.init_mutex);
  if (runtime.attempted) {
    return runtime.initialized ||
           Fail(error, runtime.initialization_error.c_str());
  }
  runtime.attempted = true;
  char* failure = nullptr;
  if (!Dart_IsPrecompiledRuntime()) {
    runtime.initialization_error = "Expected a Dart AOT runtime";
  } else if (!dart::embedder::InitOnce(&failure)) {
    runtime.initialization_error =
        failure != nullptr ? failure : "Dart embedder initialization failed";
  } else {
    // Store the host path for dart:io Platform.executable. The SDK retains
    // this pointer, so its storage must live as long as the process runtime.
    std::vector<char> executable(32768);
    const intptr_t length = dart::bin::Platform::ResolveExecutablePathInto(
        executable.data(), executable.size());
    if (length <= 0 || static_cast<size_t>(length) >= executable.size()) {
      runtime.initialization_error = "Cannot resolve host executable path";
      free(failure);
      return Fail(error, runtime.initialization_error.c_str());
    }
    runtime.executable.assign(executable.data(), static_cast<size_t>(length));
    dart::bin::Platform::SetExecutableName(runtime.executable.c_str());
    const char* flags[] = {"--precompilation"};
    failure = Dart_SetVMFlags(1, flags);
    if (failure == nullptr) {
      Dart_InitializeParams params = {};
      params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
      params.entropy_source = dart::bin::DartUtils::EntropySource;
      failure = Dart_Initialize(&params);
    }
    if (failure == nullptr) {
      runtime.initialized = true;
    } else {
      runtime.initialization_error = failure;
    }
  }
  free(failure);
  return runtime.initialized ||
         Fail(error, runtime.initialization_error.c_str());
}

void NapiDart_FreeError(char* error) {
  free(error);
}

NapiDart_Snapshot* NapiDart_LoadAotSnapshot(const char* path, char** error) {
  ClearError(error);
  if (path == nullptr || path[0] == '\0') {
    Fail(error, "Snapshot path is empty");
    return nullptr;
  }
  if (!NapiDart_Init(error)) return nullptr;
  Runtime& runtime = GetRuntime();
  std::lock_guard<std::mutex> lock(runtime.snapshots_mutex);
  auto found = runtime.snapshots.find(path);
  if (found != runtime.snapshots.end()) return found->second;

#if defined(_WIN32)
  // The ordinary Dart SDK emits ELF AOT snapshots on Windows. Map them with
  // Dart's loader instead of requiring consumers to link their own DLL.
  const char* failure = nullptr;
  const uint8_t* data = nullptr;
  const uint8_t* text = nullptr;
  auto* library = Dart_LoadELF(path, 0, &failure, &data, &text);
  if (library == nullptr || data == nullptr || text == nullptr) {
    if (library != nullptr) Dart_UnloadELF(library);
    Fail(error, failure != nullptr ? failure : "Could not load ELF AOT snapshot");
    return nullptr;
  }
#else
  char* failure = nullptr;
  void* library = dart::Utils::LoadDynamicLibrary(
      path, /*search_dll_load_dir=*/false, &failure);
  if (library == nullptr || failure != nullptr) {
    if (library != nullptr) dart::Utils::UnloadDynamicLibrary(library);
    if (failure != nullptr) {
      TransferError(error, failure);
    } else {
      Fail(error, "Could not load AOT snapshot library");
    }
    return nullptr;
  }
  auto* data = static_cast<const uint8_t*>(
      dart::Utils::ResolveSymbolInDynamicLibrary(library, kSnapshotDataCSymbol,
                                               &failure));
  const uint8_t* text = nullptr;
  if (failure == nullptr) {
    text = static_cast<const uint8_t*>(dart::Utils::ResolveSymbolInDynamicLibrary(
        library, kSnapshotTextCSymbol, &failure));
  }
  if (failure != nullptr || data == nullptr || text == nullptr) {
    dart::Utils::UnloadDynamicLibrary(library);
    if (failure != nullptr) {
      TransferError(error, failure);
    } else {
      Fail(error, "AOT snapshot has null data or text symbols");
    }
    return nullptr;
  }
#endif
  auto* snapshot = new NapiDart_Snapshot();
  snapshot->uri = std::string("file://") + path;
  snapshot->library = library;
  snapshot->data = data;
  snapshot->text = text;
  runtime.snapshots.emplace(path, snapshot);
  return snapshot;
}

NapiDart_Isolate* NapiDart_CreateIsolate(const NapiDart_Snapshot* snapshot,
                                      NapiDart_Notify notify,
                                      void* context,
                                      char** error) {
  ClearError(error);
  if (snapshot == nullptr) {
    Fail(error, "Snapshot is null");
    return nullptr;
  }
  if (Dart_CurrentIsolate() != nullptr) {
    Fail(error, "Creating an isolate requires no current isolate");
    return nullptr;
  }
  if (!NapiDart_Init(error)) return nullptr;
  auto* isolate = new NapiDart_Isolate();
  isolate->notify = notify;
  isolate->context = context;
  Dart_IsolateFlags flags;
  Dart_IsolateFlagsInitialize(&flags);
  char* failure = nullptr;
  isolate->dart = Dart_CreateIsolateGroup(
      snapshot->uri.c_str(), "napi", snapshot->data, snapshot->text, &flags,
      /*isolate_group_data=*/nullptr, /*isolate_data=*/isolate, &failure);
  if (isolate->dart == nullptr) {
    delete isolate;
    if (failure != nullptr) {
      TransferError(error, failure);
    } else {
      Fail(error, "Dart isolate creation failed");
    }
    return nullptr;
  }
  Dart_SetMessageNotifyCallback(NotifyMessage);
  Dart_EnterScope();
  Dart_Handle result = dart::bin::DartUtils::SetupCoreLibraries(
      /*is_service_isolate=*/false, /*trace_loading=*/false,
      /*flag_profile_microtasks=*/false, dart::bin::DartIoSettings{});
  if (Dart_IsError(result)) return FailCreation(isolate, result, error);
  result = Dart_LookupLibrary(
      Dart_NewStringFromCString(dart::bin::DartUtils::kIsolateLibURL));
  if (Dart_IsError(result)) return FailCreation(isolate, result, error);
  isolate->isolate_library = Dart_NewPersistentHandle(result);
  result = Dart_NewStringFromCString("_runPendingImmediateCallback");
  if (Dart_IsError(result)) return FailCreation(isolate, result, error);
  isolate->drain_name = Dart_NewPersistentHandle(result);
  Dart_ExitScope();
  Dart_ExitIsolate();
  return isolate;
}

bool NapiDart_EnterIsolate(NapiDart_Isolate* isolate, char** error) {
  ClearError(error);
  if (!IsOwner(isolate, error)) return false;
  Dart_Isolate current = Dart_CurrentIsolate();
  if (isolate->entries == 0) {
    if (current != nullptr) return Fail(error, "Another isolate is current");
    Dart_EnterIsolate(isolate->dart);
  } else if (current != isolate->dart) {
    return Fail(error, "Current isolate does not match active entry");
  }
  isolate->entries++;
  return true;
}

bool NapiDart_ExitIsolate(NapiDart_Isolate* isolate, char** error) {
  ClearError(error);
  if (!IsOwner(isolate, error)) return false;
  if (isolate->entries == 0 || Dart_CurrentIsolate() != isolate->dart) {
    return Fail(error, "No matching isolate entry to exit");
  }
  if (--isolate->entries == 0) Dart_ExitIsolate();
  return true;
}

bool NapiDart_DrainMicrotasks(NapiDart_Isolate* isolate, char** error) {
  ClearError(error);
  if (!IsOwner(isolate, error)) return false;
  if (isolate->entries == 0 || Dart_CurrentIsolate() != isolate->dart) {
    return Fail(error, "Microtask drain requires an active isolate entry");
  }
  Dart_EnterScope();
  Dart_Handle result = Dart_Invoke(isolate->isolate_library, isolate->drain_name,
                                   0, nullptr);
  const bool ok = !Dart_IsError(result);
  if (!ok) Fail(error, Dart_GetError(result));
  Dart_ExitScope();
  return ok;
}

bool NapiDart_ShutdownIsolate(NapiDart_Isolate** isolate_ptr, char** error) {
  ClearError(error);
  if (isolate_ptr == nullptr) return Fail(error, "Isolate pointer is null");
  NapiDart_Isolate* isolate = *isolate_ptr;
  if (isolate == nullptr) return true;
  if (!IsOwner(isolate, error)) return false;
  if (isolate->entries != 0 || Dart_CurrentIsolate() != nullptr) {
    return Fail(error, "Shutdown requires no active isolate or call");
  }
  StopNotifications(isolate);
  Dart_EnterIsolate(isolate->dart);
  Dart_SetMessageNotifyCallback(nullptr);
  DeleteInternalHandles(isolate);
  Dart_ShutdownIsolate();
  // No Dart_ExitScope/ExitIsolate here: ShutdownIsolate already exits both.
  // On this non-VM owner thread the root group teardown is synchronous. Its
  // port closure synchronizes against in-flight VM message notifications.
  // All caller-queued wakeups must still be invalidated by the caller token.
  delete isolate;
  *isolate_ptr = nullptr;
  return true;
}
