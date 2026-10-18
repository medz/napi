import 'dart:convert';

/// Preserve Dartdoc text without interpreting Markdown or Dart references.
String emitDocumentation(String? comment, {String indent = ''}) {
  if (comment == null || comment == '/**/') return '';
  final lineComment = comment.startsWith('///');
  final blockComment = comment.startsWith('/**') && comment.endsWith('*/');
  final body = blockComment
      ? comment.substring(3, comment.length - 2)
      : comment;
  final prefix = lineComment
      ? RegExp(r'^[ \t]*/// ?')
      : blockComment
      ? RegExp(r'^[ \t]*\* ?')
      : null;
  final lines = const LineSplitter().convert(body).map((line) {
    return prefix == null ? line : line.replaceFirst(prefix, '');
  }).toList();
  if (blockComment && lines.isNotEmpty) lines[0] = lines.first.trimLeft();
  while (lines.isNotEmpty && lines.first.trim().isEmpty) {
    lines.removeAt(0);
  }
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  if (lines.isEmpty) return '';
  if (blockComment) {
    final padding = lines
        .where((line) => line.trim().isNotEmpty)
        .map((line) => RegExp(r'^[ \t]*').firstMatch(line)![0]!.length)
        .reduce((a, b) => a < b ? a : b);
    for (var index = 0; index < lines.length; index++) {
      lines[index] = lines[index].length < padding
          ? ''
          : lines[index].substring(padding);
    }
    lines[lines.length - 1] = lines.last.trimRight();
  }
  return [
    '$indent/**',
    for (final line in lines)
      line.isEmpty ? '$indent *' : '$indent * ${line.replaceAll('*/', r'*\/')}',
    '$indent */',
  ].join('\n');
}
