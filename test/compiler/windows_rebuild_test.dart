@TestOn('windows')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:napi/build.dart';
import 'package:path/path.dart' as path;
import 'package:napi/src/build/output.dart';
import 'package:napi/src/build/output_ownership.dart';
import 'package:napi/src/build/publish.dart';
import 'package:test/test.dart';

import '../support/commands.dart';
import '../support/fixtures/module_rebuilds.dart';

void main() {
  late Directory root;
  late Directory source;
  late Directory output;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('napi Windows rebuild 雪 ');
    source = await Directory('${root.path}/source').create();
    output = Directory('${root.path}/package');
    for (final name in wasmPackageFiles) {
      await File('${source.path}/$name').writeAsString('first $name');
    }
    await assembleWasmPackage(
      module: BuiltModule(source, '3.13.5'),
      output: output,
      metadata: {'name': 'windows-rebuild', 'version': '1.0.0'},
    );
  });
  tearDown(() => root.delete(recursive: true));

  Future<Directory> nextOutput() async {
    final next = Directory('${root.path}/next');
    await File('${source.path}/module.wasm').writeAsString('second');
    await assembleWasmPackage(
      module: BuiltModule(source, '3.13.5'),
      output: next,
      metadata: {'name': 'windows-rebuild', 'version': '1.0.1'},
    );
    return next;
  }

  test('lock handles prevent file and parent-directory replacement', () async {
    final lock = PackageLock.acquire(output);
    try {
      for (final entity in <FileSystemEntity>[
        lock.file,
        lock.file.parent,
        lock.file.parent.parent,
      ]) {
        expect(
          () => entity.renameSync('${entity.path}.moved'),
          throwsA(isA<FileSystemException>()),
        );
      }
      expect(
        () => PackageLock.acquire(output),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => PackageLock.acquire(Directory(output.path.toUpperCase())),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      lock.release();
      lock.release();
    }
    PackageLock.acquire(output).release();
  });

  test('an absent DOS short name cannot create a separate output lock', () {
    expect(
      () => PackageLock.acquire(Directory('${root.path}/LONGDI~1')),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('an existing DOS short name shares the output lock', () async {
    final directory = await Directory('${root.path}/long package directory')
        .create();
    await File(path.join(root.path, 'short-path.cmd')).writeAsString(
      '@echo off\r\nfor %%I in ("%NAPI_TEST_LONG_PATH%") do @echo %%~sI\r\n',
    );
    final result = await Process.run(
      'cmd.exe',
      ['/d', '/c', 'short-path.cmd'],
      workingDirectory: root.path,
      environment: {'NAPI_TEST_LONG_PATH': directory.path},
    );
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final short = result.stdout.toString().trim();
    if (path.basename(short).toLowerCase() ==
        path.basename(directory.path).toLowerCase()) {
      markTestSkipped('DOS short names are disabled on this volume.');
      return;
    }
    expect(await FileSystemEntity.identical(directory.path, short), isTrue);
    PackageLock.acquire(Directory(short)).release();
    final lock = PackageLock.acquire(directory);
    try {
      expect(
        () => PackageLock.acquire(Directory(short)),
        throwsA(isA<FileSystemException>()),
      );
      final backup = Directory('${root.path}/previous');
      publishDirectory(directory, backup);
      try {
        expect(
          () => PackageLock.acquire(Directory(short)),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        publishDirectory(backup, directory);
      }
    } finally {
      lock.release();
    }
  });

  for (final blocked in ['old', 'new']) {
    test(
      'a $blocked directory in use leaves the old result available',
      () async {
        final next = await nextOutput();
        final update = await OutputUpdate.open(output);
        final release = _holdDirectory(blocked == 'old' ? output : next);
        try {
          await expectLater(
            update.replace(next, output),
            throwsA(isA<FileSystemException>()),
          );
          expect(
            await File('${output.path}/module.wasm').readAsString(),
            'first module.wasm',
          );
          expect(
            await File('${next.path}/module.wasm').readAsString(),
            'second',
          );
          expect(
            await Directory('${update.lock.recoveryDirectory!.path}/previous')
                .exists(),
            isFalse,
          );
        } finally {
          release();
          update.close();
        }
        final retry = await OutputUpdate.open(output);
        try {
          await retry.replace(next, output);
        } finally {
          retry.close();
        }
        expect(
          await File('${output.path}/module.wasm').readAsString(),
          'second',
        );
      },
    );
  }

  for (final phase in [
    'prepared',
    'backed-up',
    'published',
    'cleanup',
    'cleanup-edited',
  ]) {
    test(
      'process interruption at $phase recovers the recorded result',
      () async {
        final next = await nextOutput();
        final script = await File('${root.path}/interrupt.dart')
            .writeAsString(r'''
import 'dart:convert';
import 'dart:io';
import 'package:napi/src/build/output.dart';
import 'package:napi/src/build/output_ownership.dart';
import 'package:napi/src/build/publish.dart';
Future<void> main(List<String> args) async {
  final output = Directory(args[0]);
  final next = Directory(args[1]);
  final update = await OutputUpdate.open(output);
  final state = update.lock.recoveryDirectory!;
  await File('${state.path}/replacement.json').writeAsString(jsonEncode({
    'format': 1, 'kind': 'package', 'committed': args[2].startsWith('cleanup'),
    'previous': update.previous!.recoveryFingerprint,
    'entries': update.previous!.recoveryEntries,
    'next': (await OutputOwnership.read(next))!.recoveryFingerprint,
  }), flush: true);
  if (args[2] != 'prepared') publishDirectory(output, Directory('${state.path}/previous'));
  if (args[2] == 'published' || args[2].startsWith('cleanup')) publishDirectory(next, output);
  if (args[2].startsWith('cleanup')) {
    await File('${state.path}/previous/module.wasm').delete();
    await File('${state.path}/previous/.napi-output.json').delete();
  }
  stdout.writeln('ready');
  await stdin.first;
  update.close();
}
''');
        final child = await Process.start(Platform.resolvedExecutable, [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          script.path,
          output.path,
          next.path,
          phase,
        ]);
        addTearDown(() {
          child.kill();
        });
        final errors = child.stderr.transform(utf8.decoder).join();
        expect(
          await child.stdout.transform(utf8.decoder).first,
          contains('ready'),
        );
        expect(child.kill(ProcessSignal.sigkill), isTrue);
        await child.exitCode;
        expect(await errors, isEmpty);
        if (phase == 'cleanup-edited') {
          final state = PackageLock.acquire(output);
          final backup = state.recoveryDirectory!;
          state.release();
          final edit = await File('${backup.path}/previous/notes.txt')
              .writeAsString('keep');
          await expectLater(
            OutputUpdate.open(output),
            throwsA(isA<FileSystemException>()),
          );
          expect(await edit.readAsString(), 'keep');
          return;
        }
        final recovered = await OutputUpdate.open(output);
        recovered.close();
        expect(
          await File('${output.path}/module.wasm').readAsString(),
          phase == 'published' || phase == 'cleanup'
              ? 'second'
              : 'first module.wasm',
        );
        expect(
          await Directory('${recovered.lock.recoveryDirectory!.path}/previous')
              .exists(),
          isFalse,
        );
        expect(
          await File(
            '${recovered.lock.recoveryDirectory!.path}/replacement.json',
          ).exists(),
          isFalse,
        );
      },
    );
  }

  test(
    'inputs cannot read from another build backup or private lock path',
    () async {
      await expectLater(
        checkOutputInputs(output, [
          File('${root.path}/.napi-locks/other/previous/business.dart'),
        ]),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('recovery preserves an unrecorded or edited backup', () async {
    final lock = PackageLock.acquire(output);
    final backup = Directory('${lock.recoveryDirectory!.path}/previous');
    publishDirectory(output, backup);
    lock.release();
    await expectLater(
      OutputUpdate.open(output),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await File('${backup.path}/module.wasm').readAsString(),
      'first module.wasm',
    );
    final prior = (await OutputOwnership.read(backup))!;
    await File('${lock.recoveryDirectory!.path}/replacement.json')
        .writeAsString(
          jsonEncode({
            'format': 1,
            'kind': 'package',
            'committed': false,
            'previous': prior.recoveryFingerprint,
            'entries': prior.recoveryEntries,
            'next': 'a' * 64,
          }),
        );
    await File('${backup.path}/notes.txt').writeAsString('author edit');
    await expectLater(
      OutputUpdate.open(output),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      await File('${backup.path}/notes.txt').readAsString(),
      'author edit',
    );
    expect(await output.exists(), isFalse);
  });

  test(
    'author timestamps, attributes and access rules survive replacement',
    () async {
      final author = await Directory('${output.path}/author').create();
      final note = await File('${author.path}/notes.txt').writeAsString('keep');
      Future<String> metadata({bool initialize = false}) async {
        final script =
            '''
\$file = Get-Item -LiteralPath \$env:NAPI_METADATA_PATH -Force
${initialize ? r'''
$file.CreationTimeUtc = [DateTime]::new(2020, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
$file.LastWriteTimeUtc = $file.CreationTimeUtc
$file.Attributes = [IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Hidden
$acl = Get-Acl -LiteralPath $file.FullName
$acl.SetAccessRuleProtection($true, $true)
Set-Acl -LiteralPath $file.FullName -AclObject $acl
''' : ''}
@{attributes=[int]\$file.Attributes; created=\$file.CreationTimeUtc.Ticks; modified=\$file.LastWriteTimeUtc.Ticks; acl=(Get-Acl -LiteralPath \$file.FullName).Sddl} | ConvertTo-Json -Compress
''';
        final encoded = base64.encode(
          script.codeUnits.expand((unit) => [unit & 255, unit >> 8]).toList(),
        );
        final result = await Process.run(
          'pwsh',
          ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
          environment: {'NAPI_METADATA_PATH': note.path},
        );
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
        return result.stdout.toString().trim();
      }

      final before = jsonDecode(await metadata(initialize: true));
      await File('${source.path}/module.wasm').writeAsString('second');
      await assembleWasmPackage(
        module: BuiltModule(source, '3.13.5'),
        output: output,
        metadata: {'name': 'windows-rebuild', 'version': '1.0.1'},
      );
      expect(await note.readAsString(), 'keep');
      expect(jsonDecode(await metadata()), before);
      expect(await File('${output.path}/module.wasm').readAsString(), 'second');
    },
  );

  for (final change in ['attributes', 'acl']) {
    test('concurrent Windows $change changes reject replacement', () async {
      final note = await File('${output.path}/notes.txt').writeAsString('keep');
      final previous = (await OutputOwnership.read(output))!;
      final before = packageWindowsMetadata(note)!;
      final script = change == 'attributes'
          ? r"$file = Get-Item -LiteralPath $env:NAPI_METADATA_PATH; $file.Attributes = $file.Attributes -bor [IO.FileAttributes]::Hidden"
          : r"$acl = Get-Acl -LiteralPath $env:NAPI_METADATA_PATH; $acl.SetAccessRuleProtection($true, $true); Set-Acl -LiteralPath $env:NAPI_METADATA_PATH -AclObject $acl";
      final encoded = base64.encode(
        script.codeUnits.expand((unit) => [unit & 255, unit >> 8]).toList(),
      );
      final changed = await Process.run(
        'pwsh',
        ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
        environment: {'NAPI_METADATA_PATH': note.path},
      );
      expect(changed.exitCode, 0, reason: '${changed.stdout}${changed.stderr}');
      final after = packageWindowsMetadata(note)!;
      expect(after.changed, isNot(before.changed));
      await expectLater(
        previous.checkUnchanged(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await note.readAsString(), 'keep');
    });
  }

  test(
    'buildLibrary recovers an interrupted module before rebuilding',
    () async {
      final business = await File('${root.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int add(int value) => value + 1;
''');
      final module = Directory('${root.path}/module');
      final packages = File('.dart_tool/package_config.json').absolute.path;
      Future<BuiltModule> build(Directory target) => buildLibrary(
        library: business.uri,
        output: target,
        packagesPath: packages,
      );
      await build(module);
      final author = await File('${module.path}/notes.txt')
          .writeAsString('keep');
      final modified = DateTime.utc(2020);
      await author.setLastModified(modified);
      await business.writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int add(int value) => value + 3;
''');
      final replacement = (await build(Directory('${root.path}/replacement')))
          .directory;
      final script = await File('${root.path}/interrupt-module.dart')
          .writeAsString(r'''
import 'dart:convert';
import 'dart:io';
import 'package:napi/src/build/output.dart';
import 'package:napi/src/build/output_ownership.dart';
import 'package:napi/src/build/publish.dart';
Future<void> main(List<String> args) async {
  final output = Directory(args[0]);
  final update = await OutputUpdate.open(output, kind: OutputKind.module);
  final next = (await OutputOwnership.read(Directory(args[1]), kind: OutputKind.module))!;
  final state = update.lock.recoveryDirectory!;
  await File('${state.path}/replacement.json').writeAsString(jsonEncode({
    'format': 1, 'kind': 'module', 'committed': false,
    'previous': update.previous!.recoveryFingerprint,
    'entries': update.previous!.recoveryEntries,
    'next': next.recoveryFingerprint,
  }), flush: true);
  publishDirectory(output, Directory('${state.path}/previous'));
  stdout.writeln('ready');
  await stdin.first;
  update.close();
}
''');
      final child = await Process.start(Platform.resolvedExecutable, [
        '--packages=$packages',
        script.path,
        module.path,
        replacement.path,
      ]);
      addTearDown(() => child.kill());
      final errors = child.stderr.transform(utf8.decoder).join();
      expect(
        await child.stdout.transform(utf8.decoder).first,
        contains('ready'),
      );
      expect(await module.exists(), isFalse);
      // The missing-output path must still respect the active builder's lock.
      await expectLater(build(module), throwsA(isA<FileSystemException>()));
      expect(child.kill(ProcessSignal.sigkill), isTrue);
      await child.exitCode;
      expect(await errors, isEmpty);
      final recovered = await build(module);
      expect(recovered.directory.path, module.absolute.path);
      expect(await author.readAsString(), 'keep');
      expect((await author.stat()).modified.isAtSameMomentAs(modified), isTrue);
      final lock = PackageLock.acquire(module);
      try {
        expect(
          await Directory('${lock.recoveryDirectory!.path}/previous').exists(),
          isFalse,
        );
        expect(
          await File('${lock.recoveryDirectory!.path}/replacement.json')
              .exists(),
          isFalse,
        );
      } finally {
        lock.release();
      }
      await File('${module.path}/test.mjs').writeAsString('''
import assert from 'node:assert/strict';
import {add} from './module.wasm';
assert.equal(add(5), 8);
''');
      await run('node', ['test.mjs'], cwd: module.path);
    },
    timeout: Timeout(Duration(minutes: 5)),
  );

  test('rebuilt Wasm module runs after moving the output alone', () async {
    await verifyModuleRebuild(
      await Directory('${root.path}/consumer').create(),
    );
  }, timeout: Timeout(Duration(minutes: 3)));
}

/// Hold an ordinary directory open without FILE_SHARE_DELETE, like a consumer.
void Function() _holdDirectory(Directory directory) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final heap = kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      )();
  final alloc = kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, Size),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');
  final free = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');
  final create = kernel
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Uint16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Uint16>,
          int,
          int,
          Pointer<Void>,
          int,
          int,
          Pointer<Void>,
        )
      >('CreateFileW');
  final close = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  final units = '${directory.absolute.path}\x00'.codeUnits;
  final data = alloc(heap, 8, units.length * 2);
  late Pointer<Void> handle;
  try {
    data.cast<Uint16>().asTypedList(units.length).setAll(0, units);
    handle = create(data.cast(), 0x81, 3, nullptr, 3, 0x02000000, nullptr);
    expect(handle, isNot(Pointer<Void>.fromAddress(-1)));
  } finally {
    free(heap, 0, data);
  }
  return () {
    expect(close(handle), isNot(0));
  };
}
