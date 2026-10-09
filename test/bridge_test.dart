import 'package:napi/src/bridge.dart';
import 'package:napi/src/exports.dart';
import 'package:test/test.dart';

void main() {
  const fields = <RecordField>[
    (name: 'active', type: ValueType(ValueKind.boolType, nullable: true)),
    (name: 'id', type: ValueType(ValueKind.intType)),
    (name: 'name', type: ValueType(ValueKind.stringType)),
    (name: 'score', type: ValueType(ValueKind.doubleType)),
  ];

  test(
    'record bridge shares a structural shape across aliases and nullability',
    () {
      const user = ValueType(
        ValueKind.recordType,
        recordFields: fields,
        recordAlias: (
          name: 'User',
          libraryUri: 'package:users/a.dart',
          nullable: false,
        ),
      );
      const nullable = ValueType(
        ValueKind.recordType,
        nullable: true,
        recordFields: fields,
        recordAlias: (
          name: 'Account',
          libraryUri: 'package:users/b.dart',
          nullable: true,
        ),
      );
      final source = generateBridge([
        const Export(
          name: 'normalize',
          parameters: [Parameter(name: 'user', type: user)],
          returnType: user,
        ),
        const Export(
          name: 'lookup',
          parameters: [Parameter(name: 'user', type: nullable)],
          returnType: nullable,
          isAsync: true,
        ),
      ], 'file:///business.dart');

      expect(
        RegExp(
          r'^final _recordNames\d+ =',
          multiLine: true,
        ).allMatches(source).length,
        1,
      );
      expect(
        source,
        contains(
          '({bool? active, int id, String name, double score}) _readRecord0(',
        ),
      );
      expect(
        source,
        contains(
          'return (active: field0, id: field1, name: field2, score: field3);',
        ),
      );
      expect(source, contains('value.active, 1, true'));
      expect(source, contains('value.id, 2, false'));
      expect(
        source,
        contains('raw0.isNull ? null : _readRecord0(raw0, "parameter user")'),
      );
      expect(
        source,
        contains(
          'result == null ? null : _writeRecord0(result, "result")!.toJS',
        ),
      );
      expect(source, isNot(contains('business.User')));
      expect(source, isNot(contains('business.Account')));
      expect(source, isNot(contains('napi.snapshotMap')));
      expect(source, isNot(contains('napi.snapshotList')));
      expect(source, isNot(contains("import 'dart:convert';")));
      expect(
        source.indexOf('final snapshot = _snapshotRecord'),
        lessThan(source.indexOf('final field0 = _readRecordField')),
      );
    },
  );

  test(
    'different record leaf types and nullability retain separate readers',
    () {
      const first = ValueType(
        ValueKind.recordType,
        recordFields: [(name: 'value', type: ValueType(ValueKind.intType))],
      );
      const second = ValueType(
        ValueKind.recordType,
        recordFields: [
          (name: 'value', type: ValueType(ValueKind.intType, nullable: true)),
        ],
      );
      const third = ValueType(
        ValueKind.recordType,
        recordFields: [(name: 'value', type: ValueType(ValueKind.doubleType))],
      );
      final source = generateBridge([
        for (final (index, type) in [first, second, third].indexed)
          Export(
            name: 'record$index',
            parameters: [Parameter(name: 'value', type: type)],
            returnType: type,
          ),
      ], 'file:///business.dart');
      expect(
        RegExp(
          r'^final _recordNames\d+ =',
          multiLine: true,
        ).allMatches(source).length,
        3,
      );
      expect(source, contains('_readRecordField<int>(snapshot, 0, 2, false'));
      expect(source, contains('_readRecordField<int?>(snapshot, 0, 2, true'));
      expect(
        source,
        contains('_readRecordField<double>(snapshot, 0, 3, false'),
      );
    },
  );

  test('record dollar fields are literal keys and static Dart accesses', () {
    const record = ValueType(
      ValueKind.recordType,
      recordFields: [
        (name: r'$value', type: ValueType(ValueKind.intType)),
        (name: 'constructor', type: ValueType(ValueKind.stringType)),
        (name: 'then', type: ValueType(ValueKind.boolType)),
      ],
    );
    final source = generateBridge([
      const Export(
        name: 'names',
        parameters: [Parameter(name: 'value', type: record)],
        returnType: record,
      ),
    ], 'file:///business.dart');
    expect(source, contains(r'"\$value".toJS'));
    expect(source, contains(r'value.$value, 2, false'));
    expect(source, contains(r'context + "[\"\$value\"]"'));
    expect(source, contains('value.constructor, 4, false'));
    expect(source, contains('value.then, 1, false'));
  });

  test('scalar bridges do not emit record or collection helpers', () {
    const scalar = ValueType(ValueKind.intType);
    final source = generateBridge([
      const Export(
        name: 'add',
        parameters: [Parameter(name: 'value', type: scalar)],
        returnType: scalar,
      ),
    ], 'file:///business.dart');
    expect(source, isNot(contains('_recordNames')));
    expect(source, isNot(contains('napi.snapshotRecord')));
    expect(source, isNot(contains('_readRecordField')));
    expect(source, isNot(contains('napi.newMap')));
    expect(source, isNot(contains('napi.arrayGet')));
  });
}
