/// Goal, subagent, and background-job domain APIs.
///
/// Mirrors the TypeScript `goals.ts`, `subagents.ts`, and the jobs contract.
/// Goals are mutations only: the read side is the `goal` session projection
/// (history tail-page block + `session/projection` frames). Subagents read
/// transcripts without activating an Agent. Jobs arrive as `session/jobs`
/// whole snapshots.
library;

import 'transport.dart';
import 'wire.dart';

/// Compare-and-set identity for one exact goal revision.
class GoalRef {
  const GoalRef({required this.id, required this.revision});

  final String id;
  final int revision;

  factory GoalRef.fromJson(Map<String, Object?> json) => GoalRef(
        id: json['id'] as String? ?? '',
        revision: (json['revision'] as num?)?.toInt() ?? 0,
      );
}

/// Goal-domain mutations.
class DshGoalApi {
  DshGoalApi(this._client);

  final DshApiClient _client;

  Future<GoalRef> _mutate(String method, Map<String, Object?> payload) async {
    final result = await _client.callUnary(method, payload, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException(method, result.error);
      case RpcResultOk(:final value):
        // The host answers `{ref: {id, revision}}` (the tombstone ref for
        // clear); decode the nested ref, not the envelope.
        final map = value is Map ? value : const <String, Object?>{};
        final ref = map['ref'];
        if (ref is! Map) throw FormatException('$method lacked a ref');
        return GoalRef.fromJson(Map<String, Object?>.from(ref));
    }
  }

  // 0.1.2 wire shapes (verified against the live host's strict descriptors):
  // every goals mutation names the scoped agent identity as `agentId` (the
  // session id) and carries the GoalRef under `ref` and the edit fields under
  // `request` — `{agentId, ref, request}`, never flat fields.

  Future<GoalRef> create({required String agentId, required String objective, int? maxGoalRounds}) =>
      _mutate('goals/create', {
        'agentId': agentId,
        'request': <String, Object?>{
          'objective': objective,
          if (maxGoalRounds != null) 'maxGoalRounds': maxGoalRounds,
        },
      });

  Future<GoalRef> edit({
    required String agentId,
    required GoalRef ref,
    String? objective,
    int? maxGoalRounds,
  }) =>
      _mutate('goals/edit', {
        'agentId': agentId,
        'ref': {'id': ref.id, 'revision': ref.revision},
        'request': <String, Object?>{
          if (objective != null) 'objective': objective,
          if (maxGoalRounds != null) 'maxGoalRounds': maxGoalRounds,
        },
      });

  Future<GoalRef> pause({required String agentId, required GoalRef ref}) => _mutate(
      'goals/pause',
      {'agentId': agentId, 'ref': {'id': ref.id, 'revision': ref.revision}},
    );

  Future<GoalRef> resume({required String agentId, required GoalRef ref}) => _mutate(
      'goals/resume',
      {'agentId': agentId, 'ref': {'id': ref.id, 'revision': ref.revision}},
    );

  Future<GoalRef> complete({required String agentId, required GoalRef ref}) => _mutate(
      'goals/complete',
      {'agentId': agentId, 'ref': {'id': ref.id, 'revision': ref.revision}},
    );

  Future<void> clear({required String agentId, required GoalRef ref}) async {
    final result = await _client.callUnary('goals/clear', {
      'agentId': agentId,
      'ref': {'id': ref.id, 'revision': ref.revision},
    }, (value) => value);
    if (result is RpcResultErr) throw RpcDomainException('goals/clear', result.error);
  }
}

/// Complete durable direct-child catalog row.
class SubagentListEntry {
  const SubagentListEntry({
    required this.kind,
    required this.id,
    this.activity,
    this.hasChildren,
    this.mode,
    this.label,
    this.reason,
  });

  final String kind;

  /// `child` rows carry a session id.
  final String id;

  /// `running`/`inactive` for children.
  final String? activity;
  final bool? hasChildren;
  final String? mode;
  final String? label;

  /// `corrupt`/`unsupported`/`unavailable` for diagnostics.
  final String? reason;

  factory SubagentListEntry.fromJson(Map<String, Object?> json) => SubagentListEntry(
        kind: json['kind'] as String? ?? 'child',
        id: json['id'] as String? ?? '',
        activity: json['activity'] as String?,
        hasChildren: json['hasChildren'] as bool?,
        mode: json['mode'] as String?,
        label: json['label'] as String?,
        reason: json['reason'] as String?,
      );
}

/// A parent/child address selecting subagent transport.
class SubagentAddress {
  const SubagentAddress({required this.parentSessionId, required this.childSessionId});

  final String parentSessionId;
  final String childSessionId;
}

/// Subagent-domain methods.
class DshSubagentApi {
  DshSubagentApi(this._client);

  final DshApiClient _client;

  /// List direct children of one parent (no Agent activation).
  Future<SubagentCatalog> list({required String parentSessionId}) async {
    final result = await _client.callUnary('subagents/list', {'parentSessionId': parentSessionId}, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('subagents/list', result.error);
      case RpcResultOk(:final value):
        final map = value is Map ? value : const <String, Object?>{};
        final raw = map['entries'];
        final entries = raw is List
            ? raw.whereType<Map>().map((e) => SubagentListEntry.fromJson(Map<String, Object?>.from(e))).toList()
            : const <SubagentListEntry>[];
        return SubagentCatalog(
          entries: entries,
          parentAvailable: map['parentAvailable'] == true,
        );
    }
  }

  /// Send a follow-up to a continuable child.
  Future<String> prompt({
    required SubagentAddress address,
    required List<Map<String, Object?>> content,
  }) async {
    final result = await _client.callUnary('subagents/prompt', {
      'request': <String, Object?>{
        // 0.1.2 requires a client-minted requestId for prompt correlation.
        'requestId': mintRpcId(),
        'parentSessionId': address.parentSessionId,
        'childSessionId': address.childSessionId,
        'mode': 'continuable',
        'content': content,
      },
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('subagents/prompt', result.error);
      case RpcResultOk(:final value):
        final map = value is Map ? value : const <String, Object?>{};
        return map['messageId'] as String? ?? '';
    }
  }

  /// Interrupt a live continuable child's current turn.
  Future<void> interrupt({required SubagentAddress address}) async {
    final result = await _client.callUnary('subagents/interruptByParent', {
      'childSessionId': address.childSessionId,
      'parentSessionId': address.parentSessionId,
      'mode': 'continuable',
    }, (value) => value);
    if (result is RpcResultErr) throw RpcDomainException('subagents/interruptByParent', result.error);
  }
}

/// Complete direct-child catalog plus parent availability hint.
class SubagentCatalog {
  const SubagentCatalog({required this.entries, required this.parentAvailable});

  final List<SubagentListEntry> entries;
  final bool parentAvailable;
}

/// One background job as the client sees it (`session/jobs` frame entry).
class JobView {
  const JobView({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    required this.startedAt,
    this.detail,
    this.finishedAt,
  });

  final String id;
  final String kind;
  final String label;

  /// `running`/`stopping`/`completed`/`killed`/`failed`.
  final String status;
  final String? detail;
  final int startedAt;
  final int? finishedAt;

  factory JobView.fromJson(Map<String, Object?> json) => JobView(
        id: json['id'] as String? ?? '',
        kind: json['kind'] as String? ?? '',
        label: json['label'] as String? ?? '',
        status: json['status'] as String? ?? 'running',
        detail: json['detail'] as String?,
        startedAt: (json['startedAt'] as num?)?.toInt() ?? 0,
        finishedAt: (json['finishedAt'] as num?)?.toInt(),
      );
}
