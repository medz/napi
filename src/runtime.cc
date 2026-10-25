#include "runtime.h"

#include <condition_variable>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <dlfcn.h>
#include <unistd.h>
#endif

#include "bin/dartutils.h"
#include "bin/elf_loader.h"
#include "bin/icu.h"
#include "bin/loader.h"
#include "bin/platform.h"
#include "bin/snapshot_utils.h"
#include "include/bin/dart_io_api.h"
#include "include/dart_api.h"

namespace napi_dart {
namespace {

struct Group;

struct Owner {
  // initialize() writes this slot before it creates any other Dart resources.
  napi_threadsafe_function threadsafe = nullptr;
  Dart_Isolate isolate = nullptr;
  bool closing = false;
  bool child = false;
  Group* group = nullptr;
  Owner* next = nullptr;
};

static_assert(offsetof(Owner, threadsafe) == 0);

struct Environment {
  std::mutex mutex;
  std::condition_variable condition;
  Owner* children = nullptr;
  size_t groups = 0;
  bool closing = false;
};

struct Group {
  Environment* environment = nullptr;
  char* uri = nullptr;
  char* packages = nullptr;
  dart::bin::AppSnapshot* snapshot = nullptr;

  ~Group() {
    delete snapshot;
    std::free(packages);
    std::free(uri);
  }
};

std::once_flag initialize_once;
const char* initialization_error = nullptr;
const uint8_t* snapshot_data = nullptr;
const uint8_t* snapshot_text = nullptr;
Dart_LoadedElf* snapshot = nullptr;
char* script_uri = nullptr;
char executable_path[32768];

char* CopyString(const char* message) {
  const size_t length = std::strlen(message) + 1;
  auto* copy = static_cast<char*>(std::malloc(length));
  if (copy != nullptr) std::memcpy(copy, message, length);
  return copy;
}

Dart_Handle SetupLibraries(Group* group, bool first_isolate) {
  if (first_isolate) {
    Dart_Handle result =
        Dart_SetLibraryTagHandler(dart::bin::Loader::LibraryTagHandler);
    if (Dart_IsError(result)) return result;
  }
  dart::bin::DartIoSettings settings;
  settings.script_uri = group->uri;
  settings.enable_network_profiling = false;
  Dart_Handle result =
      dart::bin::DartUtils::SetupCoreLibraries(false, false, false, settings);
  if (Dart_IsError(result)) return result;
  Dart_Handle arguments[] = {
      group->packages == nullptr ? Dart_Null()
                                 : Dart_NewStringFromCString(group->packages),
      Dart_NewStringFromCString(
          dart::bin::DartUtils::original_working_directory),
      Dart_NewStringFromCString(group->uri),
  };
  return Dart_Invoke(dart::bin::DartUtils::LookupBuiltinLib(),
                     Dart_NewStringFromCString("_Init"), 3, arguments);
}

Dart_Handle Invoke(Dart_Handle library, const char* name) {
  return Dart_Invoke(library, Dart_NewStringFromCString(name), 0, nullptr);
}

void ReportError(napi_env env, Dart_Handle error) {
  napi_throw_error(env, nullptr, Dart_GetError(error));
  napi_value exception = nullptr;
  if (napi_get_and_clear_last_exception(env, &exception) == napi_ok &&
      exception != nullptr) {
    napi_fatal_exception(env, exception);
  }
}

bool RegisterChild(Owner* child) {
  auto* environment = child->group->environment;
  std::lock_guard<std::mutex> lock(environment->mutex);
  if (environment->closing) return false;
  child->next = environment->children;
  environment->children = child;
  return true;
}

bool InitializeChild(void** isolate_data, char** error) {
  *isolate_data = nullptr;
  auto* group = static_cast<Group*>(Dart_CurrentIsolateGroupData());
  Dart_EnterScope();
  Dart_Handle result = SetupLibraries(group, false);
  if (Dart_IsError(result)) {
    *error = CopyString(Dart_GetError(result));
    Dart_ExitScope();
    return false;
  }
  auto* child = new (std::nothrow) Owner;
  if (child != nullptr) {
    child->isolate = Dart_CurrentIsolate();
    child->child = true;
    child->group = group;
    if (RegisterChild(child)) *isolate_data = child;
  }
  if (*isolate_data == nullptr) {
    delete child;
    *error =
        CopyString("Dart isolate group is closing or cannot allocate a child");
  }
  Dart_ExitScope();
  // The VM shuts down a failed child after this callback returns.
  return *isolate_data != nullptr;
}

void ShutdownIsolate(void* group_data, void* isolate_data) {
  auto* group = static_cast<Group*>(group_data);
  auto* owner = static_cast<Owner*>(isolate_data);
  if (group == nullptr || owner == nullptr || !owner->child) return;
  std::lock_guard<std::mutex> lock(group->environment->mutex);
  // Clear the address before the VM can release or reuse the isolate.
  owner->isolate = nullptr;
}

void CleanupIsolate(void* group_data, void* isolate_data) {
  auto* group = static_cast<Group*>(group_data);
  auto* owner = static_cast<Owner*>(isolate_data);
  if (group == nullptr || owner == nullptr || !owner->child) return;
  auto* environment = group->environment;
  {
    std::lock_guard<std::mutex> lock(environment->mutex);
    Owner** current = &environment->children;
    while (*current != nullptr && *current != owner)
      current = &(*current)->next;
    if (*current == owner) *current = owner->next;
    // Cleanup runs after the VM has unregistered the child.
    environment->condition.notify_all();
  }
  delete owner;
}

void CleanupGroup(void* group_data) {
  auto* group = static_cast<Group*>(group_data);
  auto* environment = group->environment;
  delete group;
  std::lock_guard<std::mutex> lock(environment->mutex);
  --environment->groups;
  environment->condition.notify_all();
}

void CloseEnvironment(Environment* environment) {
  std::unique_lock<std::mutex> lock(environment->mutex);
  environment->closing = true;
  for (Owner* child = environment->children; child != nullptr;
       child = child->next) {
    if (child->isolate != nullptr) Dart_KillIsolate(child->isolate);
  }
  // Group cleanup can follow isolate cleanup asynchronously on the VM pool.
  environment->condition.wait(lock, [environment] {
    return environment->children == nullptr && environment->groups == 1;
  });
}

Dart_Isolate CreateGroup(const char* uri, const char* name, const char*,
                         const char* packages, Dart_IsolateFlags* flags,
                         void* callback_data, char** error) {
  auto* parent = static_cast<Owner*>(callback_data);
  if (parent == nullptr) {
    *error =
        CopyString("Cannot create a Dart isolate without a Node environment");
    return nullptr;
  }
  auto* group = new (std::nothrow) Group;
  if (group == nullptr) {
    *error = CopyString("Cannot allocate Dart isolate group");
    return nullptr;
  }
  // The VM keeps the parent alive until this callback returns.
  group->environment = parent->group->environment;
  auto* environment = group->environment;
  {
    std::lock_guard<std::mutex> lock(environment->mutex);
    if (environment->closing) {
      delete group;
      *error = CopyString("Dart environment is closing");
      return nullptr;
    }
    ++environment->groups;
  }
  group->uri = CopyString(uri);
  group->packages = packages == nullptr ? nullptr : CopyString(packages);
  if (group->uri == nullptr ||
      (packages != nullptr && group->packages == nullptr)) {
    *error = CopyString("Cannot allocate Dart isolate group");
    CleanupGroup(group);
    return nullptr;
  }
  group->snapshot = dart::bin::Snapshot::TryReadAppSnapshot(uri);
  if (group->snapshot == nullptr || !group->snapshot->IsAOT()) {
    *error = dart::Utils::SCreate(
        "The uri(%s) provided to `Isolate.spawnUri()` does not contain a valid "
        "AOT snapshot.",
        uri);
    CleanupGroup(group);
    return nullptr;
  }
  const uint8_t* data = nullptr;
  const uint8_t* text = nullptr;
  group->snapshot->SetBuffers(&data, &text);
  auto* owner = new (std::nothrow) Owner;
  if (owner == nullptr) {
    *error = CopyString("Cannot allocate Dart isolate");
    CleanupGroup(group);
    return nullptr;
  }
  owner->child = true;
  owner->group = group;
  owner->isolate = Dart_CreateIsolateGroup(uri, name, data, text, flags, group,
                                           owner, error);
  if (owner->isolate == nullptr) {
    delete owner;
    CleanupGroup(group);
    return nullptr;
  }
  Dart_EnterScope();
  Dart_Handle result = SetupLibraries(group, true);
  if (Dart_IsError(result) || !RegisterChild(owner)) {
    *error = CopyString(Dart_IsError(result) ? Dart_GetError(result)
                                             : "Dart environment is closing");
    Dart_ExitScope();
    Dart_ShutdownIsolate();
    return nullptr;
  }
  Dart_Isolate isolate = owner->isolate;
  Dart_ExitScope();
  Dart_ExitIsolate();
  return isolate;
}

void Notify(Dart_Isolate isolate) {
  auto* owner = static_cast<Owner*>(Dart_IsolateData(isolate));
  if (owner != nullptr && owner->threadsafe != nullptr) {
    napi_call_threadsafe_function(owner->threadsafe, nullptr,
                                  napi_tsfn_nonblocking);
  }
}

void CallJs(napi_env env, napi_value, void* context, void*) {
  auto* owner = static_cast<Owner*>(context);
  // Node passes no environment when it discards aborted TSFN calls.
  if (env == nullptr || owner->closing || owner->isolate == nullptr) return;
  Dart_EnterIsolate(owner->isolate);
  Dart_EnterScope();
  Dart_Handle result = Dart_HandleMessage();
  if (!Dart_IsError(result)) {
    Dart_Handle library =
        Dart_LookupLibrary(Dart_NewStringFromCString("dart:isolate"));
    // Native callbacks may enqueue microtasks without posting a port message.
    result = Invoke(library, "_runPendingImmediateCallback");
  }
  if (Dart_IsError(result)) ReportError(env, result);
  // Refresh Node keepalive even after a handled uncaught exception.
  result = Invoke(Dart_RootLibrary(), "afterPump");
  if (Dart_IsError(result)) ReportError(env, result);
  Dart_ExitScope();
  Dart_ExitIsolate();
}

void Finalize(napi_env, void* data, void*) { delete static_cast<Owner*>(data); }

void Cleanup(void* data) {
  auto* owner = static_cast<Owner*>(data);
  auto* environment = owner->group->environment;
  owner->closing = true;
  Dart_EnterIsolate(owner->isolate);
  Dart_SetMessageNotifyCallback(nullptr);
  CloseEnvironment(environment);
  Dart_EnterScope();
  Invoke(Dart_RootLibrary(), "dispose");
  Dart_ExitScope();
  // Shutdown closes ports and waits for outstanding notification callbacks.
  Dart_ShutdownIsolate();
  owner->isolate = nullptr;
  {
    // An outstanding same-group spawn can still be finishing initialization.
    std::unique_lock<std::mutex> lock(environment->mutex);
    environment->condition.wait(
        lock, [environment] { return environment->groups == 0; });
  }
  delete environment;
  if (owner->threadsafe != nullptr) {
    napi_release_threadsafe_function(owner->threadsafe, napi_tsfn_abort);
  } else {
    delete owner;
  }
}

bool PinModule() {
  // The VM and dart:io retain process-wide threads after the last Node env
  // ends.
#if defined(_WIN32)
  HMODULE module = nullptr;
  return GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                GET_MODULE_HANDLE_EX_FLAG_PIN,
                            reinterpret_cast<LPCWSTR>(&PinModule),
                            &module) != 0;
#else
  Dl_info module;
  if (dladdr(reinterpret_cast<void*>(&PinModule), &module) == 0) return false;
  return dlopen(module.dli_fname, RTLD_NOW | RTLD_LOCAL | RTLD_NODELETE) !=
         nullptr;
#endif
}

void InitializeVm(const char* path, FILE* file, uint64_t offset,
                  uint64_t size) {
  if (!PinModule()) {
    initialization_error = "Cannot retain the Dart runtime module";
    return;
  }
  script_uri = CopyString(path);
  if (script_uri == nullptr) {
    initialization_error = "Cannot allocate Dart runtime state";
    return;
  }
#if defined(_WIN32)
  if (size > static_cast<uint64_t>(SIZE_MAX) ||
      _fseeki64(file, static_cast<int64_t>(offset), SEEK_SET) != 0) {
    initialization_error = "Cannot read the Dart AOT snapshot";
    return;
  }
  auto* bytes = static_cast<uint8_t*>(std::malloc(static_cast<size_t>(size)));
  if (bytes == nullptr) {
    initialization_error = "Cannot allocate Dart AOT snapshot memory";
    return;
  }
  if (fread(bytes, 1, static_cast<size_t>(size), file) != size) {
    std::free(bytes);
    initialization_error = "Cannot read the Dart AOT snapshot";
    return;
  }
  snapshot = Dart_LoadELF_Memory(bytes, size, &initialization_error,
                                 &snapshot_data, &snapshot_text);
  std::free(bytes);
#else
  const int descriptor = dup(fileno(file));
  if (descriptor == -1) {
    initialization_error = "Cannot retain the Dart AOT snapshot file";
    return;
  }
  // The loader owns the duplicate, including on failure.
  snapshot = Dart_LoadELF_Fd(descriptor, offset, &initialization_error,
                             &snapshot_data, &snapshot_text);
#endif
  if (snapshot == nullptr) {
    if (initialization_error == nullptr) {
      initialization_error = "Cannot load the Dart AOT snapshot";
    }
    return;
  }

  dart::bin::SetupICU();
  if (!dart::bin::Platform::Initialize(false) ||
      dart::bin::Platform::ResolveExecutablePathInto(
          executable_path, sizeof(executable_path)) < 0) {
    initialization_error = "Cannot initialize Dart platform";
    return;
  }
  dart::bin::Platform::SetExecutableName(executable_path);
  if (!dart::bin::DartUtils::SetOriginalWorkingDirectory()) {
    initialization_error = "Cannot determine the current working directory";
    return;
  }
  dart::bin::BootstrapDartIo();
  const char* flags[] = {"--precompilation"};
  initialization_error = Dart_SetVMFlags(1, flags);
  if (initialization_error != nullptr) return;

  Dart_InitializeParams parameters = {};
  parameters.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  parameters.create_group = CreateGroup;
  parameters.initialize_isolate = InitializeChild;
  parameters.shutdown_isolate = ShutdownIsolate;
  parameters.cleanup_isolate = CleanupIsolate;
  parameters.cleanup_group = CleanupGroup;
  parameters.file_open = dart::bin::OpenFile;
  parameters.file_read = dart::bin::ReadFile;
  parameters.file_write = dart::bin::WriteFile;
  parameters.file_close = dart::bin::CloseFile;
  parameters.entropy_source = dart::bin::GetEntropy;
  initialization_error = Dart_Initialize(&parameters);
}

napi_value ThrowError(napi_env env, const char* message) {
  napi_throw_error(env, nullptr, message);
  return nullptr;
}

napi_value FailInitialization(napi_env env, Owner* owner, Dart_Handle error) {
  // Dart_GetError borrows memory from the active API scope.
  ThrowError(env, Dart_GetError(error));
  Dart_ExitScope();
  Dart_ExitIsolate();
  Cleanup(owner);
  return nullptr;
}

}  // namespace

