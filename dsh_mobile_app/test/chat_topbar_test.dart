/// Widget regression: the chat top bar — the AppBar shows the session's
/// durable title projection, and the session control strip carries the
/// model seat plus the permission and context actions.
library;

import 'dart:async';

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
        SessionSummary(sessionId: 's1', updatedAt: 1, running: false, blank: false, title: 'alpha-project'),
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
  late _FakeConnection connection;

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
    connection.sessions = _FakeSessionApi();
  });

  tearDown(() async {
    await connection.dispose();
  });

  testWidgets('the AppBar shows the session title and the command menu', (tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('alpha-project'), findsOneWidget);
    expect(find.byIcon(Icons.more_horiz), findsOneWidget);
  });

  testWidgets('the control strip carries the model, permission, and context actions', (tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
    expect(find.byIcon(Icons.radar_outlined), findsOneWidget);
  });

  testWidgets('the context trigger carries the occupancy ring when pressure data exists',
      (tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    // Without a contextPressure projection the ring paints nothing and adds
    // no percent tooltip (other chrome tooltips exist).
    expect(find.byTooltip('上下文已用 40%'), findsNothing);

    connection.seedProjections('s1', {
      'context-pressure': {'pressureTokens': 40000, 'contextWindow': 100000},
    }, seq: 9);
    await tester.pump();

    // The ring wraps the radar trigger and surfaces the occupancy percent.
    expect(find.byIcon(Icons.radar_outlined), findsOneWidget);
    expect(find.byTooltip('上下文已用 40%'), findsOneWidget);
  });

  testWidgets('the control strip sits inside the input card below the input row, both modes',
      (tester) async {
    // Text mode: the strip (model seat) rides inside the bordered composer
    // card, below the text field.
    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    final modelInText = tester.getCenter(find.byIcon(Icons.memory_outlined)).dy;
    final inputInText = tester.getCenter(find.byType(TextField)).dy;
    expect(modelInText > inputInText, isTrue);

    // Voice mode: same strip inside the voice card, below the waveform row.
    final voice = VoiceModeController();
    // Fire-and-forget: the mode flips synchronously before setMode's first
    // await (its secure-storage write never completes in widget tests).
    unawaited(voice.setMode(VoiceMode.voice));
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          connection: connection,
          sessionId: 's1',
          voiceModeController: voice,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byIcon(Icons.memory_outlined), findsOneWidget);
    final modelInVoice = tester.getCenter(find.byIcon(Icons.memory_outlined)).dy;
    final voiceDock = tester.getCenter(find.byIcon(Icons.attach_file)).dy;
    expect(modelInVoice > voiceDock, isTrue);
  });

  testWidgets('voice card: attach button spans the waveform + status rows', (tester) async {
    final voice = VoiceModeController();
    unawaited(voice.setMode(VoiceMode.voice));
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          connection: connection,
          sessionId: 's1',
          voiceModeController: voice,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    // Standby status line renders under the waveform in the right column;
    // the attach button centers across both rows, so the status text's
    // center lands below the attach button's center. (The label reads
    // 等待回复… because the conversation loop auto-arms in voice mode.)
    final statusFinder = find.textContaining('（点击结束）');
    expect(statusFinder, findsOneWidget);
    final attachDy = tester.getCenter(find.byIcon(Icons.attach_file)).dy;
    final statusDy = tester.getCenter(statusFinder).dy;
    expect(statusDy > attachDy, isTrue);
  });

  testWidgets('text composer card keeps its border; the field itself stays frameless', (tester) async {
    bool? borderedComposer(WidgetTester tester) {
      bool? found;
      tester.element(find.byType(TextField)).visitAncestorElements((element) {
        final widget = element.widget;
        if (widget is Container && widget.decoration is BoxDecoration) {
          found = ((widget.decoration as BoxDecoration).border != null);
          return false;
        }
        return true;
      });
      return found;
    }

    // Text mode composer card: framed.
    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(borderedComposer(tester), isTrue);

    // The composer field overrides the global inputDecorationTheme (which
    // paints visible enabled/focused borders on every field): both states
    // are frameless.
    final decoration = tester.widget<TextField>(find.byType(TextField)).decoration!;
    expect(decoration.enabledBorder, isA<OutlineInputBorder>());
    expect((decoration.enabledBorder! as OutlineInputBorder).borderSide, BorderSide.none);
    expect(decoration.focusedBorder, isA<OutlineInputBorder>());
    expect((decoration.focusedBorder! as OutlineInputBorder).borderSide, BorderSide.none);

    // Voice mode card: still framed. The attach icon's first decorated
    // Container ancestor is the voice card.
    final voice = VoiceModeController();
    unawaited(voice.setMode(VoiceMode.voice));
    await tester.pumpWidget(
      MaterialApp(
        home: ChatScreen(
          connection: connection,
          sessionId: 's1',
          voiceModeController: voice,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    bool? borderedVoice;
    tester.element(find.byIcon(Icons.attach_file)).visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is Container && widget.decoration is BoxDecoration) {
        borderedVoice = ((widget.decoration as BoxDecoration).border != null);
        return false;
      }
      return true;
    });
    expect(borderedVoice, isTrue);
  });

  testWidgets('a live title projection overrides the list snapshot', (tester) async {
    await tester.pumpWidget(buildScreen());
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('alpha-project'), findsOneWidget);

    // The host retitles the session: the AppBar follows the projection.
    connection.seedProjections('s1', {'title': 'renamed-live'}, seq: 99);
    await tester.pump();
    expect(find.text('renamed-live'), findsOneWidget);
    expect(find.text('alpha-project'), findsNothing);
  });
}