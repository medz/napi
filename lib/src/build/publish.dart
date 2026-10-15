import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

/// Publish a completed directory in one operation, never replacing a name that
/// another process owns. Both directories must be on the same filesystem.
///
/// Dart's Directory.rename may replace an empty destination on POSIX. There is
/// deliberately no check-then-rename fallback when exclusive rename is missing.
void publishDirectory(Directory source, Directory destination) {
  final from = source.absolute.path;
  final to = destination.absolute.path;
  if (from.contains('\x00') || to.contains('\x00')) {
    throw ArgumentError('Publication paths must not contain NUL.');
  }
  if (Platform.isWindows) {
    // Dart 3.13.5 Directory::Rename uses MoveFileExW(MOVEFILE_WRITE_THROUGH),
    // without MOVEFILE_REPLACE_EXISTING, and preserves dart:io's extended-length
    // path normalization. POSIX Directory.rename does not have this guarantee.
    // https://github.com/dart-lang/sdk/blob/3.13.5/runtime/bin/directory_win.cc
    Directory(from).renameSync(to);
    return;
  }
  final publisher = _publisher;
  publisher.withPath(from, (fromPointer) {
    publisher.withPath(to, (toPointer) {
      if (!publisher.rename(fromPointer, toPointer)) {
        throw FileSystemException(
          'Atomic no-replace publication failed. The destination may already '
          'exist, or the filesystem may not support exclusive rename. '
          'No replacing rename was attempted.',
          to,
        );
      }
    });
  });
}

final _publisher = _Publisher.load();

typedef _AllocateNative = Pointer<Void> Function(Size);
typedef _Allocate = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);
typedef _RenameAtNative = Int32 Function(
  Int32,
  Pointer<Uint8>,
  Int32,
  Pointer<Uint8>,
  Uint32,
);
typedef _RenameAt = int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _RenameNative = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Uint32);
typedef _Rename = int Function(Pointer<Uint8>, Pointer<Uint8>, int);

final class _Publisher {
  const _Publisher(this.allocate, this.free, this.rename);

  final _Allocate allocate;
  final _Free free;
  final bool Function(Pointer<Void>, Pointer<Void>) rename;

  static _Publisher load() {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw UnsupportedError(
        'Atomic no-replace publication is unavailable on '
        '${Platform.operatingSystem}.',
      );
    }
    try {
      final library = DynamicLibrary.process();
      final allocate = library.lookupFunction<_AllocateNative, _Allocate>(
        'malloc',
      );
      final free = library.lookupFunction<_FreeNative, _Free>('free');
      if (Platform.isLinux) {
        final rename = library.lookupFunction<_RenameAtNative, _RenameAt>(
          'renameat2',
        );
        // AT_FDCWD = -100; RENAME_NOREPLACE = 1. Absolute paths ignore the fds.
        return _Publisher(
          allocate,
          free,
          (from, to) => rename(-100, from.cast(), -100, to.cast(), 1) == 0,
        );
      }
      final rename = library.lookupFunction<_RenameNative, _Rename>(
        'renamex_np',
      );
      // RENAME_EXCL = 0x4.
      return _Publisher(
        allocate,
        free,
        (from, to) => rename(from.cast(), to.cast(), 4) == 0,
      );
    } on ArgumentError catch (error) {
      throw UnsupportedError(
        'Atomic no-replace publication is unavailable on '
        '${Platform.operatingSystem}: $error',
      );
    }
  }

  void withPath(String path, void Function(Pointer<Void>) action) {
    final units = utf8.encode(path);
    final pointer = allocate(units.length + 1);
    if (pointer == nullptr) {
      throw StateError('Cannot allocate publication path.');
    }
    try {
      final buffer = pointer.cast<Uint8>().asTypedList(units.length + 1);
      buffer.setAll(0, units);
      buffer[units.length] = 0;
      action(pointer);
    } finally {
      free(pointer);
    }
  }
}
