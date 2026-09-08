/// Widget regression: the chat transcript follows new content while docked to
/// the bottom, stops following when the user scrolls up to read history,
/// resumes on the way back, and always docks when the user sends a message.
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
      : super(
          baseUrl: Uri.parse('http://fake:3080'),
          token: 't',
        );

  @override
  Future<void> refreshWorkspaces() async {
    workspaceItems = const [];
    archivedSessionIds = const [];
  }
}

/// One assistant text chunk on session s1: a long standalone paragraph.
String chunkText(int i) =>
    'line $i ${List.generate(20, (j) => 'word$j').join(' ')}';

SessionEvent chunkEvent(int seq, String text) =>
    SessionEvent(
      seq: seq,
      type: 'assistant/chunk',
      time: seq,
      data: {
        'turn': 1,
        'step': 1,
        'chunk': {'type': 'text-delta', 'index': 0, 'text': text},
      },
    );

void main() {
  late _FakeConnection connection;

  Widget buildScreen() => MaterialApp(home: ChatScreen(connection: connection, sessionId: 's1', voiceModeController: VoiceModeController()));

  ListView listView(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView, skipOffstage: false));

  setUp(() {
    connection = _FakeConnection();
    installEmptySnapshot(connection, 's1');
    connection.sessions = _FakeSessionApi();
  });

  tearDown(() async {
    await connection.dispose();
  });

  testWidgets('new content follows while docked to the bottom', (tester) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));

    // Fill the transcript past the viewport.
    for (var i = 1; i <= 40; i++) {
      connection.foldSessionEvent('s1', chunkEvent(i, chunkText(i)));
      await tester.pump();
      await tester.pump(); // post-frame jump
    }

    final controller = listView(tester).controller!;
    expect(controller.position.maxScrollExtent, greaterThan(100));
    expect(
      controller.position.pixels,
      moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 1),
    );
  });

  testWidgets('scrolling up detaches; new content does not follow', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));

    // Fill the transcript past the viewport.
    for (var i = 1; i <= 40; i++) {
      connection.foldSessionEvent('s1', chunkEvent(i, chunkText(i)));
      await tester.pump();
      await tester.pump();
    }
    final controller = listView(tester).controller!;
    expect(controller.position.maxScrollExtent, greaterThan(400));

    // Scroll up to read history; the viewport detaches from the bottom.
    await tester.drag(find.byType(ListView), const Offset(0, 900));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

    // New content must not drag the viewport back down.
    connection.foldSessionEvent('s1', chunkEvent(41, chunkText(41)));
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    expect(controller.position.pixels, lessThan(controller.position.maxScrollExtent - 500));
  });

  testWidgets('jump-to-bottom control restores following while detached', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));

    for (var i = 1; i <= 40; i++) {
      connection.foldSessionEvent('s1', chunkEvent(i, chunkText(i)));
      await tester.pump();
      await tester.pump();
    }
    final controller = listView(tester).controller!;

    // Detach to the top: the jump-to-bottom control appears.
    await tester.drag(find.byType(ListView), const Offset(0, 900));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

    // Tapping it animates back to the bottom and hides the control.
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);

    // Following resumes: new content docks the viewport again.
    connection.foldSessionEvent('s1', chunkEvent(41, chunkText(41)));
    await tester.pump();
    await tester.pump();
    expect(
      controller.position.pixels,
      moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 1),
    );
  });

  testWidgets('sending a message re-docks the viewport even when detached', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));

    for (var i = 1; i <= 40; i++) {
      connection.foldSessionEvent('s1', chunkEvent(i, chunkText(i)));
      await tester.pump();
      await tester.pump();
    }
    final controller = listView(tester).controller!;

    // Detach to the top, then send: the viewport must snap back regardless.
    await tester.drag(find.byType(ListView), const Offset(0, 900));
    await tester.pumpAndSettle();
    expect(controller.position.pixels, lessThan(controller.position.maxScrollExtent - 500));

    await tester.enterText(find.byType(TextField), 'hi');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(
      controller.position.pixels,
      moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 1),
    );
  });
}
