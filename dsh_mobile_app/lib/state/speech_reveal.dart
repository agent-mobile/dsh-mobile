/// Karaoke reveal bookkeeping for streamed TTS: maps the moment a unit's
/// audio starts sounding to the characters of the transcript that become
/// visible, so the spoken message shows only as far as it has been heard.
///
/// Units are recorded in submission order as (seq, endChars) pairs — the
/// assistant message seq the unit belongs to and the unit's end offset
/// within that message's joined text. [unitStarted] advances the revealed
/// offset (taking the max, since reveals may fire slightly out of order
/// around failed units); a reveal for a message older than the current
/// reveal target is ignored, because that message was superseded and fully
/// revealed by [supersede]. [beginSessionAt] opens a session: everything
/// before [seq] counts as fully heard, [seq] itself stays hidden until its
/// first unit starts. The caller stops truncating once the session is not
/// speaking, so no text can stay hidden across session ends or interrupts.
library;

/// See the library docstring; one instance serves the chat screen.
class SpeechReveal {
  int _revealedSeq = 0;
  int _revealedChars = 0;
  final List<(int, int)> _unitEnds = [];

  /// The message seq the reveal currently applies to.
  int get revealedSeq => _revealedSeq;

  /// Characters of [revealedSeq]'s joined text heard so far.
  int get revealedChars => _revealedChars;

  /// Open a session whose first spoken message is [seq]: all older messages
  /// render in full, [seq] itself hides until its first unit starts.
  void beginSessionAt(int seq) {
    _revealedSeq = seq;
    _revealedChars = 0;
    _unitEnds.clear();
  }

  /// Record that the next unit (index `_unitEnds.length`) ends at [endChars]
  /// within message [seq]'s joined text. Call before enqueueing the unit, so
  /// a unit that reveals synchronously (a zero-audio punctuation unit) can
  /// already find its own entry.
  void unitEnqueued(int seq, int endChars) => _unitEnds.add((seq, endChars));

  /// The controller rejected the unit recorded last: drop the entry so the
  /// indices of the following units stay aligned with the playback.
  void unitDropped() {
    if (_unitEnds.isNotEmpty) _unitEnds.removeLast();
  }

  /// The unit at [index] started sounding: reveal through its end offset.
  void unitStarted(int index) {
    if (index < 0 || index >= _unitEnds.length) return;
    final (seq, end) = _unitEnds[index];
    if (seq < _revealedSeq) return; // superseded: already fully revealed
    if (seq > _revealedSeq) {
      _revealedSeq = seq;
      _revealedChars = end;
      return;
    }
    if (end > _revealedChars) _revealedChars = end;
  }

  /// Message [seq] was superseded by a newer step before its tail was fed:
  /// reveal it fully (its remaining text will never be spoken).
  void supersede(int seq, int fullLength) {
    if (seq < _revealedSeq) return;
    _revealedSeq = seq;
    if (fullLength > _revealedChars) _revealedChars = fullLength;
  }
}
