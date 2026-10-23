import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';

import '../commands.dart';

Future<void> verifyModuleRebuild(
  Directory root, {
  Directory? nativeRuntime,
}) async {
  final native = nativeRuntime != null;
  final business = await File('${root.path}/business.dart').writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int add([int value = 1]) => value + 1;
''');
  final output = Directory('${root.path}/module');
  Future<BuiltModule> build() => buildLibrary(
    library: business.uri,
    output: output,
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    target: native ? BuildTarget.native : BuildTarget.wasm,
    nativeRuntime: nativeRuntime,
  );
  final entry = native ? 'module.mjs' : 'module.wasm';
  Future<void> call(Directory directory, String expression) async {
    await File('${directory.path}/test.mjs').writeAsString('''
import assert from 'node:assert/strict';
import {add} from './$entry';
$expression
''');
    await run('node', ['test.mjs'], cwd: directory.path);
  }

  await build();
  await call(output, 'assert.equal(add(), 2);');
  final notes = await File('${output.path}/notes.txt').writeAsString('keep');
  final metadata = await File('${output.path}/package.json')
      .writeAsString('{"private":true}');
  final modified = DateTime.utc(2020);
  await notes.setLastModified(modified);
  await metadata.setLastModified(modified);
  await business.writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int add(int value) => value + 3;
''');
  final rebuilt = await build();
  if (rebuilt.target != (native ? BuildTarget.native : BuildTarget.wasm) ||
      await notes.readAsString() != 'keep' ||
      await metadata.readAsString() != '{"private":true}' ||
      !(await notes.stat()).modified.isAtSameMomentAs(modified) ||
      !(await metadata.stat()).modified.isAtSameMomentAs(modified)) {
    throw StateError('Module rebuild lost author files or timestamps.');
  }
  if (!native) {
    for (final name in ['core.wasm', 'calls.mjs', 'references.mjs']) {
      if (await File('${output.path}/$name').exists()) {
        throw StateError('Module rebuild retained obsolete $name.');
      }
    }
  }
  final consumer = await Directory('${root.path}/relocated consumer 雪')
      .create();
  await for (final file in output.list()) {
    if (file is File) {
      await file.copy('${consumer.path}/${file.uri.pathSegments.last}');
    }
  }
  await output.delete(recursive: true);
  await business.delete();
  await call(consumer, 'assert.equal(add(5), 8);');
  await File('${consumer.path}/consumer.mts').writeAsString('''
import {add} from ${jsonEncode('./$entry')};
const result: number = add(5);
// @ts-expect-error rebuilt parameters remain required
add();
// @ts-expect-error rebuilt parameters retain their scalar types
add('5');
void result;
''');
  await typescript(consumer, 'consumer.mts');
}
