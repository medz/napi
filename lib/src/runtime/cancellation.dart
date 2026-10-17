import 'dart:async';

import '../api/cancellation.dart';

/// Shared registration ownership; host adapters provide fresh state and hooks.
abstract base class NapiAbortSignal implements AbortSignal {
  Set<_AbortRegistration>? _listeners;
  bool _armed = false;
  bool _notified = false;

  /// Installs the adapter's one weak host listener on the current owner.
  void armAbort();

  /// Removes that host listener immediately, without notifying business code.
  void disarmAbort();

  @override
  void Function() onAbort(void Function() listener) {
    final registration = _AbortRegistration(listener, Zone.current);
    (_listeners ??= {}).add(registration);
    try {
      if (_notified || aborted) {
        _notify();
      } else if (!_armed) {
        _armed = true;
        armAbort();
        // An adapter may synchronously observe an abort while arming.
        if (aborted) notifyAbort();
      }
    } catch (_) {
      _remove(registration);
      rethrow;
    }
    // Keeping this function is an ordinary Dart root for the token.
    return () => _remove(registration);
  }

  /// Called only from a valid owner; false host events do not notify listeners.
  void notifyAbort() {
    if (_notified || !aborted) return;
    _notify();
  }

  void _notify() {
    _notified = true;
    final listeners = _listeners;
    _listeners = null;
    _disarm();
    if (listeners == null) return;
    for (final registration in listeners) {
      registration.schedule();
    }
  }

  void _remove(_AbortRegistration registration) {
    registration.clear();
    final listeners = _listeners;
    if (listeners == null) return;
    listeners.remove(registration);
    if (listeners.isEmpty) {
      _listeners = null;
      _disarm();
    }
  }

  void _disarm() {
    if (!_armed) return;
    _armed = false;
    disarmAbort();
  }
}

final class _AbortRegistration {
  _AbortRegistration(this.listener, this.zone);

  void Function()? listener;
  Zone? zone;

  void schedule() {
    zone?.scheduleMicrotask(deliver);
  }

  void deliver() {
    final callback = listener;
    final registrationZone = zone;
    clear();
    if (callback != null) registrationZone!.runGuarded(callback);
  }

  void clear() {
    listener = null;
    zone = null;
  }
}