napi_value Initialize(napi_env env, napi_value exports,
                      const char* snapshot_path, FILE* file,
                      uint64_t snapshot_offset, uint64_t snapshot_size) {
  std::call_once(initialize_once, InitializeVm, snapshot_path, file,
                 snapshot_offset, snapshot_size);
  if (initialization_error != nullptr) {
    return ThrowError(env, initialization_error);
  }

  auto* owner = new (std::nothrow) Owner;
  auto* group = new (std::nothrow) Group;
  auto* environment = new (std::nothrow) Environment;
  if (owner == nullptr || group == nullptr || environment == nullptr) {
    delete owner;
    delete group;
    delete environment;
    return ThrowError(env, "Cannot allocate Dart environment");
  }
  group->environment = environment;
  group->uri = CopyString(script_uri);
  if (group->uri == nullptr) {
    delete owner;
    delete group;
    delete environment;
    return ThrowError(env, "Cannot allocate Dart environment");
  }
  environment->groups = 1;
  owner->group = group;
  char* error = nullptr;
  owner->isolate =
      Dart_CreateIsolateGroup(script_uri, script_uri, snapshot_data,
                              snapshot_text, nullptr, group, owner, &error);
  if (owner->isolate == nullptr) {
    // Failed group creation does not invoke the group's cleanup callback.
    CleanupGroup(group);
    delete owner;
    delete environment;
    ThrowError(env, error == nullptr ? "Dart isolate creation failed" : error);
    std::free(error);
    return nullptr;
  }

  Dart_SetCurrentThreadOwnsIsolate();
  Dart_EnterScope();
  Dart_Handle result = SetupLibraries(group, true);
  if (Dart_IsError(result)) return FailInitialization(env, owner, result);
  Dart_Handle arguments[] = {
      Dart_NewIntegerFromUint64(reinterpret_cast<uintptr_t>(env)),
      Dart_NewIntegerFromUint64(reinterpret_cast<uintptr_t>(exports)),
      Dart_NewIntegerFromUint64(reinterpret_cast<uintptr_t>(&CallJs)),
      Dart_NewIntegerFromUint64(reinterpret_cast<uintptr_t>(owner)),
      Dart_NewIntegerFromUint64(reinterpret_cast<uintptr_t>(&Finalize)),
      Dart_NewIntegerFromUint64(
          reinterpret_cast<uintptr_t>(&Dart_HasLivePorts)),
  };
  result = Dart_Invoke(Dart_RootLibrary(),
                       Dart_NewStringFromCString("initialize"), 6, arguments);
  if (Dart_IsError(result)) return FailInitialization(env, owner, result);
  uint64_t threadsafe = 0;
  result = Dart_IntegerToUint64(result, &threadsafe);
  if (Dart_IsError(result)) return FailInitialization(env, owner, result);
  owner->threadsafe = reinterpret_cast<napi_threadsafe_function>(threadsafe);
  Dart_SetMessageNotifyCallback(Notify);
  Dart_ExitScope();
  Dart_ExitIsolate();

  error = Dart_IsolateMakeRunnable(owner->isolate);
  if (error != nullptr) {
    ThrowError(env, error);
    std::free(error);
    Cleanup(owner);
    return nullptr;
  }
  if (napi_add_env_cleanup_hook(env, Cleanup, owner) != napi_ok) {
    Cleanup(owner);
    return ThrowError(env, "Cannot register Dart isolate cleanup");
  }
  return exports;
}

}  // namespace napi_dart
