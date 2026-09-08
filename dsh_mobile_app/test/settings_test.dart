/// Settings screen: curated sections over the describe surface, read-only
/// detail pages, and the in-app appearance picker.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:dsh_mobile_app/screens/settings_screen.dart';
import 'package:dsh_mobile_app/state/connection_controller.dart';
import 'package:dsh_mobile_app/state/theme_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SettingsNamespaceView _ns(
  String name, {
  Map<String, Object?> value = const {},
  String applies = 'live',
  int revision = 1,
}) =>
    SettingsNamespaceView(
      ns: name,
      schema: const {'uid': 1, 'refs': {}},
      value: value,
      applies: applies,
      secrets: const [],
      revision: revision,
    );

class _FakeConfigApi extends DshConfigApi {
  _FakeConfigApi()
    : super(DshApiClient(baseUrl: Uri.parse('http://fake:3080'), token: 't'));

  List<SettingsNamespaceView> namespaces = const [];

  @override
  Future<SettingsDescribeResult> settingsDescribe() async {
    return SettingsDescribeResult(
      writable: true,
      hasDocument: true,
      namespaces: namespaces,
    );
  }

  @override
  Future<List<ConfigurableProviderView>> llmProviders() async {
    return const [
      ConfigurableProviderView(
        provider: 'llm-deepseek',
        displayName: 'DeepSeek',
        settingsNs: 'llm-deepseek',
        settingsPath: [],
        active: true,
      ),
    ];
  }
}

class _FakeConnection extends ConnectionController {
  _FakeConnection()
    : super(baseUrl: Uri.parse('http://fake:3080'), token: 't');
}

SettingsScreen _screen(_FakeConnection connection, ThemeController theme) =>
    SettingsScreen(connection: connection, themeController: theme);

Future<void> _pump(WidgetTester tester, _FakeConnection connection, ThemeController theme) async {
  // Tall viewport so every curated section renders without scrolling.
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: _screen(connection, theme)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('renders curated sections and hides raw namespace keys', (tester) async {
    final connection = _FakeConnection();
    final config = _FakeConfigApi()
      ..namespaces = [
        _ns('shell', value: const {'timeoutMs': 60000, 'maxOutputBytes': 100000}),
        _ns('locale', value: const {'preference': 'zh'}),
        _ns('permission', value: const {'defaultPreset': 'workspace-write'}),
        _ns('agent-presets', value: const {'default': 'research'}),
        _ns('llm-deepseek', value: const {'baseURL': 'https://api.deepseek.com'}),
        _ns('web-search-deepseek', value: const {'model': 'deepseek-search'}),
        _ns('ui-onboarding', value: const {'welcomeNoticeVersion': 'x'}),
        _ns('ui-theme', value: const {'preference': 'system'}),
        _ns('ui-conversation', value: const {'busyEnter': 'queue'}),
      ];
    connection.config = config;

    await _pump(tester, connection, ThemeController());

    // Curated section headers.
    expect(find.text('通用'), findsOneWidget);
    expect(find.text('模型'), findsOneWidget);
    expect(find.text('Agent 预设'), findsOneWidget);
    expect(find.text('插件'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);

    // Provider row from llmProviders.
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('活跃'), findsOneWidget);

    // General rows resolve friendly labels from the namespace values.
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget);
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.text('权限预设'), findsOneWidget);
    expect(find.text('工作区写入'), findsOneWidget);

    // Agent preset + plugin rows.
    expect(find.text('默认预设'), findsOneWidget);
    expect(find.text('research'), findsOneWidget);
    expect(find.text('Shell（命令执行）'), findsOneWidget);
    expect(find.text('Web 搜索'), findsOneWidget);

    // Internal namespace keys never surface.
    expect(find.text('ui-onboarding'), findsNothing);
    expect(find.text('ui-theme'), findsNothing);
    expect(find.text('ui-conversation'), findsNothing);
    expect(find.textContaining('rev '), findsNothing);
    expect(find.textContaining('shell'), findsNothing);
  });

  testWidgets('the appearance row opens a picker and applies the choice', (tester) async {
    final connection = _FakeConnection();
    connection.config = _FakeConfigApi();
    final theme = ThemeController();

    await _pump(tester, connection, theme);
    expect(find.text('深色'), findsOneWidget);

    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    expect(find.text('浅色'), findsOneWidget);

    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();

    expect(theme.mode, ThemeMode.light);
    expect(find.text('浅色'), findsOneWidget);
  });

  testWidgets('tapping a plugin row opens a read-only detail page', (tester) async {
    final connection = _FakeConnection();
    final config = _FakeConfigApi()
      ..namespaces = [
        _ns('shell', value: const {'timeoutMs': 60000, 'maxOutputBytes': 100000}, revision: 3),
      ];
    connection.config = config;

    await _pump(tester, connection, ThemeController());

    await tester.tap(find.text('Shell（命令执行）'));
    await tester.pumpAndSettle();

    expect(find.text('命令超时'), findsOneWidget);
    expect(find.text('60000'), findsOneWidget);
    expect(find.text('生效方式 live · 修订 3'), findsOneWidget);
    expect(find.textContaining('只读'), findsWidgets);
  });
}
