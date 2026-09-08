/// Todo strip above the composer, mirroring web's TodoPanel: a collapsible
/// list of the session's `todos` projection with per-status counts.
library;

import 'package:flutter/material.dart';

/// One todo item from the `todos` projection (web TodoItem shape).
class TodoItem {
  const TodoItem({required this.content, required this.status});

  final String content;

  /// `completed` / `in_progress` / `pending`.
  final String status;
}

/// Renders the todo projection as a collapsible strip; empty renders nothing.
class TodoPanel extends StatefulWidget {
  const TodoPanel({super.key, required this.todos});

  /// The session's current whole todo list (`todos` projection value).
  final List<Object?> todos;

  @override
  State<TodoPanel> createState() => _TodoPanelState();
}

class _TodoPanelState extends State<TodoPanel> {
  bool _collapsed = true;

  @override
  Widget build(BuildContext context) {
    final items = widget.todos
        .whereType<Map>()
        .map((raw) => TodoItem(
              content: raw['content'] is String ? raw['content'] as String : '',
              status: raw['status'] is String ? raw['status'] as String : 'pending',
            ))
        .where((item) => item.content.isNotEmpty)
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();

    final done = items.where((i) => i.status == 'completed').length;
    final active = items.where((i) => i.status == 'in_progress').length;
    final pending = items.length - done - active;
    final counts = <String>[
      if (done > 0) '$done 已完成',
      if (active > 0) '$active 进行中',
      if (pending > 0) '$pending 待处理',
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _collapsed = !_collapsed),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.checklist, size: 14),
                  const SizedBox(width: 6),
                  const Text('任务', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      counts,
                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
                    ),
                  ),
                  Icon(_collapsed ? Icons.expand_more : Icons.expand_less, size: 16),
                ],
              ),
            ),
          ),
          if (!_collapsed)
            for (final item in items)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _StatusGlyph(status: item.status),
                    const SizedBox(width: 8),
                    Expanded(child: Text(item.content, style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

/// Status glyph mirroring web's TodoPanel StatusGlyph: circle (completed),
/// ring (in_progress), dashed ring (pending).
class _StatusGlyph extends StatelessWidget {
  const _StatusGlyph({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: SizedBox(
        width: 14,
        height: 14,
        child: switch (status) {
          'completed' => Icon(Icons.check_circle, size: 14, color: scheme.primary),
          'in_progress' => Icon(Icons.circle_outlined, size: 14, color: scheme.primary),
          _ => Icon(Icons.radio_button_unchecked, size: 14, color: scheme.outline),
        },
      ),
    );
  }
}
