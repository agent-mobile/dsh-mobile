/// Connection state: server address + token, the transport client, and the
/// two WebSocket downlink streams.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:flutter/foundation.dart';

/// One session's history-window open state (web Session.openState).
enum SessionHistoryState {
  /// No history has been requested for this session.
  none,

  /// The tail-page request is in flight.
  loading,

  /// The tail page landed and the window is ready.
  open,

  /// The tail-page request failed; [ConnectionController.historyError] carries
  /// the rendered failure label.
  error,
}

/// Live link state between this app and the dsh host.
enum ConnectionStatus {
  /// An initial connect or manual reconnect is in flight.
  connecting,

  /// Both downlink streams are open and the latest probe succeeded.
  connected,

  /// A stream closed or the probe failed; reconnect is manual.
  disconnected,
}

/// Live connection to one dsh host.
class ConnectionController extends ChangeNotifier {
  ConnectionController({
    required this.baseUrl,
    required this.token,
    String? deviceId,
  }) : client = DshApiClient(
          baseUrl: baseUrl,
          token: token,
          deviceId: deviceId,
          deviceName: _deviceName,
        );

  /// Server origin, e.g. `http://192.168.1.5:3080`.
  final Uri baseUrl;

  /// Bearer token authenticating every request and handshake.
  final String token;

  /// Transport client shared by the domain API and event streams.
  final DshApiClient client;

  /// One-line device label the gateway management page shows for this install.
  static final String _deviceName =
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

  /// The single `$events` downlink (0.1.2 merged 0.1.1's two streams into
  /// one logical stream on `/api/remote.mux`).
  EventStream? _events;
  StreamSubscription<RemoteEventFrame>? _eventsSub;

  /// Per-session `session/follow` streams (0.1.2's live transcript channel;
  /// 0.1.1's global `session/event` push no longer exists). One open stream
  /// per chat the user has open.
  final Map<String, LogicalStream> _followStreams = {};

  /// One-shot waiter completed when a session's follow `snapshot` lands;
  /// loadHistory awaits it so the transcript opens on the snapshot itself.
  final Map<String, Completer<void>> _snapshotWaiters = {};

  /// Whether the last startFollowing open threw for the session (consumed by
  /// loadHistory's error path, then cleared on the next open attempt).
  final Set<String> _followOpenErrors = {};

  /// Sessions whose follow `snapshot` already folded; loadHistory skips its
  /// wait for them (a re-open replays nothing).
  final Set<String> _snapshotArrived = {};
  final Map<String, StreamSubscription<Object?>> _followSubs = {};

  /// Test hook: install one session's `session/follow` stream without opening
  /// a socket. Frames drive the exact same fold path as a live stream, so
  /// widget tests can feed snapshot fixtures.
  @visibleForTesting
  void installFollowForTest(String sessionId, LogicalStream stream) {
    _followStreams[sessionId] = stream;
    _followSubs[sessionId] = stream.items.listen(
      (item) => _foldFollowFrame(sessionId, item),
      onError: (Object _, StackTrace __) {},
    );
    _followOpenErrors.remove(sessionId);
  }

  /// Test hook: install the `$events` stream without opening a socket.
  @visibleForTesting
  void installMuxForTest(EventStream stream) {
    _events = stream;
    _eventsSub = stream.frames.listen(handleEventFrame);
  }

  /// High-level session-domain API backed by [client]. Tests may replace this
  /// field with a fake before a screen reads it.
  late DshSessionApi sessions = DshSessionApi(client);

  /// Interaction (approval/question) API backed by [client].
  late DshInteractionApi interaction = DshInteractionApi(client);

  /// Command/skill discovery and slash-command execution API.
  late DshCommandsApi commands = DshCommandsApi(client);

  /// Settings/credentials/LLM configuration API.
  late DshConfigApi config = DshConfigApi(client);

  /// Goal-domain mutations.
  late DshGoalApi goals = DshGoalApi(client);

  /// Subagent-domain methods.
  late DshSubagentApi subagents = DshSubagentApi(client);

  /// Workspace-domain methods.
  late DshWorkspaceApi workspaces = DshWorkspaceApi(client);

  /// Latest workspace rows in registry order.
  List<WorkspaceView> workspaceItems = const [];

  /// Registry-global archived-session set.
  List<String> archivedSessionIds = const [];

