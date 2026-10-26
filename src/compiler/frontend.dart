import 'dart:convert';
import 'dart:io';

import 'package:dart2native/dart2native_macho.dart' as macho;

import 'package:front_end/src/api_unstable/vm.dart'
    show CompilerOptions, StandardFileSystem;
import 'package:kernel/ast.dart';
import 'package:kernel/binary/ast_to_binary.dart';
import 'package:package_config/package_config.dart';
import 'package:vm/kernel_front_end.dart';

import 'node_version.dart' as versions;

String? _error;
bool _done = false;

@pragma('vm:entry-point')
String? result() => _done ? _error : 'Frontend compilation did not finish';

Future<void> main(List<String> args) async {
  _error = null;
  _done = false;
  try {
    await _compile(
      args[0],
      args[1].isEmpty ? null : args[1],
      args[2],
      args[3],
      args[4],
      args[5].isEmpty ? null : args[5],
    );
  } on FormatException catch (error) {
    _error = error.message;
  } on FileSystemException catch (error) {
    _error = error.toString();
  } catch (error, stack) {
    _error = '$error\n$stack';
  } finally {
    _done = true;
  }
}

@pragma('vm:entry-point')
Future<void> packageMac(List<String> args) async {
  _error = null;
  _done = false;
  try {
    await macho.writeAppendedMachOExecutable(args[0], args[1], args[2]);
  } catch (error, stack) {
    _error = '$error\n$stack';
  } finally {
    _done = true;
  }
}

Future<void> _compile(
  String entry,
  String? packageConfig,
  String platform,
  String targetOS,
  String outputPath,
  String? node,
) async {
  final packagesUri = packageConfig == null
      ? Uri()
      : File(packageConfig).absolute.uri;
  final packages = packageConfig == null
      ? PackageConfig.empty
      : await loadPackageConfigUri(packagesUri);
  final target = createFrontEndTarget(
    'vm',
    supportMirrors: false,
    constKeepLocalsIndicator: false,
  )!;
  final errors = ErrorDetector();
  final diagnostics = <String>[];
  final options = CompilerOptions()
    ..sdkSummary = File(platform).absolute.uri
    ..fileSystem = StandardFileSystem.instance
    ..packagesFileUri = packagesUri
    ..target = target
    ..embedSourceText = false
    ..onDiagnostic = (message) {
      diagnostics.add(message.plainTextFormatted.join('\n'));
      errors(message);
    };
  final source = await _writeEntry(entry, outputPath);
  final compiled = await compileToKernel(
    KernelCompilationArguments(
      source: source,
      options: options,
      includePlatform: true,
      enableAsserts: false,
      environmentDefines: {'dart.vm.product': 'true'},
    ),
  );
  if (compiled.component == null || errors.hasCompilationErrors) {
    throw FormatException(diagnostics.join('\n'));
  }
  final component = compiled.component!;
  final initialization = _configureBuiltinInitialization(component, targetOS);
  final requirements = _Requirements(packages);
  component.accept(requirements);
  await runGlobalTransformations(
    target,
    component,
    errors,
    KernelCompilationArguments(
      source: source,
      options: options,
      includePlatform: true,
      aot: true,
      useGlobalTypeFlowAnalysis: true,
      useRapidTypeAnalysis: true,
      enableAsserts: false,
      environmentDefines: {'dart.vm.product': 'true'},
      targetOS: targetOS,
    ),
  );
  if (errors.hasCompilationErrors) {
    throw FormatException(diagnostics.join('\n'));
  }
  final uses = _Uses(requirements);
  component.accept(uses);
  final compatibility = versions.nodeRequirements(uses.found.values, node);
  _setNodeValidator(
    component,
    source,
    versions.nodeConstraintText(compatibility.nodes),
    compatibility.napi,
    [
      for (final range in versions.nodeRanges(compatibility.nodes))
        [
          range.min?.major ?? 0,
          range.min?.minor ?? 0,
          range.min?.patch ?? 0,
          range.min?.preRelease.join('.') ?? '',
          range.max?.major ?? 0,
          range.max?.minor ?? 0,
          range.max?.patch ?? 0,
          range.max?.preRelease.join('.') ?? '',
          range.min != null,
          range.max != null,
          range.includeMin,
          range.includeMax,
        ],
    ],
  );
  final fullRuntime =
      initialization['dynamicSnapshots']! ||
      _hasUnknownSdkNative(uses.natives.values);
  await File(
    '$outputPath.runtime',
  ).writeAsString(fullRuntime ? 'full\n' : 'core\n');
  final output = File(outputPath).openWrite();
  try {
    BinaryPrinter(output).writeComponentFile(component);
  } finally {
    await output.close();
  }
}

