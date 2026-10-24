part of 'publish.dart';

final _windows = _WindowsOutput();

final class _WindowsOutput {
  final _kernel = DynamicLibrary.open('kernel32.dll');
  final _security = DynamicLibrary.open('advapi32.dll');
  late final _heap = _kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      )();
  late final _allocate = _kernel
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, Size),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');
  late final _free = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');
  late final _error = _kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  late final _create = _kernel
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
  late final _close = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  late final _getInfo = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Void>, int)
      >('GetFileInformationByHandleEx');
  late final _setInfo = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Void>, int)
      >('SetFileInformationByHandle');

  Pointer<Void> allocate(int size) {
    final result = _allocate(_heap, 8, size); // HEAP_ZERO_MEMORY.
    if (result == nullptr) {
      throw StateError('Cannot allocate Windows file data.');
    }
    return result;
  }

  void free(Pointer<Void> pointer) => _free(_heap, 0, pointer);

  T withPath<T>(String value, T Function(Pointer<Uint16>) action) {
    if (value.contains('\x00')) {
      throw ArgumentError('NUL in Windows file path.');
    }
    var absolute = path.normalize(path.absolute(value));
    if (!absolute.startsWith('\\\\?\\')) {
      absolute = absolute.startsWith('\\\\')
          ? '\\\\?\\UNC\\${absolute.substring(2)}'
          : '\\\\?\\$absolute';
    }
    final data = allocate((absolute.length + 1) * 2);
    try {
      data
          .cast<Uint16>()
          .asTypedList(absolute.length)
          .setAll(0, absolute.codeUnits);
      return action(data.cast());
    } finally {
      free(data);
    }
  }

  void check(bool success, String operation, String name) {
    if (!success) {
      throw FileSystemException(operation, name, OSError('', _error()));
    }
  }

  Pointer<Void> open(
    String name, {
    required bool directory,
    int access = 0x80, // FILE_READ_ATTRIBUTES.
    int sharing = 3, // FILE_SHARE_READ | FILE_SHARE_WRITE; deny rename/delete.
    bool create = false,
  }) {
    final handle = withPath(
      name,
      (pointer) => _create(
        pointer,
        access,
        sharing,
        nullptr,
        create ? 4 : 3, // OPEN_ALWAYS/EXISTING.
        0x00200000 |
            (directory
                ? 0x02000000
                : 0), // OPEN_REPARSE_POINT/BACKUP_SEMANTICS.
        nullptr,
      ),
    );
    check(
      handle != Pointer<Void>.fromAddress(-1),
      'Cannot open Windows build path.',
      name,
    );
    final info = allocate(40);
    try {
      check(
        _getInfo(handle, 0, info, 40) != 0,
        'Cannot inspect Windows build path.',
        name,
      );
      final attributes = info.cast<Uint32>()[8];
      if (attributes & 0x400 != 0 || (attributes & 0x10 != 0) != directory) {
        throw FileSystemException(
          'Windows build paths cannot be reparse points or unexpected file types.',
          name,
        );
      }
      return handle;
    } catch (_) {
      close(handle);
      rethrow;
    } finally {
      free(info);
    }
  }

  void close(Pointer<Void> handle) {
    check(_close(handle) != 0, 'Cannot close Windows build handle.', '');
  }

  void checkFilesystem(Directory directory) {
    final getVolume = _kernel
        .lookupFunction<
          Int32 Function(Pointer<Uint16>, Pointer<Uint16>, Uint32),
          int Function(Pointer<Uint16>, Pointer<Uint16>, int)
        >('GetVolumePathNameW');
    final driveType = _kernel
        .lookupFunction<
          Uint32 Function(Pointer<Uint16>),
          int Function(Pointer<Uint16>)
        >('GetDriveTypeW');
    final volumeInfo = _kernel
        .lookupFunction<
          Int32 Function(
            Pointer<Uint16>,
            Pointer<Uint16>,
            Uint32,
            Pointer<Uint32>,
            Pointer<Uint32>,
            Pointer<Uint32>,
            Pointer<Uint16>,
            Uint32,
          ),
          int Function(
            Pointer<Uint16>,
            Pointer<Uint16>,
            int,
            Pointer<Uint32>,
            Pointer<Uint32>,
            Pointer<Uint32>,
            Pointer<Uint16>,
            int,
          )
        >('GetVolumeInformationW');
    final volume = allocate(65536);
    final filesystem = allocate(64);
    try {
      withPath(directory.path, (name) {
        check(
          getVolume(name, volume.cast(), 32768) != 0,
          'Cannot inspect Windows build volume.',
          directory.path,
        );
      });
      check(
        volumeInfo(
              volume.cast(),
              nullptr,
              0,
              nullptr,
              nullptr,
              nullptr,
              filesystem.cast(),
              32,
            ) !=
            0,
        'Cannot inspect Windows build filesystem.',
        directory.path,
      );
      final name = String.fromCharCodes(
        filesystem
            .cast<Uint16>()
            .asTypedList(32)
            .takeWhile((unit) => unit != 0),
      );
      if (driveType(volume.cast()) != 3 || name != 'NTFS') {
        throw UnsupportedError(
          'Managed Windows rebuilds require a local NTFS filesystem.',
        );
      }
    } finally {
      free(volume);
      free(filesystem);
    }
  }

  ({int changed, int attributes}) metadata(FileSystemEntity entity) {
    final handle = open(
      entity.path,
      directory: entity is Directory,
      sharing: 7,
    );
    final basic = allocate(40);
    try {
      check(
        _getInfo(handle, 0, basic, 40) != 0,
        'Cannot inspect Windows file metadata.',
        entity.path,
      );
      return (
        changed: basic.cast<Int64>()[3],
        attributes: basic.cast<Uint32>()[8],
      );
    } finally {
      free(basic);
      close(handle);
    }
  }

  void copyMetadata(
    String source,
    String destination, {
    bool preserveTimes = true,
  }) {
    final from = open(
      source,
      directory: Directory(source).existsSync(),
      access: 0x20080,
      sharing: 7,
    );
    Pointer<Void> to = nullptr;
    final basic = allocate(40);
    try {
      to = open(
        destination,
        directory: Directory(destination).existsSync(),
        access: 0xe0100,
        sharing: 7,
      );
      check(
        _getInfo(from, 0, basic, 40) != 0,
        'Cannot read Windows file metadata.',
        source,
      );
      // Zero means leave the destination timestamp unchanged.
      if (!preserveTimes) basic.cast<Int64>().asTypedList(4).fillRange(0, 4, 0);
      basic.cast<Int64>()[3] =
          0; // Change time belongs to the new filesystem object.
      _copySecurity(from, to, destination);
      check(
        _setInfo(to, 0, basic, 40) != 0,
        'Cannot preserve Windows file metadata.',
        destination,
      );
    } finally {
      free(basic);
      if (to != nullptr) close(to);
      close(from);
    }
  }

  void _copySecurity(Pointer<Void> from, Pointer<Void> to, String destination) {
    final get = _security
        .lookupFunction<
          Uint32 Function(
            Pointer<Void>,
            Int32,
            Uint32,
            Pointer<Pointer<Void>>,
            Pointer<Pointer<Void>>,
            Pointer<Pointer<Void>>,
            Pointer<Pointer<Void>>,
            Pointer<Pointer<Void>>,
          ),
          int Function(
            Pointer<Void>,
            int,
            int,
            Pointer<Pointer<Void>>,
            Pointer<Pointer<Void>>,
            Pointer<Pointer<Void>>,
            Pointer<Pointer<Void>>,
            Pointer<Pointer<Void>>,
          )
        >('GetSecurityInfo');
    final set = _security
        .lookupFunction<
          Uint32 Function(
            Pointer<Void>,
            Int32,
            Uint32,
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Void>,
          ),
          int Function(
            Pointer<Void>,
            int,
            int,
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Void>,
            Pointer<Void>,
          )
        >('SetSecurityInfo');
    final control = _security
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint32>),
          int Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint32>)
        >('GetSecurityDescriptorControl');
    final localFree = _kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    final data = allocate(6 * sizeOf<IntPtr>());
    final pointers = data.cast<Pointer<Void>>();
    try {
      var result = get(
        from,
        1,
        7,
        pointers,
        pointers + 1,
        pointers + 2,
        nullptr,
        pointers + 3,
      );
      if (result != 0) {
        throw FileSystemException(
          'Cannot read Windows file security.',
          destination,
          OSError('', result),
        );
      }
      check(
        control(pointers[3], (pointers + 4).cast(), (pointers + 5).cast()) != 0,
        'Cannot read Windows security inheritance.',
        destination,
      );
      final protected = (pointers + 4).cast<Uint16>().value & 0x1000 != 0;
      result = set(
        to,
        1,
        7 | (protected ? 0x80000000 : 0x20000000),
        pointers[0],
        pointers[1],
        pointers[2],
        nullptr,
      );
      if (result != 0) {
        throw FileSystemException(
          'Cannot preserve Windows file security.',
          destination,
          OSError('', result),
        );
      }
    } finally {
      if (pointers[3] != nullptr) localFree(pointers[3]);
      free(data);
    }
  }
}

