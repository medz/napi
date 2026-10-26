#ifndef NAPI_COMPILER_H_
#define NAPI_COMPILER_H_

#if defined(_WIN32)
#define NAPI_COMPILER_EXPORT extern "C" __declspec(dllexport)
#else
#define NAPI_COMPILER_EXPORT extern "C" __attribute__((visibility("default")))
#endif

struct NapiCompileOptions {
  const char* entry;
  const char* output;
  const char* packages;
  const char* node;
  const char* declarations;
};

// Paths, metadata and errors use UTF-8. Null packages enables discovery;
// null declarations skips .d.ts output. Null metadata skips reading the report.
// The caller releases returned metadata and errors with napi_compiler_free().
NAPI_COMPILER_EXPORT int napi_compile(const NapiCompileOptions* options,
                                      char** metadata,
                                      char** error);
NAPI_COMPILER_EXPORT void napi_compiler_free(char* value);

#endif  // NAPI_COMPILER_H_
