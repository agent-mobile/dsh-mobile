/// Home screen: a narrow icon rail (web's collapsed 56 px rail: open sidebar /
/// new session / add workspace / search / settings) plus a center welcome pane.
/// The workspace-grouped session browser lives in a drawer — hidden by default
/// and opened from the rail's "打开侧边栏" button — mirroring the web
/// narrow-state sidebar overlay. Drawer groups mirror the web sidebar's
/// WorkspaceBrowser: folder groups per workspace, an "未分组" bucket for loose
/// sessions, status dots, relative time, and New Session placeholders.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../state/connection_controller.dart';
import '../state/theme_controller.dart';
import '../state/voice_mode_controller.dart';
import '../theme.dart';
import '../widgets/directory_picker.dart';
import 'chat_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

/// Ungrouped bucket label (mirrors web's `group.ungrouped`).
const _ungroupedLabel = '未分组';

/// Drawer header title (the same label as the rail's "打开侧边栏" tooltip).
const _drawerTitle = '打开会话列表';

/// Visible sessions per group before the overflow control.
const _collapsedSessionLimit = 5;

/// One derived session row (mirrors web's SessionNode).
class _SessionRow {
  _SessionRow({
    required this.id,
    required this.title,
    required this.blank,
    required this.running,
    required this.updatedAt,
    this.waitingApproval = false,
  });

  final String id;
  final String title;
  final bool blank;
  final bool running;
  final int updatedAt;

  /// Whether a tool approval is pending for this session (web's amber dot).
  final bool waitingApproval;
}

/// One workspace group section (mirrors web's GroupNode).
class _SessionGroup {
  _SessionGroup({
    required this.key,
    required this.label,
    required this.sessionCount,
    required this.containsCurrent,
    required this.sessions,
  });

  final String key;
  final String label;
  final int sessionCount;
  final bool containsCurrent;
  final List<_SessionRow> sessions;
}

