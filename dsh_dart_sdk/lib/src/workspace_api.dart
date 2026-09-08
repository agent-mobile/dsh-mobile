/// Workspace-domain API.
///
/// Mirrors the TypeScript `workspace.ts` contract: workspaces own an ordered
/// session account over a canonical directory path. The phone has no native
/// picker for the host filesystem, so directory entry uses the browse
/// capability (`host.listDirectory`) rather than a native dialog.
library;

import 'transport.dart';
import 'wire.dart';

/// One workspace row (the record projection every `workspace.*` value carries).
class WorkspaceView {
  const WorkspaceView({
    required this.workspaceId,
    required this.path,
    required this.title,
    required this.sessionIds,
    required this.createdAt,
    required this.updatedAt,
  });

  final String workspaceId;
  final String path;
  final String title;
  final List<String> sessionIds;
  final String createdAt;
  final String updatedAt;

  factory WorkspaceView.fromJson(Map<String, Object?> json) => WorkspaceView(
        workspaceId: json['workspaceId'] as String? ?? '',
        path: json['path'] as String? ?? '',
        title: json['title'] as String? ?? '',
        sessionIds: json['sessionIds'] is List
            ? List<String>.from(json['sessionIds']! as List)
            : const [],
        createdAt: json['createdAt'] as String? ?? '',
        updatedAt: json['updatedAt'] as String? ?? '',
      );
}

/// Workspace-domain methods.
class DshWorkspaceApi {
  DshWorkspaceApi(this._client);

  final DshApiClient _client;

  /// List workspaces in registry order plus the archive set.
  ///
  /// 0.1.2 has no unary `workspace/list`: the baseline rides the
  /// `workspace/follow` stream, whose first frame is
  /// `{type:'baseline', value:{items, archivedSessionIds}}`. This opens the
  /// stream, takes the baseline, and closes it — the App pulls, it does not
  /// hold a live generation open.
  Future<WorkspaceList> list() async {
    final stream = await _client.openLogicalStream('workspace/follow', const {
      'args': <String, Object?>{},
    });
    try {
      final first = await stream.items.first;
      final map = first is Map ? Map<String, Object?>.from(first) : const <String, Object?>{};
      if (map['type'] != 'baseline') {
        throw const FormatException('workspace/follow opened without a baseline frame');
      }
      final value = map['value'];
      final baseline = value is Map ? Map<String, Object?>.from(value) : const <String, Object?>{};
      final rawItems = baseline['items'];
      final items = rawItems is List
          ? rawItems.whereType<Map>().map((w) => WorkspaceView.fromJson(Map<String, Object?>.from(w))).toList()
          : const <WorkspaceView>[];
      final rawArchived = baseline['archivedSessionIds'];
      final archived = rawArchived is List ? List<String>.from(rawArchived) : const <String>[];
      return WorkspaceList(items: items, archivedSessionIds: archived);
    } finally {
      await stream.close();
    }
  }

  /// Create (or idempotently resolve) a workspace over an EXISTING directory.
  Future<WorkspaceCreateResult> create({required String path}) async {
    final result = await _client.callUnary('workspace/create', {
      'request': <String, Object?>{'path': path},
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('workspace/create', result.error);
      case RpcResultOk(:final value):
        final map = value is Map ? Map<String, Object?>.from(value) : const {};
        final workspace = map['workspace'];
        return WorkspaceCreateResult(
          workspace: WorkspaceView.fromJson(workspace is Map ? Map<String, Object?>.from(workspace) : const {}),
          created: map['created'] == true,
        );
    }
  }

  /// Rename a workspace.
  Future<WorkspaceView> rename({required String workspaceId, required String title}) async {
    final result = await _client.callUnary('workspace/rename', {
      'request': <String, Object?>{'workspaceId': workspaceId, 'title': title},
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('workspace/rename', result.error);
      case RpcResultOk(:final value):
        return WorkspaceView.fromJson(value is Map ? Map<String, Object?>.from(value) : const {});
    }
  }

  /// Remove a Workspace registration (directory and logs preserved).
  Future<void> delete({required String workspaceId}) async {
    final result = await _client.callUnary('workspace/delete', {
      'request': <String, Object?>{'workspaceId': workspaceId},
    }, (value) => value);
    if (result is RpcResultErr) throw RpcDomainException('workspace/delete', result.error);
  }

  /// Browse one directory level for workspace-path entry (browse capability).
  Future<DirectoryListing> listDirectory({String? path}) async {
    final result = await _client.callUnary('directoryPicker/list', {
      if (path != null) 'path': path,
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('directoryPicker/list', result.error);
      case RpcResultOk(:final value):
        return DirectoryListing.fromJson(value is Map ? Map<String, Object?>.from(value) : const {});
    }
  }

  /// Create one child directory under an existing parent (browse capability).
  Future<String> createDirectory({required String path, required String name}) async {
    final result = await _client.callUnary('directoryPicker/createDirectory', {
      'path': path,
      'name': name,
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('directoryPicker/createDirectory', result.error);
      case RpcResultOk(:final value):
        final map = value is Map ? Map<String, Object?>.from(value) : const {};
        return map['path'] as String? ?? '';
    }
  }

  /// Archive one session: hidden from grouping surfaces, log preserved.
  Future<List<String>> archiveSession({required String sessionId}) async {
    final result = await _client.callUnary('workspace/archiveSession', {
      'request': <String, Object?>{'sessionId': sessionId},
    }, (value) => value);
    switch (result) {
      case RpcResultErr():
        throw RpcDomainException('workspace/archiveSession', result.error);
      case RpcResultOk(:final value):
        final map = value is Map ? Map<String, Object?>.from(value) : const {};
        final raw = map['archivedSessionIds'];
        return raw is List ? List<String>.from(raw) : const [];
    }
  }
}

/// Result of `workspace.list`.
class WorkspaceList {
  const WorkspaceList({required this.items, required this.archivedSessionIds});

  final List<WorkspaceView> items;
  final List<String> archivedSessionIds;
}

/// Result of `workspace.create`.
class WorkspaceCreateResult {
  const WorkspaceCreateResult({required this.workspace, required this.created});

  final WorkspaceView workspace;
  final bool created;
}

/// One directory level plus breadcrumbs from `host.listDirectory`.
class DirectoryListing {
  const DirectoryListing({
    required this.path,
    required this.home,
    required this.crumbs,
    required this.entries,
    required this.truncated,
  });

  final String path;
  final String home;
  final List<DirectoryEntry> crumbs;
  final List<DirectoryEntry> entries;
  final bool truncated;

  factory DirectoryListing.fromJson(Map<String, Object?> json) {
    List<DirectoryEntry> parseList(Object? raw) => raw is List
        ? raw.whereType<Map>().map((e) => DirectoryEntry.fromJson(Map<String, Object?>.from(e))).toList()
        : const <DirectoryEntry>[];
    return DirectoryListing(
      path: json['path'] as String? ?? '',
      home: json['home'] as String? ?? '',
      crumbs: parseList(json['crumbs']),
      entries: parseList(json['entries']),
      truncated: json['truncated'] == true,
    );
  }
}

/// One directory row: child or breadcrumb ancestor.
class DirectoryEntry {
  const DirectoryEntry({required this.name, required this.path, required this.hidden});

  final String name;
  final String path;
  final bool hidden;

  factory DirectoryEntry.fromJson(Map<String, Object?> json) => DirectoryEntry(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        hidden: json['hidden'] == true,
      );
}
