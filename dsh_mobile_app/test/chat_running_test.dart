/// Widget regression: the running-turn surface — the primary control flips
/// to stop while a turn runs, tapping it cancels through the session API,
/// and the turn status row appears at the transcript tail.
library;

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

  int cancelCalls = 0;

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

  @override
  Future<void> cancel({required String sessionId}) async {
    cancelCalls += 1;
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

void main() {
  late _FakeConnection connection;
  late _FakeSessionApi sessions;

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
    sessions = _FakeSessionApi();
    connection.sessions = sessions;
  });

  tearDown(() async {
    await connection.dispose();
  });

  testWidgets('the primary control flips to stop while running and cancels on tap', (tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));

    // Idle: the send affordance.
    expect(find.byIcon(Icons.send), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle), findsNothing);

    // The host reports a running turn: the control becomes stop.
    connection.updateRunning('s1', true);
    await tester.pump();
    expect(find.byIcon(Icons.stop_circle), findsOneWidget);
    expect(find.byIcon(Icons.send), findsNothing);

    // Tapping stop cancels through the session API.
    await tester.tap(find.byIcon(Icons.stop_circle));
    await tester.pump();
    expect(sessions.cancelCalls, 1);
  });

  testWidgets('a running turn shows the turn status row at the transcript tail', (tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));

    connection.updateRunning('s1', true);
    await tester.pump();

    // The running placeholder row renders (the TurnStatusRow affordance).
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets('the turn status row disappears when the turn settles', (tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));

    connection.updateRunning('s1', true);
    await tester.pump();
    connection.updateRunning('s1', false);
    await tester.pump();

    // Blank idle session: no running placeholder, the status panel shows.
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}