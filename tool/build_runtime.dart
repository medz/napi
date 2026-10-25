import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';

const _sdkVersion = '3.13.5';
const _sdkRevision = '04bcd1036cdc799ac6564988f159ee454d42c822';
const _nodeVersion = '24.19.0';

Future<void> main(List<String> args) async {
  try {
    await _build(args);
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}

Future<void> _build(List<String> args) async {
  if (args.isEmpty || args.contains('--help')) {
    stdout.writeln(
      'Usage: dart run tool/build_runtime.dart '
      '--sdk <SDK checkout> --node-headers <include/node> '
      '[--node-lib <node.lib>] [--arch arm64|x64] [--jobs <count>]\n'
      'The SDK checkout must already have its dependencies and build tools.\n'
      'Windows requires Node $_nodeVersion headers and its matching node.lib.',
    );
    return;
  }
  final options = <String, String>{};
  const names = {'sdk', 'node-headers', 'node-lib', 'arch', 'jobs'};
  for (var i = 0; i < args.length; i += 2) {
    final option = args[i];
    if (!option.startsWith('--') ||
        !names.contains(option.substring(2)) ||
        i + 1 == args.length ||
        args[i + 1].startsWith('--') ||
        options.containsKey(option.substring(2))) {
      throw ArgumentError('Invalid or repeated option: $option');
    }
    options[option.substring(2)] = args[i + 1];
  }
  final sdkPath = options['sdk'];
  final headersPath = options['node-headers'];
  if (sdkPath == null || headersPath == null) {
    throw ArgumentError('--sdk and --node-headers are required');
  }
  final sdk = Directory(sdkPath).absolute;
  final headers = Directory(headersPath).absolute;
  final architecture = options['arch'] ?? _hostArchitecture();
  if (architecture != 'arm64' && architecture != 'x64') {
    throw ArgumentError('--arch must be arm64 or x64');
  }
  final jobs = options['jobs'] == null
      ? Platform.numberOfProcessors.clamp(1, 4)
      : int.parse(options['jobs']!);
  if (jobs < 1) throw ArgumentError('--jobs must be positive');
  if (!await File.fromUri(sdk.uri.resolve('tools/gn.py')).exists() ||
      !await File.fromUri(headers.uri.resolve('node_api.h')).exists()) {
    throw ArgumentError(
      'Expected an SDK source checkout and Node header directory',
    );
  }
  final revision = await Process.run('git', [
    '-C',
    sdk.path,
    'rev-parse',
    'HEAD',
  ]);
  if (revision.exitCode != 0 ||
      revision.stdout.toString().trim() != _sdkRevision) {
    throw StateError('The SDK checkout must be at $_sdkRevision');
  }

  File? nodeLibrary;
  if (Platform.isWindows) {
    final libraryPath = options['node-lib'];
    if (libraryPath == null || !await File(libraryPath).exists()) {
      throw ArgumentError('--node-lib is required on Windows');
    }
    nodeLibrary = File(libraryPath).absolute;
    final versionHeader = await File.fromUri(
      headers.uri.resolve('node_version.h'),
    ).readAsString();
    final version = ['MAJOR', 'MINOR', 'PATCH']
        .map((part) {
          final match = RegExp('#define NODE_${part}_VERSION\\s+(\\d+)')
              .firstMatch(versionHeader);
          return match?.group(1);
        })
        .join('.');
    if (version != _nodeVersion) {
      throw StateError('Windows requires Node $_nodeVersion headers');
    }
  }

  final package = Directory.fromUri(Platform.script.resolve('../'));
  final overlay = Directory.fromUri(sdk.uri.resolve('napi/'));
  await _copyDirectory(Directory.fromUri(package.uri.resolve('src/')), overlay);
  await _copyDirectory(
    headers,
    Directory.fromUri(overlay.uri.resolve('node/')),
  );
  if (nodeLibrary != null) {
    await nodeLibrary.copy(overlay.uri.resolve('node/node.lib').toFilePath());
  }

  await _run(
    Platform.isWindows ? 'python' : 'python3',
    ['-c', _buildSdkTarget, architecture, '$jobs'],
    sdk.path,
    environment: {if (Platform.isWindows) 'DEPOT_TOOLS_WIN_TOOLCHAIN': '0'},
  );

  final os = Platform.operatingSystem;
  final outputRoot = Platform.isMacOS ? 'xcodebuild' : 'out';
  final libraryName = switch (os) {
    'windows' => 'napi_template.dll',
    'macos' => 'libnapi_template.dylib',
    'linux' => 'libnapi_template.so',
    _ => throw UnsupportedError('Unsupported build host: $os'),
  };
  final built = File.fromUri(
    sdk.uri.resolve(
      '$outputRoot/Product${architecture.toUpperCase()}/$libraryName',
    ),
  );
  final templates = Directory.fromUri(
    package.uri.resolve('lib/src/compiler/templates/'),
  );
  await templates.create(recursive: true);
  await _writeNotices(sdk, templates);
  final target = '${os}_$architecture';
  final output = await built.copy(
    templates.uri.resolve('$target.node').toFilePath(),
  );
  if (Platform.isLinux) {
    await _run(
      sdk.uri
          .resolve(
            'buildtools/linux-${_hostArchitecture()}/clang/bin/llvm-strip',
          )
          .toFilePath(),
      ['--strip-unneeded', output.path],
      sdk.path,
    );
  }
  final digest = await sha256.bind(output.openRead()).first;
  await File.fromUri(templates.uri.resolve('$target.json')).writeAsString(
    '${const JsonEncoder.withIndent('  ').convert({'sdk': _sdkVersion, 'revision': _sdkRevision, 'target': target, 'napi': 8, 'format': 1, 'sha256': digest.toString()})}\n',
  );
  stdout.writeln(output.path);
}

String _hostArchitecture() => switch (Abi.current()) {
  Abi.linuxArm64 || Abi.macosArm64 || Abi.windowsArm64 => 'arm64',
  Abi.linuxX64 || Abi.macosX64 || Abi.windowsX64 => 'x64',
  _ => throw UnsupportedError('Unsupported build host: ${Abi.current()}'),
};

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entry in source.list(followLinks: false)) {
    final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
    final target = destination.uri.resolve(name);
    if (entry is Directory) {
      await _copyDirectory(entry, Directory.fromUri(target));
    } else if (entry is File) {
      await entry.copy(target.toFilePath());
    } else {
      throw UnsupportedError('Cannot copy source link: ${entry.path}');
    }
  }
}

