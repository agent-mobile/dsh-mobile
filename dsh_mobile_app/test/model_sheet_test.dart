/// Widget regression: the model selector surfaces gateway-annotated
/// capabilities — vision models carry the 「视觉」 badge, and when the
/// deployment default refuses image input the header says so.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/state/connection_controller.dart';
import 'package:dsh_mobile_app/state/voice_mode_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers/follow_fixture.dart';

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
  }) async => SessionHistoryPage(entries: const [], hasMore: false, projections: null);

  @override
  Future<void> prompt({
    required String sessionId,
    required List<Map<String, Object?>> content,
    String mode = 'queue',
    String? clientTimeZone,
  }) async {}

  @override
  Future<SessionModels> models() async => SessionModels(
        defaultSelection: const {'provider': 'p1', 'model': 'm-text'},
        routableProviders: const ['p1'],
        groups: [
          ModelProviderGroup(
            id: 'p1',
            name: 'Provider One',
            models: [
              const ModelCatalogModel(id: 'm-text', name: 'Text Model', inputModalities: ['text']),
              const ModelCatalogModel(id: 'm-vision', name: 'Vision Model', inputModalities: ['text', 'image']),
            ],
          ),
        ],
        failures: const [],
      );
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
  testWidgets('the model sheet badges vision entries and flags a text-only default', (
    tester,
  ) async {
    final connection = _FakeConnection();
    connection.sessions = _FakeSessionApi();
    installSnapshot(connection, 's1', snapshotFrame(entries: const []));
    addTearDown(connection.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          connection: connection,
          sessionId: 's1',
          voiceModeController: VoiceModeController(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('m-text'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('视觉'), findsOneWidget);
    expect(find.textContaining('不支持图片'), findsOneWidget);
    expect(find.text('Vision Model'), findsOneWidget);
  });
}
