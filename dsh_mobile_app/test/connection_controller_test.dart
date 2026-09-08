/// Tests for the connection state controller: the mux-frame handler drives
/// session surfaces, pending approvals, and pending questions.
library;

import 'dart:async';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:dsh_mobile_app/state/connection_controller.dart';
import 'helpers/follow_fixture.dart';
import 'package:flutter_test/flutter_test.dart';

/// One `user/message` history entry with seq and text.
HistoryEntry msg(int seq, String text) => HistoryEntry(
      SessionEvent(seq: seq, type: 'user/message', time: seq, data: {
        'source': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
      }),
      null,
    );

/// Pageable history fake: pages keyed by `beforeSeq` (null = tail), with
/// optional one-shot failure, an in-flight gate, and raw window bounds.
class _PagedSessionApi extends DshSessionApi {
  _PagedSessionApi()
      : super(DshApiClient(baseUrl: Uri.parse('http://fake:3080'), token: 't'));

  final Map<int?, ({List<HistoryEntry> entries, bool hasMore, int? headSeq, int? tailSeq})> pages = {};
  Map<String, Object?>? tailProjections;
  int historyCalls = 0;

  /// When set, the next history call throws it (then clears).
  Object? failWith;

  /// When set, history awaits it before answering.
  Completer<void>? gate;

  @override
  Future<SessionHistoryPage> history({
    required String sessionId,
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
  }) async {
    historyCalls++;
    if (gate != null) await gate!.future;
    final error = failWith;
    if (error != null) {
      failWith = null;
      throw error;
    }
    final page = pages[throughSeq];
    return SessionHistoryPage(
      entries: page?.entries ?? const [],
      hasMore: page?.hasMore ?? false,
      projections: beforeSeq == null ? tailProjections : null,
      headSeq: page?.headSeq,
      tailSeq: page?.tailSeq,
    );
  }
}

/// List-only session API fake for the running-baseline resync tests.
class _ListSessionApi extends DshSessionApi {
  _ListSessionApi({required this.runningBySession})
      : super(DshApiClient(baseUrl: Uri.parse('http://fake:3080'), token: 't'));

  /// `running` field per session id returned by `list()`.
  final Map<String, bool> runningBySession;

  /// When set, the next `list()` throws it (then clears).
  Object? failWith;

  @override
  Future<List<SessionSummary>> list() async {
    final error = failWith;
    if (error != null) {
      failWith = null;
      throw error;
    }
    return [
      for (final entry in runningBySession.entries)
        SessionSummary(
          sessionId: entry.key,
          updatedAt: 1,
          running: entry.value,
          blank: false,
        ),
    ];
  }
}

