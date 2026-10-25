import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'arm64.dart';
import 'lifecycle.dart';
import 'macho.dart';
import 'runtime.dart';
import 'scheduler.dart';

const _page = 0x4000;
const _revision = '04bcd1036cdc799ac6564988f159ee454d42c822';
int _align(int value) => (value + _page - 1) & -_page;

Future<void> _run(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      args,
      '${result.stdout}${result.stderr}',
      result.exitCode,
    );
  }
}

String _name(Uint8List bytes, int start) =>
    utf8.decode(bytes.sublist(start, bytes.indexOf(0, start)));

final class _Snapshot {
  _Snapshot(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    var command = 32;
    for (var i = 0; i < view.getUint32(16, Endian.little); i++) {
      final kind = view.getUint32(command, Endian.little);
      if (kind == 0x19) {
        final name = _name(bytes, command + 8);
        if (name == '__TEXT') {
          textSize = view.getUint64(command + 32, Endian.little);
          final start = view.getUint64(command + 40, Endian.little);
          final size = view.getUint64(command + 48, Endian.little);
          text = Uint8List(textSize)..setRange(0, size, bytes, start);
        } else if (name == '__DATA') {
          dataAddress = view.getUint64(command + 24, Endian.little);
          dataSize = view.getUint64(command + 32, Endian.little);
          if (view.getUint64(command + 48, Endian.little) != 0) {
            throw UnsupportedError('Expected zero-filled AOT data');
          }
        }
      } else if (kind == 2) {
        final symbols = view.getUint32(command + 8, Endian.little);
        final count = view.getUint32(command + 12, Endian.little);
        final strings = view.getUint32(command + 16, Endian.little);
        for (var j = 0; j < count; j++) {
          final entry = symbols + j * 16;
          final name = _name(
            bytes,
            strings + view.getUint32(entry, Endian.little),
          );
          if (name == '_kDartSnapshotData') {
            snapshotData = view.getUint64(entry + 8, Endian.little);
          } else if (name == '_kDartSnapshotText') {
            snapshotText = view.getUint64(entry + 8, Endian.little);
          }
        }
      }
      command += view.getUint32(command + 4, Endian.little);
    }
    if (dataAddress != textSize || textSize % _page != 0) {
      throw UnsupportedError('Unexpected AOT segment layout');
    }
  }

  late Uint8List text;
  late int textSize, dataAddress, dataSize, snapshotData, snapshotText;
}

