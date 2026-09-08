/// Regression: the TTS feed cut must NEVER return more than `hardChars` —
/// an unbounded unit (a whole long reply) synthesizes past the provider
/// timeout and kills streaming playback for the whole session.
library;

import 'package:dsh_mobile_app/state/speech_feed_cut.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('never exceeds the hard cap, whatever the tail punctuation', () {
    // A long reply whose LAST char is a strong boundary used to cut at the
    // end of the whole string (311 and 1398 chars hit the relay).
    final long = '这是一段很长的回复。' * 30; // 330 chars, ends with 。
    final cut = speechFeedCut(long);
    expect(cut, lessThanOrEqualTo(48));
    expect(cut, greaterThan(0));
  });

  test('hard-caps punctuation-free text at exactly hardChars', () {
    final cut = speechFeedCut('没有任何标点的一长串文本' * 20);
    expect(cut, 48);
  });

  test('prefers the strong boundary nearest to the cap', () {
    final pending = '短句一。短句二。短句三。' 'x' * 60;
    final cut = speechFeedCut(pending);
    expect(cut, lessThanOrEqualTo(48));
    expect(pending.substring(cut - 1, cut), anyOf('。', 'x'));
  });

  test('holds short text without boundaries (returns 0)', () {
    expect(speechFeedCut('不足二十四字无标点'), 0);
  });

  test('weak boundary only after the weak threshold', () {
    // 20 chars with a comma: below the weak threshold, hold.
    expect(speechFeedCut('前段没有标点的文字超过二十四字，后面还有内容'), 0);
    // 24+ chars before the comma: cut lands in [24, 48].
    final pending = '这一段没有标点的文字足足超过了二十四字的长度限制，后面还有内容';
    final cut = speechFeedCut(pending);
    expect(cut, inInclusiveRange(24, 48));
  });

  test('ASCII dot is strong only before whitespace or end', () {
    expect(speechFeedCut('步骤 1. 如下'), 5);
    expect(speechFeedCut('值是3.14159以及更多内容填充到超过上限的长度'), lessThanOrEqualTo(48));
  });
}