  /// Load the workspace list; failures are surfaced to the caller.
  Future<void> refreshWorkspaces() async {
    final list = await workspaces.list();
    workspaceItems = list.items;
    archivedSessionIds = list.archivedSessionIds;
    notifyListeners();
  }

  /// Per-session surface fold, keyed by session id.
  final Map<String, SessionSurface> _surfaces = {};

  /// Per-session pending approvals, keyed by session id.
  final Map<String, Map<String, ApprovalRequest>> _approvals = {};

  /// Per-session pending question batches, keyed by session id.
  final Map<String, QuestionRequest> _questions = {};

  /// Per-session projection values (goal, plan, todos, title, ...) under
  /// higher-seq-wins: `{sessionId: {key: {seq, value}}}`.
  final Map<String, Map<String, ({int seq, Object? value})>> _projections = {};

  /// Per-session background jobs (`session/jobs` whole snapshots).
  final Map<String, List<JobView>> _jobs = {};

  /// Per-session pending inbox queue (`session/queue` whole snapshots).
  final Map<String, List<Map<String, Object?>>> _queues = {};

  /// The `$events` generation id from the `ready` frame; needed to answer
  /// waterfalls. Null until the stream opens.
  String? _clientId;

  /// Per-session authoritative running state from `api-session/status`
  /// frames and the `session.list` baseline. Null until first reported.
  final Map<String, bool> _running = {};

  /// Monotonic connection-generation counter, bumped on every `_open`.
  /// Host frames record the generation they arrived in, so the reconnect
  /// `session.list` baseline can never overwrite a fresher live signal.
  int _epoch = 0;

  /// Generation in which the last `host/session-status` frame arrived, per
  /// session. A session whose entry matches [_epoch] has a live host signal
  /// in the current connection and is exempt from the list re-baseline.
  final Map<String, int> _runningFrameEpoch = {};

  /// Per-session history-window open state (web Session.openState).
  final Map<String, SessionHistoryState> _historyStates = {};

  /// Rendered failure label per session when [_historyStates] is `error`.
  final Map<String, String> _historyErrors = {};

  /// Whether older history exists before the loaded window (web hasMore).
  final Map<String, bool> _historyHasMore = {};

  /// Whether an older page request is in flight for one session.
  final Map<String, bool> _historyLoadingOlder = {};

  /// History page size for both the initial tail load and "加载更早". 10
  /// messages keeps a chunk-filtered + viewless page tiny (tens of KB, ~50 ms
  /// on the host), so loading is effectively imperceptible ("无感加载"); the
  /// cost is more pages to reach the beginning of a long session.
  static const int historyPageSize = 10;

  /// Latest folded surface for one session.
  SessionSurface surface(String sessionId) => _surfaces.putIfAbsent(
    sessionId,
    () => SessionSurface(sessionId: sessionId),
  );

  /// Latest projection values for one session.
  Map<String, ({int seq, Object? value})> projections(String sessionId) =>
      _projections.putIfAbsent(sessionId, () => {});

  /// Seed projection values from the history tail-page baseline. The host
  /// pushes `session/projection` frames only on change, so the initial
  /// projections (goal/todos/plan/...) arrive once in `session.history`'s
  /// tail page and must be folded here or docks stay empty. Higher-seq-wins,
  /// matching the live frame path.
  void seedProjections(
    String sessionId,
    Map<String, Object?> values, {
    required int seq,
  }) {
    final store = projections(sessionId);
    var changed = false;
    values.forEach((key, value) {
      final existing = store[key];
      if (existing == null || seq > existing.seq) {
        store[key] = (seq: seq, value: value);
        changed = true;
      }
    });
    if (changed) notifyListeners();
  }

  /// Latest background-job snapshot for one session.
  List<JobView> jobs(String sessionId) => _jobs[sessionId] ?? const [];

  /// Latest pending inbox queue for one session (`session/queue` items).
  List<Map<String, Object?>> queue(String sessionId) =>
      _queues[sessionId] ?? const [];

  /// Pending approval requests for one session.
  Map<String, ApprovalRequest> approvals(String sessionId) =>
      _approvals.putIfAbsent(sessionId, () => {});

  /// Pending question batch for one session, if any.
  QuestionRequest? pendingQuestion(String sessionId) => _questions[sessionId];

