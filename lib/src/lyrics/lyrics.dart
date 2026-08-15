/// Minimal LRC lyrics support — parse, query the active line for a playback
/// position. Mirrors the subset the reference player uses for its synced
/// overlay (its 3D spatial lyrics are approximated by the Flutter overlay).
class LyricLine {
  const LyricLine(this.time, this.text);
  final Duration time;
  final String text;
}

class Lyrics {
  Lyrics(this.lines) : _times = lines.map((l) => l.time).toList();

  final List<LyricLine> lines;
  final List<Duration> _times;

  static final RegExp _tag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');

  /// Parse an LRC document. Multiple timestamps on one line
  /// (`[00:12.00][01:05.00] chorus`) fan out to repeated lines.
  static Lyrics parse(String source) {
    final out = <LyricLine>[];
    for (final raw in source.split(RegExp(r'\r?\n'))) {
      final matches = _tag.allMatches(raw).toList();
      if (matches.isEmpty) continue;
      final text = raw.substring(matches.last.end).trim();
      for (final m in matches) {
        final minutes = int.parse(m.group(1)!);
        final seconds = int.parse(m.group(2)!);
        final fracRaw = m.group(3) ?? '0';
        final frac = int.parse(fracRaw.padRight(3, '0').substring(0, 3));
        final time = Duration(
            milliseconds:
                minutes * 60000 + seconds * 1000 + frac);
        if (text.isNotEmpty) out.add(LyricLine(time, text));
      }
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return Lyrics(out);
  }

  /// Whether this document has any usable lines.
  bool get hasLyrics => lines.isNotEmpty;

  /// Index of the line active at [position], or -1 before the first line.
  int activeIndexAt(Duration position) {
    if (lines.isEmpty) return -1;
    int lo = 0, hi = lines.length - 1, found = -1;
    final ms = position.inMilliseconds;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_times[mid].inMilliseconds <= ms) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }
}
