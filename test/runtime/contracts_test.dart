import 'package:napi/src/runtime/contracts.dart';
import 'package:test/test.dart';

void main() {
  test('omission and supplied null remain distinct before conversion', () {
    const ArgumentPresence<Object?> omitted = OmittedArgument();
    const ArgumentPresence<Object?> supplied = SuppliedArgument(null);
    expect(omitted, isA<OmittedArgument<Object?>>());
    expect(supplied, isA<SuppliedArgument<Object?>>());
    expect((supplied as SuppliedArgument<Object?>).value, isNull);
  });

  test('unsupported capabilities never silently succeed', () {
    for (final capability in RuntimeCapability.values) {
      expect(
        () => unsupportedCapability(capability),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains(capability.name),
          ),
        ),
      );
    }
  });

  test('conversion errors retain nested paths', () {
    final path = const ValuePath('argument[0]').field('values').index(2);
    final error = BindingConversionException(path, 'expected a safe integer');
    expect(error.toString(), 'argument[0].values[2]: expected a safe integer');
  });
}
