import 'arm64.dart';

/// Group: Darwin mutex[64], condition[48], child head at 112, closing at 120.
/// Child: isolate at 8, next at 40, kind=1 at 56. Root Owner has kind=0.
({
  int initGroup,
  int registerChild,
  int shutdownChild,
  int cleanupChild,
  int closeGroup,
  int cleanupGroup,
})
emitLifecycle(
  Arm64 code,
  int Function(String) apiAddress,
  int Function(String) importSlot,
) {
  void imported(String name) => code.imported(importSlot(name));

  // void* initGroup(): fully initialize before exposing the group to the VM.
  final initGroup = code.address;
  code.enter();
  code.immediate(0, 1);
  code.immediate(1, 160);
  imported('calloc');
  code.zero(0, 'lifecycleInitDone');
  code.mov(19, 0);
  code.immediate(1, 0);
  imported('pthread_mutex_init');
  code.nonzero(0, 'lifecycleInitFree');
  code.add(0, 19, 64);
  code.immediate(1, 0);
  imported('pthread_cond_init');
  code.nonzero(0, 'lifecycleInitDestroyMutex');
  code.mov(0, 19);
  code.branch('lifecycleInitDone');
  code.label('lifecycleInitDestroyMutex');
  code.mov(0, 19);
  imported('pthread_mutex_destroy');
  code.label('lifecycleInitFree');
  code.mov(0, 19);
  imported('free');
  code.immediate(0, 0);
  code.label('lifecycleInitDone');
  code.leave();

  // void* registerChild(group, isolate): return null when closing or on OOM.
  // The VM has not invoked the child's Dart entry point yet.
  final registerChild = code.address;
  code.enter();
  code.mov(19, 0);
  code.mov(20, 1);
  code.zero(19, 'lifecycleRegisterNull');
  code.immediate(0, 1);
  code.immediate(1, 64);
  imported('calloc');
  code.zero(0, 'lifecycleRegisterNull');
  code.mov(21, 0);
  code.store(20, 21, 8);
  code.immediate(9, 1);
  code.store(9, 21, 56);
  code.mov(0, 19);
  imported('pthread_mutex_lock');
  code.load(9, 19, 120);
  code.nonzero(9, 'lifecycleRegisterClosed');
  code.load(9, 19, 112);
  code.store(9, 21, 40);
  code.store(21, 19, 112);
  code.mov(0, 19);
  imported('pthread_mutex_unlock');
  code.mov(0, 21);
  code.leave();
  code.label('lifecycleRegisterClosed');
  code.mov(0, 19);
  imported('pthread_mutex_unlock');
  code.mov(0, 21);
  imported('free');
  code.label('lifecycleRegisterNull');
  code.immediate(0, 0);
  code.leave();

  // shutdown_isolate(group, data): invalidate the address before the VM frees
  // the isolate. Otherwise a concurrent kill could target a reused address.
  final shutdownChild = code.address;
  code.enter();
  code.zero(0, 'lifecycleShutdownDone');
  code.zero(1, 'lifecycleShutdownDone');
  code.mov(19, 0);
  code.mov(20, 1);
  code.load(9, 20, 56);
  code.zero(9, 'lifecycleShutdownDone');
  imported('pthread_mutex_lock');
  code.store(31, 20, 8);
  code.mov(0, 19);
  imported('pthread_mutex_unlock');
  code.label('lifecycleShutdownDone');
  code.leave();

  // cleanup_isolate(group, data): the isolate is already unregistered/deleted.
  // Only now remove it from the list on which closeGroup waits.
  final cleanupChild = code.address;
  code.enter();
  code.zero(0, 'lifecycleCleanupDone');
  code.zero(1, 'lifecycleCleanupDone');
  code.mov(19, 0);
  code.mov(20, 1);
  code.load(9, 20, 56);
  code.zero(9, 'lifecycleCleanupDone');
  imported('pthread_mutex_lock');
  code.add(21, 19, 112);
  code.label('lifecycleFindChild');
  code.load(22, 21);
  code.zero(22, 'lifecycleChildRemoved');
  // EOR x9, x22, x20; CBZ compares the two pointers without altering them.
  code.word(0xca000000 | (20 << 16) | (22 << 5) | 9);
  code.zero(9, 'lifecycleUnlinkChild');
  code.add(21, 22, 40);
  code.branch('lifecycleFindChild');
  code.label('lifecycleUnlinkChild');
  code.load(9, 20, 40);
  code.store(9, 21);
  code.label('lifecycleChildRemoved');
  code.add(0, 19, 64);
  imported('pthread_cond_broadcast');
  code.mov(0, 19);
  imported('pthread_mutex_unlock');
  code.mov(0, 20);
  imported('free');
  code.label('lifecycleCleanupDone');
  code.leave();

  // void closeGroup(group): caller has entered the root isolate. The SDK runs
  // shutdown callbacks before acquiring its global port/isolate-list locks,
  // and cleanup callbacks after dropping those locks. Holding this mutex while
  // posting asynchronous kill messages therefore does not invert their order.
  final closeGroup = code.address;
  code.enter();
  code.zero(0, 'lifecycleCloseDone');
  code.mov(19, 0);
  imported('pthread_mutex_lock');
  code.immediate(9, 1);
  code.store(9, 19, 120);
  code.load(20, 19, 112);
  code.label('lifecycleKillNext');
  code.zero(20, 'lifecycleWait');
  code.load(0, 20, 8);
  code.zero(0, 'lifecycleSkipKill');
  code.call(apiAddress('Dart_KillIsolate'));
  code.label('lifecycleSkipKill');
  code.load(20, 20, 40);
  code.branch('lifecycleKillNext');
  code.label('lifecycleWait');
  code.load(9, 19, 112);
  code.zero(9, 'lifecycleCloseUnlock');
  code.add(0, 19, 64);
  code.mov(1, 19);
  imported('pthread_cond_wait');
  code.branch('lifecycleWait');
  code.label('lifecycleCloseUnlock');
  code.mov(0, 19);
  imported('pthread_mutex_unlock');
  code.label('lifecycleCloseDone');
  code.leave();

  // cleanup_group(group): called by the SDK after the final isolate is gone.
  // The embedder also calls it when initial group creation fails, because the
  // SDK deliberately omits cleanup_group for an unsuccessful initial spawn.
  final cleanupGroup = code.address;
  code.enter();
  code.zero(0, 'lifecycleGroupDone');
  code.mov(19, 0);
  code.add(0, 19, 64);
  imported('pthread_cond_destroy');
  code.mov(0, 19);
  imported('pthread_mutex_destroy');
  code.mov(0, 19);
  imported('free');
  code.label('lifecycleGroupDone');
  code.leave();

  return (
    initGroup: initGroup,
    registerChild: registerChild,
    shutdownChild: shutdownChild,
    cleanupChild: cleanupChild,
    closeGroup: closeGroup,
    cleanupGroup: cleanupGroup,
  );
}
