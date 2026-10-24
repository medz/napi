import 'dart:convert';
import 'dart:io';

import 'package:napi/src/build/native_package.dart';
import 'package:napi/src/compiler/native/platform.dart';
import 'package:test/test.dart';

const _modules = {
  NativePlatform.macosArm64: './macos-arm64/module.mjs',
  NativePlatform.macosX64: './macos-x64/module.mjs',
  NativePlatform.linuxX64: './linux-x64-glibc/module.mjs',
  NativePlatform.linuxArm64: './linux-arm64-glibc/module.mjs',
};

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi native package ');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<void> writeModules({List<String> names = const ['Counter']}) async {
    for (final entry in _modules.entries) {
      final module = File('${directory.path}/${entry.value}');
      await module.parent.create(recursive: true);
      await module.writeAsString('''
(globalThis.loadedTargets ??= []).push(${jsonEncode(entry.key.name)});
export class Counter {
  constructor(value = 0) { this.value = value; }
  increment() { return ++this.value; }
}
const selected = ${jsonEncode(entry.key.name)};
${names.where((name) => name != 'Counter').map((name) => 'export {selected as $name};').join('\n')}
''');
    }
    await File('${directory.path}/native.mjs')
        .writeAsString(emitNativePackageLoader(_modules, names));
    await File('${directory.path}/index.mjs')
        .writeAsString("export * from './native.mjs';\n");
  }

  Future<void> run(
    String source, {
    String platform = 'linux',
    String architecture = 'x64',
    String? glibc = '2.28',
    String kernel = '23.0.0',
    bool report = true,
  }) async {
    await File('${directory.path}/preload.cjs').writeAsString('''
Object.defineProperty(process, 'platform', {value: ${jsonEncode(platform)}});
Object.defineProperty(process, 'arch', {value: ${jsonEncode(architecture)}});
require('node:os').release = () => ${jsonEncode(kernel)};
require('node:module').syncBuiltinESMExports();
globalThis.reportCalls = 0;
${report ? '''process.report.getReport = () => {
  globalThis.reportCalls++;
  return {header: {glibcVersionRuntime: ${jsonEncode(glibc)}}};
};''' : "Object.defineProperty(process, 'report', {value: undefined});"}
''');
    await File('${directory.path}/check.mjs').writeAsString('''
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
$source
''');
    final result = await Process.run('node', [
      '--require',
      '${directory.path}/preload.cjs',
      '${directory.path}/check.mjs',
    ]);
    expect(
      result.exitCode,
      0,
      reason:
          '$platform/$architecture ($glibc): '
          '${result.stdout}${result.stderr}',
    );
  }

  test(
    'selects one platform and preserves constructor identity and state',
    () async {
      const names = [
        'Counter',
        'process',
        'Error',
        'Number',
        'version',
        'bindings',
        r'$napiBindings',
        r'$napiModules',
        r'$napiModule',
        r'$napiHost',
        r'$napiRelease',
        r'$napiCreateRequire',
        r'$napi0',
      ];
      await writeModules(names: names);
      for (final platform in NativePlatform.values) {
        await run(
          '''
const root = await import('./index.mjs');
const native = await import('./native.mjs');
const common = require('./native.mjs');
const selected = await import(${jsonEncode(_modules[platform])});
assert.equal(root.Counter, native.Counter);
assert.equal(common.Counter, native.Counter);
assert.equal(native.Counter, selected.Counter);
const counter = new root.Counter(4);
assert.equal(counter.increment(), 5);
assert.ok(counter instanceof native.Counter);
assert.ok(counter instanceof selected.Counter);
assert.deepEqual(globalThis.loadedTargets, [${jsonEncode(platform.name)}]);
for (const name of ${jsonEncode(names.skip(1).toList())}) {
  assert.equal(root[name], ${jsonEncode(platform.name)});
}
assert.equal(globalThis.reportCalls, ${platform.nodePlatform == 'linux' ? 1 : 0});
''',
          platform: platform.nodePlatform,
          architecture: platform.architecture,
        );
      }
    },
  );

  test(
    'CommonJS can load a platform before ESM without a second instance',
    () async {
      await writeModules();
      await run(r'''
const common = require('./index.mjs');
const counter = new common.Counter(4);
const esm = await import('./index.mjs');
assert.equal(common.Counter, esm.Counter);
assert.ok(counter instanceof esm.Counter);
assert.equal(counter.increment(), 5);
assert.deepEqual(globalThis.loadedTargets, ['linuxX64']);
''');
    },
  );

  test(
    'rejects unavailable platforms without loading another artifact',
    () async {
      await writeModules();
      for (final (platform, architecture) in [
        ('win32', 'x64'),
        ('linux', 'riscv64'),
      ]) {
        await run(
          '''
await assert.rejects(import('./index.mjs'), error => {
  assert.ok(error.message.includes(${jsonEncode('no native artifact for $platform/$architecture')}));
  assert.match(error.message, /Available targets: macOS arm64, macOS x64, Linux x64/);
  return true;
});
assert.equal(globalThis.loadedTargets, undefined);
assert.equal(globalThis.reportCalls, 0);
''',
          platform: platform,
          architecture: architecture,
        );
      }
      await File('${directory.path}/native.mjs').writeAsString(
        emitNativePackageLoader(
          {NativePlatform.macosArm64: _modules[NativePlatform.macosArm64]!},
          ['Counter'],
        ),
      );
      await run(r'''
await assert.rejects(import('./native.mjs'), /no native artifact for linux\/x64/);
assert.equal(globalThis.loadedTargets, undefined);
assert.equal(globalThis.reportCalls, 0);
''');
    },
  );

  test(
    'rejects unsupported OS and libc versions before loading native code',
    () async {
      await writeModules();
      const rejectedLinux = r'''
await assert.rejects(import('./native.mjs'), /requires Linux with glibc 2\.28 or newer/);
assert.equal(globalThis.loadedTargets, undefined);
''';
      for (final glibc in [null, '', '2.9', '2.27', '1.100', 'unknown']) {
        await run(rejectedLinux, glibc: glibc);
      }
      await run(rejectedLinux, report: false);
      for (final glibc in ['2.28.0', '2.39', '3.0']) {
        await run(r'''
await import('./native.mjs');
assert.deepEqual(globalThis.loadedTargets, ['linuxX64']);
''', glibc: glibc);
      }
      await run(
        r'''
await assert.rejects(import('./native.mjs'), /requires macOS 14 or newer/);
assert.equal(globalThis.loadedTargets, undefined);
''',
        platform: 'darwin',
        architecture: 'arm64',
        kernel: '22.6.0',
      );
    },
  );

  test('Intel-only packages enforce the minimum macOS version', () async {
    await writeModules();
    await File('${directory.path}/native.mjs').writeAsString(
      emitNativePackageLoader(
        {NativePlatform.macosX64: _modules[NativePlatform.macosX64]!},
        ['Counter'],
      ),
    );
    await run(
      r'''
await assert.rejects(import('./native.mjs'), /requires macOS 14 or newer/);
assert.equal(globalThis.loadedTargets, undefined);
''',
      platform: 'darwin',
      architecture: 'x64',
      kernel: '22.6.0',
    );
    await run(
      r'''
await import('./native.mjs');
assert.deepEqual(globalThis.loadedTargets, ['macosX64']);
assert.equal(globalThis.reportCalls, 0);
''',
      platform: 'darwin',
      architecture: 'x64',
    );
  });

  test('Linux arm64-only packages enforce the glibc requirement', () async {
    await writeModules();
    await File('${directory.path}/native.mjs').writeAsString(
      emitNativePackageLoader(
        {NativePlatform.linuxArm64: _modules[NativePlatform.linuxArm64]!},
        ['Counter'],
      ),
    );
    for (final glibc in [null, '2.27']) {
      await run(
        r'''
await assert.rejects(import('./native.mjs'), /requires Linux with glibc 2\.28 or newer/);
assert.equal(globalThis.loadedTargets, undefined);
''',
        architecture: 'arm64',
        glibc: glibc,
      );
    }
    await run(r'''
await import('./native.mjs');
assert.deepEqual(globalThis.loadedTargets, ['linuxArm64']);
assert.equal(globalThis.reportCalls, 1);
''', architecture: 'arm64');
  });

  test(
    'preserves a selected module failure and never tries another target',
    () async {
      await writeModules();
      await File('${directory.path}/${_modules[NativePlatform.linuxX64]}')
          .writeAsString('throw globalThis.nativeFailure;\n');
      await run(r'''
globalThis.nativeFailure = new Error('native image could not be loaded');
await assert.rejects(import('./index.mjs'), error => error === globalThis.nativeFailure);
assert.equal(globalThis.loadedTargets, undefined);
''');
      await File('${directory.path}/${_modules[NativePlatform.linuxX64]}')
          .delete();
      await run(r'''
await assert.rejects(import('./index.mjs'), error => {
  assert.equal(error.code, 'MODULE_NOT_FOUND');
  assert.match(error.message, /linux-x64-glibc/);
  return true;
});
assert.equal(globalThis.loadedTargets, undefined);
''');
    },
  );
}
