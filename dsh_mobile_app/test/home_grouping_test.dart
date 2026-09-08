/// Widget regression: the drawer's workspace grouping — groups render
/// collapsed by default, the automatic rule opens exactly one group (running
/// first, then the current session's, else the most recently updated), and
/// tapping a folder header toggles a manual pin.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:dsh_mobile_app/screens/home_screen.dart';
import 'package:dsh_mobile_app/state/connection_controller.dart';
import 'package:dsh_mobile_app/state/theme_controller.dart';
import 'package:dsh_mobile_app/state/voice_mode_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSessionApi extends DshSessionApi {
  _FakeSessionApi()
      : super(DshApiClient(baseUrl: Uri.parse('http://fake:3080'), token: 't'));

  List<SessionSummary> sessions = const [];

  @override
  Future<List<SessionSummary>> list() async => sessions;
}

class _FakeConnection extends ConnectionController {
  _FakeConnection()
      : super(baseUrl: Uri.parse('http://fake:3080'), token: 't');

  @override
  Future<void> refreshWorkspaces() async {}
}

WorkspaceView _ws(String id, String title, List<String> sessionIds) =>
    WorkspaceView(workspaceId: id, path: 'C:\\$id', title: title, sessionIds: sessionIds, createdAt: '1', updatedAt: '1');

SessionSummary _s(String id, int updatedAt, {bool running = false}) =>
    SessionSummary(sessionId: id, updatedAt: updatedAt, running: running, blank: false, title: id);

Future<void> _pump(
  WidgetTester tester,
  _FakeConnection connection, {
  List<SessionSummary> sessions = const [],
  List<WorkspaceView> workspaces = const [],
}) async {
  final api = _FakeSessionApi()..sessions = sessions;
  connection.sessions = api;
  connection.workspaceItems = workspaces;
  connection.archivedSessionIds = const [];
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(MaterialApp(
    home: HomeScreen(
      connection: connection,
      themeController: ThemeController(),
      voiceModeController: VoiceModeController(),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
  // Open the drawer holding the grouped session browser.
  await tester.tap(find.byTooltip('打开侧边栏'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('groups render collapsed; the most-recent rule opens one', (tester) async {
    final connection = _FakeConnection();
    addTearDown(() => connection.dispose());
    await _pump(
      tester,
      connection,
      sessions: [_s('a', 10), _s('b', 5)],
      workspaces: [_ws('w1', '工作区一', ['a']), _ws('w2', '工作区二', ['b'])],
    );

    // Both group headers render.
    expect(find.text('工作区一'), findsOneWidget);
    expect(find.text('工作区二'), findsOneWidget);

    // The automatic rule opens only the most recently updated session's group.
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsNothing);
  });

  testWidgets('a running session group wins the automatic open', (tester) async {
    final connection = _FakeConnection();
    addTearDown(() => connection.dispose());
    await _pump(
      tester,
      connection,
      sessions: [_s('a', 10), _s('b', 5, running: true)],
      workspaces: [_ws('w1', '工作区一', ['a']), _ws('w2', '工作区二', ['b'])],
    );

    // b runs: its group opens even though a is newer.
    expect(find.text('b'), findsOneWidget);
    expect(find.text('a'), findsNothing);
  });

  testWidgets('tapping a folder header pins it open over the automatic rule', (tester) async {
    final connection = _FakeConnection();
    addTearDown(() => connection.dispose());
    await _pump(
      tester,
      connection,
      sessions: [_s('a', 10), _s('b', 5)],
      workspaces: [_ws('w1', '工作区一', ['a']), _ws('w2', '工作区二', ['b'])],
    );

    // Initially only w1 (auto) is open.
    expect(find.text('a'), findsOneWidget);
    expect(find.text('b'), findsNothing);

    // Tap w2's header: the manual pin opens it.
    await tester.tap(find.text('工作区二'));
    await tester.pumpAndSettle();
    expect(find.text('b'), findsOneWidget);

    // Tap it again: the manual pin closes it back to header-only.
    await tester.tap(find.text('工作区二'));
    await tester.pumpAndSettle();
    expect(find.text('b'), findsNothing);
  });

  testWidgets('an open group shows only the first five sessions until expanded', (tester) async {
    final connection = _FakeConnection();
    addTearDown(() => connection.dispose());
    final members = [for (var i = 1; i <= 7; i++) _s('m$i', i)];
    await _pump(
      tester,
      connection,
      sessions: members,
      workspaces: [_ws('w1', '大工作区', [for (var i = 1; i <= 7; i++) 'm$i'])],
    );

    // The first five rows render; the rest wait behind the overflow control.
    expect(find.text('m1'), findsOneWidget);
    expect(find.text('m5'), findsOneWidget);
    expect(find.text('m6'), findsNothing);
    expect(find.text('m7'), findsNothing);
  });
}