Future<void> main() async {
  if (!Platform.isMacOS) {
    throw UnsupportedError('This experiment targets macOS arm64');
  }
  final root = File.fromUri(Platform.script).parent.absolute;
  final build = Directory('${root.path}/build')..createSync(recursive: true);
  final sdk = Directory(Platform.resolvedExecutable).parent.parent;
  if (File('${sdk.path}/revision').readAsStringSync().trim() != _revision) {
    throw StateError('Expected the pinned Dart 3.13.5 SDK');
  }
  final runtime = File('${sdk.path}/bin/dartaotruntime');
  final runtimeBytes = runtime.readAsBytesSync();
  final image = MachOImage.parse(runtimeBytes);
  final symbols = RuntimeSymbols.parse(
    runtimeBytes,
    File('${runtime.path}.sym').readAsBytesSync(),
    image,
  );
  stdout.writeln('Compiling the Dart payload directly to Mach-O...');
  await _run(runtime.path, [
    '${sdk.path}/bin/snapshots/gen_kernel_aot.dart.snapshot',
    '--platform=${sdk.path}/lib/_internal/vm_platform_product.dill',
    '-Ddart.vm.product=true',
    '--aot',
    '--no-embed-sources',
    '--output=${build.path}/payload.dill',
    '${root.path}/payload.dart',
  ]);
  await _run('${sdk.path}/bin/utils/gen_snapshot', [
    '--snapshot_kind=app-aot-macho-dylib',
    '--macho=${build.path}/payload.dylib',
    '${build.path}/payload.dill',
  ]);
  final snapshot = _Snapshot(
    File('${build.path}/payload.dylib').readAsBytesSync(),
  );
  final codeBase = image.nextVmAddress;
  final payloadBase = codeBase + _page;
  final rwBase = codeBase + _page + snapshot.textSize;
  final stateBase = rwBase + _align(snapshot.dataSize);
  final state = Uint8List(_page);
  final stateView = ByteData.sublistView(state);
  var stringOffset = 512;
  int string(String value) {
    final bytes = utf8.encode(value);
    final address = stateBase + stringOffset;
    state.setRange(stringOffset, stringOffset + bytes.length, bytes);
    stringOffset += bytes.length + 1;
    return address;
  }

  final flag = string('--precompilation');
  final name = string('napi:native-image');
  final initialize = string('initialize');
  final dispose = string('dispose');
  final throwError = string('napi_throw_error');
  final addCleanup = string('napi_add_env_cleanup_hook');
  final callThreadsafe = string('napi_call_threadsafe_function');
  final releaseThreadsafe = string('napi_release_threadsafe_function');
  final takeException = string('napi_get_and_clear_last_exception');
  final fatalException = string('napi_fatal_exception');
  final isolateLibrary = string('dart:isolate');
  final drainMicrotasks = string('_runPendingImmediateCallback');
  final afterPump = string('afterPump');
  final allocationError = string('Cannot allocate Dart environment');
  final platformError = string('Cannot initialize Dart platform');
  final creationError = string('Dart isolate creation failed');
  final childError = string(
    'Dart isolate group is closing or cannot allocate a child',
  );
  final cleanupError = string('Cannot register Dart isolate cleanup');
  final parameters = stateBase;
  final flagList = stateBase + 128;
  final vmError = stateBase + 136;
  final once = stateBase + 144;
  final callThreadsafeSlot = stateBase + 160;
  final settings = stateBase + 176;
  stateView.setUint32(0, 11, Endian.little);
  // Darwin pthread_once_t: signature followed by eight zero bytes.
  stateView.setUint64(144, 0x30b1bcba, Endian.little);
  final code = Arm64(codeBase);
  int apiAddress(String name) => image.symbolAddress('_$name');
  int importSlot(String name) => image.importPointerAddress('_$name');
  void api(String name) => code.call(apiAddress(name));
  void imported(String name) => code.imported(importSlot(name));
  void internal(String name) => code.call(symbols.address(name));
  void resolve(int symbol) {
    code.immediate(0, -2); // RTLD_DEFAULT on macOS.
    code.pointer(1, symbol);
    imported('dlsym');
  }

  void throwJs() {
    resolve(throwError);
    code.mov(16, 0);
    code.mov(0, 19);
    code.immediate(1, 0);
    code.mov(2, 22);
    code.indirect(16);
  }

  void setupLibraries() {
    code.immediate(0, 0);
    code.immediate(1, 0);
    code.immediate(2, 0);
    code.pointer(3, settings);
    internal('dart::bin::DartUtils::SetupCoreLibraries');
  }

  // A Dart error outside a returned Future is delivered as a Node exception.
  final reportError = code.address;
  code.enter();
  code.mov(19, 0);
  code.mov(22, 1);
  throwJs();
  resolve(takeException);
  code.mov(16, 0);
  code.mov(0, 19);
  code.add(1, 31, 64);
  code.indirect(16);
  resolve(fatalException);
  code.mov(16, 0);
  code.mov(0, 19);
  code.load(1, 31, 64);
  code.indirect(16);
  code.leave();
  final scheduler = emitScheduler(
    code,
    apiAddress,
    importSlot,
    callThreadsafeSlot: callThreadsafeSlot,
    isolateLibraryName: isolateLibrary,
    drainMicrotasksName: drainMicrotasks,
    afterPumpName: afterPump,
    reportError: reportError,
  );

  final lifecycle = emitLifecycle(code, apiAddress, importSlot);

  // The VM calls this with the newly spawned isolate already entered.
  final initializeChild = code.address;
  code.enter();
  code.mov(19, 0);
  code.mov(20, 1);
  code.store(31, 19);
  api('Dart_EnterScope');
  setupLibraries();
  code.mov(21, 0);
  api('Dart_IsError');
  code.nonzero(0, 'childFailed');
  api('Dart_CurrentIsolate');
  code.mov(21, 0);
  api('Dart_CurrentIsolateGroupData');
  code.mov(1, 21);
  code.call(lifecycle.registerChild);
  code.zero(0, 'childRegisterFailed');
  code.store(0, 19);
  api('Dart_ExitScope');
  code.immediate(0, 1);
  code.leave();
  code.label('childRegisterFailed');
  code.pointer(0, childError);
  code.branch('childCopyError');
  code.label('childFailed');
  code.mov(0, 21);
  api('Dart_GetError');
  code.label('childCopyError');
  imported('strdup');
  code.store(0, 20);
  api('Dart_ExitScope');
  // This SDK's spawn path shuts down the child after a false return.
  code.immediate(0, 0);
  code.leave();

  final initializeVm = code.address;
  code.enter();
  internal('dart::bin::SetupICU');
  code.immediate(0, 0); // Keep Node's crash handlers.
  internal('dart::bin::Platform::Initialize');
  code.zero(0, 'platformFailed');
  code.pointer(0, stateBase + 2048);
  code.immediate(1, 4096);
  internal('dart::bin::Platform::ResolveExecutablePathInto');
  code.add(9, 0, 1); // The failure sentinel is intptr_t(-1).
  code.zero(9, 'platformFailed');
  code.pointer(9, stateBase + 2048);
  code.pointer(10, symbols.executableNameSlot);
  code.store(9, 10);
  code.pointer(9, name);
  code.pointer(10, settings);
  code.store(9, 10, 24);
  code.pointer(0, vmError);
  internal('dart::embedder::InitOnce');
  code.zero(0, 'vmInitFailed');
  code.pointer(9, flag);
  code.pointer(10, flagList);
  code.store(9, 10);
  code.immediate(0, 1);
  code.mov(1, 10);
  api('Dart_SetVMFlags');
  code.nonzero(0, 'vmInitialized');
  code.pointer(9, initializeChild);
  code.pointer(10, parameters);
  code.store(9, 10, 16);
  for (final (offset, callback) in [
    (24, lifecycle.shutdownChild),
    (32, lifecycle.cleanupChild),
    (40, lifecycle.cleanupGroup),
  ]) {
    code.pointer(9, callback);
    code.store(9, 10, offset);
  }
  for (final (offset, function) in [
    (64, 'OpenFile'),
    (72, 'ReadFile'),
    (80, 'WriteFile'),
    (88, 'CloseFile'),
    (96, 'EntropySource'),
  ]) {
    code.pointer(9, symbols.address('dart::bin::DartUtils::$function'));
    code.store(9, 10, offset);
  }
  resolve(callThreadsafe);
  code.pointer(9, callThreadsafeSlot);
  code.store(0, 9);
  code.pointer(0, parameters);
  api('Dart_Initialize');
  code.label('vmInitialized');
  code.pointer(9, vmError);
  code.store(0, 9);
  code.label('vmInitFailed');
  code.leave();
  code.label('platformFailed');
  code.pointer(0, platformError);
  code.branch('vmInitialized');

  // Owner lives until the TSFN finalizer, after queued Node callbacks drain.
  final cleanup = code.address;
  code.enter();
  code.mov(23, 0);
  code.immediate(9, 1);
  code.store(9, 23, 24);
  code.load(0, 23, 8);
  api('Dart_EnterIsolate');
  code.immediate(0, 0);
  api('Dart_SetMessageNotifyCallback');
  code.load(0, 23, 32);
  code.call(lifecycle.closeGroup);
  api('Dart_EnterScope');
  api('Dart_RootLibrary');
  code.mov(21, 0);
  code.pointer(0, dispose);
  api('Dart_NewStringFromCString');
  code.mov(1, 0);
  code.mov(0, 21);
  code.immediate(2, 0);
  code.immediate(3, 0);
  api('Dart_Invoke');
  api('Dart_ExitScope');
  api('Dart_ShutdownIsolate');
  code.store(31, 23, 8);
  code.load(9, 23);
  code.zero(9, 'freeOwner');
  resolve(releaseThreadsafe);
  code.mov(16, 0);
  code.load(0, 23);
  code.immediate(1, 1); // napi_tsfn_abort.
  code.indirect(16);
  code.leave();
  code.label('freeOwner');
  code.mov(0, 23);
  imported('free');
  code.leave();

  final entry = code.address;
  code.enter();
  code.mov(19, 0);
  code.mov(20, 1);
  code.pointer(0, once);
  code.pointer(1, initializeVm);
  imported('pthread_once');
  code.pointer(9, vmError);
  code.load(0, 9);
  code.nonzero(0, 'failure');
  code.immediate(0, 1);
  code.immediate(1, 64);
  imported('calloc');
  code.zero(0, 'allocationFailed');
  code.mov(23, 0);
  code.store(19, 23, 16);
  code.call(lifecycle.initGroup);
  code.zero(0, 'groupAllocationFailed');
  code.store(0, 23, 32);
  code.add(0, 31, 112);
  api('Dart_IsolateFlagsInitialize');
  code.store(31, 31, 104);
  code.pointer(0, name);
  code.mov(1, 0);
  code.pointer(2, payloadBase + snapshot.snapshotData);
  code.pointer(3, payloadBase + snapshot.snapshotText);
  code.add(4, 31, 112);
  code.load(5, 23, 32);
  code.mov(6, 23);
  code.add(7, 31, 104);
  api('Dart_CreateIsolateGroup');
  code.zero(0, 'creationFailed');
  code.mov(24, 0);
  code.store(24, 23, 8);
  api('Dart_SetCurrentThreadOwnsIsolate');
  api('Dart_EnterScope');
  setupLibraries();
  code.mov(22, 0);
  api('Dart_IsError');
  code.nonzero(0, 'dartFailure');
  api('Dart_RootLibrary');
  code.mov(21, 0);
  for (final (offset, register, pointer) in [
    (64, 19, 0),
    (72, 20, 0),
    (80, -1, scheduler.callJs),
    (88, 23, 0),
    (96, -1, scheduler.finalize),
    (104, -1, apiAddress('Dart_HasLivePorts')),
  ]) {
    if (register >= 0) {
      code.mov(0, register);
    } else {
      code.pointer(0, pointer);
    }
    api('Dart_NewIntegerFromUint64');
    code.store(0, 31, offset);
  }
  code.pointer(0, initialize);
  api('Dart_NewStringFromCString');
  code.mov(1, 0);
  code.mov(0, 21);
  code.immediate(2, 6);
  code.add(3, 31, 64);
  api('Dart_Invoke');
  code.mov(22, 0);
  api('Dart_IsError');
  code.nonzero(0, 'dartFailure');
  code.mov(0, 22);
  code.mov(1, 23);
  api('Dart_IntegerToUint64');
  code.mov(22, 0);
  api('Dart_IsError');
  code.nonzero(0, 'dartFailure');
  code.pointer(0, scheduler.notify);
  api('Dart_SetMessageNotifyCallback');
  api('Dart_ExitScope');
  api('Dart_ExitIsolate');
  code.mov(0, 24);
  api('Dart_IsolateMakeRunnable');
  code.nonzero(0, 'runnableFailed');
  resolve(addCleanup);
  code.mov(16, 0);
  code.mov(0, 19);
  code.pointer(1, cleanup);
  code.mov(2, 23);
  code.indirect(16);
  code.nonzero(0, 'cleanupFailed');
  code.mov(0, 20);
  code.leave();

  code.label('cleanupFailed');
  code.mov(0, 23);
  code.call(cleanup);
  code.pointer(0, cleanupError);
  code.branch('failure');
  code.label('runnableFailed');
  code.mov(22, 0);
  throwJs();
  code.mov(0, 22);
  imported('free');
  code.mov(0, 23);
  code.call(cleanup);
  code.immediate(0, 0);
  code.leave();
  code.label('creationFailed');
  code.load(0, 23, 32);
  code.call(lifecycle.cleanupGroup);
  code.mov(0, 23);
  imported('free');
  code.load(0, 31, 104);
  code.zero(0, 'noCreationMessage');
  code.mov(22, 0);
  throwJs();
  code.mov(0, 22);
  imported('free');
  code.immediate(0, 0);
  code.leave();
  code.label('noCreationMessage');
  code.pointer(0, creationError);
  code.branch('failure');
  code.label('groupAllocationFailed');
  code.mov(0, 23);
  imported('free');
  code.label('allocationFailed');
  code.pointer(0, allocationError);
  code.branch('failure');
  code.label('dartFailure');
  code.mov(0, 22);
  api('Dart_GetError');
  code.mov(22, 0);
  // The error text is borrowed from the active Dart scope.
  throwJs();
  api('Dart_ExitScope');
  api('Dart_ExitIsolate');
  code.mov(0, 23);
  code.call(cleanup);
  code.immediate(0, 0);
  code.leave();
  code.label('failure');
  code.mov(22, 0);
  throwJs();
  code.immediate(0, 0);
  code.leave();

  final version = code.address;
  code.immediate(0, 8);
  code.word(0xd65f03c0);
  final native = code.finish();
  if (native.length > _page) {
    throw StateError('Bootstrap exceeds its code page');
  }
  final rx = Uint8List(_page + snapshot.textSize)
    ..setRange(0, native.length, native)
    ..setRange(_page, _page + snapshot.text.length, snapshot.text);
  final rw = Uint8List(_align(snapshot.dataSize) + state.length)
    ..setRange(
      _align(snapshot.dataSize),
      _align(snapshot.dataSize) + state.length,
      state,
    );
  image.addSegment('__NAPI_TEXT', rx, vmSize: rx.length, protections: 5);
  image.addSegment('__NAPI_DATA', rw, vmSize: rw.length, protections: 3);
  image.addExport('_napi_register_module_v1', entry);
  image.addExport('_node_api_module_get_api_version_v1', version);
  final output = File('${build.path}/addon.node');
  output.writeAsBytesSync(image.build());
  stdout.writeln('Built ${output.path} (${output.lengthSync()} bytes)');
}