bool _hasUnknownSdkNative(Iterable<Map<String, Object?>> natives) {
  // These SDK FFI entries are present in every prebuilt runtime profile.
  const core = {
    'ConditionVariable_Initialize',
    'ConditionVariable_Notify',
    'ConditionVariable_NotifyAll',
    'ConditionVariable_Wait',
    'FinalizerEntry_SetExternalSize',
    'FileSystemWatcher::DestroyWatch',
    'IsolateGroup_runSync',
    'Mutex_Initialize',
    'Mutex_RunLocked',
    'Pointer_asTypedListFinalizerAllocateData',
    'Pointer_asTypedListFinalizerCallbackPointer',
  };
  return natives.any((native) {
    final asset = native['assetId'];
    return asset is String &&
        asset.startsWith('dart:') &&
        !core.contains(native['symbol']);
  });
}

Future<Uri> _writeEntry(String entry, String output) async {
  final uri = jsonEncode(
    File(entry).absolute.uri.toString(),
  ).replaceAll(r'$', r'\$');
  final file = File('${File(output).parent.path}/entry.dart');
  await file.writeAsString('''
import $uri as addon;

@pragma('vm:entry-point')
int initialize(int environment, int exports, int callJs, int owner,
    int finalizer, int hasLivePorts) => addon.initialize(
        environment, exports, callJs, owner, finalizer, hasLivePorts);

@pragma('vm:entry-point')
void afterPump() => addon.afterPump();

@pragma('vm:entry-point')
void dispose() => addon.dispose();

@pragma('vm:entry-point')
String? validateNodeVersion(int major, int minor, int patch, int napi,
    String version) =>
    _nodeVersionAllowed(major, minor, patch, napi, version,
        0, 0, 0, 0, '', 0, 0, 0, '',
        false, false, false, false) ? null : 'Unsupported Node.js version';

bool _windowsPathHasReservedCharacters(String segment) {
  for (var i = 0; i < segment.length; i++) {
    final c = segment.codeUnitAt(i);
    if (c == 34 || c == 42 || c == 47 || c == 58 || c == 60 ||
        c == 62 || c == 63 || c == 92 || c == 124) return true;
  }
  return false;
}

@pragma('vm:entry-point')
bool _nodeVersionAllowed(int major, int minor, int patch, int napi,
    String version, int minNapi,
    int minMajor, int minMinor, int minPatch, String minPreRelease,
    int maxMajor, int maxMinor, int maxPatch, String maxPreRelease,
    bool hasMin, bool hasMax, bool includeMin, bool includeMax) {
  if (napi < minNapi) return false;
  final preRelease = _nodePreRelease(version);
  final lower = major != minMajor ? (major < minMajor ? -1 : 1)
      : minor != minMinor ? (minor < minMinor ? -1 : 1)
      : patch != minPatch ? (patch < minPatch ? -1 : 1)
      : _nodeComparePreRelease(preRelease, minPreRelease);
  final upper = major != maxMajor ? (major < maxMajor ? -1 : 1)
      : minor != maxMinor ? (minor < maxMinor ? -1 : 1)
      : patch != maxPatch ? (patch < maxPatch ? -1 : 1)
      : _nodeComparePreRelease(preRelease, maxPreRelease);
  return (!hasMin || lower > 0 || (includeMin && lower == 0)) &&
      (!hasMax || upper < 0 || (includeMax && upper == 0));
}

String _nodePreRelease(String version) {
  var start = -1;
  for (var index = 0; index < version.length; index++) {
    final unit = version.codeUnitAt(index);
    if (unit == 43) return start < 0 ? '' : version.substring(start, index);
    if (unit == 45 && start < 0) start = index + 1;
  }
  return start < 0 ? '' : version.substring(start);
}

int _nodeComparePreRelease(String left, String right) {
  if (left.isEmpty) return right.isEmpty ? 0 : 1;
  if (right.isEmpty) return -1;
  var leftStart = 0;
  var rightStart = 0;
  while (true) {
    var leftEnd = leftStart;
    var rightEnd = rightStart;
    while (leftEnd < left.length && left.codeUnitAt(leftEnd) != 46) leftEnd++;
    while (rightEnd < right.length && right.codeUnitAt(rightEnd) != 46) rightEnd++;
    final leftPart = left.substring(leftStart, leftEnd);
    final rightPart = right.substring(rightStart, rightEnd);
    final leftNumber = int.tryParse(leftPart);
    final rightNumber = int.tryParse(rightPart);
    int comparison;
    if (leftNumber != null && rightNumber != null) {
      comparison = leftNumber.compareTo(rightNumber);
    } else if (leftNumber != null) {
      comparison = -1;
    } else if (rightNumber != null) {
      comparison = 1;
    } else {
      comparison = leftPart.compareTo(rightPart);
    }
    if (comparison != 0) return comparison;
    if (leftEnd == left.length) return rightEnd == right.length ? 0 : -1;
    if (rightEnd == right.length) return 1;
    leftStart = leftEnd + 1;
    rightStart = rightEnd + 1;
  }
}

void main() {}
''');
  return file.absolute.uri;
}

