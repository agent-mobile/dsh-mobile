/// High-level session-domain API over [DshApiClient].
///
/// Mirrors the `sessions` domain of the TypeScript contract: list, create,
/// history (message-aligned pages), prompt (send), rename, fork, and cancel.
/// Method payloads and values are plain JSON maps; the caller decodes typed
/// projections from them.
library;

import 'dart:convert';

import 'events.dart';
import 'settings_api.dart' show ModelProviderGroup;
import 'transport.dart';
import 'wire.dart';

/// Unary timeout for `session.history`: a large transcript's read and view
/// rendering on the host can exceed the general 30 s call budget, so the
/// history call relaxes it (the client mirrors the web's un-capped fetch).
const historyUnaryTimeout = Duration(seconds: 60);

/// One session list row (`SessionSummary`).
class SessionSummary {
  const SessionSummary({
    required this.sessionId,
    required this.updatedAt,
    required this.running,
    required this.blank,
    this.cwd,
    this.agentPreset,
    this.parentSessionId,
    this.origin,
    this.title,
  });

  final String sessionId;
  final int updatedAt;
  final bool running;

  /// Derived conversation-not-started bit: hide blank sessions from lists and
  /// reuse them for New Session.
  final bool blank;

  final String? cwd;
  final String? agentPreset;
  final String? parentSessionId;
  final String? origin;

  /// Log-backed display title from the row's `projections.values.title`, when
  /// the projection registry supplies one.
  final String? title;

  factory SessionSummary.fromJson(Map<String, Object?> json) {
    // The row's projections block carries {asOfSeq, values:{title, ...}}; the
    // title is the display name. Read it defensively.
    String? title;
    final projections = json['projections'];
    if (projections is Map) {
      final values = projections['values'];
      if (values is Map) {
        final rawTitle = values['title'];
        if (rawTitle is String) title = rawTitle;
      }
    }
    return SessionSummary(
      sessionId: json['sessionId'] as String? ?? '',
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      running: json['running'] == true,
      blank: json['blank'] == true,
      cwd: json['cwd'] as String?,
      agentPreset: json['agentPreset'] as String?,
      parentSessionId: json['parentSessionId'] as String?,
      origin: json['origin'] as String?,
      title: title,
    );
  }

  /// Display title projection mirroring the web client's `displayTitleOf`:
  /// the durable title, else the working-directory basename, else the raw id.
  /// A blank session's placeholder label is the caller's concern.
  String get displayTitle {
    if (title != null && title!.isNotEmpty) return title!;
    final base = workspaceTitleOf(cwd);
    if (base.isNotEmpty) return base;
    return sessionId;
  }
}

/// Directory basename label (both path separators accepted); empty for a
/// missing or root-only path. Mirrors the web client's `workspaceTitleOf`.
String workspaceTitleOf(String? cwd) {
  if (cwd == null || cwd.isEmpty) return '';
  final trimmed = cwd.replaceAll(RegExp(r'[/\\]+$'), '');
  if (trimmed.isEmpty) return '';
  final parts = trimmed.split(RegExp(r'[/\\]'));
  return parts.isNotEmpty ? parts.last : '';
}

/// One history page: message-aligned events plus whether older pages exist.
class SessionHistoryPage {
  const SessionHistoryPage({
    required this.entries,
    required this.hasMore,
    this.projections,
    this.headSeq,
    this.tailSeq,
  });

  final List<HistoryEntry> entries;
  final bool hasMore;

  /// Tail-page projection baseline (watermark snapshot). 0.1.2's `session/page`
  /// no longer carries one — projections now arrive via the `session/follow`
  /// stream — so this is null on a 0.1.2 page. Kept for the App's fold, which
  /// null-checks it.
  final Map<String, Object?>? projections;

  /// 0.1.1-only: raw seq of the page's first event. Null on a 0.1.2 page
  /// (window continuity now rides the `session/follow` cursor, not page seqs).
  final int? headSeq;

  /// 0.1.1-only: raw seq of the page's last event. Null on a 0.1.2 page.
  final int? tailSeq;

