/// Karaoke reveal bookkeeping: unit starts must surface exactly the text
/// that has been heard, superseded messages must reveal in full, and stale
/// or out-of-order callbacks must never hide or corrupt what is shown.
library;

import 'package:dsh_mobile_app/state/speech_reveal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reveals text only as its units start sounding', () {
    final reveal = SpeechReveal();
    reveal.beginSessionAt(10);
    expect(reveal.revealedSeq, 10);
    expect(reveal.revealedChars, 0);

    reveal.unitEnqueued(10, 12);
    reveal.unitEnqueued(10, 25);
    reveal.unitEnqueued(10, 40);
    expect(reveal.revealedChars, 0, reason: 'nothing sounded yet');

    reveal.unitStarted(0);
    expect(reveal.revealedChars, 12);
    reveal.unitStarted(1);
    expect(reveal.revealedChars, 25);
  });

  test('a zero-audio unit reveals synchronously when recorded first', () {
    final reveal = SpeechReveal();
    reveal.beginSessionAt(7);
    reveal.unitEnqueued(7, 8); // real unit
    reveal.unitStarted(0);
    // punctuation-only unit follows; its entry exists before it starts
    reveal.unitEnqueued(7, 9);
    reveal.unitStarted(1);
    expect(reveal.revealedChars, 9);
  });

  test('out-of-order and stale reveals take the max and never regress', () {
    final reveal = SpeechReveal();
    reveal.beginSessionAt(3);
    reveal.unitEnqueued(3, 10);
    reveal.unitEnqueued(3, 20);
    reveal.unitStarted(1);
    expect(reveal.revealedChars, 20);
    reveal.unitStarted(0); // late duplicate of an earlier unit
    expect(reveal.revealedChars, 20, reason: 'monotonic');
    reveal.unitStarted(99); // out of range
    reveal.unitStarted(-1);
    expect(reveal.revealedChars, 20);
  });

  test('supersede reveals the old message fully; newer messages stay hidden',
      () {
    final reveal = SpeechReveal();
    reveal.beginSessionAt(5);
    reveal.unitEnqueued(5, 10);
    reveal.unitStarted(0);
    // step 2 arrives while step 1's tail was never fed
    reveal.supersede(5, 33);
    expect(reveal.revealedSeq, 5);
    expect(reveal.revealedChars, 33);

    reveal.unitEnqueued(6, 15);
    reveal.unitStarted(1);
    expect(reveal.revealedSeq, 6);
    expect(reveal.revealedChars, 15);
  });

  test('a reveal for a superseded message is ignored', () {
    final reveal = SpeechReveal();
    reveal.beginSessionAt(5);
    reveal.unitEnqueued(5, 10);
    reveal.unitStarted(0);
    reveal.supersede(5, 30);
    // step 2 sounding, then a stale timer for the old message fires
    reveal.unitEnqueued(6, 40);
    reveal.unitStarted(1);
    expect(reveal.revealedSeq, 6);
    reveal.unitStarted(0); // stale: belongs to seq 5
    expect(reveal.revealedSeq, 6);
    expect(reveal.revealedChars, 40, reason: 'old message already fully shown');
  });

  test('unitDropped keeps indices aligned with the playback', () {
    final reveal = SpeechReveal();
    reveal.beginSessionAt(2);
    reveal.unitEnqueued(2, 10);
    reveal.unitStarted(0);
    reveal.unitEnqueued(2, 20);
    reveal.unitDropped(); // controller rejected the unit
    reveal.unitEnqueued(2, 30);
    reveal.unitStarted(1); // now the real second unit
    expect(reveal.revealedChars, 30);
  });

  test('beginSessionAt clears per-session units and retargets the reveal',
      () {
    final reveal = SpeechReveal();
    reveal.beginSessionAt(1);
    reveal.unitEnqueued(1, 20);
    reveal.unitStarted(0);
    reveal.beginSessionAt(9); // next turn
    expect(reveal.revealedSeq, 9);
    expect(reveal.revealedChars, 0);
    reveal.unitStarted(0); // stale index from the old session
    expect(reveal.revealedChars, 0);
  });
}