/// Lists sessions grouped by workspace, supports New Session, and navigates
/// into a chat.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.connection,
    required this.themeController,
    required this.voiceModeController,
  });

  final ConnectionController connection;

  /// App appearance preference; the 通用 外观 row writes through it.
  final ThemeController themeController;

  /// Global voice/text mode preference.
  final VoiceModeController voiceModeController;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<SessionSummary> _sessions = [];
  bool _loading = true;
  String? _error;

  /// Currently selected session (drives blank-session visibility + the
  /// "New Session" provisional row, mirroring web's list.current).
  String? _currentSessionId;

  /// Overflow-expanded session groups (key → show all rows instead of the
  /// first `_collapsedSessionLimit`); toggled by the overflow control.
  final Set<String> _overflowExpandedGroups = {};

  /// Manual group-level open/close pins (key → open). A pinned group is exempt
  /// from the automatic open-group rule until the app restarts.
  final Map<String, bool> _groupOpenOverrides = {};

  @override
  void initState() {
    super.initState();
    _refresh();
    widget.connection.addListener(_onConnectionChanged);
  }

  @override
  void dispose() {
    widget.connection.removeListener(_onConnectionChanged);
    super.dispose();
  }

  void _onConnectionChanged() {
    if (!mounted) return;
    // Pick up sessions refreshed by the controller's structural refresh (host
    // frames for session-added/workspace-changed); fall back to a manual
    // refresh when the controller has not populated the list yet.
    final structural = widget.connection.structuralSessionList;
    if (structural.isNotEmpty) {
      _sessions = structural;
    } else if (!_loading && _sessions.isEmpty) {
      _refresh();
    }
    // A notification can arrive while a frame is being built (a pushed chat's
    // mount boots a history load that notifies synchronously). Defer the
    // rebuild past the frame; HomeScreen is not an ancestor of that build.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  Future<void> _refresh() async {
    try {
      final sessions = await widget.connection.sessions.list();
      await widget.connection.refreshWorkspaces();
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  /// Manual reconnect after a disconnect; failures surface in a SnackBar and
  /// the status indicator keeps showing `disconnected`.
  Future<void> _reconnect() async {
    try {
      await widget.connection.reconnect();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('重连失败：$error')));
      }
    }
  }

  /// Mirror web's sessionVisible: subagent children and archived sessions are
  /// hidden; blank sessions show only as the selected provisional row.
  bool _visible(SessionSummary s) =>
      s.origin != 'subagent' &&
      !widget.connection.archivedSessionIds.contains(s.sessionId) &&
      (!s.blank || s.sessionId == _currentSessionId);

  /// Build the workspace-grouped tree (mirrors web's deriveGroups).
  List<_SessionGroup> _groups() {
    final groups = <_SessionGroup>[];
    final accounted = <String>{};

    for (final workspace in widget.connection.workspaceItems) {
      final members = <_SessionRow>[];
      for (final id in workspace.sessionIds) {
        final summary = _sessions.where((s) => s.sessionId == id).firstOrNull;
        if (summary == null) continue;
        accounted.add(id);
        if (!_visible(summary)) continue;
        members.add(_rowOf(summary));
      }
      groups.add(
        _SessionGroup(
          key: workspace.workspaceId,
          label: workspace.title,
          sessionCount: members.length,
          containsCurrent: workspace.sessionIds.contains(_currentSessionId),
          sessions: members,
        ),
      );
    }

    final stray = _sessions
        .where((s) => !accounted.contains(s.sessionId) && _visible(s))
        .toList();
    if (stray.isNotEmpty) {
      stray.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      groups.add(
        _SessionGroup(
          key: _ungroupedLabel,
          label: _ungroupedLabel,
          sessionCount: stray.length,
          containsCurrent: !groups.any((g) => g.containsCurrent),
          sessions: stray.map(_rowOf).toList(),
        ),
      );
    }
    return groups;
  }

  _SessionRow _rowOf(SessionSummary s) => _SessionRow(
    id: s.sessionId,
    title: s.blank ? 'New Session' : s.displayTitle,
    blank: s.blank,
    // Live running gate first (host/session-status frames), the list
    // snapshot as the fallback: the dot must follow a turn that finishes
    // after the last session.list refresh.
    running: widget.connection.running(s.sessionId) ?? s.running,
    updatedAt: s.updatedAt,
    waitingApproval: widget.connection.approvals(s.sessionId).isNotEmpty,
  );

  /// The single group opened by the automatic rule, in priority order: a group
  /// with a running session, else the current session's group, else the group
  /// of the most recently updated visible session. Null when none applies
  /// (every group then shows its folder header only).
  String? _autoOpenGroupKey(List<_SessionGroup> groups) {
    for (final group in groups) {
      if (group.sessions.any((s) => s.running)) return group.key;
    }
    final currentId = _currentSessionId;
    if (currentId != null) {
      for (final group in groups) {
        if (group.sessions.any((s) => s.id == currentId)) return group.key;
      }
    }
    String? lastGroupKey;
    var lastUpdatedAt = -1;
    for (final group in groups) {
      for (final session in group.sessions) {
        if (session.updatedAt > lastUpdatedAt) {
          lastUpdatedAt = session.updatedAt;
          lastGroupKey = group.key;
        }
      }
    }
    return lastGroupKey;
  }

  /// Global New Session entry (rail, drawer header, welcome pane): create in
  /// the current session's workspace, else the recent workspace (mirror web's
  /// startSession), else ungrouped when no workspace exists.
  Future<void> _newSession() async {
    await _createSession(_resolveTargetWorkspaceId());
  }

  /// Group-scoped New Session: create in [workspaceId]; a null target (the
  /// ungrouped bucket's add button) creates an ungrouped session.
  Future<void> _newSessionForWorkspace(String? workspaceId) async {
    await _createSession(workspaceId);
  }

  /// Shared create + refresh + open tail for both New Session entry points.
  Future<void> _createSession(String? workspaceId) async {
    try {
      final id = await widget.connection.sessions.create(
        workspaceId: workspaceId,
      );
      if (!mounted) return;
      _currentSessionId = id;
      await _refresh();
      _openChat(id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('新建会话失败：$error')));
    }
  }

  /// Target workspace for a global New Session: the current session's
  /// workspace, else the most recently active workspace (highest max-updatedAt
  /// across its accounted sessions, host order breaks ties; a workspace with
  /// no sessions anchors at its creation time), else null (create ungrouped).
  String? _resolveTargetWorkspaceId() {
    final currentId = _currentSessionId;
    if (currentId != null) {
      final workspace = widget.connection.workspaceItems
          .where((w) => w.sessionIds.contains(currentId))
          .firstOrNull;
      if (workspace != null) return workspace.workspaceId;
    }
    String? recent;
    var bestTime = -1;
    for (final workspace in widget.connection.workspaceItems) {
      var latest = -1;
      for (final id in workspace.sessionIds) {
        final summary = _sessions.where((s) => s.sessionId == id).firstOrNull;
        if (summary != null && summary.updatedAt > latest) {
          latest = summary.updatedAt;
        }
      }
      if (latest == -1) {
        latest =
            DateTime.tryParse(workspace.createdAt)?.millisecondsSinceEpoch ??
            -1;
      }
      if (bestTime == -1 || latest > bestTime) {
        bestTime = latest;
        recent = workspace.workspaceId;
      }
    }
    return recent;
  }

  /// Add a workspace by picking a host directory (web rail's "添加工作区").
  Future<void> _addWorkspace() async {
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => DirectoryPickerScreen(connection: widget.connection),
      ),
    );
    if (picked == null) return;
    try {
      await widget.connection.workspaces.create(path: picked);
      await _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('创建工作区失败：$error')));
      }
    }
  }

  void _openChat(String sessionId) {
    setState(() => _currentSessionId = sessionId);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(
          connection: widget.connection,
          sessionId: sessionId,
          voiceModeController: widget.voiceModeController,
        ),
      ),
    );
  }

  Future<void> _renameWorkspace(String workspaceId) async {
    final current = widget.connection.workspaceItems
        .where((w) => w.workspaceId == workspaceId)
        .map((w) => w.title)
        .firstOrNull;
    final controller = TextEditingController(text: current ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名工作区'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('重命名'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await widget.connection.workspaces.rename(
        workspaceId: workspaceId,
        title: name.trim(),
      );
      await _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('重命名失败：$error')));
      }
    }
  }

  Future<void> _deleteWorkspace(String workspaceId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除工作区？'),
        content: const Text('文件夹与会话记录会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.connection.workspaces.delete(workspaceId: workspaceId);
      await _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('删除失败：$error')));
      }
    }
  }

  /// Handle a session-row menu action: rename, fork, or archive.
  Future<void> _sessionAction(String sessionId, String action) async {
    switch (action) {
      case 'rename':
        final current = _sessions
            .where((s) => s.sessionId == sessionId)
            .map((s) => s.displayTitle)
            .firstOrNull;
        final controller = TextEditingController(text: current ?? '');
        final name = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('重命名会话'),
            content: TextField(
              controller: controller,
              autofocus: true,
              onSubmitted: (value) => Navigator.of(context).pop(value),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(controller.text),
                child: const Text('重命名'),
              ),
            ],
          ),
        );
        if (name == null || name.trim().isEmpty) return;
        try {
          await widget.connection.sessions.rename(
            sessionId: sessionId,
            title: name.trim(),
          );
          await _refresh();
        } catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('重命名失败：$error')));
          }
        }
      case 'fork':
        try {
          final childId = await widget.connection.sessions.fork(
            sessionId: sessionId,
          );
          if (!mounted) return;
          await _refresh();
          _openChat(childId);
        } catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('分叉会话失败：$error')));
          }
        }
      case 'archive':
        try {
          await widget.connection.workspaces.archiveSession(
            sessionId: sessionId,
          );
          await widget.connection.refreshWorkspaces();
          await _refresh();
        } catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('归档失败：$error')));
          }
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: widget.connection,
          builder: (context, _) => Row(
            children: [
              const Flexible(
                child: Text('Harness App', overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 10),
              _ConnectionIndicator(
                status: widget.connection.status,
                onReconnect: _reconnect,
              ),
            ],
          ),
        ),
        leading: ListenableBuilder(
          listenable: widget.voiceModeController,
          builder: (context, _) => IconButton(
            icon: Icon(
              widget.voiceModeController.isVoice
                  ? Icons.mic
                  : Icons.chat_bubble_outline,
              color: widget.voiceModeController.isVoice
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            tooltip: widget.voiceModeController.isVoice ? '语音模式（点击切回文字）' : '文字模式（点击切换语音）',
            onPressed: () => widget.voiceModeController.toggle(),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
            tooltip: '刷新',
          ),
        ],
      ),
      // Session list lives in the drawer: hidden by default, opened from the
      // rail's "打开侧边栏" button (web narrow-state sidebar overlay).
      drawer: _buildDrawer(),
      body: Builder(
        builder: (context) => Row(
          children: [
            // Narrow icon rail (web's collapsed 56 px rail): open sidebar /
            // new session / add workspace / search / settings.
            _NavRail(
              onOpenSessions: () => Scaffold.of(context).openDrawer(),
              onNewSession: _newSession,
              onAddWorkspace: _addWorkspace,
              onSearch: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SearchScreen(
                    connection: widget.connection,
                    voiceModeController: widget.voiceModeController,
                  ),
                ),
              ),
              onSettings: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsScreen(
                    connection: widget.connection,
                    themeController: widget.themeController,
                  ),
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _WelcomePane(onNewSession: _newSession)),
          ],
        ),
      ),
    );
  }

  /// Drawer content: a fixed header title over the workspace-grouped session
  /// browser (web sidebar). The header stays put across loading/error/empty
  /// and the scrollable group list.
  Widget _buildDrawer() {
    final groups = _loading ? const <_SessionGroup>[] : _groups();
    final autoOpenKey = _autoOpenGroupKey(groups);
    return Drawer(
      width: 280,
      child: SafeArea(
        child: Column(
          children: [
            _DrawerHeader(title: _drawerTitle, onNewSession: _newSession),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline, size: 48),
                            const SizedBox(height: 12),
                            Text(_error!, textAlign: TextAlign.center),
                          ],
                        ),
                      ),
                    )
                  : groups.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.chat_bubble_outline,
                              size: 48,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '还没有会话',
                              style: TextStyle(
                                fontSize: 16,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '点击下方按钮，开始第一段对话',
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 20),
                            FilledButton.icon(
                              onPressed: _newSession,
                              icon: const Icon(Icons.add),
                              label: const Text('新建会话'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: groups.length,
                      itemBuilder: (context, groupIndex) {
                        final group = groups[groupIndex];
                        final open =
                            _groupOpenOverrides[group.key] ??
                            group.key == autoOpenKey;
                        return Column(
                          children: [
                            // A hairline between groups keeps collapsed
                            // folder headers visually distinct (theme divider:
                            // 6% white).
                            if (groupIndex > 0) const Divider(height: 1),
                            _GroupSection(
                              group: group,
                              open: open,
                              overflowExpanded: _overflowExpandedGroups
                                  .contains(group.key),
                              currentId: _currentSessionId,
                              onToggleOpen: () => setState(() {
                                _groupOpenOverrides[group.key] = !open;
                              }),
                              onToggleOverflow: () => setState(() {
                                if (!_overflowExpandedGroups.remove(
                                  group.key,
                                )) {
                                  _overflowExpandedGroups.add(group.key);
                                }
                              }),
                              onNewSession: _newSessionForWorkspace,
                              onOpen: _openChat,
                              onRename: group.key == _ungroupedLabel
                                  ? null
                                  : _renameWorkspace,
                              onDelete: group.key == _ungroupedLabel
                                  ? null
                                  : _deleteWorkspace,
                              onSessionAction: _sessionAction,
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fixed drawer header: title + a compact New Session action, with a hairline
/// below separating it from the session browser's states.
class _DrawerHeader extends StatelessWidget {
  const _DrawerHeader({required this.title, required this.onNewSession});

  final String title;
  final VoidCallback onNewSession;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: dswColor(
                      context,
                      dark: DswColors.bluish50,
                      light: DswColors.bluish1000,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                iconSize: 16,
                style: _GroupSection._compactButtonStyle,
                tooltip: '新建会话',
                onPressed: onNewSession,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

/// One workspace group section: header row + (when open) session rows.
class _GroupSection extends StatelessWidget {
  const _GroupSection({
    required this.group,
    required this.open,
    required this.overflowExpanded,
    required this.currentId,
    required this.onToggleOpen,
    required this.onToggleOverflow,
    required this.onNewSession,
    required this.onOpen,
    this.onRename,
    this.onDelete,
    this.onSessionAction,
  });

  final _SessionGroup group;

  /// Group-level visibility: folder header only when false, header + rows when
  /// true (an automatic rule or a manual pin).
  final bool open;

  /// Overflow-level expansion: show all rows instead of the first
  /// `_collapsedSessionLimit` (only meaningful when [open]).
  final bool overflowExpanded;

  final String? currentId;
  final VoidCallback onToggleOpen;
  final VoidCallback onToggleOverflow;

  /// New Session scoped to this group: its workspace id, or null for the
  /// ungrouped bucket.
  final ValueChanged<String?> onNewSession;
  final ValueChanged<String> onOpen;

  /// Real-workspace actions (absent for the Ungrouped bucket).
  final ValueChanged<String>? onRename;
  final ValueChanged<String>? onDelete;

  /// Session-row menu action: `rename` / `fork` / `archive`.
  final void Function(String sessionId, String action)? onSessionAction;

  /// Compact style for the header's secondary buttons: the Material 48 px
  /// minimum tap target would otherwise balloon the 44 px header.
  static final ButtonStyle _compactButtonStyle = IconButton.styleFrom(
    minimumSize: const Size(28, 28),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = overflowExpanded
        ? group.sessions
        : group.sessions.take(_collapsedSessionLimit).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Project (workspace) header row, mirroring web's ProjectRowItem.
        InkWell(
          onTap: onToggleOpen,
          child: Container(
            // A faint tint marks the open/current group without a heavy
            // surface; the divider between groups does the sectioning.
            color: open || group.containsCurrent
                ? scheme.primary.withValues(alpha: 0.05)
                : null,
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
            child: Row(
              children: [
                Icon(
                  open ? Icons.folder_open : Icons.folder,
                  size: 16,
                  color: group.containsCurrent
                      ? scheme.primary
                      : scheme.outline,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    group.label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: group.containsCurrent ? scheme.primary : null,
                    ),
                  ),
                ),
                if (onRename != null && onDelete != null)
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz, size: 16),
                    padding: EdgeInsets.zero,
                    style: _compactButtonStyle,
                    tooltip: '工作区操作',
                    onSelected: (value) {
                      if (value == 'rename') onRename!(group.key);
                      if (value == 'delete') onDelete!(group.key);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                IconButton(
                  icon: const Icon(Icons.add),
                  iconSize: 16,
                  style: _compactButtonStyle,
                  tooltip: '新建会话',
                  onPressed: () => onNewSession(
                    group.key == _ungroupedLabel ? null : group.key,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (open) ...[
          for (final row in visible)
            Dismissible(
              key: ValueKey('session-${row.id}'),
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                color: scheme.primary.withValues(alpha: 0.15),
                child: Icon(Icons.drive_file_rename_outline, color: scheme.primary),
              ),
              secondaryBackground: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 20),
                color: scheme.error.withValues(alpha: 0.15),
                child: Icon(Icons.archive_outlined, color: scheme.error),
              ),
              confirmDismiss: (direction) async {
                if (direction == DismissDirection.startToEnd) {
                  onSessionAction?.call(row.id, 'rename');
                  return false;
                } else {
                  onSessionAction?.call(row.id, 'archive');
                  return false;
                }
              },
              child: _SessionRowTile(
                row: row,
                selected: row.id == currentId,
                onTap: () => onOpen(row.id),
                onAction: (action) => onSessionAction?.call(row.id, action),
              ),
            ),
          if (group.sessions.length > _collapsedSessionLimit)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 0, 8),
              child: TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: onToggleOverflow,
                child: Text(
                  overflowExpanded
                      ? '收起'
                      : '展开其余 ${group.sessions.length - _collapsedSessionLimit} 个会话',
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// One session row, mirroring web's SessionNodeItem: status dot + title +
/// relative time, plus a row menu (Rename/Fork/Archive) for non-blank rows.
class _SessionRowTile extends StatelessWidget {
  const _SessionRowTile({
    required this.row,
    required this.selected,
    required this.onTap,
    this.onAction,
  });

  final _SessionRow row;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<String>? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.only(left: 16, right: 4),
        color: selected ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
        child: Row(
          children: [
            // Status dot: waiting approval → amber (primary), running → green,
            // idle → transparent.
            SizedBox(
              width: 16,
              child: row.waitingApproval
                  ? const Icon(Icons.circle, size: 8, color: Colors.amber)
                  : row.running
                  ? Icon(Icons.circle, size: 8, color: Colors.green)
                  : null,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                row.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            // Relative time, absent for a blank New Session placeholder.
            if (!row.blank)
              Text(
                _timeLabel(
                  row.updatedAt,
                  DateTime.now().millisecondsSinceEpoch,
                ),
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            // Row menu (absent for blank rows — nothing to rename/fork/archive).
            if (!row.blank && onAction != null)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz, size: 16),
                tooltip: '会话操作',
                onSelected: onAction,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('重命名')),
                  PopupMenuItem(value: 'fork', child: Text('分叉会话')),
                  PopupMenuItem(value: 'archive', child: Text('归档会话')),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// Localized compact relative time ("刚刚", "5分钟", "3小时", "2天", "4个月", "1年").
  String _timeLabel(int updatedAt, int now) {
    final t = relativeTime(updatedAt, now);
    return switch (t.unit) {
      'now' => '刚刚',
      'minutes' => '${t.n}分钟',
      'hours' => '${t.n}小时',
      'days' => '${t.n}天',
      'months' => '${t.n}个月',
      _ => '${t.n}年',
    };
  }
}

/// Narrow icon rail (web's collapsed 56 px sidebar rail): open sidebar, new
/// session, add workspace, search, settings — the home's primary navigation.
/// Icons pick a brightness-appropriate rail color (light on the dark rail,
/// dark on the light rail) so they stay visible in both themes.
class _NavRail extends StatelessWidget {
  const _NavRail({
    required this.onOpenSessions,
    required this.onNewSession,
    required this.onAddWorkspace,
    required this.onSearch,
    required this.onSettings,
  });

  final VoidCallback onOpenSessions;
  final VoidCallback onNewSession;
  final VoidCallback onAddWorkspace;
  final VoidCallback onSearch;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      color: dswColor(
        context,
        dark: DswColors.bluish900,
        light: DswColors.bluish50,
      ),
      child: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            _railButton(context, Icons.menu, '打开侧边栏', onOpenSessions),
            _railButton(context, Icons.add, '新建会话', onNewSession),
            _railButton(
              context,
              Icons.create_new_folder_outlined,
              '添加工作区',
              onAddWorkspace,
            ),
            _railButton(context, Icons.search, '搜索会话', onSearch),
            const Spacer(),
            _railButton(context, Icons.settings_outlined, '设置', onSettings),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _railButton(
    BuildContext context,
    IconData icon,
    String tooltip,
    VoidCallback onPressed,
  ) {
    final iconColor = dswColor(
      context,
      dark: DswColors.bluish50,
      light: DswColors.bluish1000,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: IconButton(
        icon: Icon(icon, size: 20, color: iconColor),
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: iconColor,
          highlightColor: dswColor(
            context,
            dark: DswColors.borderL1,
            light: DswColors.lightBorderL1,
          ),
        ),
      ),
    );
  }
}

/// Center welcome pane shown while the session list stays hidden in the
/// drawer (web center-column empty state).
class _WelcomePane extends StatelessWidget {
  const _WelcomePane({required this.onNewSession});

  final VoidCallback onNewSession;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.explore_outlined,
              size: 40,
              color: dswColor(
                context,
                dark: DswColors.deepseek400,
                light: DswColors.deepseek500,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '探索未至之境',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: dswColor(
                  context,
                  dark: DswColors.bluish50,
                  light: DswColors.bluish1000,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '点击左侧的会话列表按钮开始，或新建一个会话。',
              style: TextStyle(
                fontSize: 13,
                color: dswColor(
                  context,
                  dark: DswColors.bluish400,
                  light: DswColors.bluish600,
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onNewSession,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新建会话'),
            ),
          ],
        ),
      ),
    );
  }
}

/// AppBar link-status indicator: colored dot + label, rebuilt by the
/// connection controller's notifications. Tapping while disconnected triggers
/// a manual reconnect.
class _ConnectionIndicator extends StatelessWidget {
  const _ConnectionIndicator({required this.status, required this.onReconnect});

  final ConnectionStatus status;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      ConnectionStatus.connecting => const _StatusPill(
        color: DswColors.amber500,
        label: '连接中',
      ),
      ConnectionStatus.connected => const _StatusPill(
        color: DswColors.green500,
        label: '已连接',
      ),
      ConnectionStatus.disconnected => GestureDetector(
        onTap: onReconnect,
        behavior: HitTestBehavior.opaque,
        child: const _StatusPill(color: DswColors.red400, label: '已断开，点击重连'),
      ),
    };
  }
}

/// One status pill: dot + text on a tinted rounded background.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: dswColor(
                context,
                dark: DswColors.bluish50,
                light: DswColors.bluish1000,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
