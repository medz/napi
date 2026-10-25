#include <node_api.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include "runtime.h"

namespace {

constexpr uint64_t kAlignment = 65536;
constexpr size_t kFooterSize = 32;
constexpr char kMagic[] = "NAPI AOT";

uint64_t ReadLittleEndian(const uint8_t* bytes, size_t length) {
  uint64_t value = 0;
  for (size_t i = 0; i < length; ++i) {
    value |= static_cast<uint64_t>(bytes[i]) << (i * 8);
  }
  return value;
}

bool Seek(FILE* file, int64_t offset, int origin) {
#if defined(_WIN32)
  return _fseeki64(file, offset, origin) == 0;
#else
  return fseeko(file, offset, origin) == 0;
#endif
}

int64_t Position(FILE* file) {
#if defined(_WIN32)
  return _ftelli64(file);
#else
  return ftello(file);
#endif
}

FILE* OpenAddon(std::string* path) {
#if defined(_WIN32)
  HMODULE module = nullptr;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                             GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                         reinterpret_cast<LPCWSTR>(&OpenAddon), &module)) {
    return nullptr;
  }
  wchar_t filename[32768];
  const DWORD length = GetModuleFileNameW(module, filename, 32768);
  if (length == 0 || length >= 32768) return nullptr;
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, filename,
                                     length, nullptr, 0, nullptr, nullptr);
  if (size <= 0) return nullptr;
  path->resize(size);
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, filename, length,
                          &(*path)[0], size, nullptr, nullptr) != size) {
    return nullptr;
  }
  return _wfopen(filename, L"rb");
#else
  Dl_info info{};
  if (!dladdr(reinterpret_cast<const void*>(&OpenAddon), &info) ||
      info.dli_fname == nullptr) {
    return nullptr;
  }
  *path = info.dli_fname;
  return fopen(path->c_str(), "rb");
#endif
}

bool SnapshotLocation(FILE* file, uint64_t* offset, uint64_t* snapshot_size) {
  if (!Seek(file, 0, SEEK_END)) return false;
  const int64_t length = Position(file);
  if (length < static_cast<int64_t>(kFooterSize) ||
      !Seek(file, -static_cast<int64_t>(kFooterSize), SEEK_END)) {
    return false;
  }
  uint8_t footer[kFooterSize];
  if (fread(footer, 1, sizeof(footer), file) != sizeof(footer) ||
      memcmp(footer, kMagic, 8) != 0 ||
      ReadLittleEndian(footer + 8, 4) != 1 ||
      ReadLittleEndian(footer + 12, 4) != 0) {
    return false;
  }
  const uint64_t start = ReadLittleEndian(footer + 16, 8);
  const uint64_t size = ReadLittleEndian(footer + 24, 8);
  const uint64_t end = static_cast<uint64_t>(length) - kFooterSize;
  if (start == 0 || start % kAlignment != 0 || start > end ||
      size != end - start || size < 4 ||
      !Seek(file, static_cast<int64_t>(start), SEEK_SET)) {
    return false;
  }
  uint8_t magic[4];
  if (fread(magic, 1, sizeof(magic), file) != sizeof(magic) ||
      memcmp(magic, "\x7f" "ELF", 4) != 0) {
    return false;
  }
  *offset = start;
  *snapshot_size = size;
  return true;
}

}  // namespace

NAPI_MODULE_INIT() {
  std::string path;
  FILE* file = OpenAddon(&path);
  if (file == nullptr) {
    napi_throw_error(env, nullptr, "Cannot open the Dart addon file");
    return nullptr;
  }
  uint64_t offset = 0;
  uint64_t size = 0;
  const bool valid = SnapshotLocation(file, &offset, &size);
  if (!valid) {
    fclose(file);
    napi_throw_error(env, nullptr, "Missing or invalid embedded Dart AOT snapshot");
    return nullptr;
  }
  napi_value result =
      napi_dart::Initialize(env, exports, path.c_str(), file, offset, size);
  fclose(file);
  return result;
}
