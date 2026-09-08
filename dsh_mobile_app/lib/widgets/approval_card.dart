/// Approval prompt, mirroring web's ApprovalPanel: an amber "Waiting for
/// approval" strip, the model's reason as the headline, and a right-aligned
/// refuse/allow action row. One-shot: answered state disables the buttons.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:flutter/material.dart';

/// One pending tool-approval prompt, answered over the interaction API.
class ApprovalCard extends StatefulWidget {
  const ApprovalCard({super.key, required this.request, required this.onDecide});

  final ApprovalRequest request;

  /// Answers the approval; resolves true on success (buttons stay disabled),
  /// false on failure (buttons re-arm for another try).
  final Future<bool> Function(ApprovalOutcome outcome) onDecide;

  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  bool _answered = false;

  Future<void> _decide(ApprovalOutcome outcome) async {
    setState(() => _answered = true);
    final ok = await widget.onDecide(outcome);
    // Re-arm on failure so the user can retry; stay disabled on success.
    if (!ok && mounted) setState(() => _answered = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final request = widget.request;
    final headline = request.reason != null && request.reason!.isNotEmpty
        ? request.reason!
        : '工具 ${request.toolName} 请求越权执行';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.amber.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Amber "Waiting for approval" strip (web ApprovalPanel .strip).
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.15),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                const Icon(Icons.circle, size: 8, color: Colors.amber),
                const SizedBox(width: 6),
                const Text(
                  '等待审批',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  request.toolName ?? '工具',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headline, style: const TextStyle(fontSize: 14)),
                if (request.callId != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '调用：${request.callId}',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _answered ? null : () => _decide(ApprovalOutcome.rejected),
                      child: const Text('拒绝'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _answered ? null : () => _decide(ApprovalOutcome.allowedOnce),
                      child: const Text('允许一次'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
