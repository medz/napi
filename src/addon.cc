#include <node_api.h>

#include <string>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include "runtime.h"

namespace {

bool ModulePath(std::string* path) {
#if defined(_WIN32)
  HMODULE module = nullptr;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                              GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          reinterpret_cast<LPCWSTR>(&ModulePath), &module)) {
    return false;
  }
  wchar_t filename[32768];
  const DWORD length = GetModuleFileNameW(module, filename, 32768);
  if (length == 0 || length >= 32768) return false;
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, filename,
                                       length, nullptr, 0, nullptr, nullptr);
  if (size <= 0) return false;
  path->resize(size);
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, filename, length,
                          &(*path)[0], size, nullptr, nullptr) != size) {
    return false;
  }
  return true;
#else
  Dl_info info{};
  if (!dladdr(reinterpret_cast<const void*>(&ModulePath), &info) ||
      info.dli_fname == nullptr) {
    return false;
  }
  *path = info.dli_fname;
  return true;
#endif
}

}  // namespace

extern "C" NAPI_MODULE_EXPORT napi_value napi_register_module_v1(
    napi_env env, napi_value exports) {
  std::string path;
  if (!ModulePath(&path)) {
    napi_throw_error(env, nullptr, "Cannot locate the Dart addon file");
    return nullptr;
  }
  return napi_dart::Initialize(env, exports, path.c_str());
}
