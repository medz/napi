#include "runtime.h"

#include "image.h"

#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <string>

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
#include "bin/file.h"
#include "bin/icu.h"
#include "bin/platform.h"
#if defined(__APPLE__)
#include "bin/snapshot_utils.h"
#endif
#include "bin/uri.h"
#include "include/bin/dart_io_api.h"
#include "include/dart_api.h"
#include "include/dart_native_api.h"

namespace napi_dart {
namespace {

struct Group;
struct Owner;

struct CallbackData {
  Owner* owner;
  intptr_t token;
  napi_callback primary;
  napi_callback secondary;
  CallbackData* previous;
  CallbackData* next;
  Dart_Port port;
};

static_assert(offsetof(CallbackData, token) == sizeof(void*));

using WrapCallback = int32_t (*)(void*, napi_env, napi_value, int64_t, intptr_t);
using CallbackDataFactory =
    int32_t (*)(void*, intptr_t, napi_callback, napi_callback, void**);
using TrackFunctionCallback = int32_t (*)(void*, napi_value, void*, int64_t);

int32_t WrapValue(void* data,
                  napi_env env,
                  napi_value object,
                  int64_t port,
                  intptr_t token);
napi_value Callback(napi_env env, napi_callback_info info);
napi_value SetterCallback(napi_env env, napi_callback_info info);
int32_t CreateCallbackData(void* data,
                           intptr_t token,
                           napi_callback primary,
                           napi_callback secondary,
                           void** output);
int32_t TrackFunction(void* data,
                      napi_value function,
                      void* callback_data,
                      int64_t port);
napi_value ThrowError(napi_env env, const char* message);

struct Owner {
  // initialize() writes this slot before it creates any other Dart resources.
  napi_threadsafe_function threadsafe = nullptr;
  WrapCallback wrap = WrapValue;
  napi_callback callback = Callback;
  napi_callback setter = SetterCallback;
  CallbackDataFactory create_callback_data = CreateCallbackData;
  TrackFunctionCallback track_function = TrackFunction;
  Dart_Isolate isolate = nullptr;
  napi_env env = nullptr;
  // Wrapping, tracking and Node finalizers run on this environment's thread.
  size_t references = 1;
  bool closing = false;
  bool initialize_started = false;
  bool child = false;
  bool callback_cleanup_registered = false;
  CallbackData* callbacks = nullptr;
  Group* group = nullptr;
  Owner* next = nullptr;

