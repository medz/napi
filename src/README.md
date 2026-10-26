# Building the compiler SDK

The native compiler uses Dart SDK **3.13.5**, revision
`04bcd1036cdc799ac6564988f159ee454d42c822`. Compiler libraries, `frontend.aot`,
`platform.dill` and runtime images must be rebuilt and distributed together.
The SDK under `tools/sdks/dart-sdk` must also be this version.

Prepare the SDK checkout and its dependencies using the
[Dart SDK build instructions](https://github.com/dart-lang/sdk/wiki/Building).
Apply the patches in this directory's `patches/` folder, then link this repository
into the SDK checkout as `napi_compiler`. Set `napi_node_headers` to the Node.js
24.19.0 public header directory containing `node_api.h`.

For Linux arm64, run from the SDK checkout:

```sh
buildtools/gn gen out/Napi --root-target=//napi_compiler:compiler --args='
  target_os="linux"
  host_cpu="arm64"
  target_cpu="arm64"
  dart_target_arch="arm64"
  is_debug=false
  is_release=false
  is_product=true
  dart_debug=false
  dart_runtime_mode="profile"
  dart_use_compressed_pointers=false
  use_rbe=false
  napi_node_headers="/path/to/node/include/node"
'
buildtools/ninja/ninja -C out/Napi napi_compiler:compiler
python3 napi_compiler/tool/package_compiler.py \
  --sdk . \
  --build out/Napi \
  --runtime-dir out/Napi/clang_arm64_shared \
  --platform-dill tools/sdks/dart-sdk/lib/_internal/vm_platform_product.dill \
  --output out/package/linux_arm64
```

The packaging command requires a new output directory. Copy its complete contents
into `lib/src/compiler/assets/linux_arm64/` when updating the package.

For macOS arm64, use `target_os="mac"` and the same CPU values. For Windows x64,
use `target_os="win"`, `target_cpu="x64"` and `dart_target_arch="x64"`; its shared
outputs are in `clang_x64_shared`. Windows builds require
`dart_lib_export_symbols=false` to keep the two compiler VMs private.

Linux-to-Windows x64 builds use the SDK's host `gen_snapshot` target and a Windows
SDK/MSVC sysroot. Configure `clang_base_path`, `visual_studio_path`,
`visual_studio_version`, `windows_sdk_path` and `wdk_path` for that sysroot.
This cross-build produces the Windows compiler package; it does not make the Dart
`Compiler` API cross-compile user addons.

macOS packaging uses the system `strip` and `codesign`. When building the SDK with
a toolchain other than the SDK's bundled Clang, pass the applicable license text
with `--notices`.
