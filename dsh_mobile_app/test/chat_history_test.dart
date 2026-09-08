/// Widget regression: history paging — the initial open renders the tail
/// page, the "加载更早" affordance appears while older history remains, and
/// tapping it requests the next older page through `beforeSeq`.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/state/connection_controller.dart';
import 'helpers/follow_fixture.dart';
import 'package:dsh_mobile_app/state/voice_mode_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// One settled assistant message event at [seq].
HistoryEntry assistantEntry(int seq, String text) => HistoryEntry(
      SessionEvent(
        seq: seq,
        type: 'assistant/message',
        time: seq,
        data: {
          'turn': 1,
          'step': seq,
          'message': {
            'content': [
              {'type': 'text', 'text': text},
            ],
          },
        },
      ),
      null,
    );

class _FakeSessionApi extends DshSessionApi {
  _FakeSessionApi()
      : super(DshApiClient(baseUrl: Uri.parse('http://fake:3080'), token: 't'));

  List<HistoryEntry> log = const [];
  final List<int?> beforeSeqCalls = [];
  final List<int> throughSeqCalls = [];

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
    throughSeqCalls.add(throughSeq);
    // 0.1.2 window: throughSeq is the inclusive upper bound (head-1 pages the
    // older window); -1 pages nothing.
    final top = beforeSeq ?? throughSeq;
    final window = top < 0
        ? const <HistoryEntry>[]
        : log.where((entry) => entry.event.seq <= top).toList();
    final page = window.length > 20 ? window.sublist(window.length - 20) : window;
    return SessionHistoryPage(
      entries: page,
      hasMore: window.length > 20,
      projections: null,
    );
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
    sessions = _FakeSessionApi()
      ..log = [
        for (var i = 1; i <= 50; i++) assistantEntry(i, 'message $i'),
      ];
    connection.sessions = sessions;
    // The 0.1.2 bootstrap: the follow snapshot IS the tail page (the window's
    // newest 20 records), with older history paged via session/page.
    installSnapshot(
      connection,
      's1',
      snapshotFrame(
        entries: sessions.log.sublist(30),
        cursor: 50,
        hasMore: true,
      ),
    );
  });

  tearDown(() async {
    await connection.dispose();
  });

  testWidgets('renders the tail page and the 加载更早 affordance', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('message 50'), findsOneWidget);
    expect(find.text('加载更早'), findsOneWidget);
    expect(sessions.beforeSeqCalls, isEmpty);
  });

  testWidgets('tapping 加载更早 requests the next older page', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('加载更早'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // The paging request ends at the window head minus one (30).
    expect(sessions.throughSeqCalls, contains(30));

    // Scroll up through the prepended page: the older window's newest
    // message becomes visible (ListView builds lazily around the viewport).
    for (var i = 0; i < 12; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(find.text('message 11'), findsOneWidget);
  });
}