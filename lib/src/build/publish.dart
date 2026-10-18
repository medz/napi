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
      if (!publisher.rename(fromPointer, toPointer, false)) {
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

/// Exchange two completed directories in one filesystem operation. The old
/// destination remains at [source]; callers must never roll back a committed
/// exchange if deleting that backup fails.
void exchangeDirectories(Directory source, Directory destination) {
  final publisher = _publisher;
  publisher.withPath(source.absolute.path, (from) {
    publisher.withPath(destination.absolute.path, (to) {
      if (!publisher.rename(from, to, true)) {
        throw FileSystemException(
          'Atomic package exchange failed; no replacing rename was attempted.',
          destination.path,
        );
      }
    });
  });
}

/// Once committed, auxiliary cleanup is best effort, never a failed build or
/// a reason to roll back. Retain its path even if the diagnostic stream closed.
Future<void> cleanPackageStaging(
  Directory directory, {
  required bool committed,
}) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } catch (error) {
    if (!committed) rethrow;
    try {
      stderr.writeln(
        'Package committed; cleanup left ${directory.path}: $error',
      );
    } catch (_) {
      /* Publication remains successful. */
    }
  }
}

/// Rebuild support is narrower than fresh publication. In particular, a local
/// filesystem is required: a remote rename error need not mean no commit.
void checkPackageRebuildFilesystem(Directory directory) {
  if (!Platform.isMacOS) {
    throw UnsupportedError(
      'Managed package replacement is currently qualified only on macOS.',
    );
  }
  final publisher = _publisher;
  final library = DynamicLibrary.process();
  final statfs = library.lookupFunction<_StatfsNative, _Statfs>('statfs64');
  // Darwin statfs64 is 2168 bytes on both supported 64-bit ABIs.
  // Read only the documented fixed prefix, never an OS pointer.
  final buffer = publisher.allocate(4096);
  if (buffer == nullptr) throw StateError('Cannot inspect package filesystem.');
  try {
    publisher.withPath(directory.path, (name) {
      if (statfs(name.cast(), buffer) != 0) {
        throw FileSystemException(
          'Cannot inspect package filesystem.',
          directory.path,
        );
      }
    });
    final flags = buffer.cast<Uint32>()[16];
    final name = String.fromCharCodes(
      buffer
          .cast<Uint8>()
          .asTypedList(88)
          .sublist(72)
          .takeWhile((byte) => byte != 0),
    );
    final supported = flags & 0x1000 != 0 && name == 'apfs';
    if (!supported) {
      throw UnsupportedError(
        'Managed package rebuild requires a qualified local filesystem.',
      );
    }
  } finally {
    publisher.free(buffer);
  }
}

/// dart:io File.copy uses COPYFILE_ALL on the pinned macOS SDK. Directories
/// need a separate metadata-only copy, after creating their new children.
void copyPackageDirectoryMetadata(Directory source, Directory destination) {
  if (!Platform.isMacOS) {
    throw UnsupportedError(
      'Directory metadata preservation is unavailable on this host.',
    );
  }
  final publisher = _publisher;
  final copy = DynamicLibrary.process().lookupFunction<_CopyNative, _Copy>(
    'copyfile',
  );
  publisher.withPath(source.path, (from) {
    publisher.withPath(destination.path, (to) {
      // COPYFILE_METADATA | COPYFILE_NOFOLLOW. Includes stat, ACLs and xattrs.
      if (copy(from.cast(), to.cast(), nullptr, 7 | (3 << 18)) != 0) {
        throw FileSystemException(
          'Cannot preserve package directory metadata.',
          source.path,
        );
      }
    });
  });
}

/// A stable sibling lock, shared by independent processes and Dart isolates.
/// Its inode deliberately survives release: unlinking it can split contenders
/// between two different locks. It is not a lease on arbitrary author edits.
final class PackageLock {
  PackageLock._(this._descriptor);
  int? _descriptor;

