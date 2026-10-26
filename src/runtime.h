#ifndef NAPI_RUNTIME_H_
#define NAPI_RUNTIME_H_

#include <node_api.h>

namespace napi_dart {

napi_value Initialize(napi_env env,
                      napi_value exports,
                      const char* snapshot_path);

}  // namespace napi_dart

#endif  // NAPI_RUNTIME_H_
