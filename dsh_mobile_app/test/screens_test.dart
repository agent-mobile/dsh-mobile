/// Widget regression: home navigation — the rail's buttons reach the drawer,
/// search, and settings surfaces, and the voice-mode toggle in the AppBar
/// leading flips the global mode.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:dsh_mobile_app/screens/home_screen.dart';
import 'package:dsh_mobile_app/screens/search_screen.dart';
import 'package:dsh_mobile_app/screens/settings_screen.dart';
import 'package:dsh_mobile_app/state/connection_controller.dart';
import 'package:dsh_mobile_app/state/theme_controller.dart';
import 'package:dsh_mobile_app/state/voice_mode_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeConfigApi extends DshConfigApi {
  _FakeConfigApi()
      : super(DshApiClient(baseUrl: Uri.parse('http://fake:3080'), token: 't'));

  @override
  Future<SettingsDescribeResult> settingsDescribe() async {
    return const SettingsDescribeResult(writable: true, hasDocument: false, namespaces: []);
  }

  @override
  Future<List<ConfigurableProviderView>> llmProviders() async => const [];
}

class _FakeSessionApi extends DshSessionApi {
  _FakeSessionApi()
      : super(DshApiClient(baseUrl: Uri.parse('http://fake:3080'), token: 't'));

  @override
  Future<List<SessionSummary>> list() async => const [];

  @override
  Future<SessionSearchResult> search(String query) async =>
      const SessionSearchResult(items: [], hasMore: false);
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

Widget _home(_FakeConnection connection, ThemeController theme, VoiceModeController voice) =>
    HomeScreen(connection: connection, themeController: theme, voiceModeController: voice);

void main() {
  testWidgets('the rail reaches search and settings', (tester) async {
    final connection = _FakeConnection();
    connection.sessions = _FakeSessionApi();
    connection.config = _FakeConfigApi();
    addTearDown(() => connection.dispose());

    await tester.pumpWidget(MaterialApp(
      home: _home(connection, ThemeController(), VoiceModeController()),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('搜索会话'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('the rail opens the session drawer', (tester) async {
    final connection = _FakeConnection();
    connection.sessions = _FakeSessionApi();
    addTearDown(() => connection.dispose());

    await tester.pumpWidget(MaterialApp(
      home: _home(connection, ThemeController(), VoiceModeController()),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byTooltip('打开侧边栏'));
    await tester.pumpAndSettle();
    expect(find.text('打开会话列表'), findsOneWidget);
  });

  testWidgets('the AppBar leading toggles the global voice mode', (tester) async {
    final connection = _FakeConnection();
    connection.sessions = _FakeSessionApi();
    addTearDown(() => connection.dispose());
    final voice = VoiceModeController();

    await tester.pumpWidget(MaterialApp(
      home: _home(connection, ThemeController(), voice),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // Text mode: the bubble icon in the AppBar leading.
    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
    expect(voice.isVoice, isFalse);

    await tester.tap(find.byIcon(Icons.chat_bubble_outline));
    await tester.pump();

    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(voice.isVoice, isTrue);
  });
}