/// Assigns complete fixtures to shards without splitting their runtime checks.
final class VerificationShard {
  const VerificationShard({required this.count, required this.index});

  final int count;
  final int index;

  factory VerificationShard.parse(List<String> arguments) {
    if (arguments.isEmpty) return const VerificationShard(count: 1, index: 0);
    if (arguments.length != 4 ||
        arguments[0] != '--total-shards' ||
        arguments[2] != '--shard-index') {
      throw ArgumentError(
        'Usage: dart run tool/verify.dart '
        '[--total-shards COUNT --shard-index INDEX]',
      );
    }
    final count = int.tryParse(arguments[1]);
    final index = int.tryParse(arguments[3]);
    if (count == null ||
        index == null ||
        count < 1 ||
        index < 0 ||
        index >= count) {
      throw ArgumentError('Expected COUNT > 0 and 0 <= INDEX < COUNT.');
    }
    return VerificationShard(count: count, index: index);
  }

  List<T> select<T>(List<T> fixtures) {
    if (count < 1 || index < 0 || index >= count || count > fixtures.length) {
      throw ArgumentError('Every shard must contain at least one fixture.');
    }
    return [
      for (var position = 0; position < fixtures.length; position++)
        if (position % count == index) fixtures[position],
    ];
  }
}
