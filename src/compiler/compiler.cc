#include "compiler.h"

#include <array>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#include <unistd.h>
#endif

#include "../image.h"

namespace {
namespace fs = std::filesystem;

using Frontend = int (*)(const char*,
                         const char*,
                         const char*,
                         const char*,
                         const char*,
                         const char*,
                         const char*,
                         char**);
using Backend = int (*)(const char*, const char*, int, char**);
using Free = void (*)(char*);

std::mutex compile_mutex;

std::string Utf8(const fs::path& path) {
  const auto value = path.u8string();
  return {value.begin(), value.end()};
}

fs::path Path(const char* utf8) {
  return fs::path(std::u8string(utf8, utf8 + std::strlen(utf8)));
}

int Error(char** output, const std::string& message) {
  if (output != nullptr) {
    *output = static_cast<char*>(std::malloc(message.size() + 1));
    if (*output != nullptr) {
      std::memcpy(*output, message.c_str(), message.size() + 1);
    }
  }
  return 1;
}

fs::path LibraryDirectory() {
#if defined(_WIN32)
  HMODULE module = nullptr;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                              GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          reinterpret_cast<LPCWSTR>(&napi_compile), &module)) {
    return {};
  }
  wchar_t path[32768];
  const DWORD length = GetModuleFileNameW(module, path, 32768);
  if (length == 0 || length == 32768) return {};
  return fs::path(path).parent_path();
#else
  Dl_info info{};
  if (dladdr(reinterpret_cast<void*>(&napi_compile), &info) == 0 ||
      info.dli_fname == nullptr) {
    return {};
  }
  std::error_code error;
  return fs::absolute(info.dli_fname, error).parent_path();
#endif
}

