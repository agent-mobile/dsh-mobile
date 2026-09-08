/// Tool-call card: one requested tool invocation with its result. Tapping the
/// card opens the detail panel as a modal bottom sheet (web DetailsPanel
/// routed as a sheet on the phone): args as pretty JSON and the output
/// section. Copy mirrors the web locale verbatim.
library;

import 'dart:convert';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:flutter/material.dart';

/// Renders one `tool/call` plus its `tool/result` (a tool call tree leaf).
class ToolCard extends StatelessWidget {
  const ToolCard({super.key, required this.call});

  final AssistantToolCallBlock call;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pending = call.result == null;
    final failed = call.error != null;
    final icon = failed
        ? Icons.error_outline
        : pending
            ? Icons.hourglass_top
            : Icons.check_circle_outline;
    final iconColor = failed
        ? scheme.error
        : pending
            ? scheme.outline
            : Colors.green;

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon, color: iconColor),
        title: Text(call.name),
        subtitle: Text(_preview(call), maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => _openDetails(context),
      ),
    );
  }

  /// Open the detail panel as a modal bottom sheet (web DetailsPanel posture).
  Future<void> _openDetails(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DetailsSheet(call: call),
    );
  }

  String _preview(AssistantToolCallBlock call) {
    if (call.result != null) {
      return call.result!.replaceAll('\n', ' ');
    }
    return call.arguments;
  }
}

/// Detail panel for one tool call: header, pretty JSON input, and output.
class _DetailsSheet extends StatelessWidget {
  const _DetailsSheet({required this.call});

  final AssistantToolCallBlock call;

  @override
  Widget build(BuildContext context) {
    final pending = call.result == null;
    final failed = call.error != null;
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Text(
                    '详情',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Text(
                    call.name,
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                children: [
                  _section(context, '输入', _pretty(call.arguments)),
                  const SizedBox(height: 8),
                  if (pending)
                    _section(context, '输出', '运行中…')
                  else if (failed)
                    _section(context, '输出', call.error.toString())
                  else
                    _section(context, '输出', call.result!),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String label, String content) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: scheme.outline),
          ),
          const SizedBox(height: 2),
          SelectableText(
            content,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }

  /// Pretty-print JSON args (web DetailsPanel `pretty`); verbatim on malformed.
  String _pretty(String json) {
    final trimmed = json.trim();
    if (trimmed.isEmpty) return trimmed;
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(trimmed));
    } catch (_) {
      return trimmed;
    }
  }
}