  /// Drop one answered approval so its card leaves the UI. The 0.1.2
  /// forwarded frame set carries no resolution event, so the answerer clears
  /// its own entry (mirroring the web's waterfall-promise lifecycle).
  void clearApproval(String sessionId, String eventId) {
    final pending = _approvals[sessionId];
    if (pending == null || pending.remove(eventId) == null) return;
    notifyListeners();
  }

  /// Drop the session's answered question batch so its dock leaves the UI.
  void clearQuestion(String sessionId) {
    if (_questions.remove(sessionId) == null) return;
    notifyListeners();
  }

  /// Authoritative running state for one session (the host's
  /// `host/session-status` signal), or null before the first report.
  bool? running(String sessionId) => _running[sessionId];

  /// Record the host's running signal for one session. The mux stream's
  /// `turn/start`/`turn/end` events are display hints, not the running gate.
  void updateRunning(String sessionId, bool value) {
    if (_running[sessionId] == value) return;
    _running[sessionId] = value;
    notifyListeners();
  }

  /// One session's history-window open state (web Session.openState).
  SessionHistoryState historyState(String sessionId) =>
      _historyStates[sessionId] ?? SessionHistoryState.none;

  /// Rendered history-load failure label, null unless the state is `error`.
  String? historyError(String sessionId) => _historyErrors[sessionId];

  /// Whether older history exists before the loaded window (web hasMore).
  bool historyHasMore(String sessionId) => _historyHasMore[sessionId] ?? false;

  /// Whether an older-page request is in flight (web loadingOlder).
  bool historyLoadingOlder(String sessionId) =>
      _historyLoadingOlder[sessionId] ?? false;

  /// Pull the session's history tail page and fold it into its surface
  /// (web Session.open/doOpen): events fold, the tail-page projection baseline
  /// seeds the value store, and the window head anchors later paging. The
  /// state machine drives the transcript's loading/error/ready presentation;
  /// failures land in the `error` state instead of being dropped.
  Future<void> loadHistory(String sessionId) async {
    if (_historyStates[sessionId] == SessionHistoryState.loading) return;
    _historyStates[sessionId] = SessionHistoryState.loading;
    _historyErrors.remove(sessionId);
    // Defer the loading notification: loadHistory is commonly called from a
    // pushed route's initState, and notifying synchronously there marks live
    // listeners (this screen's builders, the HomeScreen beneath the route)
    // dirty while the framework is building the incoming route.
    scheduleMicrotask(notifyListeners);
    try {
      // 0.1.2: the follow opening snapshot IS the tail page (records,
      // projections baseline, hasMore, and the paging anchor). Open the stream
      // and wait for its snapshot instead of paging blind.
      final waiter = _snapshotWaiters.putIfAbsent(sessionId, () => Completer<void>());
      await startFollowing(sessionId);
      if (_followOpenErrors.contains(sessionId)) {
        throw Exception('session/follow failed to open');
      }
      // A snapshot that already folded (injected fixture, or a stream opened
      // while loadHistory was queued) needs no wait.
      if (!_snapshotArrived.contains(sessionId)) {
        await waiter.future.timeout(const Duration(seconds: 10));
      }
      _historyStates[sessionId] = SessionHistoryState.open;
    } catch (error) {
      _historyStates[sessionId] = SessionHistoryState.error;
      _historyErrors[sessionId] = _historyErrorLabel(error);
    }
    notifyListeners();
  }

  /// Re-fold the tail history page into an open session's surface without
  /// touching the loading/open state: recovery for events published while the
  /// downlinks were down (a reconnect, or a session advanced by another
  /// client). Fold is idempotent by seq, so already-seen events are ignored and
  /// paging state is left untouched when nothing new arrived. Best-effort: a
  /// transport failure leaves the transcript as-is.
  Future<void> refreshHistory(String sessionId) async {
    if (historyState(sessionId) != SessionHistoryState.open) return;
    // A live follow stream already appends every new event; nothing to do.
    if (_followStreams.containsKey(sessionId)) return;
    try {
      // Recovery after the stream was lost: a fresh follow generation
      // re-replays an idempotent snapshot (fold dedupes by seq), covering
      // anything missed while the streams were down.
      final waiter = _snapshotWaiters.putIfAbsent(sessionId, () => Completer<void>());
      await startFollowing(sessionId);
      if (!_snapshotArrived.contains(sessionId)) {
        await waiter.future.timeout(const Duration(seconds: 10));
      }
      notifyListeners();
    } catch (_) {
      // Best-effort recovery; the next open or manual reload recovers.
    }
  }