  static PackageLock acquire(Directory output) {
    final name = '${output.path}.napi-lock';
    final type = FileSystemEntity.typeSync(name, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw FileSystemException('Package lock is not a regular file.', name);
    }
    // Exclusive creation cannot follow a substituted symlink. Another builder
    // may win creation, in which case both open the same retained regular file.
    if (type == FileSystemEntityType.notFound) {
      try {
        File(name).createSync(exclusive: true);
      } on FileSystemException {
        if (FileSystemEntity.typeSync(name, followLinks: false) !=
            FileSystemEntityType.file) {
          rethrow;
        }
      }
    }
    final publisher = _publisher;
    var descriptor = -1;
    publisher.withPath(name, (pointer) {
      descriptor = publisher.open(
        pointer.cast(),
        2 | (Platform.isMacOS ? 0x1000100 : 0xa0000),
      ); // O_RDWR | O_CLOEXEC | O_NOFOLLOW.
    });
    if (descriptor < 0) {
      throw FileSystemException('Cannot open package lock.', name);
    }
    // LOCK_EX | LOCK_NB. A separately opened fd contends even in this process.
    if (publisher.flock(descriptor, 6) != 0) {
      publisher.close(descriptor);
      throw FileSystemException('Another package build holds the lock.', name);
    }
    return PackageLock._(descriptor);
  }

  void release() {
    final descriptor = _descriptor;
    if (descriptor == null) return;
    _descriptor = null;
    _publisher.close(descriptor);
  }
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
typedef _OpenNative = Int32 Function(Pointer<Uint8>, Int32);
typedef _Open = int Function(Pointer<Uint8>, int);
typedef _FlockNative = Int32 Function(Int32, Int32);
typedef _Flock = int Function(int, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _Close = int Function(int);
typedef _StatfsNative = Int32 Function(Pointer<Uint8>, Pointer<Void>);
typedef _Statfs = int Function(Pointer<Uint8>, Pointer<Void>);
typedef _CopyNative = Int32 Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Void>,
  Uint32,
);
typedef _Copy = int Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Void>,
  int,
);

final class _Publisher {
  const _Publisher(
    this.allocate,
    this.free,
    this.rename,
    this.open,
    this.flock,
    this.close,
  );

  final _Allocate allocate;
  final _Free free;
  final bool Function(Pointer<Void>, Pointer<Void>, bool) rename;
  final _Open open;
  final _Flock flock;
  final _Close close;

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
      final open = library.lookupFunction<_OpenNative, _Open>('open');
      final flock = library.lookupFunction<_FlockNative, _Flock>('flock');
      final close = library.lookupFunction<_CloseNative, _Close>('close');
      if (Platform.isLinux) {
        final rename = library.lookupFunction<_RenameAtNative, _RenameAt>(
          'renameat2',
        );
        // AT_FDCWD = -100; RENAME_NOREPLACE = 1. Absolute paths ignore the fds.
        return _Publisher(
          allocate,
          free,
          (from, to, exchange) =>
              rename(-100, from.cast(), -100, to.cast(), exchange ? 2 : 1) == 0,
          open,
          flock,
          close,
        );
      }
      final rename = library.lookupFunction<_RenameNative, _Rename>(
        'renamex_np',
      );
      // RENAME_EXCL = 0x4.
      return _Publisher(
        allocate,
        free,
        (from, to, exchange) =>
            rename(from.cast(), to.cast(), exchange ? 2 : 4) == 0,
        open,
        flock,
        close,
      );
    } on ArgumentError catch (error) {
      throw UnsupportedError(
        'Atomic no-replace publication is unavailable on '
        '${Platform.operatingSystem}: $error',
      );
    }
  }

  void withPath(String path, void Function(Pointer<Void>) action) {
    if (path.contains('\x00')) {
      throw ArgumentError('Publication paths must not contain NUL.');
    }
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
