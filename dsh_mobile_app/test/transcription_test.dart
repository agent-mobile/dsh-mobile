/// Transcription controller coverage: the session event fold (ready facts,
/// partial preview, diarized turn accumulation, failure capture) and the
/// stop-time document assembly — plus the screen rendering of those states.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:dsh_mobile_app/screens/transcription_screen.dart';
import 'package:dsh_mobile_app/state/transcription_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

DshSpeechClient fakeClient() =>
    DshSpeechClient(baseUrl: Uri.parse('http://fake:3080'), token: 't');

void main() {
  test('ready event surfaces provider facts and recording state', () {
    final controller = TranscriptionController(speechClient: fakeClient());
    controller.handleSessionEvent(
      const SpeechSessionReady(
        provider: 'local',
        mode: 'vad',
        partial: false,
        diarization: true,
      ),
    );
    expect(controller.providerId, 'local');
    expect(controller.supportsPartial, isFalse);
    expect(controller.diarization, isTrue);
    controller.dispose();
  });

  test('transcript events append turns, diarized and plain', () {
    final controller = TranscriptionController(speechClient: fakeClient());
    controller.handleSessionEvent(
      const SpeechSessionReady(
        provider: 'cloud',
        mode: 'streaming',
        partial: true,
        diarization: true,
      ),
    );
    controller.handleSessionEvent(const SpeechSessionPartial('今天我们'));
    expect(controller.partialText, '今天我们');

    controller.handleSessionEvent(
      const SpeechSessionTranscript('今天我们讨论', [
        SpeechSessionSegment(spk: 0, text: '今天我们讨论', startMs: 0, endMs: 900),
        SpeechSessionSegment(spk: 1, text: '第三季度', startMs: 900, endMs: 1500),
      ]),
    );
    expect(controller.liveText, '今天我们讨论');
    expect(controller.partialText, isEmpty);
    expect(controller.turns.map((turn) => turn.speaker), [0, 1]);

    controller.handleSessionEvent(const SpeechSessionTranscript('下一句话', []));
    expect(controller.liveText, '今天我们讨论\n下一句话');
    expect(controller.turns.last.speaker, 0);
    expect(controller.turns.last.text, '下一句话');
    controller.dispose();
  });

  test(
    'error event captures text for retry; stop still returns the document',
    () async {
      final controller = TranscriptionController(speechClient: fakeClient());
      controller.handleSessionEvent(
        const SpeechSessionTranscript('第一句', [
          SpeechSessionSegment(spk: 0, text: '第一句', startMs: 0, endMs: 400),
        ]),
      );
      controller.handleSessionEvent(
        const SpeechSessionError('SPEECH_UPSTREAM_FAILURE', 'asr down'),
      );
      expect(controller.state, TranscriptionState.failed);
      expect(controller.error, contains('asr down'));
      // Captured text survives the failure.
      expect(controller.liveText, '第一句');

      final result = await controller.stop();
      expect(result, isNotNull);
      expect(result!.text, '第一句');
      expect(result.turns, hasLength(1));
      expect(controller.state, TranscriptionState.idle);
      controller.dispose();
    },
  );

  test('stop with nothing captured settles to idle and returns null', () async {
    final controller = TranscriptionController(speechClient: fakeClient());
    expect(await controller.stop(), isNull);
    expect(controller.state, TranscriptionState.idle);
    controller.dispose();
  });

  test(
    'stop document body carries speaker labels matching the saved file',
    () async {
      final controller = TranscriptionController(speechClient: fakeClient());
      controller.handleSessionEvent(
        const SpeechSessionTranscript('第一句第二句', [
          SpeechSessionSegment(spk: 0, text: '第一句', startMs: 0, endMs: 100),
          SpeechSessionSegment(spk: 1, text: '第二句', startMs: 100, endMs: 200),
        ]),
      );
      final result = await controller.stop();
      expect(result, isNotNull);
      expect(result!.text, '第一句第二句');
      expect(result.labeledText, '[说话人 1] 第一句\n[说话人 2] 第二句');
      controller.dispose();
    },
  );

  test(
    'labeledText stays unlabeled for one speaker and falls back to text',
    () async {
      final controller = TranscriptionController(speechClient: fakeClient());
      controller.handleSessionEvent(const SpeechSessionTranscript('只有一句话', []));
      final result = await controller.stop();
      expect(result!.labeledText, '只有一句话');
      controller.dispose();

      final empty = TranscriptionSessionResult(
        text: '纯文本',
        turns: const [],
        durationMs: 1000,
        startedAt: DateTime(2026),
        endedAt: DateTime(2026),
      );
      expect(empty.labeledText, '纯文本');
    },
  );

  testWidgets('the screen renders turns, partial preview, and provider facts', (
    tester,
  ) async {
    final controller = TranscriptionController(speechClient: fakeClient());
    // A failed session avoids the auto-start path (no mic in the test env).
    controller.handleSessionEvent(
      const SpeechSessionReady(
        provider: 'local',
        mode: 'vad',
        partial: false,
        diarization: true,
      ),
    );
    controller.handleSessionEvent(
      const SpeechSessionError('SPEECH_UPSTREAM_FAILURE', '服务不可用'),
    );
    controller.handleSessionEvent(
      const SpeechSessionTranscript('已捕获的话', [
        SpeechSessionSegment(spk: 1, text: '已捕获的话', startMs: 0, endMs: 500),
      ]),
    );

    await tester.pumpWidget(
      MaterialApp(home: TranscriptionScreen(controller: controller)),
    );
    await tester.pump();

    expect(find.textContaining('已中断'), findsOneWidget);
    expect(find.text('说话人 2'), findsOneWidget);
    expect(find.text('已捕获的话'), findsOneWidget);
    expect(find.textContaining('句级'), findsOneWidget);
    expect(find.textContaining('说话人分离'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    controller.dispose();
  });

  testWidgets('a live session shows pause and stop controls', (tester) async {
    final controller = TranscriptionController(speechClient: fakeClient());
    controller.handleSessionEvent(
      const SpeechSessionReady(
        provider: 'cloud',
        mode: 'streaming',
        partial: true,
        diarization: true,
      ),
    );
    controller.handleSessionEvent(
      const SpeechSessionTranscript('第一句第二句', [
        SpeechSessionSegment(spk: 0, text: '第一句', startMs: 0, endMs: 100),
        SpeechSessionSegment(spk: 1, text: '第二句', startMs: 100, endMs: 200),
      ]),
    );
    // A partial for the still-ongoing next utterance.
    controller.handleSessionEvent(const SpeechSessionPartial('正在说的话'));

    await tester.pumpWidget(
      MaterialApp(
        home: TranscriptionScreen(controller: controller, autoStart: false),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.text('正在说的话'), findsOneWidget);
    expect(find.textContaining('逐字'), findsOneWidget);
    // The provisional line carries no badge: speaker attribution is only
    // known once the sentence finalizes.
    expect(find.text('说话人 1'), findsOneWidget);
    expect(find.text('说话人 2'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();
    // The finished document sheet shows the speaker-labeled turns, not a
    // flat text block.
    expect(find.text('[说话人 1] 第一句\n[说话人 2] 第二句'), findsOneWidget);
    expect(find.text('保存到本地'), findsOneWidget);
    controller.dispose();
  });
}