  factory SessionHistoryPage.fromJson(Map<String, Object?> json) {
    // 0.1.2 `session/page` names the window `records`: a chronological run of
    // `{type:'event', event}` or `{type:'chunks', event}`. Fold only the
    // `event` records into the surface; `chunks` records are packed streaming
    // deltas already reflected in the final `assistant/message`.
    final rawRecords = json['records'];
    final entries = <HistoryEntry>[];
    if (rawRecords is List) {
      for (final raw in rawRecords) {
        if (raw is! Map) continue;
        if (raw['type'] != 'event') continue;
        final eventJson = raw['event'];
        if (eventJson is! Map) continue;
        final event = SessionEvent.fromJson(Map<String, Object?>.from(eventJson));
        entries.add(HistoryEntry(event, null));
      }
    }
    return SessionHistoryPage(
      entries: entries,
      hasMore: json['hasMore'] == true,
    );
  }
}

/// A durable image reference returned by `session.attachment`.
class SessionAttachment {
  const SessionAttachment({required this.attachmentId, required this.mediaType, required this.data});

  final String attachmentId;
  final String mediaType;

  /// Base64-encoded image bytes.
  final String data;
}

/// One user-visible skill catalog row (`skill.list`).
class SkillEntry {
  const SkillEntry({required this.name, required this.description, required this.modelInvocable, this.whenToUse});

  final String name;
  final String description;
  final bool modelInvocable;
  final String? whenToUse;
}

/// Session-domain methods.
class DshSessionApi {
  DshSessionApi(this._client);

  final DshApiClient _client;

