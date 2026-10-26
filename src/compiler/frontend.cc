#include <cstdlib>
#include <cstring>
#include <mutex>

#include "bin/dartutils.h"
#include "bin/elf_loader.h"
#include "bin/icu.h"
#include "bin/platform.h"
#include "include/bin/dart_io_api.h"
#include "include/dart_api.h"

#if defined(_WIN32)
#define NAPI_COMPILER_EXPORT extern "C" __declspec(dllexport)
#else
#define NAPI_COMPILER_EXPORT extern "C" __attribute__((visibility("default")))
#endif

namespace {

std::mutex mutex;
bool initialized = false;
const char* initialization_error = nullptr;
const uint8_t* snapshot_data = nullptr;
const uint8_t* snapshot_text = nullptr;
Dart_LoadedElf* snapshot = nullptr;
char executable[32768];

int Error(char** error, const char* message) {
  if (error != nullptr) {
    if (message == nullptr) message = "Unknown frontend failure";
    const size_t size = std::strlen(message) + 1;
    *error = static_cast<char*>(std::malloc(size));
    if (*error != nullptr) std::memcpy(*error, message, size);
  }
  return 1;
}

void Initialize(const char* aot) {
  snapshot = Dart_LoadELF(aot, 0, &initialization_error, &snapshot_data,
                          &snapshot_text);
  if (snapshot == nullptr) return;
  dart::bin::SetupICU();
  if (!dart::bin::Platform::Initialize(false) ||
      dart::bin::Platform::ResolveExecutablePathInto(executable,
                                                     sizeof(executable)) < 0) {
    initialization_error = "Cannot initialize frontend platform";
    return;
  }
  dart::bin::Platform::SetExecutableName(executable);
  if (!dart::bin::DartUtils::SetOriginalWorkingDirectory()) {
    initialization_error = "Cannot determine working directory";
    return;
  }
  dart::bin::BootstrapDartIo();
  const char* flags[] = {"--precompilation"};
  initialization_error = Dart_SetVMFlags(1, flags);
  if (initialization_error != nullptr) return;
  Dart_InitializeParams params = {};
  params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  params.file_open = dart::bin::OpenFile;
  params.file_read = dart::bin::ReadFile;
  params.file_write = dart::bin::WriteFile;
  params.file_close = dart::bin::CloseFile;
  params.entropy_source = dart::bin::GetEntropy;
  params.start_kernel_isolate = false;
  initialization_error = Dart_Initialize(&params);
}

int RunFrontend(const char* aot, const char* entry_point, int argument_count,
                const char* const* argument_values, char** error) {
  std::lock_guard<std::mutex> lock(mutex);
  if (error != nullptr) *error = nullptr;
  if (!aot || !entry_point || argument_count < 0) {
    return Error(error, "Missing frontend path or configuration");
  }
  if (!initialized) {
    initialized = true;
    Initialize(aot);
  }
  if (initialization_error != nullptr)
    return Error(error, initialization_error);

  char* creation_error = nullptr;
  Dart_Isolate isolate =
      Dart_CreateIsolateGroup(aot, "frontend", snapshot_data, snapshot_text,
                              nullptr, nullptr, nullptr, &creation_error);
  if (isolate == nullptr) {
    const int status = Error(error, creation_error);
    std::free(creation_error);
    return status;
  }
  Dart_EnterScope();
  dart::bin::DartIoSettings settings;
  settings.script_uri = aot;
  settings.disable_exit = true;
  settings.enable_network_profiling = false;
  Dart_Handle result =
      dart::bin::DartUtils::SetupCoreLibraries(false, false, false, settings);
  if (Dart_IsError(result)) {
    const int status = Error(error, Dart_GetError(result));
    Dart_ExitScope();
    Dart_ShutdownIsolate();
    return status;
  }
  Dart_ExitScope();
  Dart_ExitIsolate();
  creation_error = Dart_IsolateMakeRunnable(isolate);
  Dart_EnterIsolate(isolate);
  if (creation_error != nullptr) {
    const int status = Error(error, creation_error);
    std::free(creation_error);
    Dart_ShutdownIsolate();
    return status;
  }
  Dart_EnterScope();
  dart::bin::CommandLineOptions arguments(argument_count);
  for (int i = 0; i < argument_count; ++i) {
    arguments.AddArgument(argument_values[i]);
  }
  result = arguments.CreateRuntimeOptions();
  if (!Dart_IsError(result)) {
    Dart_Handle main =
        Dart_GetField(Dart_RootLibrary(), Dart_NewStringFromCString(entry_point));
    if (Dart_IsError(main)) {
      result = main;
    } else {
      Dart_Handle args[] = {main, result};
      result = Dart_Invoke(
          Dart_LookupLibrary(Dart_NewStringFromCString("dart:isolate")),
          Dart_NewStringFromCString("_startMainIsolate"), 2, args);
    }
  }
  if (!Dart_IsError(result)) result = Dart_RunLoop();
  if (!Dart_IsError(result)) {
    result = Dart_Invoke(Dart_RootLibrary(),
                         Dart_NewStringFromCString("result"), 0, nullptr);
  }
  int status = 0;
  if (Dart_IsError(result)) {
    status = Error(error, Dart_GetError(result));
  } else if (!Dart_IsNull(result)) {
    const char* message = nullptr;
    Dart_Handle decoded = Dart_StringToCString(result, &message);
    status =
        Error(error, Dart_IsError(decoded) ? Dart_GetError(decoded) : message);
  }
  Dart_ExitScope();
  Dart_ShutdownIsolate();
  return status;
}

}  // namespace

NAPI_COMPILER_EXPORT int napi_frontend_compile(const char* aot,
                                               const char* entry,
                                               const char* packages,
                                               const char* platform,
                                               const char* target_os,
                                               const char* output,
                                               const char* node,
                                               char** error) {
  if (!entry || !platform || !target_os || !output) {
    return Error(error, "Missing frontend path or configuration");
  }
  const char* arguments[] = {entry, packages == nullptr ? "" : packages,
                             platform, target_os, output,
                             node == nullptr ? "" : node};
  return RunFrontend(aot, "main", 6, arguments, error);
}

#if defined(__APPLE__)
NAPI_COMPILER_EXPORT int napi_frontend_package(const char* aot,
                                               const char* runtime,
                                               const char* snapshot_path,
                                               const char* output,
                                               char** error) {
  if (!runtime || !snapshot_path || !output) {
    return Error(error, "Missing Mach-O image path or configuration");
  }
  const char* arguments[] = {runtime, snapshot_path, output};
  return RunFrontend(aot, "packageMac", 3, arguments, error);
}
#endif

NAPI_COMPILER_EXPORT void napi_frontend_free(char* error) {
  std::free(error);
}