void _setNodeValidator(
  Component component,
  Uri entry,
  String requiredVersions,
  int requiredNapi,
  List<List<Object>> ranges,
) {
  final library = component.libraries.singleWhere(
    (library) => library.importUri == entry,
  );
  final validator = library.procedures.singleWhere(
    (procedure) => procedure.name.text == 'validateNodeVersion',
  );
  final helper = library.procedures.singleWhere(
    (procedure) => procedure.name.text == '_nodeVersionAllowed',
  );
  Expression allowed = BoolLiteral(false);
  for (final range in ranges) {
    final call = StaticInvocation(
      helper,
      Arguments([
        for (final parameter in validator.function.positionalParameters)
          VariableGet(parameter),
        IntLiteral(requiredNapi),
        for (final bound in range)
          switch (bound) {
            int value => IntLiteral(value),
            String value => StringLiteral(value),
            bool value => BoolLiteral(value),
            _ => throw StateError('Invalid Node.js version bound'),
          },
      ]),
    );
    allowed = LogicalExpression(allowed, LogicalExpressionOperator.OR, call);
  }
  validator.function.body = ReturnStatement(
    ConditionalExpression(
      allowed,
      NullLiteral(),
      StringLiteral(
        'This addon requires Node.js $requiredVersions '
        'and Node-API $requiredNapi.',
      ),
      validator.function.returnType,
    ),
  )..parent = validator.function;
}

Map<String, Object?> _fields(InstanceConstant value) => {
  for (final field in value.fieldValues.entries)
    field.key.asField.name.text: switch (field.value) {
      IntConstant(:final value) => value,
      StringConstant(:final value) => value,
      NullConstant() => null,
      _ => field.value.toString(),
    },
};

InstanceConstant? _nativeMarker(Annotatable member) {
  for (final value in member.annotations) {
    if (value is! ConstantExpression || value.constant is! InstanceConstant) {
      continue;
    }
    final instance = value.constant as InstanceConstant;
    if (instance.classNode.name != 'pragma' ||
        instance.classNode.enclosingLibrary.importUri.toString() !=
            'dart:core') {
      continue;
    }
    final values = {
      for (final entry in instance.fieldValues.entries)
        entry.key.asField.name.text: entry.value,
    };
    if (values['name'] case StringConstant(value: 'cfe:ffi:native-marker')) {
      return values['options'] as InstanceConstant;
    }
  }
  return null;
}