void* OpenLibrary(const fs::path& path, std::string* error) {
#if defined(_WIN32)
  auto library = LoadLibraryExW(
      path.c_str(), nullptr,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  if (library == nullptr) {
    *error = "Cannot load " + Utf8(path) + " (Windows error " +
             std::to_string(GetLastError()) + ")";
  }
  return reinterpret_cast<void*>(library);
#else
  void* library = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (library == nullptr) {
    const char* detail = dlerror();
    *error = detail == nullptr ? "Cannot load " + Utf8(path) : detail;
  }
  return library;
#endif
}

template <typename T>
bool Symbol(void* library, const char* name, T* value, std::string* error) {
#if defined(_WIN32)
  *value = reinterpret_cast<T>(
      GetProcAddress(reinterpret_cast<HMODULE>(library), name));
#else
  *value = reinterpret_cast<T>(dlsym(library, name));
#endif
  if (*value != nullptr) return true;
  *error = std::string("The bundled SDK is missing ") + name;
  return false;
}

struct Sdk {
  fs::path directory;
  Frontend frontend = nullptr;
  Backend backend = nullptr;
#if defined(__APPLE__)
  using Package = int (*)(const char*, const char*, const char*, const char*, char**);
  Package package = nullptr;
#endif
  Free frontend_free = nullptr;
  Free backend_free = nullptr;
  std::string error;

  Sdk() {
    directory = LibraryDirectory();
    if (directory.empty()) {
      error = "Cannot locate the bundled Dart SDK library";
      return;
    }
#if defined(_WIN32)
    const char* extension = ".dll";
#elif defined(__APPLE__)
    const char* extension = ".dylib";
#else
    const char* extension = ".so";
#endif
    void* front =
        OpenLibrary(directory / (std::string("frontend") + extension), &error);
    if (front == nullptr) return;
    void* back =
        OpenLibrary(directory / (std::string("backend") + extension), &error);
    if (back == nullptr) return;
    if (!Symbol(front, "napi_frontend_compile", &frontend, &error) ||
        !Symbol(front, "napi_frontend_free", &frontend_free, &error) ||
        !Symbol(back, "napi_backend_compile", &backend, &error) ||
        !Symbol(back, "napi_backend_free", &backend_free, &error)) {
      return;
    }
#if defined(__APPLE__)
    if (!Symbol(front, "napi_frontend_package", &package, &error)) return;
#endif
    for (const char* resource :
         {"frontend.aot", "platform.dill", "runtime.node", "runtime-core.node",
          "runtime-regexp.node"}) {
      std::error_code status;
      if (!fs::is_regular_file(directory / resource, status)) {
        error = std::string("The bundled SDK is missing ") + resource;
        return;
      }
    }
    // Both private VMs retain process-wide state. Their libraries remain loaded.
  }
};

struct Workspace {
  fs::path path;
  bool preserve = false;

  ~Workspace() {
    if (path.empty() || preserve) return;
    std::error_code ignored;
    fs::remove_all(path, ignored);
  }

  bool Create(const fs::path& parent, std::string* error) {
    static std::atomic<uint64_t> sequence{0};
#if defined(_WIN32)
    const auto process = GetCurrentProcessId();
#else
    const auto process = getpid();
#endif
    for (int attempt = 0; attempt < 100; ++attempt) {
      const fs::path candidate =
          parent / (".napi-" + std::to_string(process) + "-" +
                    std::to_string(sequence.fetch_add(1)));
      std::error_code status;
      if (fs::create_directory(candidate, status)) {
        path = candidate;
        return true;
      }
      if (status && status != std::errc::file_exists) {
        *error = "Cannot create compiler workspace: " + status.message();
        return false;
      }
    }
    *error = "Cannot allocate a compiler workspace";
    return false;
  }
};

bool SelectRuntime(const fs::path& kernel,
                   const fs::path& snapshot,
                   std::string* name,
                   std::string* error) {
  fs::path capabilities_path = kernel;
  capabilities_path += ".runtime";
  std::ifstream capabilities(capabilities_path);
  std::string profile;
  if (!std::getline(capabilities, profile) ||
      (profile != "core" && profile != "full")) {
    *error = "The Dart frontend did not report runtime requirements";
    return false;
  }
  fs::path natives_path = snapshot;
  natives_path += ".natives.tsv";
  std::ifstream natives(natives_path);
  if (!natives) {
    *error = "The Dart backend did not report native requirements";
    return false;
  }
  std::string line;
  while (std::getline(natives, line)) {
    const auto start = line.find('\t');
    const auto end = start == std::string::npos ? std::string::npos
                                                : line.find('\t', start + 1);
    if (start == std::string::npos || end == std::string::npos) {
      *error = "The Dart backend reported invalid native requirements";
      return false;
    }
    const std::string native = line.substr(start + 1, end - start - 1);
    if (native.starts_with("SecureSocket") ||
        native.starts_with("SecurityContext") || native.starts_with("X509")) {
      profile = "full";
    } else if (profile == "core" && native.starts_with("RegExp")) {
      profile = "regexp";
    }
  }
  if (natives.bad()) {
    *error = "Cannot read native requirements";
    return false;
  }
  *name = profile == "full" ? "runtime.node" : "runtime-" + profile + ".node";
  return true;
}

#if !defined(__APPLE__)
bool AppendSnapshot(const fs::path& runtime,
                    const fs::path& snapshot,
                    const fs::path& output,
                    std::string* error) {
  std::error_code status;
  const uint64_t runtime_size = fs::file_size(runtime, status);
  if (status) {
    *error = "Cannot read the bundled runtime: " + status.message();
    return false;
  }
  const uint64_t snapshot_size = fs::file_size(snapshot, status);
  if (status || snapshot_size < 64) {
    *error = "The Dart SDK did not produce a valid AOT image";
    return false;
  }
  const uint64_t offset = (runtime_size + napi_dart::kAotAlignment - 1) &
                          ~(napi_dart::kAotAlignment - 1);
  std::ifstream input(snapshot, std::ios::binary);
  std::ifstream base(runtime, std::ios::binary);
  std::ofstream result(output, std::ios::binary | std::ios::trunc);
  if (!input || !base || !result) {
    *error = "Cannot open the native output image";
    return false;
  }
  result << base.rdbuf();
  if (!result || base.bad()) {
    *error = "Cannot copy the bundled runtime";
    return false;
  }
  result.seekp(static_cast<std::streamoff>(offset));
  result << input.rdbuf();
  uint8_t footer[napi_dart::kAotFooterSize] = {};
  std::memcpy(footer, napi_dart::kAotMagic, sizeof(napi_dart::kAotMagic));
  napi_dart::WriteLittleEndian64(footer + 8, offset);
  napi_dart::WriteLittleEndian64(footer + 16, snapshot_size);
  result.write(reinterpret_cast<const char*>(footer), sizeof(footer));
  result.close();
  if (!result || input.bad()) {
    *error = "Cannot write the native output image";
    return false;
  }
  return true;
}

#endif

bool ReplaceOutput(const fs::path& candidate,
                   const fs::path& output,
                   std::string* error) {
#if defined(_WIN32)
  if (MoveFileExW(candidate.c_str(), output.c_str(),
                  MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    return true;
  }
  *error = "Cannot replace " + Utf8(output) + " (Windows error " +
           std::to_string(GetLastError()) + ")";
  return false;
#else
  std::error_code status;
  fs::rename(candidate, output, status);
  if (!status) return true;
  *error = "Cannot replace " + Utf8(output) + ": " + status.message();
  return false;
#endif
}

bool InspectOutput(const fs::path& path, std::string* error) {
  std::error_code status;
  const auto type = fs::symlink_status(path, status);
  if (status && status != std::errc::no_such_file_or_directory) {
    *error = "Cannot inspect " + Utf8(path) + ": " + status.message();
    return false;
  }
  if (fs::exists(type) && !fs::is_regular_file(type)) {
    *error = "Output must be a regular file: " + Utf8(path);
    return false;
  }
  return true;
}

bool DifferentFiles(const fs::path& left,
                     const fs::path& right,
                     std::string* error) {
  std::error_code status;
  const bool left_exists = fs::exists(left, status);
  if (status) {
    *error = "Cannot inspect " + Utf8(left) + ": " + status.message();
    return false;
  }
  const bool right_exists = fs::exists(right, status);
  if (status) {
    *error = "Cannot inspect " + Utf8(right) + ": " + status.message();
    return false;
  }
  const bool equivalent =
      left_exists && right_exists && fs::equivalent(left, right, status);
  if (status) {
    *error = "Cannot compare output paths: " + status.message();
    return false;
  }
  status.clear();
  const auto first = fs::weakly_canonical(left, status);
  if (status) {
    *error = "Cannot resolve " + Utf8(left) + ": " + status.message();
    return false;
  }
  const auto second = fs::weakly_canonical(right, status);
  if (status) {
    *error = "Cannot resolve " + Utf8(right) + ": " + status.message();
    return false;
  }
  if (equivalent || first == second) {
    *error = "Entry and output paths must refer to different files: " +
             Utf8(left) + " and " + Utf8(right);
    return false;
  }
  return true;
}

struct PendingOutput {
  fs::path candidate;
  fs::path destination;
  fs::path backup;
  Workspace* workspace;
  bool backed_up = false;
  bool installed = false;
};

bool CommitOutputs(std::array<PendingOutput, 2>& outputs,
                    std::string* error) {
  auto rollback = [&] {
    for (auto it = outputs.rbegin(); it != outputs.rend(); ++it) {
      std::string detail;
      if (it->backed_up) {
        if (!ReplaceOutput(it->backup, it->destination, &detail)) {
          it->workspace->preserve = true;
          *error += "; original retained at " + Utf8(it->backup) + ": " + detail;
        }
      } else if (it->installed) {
        std::error_code status;
        fs::remove(it->destination, status);
        if (status) {
          *error += "; cannot remove incomplete output " +
                    Utf8(it->destination) + ": " + status.message();
        }
      }
    }
  };
  for (auto& output : outputs) {
    std::error_code status;
    const bool exists = fs::exists(output.destination, status);
    if (status) {
      *error = "Cannot inspect " + Utf8(output.destination) + ": " +
               status.message();
      rollback();
      return false;
    }
    if (exists) {
      if (!ReplaceOutput(output.destination, output.backup, error)) {
        rollback();
        return false;
      }
      output.backed_up = true;
    }
  }
  for (auto& output : outputs) {
    if (!ReplaceOutput(output.candidate, output.destination, error)) {
      rollback();
      return false;
    }
    output.installed = true;
  }
  return true;
}

int Compile(const char* entry,
             const char* output,
             const char* packages,
             const char* node,
             const char* declarations,
             char** error) {
  std::lock_guard<std::mutex> lock(compile_mutex);
  if (error != nullptr) *error = nullptr;
  if (entry == nullptr || output == nullptr || *entry == '\0' ||
      *output == '\0') {
    return Error(error, "Entry and output paths are required");
  }
  if (node != nullptr && *node == '\0') {
    return Error(error, "The Node.js version constraint must not be empty");
  }
  std::error_code status;
  const fs::path source = fs::canonical(Path(entry), status);
  if (status || !fs::is_regular_file(source, status)) {
    return Error(error, "The Dart entry must be an existing file");
  }
  const fs::path destination = fs::absolute(Path(output), status);
  if (status || destination.extension() != ".node") {
    return Error(error, "Native output must be a .node file");
  }
  std::string message;
  if (!InspectOutput(destination, &message) ||
      !DifferentFiles(source, destination, &message)) {
    return Error(error, message);
  }
  fs::path declaration_path;
  if (declarations != nullptr) {
    declaration_path = fs::absolute(Path(declarations), status);
    if (status || !Utf8(declaration_path.filename()).ends_with(".d.ts")) {
      return Error(error, "Declarations output must be a .d.ts file");
    }
    if (!InspectOutput(declaration_path, &message) ||
        !DifferentFiles(source, declaration_path, &message) ||
        !DifferentFiles(destination, declaration_path, &message)) {
      return Error(error, message);
    }
  }
  static Sdk sdk;
  if (!sdk.error.empty()) return Error(error, sdk.error);
  fs::create_directories(destination.parent_path(), status);
  if (status)
    return Error(error, "Cannot create output directory: " + status.message());
  if (declarations != nullptr) {
    fs::create_directories(declaration_path.parent_path(), status);
    if (status) {
      return Error(error, "Cannot create declarations directory: " +
                              status.message());
    }
  }
  Workspace workspace;
  if (!workspace.Create(destination.parent_path(), &message)) {
    return Error(error, message);
  }
  Workspace declaration_workspace;
  if (declarations != nullptr &&
      !declaration_workspace.Create(declaration_path.parent_path(), &message)) {
    return Error(error, message);
  }
  const std::string input = Utf8(source);
  std::string package_path;
  if (packages == nullptr) {
    for (fs::path directory = source.parent_path(); !directory.empty();) {
      const fs::path config = directory / ".dart_tool" / "package_config.json";
      status.clear();
      if (fs::is_regular_file(config, status)) {
        package_path = Utf8(config);
        packages = package_path.c_str();
        break;
      }
      const fs::path parent = directory.parent_path();
      if (parent == directory) break;
      directory = parent;
    }
  }
  const std::string frontend = Utf8(sdk.directory / "frontend.aot");
  const std::string platform = Utf8(sdk.directory / "platform.dill");
  const std::string kernel = Utf8(workspace.path / "app.dill");
  const std::string snapshot = Utf8(workspace.path / "app.aot");
#if defined(_WIN32)
  const char* target_os = "windows";
#elif defined(__APPLE__)
  const char* target_os = "macos";
#else
  const char* target_os = "linux";
#endif
  char* component_error = nullptr;
  int result =
      sdk.frontend(frontend.c_str(), input.c_str(), packages, platform.c_str(),
                   target_os, kernel.c_str(), node, &component_error);
  if (result != 0) {
    message =
        component_error == nullptr ? "Dart frontend failed" : component_error;
    sdk.frontend_free(component_error);
    return Error(error, message);
  }
  const fs::path declaration_candidate =
      declaration_workspace.path / "bindings.d.ts";
  if (declarations != nullptr) {
    const fs::path generated = workspace.path / "app.dill.d.ts";
    if (!fs::is_regular_file(generated, status)) {
      return Error(error,
                   "TypeScript declarations require annotation-based exports");
    }
    if (!fs::copy_file(generated, declaration_candidate, status)) {
      return Error(error, "Cannot read generated declarations: " +
                              status.message());
    }
  }
  // Dart's own ELF writer emits the machine code; no assembler is involved.
  result = sdk.backend(kernel.c_str(), snapshot.c_str(), 0, &component_error);
  if (result != 0) {
    message = component_error == nullptr ? "Dart AOT compilation failed"
                                         : component_error;
    sdk.backend_free(component_error);
    return Error(error, message);
  }
  const fs::path candidate = workspace.path / "addon.node";
  std::string runtime;
  if (!SelectRuntime(workspace.path / "app.dill", workspace.path / "app.aot",
                     &runtime, &message)) {
    return Error(error, message);
  }
#if defined(__APPLE__)
  const std::string image = Utf8(candidate);
  const std::string runtime_path = Utf8(sdk.directory / runtime);
  result = sdk.package(frontend.c_str(), runtime_path.c_str(), snapshot.c_str(),
                        image.c_str(), &component_error);
  if (result != 0) {
    message = component_error == nullptr ? "Mach-O image generation failed"
                                         : component_error;
    sdk.frontend_free(component_error);
    return Error(error, message);
  }
#else
  if (!AppendSnapshot(sdk.directory / runtime, workspace.path / "app.aot",
                      candidate, &message)) {
    return Error(error, message);
  }
#endif
  if (declarations == nullptr) {
    if (!ReplaceOutput(candidate, destination, &message)) {
      return Error(error, message);
    }
  } else {
    if (!InspectOutput(destination, &message) ||
        !InspectOutput(declaration_path, &message) ||
        !DifferentFiles(source, destination, &message) ||
        !DifferentFiles(source, declaration_path, &message) ||
        !DifferentFiles(destination, declaration_path, &message)) {
      return Error(error, message);
    }
    std::array<PendingOutput, 2> outputs = {{
        {candidate, destination, workspace.path / "previous.node", &workspace},
        {declaration_candidate, declaration_path,
         declaration_workspace.path / "previous.d.ts", &declaration_workspace},
    }};
    if (!CommitOutputs(outputs, &message)) return Error(error, message);
  }
  return 0;
}

}  // namespace

NAPI_COMPILER_EXPORT int napi_compile(const char* entry,
                                      const char* output,
                                      const char* packages,
                                      const char* node,
                                      char** error) {
  return Compile(entry, output, packages, node, nullptr, error);
}

NAPI_COMPILER_EXPORT int napi_compile_declarations(const char* entry,
                                                   const char* output,
                                                   const char* packages,
                                                   const char* node,
                                                   const char* declarations,
                                                   char** error) {
  if (error != nullptr) *error = nullptr;
  if (declarations == nullptr || *declarations == '\0') {
    return Error(error, "Declarations output path is required");
  }
  return Compile(entry, output, packages, node, declarations, error);
}

NAPI_COMPILER_EXPORT void napi_compiler_free(char* error) {
  std::free(error);
}
