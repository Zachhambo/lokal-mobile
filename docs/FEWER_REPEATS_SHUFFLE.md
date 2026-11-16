# Fewer repeats shuffle

Ordinary song shuffle and library, album, artist, folder and provider playlist
Shuffle buttons defer recently heard tracks by default on Android and iOS.
The desktop implementation uses the same rules.

The currently selected song is also treated as recent when a Shuffle button
chooses a new starting track, even before that song qualifies for history.

Shuffle reads at most 200 existing history rows at startup, retains a bounded
ID cache, and updates that cache when the existing play tracker counts a play.
The mobile read walks the playedAt index without loading songs or the library.
Provider rows match owned songs through the existing library index. Tracks
without matching history receive ordinary random ordering.

Five buckets play in this order: outside the recent window, ranks 100–199,
ranks 20–99, ranks 1–19, and the most recently heard track. Each bucket uses
Fisher–Yates shuffle. Runtime is O(n + 200) when constructing a queue; playback
adds no timers, network requests, writes or new dependencies. All occurrences
remain eligible, including intentional playlist duplicates. Tapping a specific
song still starts that song; toggling shuffle keeps the currently playing song
first, and queued manual entries continue through the existing queue machinery.

The explicit Random mode continues to pick a random next song. Category choice,
repeat mode, native gapless handling and non-shuffled playback are unchanged.
This is recency-based ordering, not an implementation of Spotify's algorithm.
It reduces repeat exposure across newly shuffled sessions; it does not prohibit
repeats or persist additional history for sources the app does not already save.

Validation: `flutter test test/services/fewer_repeats_shuffle_test.dart
 test/services/player_service_shuffle_test.dart`. Playback on physical devices
remains a separate check from the ordering tests.
