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
  --platform-dill out/Napi/vm_platform_product.dill \
  --output out/package/linux_arm64
```

The packaging command requires a new output directory. Copy its complete contents
into `lib/src/compiler/assets/linux_arm64/` and the shared
`out/package/platform.dill` into `lib/src/compiler/assets/` when updating the
package. All platforms must use the same SDK libraries; the packaging command
rejects a different `platform.dill` in an existing package directory.
For a native Linux x64 build, set `host_cpu`, `target_cpu` and `dart_target_arch`
to `"x64"`, use `clang_x64_shared` for the runtime directory, and package into
`lib/src/compiler/assets/linux_x64/`.
Use the platform built from the patched SDK; the stock SDK platform does not
include the private type conversion entry used by generated generic bindings.

For musl, set `dart_sysroot="alpine"` and provide a matching musl sysroot at
`buildtools/sysroot/alpine-linux-aarch64` or `alpine-linux-x86_64`. Set
`clang_prefix` when using a different Clang installation. An ARM64-to-x64 build
can use `dart_host_sysroot=""` to compile host tools against the host system
while the target uses musl. Package these builds as `linux_arm64_musl` or
`linux_x64_musl`.

For macOS, use `target_os="mac"`. For Windows, use `target_os="win"`. Both support
`target_cpu` and `dart_target_arch` set to `"arm64"` or `"x64"`; shared outputs
are in `clang_arm64_shared` or `clang_x64_shared`. Windows builds require
`dart_lib_export_symbols=false` to keep the two compiler VMs private.

Linux-to-Windows builds use the SDK's host `gen_snapshot` target and a Windows
SDK/MSVC sysroot. Configure `clang_base_path`, `visual_studio_path`,
`visual_studio_version`, `windows_sdk_path` and `wdk_path` for that sysroot.
The sysroot must include the target architecture's SDK and CRT libraries.
On a case-sensitive filesystem, `windows_vfs_overlay` can provide Clang and LLD
with a case-insensitive view of the Windows headers and libraries.
This cross-build produces the Windows compiler package; it does not make the Dart
`Compiler` API cross-compile user addons.

macOS packaging uses the system `strip` and `codesign`. When building the SDK with
a toolchain other than the SDK's bundled Clang, pass the applicable license text
with `--notices`.
