import 'native/compile.dart';
import 'target.dart';

/// A compiler configured with output targets.
final class Compiler {
  Compiler(List<Target> targets) : targets = List.unmodifiable(targets);

  final List<Target> targets;

  /// Builds each target. Command-line options are not supported yet.
  Future<void> run(List<String> args) async {
    if (args.isNotEmpty) {
      throw ArgumentError(
        'Compiler command-line options are not supported yet.',
      );
    }
    for (final target in targets) {
      switch (target) {
        case NativeTarget():
          await compileNative(target);
      }
    }
  }
}
