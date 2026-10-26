#ifndef NAPI_DART_IMAGE_H_
#define NAPI_DART_IMAGE_H_

#include <cstddef>
#include <cstdint>

namespace napi_dart {

inline constexpr uint8_t kAotMagic[8] = {'N', 'A', 'P', 'I', 'A', 'O', 'T', 0};
inline constexpr size_t kAotFooterSize = 24;
inline constexpr uint64_t kAotAlignment = 65536;

inline uint64_t ReadLittleEndian64(const uint8_t* bytes) {
  uint64_t value = 0;
  for (size_t i = 0; i < 8; ++i)
    value |= uint64_t{bytes[i]} << (i * 8);
  return value;
}

inline void WriteLittleEndian64(uint8_t* bytes, uint64_t value) {
  for (size_t i = 0; i < 8; ++i)
    bytes[i] = static_cast<uint8_t>(value >> (i * 8));
}

}  // namespace napi_dart

#endif  // NAPI_DART_IMAGE_H_
