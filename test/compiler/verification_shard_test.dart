import 'package:test/test.dart';

import '../../tool/verification_shard.dart';
import '../../tool/verify.dart' show consumerFixtures;

void main() {
  test('default invocation includes every registered fixture', () {
    final fixtures = consumerFixtures.keys.toList();
    expect(VerificationShard.parse([]).select(fixtures), fixtures);
    expect(fixtures, hasLength(17));
    expect(fixtures, contains('js-collections'));
  });

  test('all shards are disjoint and cover current and future fixtures', () {
    for (final fixtures in [
      consumerFixtures.keys.toList(),
      for (var length = 1; length <= 40; length++)
        List.generate(length, (index) => 'fixture-$index'),
    ]) {
      for (var count = 1; count <= fixtures.length; count++) {
        final selected = <String>[];
        for (var index = 0; index < count; index++) {
          final shard = VerificationShard.parse([
            '--total-shards',
            '$count',
            '--shard-index',
            '$index',
          ]).select(fixtures);
          expect(shard, isNotEmpty);
          selected.addAll(shard);
        }
        expect(selected.toSet().length, selected.length);
        expect(selected, unorderedEquals(fixtures));
      }
    }
  });

  test('malformed or empty shards fail rather than silently skip', () {
    for (final arguments in <List<String>>[
      ['--total-shards', '2'],
      ['--total-shards', '0', '--shard-index', '0'],
      ['--total-shards', '2', '--shard-index', '-1'],
      ['--total-shards', '2', '--shard-index', '2'],
      ['--total-shards', 'x', '--shard-index', '0'],
      ['--unknown', '2', '--shard-index', '0'],
      ['--total-shards', '2', '--shard-index', '0', '--extra'],
    ]) {
      expect(() => VerificationShard.parse(arguments), throwsArgumentError);
    }
    expect(
      () => const VerificationShard(count: 2, index: 0).select(['only']),
      throwsArgumentError,
    );
  });
}
