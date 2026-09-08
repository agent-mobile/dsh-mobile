/// Widget regression: the transcription document sheet's 发送到对话 action
/// per interaction mode. Text mode stages the document into the input dock
/// for review; voice mode renders NO input dock, so the document sends
/// straight out via sessions.prompt — before the fix the voice-mode text
/// landed in the invisible input controller and nothing observable happened.
library;

import 'dart:async';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/state/connection_controller.dart';
import 'package:dsh_mobile_app/state/transcription_controller.dart';
import 'package:dsh_mobile_app/state/voice_mode_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers/follow_fixture.dart';

class _FakeSessionApi extends DshSessionApi {
  _FakeSessionApi()
      : super(DshApiClient(baseUrl: Uri.parse('http://fake:3080'), token: 't'));

  final List<List<Map<String, Object?>>> promptCalls = [];

  @override
  Future<List<SessionSummary>> list() async => const [
        SessionSummary(
          sessionId: 's1',
          updatedAt: 1,
          running: false,
          blank: false,
          title: 'chat',
        ),
      ];

  @override
  Future<SessionHistoryPage> history({
    required String sessionId,
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
  }) async =>
      SessionHistoryPage(
        entries: const [],
        hasMore: false,
        projections: null,
      );

  @override
  Future<void> prompt({
    required String sessionId,
    required List<Map<String, Object?>> content,
    String mode = 'queue',
    String? clientTimeZone,
  }) async {
    promptCalls.add(content);
  }
}

class _FakeConnection extends ConnectionController {
  _FakeConnection()
      : super(baseUrl: Uri.parse('http://fake:3080'), token: 't');

  @override
  Future<void> refreshWorkspaces() async {
    workspaceItems = const [];
    archivedSessionIds = const [];
  }
}

const _document = '[说话人 1] 第一句\n[说话人 2] 第二句';

/// A controller pre-folded to a live recording with two diarized turns;
/// state != idle so the screen's auto-start (mic) never fires in tests.
TranscriptionController settledController() {
  final controller = TranscriptionController(
    speechClient:
        DshSpeechClient(baseUrl: Uri.parse('http://fake:3080'), token: 't'),
  );
  controller.handleSessionEvent(
    const SpeechSessionReady(
      provider: 'local',
      mode: 'vad',
      partial: false,
      diarization: true,
    ),
  );
  controller.handleSessionEvent(
    const SpeechSessionTranscript('第一句第二句', [
      SpeechSessionSegment(spk: 0, text: '第一句', startMs: 0, endMs: 100),
      SpeechSessionSegment(spk: 1, text: '第二句', startMs: 100, endMs: 200),
    ]),
  );
  return controller;
}

void main() {
  late _FakeConnection connection;
  late _FakeSessionApi sessions;
  late TranscriptionController controller;

  setUp(() {
    connection = _FakeConnection();
    sessions = _FakeSessionApi();
    connection.sessions = sessions;
    installSnapshot(connection, 's1', snapshotFrame(entries: const []));
    controller = settledController();
  });

  tearDown(() async {
    controller.dispose();
    await connection.dispose();
  });

  /// Chat screen with the settled transcription session injected; the flow
  /// runs to the point where the finished-document sheet shows.
  Future<void> runToSheet(WidgetTester tester, VoiceModeController voice) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          connection: connection,
          sessionId: 's1',
          voiceModeController: voice,
          transcriptionController: controller,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byTooltip('实时转录'));
    // Route pushes need one pump to build, then one to advance the
    // transition; a single pump leaves the pushed route unbuilt.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('说话人 1'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('发送到对话'), findsOneWidget);
  }

  testWidgets('voice mode: 发送到对话 sends the document as a prompt', (
    tester,
  ) async {
    final voice = VoiceModeController();
    // _mode applies synchronously; the storage write below never completes
    // in the test binding (no plugin mock), so it must not be awaited.
    unawaited(voice.setMode(VoiceMode.voice));
    addTearDown(voice.dispose);
    await runToSheet(tester, voice);

    await tester.tap(find.text('发送到对话'));
    await tester.pump();
    // Sheet pop (200ms) then the transcription route pop (~300ms).
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 500));

    expect(sessions.promptCalls, hasLength(1));
    expect(sessions.promptCalls.single.single['text'], _document);
  });

  testWidgets('text mode: 发送到对话 stages the document in the input dock', (
    tester,
  ) async {
    await runToSheet(tester, VoiceModeController());

    await tester.tap(find.text('发送到对话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 500));

    expect(sessions.promptCalls, isEmpty);
    expect(find.widgetWithText(TextField, _document), findsOneWidget);
  });
}