Future<void> _run(
  String executable,
  List<String> arguments,
  String directory, {
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: directory,
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final status = await process.exitCode;
  if (status != 0) {
    throw ProcessException(executable, arguments, 'Build failed', status);
  }
}

Future<void> _writeNotices(Directory sdk, Directory templates) async {
  const licenses = [
    'LICENSE',
    'third_party/icu/LICENSE',
    'third_party/boringssl/src/LICENSE',
    'third_party/zlib/LICENSE',
    'third_party/double-conversion/LICENSE',
    'third_party/cpu_features/src/LICENSE',
    'third_party/libcxx/LICENSE.TXT',
    'third_party/libcxxabi/LICENSE.TXT',
  ];
  final compilerDirectory = switch (Platform.operatingSystem) {
    'windows' => 'win-x64',
    'macos' => 'mac-${_hostArchitecture()}',
    'linux' => 'linux-${_hostArchitecture()}',
    _ => throw UnsupportedError('Unsupported build host'),
  };
  final output = StringBuffer();
  for (final path in [
    ...licenses,
    'buildtools/$compilerDirectory/clang/LICENSE',
  ]) {
    output
      ..writeln(path)
      ..writeln('=' * path.length)
      ..writeln(await File.fromUri(sdk.uri.resolve(path)).readAsString())
      ..writeln();
  }
  await File.fromUri(templates.uri.resolve('NOTICES'))
      .writeAsString(output.toString());
}

// Keep the SDK's platform configuration; only select our additional root target.
const _buildSdkTarget = r'''
import os
import subprocess
import sys
if sys.platform == 'darwin':
    for key in ('CPATH', 'LIBRARY_PATH', 'SDKROOT'):
        os.environ.pop(key, None)
sys.path.insert(0, os.path.join(os.getcwd(), 'tools'))
sys.argv[0] = os.path.join(os.getcwd(), 'tools', 'gn.py')
import gn
arch, jobs = sys.argv[1:]
arguments = ['gn.py', '-m', 'product', '-a', arch, '--no-rbe']
if os.name == 'nt':
    arguments.append('--gn-args=dart_lib_export_symbols=false')
options = gn.parse_args(arguments)
if options is None:
    sys.exit(1)
target_os = options.os[0]
out_dir = gn.GetOutDir('product', arch, target_os, 'none')
command = gn.BuildGnCommand(options, 'product', arch, target_os, 'none', out_dir)
command.append('--root-target=//napi:napi_template')
subprocess.check_call(command)
ninja = os.path.join('buildtools', 'ninja', 'ninja.exe' if os.name == 'nt' else 'ninja')
subprocess.check_call([ninja, '-C', out_dir, '-j', jobs, 'napi_template'])
''';
