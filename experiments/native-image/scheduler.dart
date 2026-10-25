import 'arm64.dart';

/// Emits callbacks for a Node-owned isolate. Owner fields are TSFN, isolate,
/// environment and closing at offsets 0, 8, 16 and 24 respectively.
({int notify, int callJs, int finalize}) emitScheduler(
  Arm64 code,
  int Function(String) apiAddress,
  int Function(String) importSlot, {
  required int callThreadsafeSlot,
  required int isolateLibraryName,
  required int drainMicrotasksName,
  required int afterPumpName,
  required int reportError,
}) {
  void api(String name) => code.call(apiAddress(name));

  // VM notifications may run on any thread. The TSFN is immutable until
  // shutdown has closed all ports and waited out their notification calls.
  final notify = code.address;
  code.enter();
  api('Dart_IsolateData');
  code.zero(0, 'schedulerNotifyDone');
  code.load(0, 0);
  code.zero(0, 'schedulerNotifyDone');
  code.immediate(1, 0);
  code.immediate(2, 0); // napi_tsfn_nonblocking; queue size is unlimited.
  code.imported(callThreadsafeSlot);
  code.label('schedulerNotifyDone');
  code.leave();

  // TSFN calls this on its Node environment thread. During abort, env may be
  // null; queued notifications must then be discarded without entering Dart.
  final callJs = code.address;
  code.enter();
  code.zero(0, 'schedulerCallDone');
  code.mov(19, 0);
  code.mov(20, 2);
  code.load(9, 20, 24);
  code.nonzero(9, 'schedulerCallDone');
  code.load(0, 20, 8);
  code.zero(0, 'schedulerCallDone');
  api('Dart_EnterIsolate');
  api('Dart_EnterScope');
  api('Dart_HandleMessage');
  code.mov(21, 0);
  api('Dart_IsError');
  code.nonzero(0, 'schedulerDartError');

  // A synchronous FFI export can schedule a microtask without posting a port
  // message. Its initial TSFN wake must drain the VM's pending callback too.
  code.pointer(0, isolateLibraryName);
  api('Dart_NewStringFromCString');
  api('Dart_LookupLibrary');
  code.mov(21, 0);
  api('Dart_IsError');
  code.nonzero(0, 'schedulerDartError');
  code.pointer(0, drainMicrotasksName);
  api('Dart_NewStringFromCString');
  code.mov(1, 0);
  code.mov(0, 21);
  code.immediate(2, 0);
  code.immediate(3, 0);
  api('Dart_Invoke');
  code.mov(21, 0);
  api('Dart_IsError');
  code.zero(0, 'schedulerAfterPump');

  code.label('schedulerDartError');
  code.mov(0, 21);
  api('Dart_GetError');
  code.mov(1, 0);
  code.mov(0, 19);
  code.call(reportError);

  // A Node uncaughtException listener may handle the error. Refresh keepalive
  // state in that case too, so a completed wake cannot keep Node running.
  code.label('schedulerAfterPump');
  api('Dart_RootLibrary');
  code.mov(21, 0);
  code.pointer(0, afterPumpName);
  api('Dart_NewStringFromCString');
  code.mov(1, 0);
  code.mov(0, 21);
  code.immediate(2, 0);
  code.immediate(3, 0);
  api('Dart_Invoke');
  code.mov(21, 0);
  api('Dart_IsError');
  code.zero(0, 'schedulerExitIsolate');

  // Report an afterPump failure once; retrying it here could loop forever.
  code.mov(0, 21);
  api('Dart_GetError');
  code.mov(1, 0);
  code.mov(0, 19);
  code.call(reportError);

  code.label('schedulerExitIsolate');
  api('Dart_ExitScope');
  api('Dart_ExitIsolate');
  code.label('schedulerCallDone');
  code.leave();

  // Only the TSFN finalizer frees Owner, after all queued callbacks finish.
  final finalize = code.address;
  code.enter();
  code.mov(0, 1);
  code.imported(importSlot('free'));
  code.leave();

  return (notify: notify, callJs: callJs, finalize: finalize);
}
