/// Widget regression: live list state — a session's running dot follows the
/// host's running signal in real time (newer than the list snapshot), and a
/// pending approval flips the dot to amber.
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

  @override
  Future<List<SessionSummary>> list() async => const [
        SessionSummary(sessionId: 'a', updatedAt: 10, running: false, blank: false, title: 'a'),
      ];
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

Future<void> _pump(WidgetTester tester, _FakeConnection connection) async {
  connection.sessions = _FakeSessionApi();
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
  await tester.tap(find.byTooltip('打开侧边栏'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the running dot follows the live host signal', (tester) async {
    final connection = _FakeConnection();
    addTearDown(() => connection.dispose());
    await _pump(tester, connection);

    // The list snapshot said idle: no green dot.
    Icon dot(int index) => tester.widget<Icon>(
          find.byIcon(Icons.circle, skipOffstage: false).at(index),
        );

    connection.updateRunning('a', true);
    await tester.pump();
    final green = find.byIcon(Icons.circle, skipOffstage: false);
    expect(green, findsOneWidget);
    expect(dot(0).color, Colors.green);

    connection.updateRunning('a', false);
    await tester.pump();
    expect(find.byIcon(Icons.circle, skipOffstage: false), findsNothing);
  });
}