final class _WindowsPackageLock {
  _WindowsPackageLock(this.directory, this.handles);
  final Directory directory;
  final List<Pointer<Void>> handles;

  static _WindowsPackageLock acquire(Directory output) {
    final normalized = path.normalize(output.absolute.path);
    if (path
        .split(normalized)
        .any((part) => part.endsWith('.') || part.endsWith(' '))) {
      throw ArgumentError(
        'Managed Windows build paths cannot end in a dot or space.',
      );
    }
    final locks = Directory(path.join(path.dirname(normalized), '.napi-locks'));
    final state = Directory(path.join(locks.path, path.basename(normalized)));
    final handles = <Pointer<Void>>[];
    try {
      locks.createSync();
      handles.add(_windows.open(locks.path, directory: true));
      state.createSync();
      handles.add(_windows.open(state.path, directory: true));
      try {
        handles.add(
          _windows.open(
            path.join(state.path, 'lock'),
            directory: false,
            access: 0xc0000000,
            sharing: 0,
            create: true,
          ),
        );
      } on FileSystemException catch (error) {
        throw FileSystemException(
          'Another package build holds the lock, or the lock cannot be opened.',
          error.path,
          error.osError,
        );
      }
      return _WindowsPackageLock(state, handles);
    } catch (_) {
      for (final handle in handles.reversed) {
        _windows.close(handle);
      }
      rethrow;
    }
  }

  void release() {
    while (handles.isNotEmpty) {
      _windows.close(handles.removeLast());
    }
  }
}
