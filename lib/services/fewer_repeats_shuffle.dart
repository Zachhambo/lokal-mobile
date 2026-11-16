import 'dart:math';

const shuffleHistoryLimit = 200;

/// Randomize within five recency buckets, retaining every queue occurrence.
/// O(n + 200); no timers, database writes or per-song queries.
List<T> fewerRepeatsShuffle<T>(
  List<T> items, {
  required String Function(T) idOf,
  List<String> recentIds = const [],
  Random? random,
}) {
  final ranks = <String, int>{};
  for (final id in recentIds.take(shuffleHistoryLimit)) {
    ranks.putIfAbsent(id, () => ranks.length);
  }
  final buckets = List.generate(5, (_) => <T>[]);
  for (final item in items) {
    final rank = ranks[idOf(item)];
    final bucket = rank == null
        ? 0
        : rank >= 100
        ? 1
        : rank >= 20
        ? 2
        : rank > 0
        ? 3
        : 4;
    buckets[bucket].add(item);
  }
  final rng = random ?? Random();
  return [for (final bucket in buckets) ...(bucket..shuffle(rng))];
}
