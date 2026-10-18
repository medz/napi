import 'dart:io';

Future<void> createCompetitor(Directory root, String kind) async {
  final output = '${root.path}/output';
  if (kind.endsWith('symlink')) {
    final linked = '${root.path}/linked';
    if (kind == 'directory symlink') {
      await Directory(linked).create();
      await File('$linked/keep').writeAsString('keep');
    } else if (kind == 'file symlink') {
      await File(linked).writeAsString('keep');
    }
    await Link(output).create(linked);
  } else if (kind == 'file') {
    await File(output).writeAsString('keep');
  } else {
    await Directory(output).create();
    if (kind == 'populated directory') {
      await File('$output/keep').writeAsString('keep');
    }
  }
}

Future<void> main(List<String> arguments) =>
    createCompetitor(Directory(arguments[0]), arguments[1]);
