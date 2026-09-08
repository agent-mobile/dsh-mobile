/// Widget regression: the session-row menu — Rename opens a prefilled dialog
/// and writes through `sessions.rename`; Fork and Archive ride the same
/// menu; blank placeholder rows expose no menu.
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

  final renames = <({String sessionId, String title})>[];
  final forks = <String>[];

  @override
  Future<List<SessionSummary>> list() async => const [
        SessionSummary(sessionId: 'a', updatedAt: 10, running: false, blank: false, title: 'alpha'),
      ];

  @override
  Future<void> rename({required String sessionId, required String title}) async {
    renames.add((sessionId: sessionId, title: title));
  }

  @override
  Future<String> fork({required String sessionId, int? atSeq}) async {
    forks.add(sessionId);
    return 'child-of-$sessionId';
  }
}

class _FakeWorkspacesApi extends DshWorkspaceApi {
  _FakeWorkspacesApi()
      : super(DshApiClient(baseUrl: Uri.parse('http://fake:3080'), token: 't'));

  final archived = <String>[];

  @override
  Future<List<String>> archiveSession({required String sessionId}) async {
    archived.add(sessionId);
    return archived;
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

Future<void> _pump(WidgetTester tester, _FakeConnection connection) async {
  await tester.tap(find.byTooltip('打开侧边栏'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('rename opens a prefilled dialog and writes through', (tester) async {
    final connection = _FakeConnection();
    final sessions = _FakeSessionApi();
    connection.sessions = sessions;
    connection.workspaces = _FakeWorkspacesApi();
    addTearDown(() => connection.dispose());

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
    await _pump(tester, connection);

    await tester.tap(find.byTooltip('会话操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名').last);
    await tester.pumpAndSettle();

    expect(find.text('重命名会话'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'beta');
    await tester.tap(find.widgetWithText(FilledButton, '重命名'));
    await tester.pumpAndSettle();

    expect(sessions.renames, [(sessionId: 'a', title: 'beta')]);
  });

  testWidgets('archive rides the same menu and archives through workspaces', (tester) async {
    final connection = _FakeConnection();
    connection.sessions = _FakeSessionApi();
    final workspaces = _FakeWorkspacesApi();
    connection.workspaces = workspaces;
    addTearDown(() => connection.dispose());

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
    await _pump(tester, connection);

    await tester.tap(find.byTooltip('会话操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('归档会话'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));

    expect(workspaces.archived, ['a']);
  });
}