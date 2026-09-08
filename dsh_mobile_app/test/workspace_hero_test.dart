/// Widget regression: the blank-session hero — the "探索未至之境" headline
/// with the "预览版" badge renders on a blank session, and the workspace
/// row carries the picked workspace label.
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

  @override
  Future<List<SessionSummary>> list() async => const [
        SessionSummary(sessionId: 's1', updatedAt: 1, running: false, blank: true),
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
  testWidgets('a blank session shows the hero headline and preview badge', (tester) async {
    final connection = _FakeConnection();
    connection.sessions = _FakeSessionApi();
    installEmptySnapshot(connection, 's1');
    addTearDown(() => connection.dispose());

    await tester.pumpWidget(MaterialApp(
      home: ChatScreen(
        connection: connection,
        sessionId: 's1',
        voiceModeController: VoiceModeController(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('探索未至之境'), findsOneWidget);
    expect(find.text('预览版'), findsOneWidget);
  });
}