  /// Page one older history window and splice it to the front of the surface
  /// (web Session.loadOlder): guarded by open/hasMore/loading state, the page
  /// must end immediately before the window head (else it is dropped fail-soft
  /// and hasMore clears), and older events fold through a scratch surface so
  /// the tail lifecycle state stays untouched. A transport failure keeps the
  /// window as-is; hasMore is unchanged so the user can retry.
  Future<void> loadOlder(String sessionId) async {
    final surf = surface(sessionId);
    if (historyState(sessionId) != SessionHistoryState.open) return;
    if (!historyHasMore(sessionId)) return;
    if (historyLoadingOlder(sessionId)) return;
    final headSeq = surf.windowHeadSeq;
    if (headSeq == null) return;
    _historyLoadingOlder[sessionId] = true;
    notifyListeners();
    try {
      final page = await sessions.history(
        sessionId: sessionId,
        // The older window ends at the event right before the current head.
        throughSeq: headSeq - 1,
        maxMessages: historyPageSize,
      );
      final older = page.entries;
      if (older.isEmpty) {
        _historyHasMore[sessionId] = page.hasMore;
        return;
      }
      // Continuity runs against RAW seqs: the older page's raw tail must sit
      // immediately before the window head. On a chunk-filtered page the last
      // kept event predates the raw tail (the filtered deltas fill the gap),
      // so the server's tailSeq is the authoritative bound.
      final tailSeq = page.tailSeq ?? older.last.event.seq;
      if (tailSeq + 1 != headSeq) {
        // Continuity assertion (web mirrors this): a discontinuous page is
        // dropped rather than rendering an out-of-order window.
        _historyHasMore[sessionId] = false;
        return;
      }
      final scratch = SessionSurface(sessionId: sessionId);
      for (final entry in older) {
        scratch.fold(entry.event);
      }
      surf.messages.insertAll(0, scratch.messages);
      surf.windowHeadSeq = page.headSeq ?? older.first.event.seq;
      _historyHasMore[sessionId] = page.hasMore;
    } catch (_) {
      // loadOlder failure keeps the window and hasMore (mirrors web).
    } finally {
      _historyLoadingOlder[sessionId] = false;
      notifyListeners();
    }
  }

  /// Render a history failure into a display label mirroring the web client's
  /// `chat.loadError` ({message}（{code}）); transport errors carry their full
  /// description because they have no wire code.
  String _historyErrorLabel(Object error) {
    if (error is RpcDomainException) {
      return '${error.error.message}（${error.error.code.wire}）';
    }
    return '$error';
  }

  /// Open a `session/follow` stream for [sessionId]: 0.1.2's live transcript
  /// channel. The stream yields one opening `snapshot` frame (folding the tail
  /// window + seeding the projection baseline) followed by live `event` frames
  /// appended to the surface. Idempotent per session.
  Future<void> startFollowing(String sessionId) async {
    if (_followStreams.containsKey(sessionId)) return;
    _followOpenErrors.remove(sessionId);
    _snapshotArrived.remove(sessionId);
    try {
      final stream = await client.openLogicalStream(
        'session/follow',
        {
          'args': {
            'request': {
              'address': {'kind': 'session', 'sessionId': sessionId},
            },
          },
        },
      );
      _followStreams[sessionId] = stream;
      _followSubs[sessionId] = stream.items.listen(
        (item) => _foldFollowFrame(sessionId, item),
        onError: (Object _, StackTrace __) {
          // A follow stream error must not tear the whole connection; the next
          // open (or a manual reload) recovers the live channel.
        },
      );
    } catch (_) {
      _followStreams.remove(sessionId);
      _followSubs.remove(sessionId);
      _followOpenErrors.add(sessionId);
    }
  }

  /// Close the `session/follow` stream for [sessionId] (when the chat closes).
  Future<void> stopFollowing(String sessionId) async {
    final sub = _followSubs.remove(sessionId);
    final stream = _followStreams.remove(sessionId);
    await sub?.cancel();
    await stream?.close();
  }

  /// Fold one `SessionEvent` into a session surface. The live path drives this
  /// from the session's `session/follow` stream; tests and the history pager
  /// use it directly.
  @visibleForTesting
  void foldSessionEvent(String sessionId, SessionEvent event) {
    surface(sessionId).fold(event);
    notifyListeners();
  }

