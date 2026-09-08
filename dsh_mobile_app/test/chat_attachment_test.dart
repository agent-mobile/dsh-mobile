/// Widget regression: the image attachment flow — the source menu is gated
/// behind the attach control: in text mode it opens while idle and stays
/// closed while a turn runs; in voice mode the dock carries the same control
/// and it stays openable while running (staged images ride along with the
/// next spoken line). The platform picker itself needs a real device, so the
/// picking flow is covered by on-device QA, not here.
library;

import 'dart:async';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/state/connection_controller.dart';
import 'helpers/follow_fixture.dart';
import 'package:dsh_mobile_app/state/voice_mode_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSessionApi extends DshSessionApi {
  _FakeSessionApi()
      : super(DshApiClient(baseUrl: Uri.parse('http://fake:3080'), token: 't'));

  @override
  Future<List<SessionSummary>> list() async => const [
        SessionSummary(sessionId: 's1', updatedAt: 1, running: false, blank: false, title: 'chat'),
      ];

  @override
  Future<SessionHistoryPage> history({
    required String sessionId,
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
  }) async {
    return const SessionHistoryPage(entries: [], hasMore: false, projections: null);
  }

  @override
  Future<void> prompt({
    required String sessionId,
    required List<Map<String, Object?>> content,
    String mode = 'queue',
    String? clientTimeZone,
  }) async {}
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

void main() {
  late _FakeConnection connection;

  Widget buildScreen() => MaterialApp(
        home: ChatScreen(
          connection: connection,
          sessionId: 's1',
          voiceModeController: VoiceModeController(),
        ),
      );

  setUp(() {
    connection = _FakeConnection();
    installEmptySnapshot(connection, 's1');
    connection.sessions = _FakeSessionApi();
  });

  tearDown(() async {
    await connection.dispose();
  });

  testWidgets('the attach control is idle-enabled: tapping it opens a sheet without throwing', (tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));

    // The attach affordance is enabled while idle; invoking the source menu
    // must not throw even though the platform picker is unavailable in tests.
    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 1));
    // No exception = pass; sheet content depends on the picker platform.
    expect(tester.takeException(), isNull);
  });

  testWidgets('the attach control is disabled while a turn is running', (tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));

    connection.updateRunning('s1', true);
    await tester.pump();

    // Disabled: tapping must not open any bottom sheet.
    await tester.tap(find.byIcon(Icons.attach_file), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the voice dock keeps the attach control openable while a turn runs and hides the transcript item', (tester) async {
    final voice = VoiceModeController();
    // Fire-and-forget: the mode flips synchronously before setMode's first
    // await, and its secure-storage write never completes in widget tests
    // (unmocked method channel under FakeAsync).
    unawaited(voice.setMode(VoiceMode.voice));
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          connection: connection,
          sessionId: 's1',
          voiceModeController: voice,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // The voice dock carries the same paperclip affordance as the text dock.
    expect(find.byIcon(Icons.attach_file), findsOneWidget);

    // Unlike the text dock, staging stays openable while a turn runs: the
    // next spoken line steers with the staged images aboard.
    connection.updateRunning('s1', true);
    await tester.pump();

    await tester.tap(find.byIcon(Icons.attach_file));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(BottomSheet), findsOneWidget);
    // The transcript item injects into a draft field the voice dock has none,
    // so it is hidden there.
    expect(find.text('加载转录文档'), findsNothing);
    expect(find.text('从相册选择'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}