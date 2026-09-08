/// Goal strip above the composer, mirroring web's GoalBar: the session's
/// `goal` projection as a compact bar with the objective, phase, and round
/// count. Empty renders nothing.
library;

import 'package:flutter/material.dart';

/// One goal projection as the client sees it (`goal` projection value).
class GoalProjectionView {
  const GoalProjectionView({
    required this.objective,
    required this.phase,
    required this.roundsStarted,
  });

  final String objective;

  /// `active` / `paused` / `blocked` / `complete`.
  final String phase;
  final int roundsStarted;

  static GoalProjectionView? fromValue(Object? value) {
    if (value is! Map) return null;
    final goal = value['goal'];
    if (goal is! Map) return null;
    final objective = goal['objective'];
    if (objective is! String || objective.isEmpty) return null;
    return GoalProjectionView(
      objective: objective,
      phase: goal['phase'] is String ? goal['phase'] as String : 'active',
      roundsStarted: (value['roundsStarted'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Renders the goal projection as a compact strip; empty renders nothing.
class GoalDock extends StatelessWidget {
  const GoalDock({super.key, required this.goal, this.onAction});

  /// The `goal` projection value, or null when absent.
  final Object? goal;

  /// Optional phase-action callback (pause/resume/complete/clear).
  final void Function(String phase)? onAction;

  @override
  Widget build(BuildContext context) {
    final view = GoalProjectionView.fromValue(goal);
    if (view == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    final phaseLabel = switch (view.phase) {
      'paused' => '已暂停',
      'blocked' => '受阻',
      'complete' => '已完成',
      _ => '进行中',
    };
    final phaseColor = switch (view.phase) {
      'complete' => Colors.green,
      'paused' => scheme.outline,
      'blocked' => scheme.error,
      _ => scheme.primary,
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: onAction == null ? null : () => onAction!(view.phase),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.flag_outlined, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  view.objective,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: phaseColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  phaseLabel,
                  style: TextStyle(fontSize: 11, color: phaseColor),
                ),
              ),
              if (view.roundsStarted > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '${view.roundsStarted} 轮',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