  /// Fold one `session/follow` frame value into the session surface.
  void _foldFollowFrame(String sessionId, Object? item) {
    if (item is! Map) return;
    final json = Map<String, Object?>.from(item);
    final type = json['type'];
    if (type == 'snapshot') {
      // Opening window: fold the records, seed the projection baseline, and
      // anchor the paging state - the 0.1.2 snapshot carries the window's
      // oldest raw seq (older pages end at it), hasMore, and the live cursor.
      final rawRecords = json['records'];
      int? windowHead;
      if (rawRecords is List) {
        for (final raw in rawRecords) {
          if (raw is! Map) continue;
          final record = Map<String, Object?>.from(raw);
          final recordEvent = record['event'];
          if (recordEvent is! Map) continue;
          final wireEvent = Map<String, Object?>.from(recordEvent);
          final seq = wireEvent['seq'];
          // The window head is the FIRST record's raw seq, chunk rows
          // included: older pages must end exactly before the raw window.
          windowHead ??= seq is num ? seq.toInt() : null;
          if (record['type'] != 'event') continue;
          try {
            surface(sessionId).fold(SessionEvent.fromJson(wireEvent));
          } catch (_) {}
        }
      }
      if (windowHead != null) surface(sessionId).windowHeadSeq = windowHead;
      _historyHasMore[sessionId] = json['hasMore'] == true;
      _snapshotArrived.add(sessionId);
      final baseline = json['projections'];
      if (baseline is Map) {
        final values = baseline['values'];
        final asOfSeq = baseline['asOfSeq'];
        if (values is Map) {
          seedProjections(
            sessionId,
            Map<String, Object?>.from(values),
            seq: asOfSeq is num ? asOfSeq.toInt() : 0,
          );
        }
      }
      // The snapshot completes a pending loadHistory: the transcript is ready.
      final waiter = _snapshotWaiters.remove(sessionId);
      if (waiter != null && !waiter.isCompleted) waiter.complete();
      if (_historyStates[sessionId] == SessionHistoryState.loading) {
        _historyStates[sessionId] = SessionHistoryState.open;
      }
    } else if (type == 'event') {
      // A live appended event: {type:'event', event:{...}}.
      final eventJson = json['event'];
      if (eventJson is Map) {
        try {
          surface(sessionId).fold(SessionEvent.fromJson(Map<String, Object?>.from(eventJson)));
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  /// Frames from the single `$events` downlink (0.1.2): `ready`, `emit`
  /// (Cordis events like `session/event`), `waterfall` (answerable
  /// interactions), `cancel`.
  Stream<RemoteEventFrame> get eventFrames => _events?.frames ?? const Stream.empty();

  /// Live link state; changes notify listeners so the UI stays current.
  ConnectionStatus _status = ConnectionStatus.disconnected;
  ConnectionStatus get status => _status;

  /// Whether both downlink streams were opened and not yet closed. The probe
  /// must not resurrect a `connected` state over a dead stream.
  bool _streamsUp = false;

  /// Periodic liveness probe; the server pushes no keepalive frames, so a
  /// half-open socket would otherwise stay silent forever.
  Timer? _probeTimer;

  static const _probeInterval = Duration(seconds: 5);
  static const _probeTimeout = Duration(seconds: 3);

  /// Automatic downlink reconnect state: a capped-exponential backoff timer
  /// started whenever a stream drops after a successful connect. [_tearingDown]
  /// and [_disposed] keep intentional teardowns (a reconnect's own `_open`, the
  /// app shutting down) from rescheduling.
  Timer? _reconnectTimer;
  bool _tearingDown = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;

  /// Backoff ladder base and max exponent (1s, 2s, 4s, 8s, 16s, then 32s).
  static const _reconnectBaseSeconds = 1;
  static const _reconnectMaxExponent = 5;

  /// Record a status change with one notification per change.
  void _setStatus(ConnectionStatus value) {
    if (_status == value) return;
    _status = value;
    notifyListeners();
  }

  /// Verify credentials against the host and open both downlink streams.
  /// Throws [TransportException] on failure (401 = bad token).
  Future<void> connect() => _open();

  /// Re-establish both downlink streams after a disconnect. No-op while
  /// connected; on failure the status stays `disconnected` and the error is
  /// rethrown for the caller to surface.
  Future<void> reconnect() async {
    if (_status == ConnectionStatus.connected) return;
    await _open();
  }

  Future<void> _open() async {
    _setStatus(ConnectionStatus.connecting);
    _tearingDown = true;
    try {
      await _teardownStreams();
    } finally {
      _tearingDown = false;
    }
    try {
      _epoch++;
      // 0.1.2 has no host.describe; a successful session/list is the auth proof.
      final list = await client.callUnary<Object?>(
        'session/list',
        // The strict descriptor requires the reserved `_request` field even
        // when empty; bare {} args are rejected with arguments-invalid.
        const {'_request': <String, Object?>{}},
        (value) => value,
      );
      if (list is RpcResultErr) {
        throw TransportException(
          'authentication failed: ${list.error.message}',
        );
      }
      _events = await client.openEvents();
      _eventsSub = _events!.frames.listen(
        handleEventFrame,
        onError: _onStreamError,
        onDone: _onStreamDone,
      );
      _streamsUp = true;
      _probeTimer?.cancel();
      _probeTimer = Timer.periodic(_probeInterval, (_) => _probe());
      _setStatus(ConnectionStatus.connected);
      // Re-baseline the running gate after every (re)connect.
      await resyncRunningBaseline();
    } catch (_) {
      _setStatus(ConnectionStatus.disconnected);
      rethrow;
    }
  }

  /// One downlink socket closed or errored: the app can no longer receive
  /// events, so the link is down until the streams are re-established. The
  /// phone reconnects automatically with capped backoff rather than waiting
  /// for the user to reopen the connection.
  void _onStreamError(Object error, StackTrace stackTrace) {
    _streamsUp = false;
    _setStatus(ConnectionStatus.disconnected);
    _scheduleReconnect();
  }

  void _onStreamDone() {
    _streamsUp = false;
    _setStatus(ConnectionStatus.disconnected);
    _scheduleReconnect();
  }

  /// Schedule a downlink reconnect with capped exponential backoff. Only runs
  /// after a successful connect; a teardown that is part of an intentional
  /// `_open` or [dispose] never reschedules.
  void _scheduleReconnect() {
    if (_disposed || _tearingDown) return;
    _reconnectTimer?.cancel();
    final exponent = _reconnectAttempt.clamp(0, _reconnectMaxExponent);
    final delay = Duration(seconds: _reconnectBaseSeconds << exponent);
    _reconnectTimer = Timer(delay, _reconnectNow);
  }

  Future<void> _reconnectNow() async {
    if (_disposed) return;
    _reconnectAttempt++;
    try {
      await _open();
      _reconnectAttempt = 0;
    } catch (_) {
      _scheduleReconnect();
    }
  }

  /// Cheap unary probe that catches server-side outages between [connect]
  /// calls; success only restores `connected` while the streams are still up.
  Future<void> _probe() async {
    try {
      await client.callUnary<Object?>(
        'session/list',
        const {'_request': <String, Object?>{}},
        (value) => value,
        timeout: _probeTimeout,
      );
      if (_streamsUp && _status != ConnectionStatus.connected) {
        _setStatus(ConnectionStatus.connected);
      }
    } catch (_) {
      if (_status == ConnectionStatus.connected) {
        _setStatus(ConnectionStatus.disconnected);
      }
    }
  }

  /// Close the downlink socket and forget it. Idempotent.
  Future<void> _teardownStreams() async {
    await _eventsSub?.cancel();
    await _events?.close();
    _eventsSub = null;
    _events = null;
    _streamsUp = false;
  }

  /// Process one `$events` frame (0.1.2). Public so tests can drive the real
  /// parsing logic.
  ///
  /// 0.1.2's forwarded set is small: `api-session/*` (list/running/structural),
  /// the two answerable waterfalls (`approval/request`, `user-questions/request`),
  /// and `cancel`. Session transcript events are NOT forwarded here — an open
  /// chat receives them over its own `session/follow` stream (see ChatScreen).
  void handleEventFrame(RemoteEventFrame frame) {
    // The generation id for answering waterfalls arrives in the ready frame.
    if (frame.type == 'ready') {
      _clientId = frame.clientId;
      notifyListeners();
      return;
    }
    if (frame.type == 'emit') {
      _handleEmit(frame);
    } else if (frame.type == 'waterfall') {
      _handleWaterfall(frame);
    } else if (frame.type == 'cancel') {
      // A cancelled waterfall (e.g. a user-question batch the host dropped).
      final eventId = frame.eventId;
      if (eventId != null) {
        _questions.removeWhere((_, q) => q.eventId == eventId);
        for (final pending in _approvals.values) {
          pending.remove(eventId);
        }
      }
    }
    notifyListeners();
  }

  void _handleEmit(RemoteEventFrame frame) {
    final args = frame.args;
    switch (frame.event) {
      case 'api-session/status':
        // args: [sessionId, running]
        if (args.length >= 2 && args[0] is String) {
          final sessionId = args[0] as String;
          _runningFrameEpoch[sessionId] = _epoch;
          updateRunning(sessionId, args[1] == true);
        }
      case 'api-session/added':
      case 'api-session/removed':
        _scheduleStructuralRefresh();
      case 'api-session/error':
        // args: [sessionId, message]; surfaced by the next list refresh.
        break;
      default:
        break;
    }
  }

  void _handleWaterfall(RemoteEventFrame frame) {
    final eventId = frame.eventId;
    final request = frame.request;
    final sessionId = frame.agentId; // 0.1.2: the agent id equals the session id.
    if (eventId == null || request == null) return;
    switch (frame.event) {
      case 'approval/request':
        if (sessionId is String) {
          // The frame carries no approvalId (it comes from the session log);
          // key the pending entry by the waterfall eventId so the answer
          // correlates. toolName/callId/reason ride in `request`.
          approvals(sessionId)[eventId] = ApprovalRequest.fromWaterfall(
            clientId: _clientId ?? '',
            eventId: eventId,
            request: request,
          );
        }
      case 'user-questions/request':
        if (sessionId is String) {
          _questions[sessionId] = QuestionRequest.fromWaterfall(
            clientId: _clientId ?? '',
            eventId: eventId,
            request: request,
          );
        }
      default:
        break;
    }
  }

  /// Debounced structural refresh: a burst of host frames (session-added +
  /// workspace-changed on one create) collapses into one `session.list` +
  /// `workspace.list` pull. The guard avoids a re-entrant refresh while one
  /// is already in flight.
  Timer? _structuralRefreshTimer;
  bool _structuralRefreshing = false;

  static const _structuralRefreshDebounce = Duration(milliseconds: 200);

  void _scheduleStructuralRefresh() {
    if (_structuralRefreshing) return;
    _structuralRefreshTimer?.cancel();
    _structuralRefreshTimer = Timer(_structuralRefreshDebounce, _doStructuralRefresh);
  }

  Future<void> _doStructuralRefresh() async {
    if (_structuralRefreshing) return;
    _structuralRefreshing = true;
    try {
      final sessions = await this.sessions.list();
      await refreshWorkspaces();
      _lastStructuralSessionList = sessions;
    } catch (_) {
      // Best-effort; the next host frame or manual refresh retries.
    } finally {
      _structuralRefreshing = false;
      notifyListeners();
    }
  }

  /// Latest session list from a structural refresh, surfaced to listeners
  /// (HomeScreen consumes this to update its session list drawer without a
  /// manual refresh).
  List<SessionSummary> _lastStructuralSessionList = const [];
  List<SessionSummary> get structuralSessionList => _lastStructuralSessionList;

  /// Re-baseline the per-session running gate from `session.list`, called
  /// after every (re)connect. The host pushes `host/session-status` only on
  /// transitions, so a phone that missed an idle flip (a drop while the turn
  /// finished, or a reconnect after the fact) would otherwise stay stuck
  /// running forever. A session that already received a live host signal in
  /// the current connection generation keeps it: the host frame is fresher
  /// than the list snapshot.
  Future<void> resyncRunningBaseline() async {
    try {
      final list = await sessions.list();
      for (final summary in list) {
        if (_runningFrameEpoch[summary.sessionId] != _epoch) {
          updateRunning(summary.sessionId, summary.running);
        }
      }
    } catch (_) {
      // A failed baseline is best-effort; live host frames still drive running.
    }
  }

  /// Close both streams and the HTTP client.
  @override
  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _probeTimer?.cancel();
    _structuralRefreshTimer?.cancel();
    await _teardownStreams();
    client.dispose();
    _status = ConnectionStatus.disconnected;
    super.dispose();
  }
}
