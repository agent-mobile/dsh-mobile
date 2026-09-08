/// The TTS feed cut for streamed assistant text: decides how much of the
/// pending tail to enqueue as one synthesis unit.
///
/// Bounds are a hard contract: the local relay synthesizes a unit fully
/// before answering, so unit length must satisfy "synthesis time < the
/// provider timeout". A 311-char unit (one whole long reply) timed out the
/// relay and knocked the session back to batch playback. Every scan is
/// capped at [hardChars], so a unit NEVER exceeds it.
library;

/// Strong sentence enders: a unit may always end here.
const String _strong = '。！？；！?;\n';

/// Weak boundaries: used only once a unit reaches [weakChars] to keep
/// first-audio latency bounded.
const String _weak = '，、：,: ';

/// Returns the enqueue cut for [pending]: the boundary nearest to — but not
/// past — [hardChars] (strong first, then weak), else a hard cut at
/// [hardChars], else 0 while the text is shorter than [weakChars] and has no
/// boundary yet.
///
/// ASCII `.` only counts when followed by whitespace/end so list markers
/// ("1.") and decimals ("3.14") do not shatter units.
int speechFeedCut(
  String pending, {
  int weakChars = 24,
  int hardChars = 48,
}) {
  final limit = pending.length < hardChars ? pending.length : hardChars;
  for (var i = limit - 1; i >= 0; i--) {
    final ch = pending[i];
    if (_strong.contains(ch)) return i + 1;
    if (ch == '.' &&
        (i + 1 == pending.length ||
            pending[i + 1] == ' ' ||
            pending[i + 1] == '\n')) {
      return i + 1;
    }
  }
  if (pending.length >= weakChars) {
    for (var i = limit - 1; i >= weakChars - 1; i--) {
      if (_weak.contains(pending[i])) return i + 1;
    }
  }
  if (pending.length >= hardChars) return hardChars;
  return 0;
}
