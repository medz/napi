import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:test/test.dart';

import '../../tool/scalar_fixture.dart';

void main() {
  test('existing output is rejected without changing user files', () async {
    final directory = await Directory.systemTemp.createTemp('napi-preserve-');
    addTearDown(() => directory.delete(recursive: true));
    final marker = File('${directory.path}/keep.txt');
    await marker.writeAsString('keep');
    await expectLater(
      buildModule(bindings: scalarBindings(), output: directory),
      throwsArgumentError,
    );
    expect(await marker.readAsString(), 'keep');
    expect(await directory.list().length, 1);
  });
}
