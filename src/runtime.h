#ifndef NAPI_RUNTIME_H_
#define NAPI_RUNTIME_H_

#include <node_api.h>

#include <cstdint>
#include <cstdio>

namespace napi_dart {

// The caller keeps file open until initialization has finished.
napi_value Initialize(napi_env env, napi_value exports,
                      const char* snapshot_path, FILE* file,
                      uint64_t snapshot_offset, uint64_t snapshot_size);

}  // namespace napi_dart

#endif  // NAPI_RUNTIME_H_
