import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flick/services/fewer_repeats_shuffle.dart';

void main() {
  List<String> shuffle(List<String> items, List<String> history) =>
      fewerRepeatsShuffle(
        items,
        idOf: (id) => id,
        recentIds: history,
        random: Random(7),
      );
  test('recent buckets and last heard song come later', () {
    final history = List.generate(200, (i) => '$i');
    final input = ['0', '10', '50', '150', 'fresh'];
    expect(shuffle(input, history), ['fresh', '150', '50', '10', '0']);
    expect(input, ['0', '10', '50', '150', 'fresh']);
  });
  test('duplicates and small playlists retain every occurrence', () {
    expect(shuffle(['a', 'a', 'b'], ['a', 'b', 'a']), ['b', 'a', 'a']);
    expect(shuffle([], []), isEmpty);
    expect(shuffle(['a'], ['a']), ['a']);
  });
  test('no history stays random; history beyond bound is ignored', () {
    final items = List.generate(10000, (i) => '$i');
    final result = shuffle(items, []);
    expect(result.toSet(), items.toSet());
    expect(result, isNot(items));
    expect(
      shuffle(
        ['last', 'fresh'],
        [...List.generate(shuffleHistoryLimit, (i) => '$i'), 'last'],
      ),
      shuffle(['last', 'fresh'], []),
    );
  });
}
