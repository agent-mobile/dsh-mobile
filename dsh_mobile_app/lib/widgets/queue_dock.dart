/// Queue dock: renders the pending inbox queue and addresses per-row edits,
/// removal, and steer through `session.updateQueue`. Mirrors web's QueueDock.
library;

import 'package:flutter/material.dart';

import '../state/connection_controller.dart';

/// Pending queued item text extracted from the wire `message` (web's
/// QueuedInboxItem.message.content text blocks).
String _messageText(Map<String, Object?> item) {
  final message = item['message'];
  if (message is! Map) return '';
  final content = message['content'];
  if (content is! List) return '';
  final buffer = StringBuffer();
  for (final block in content) {
    if (block is Map && block['type'] == 'text' && block['text'] is String) {
      buffer.write(block['text']);
    }
  }
  return buffer.toString();
}

/// Collapsible queue strip; empty renders nothing.
class QueueDock extends StatefulWidget {
  const QueueDock({super.key, required this.connection, required this.sessionId});

  final ConnectionController connection;
  final String sessionId;

  @override
  State<QueueDock> createState() => _QueueDockState();
}

class _QueueDockState extends State<QueueDock> {
  bool _collapsed = true;

  Future<void> _mutate(String itemId, Map<String, Object?> action) async {
    try {
      await widget.connection.sessions.updateQueue(
        sessionId: widget.sessionId,
        itemId: itemId,
        action: action,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('排队消息更新失败：$error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.connection.queue(widget.sessionId)
        .where((item) => item['placement'] == 'queued')
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();

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
                  const Icon(Icons.outbox, size: 14),
                  const SizedBox(width: 6),
                  Text(
                    items.length == 1 ? '1 条排队消息' : '${items.length} 条排队消息',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Icon(_collapsed ? Icons.expand_more : Icons.expand_less, size: 16),
                ],
              ),
            ),
          ),
          if (!_collapsed)
            for (final item in items)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                title: Text(
                  _messageText(item),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.send, size: 16),
                      tooltip: '插话发送',
                      onPressed: () => _mutate(
                        item['id'] as String? ?? '',
                        {'kind': 'steer'},
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 16),
                      tooltip: '删除排队消息',
                      onPressed: () => _mutate(
                        item['id'] as String? ?? '',
                        {'kind': 'remove'},
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
