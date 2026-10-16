// Stable maintainer identity; deliberately independent of the final binary SHA.
#include "runtime.h"
#ifndef NAPI_DART_RUNTIME_ID
#error NAPI_DART_RUNTIME_ID must identify this maintainer runtime build
#endif
NAPI_DART_EXPORT const char* NapiDart_RuntimeIdentity() {
  return NAPI_DART_RUNTIME_ID;
}