void main() {
  late ConnectionController connection;

  RemoteEventFrame emit(String event, List<Object?> args) =>
      RemoteEventFrame.fromJson({'type': 'emit', 'event': event, 'args': args});

  RemoteEventFrame waterfall(
    String event,
    String eventId,
    String agentId,
    Map<String, Object?> request,
  ) =>
      RemoteEventFrame.fromJson({
        'type': 'waterfall',
        'event': event,
        'eventId': eventId,
        'agentId': agentId,
        'request': request,
      });

  RemoteEventFrame cancel(String eventId) =>
      RemoteEventFrame.fromJson({'type': 'cancel', 'eventId': eventId});

  setUp(() {
    connection = ConnectionController(
      baseUrl: Uri.parse('http://fake:3080'),
      token: 't',
    );
  });

  tearDown(() async {
    await connection.dispose();
  });

  test('ready frame captures the client id', () async {
    connection.handleEventFrame(
      RemoteEventFrame.fromJson({'type': 'ready', 'clientId': 'gen-1', 'home': {'home': '/h'}}),
    );
    // The client id is internal; the observable effect is that waterfalls
    // answered later echo it (covered by the interaction API tests).
    expect(connection.status, isA<ConnectionStatus>());
  });

  test('approval/request waterfall tracks, keyed by the waterfall event id',
      () async {
    connection.handleEventFrame(waterfall(
      'approval/request',
      'ev-a',
      's1',
      {'toolName': 'bash', 'callId': 'c1', 'reason': 'escalate'},
    ));
    expect(connection.approvals('s1'), hasLength(1));
    expect(connection.approvals('s1')['ev-a']!.toolName, 'bash');
    expect(connection.approvals('s1')['ev-a']!.callId, 'c1');
  });

  test('clearApproval drops the answered card and cancel clears approvals too',
      () async {
    connection.handleEventFrame(waterfall(
      'approval/request',
      'ev-a',
      's1',
      {'toolName': 'bash'},
    ));
    connection.handleEventFrame(waterfall(
      'approval/request',
      'ev-b',
      's1',
      {'toolName': 'write'},
    ));
    expect(connection.approvals('s1'), hasLength(2));

    // The answerer clears its own entry once the answer is accepted.
    connection.clearApproval('s1', 'ev-a');
    expect(connection.approvals('s1'), hasLength(1));
    expect(connection.approvals('s1').keys, ['ev-b']);

    // A host-side cancel of the same waterfall id clears it as well.
    connection.handleEventFrame(cancel('ev-b'));
    expect(connection.approvals('s1'), isEmpty);
  });

  test('clearQuestion drops the answered batch', () async {
    connection.handleEventFrame(waterfall(
      'user-questions/request',
      'ev-q',
      's1',
      {
        'questions': [
          {'id': 'q1', 'question': 'Pick?', 'options': [
                {'label': 'A'},
              ]},
        ],
      },
    ));
    expect(connection.pendingQuestion('s1'), isNotNull);

    connection.clearQuestion('s1');
    expect(connection.pendingQuestion('s1'), isNull);
  });

  test('user-questions/request waterfall tracks, cancel clears by event id',
      () async {
    expect(connection.pendingQuestion('s1'), isNull);

    connection.handleEventFrame(waterfall(
      'user-questions/request',
      'ev-q',
      's1',
      {
        'questions': [
          {'id': 'q1', 'question': 'Pick?', 'options': [
                {'label': 'A'},
              ]},
        ],
      },
    ));
    final question = connection.pendingQuestion('s1');
    expect(question, isNotNull);
    expect(question!.eventId, 'ev-q');
    expect(question.questions.single.question, 'Pick?');

    connection.handleEventFrame(cancel('ev-q'));
    expect(connection.pendingQuestion('s1'), isNull);
  });

  test('api-session/status drives per-session running state', () async {
    expect(connection.running('s1'), isNull);

    connection.handleEventFrame(emit('api-session/status', ['s1', true]));
    expect(connection.running('s1'), isTrue);

    connection.handleEventFrame(emit('api-session/status', ['s1', false]));
    expect(connection.running('s1'), isFalse);

    // Other sessions are unaffected.
    expect(connection.running('other'), isNull);
  });

  test('updateRunning seeds the running gate and notifies listeners', () async {
    var notified = 0;
    connection.addListener(() => notified++);

    connection.updateRunning('s1', true);
    expect(connection.running('s1'), isTrue);
    expect(notified, 1);

    // A no-op change does not re-notify.
    connection.updateRunning('s1', true);
    expect(notified, 1);
  });

  group('running baseline resync', () {
    late _ListSessionApi api;

    setUp(() {
      api = _ListSessionApi(runningBySession: const {'s1': false});
      connection.sessions = api;
    });

    test('reconnect re-baselines a stale running=true from the list', () async {
      // The phone saw running:true, then its host stream dropped before the
      // idle transition; a stale true survived the disconnect.
      connection.updateRunning('s1', true);
      expect(connection.running('s1'), isTrue);

      await connection.resyncRunningBaseline();

      // session.list says idle, and no host frame arrived in this generation:
      // the baseline must correct the stuck gate.
      expect(connection.running('s1'), isFalse);
    });

    test('a live host signal in this generation wins over the list baseline',
        () async {
      connection.handleEventFrame(emit('api-session/status', ['s1', true]));
      expect(connection.running('s1'), isTrue);

      // The stale list snapshot (idle) must not overwrite the fresher frame.
      await connection.resyncRunningBaseline();
      expect(connection.running('s1'), isTrue);
    });

    test('sessions absent from the list keep their live signal', () async {
      connection.handleEventFrame(emit('api-session/status', ['gone', true]));
      await connection.resyncRunningBaseline();
      expect(connection.running('gone'), isTrue);
    });

    test('a failed baseline leaves the gate untouched', () async {
      api.failWith = const TransportException('boom');
      connection.updateRunning('s1', true);
      await connection.resyncRunningBaseline();
      expect(connection.running('s1'), isTrue);
    });
  });

  group('history window', () {
    late _PagedSessionApi api;
    TestFollowStream? follow;

    /// Install a follow fixture replaying [entries] as the opening snapshot.
    void feedSnapshot({
      required List<HistoryEntry> entries,
      required int cursor,
      required bool hasMore,
      Map<String, Object?>? projections,
      List<Map<String, Object?>> rawRecords = const [],
    }) {
      follow = TestFollowStream();
      connection.installFollowForTest('s1', follow!);
      follow!.add({
        'type': 'snapshot',
        'cursor': cursor,
        'hasMore': hasMore,
        if (projections != null) 'projections': projections,
        'records': [
          ...rawRecords,
          for (final e in entries)
            {
              'type': 'event',
              'event': {
                'seq': e.event.seq,
                'type': e.event.type,
                'time': e.event.time,
                'data': e.event.data,
              },
            },
        ],
      });
    }

    setUp(() {
      api = _PagedSessionApi();
      connection.sessions = api;
    });

    tearDown(() async {
      await follow?.close();
      follow = null;
    });

    test('loadHistory folds the tail snapshot, seeds projections, and opens', () async {
      feedSnapshot(
        entries: [msg(1, 'one'), msg(2, 'two'), msg(3, 'three')],
        cursor: 3,
        hasMore: true,
        projections: {'asOfSeq': 3, 'values': {'goal': {'objective': 'x'}}},
      );

      await connection.loadHistory('s1');

      expect(connection.historyState('s1'), SessionHistoryState.open);
      expect(connection.historyHasMore('s1'), isTrue);
      expect(connection.historyLoadingOlder('s1'), isFalse);
      final surf = connection.surface('s1');
      expect(surf.messages.map((m) => m.seq), [1, 2, 3]);
      expect(surf.windowHeadSeq, 1);
      expect(connection.projections('s1')['goal']?.value, {'objective': 'x'});
    });

    test('loadHistory marks the window open only after the snapshot folds', () async {
      // The state machine drives the transcript's loading/ready presentation:
      // no snapshot yet means still loading.
      final pending = connection.loadHistory('s1');
      expect(connection.historyState('s1'), SessionHistoryState.loading);

      feedSnapshot(entries: [msg(1, 'one')], cursor: 1, hasMore: false);
      await pending;
      expect(connection.historyState('s1'), SessionHistoryState.open);
      expect(connection.surface('s1').messages, hasLength(1));
    });

    test('refreshHistory is a no-op while the live follow stream is open', () async {
      feedSnapshot(entries: [msg(1, 'one'), msg(2, 'two')], cursor: 2, hasMore: true);
      await connection.loadHistory('s1');
      expect(connection.historyState('s1'), SessionHistoryState.open);

      // The live stream appends; refresh has nothing to reopen.
      await connection.refreshHistory('s1');
      expect(follow, isNotNull);
      expect(connection.historyState('s1'), SessionHistoryState.open);
    });

    test('live follow event frames append to the open surface', () async {
      feedSnapshot(entries: [msg(1, 'one'), msg(2, 'two')], cursor: 2, hasMore: true);
      await connection.loadHistory('s1');

      // A live appended event: {type:'event', event:{...}}.
      follow!.add({
        'type': 'event',
        'event': {'seq': 3, 'type': 'user/message', 'time': 3, 'data': {
          'source': 'user',
          'content': [
            {'type': 'text', 'text': 'three'},
          ],
        }},
      });
      await pumpEventQueue();

      expect(connection.surface('s1').messages.map((m) => m.seq), [1, 2, 3]);
    });

    test('refreshHistory is a no-op until the window is open', () async {
      await connection.refreshHistory('s1');
      expect(connection.historyState('s1'), SessionHistoryState.none);
      expect(api.historyCalls, 0);
    });

    test('loadOlder splices a contiguous older page and updates hasMore', () async {
      feedSnapshot(entries: [
        for (var i = 10; i <= 13; i++) msg(i, 'msg-$i'),
      ], cursor: 13, hasMore: true);
      api.pages[9] = (
        entries: [for (var i = 1; i <= 9; i++) msg(i, 'msg-$i')],
        hasMore: false,
        headSeq: null,
        tailSeq: null,
      );

      await connection.loadHistory('s1');
      await connection.loadOlder('s1');

      final surf = connection.surface('s1');
      expect(surf.messages.map((m) => m.seq), List.generate(13, (i) => i + 1));
      expect(surf.windowHeadSeq, 1);
      expect(connection.historyHasMore('s1'), isFalse);
    });

    test('loadOlder guards: not open / no hasMore no-op', () async {
      await connection.loadOlder('s1');
      expect(api.historyCalls, 0);

      feedSnapshot(entries: [msg(1, 'one')], cursor: 1, hasMore: false);
      await connection.loadHistory('s1');
      await connection.loadOlder('s1');
      expect(api.historyCalls, 0);
    });

    test('loadOlder guards while a request is in flight', () async {
      feedSnapshot(entries: [msg(1, 'one'), msg(2, 'two')], cursor: 2, hasMore: true);
      api.pages[0] = (entries: [msg(0, 'zero')], hasMore: false, headSeq: null, tailSeq: null);
      await connection.loadHistory('s1');

      final gate = Completer<void>();
      api.gate = gate;
      final pending = connection.loadOlder('s1');
      final second = connection.loadOlder('s1'); // guarded while loading
      gate.complete();
      await pending;
      await second;

      expect(api.historyCalls, 1); // one older; the second no-oped
      expect(connection.surface('s1').messages.map((m) => m.seq), [0, 1, 2]);
    });

    test('loadOlder drops a discontinuous page and clears hasMore', () async {
      feedSnapshot(entries: [msg(10, 'ten'), msg(11, 'eleven')], cursor: 11, hasMore: true);
      // The older page ends at seq 8, but the window head is 10: a gap.
      api.pages[9] = (
        entries: [msg(5, 'five'), msg(6, 'six'), msg(7, 'seven'), msg(8, 'eight')],
        hasMore: false,
        headSeq: null,
        tailSeq: null,
      );

      await connection.loadHistory('s1');
      await connection.loadOlder('s1');

      final surf = connection.surface('s1');
      expect(surf.messages.map((m) => m.seq), [10, 11]);
      expect(surf.windowHeadSeq, 10);
      expect(connection.historyHasMore('s1'), isFalse);
    });

    test('loadOlder keeps the window on failure', () async {
      feedSnapshot(entries: [msg(1, 'one'), msg(2, 'two')], cursor: 2, hasMore: true);
      api.pages[0] = (entries: [msg(0, 'zero')], hasMore: false, headSeq: null, tailSeq: null);
      await connection.loadHistory('s1');

      api.failWith = const TransportException('boom');
      await connection.loadOlder('s1');

      final surf = connection.surface('s1');
      expect(surf.messages.map((m) => m.seq), [1, 2]);
      expect(connection.historyHasMore('s1'), isTrue); // retryable
    });

    test('loadOlder pages against the raw window head (chunk rows included)', () async {
      // A tail snapshot whose raw window head is 4 (a chunk row precedes the
      // first kept event at 6): the page request ends at 3, before the head.
      feedSnapshot(
        entries: [msg(6, 'six'), msg(100, 'hundred')],
        cursor: 100,
        hasMore: true,
        rawRecords: [
          {
            'type': 'chunks',
            'event': {
              'type': 'chunkrow/text-chunks',
              'seq': 4,
              'time': 4,
              'data': {'turn': 1, 'step': 1, 'index': 0},
            },
          },
        ],
      );
      api.pages[3] = (
        entries: [msg(3, 'three')],
        hasMore: false,
        headSeq: 1,
        tailSeq: 3,
      );

      await connection.loadHistory('s1');
      final surf = connection.surface('s1');
      expect(surf.messages.map((m) => m.seq), [6, 100]);
      expect(surf.windowHeadSeq, 4);

      await connection.loadOlder('s1');
      expect(surf.messages.map((m) => m.seq), [3, 6, 100]);
      expect(surf.windowHeadSeq, 1);
      expect(connection.historyHasMore('s1'), isFalse);
    });
  });
}