String _nativeKey(InstanceConstant constant) {
  final value = _fields(constant);
  return '${value['assetId']}#${value['symbol']}';
}

String _enumKey(InstanceConstant constant) {
  final value = _fields(constant);
  return '${constant.classNode.enclosingLibrary.importUri}'
      '#${constant.classNode.name}#${value['index']}';
}

class _Requirements extends RecursiveVisitor {
  _Requirements(this.packages);

  final PackageConfig packages;
  final natives = <String, Map<String, Object?>>{};
  final enums = <String, Map<String, Object?>>{};

  InstanceConstant? _available(Annotatable member) {
    final uri = Uri.parse('package:napi/src/_internal/annotations.dart');
    for (final value in member.annotations) {
      if (value is ConstantExpression && value.constant is InstanceConstant) {
        final instance = value.constant as InstanceConstant;
        final library = instance.classNode.enclosingLibrary;
        if (instance.classNode.name == 'Available' &&
            (library.importUri == uri ||
                library.fileUri == packages.resolve(uri))) {
          return instance;
        }
      }
    }
    return null;
  }

  @override
  void visitProcedure(Procedure node) {
    final available = _available(node);
    final native = _nativeMarker(node);
    if (available != null && native != null) {
      natives[_nativeKey(native)] = {
        'api': node.name.text,
        ..._fields(available),
      };
    }
    super.visitProcedure(node);
  }

  @override
  void visitField(Field node) {
    final available = _available(node);
    if (available != null &&
        node.isEnumElement &&
        node.initializer is ConstantExpression) {
      final value =
          (node.initializer as ConstantExpression).constant as InstanceConstant;
      enums[_enumKey(value)] = {
        'api': '${node.enclosingClass!.name}.${node.name.text}',
        ..._fields(available),
      };
    }
    super.visitField(node);
  }
}

class _Uses extends RecursiveVisitor {
  _Uses(this.registry);

  final _Requirements registry;
  final found = <String, Map<String, Object?>>{};
  final natives = <String, Map<String, Object?>>{};

  void _constant(Constant constant) {
    if (constant is InstanceConstant) {
      final cls = constant.classNode;
      if (cls.name == 'Native' &&
          cls.enclosingLibrary.importUri.toString() == 'dart:ffi') {
        final key = _nativeKey(constant);
        natives[key] = _fields(constant);
        if (registry.natives[key] case final value?) found[key] = value;
      }
      final enumKey = _enumKey(constant);
      if (registry.enums[enumKey] case final value?) found[enumKey] = value;
      for (final field in constant.fieldValues.values) {
        _constant(field);
      }
    } else if (constant is SetConstant) {
      constant.entries.forEach(_constant);
    } else if (constant is ListConstant) {
      constant.entries.forEach(_constant);
    } else if (constant is MapConstant) {
      for (final entry in constant.entries) {
        _constant(entry.key);
        _constant(entry.value);
      }
    } else if (constant is RecordConstant) {
      constant.positional.forEach(_constant);
      constant.named.values.forEach(_constant);
    }
  }

  @override
  void visitConstantExpression(ConstantExpression node) {
    _constant(node.constant);
  }
}

bool _isEntryPoint(Expression annotation) {
  if (annotation is! ConstantExpression ||
      annotation.constant is! InstanceConstant)
    return false;
  final constant = annotation.constant as InstanceConstant;
  if (constant.classNode.name != 'pragma' ||
      constant.classNode.enclosingLibrary.importUri.toString() != 'dart:core')
    return false;
  return _fields(constant)['name'] == 'vm:entry-point';
}