  ~Owner() {
    while (callbacks != nullptr) {
      CallbackData* next = callbacks->next;
      delete callbacks;
      callbacks = next;
    }
  }
};

static_assert(offsetof(Owner, threadsafe) == 0);
static_assert(offsetof(Owner, wrap) == sizeof(void*));
static_assert(sizeof(WrapCallback) == sizeof(void*));
static_assert(offsetof(Owner, callback) == 2 * sizeof(void*));
static_assert(offsetof(Owner, setter) == 3 * sizeof(void*));
static_assert(offsetof(Owner, create_callback_data) == 4 * sizeof(void*));
static_assert(sizeof(CallbackDataFactory) == sizeof(void*));
static_assert(offsetof(Owner, track_function) == 5 * sizeof(void*));
static_assert(sizeof(TrackFunctionCallback) == sizeof(void*));

struct WrappedValue {
  Owner* owner;
  Dart_Port port;
};

void ReleaseOwner(Owner* owner) {
  if (--owner->references == 0) delete owner;
}

void ReleaseCallbackOwner(void* data) {
  ReleaseOwner(static_cast<Owner*>(data));
}

void DeleteCallbackData(CallbackData* callback) {
  if (callback->previous != nullptr) {
    callback->previous->next = callback->next;
  } else {
    callback->owner->callbacks = callback->next;
  }
  if (callback->next != nullptr) {
    callback->next->previous = callback->previous;
  }
  delete callback;
}

void FinalizeFunction(napi_env, void* data, void*) {
  auto* callback = static_cast<CallbackData*>(data);
  Owner* owner = callback->owner;
  if (!owner->closing) {
    Dart_PostInteger(callback->port, callback->token);
  }
  DeleteCallbackData(callback);
  ReleaseOwner(owner);
}

int32_t CreateCallbackData(void* data,
                           intptr_t token,
                           napi_callback primary,
                           napi_callback secondary,
                           void** output) {
  if (output == nullptr) return napi_invalid_arg;
  *output = nullptr;
  auto* owner = static_cast<Owner*>(data);
  if (owner == nullptr || owner->child || owner->closing || token <= 0 ||
      (primary == nullptr && secondary == nullptr)) {
    return napi_invalid_arg;
  }
  auto* callback = new (std::nothrow) CallbackData{
      owner, token, primary, secondary, nullptr, nullptr, ILLEGAL_PORT};
  if (callback == nullptr) return napi_generic_failure;
  if (!owner->callback_cleanup_registered) {
    ++owner->references;
    const napi_status status =
        napi_add_env_cleanup_hook(owner->env, ReleaseCallbackOwner, owner);
    if (status != napi_ok) {
      delete callback;
      ReleaseOwner(owner);
      return status;
    }
    owner->callback_cleanup_registered = true;
  }
  callback->next = owner->callbacks;
  if (callback->next != nullptr) callback->next->previous = callback;
  owner->callbacks = callback;
  *output = callback;
  return napi_ok;
}

int32_t TrackFunction(void* data,
                      napi_value function,
                      void* callback_data,
                      int64_t port) {
  auto* owner = static_cast<Owner*>(data);
  auto* callback = static_cast<CallbackData*>(callback_data);
  if (owner == nullptr || callback == nullptr || callback->owner != owner ||
      callback->port != ILLEGAL_PORT) {
    return napi_invalid_arg;
  }
  // Only a record that has not been attached to a JS function can be abandoned.
  if (function == nullptr) {
    DeleteCallbackData(callback);
    return napi_ok;
  }
  if (owner->child || owner->closing || port <= 0 ||
      callback->primary == nullptr || callback->secondary != nullptr) {
    return napi_invalid_arg;
  }
  callback->port = port;
  ++owner->references;
  const napi_status status = napi_add_finalizer(
      owner->env, function, callback, FinalizeFunction, nullptr, nullptr);
  if (status != napi_ok) {
    callback->port = ILLEGAL_PORT;
    ReleaseOwner(owner);
  }
  return status;
}

napi_value DispatchCallback(napi_env env,
                            napi_callback_info info,
                            bool secondary) {
  size_t count = 0;
  void* data = nullptr;
  if (napi_get_cb_info(env, info, &count, nullptr, nullptr, &data) != napi_ok) {
    return ThrowError(env, "Cannot read Dart callback data");
  }
  auto* callback = static_cast<CallbackData*>(data);
  if (callback == nullptr || callback->owner->env != env) {
    return ThrowError(env, "Invalid Dart callback environment");
  }
  if (callback->owner->closing) {
    return ThrowError(env, "Dart environment is closed");
  }
  napi_callback target = secondary ? callback->secondary : callback->primary;
  if (target == nullptr) return ThrowError(env, "Dart callback is unavailable");
  return target(env, info);
}

napi_value Callback(napi_env env, napi_callback_info info) {
  return DispatchCallback(env, info, false);
}

napi_value SetterCallback(napi_env env, napi_callback_info info) {
  return DispatchCallback(env, info, true);
}

void FinalizeValue(napi_env, void* data, void* hint) {
  auto* value = static_cast<WrappedValue*>(hint);
  Owner* owner = value->owner;
  if (!owner->closing) {
    Dart_PostInteger(value->port, reinterpret_cast<intptr_t>(data));
  }
  delete value;
  ReleaseOwner(owner);
}

int32_t WrapValue(void* data,
                  napi_env env,
                  napi_value object,
                  int64_t port,
                  intptr_t token) {
  auto* owner = static_cast<Owner*>(data);
  if (owner == nullptr || owner->child || owner->closing || owner->env != env ||
      port <= 0 || token <= 0) {
    return napi_invalid_arg;
  }
  auto* value = new (std::nothrow) WrappedValue{owner, port};
  if (value == nullptr) return napi_generic_failure;
  ++owner->references;
  const napi_status status =
      napi_wrap(env, object, reinterpret_cast<void*>(token), FinalizeValue, value,
                nullptr);
  if (status != napi_ok) {
    delete value;
    ReleaseOwner(owner);
  }
  return status;
}

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
  Dart_LoadedElf* snapshot = nullptr;