  /// List persisted sessions (updatedAt descending).
  ///
  /// Wire shape: the descriptor's reserved `_request` named parameter must be
  /// present even though empty — the host's strict descriptor rejects bare
  /// `{}` args with `missing "_request"`.
  Future<List<SessionSummary>> list() async {
    final result = await _client.callUnary(
      'session/list',
      const {
        '_request': <String, Object?>{},
      },
      (value) => value,
    );
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('session.list', result.error);
      case RpcResultOk(:final value):
        final map = value is Map ? value : const <String, Object?>{};
        final items = map['items'];
        if (items is! List) return const [];
        return items
            .whereType<Map>()
            .map((item) => SessionSummary.fromJson(Map<String, Object?>.from(item)))
            .toList();
    }
  }

  /// Create a session (and its idle agent). A caller may preallocate
  /// `sessionId`; retries with the same id and cwd return the same session.
  Future<String> create({
    String? workspaceId,
    String? cwd,
    String? sessionId,
    String? agentPreset,
  }) async {
    final result = await _client.callUnary('session/create', {
      'request': <String, Object?>{
        if (workspaceId != null) 'workspaceId': workspaceId,
        if (cwd != null) 'cwd': cwd,
        if (sessionId != null) 'sessionId': sessionId,
        if (agentPreset != null) 'agentPreset': agentPreset,
      },
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('session.create', result.error);
      case RpcResultOk(:final value):
        final map = value is Map ? value : const <String, Object?>{};
        final id = map['sessionId'];
        if (id is! String) throw const FormatException('session.create lacked sessionId');
        return id;
    }
  }

  /// Read a window of history events, message-aligned.
  ///
  /// 0.1.2 wire shape: `throughSeq` is the window's INCLUSIVE upper bound —
  /// the log seq the caller's window ends at; `-1` is legal and yields an
  /// empty window. First-load flow: take the cursor from the `session/follow`
  /// snapshot frame; paging older continues with `beforeSeq`/`headSeq - 1`.
  /// [includeViews]/[includeChunks] of 0.1.1 are gone: the page always returns
  /// message-aligned records (`records`) plus `hasMore`.
  Future<SessionHistoryPage> history({
    required String sessionId,
    required int throughSeq,
    int? beforeSeq,
    int? maxMessages,
  }) async {
    final args = <String, Object?>{
      'request': <String, Object?>{
        'address': {'kind': 'session', 'sessionId': sessionId},
        'throughSeq': throughSeq,
        if (beforeSeq != null) 'beforeSeq': beforeSeq,
        if (maxMessages != null) 'maxMessages': maxMessages,
      },
    };
    final result = await _client.callUnary('session/page', args, (value) => value, timeout: historyUnaryTimeout);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('session/page', result.error);
      case RpcResultOk(:final value):
        final map = value is Map ? Map<String, Object?>.from(value) : const <String, Object?>{};
        return SessionHistoryPage.fromJson(map);
    }
  }

  /// Send a message (queue or steer). A leading `/` text block is a slash
  /// command executed host-side.
  Future<void> prompt({
    required String sessionId,
    required List<Map<String, Object?>> content,
    String mode = 'queue',
    String? clientTimeZone,
  }) async {
    final result = await _client.callUnary('session/prompt', {
      'request': <String, Object?>{
        // 0.1.2 requires a client-minted requestId for prompt correlation.
        'requestId': mintRpcId(),
        'sessionId': sessionId,
        'mode': mode,
        'content': content,
        if (clientTimeZone != null) 'clientTimeZone': clientTimeZone,
      },
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('session/prompt', result.error);
      case RpcResultOk():
        return;
    }
  }

  /// Rename a session, pinning the title against automatic regeneration.
  Future<void> rename({required String sessionId, required String title}) async {
    final result = await _client.callUnary('session/rename', {
      'request': <String, Object?>{'sessionId': sessionId, 'title': title},
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('session.rename', result.error);
      case RpcResultOk():
        return;
    }
  }

  /// Edit, remove, or steer one pending queued occurrence.
  Future<void> updateQueue({
    required String sessionId,
    required String itemId,
    required Map<String, Object?> action,
  }) async {
    final result = await _client.callUnary('session/updateQueue', {
      'request': <String, Object?>{
        'sessionId': sessionId,
        'itemId': itemId,
        'action': action,
      },
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('session.updateQueue', result.error);
      case RpcResultOk():
        return;
    }
  }

  /// Fork a new session from a completed-turn prefix.
  Future<String> fork({required String sessionId, int? atSeq}) async {
    final result = await _client.callUnary('session/fork', {
      'request': <String, Object?>{
        'sessionId': sessionId,
        if (atSeq != null) 'atSeq': atSeq,
      },
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('session.fork', result.error);
      case RpcResultOk(:final value):
        final map = value is Map ? value : const <String, Object?>{};
        final id = map['sessionId'];
        if (id is! String) throw const FormatException('session.fork lacked sessionId');
        return id;
    }
  }

  /// Stop an ordinary session's active turn, preserving pending inbox work.
  Future<void> cancel({required String sessionId}) async {
    final result = await _client.callUnary('session/cancel', {
      'request': <String, Object?>{'sessionId': sessionId},
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('session.cancel', result.error);
      case RpcResultOk():
        return;
    }
  }

  /// Read one durable image after proving this session's log references it.
  Future<SessionAttachment> attachment({
    required String sessionId,
    required String attachmentId,
  }) async {
    final result = await _client.callUnary('session/attachment', {
      'request': <String, Object?>{
        'sessionId': sessionId,
        'attachmentId': attachmentId,
      },
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('session.attachment', result.error);
      case RpcResultOk(:final value):
        final map = value is Map ? value : const <String, Object?>{};
        final attachment = map['attachment'];
        final data = map['data'];
        if (attachment is! Map || data is! String) {
          throw const FormatException('session.attachment lacked attachment/data');
        }
        final id = attachment['attachmentId'];
        final mediaType = attachment['mediaType'];
        return SessionAttachment(
          attachmentId: id is String ? id : '',
          mediaType: mediaType is String ? mediaType : '',
          data: data,
        );
    }
  }

  /// Read the deployment's model catalog: the default selection, the routable
  /// provider ids, provider-grouped models, and isolated provider failures.
  ///
  /// 0.1.2's `session/modelCatalog` takes no arguments (the catalog is
  /// deployment-wide, not per-session); the 0.1.1 per-session form is gone.
  Future<SessionModels> models() async {
    final result = await _client.callUnary('session/modelCatalog', const {}, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('session/modelCatalog', result.error);
      case RpcResultOk(:final value):
        return SessionModels.fromJson(value is Map ? Map<String, Object?>.from(value) : const {});
    }
  }

  /// Select the complete model selection for this session.
  Future<void> selectModel({
    required String sessionId,
    required String provider,
    required String model,
    String? reasoningEffort,
  }) async {
    final result = await _client.callUnary('session/selectModel', {
      'request': <String, Object?>{
        'sessionId': sessionId,
        'provider': provider,
        'model': model,
        if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
      },
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('session.selectModel', result.error);
      case RpcResultOk():
        return;
    }
  }

  /// Search the current message surface across visible sessions.
  Future<SessionSearchResult> search(String query) async {
    final result = await _client.callUnary('session/search', {
      'request': <String, Object?>{'query': query},
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('session.search', result.error);
      case RpcResultOk(:final value):
        final map = value is Map ? value : const <String, Object?>{};
        final raw = map['items'];
        final items = raw is List
            ? raw.whereType<Map>().map((item) => SessionSearchItem.fromJson(Map<String, Object?>.from(item))).toList()
            : const <SessionSearchItem>[];
        return SessionSearchResult(items: items, hasMore: map['hasMore'] == true);
    }
  }
}

/// Session model catalog: the deployment default selection, routable provider
/// ids, provider-grouped models, and isolated provider failures.
class SessionModels {
  const SessionModels({
    required this.defaultSelection,
    required this.routableProviders,
    required this.groups,
    required this.failures,
  });

  /// The deployment's default `{provider, model, reasoningEffort?}` (the wire
  /// field is `default`, a Dart keyword, hence the rename).
  final Map<String, Object?> defaultSelection;

  /// Provider ids able to serve a request (includes empty catalogs).
  final List<String> routableProviders;
  final List<ModelProviderGroup> groups;
  final List<Map<String, Object?>> failures;

  factory SessionModels.fromJson(Map<String, Object?> json) {
    final rawGroups = json['groups'];
    final groups = rawGroups is List
        ? rawGroups.whereType<Map>().map((g) => ModelProviderGroup.fromJson(Map<String, Object?>.from(g))).toList()
        : const <ModelProviderGroup>[];
    final rawFailures = json['failures'];
    final failures = rawFailures is List
        ? rawFailures.whereType<Map>().map((f) => Map<String, Object?>.from(f)).toList()
        : const <Map<String, Object?>>[];
    final rawRoutable = json['routableProviders'];
    return SessionModels(
      defaultSelection: json['default'] is Map ? Map<String, Object?>.from(json['default']! as Map) : const {},
      routableProviders: rawRoutable is List ? rawRoutable.whereType<String>().toList() : const [],
      groups: groups,
      failures: failures,
    );
  }
}

/// One session-content search result.
class SessionSearchItem {
  const SessionSearchItem({required this.sessionId, required this.snippet});

  final String sessionId;
  final String snippet;

  factory SessionSearchItem.fromJson(Map<String, Object?> json) => SessionSearchItem(
        sessionId: json['sessionId'] as String? ?? '',
        snippet: json['snippet'] as String? ?? '',
      );
}

/// Result of `session.search`: at most 20 sessions, `hasMore` asks to refine.
class SessionSearchResult {
  const SessionSearchResult({required this.items, required this.hasMore});

  final List<SessionSearchItem> items;
  final bool hasMore;
}

/// Compact relative time for a session row, mirroring the web client's
/// `relativeTime`: a bucket plus magnitude ("now", "5min", "3h", "2d", "4mo",
/// "1y"). A future timestamp clamps to "now".
({String unit, int n}) relativeTime(int updatedAt, int now) {
  const min = 60 * 1000;
  const hour = 60 * min;
  const day = 24 * hour;
  final diff = now > updatedAt ? now - updatedAt : 0;
  if (diff < min) return (unit: 'now', n: 0);
  if (diff < hour) return (unit: 'minutes', n: diff ~/ min);
  if (diff < day) return (unit: 'hours', n: diff ~/ hour);
  if (diff < 30 * day) return (unit: 'days', n: diff ~/ day);
  if (diff < 365 * day) return (unit: 'months', n: diff ~/ (30 * day));
  return (unit: 'years', n: diff ~/ (365 * day));
}

/// Decode a JSON string into a map when the payload is JSON text.
Map<String, Object?>? decodeObjectOrNull(Object? value) {
  if (value is Map) return Map<String, Object?>.from(value);
  if (value is String) {
    final decoded = jsonDecode(value);
    if (decoded is Map) return Map<String, Object?>.from(decoded);
  }
  return null;
}