Map<String, bool> _configureBuiltinInitialization(
  Component component,
  String targetOS,
) {
  final core = component.libraries.singleWhere(
    (lib) => lib.importUri.toString() == 'dart:core',
  );
  final uri = core.classes.singleWhere((cls) => cls.name == '_Uri');
  final pathCheck = uri.procedures.singleWhere(
    (procedure) => procedure.name.text == '_checkWindowsPathReservedCharacters',
  );
  final pathHelper = component.mainMethod!.enclosingLibrary.procedures
      .singleWhere(
        (procedure) =>
            procedure.name.text == '_windowsPathHasReservedCharacters',
      );
  final replacement = _WindowsPathCheck(pathHelper);
  pathCheck.function.body =
      (pathCheck.function.body!.accept(replacement) as Statement)
        ..parent = pathCheck.function;
  if (replacement.count != 1) {
    throw StateError('Unexpected Dart SDK Windows URI validation');
  }
  final windows = uri.fields.singleWhere(
    (field) => field.name.text == '_isWindowsCached',
  );
  windows.initializer = BoolLiteral(targetOS == 'windows')..parent = windows;
  final packageApis = _PackageApis();
  for (final library in component.libraries) {
    if (!library.importUri.isScheme('dart')) library.accept(packageApis);
  }
  final capabilities = {
    'packageResolution': packageApis.used,
    'dynamicSnapshots': packageApis.dynamicSnapshots,
  };
  if (packageApis.used) return capabilities;
  final builtin = component.libraries.singleWhere(
    (lib) => lib.importUri.toString() == 'dart:_builtin',
  );
  for (final procedure in builtin.procedures) {
    if ({
      '_setPackagesMap',
      '_resolveScriptUri',
      '_setupHooks',
    }.contains(procedure.name.text)) {
      procedure.annotations.removeWhere(_isEntryPoint);
    }
    if (procedure.name.text == '_setWorkingDirectory') {
      final body = procedure.function.body! as Block;
      body.statements.removeAt(0);
    }
    if (procedure.name.text == '_Init') {
      final body = procedure.function.body! as Block;
      if (body.statements.length != 4)
        throw StateError('Unexpected Dart SDK builtin initialization');
      body.statements.removeLast();
      body.statements.removeAt(0);
    }
  }
  return capabilities;
}

class _WindowsPathPattern extends RecursiveVisitor {
  bool found = false;
  static const pattern = r'["*/:<>?\\|]';

  @override
  void visitStringLiteral(StringLiteral node) {
    if (node.value == pattern) found = true;
  }

  @override
  void visitConstantExpression(ConstantExpression node) {
    if (node.constant case StringConstant(value: pattern)) found = true;
  }
}

class _WindowsPathCheck extends Transformer {
  _WindowsPathCheck(this.helper);
  final Procedure helper;
  int count = 0;

  @override
  TreeNode visitInstanceInvocation(InstanceInvocation node) {
    if (node.interfaceTarget.name.text == 'contains') {
      final pattern = _WindowsPathPattern();
      node.arguments.accept(pattern);
      if (pattern.found) {
        count++;
        return StaticInvocation(helper, Arguments([node.receiver]));
      }
    }
    return super.visitInstanceInvocation(node);
  }
}

class _PackageApis extends RecursiveVisitor {
  bool used = false;
  bool dynamicSnapshots = false;
  @override
  void defaultConstantReference(Constant node) {
    if (node is StaticTearOffConstant) _target(node.target);
    node.visitChildren(this);
  }

  void _target(Member member) {
    if (member.enclosingLibrary.importUri.toString() != 'dart:isolate') return;
    if (member.enclosingClass?.name != 'Isolate') return;
    if (member.name.text == 'spawnUri') dynamicSnapshots = true;
    if ({
      'packageConfig',
      'packageConfigSync',
      'resolvePackageUri',
      'resolvePackageUriSync',
      'spawnUri',
    }.contains(member.name.text))
      used = true;
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    _target(node.target);
    super.visitStaticInvocation(node);
  }

  @override
  void visitStaticGet(StaticGet node) {
    _target(node.target);
    super.visitStaticGet(node);
  }
}
