import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:napi/build.dart';
import 'package:napi/src/build/output_ownership.dart';
import 'package:napi/src/compiler/native/platform.dart';
import 'package:napi/src/compiler/linker/dart_module_linker.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_aot_adapter.dart';

Future<BuiltModule> createPackageModule(
  Directory root,
  NativePlatform? platform,
  Map<String, Object?> contract,
) async {
  final directory = await Directory(
    '${root.path}/${platform?.packageId ?? 'wasm'}',
  ).create();
  final runtime = platform == null
      ? null
      : 'libnapi_runtime_fixture.${platform.runtimeExtension}';
  final names = packageArtifactNames(
    {platform == null ? 'wasm' : 'native'},
    runtime,
    calls: false,
  );
  for (final name in names) {
    await File('${directory.path}/$name').writeAsString(
      name.startsWith('module.d.')
          ? 'export declare class Counter {}\n'
          : name == 'module.mjs'
          ? 'export class Counter { value = 0; increment() { return ++this.value; } }\n'
          : name,
    );
  }
  if (platform == null) {
    await File('${directory.path}/module.wasm').writeAsBytes(
      buildPublicWasmFacade(
        hostSpecifier: './host.mjs',
        exportNames: ['Counter'],
      ),
    );
    await File('${directory.path}/host.mjs')
        .writeAsString('export class Counter { value = 100; }');
  }
  if (platform != null) {
    final hashes = <String, String>{};
    for (final name in [
      'bridge.node',
      runtime!,
      'DART_LICENSE',
      'DART_AUTHORS',
      'NAPI_LICENSE',
    ]) {
      hashes[name] = sha256
          .convert(await File('${directory.path}/$name').readAsBytes())
          .toString();
    }
    await File('${directory.path}/runtime.json').writeAsString(
      jsonEncode({
        'format': 1,
        'sdkVersion': '3.13.5',
        'sdkRevision': nativeSdkRevision,
        'platform': platform.platform,
        'architecture': platform.architecture,
        if (platform.minimumOsVersion != null)
          'minimumOsVersion': platform.minimumOsVersion,
        if (platform.libc != null) 'libc': platform.libc,
        if (platform.minimumLibcVersion != null)
          'minimumLibcVersion': platform.minimumLibcVersion,
        'abi': 15,
        'identity': 'fixture',
        'bridge': 'bridge.node',
        'runtime': runtime,
        'files': hashes,
      }),
    );
  }
  await writeOutputOwnership(
    directory,
    kind: OutputKind.module,
    targets: {platform == null ? 'wasm' : 'native'},
    root: platform == null ? 'wasm' : 'native',
    runtime: runtime,
    calls: false,
    moduleContract: contract,
  );
  return BuiltModule(
    directory,
    '3.13.5',
    target: platform == null ? BuildTarget.wasm : BuildTarget.native,
  );
}
