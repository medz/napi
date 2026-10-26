import '../target.dart';
import 'sdk.dart';

Future<void> compileNative(NativeTarget target) async {
  final sdk = await NativeSdk.current();
  sdk.compile(target);
}
