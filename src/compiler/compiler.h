#ifndef NAPI_COMPILER_H_
#define NAPI_COMPILER_H_

#if defined(_WIN32)
#define NAPI_COMPILER_EXPORT extern "C" __declspec(dllexport)
#else
#define NAPI_COMPILER_EXPORT extern "C" __attribute__((visibility("default")))
#endif

// Paths and errors use UTF-8. A null package configuration enables discovery.
// The caller releases a returned error with napi_compiler_free().
NAPI_COMPILER_EXPORT int napi_compile(const char* entry,
                                      const char* output,
                                      const char* packages,
                                      const char* node,
                                      char** error);
NAPI_COMPILER_EXPORT int napi_compile_declarations(const char* entry,
                                                   const char* output,
                                                   const char* packages,
                                                   const char* node,
                                                   const char* declarations,
                                                   char** error);
NAPI_COMPILER_EXPORT void napi_compiler_free(char* error);

#endif  // NAPI_COMPILER_H_