  ~Group() {
    if (snapshot != nullptr) Dart_UnloadELF(snapshot);
    std::free(packages);
    std::free(uri);
  }
};

std::once_flag initialize_once;
const char* initialization_error = nullptr;
char* script_uri = nullptr;
char executable_path[32768];
// The process-wide VM keeps using these mappings across Node environments.
#if defined(__APPLE__)
dart::bin::AppSnapshot* main_snapshot = nullptr;
#else
Dart_LoadedElf* main_snapshot = nullptr;
#endif
const uint8_t* main_data = nullptr;
const uint8_t* main_text = nullptr;

char* CopyString(const char* message) {
  const size_t length = std::strlen(message) + 1;
  auto* copy = static_cast<char*>(std::malloc(length));
  if (copy != nullptr) std::memcpy(copy, message, length);
  return copy;
}

Dart_Handle LibraryTagHandler(Dart_LibraryTag tag,
                              Dart_Handle library,
                              Dart_Handle url) {
  if (tag != Dart_kCanonicalizeUrl) {
    return Dart_NewApiError("Only URI canonicalization is available in AOT");
  }
  const char* path = nullptr;
  Dart_Handle result = Dart_StringToCString(url, &path);
  if (Dart_IsError(result)) return result;
  Dart_Handle library_url = Dart_LibraryUrl(library);
  if (Dart_IsError(library_url)) return library_url;
  const char* base = nullptr;
  result = Dart_StringToCString(library_url, &base);
  if (Dart_IsError(result)) return result;
  if (dart::bin::DartUtils::IsDartSchemeURL(path) ||
      dart::bin::DartUtils::IsDartSchemeURL(base)) {
    return url;
  }
  auto resolved = dart::ResolveUri(path, base);
  if (resolved == nullptr) {
    return Dart_NewApiError("Cannot canonicalize the Dart library URI");
  }
  return Dart_NewStringFromCString(resolved.get());
}

Dart_Handle SetupLibraries(Group* group, bool first_isolate) {
  if (first_isolate) {
    Dart_Handle result = Dart_SetLibraryTagHandler(LibraryTagHandler);
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

Dart_LoadedElf* LoadSnapshotFile(dart::bin::File* file,
                                 uint64_t offset,
                                 uint64_t length,
                                 const uint8_t** data,
                                 const uint8_t** text,
                                 const char** error) {
#if defined(__linux__) || defined(__FreeBSD__) || defined(__Fuchsia__)
  const int descriptor = dup(static_cast<int>(file->GetFD()));
  if (descriptor == -1) {
    *error = "Cannot retain the AOT snapshot file";
    return nullptr;
  }
  return Dart_LoadELF_Fd(descriptor, offset, error, data, text);
#else
  if (length > SIZE_MAX || !file->SetPosition(static_cast<int64_t>(offset))) {
    *error = "Cannot read the AOT snapshot";
    return nullptr;
  }
  auto* bytes = static_cast<uint8_t*>(std::malloc(static_cast<size_t>(length)));
  if (bytes == nullptr) {
    *error = "Cannot allocate AOT snapshot memory";
    return nullptr;
  }
  Dart_LoadedElf* loaded = nullptr;
  if (file->ReadFully(bytes, static_cast<int64_t>(length))) {
    loaded = Dart_LoadELF_Memory(bytes, length, error, data, text);
  } else {
    *error = "Cannot read the AOT snapshot";
  }
  std::free(bytes);
  return loaded;
#endif
}

Dart_LoadedElf* LoadSnapshot(const char* uri,
                             const uint8_t** data,
                             const uint8_t** text,
                             const char** error) {
  using dart::bin::File;
  auto path = File::UriToPath(uri);
  if (path == nullptr ||
      File::GetType(nullptr, path.get(), true) != File::kIsFile) {
    *error = "The URI does not identify a file";
    return nullptr;
  }
  File* file = File::Open(nullptr, path.get(), File::kRead);
  if (file == nullptr) {
    *error = "Cannot open the AOT snapshot";
    return nullptr;
  }
  const int64_t length = file->Length();
  Dart_LoadedElf* loaded = nullptr;
  if (length <= 0) {
    *error = "Cannot read the AOT snapshot";
  } else {
    loaded = LoadSnapshotFile(file, 0, static_cast<uint64_t>(length), data,
                              text, error);
  }
  file->Release();
  return loaded;
}

#if !defined(__APPLE__)
Dart_LoadedElf* LoadEmbeddedSnapshot(const char* path,
                                     const uint8_t** data,
                                     const uint8_t** text,
                                     const char** error) {
  using dart::bin::File;
  File* file = File::Open(nullptr, path, File::kRead);
  if (file == nullptr) {
    *error = "Cannot open the Dart addon file";
    return nullptr;
  }
  Dart_LoadedElf* loaded = nullptr;
  const int64_t file_length = file->Length();
  uint8_t footer[kAotFooterSize];
  if (file_length < static_cast<int64_t>(kAotFooterSize) ||
      !file->SetPosition(file_length - kAotFooterSize) ||
      !file->ReadFully(footer, sizeof(footer))) {
    *error = "Cannot read the Dart addon footer";
  } else if (std::memcmp(footer, kAotMagic, sizeof(kAotMagic)) != 0) {
    *error = "The Dart addon does not contain an AOT snapshot";
  } else {
    const uint64_t offset = ReadLittleEndian64(footer + 8);
    const uint64_t length = ReadLittleEndian64(footer + 16);
    const uint64_t end = static_cast<uint64_t>(file_length) - kAotFooterSize;
    // Check subtraction before using it to reject overflowed or truncated data.
    if (offset < kAotAlignment || offset % kAotAlignment != 0 || offset > end ||
        length < 64 || length != end - offset) {
      *error = "The Dart addon contains an invalid AOT snapshot range";
    } else {
      loaded = LoadSnapshotFile(file, offset, length, data, text, error);
    }
  }
  file->Release();
  return loaded;
}

#endif

Dart_Isolate CreateGroup(const char* uri,
                         const char* name,
                         const char*,
                         const char* packages,
                         Dart_IsolateFlags* flags,
                         void* callback_data,
                         char** error) {
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
  const uint8_t* data = nullptr;
  const uint8_t* text = nullptr;
  const char* load_error = nullptr;
  group->snapshot = LoadSnapshot(uri, &data, &text, &load_error);
  if (group->snapshot == nullptr) {
    *error = dart::Utils::SCreate(
        "The uri(%s) provided to `Isolate.spawnUri()` does not contain a valid "
        "AOT ELF snapshot: %s.",
        uri, load_error == nullptr ? "Loading failed" : load_error);
    CleanupGroup(group);
    return nullptr;
  }
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

void Finalize(napi_env, void* data, void*) {
  ReleaseOwner(static_cast<Owner*>(data));
}

void Cleanup(void* data) {
  auto* owner = static_cast<Owner*>(data);
  auto* environment = owner->group->environment;
  owner->closing = true;
  Dart_EnterIsolate(owner->isolate);
  Dart_SetMessageNotifyCallback(nullptr);
  CloseEnvironment(environment);
  Dart_EnterScope();
  if (owner->initialize_started) Invoke(Dart_RootLibrary(), "dispose");
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
    ReleaseOwner(owner);
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

void InitializeVm(const char* path) {
  if (!PinModule()) {
    initialization_error = "Cannot retain the Dart runtime module";
    return;
  }
  script_uri = CopyString(path);
  if (script_uri == nullptr) {
    initialization_error = "Cannot allocate Dart runtime state";
    return;
  }
#if !defined(NAPI_RUNTIME_NO_REGEXP)
  dart::bin::SetupICU();
#endif
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
#if defined(__APPLE__)
  main_snapshot = dart::bin::Snapshot::TryReadAppendedAppSnapshot(path);
  if (main_snapshot == nullptr) {
    initialization_error = "Cannot load the embedded AOT snapshot";
    return;
  }
  main_snapshot->SetBuffers(&main_data, &main_text);
#else
  main_snapshot =
      LoadEmbeddedSnapshot(path, &main_data, &main_text, &initialization_error);
  if (main_snapshot == nullptr) return;
#endif
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
  const std::string message = Dart_GetError(error);
  Dart_ExitScope();
  Dart_ExitIsolate();
  Cleanup(owner);
  bool pending = false;
  if (napi_is_exception_pending(env, &pending) == napi_ok && pending) {
    return nullptr;
  }
  return ThrowError(env, message.c_str());
}

}  // namespace

napi_value Initialize(napi_env env,
                      napi_value exports,
                      const char* snapshot_path) {
  std::call_once(initialize_once, InitializeVm, snapshot_path);
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
  owner->env = env;
  owner->group = group;
  char* error = nullptr;
  owner->isolate =
      Dart_CreateIsolateGroup(script_uri, script_uri, main_data, main_text,
                              nullptr, group, owner, &error);
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
  const napi_node_version* version = nullptr;
  uint32_t napi_version = 0;
  napi_value global = nullptr;
  napi_value process = nullptr;
  napi_value version_value = nullptr;
  size_t version_length = 0;
  if (napi_get_node_version(env, &version) != napi_ok || version == nullptr ||
      napi_get_version(env, &napi_version) != napi_ok ||
      napi_get_global(env, &global) != napi_ok ||
      napi_get_named_property(env, global, "process", &process) != napi_ok ||
      napi_get_named_property(env, process, "version", &version_value) != napi_ok ||
      napi_get_value_string_utf8(env, version_value, nullptr, 0,
                                 &version_length) != napi_ok) {
    return FailInitialization(env, owner,
        Dart_NewApiError("Cannot determine the Node.js version"));
  }
  std::string version_text(version_length, '\0');
  if (napi_get_value_string_utf8(env, version_value, version_text.data(),
                                 version_length + 1, &version_length) != napi_ok) {
    return FailInitialization(env, owner,
        Dart_NewApiError("Cannot determine the Node.js version"));
  }
  Dart_Handle version_arguments[] = {
      Dart_NewInteger(version->major), Dart_NewInteger(version->minor),
      Dart_NewInteger(version->patch), Dart_NewInteger(napi_version),
      Dart_NewStringFromUTF8(
          reinterpret_cast<const uint8_t*>(version_text.data()), version_length)};
  result = Dart_Invoke(Dart_RootLibrary(),
      Dart_NewStringFromCString("validateNodeVersion"), 5, version_arguments);
  if (Dart_IsError(result)) return FailInitialization(env, owner, result);
  if (!Dart_IsNull(result)) {
    const char* message = nullptr;
    Dart_Handle decoded = Dart_StringToCString(result, &message);
    return FailInitialization(env, owner,
        Dart_IsError(decoded) ? decoded : Dart_NewApiError(message));
  }
  Dart_Handle arguments[] = {
      Dart_NewIntegerFromUint64(reinterpret_cast<uintptr_t>(env)),
      Dart_NewIntegerFromUint64(reinterpret_cast<uintptr_t>(exports)),
      Dart_NewIntegerFromUint64(reinterpret_cast<uintptr_t>(&CallJs)),
      Dart_NewIntegerFromUint64(reinterpret_cast<uintptr_t>(owner)),
      Dart_NewIntegerFromUint64(reinterpret_cast<uintptr_t>(&Finalize)),
      Dart_NewIntegerFromUint64(
          reinterpret_cast<uintptr_t>(&Dart_HasLivePorts)),
  };
  owner->initialize_started = true;
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
