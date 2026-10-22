part of 'publish.dart';

final _linuxMetadata = _LinuxMetadata();

/// Linux's statx layout is fixed across 64-bit ABIs. Traditional stat layouts
/// differ between x64 and arm64; do not interpret one as the other.
final class _LinuxMetadata {
  final _lib = DynamicLibrary.process();
  final _errno = DynamicLibrary.process()
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        '__errno_location',
      );
  late final _statfs = _lib.lookupFunction<_StatfsNative, _Statfs>('statfs');
  late final _statx = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Uint8>, Int32, Uint32, Pointer<Void>),
        int Function(int, Pointer<Uint8>, int, int, Pointer<Void>)
      >('statx');
  late final _chown = _lib
      .lookupFunction<
        Int32 Function(Int32, Uint32, Uint32),
        int Function(int, int, int)
      >('fchown');
  late final _chmod = _lib
      .lookupFunction<Int32 Function(Int32, Uint32), int Function(int, int)>(
        'fchmod',
      );
  late final _times = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Int64>),
        int Function(int, Pointer<Int64>)
      >('futimens');
  late final _list = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Void>, Size),
        int Function(int, Pointer<Void>, int)
      >('flistxattr');
  late final _get = _lib
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Void>, Pointer<Void>, Size),
        int Function(int, Pointer<Void>, Pointer<Void>, int)
      >('fgetxattr');
  late final _set = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>, Pointer<Void>, Size, Int32),
        int Function(int, Pointer<Void>, Pointer<Void>, int, int)
      >('fsetxattr');
  late final _remove = _lib
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>),
        int Function(int, Pointer<Void>)
      >('fremovexattr');

  void checkFilesystem(Directory directory) {
    _checkHost();
    final data = _allocate(4096);
    try {
      _publisher.withPath(directory.path, (name) {
        _check(_statfs(name.cast(), data) == 0, 'statfs', directory.path);
      });
      final type = data.cast<Int64>().value;
      // ext2/3/4 share their superblock magic. An unsupported exchange still
      // fails without a fallback rename. tmpfs is also local to this kernel.
      if (type != 0xef53 && type != 0x01021994) {
        throw UnsupportedError(
          'Managed package rebuilds on Linux require a local ext filesystem or tmpfs.',
        );
      }
    } finally {
      _publisher.free(data);
    }
  }

  PackageAccessTime accessTime(String path) {
    _checkHost();
    final fd = _open(path);
    Pointer<Void> data = nullptr;
    try {
      data = _allocate(256);
      _stat(fd, data, path);
      return (
        seconds: data.cast<Int64>()[8],
        nanoseconds: data.cast<Uint32>()[18],
      );
    } finally {
      if (data != nullptr) _publisher.free(data);
      _publisher.close(fd);
    }
  }

  void copy(
    String source,
    String destination, {
    bool preserveTimes = true,
    PackageAccessTime? accessTime,
  }) {
    _checkHost();
    final from = _open(source);
    var to = -1;
    Pointer<Void> data = nullptr;
    try {
      to = _open(destination);
      // statx occupies 256 bytes; two 64-bit timespecs follow it.
      data = _allocate(288);
      _stat(from, data, source);
      final uid = data.cast<Uint32>()[5];
      final gid = data.cast<Uint32>()[6];
      final mode = data.cast<Uint16>()[14];
      final kind = mode & 0xf000;
      if (kind != 0x8000 && kind != 0x4000) {
        throw FileSystemException(
          'Package metadata requires a regular file or directory.',
          source,
        );
      }
      final accessSeconds = accessTime?.seconds ?? data.cast<Int64>()[8];
      final accessNanos = accessTime?.nanoseconds ?? data.cast<Uint32>()[18];
      final modifiedSeconds = data.cast<Int64>()[14];
      final modifiedNanos = data.cast<Uint32>()[30];
      // Ownership changes can clear set-ID bits and security.capability.
      // Restore ownership before xattrs and the final permission mode.
      _check(_chown(to, uid, gid) == 0, 'fchown', destination);
      // Retained read-only files still need write permission for user xattrs.
      _check(_chmod(to, (mode & 0xfff) | 0x80) == 0, 'fchmod', destination);
      _copyAttributes(from, to, source, destination);
      _check(_chmod(to, mode & 0xfff) == 0, 'fchmod', destination);
      final times = data.cast<Int64>() + 32;
      times[0] = accessSeconds;
      times[1] = accessNanos;
      times[2] = modifiedSeconds;
      times[3] = modifiedNanos;
      if (preserveTimes) {
        _check(_times(to, times) == 0, 'futimens', destination);
      }
      _stat(to, data, destination);
      if (data.cast<Uint32>()[5] != uid ||
          data.cast<Uint32>()[6] != gid ||
          data.cast<Uint16>()[14] != mode ||
          preserveTimes &&
              (data.cast<Int64>()[8] != accessSeconds ||
                  data.cast<Uint32>()[18] != accessNanos ||
                  data.cast<Int64>()[14] != modifiedSeconds ||
                  data.cast<Uint32>()[30] != modifiedNanos)) {
        throw FileSystemException(
          'Package file metadata was not preserved.',
          destination,
        );
      }
    } finally {
      if (data != nullptr) _publisher.free(data);
      if (to >= 0) _publisher.close(to);
      _publisher.close(from);
    }
  }

  void _copyAttributes(int from, int to, String source, String destination) {
    final names = _names(from, source).toSet();
    for (final name in _names(to, destination)) {
      if (!names.contains(name)) {
        _publisher.withBytes(name.codeUnits, (key) {
          _check(_remove(to, key) == 0, 'fremovexattr', destination);
        });
      }
    }
    // An access ACL can remove owner-write permission; apply it after xattrs.
    const accessAcl = 'system.posix_acl_access';
    for (final name in [
      ...names.where((name) => name != accessAcl),
      if (names.contains(accessAcl)) accessAcl,
    ]) {
      _publisher.withBytes(name.codeUnits, (key) {
        final length = _size(_get(from, key, nullptr, 0), source);
        final value = _allocate(length == 0 ? 1 : length);
        try {
          final read = _get(from, key, value, length);
          _check(read >= 0, 'fgetxattr', source);
          if (read != length) {
            throw FileSystemException(
              'Package attributes changed while copying.',
              source,
            );
          }
          _check(
            _set(to, key, value, length, 0) == 0,
            'fsetxattr',
            destination,
          );
        } finally {
          _publisher.free(value);
        }
      });
    }
  }

  List<String> _names(int fd, String path) {
    final length = _size(_list(fd, nullptr, 0), path);
    if (length == 0) return const [];
    final data = _allocate(length);
    try {
      final read = _list(fd, data, length);
      _check(read >= 0, 'flistxattr', path);
      if (read != length) {
        throw FileSystemException(
          'Package attributes changed while copying.',
          path,
        );
      }
      // Attribute names are bytes, not necessarily UTF-8. Latin-1 preserves
      // their exact spelling for comparison and the next syscall.
      return latin1.decode(data.cast<Uint8>().asTypedList(length)).split('\x00')
        ..removeLast();
    } finally {
      _publisher.free(data);
    }
  }

  int _open(String path) {
    var fd = -1;
    _publisher.withPath(path, (name) {
      // O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK. A replaced FIFO must
      // not block the build before statx can reject its type.
      fd = _publisher.open(name.cast(), 0x80800 | _linuxNoFollowFlag);
      _check(fd >= 0, 'open', path);
    });
    return fd;
  }

  void _stat(int fd, Pointer<Void> data, String path) {
    _publisher.withPath('', (empty) {
      // AT_EMPTY_PATH; TYPE, MODE, UID, GID, ATIME and MTIME.
      _check(_statx(fd, empty.cast(), 0x1000, 0x7b, data) == 0, 'statx', path);
    });
    if (data.cast<Uint32>().value & 0x7b != 0x7b) {
      throw FileSystemException(
        'Required package file metadata is unavailable.',
        path,
      );
    }
  }

  void _checkHost() {
    if (sizeOf<IntPtr>() != 8) {
      throw UnsupportedError(
        'Managed Linux package rebuilds require a 64-bit host.',
      );
    }
  }

  int _size(int length, String path) {
    _check(length >= 0, 'read extended attributes', path);
    if (length > 65536) {
      throw FileSystemException(
        'Package extended attributes exceed Linux limits.',
        path,
      );
    }
    return length;
  }

  Pointer<Void> _allocate(int size) {
    final data = _publisher.allocate(size);
    if (data == nullptr) {
      throw StateError('Cannot allocate Linux file metadata.');
    }
    return data;
  }

  void _check(bool ok, String operation, String path) {
    if (!ok) {
      final code = _errno().value;
      throw FileSystemException(
        'Cannot preserve package metadata ($operation).',
        path,
        OSError('', code),
      );
    }
  }
}
