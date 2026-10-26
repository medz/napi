#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <windows.h>

#include <bcrypt.h>
#define COMPILER_EXPORT extern "C" __declspec(dllexport)
#else
#define COMPILER_EXPORT extern "C" __attribute__((visibility("default")))
#endif

#include "include/dart_api.h"
#include "vm/dart_api_impl.h"
#include "vm/heap/heap.h"
#include "vm/native_arguments.h"
#include "vm/object.h"
#include "vm/thread.h"
#include "vm/visitor.h"

namespace {
std::mutex mutex;
bool initialized = false;
char* initialization_error = nullptr;

bool Entropy(uint8_t* buffer, intptr_t size) {
#if defined(_WIN32)
  if (size < 0 || static_cast<uint64_t>(size) > UINT32_MAX) return false;
  return BCryptGenRandom(nullptr, buffer, static_cast<ULONG>(size),
                         BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
#else
  FILE* source = fopen("/dev/urandom", "rb");
  if (source == nullptr) return false;
  const size_t count = fread(buffer, 1, size, source);
  fclose(source);
  return count == static_cast<size_t>(size);
#endif
}

FILE* OpenFile(const char* path, bool write) {
#if defined(_WIN32)
  const int length =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, nullptr, 0);
  if (length == 0) {
    errno = EINVAL;
    return nullptr;
  }
  std::vector<wchar_t> wide(length);
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide.data(),
                          length) == 0) {
    errno = EINVAL;
    return nullptr;
  }
  return _wfopen(wide.data(), write ? L"wb" : L"rb");
#else
  return fopen(path, write ? "wb" : "rb");
#endif
}

void Initialize() {
  const char* flags[] = {"--deterministic", "--precompilation",
                         "--target_unknown_cpu"};
  initialization_error = Dart_SetVMFlags(3, flags);
  if (initialization_error != nullptr) return;
  Dart_InitializeParams params = {};
  params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
  params.entropy_source = Entropy;
  params.start_kernel_isolate = false;
  initialization_error = Dart_Initialize(&params);
}

int Error(char** output, const char* message) {
  if (message == nullptr) message = "Unknown AOT compilation failure";
  if (output != nullptr) {
    const size_t size = strlen(message) + 1;
    *output = static_cast<char*>(malloc(size));
    if (*output != nullptr) memcpy(*output, message, size);
  }
  return 1;
}

class NativeRequirementsVisitor final : public dart::ObjectVisitor {
 public:
  NativeRequirementsVisitor(dart::Zone* zone, FILE* file)
      : zone_(zone), file_(file) {}
  void VisitFunction(const dart::Function& function) {
    if (!function.is_old_native()) return;
    const auto& owner = dart::Class::Handle(zone_, function.Owner());
    const auto& library = dart::Library::Handle(zone_, owner.library());
    const auto& url = dart::String::Handle(zone_, library.url());
    const auto& native = dart::String::Handle(zone_, function.native_name());
    std::string key = std::string(url.ToCString()) + "#" + native.ToCString();
    if (!seen_.insert(key).second) return;
    fprintf(file_, "%s\t%s\t%" Pd "\n", url.ToCString(), native.ToCString(),
            dart::NativeArguments::ParameterCountForResolution(function));
  }
  void VisitObject(dart::ObjectPtr object) override {
    if (!object->IsFunction()) return;
    const auto& function =
        dart::Function::Handle(zone_, dart::Function::RawCast(object));
    VisitFunction(function);
  }

 private:
  std::set<std::string> seen_;
  dart::Zone* zone_;
  FILE* file_;
};

int WriteNativeRequirements(const char* output, char** error) {
  std::string path = std::string(output) + ".natives.tsv";
  FILE* file = OpenFile(path.c_str(), true);
  if (file == nullptr) return Error(error, "Cannot open native requirements");
  auto* thread = dart::Thread::Current();
  dart::TransitionNativeToVM transition(thread);
  auto* zone = thread->zone();
  NativeRequirementsVisitor visitor(zone, file);
  thread->isolate_group()->heap()->CollectAllGarbage(dart::GCReason::kFull);
  dart::HeapIterationScope iteration(thread);
  iteration.IterateObjects(&visitor);
  return fclose(file) == 0 ? 0
                           : Error(error, "Cannot write native requirements");
}

struct Output {
  FILE* file;
  bool failed = false;
};

void Write(void* context, const uint8_t* buffer, intptr_t size) {
  auto* output = static_cast<Output*>(context);
  if (fwrite(buffer, 1, size, output->file) != static_cast<size_t>(size)) {
    output->failed = true;
  }
}
}  // namespace

COMPILER_EXPORT int napi_backend_compile(const char* input,
                                         const char* output,
                                         int format,
                                         char** error) {
  std::lock_guard<std::mutex> lock(mutex);
  if (error != nullptr) *error = nullptr;
  if (format < Dart_AotBinaryFormat_Elf ||
      format > Dart_AotBinaryFormat_PECoff_Obj) {
    return Error(error, "Unsupported snapshot format");
  }
  if (input == nullptr || output == nullptr || *input == '\0' ||
      *output == '\0') {
    return Error(error, "Missing path");
  }
  FILE* file = OpenFile(input, false);
  if (file == nullptr) return Error(error, strerror(errno));
  std::vector<uint8_t> kernel;
  uint8_t chunk[65536];
  size_t count;
  while ((count = fread(chunk, 1, sizeof(chunk), file)) > 0) {
    kernel.insert(kernel.end(), chunk, chunk + count);
  }
  const bool read_failed = ferror(file);
  fclose(file);
  if (read_failed) return Error(error, "Cannot read kernel");

  if (!initialized) {
    initialized = true;
    Initialize();
  }
  if (initialization_error != nullptr)
    return Error(error, initialization_error);
  Dart_IsolateFlags flags;
  Dart_IsolateFlagsInitialize(&flags);
  char* creation_error = nullptr;
  Dart_Isolate isolate = Dart_CreateIsolateGroupFromKernel(
      input, "compiler", kernel.data(), kernel.size(), &flags, nullptr, nullptr,
      &creation_error);
  if (isolate == nullptr) {
    const int status = Error(error, creation_error);
    free(creation_error);
    return status;
  }
  Dart_EnterScope();
  Dart_Handle result = Dart_LoadLibraryFromKernel(kernel.data(), kernel.size());
  if (!Dart_IsError(result)) result = Dart_SetRootLibrary(result);
  if (!Dart_IsError(result)) result = Dart_Precompile();
  int status = 0;
  if (Dart_IsError(result)) {
    status = Error(error, Dart_GetError(result));
  } else {
    status = WriteNativeRequirements(output, error);
    if (status != 0) {
      Dart_ExitScope();
      Dart_ShutdownIsolate();
      return status;
    }
    file = OpenFile(output, true);
    if (file == nullptr) {
      status = Error(error, strerror(errno));
    } else {
      Output stream = {file};
      result = Dart_CreateAppAOTSnapshotAsBinary(
          static_cast<Dart_AotBinaryFormat>(format), Write, &stream, true,
          nullptr, output, output);
      if (Dart_IsError(result)) status = Error(error, Dart_GetError(result));
      const int close_status = fclose(file);
      if (status == 0 && (stream.failed || close_status != 0)) {
        status = Error(error, "Cannot write snapshot");
      }
    }
  }
  Dart_ExitScope();
  Dart_ShutdownIsolate();
  return status;
}

COMPILER_EXPORT void napi_backend_free(char* error) {
  free(error);
}
