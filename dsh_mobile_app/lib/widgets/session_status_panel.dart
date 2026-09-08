/// Session status panel: goal, plan, todo, and background-job projections.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:flutter/material.dart';

import '../state/connection_controller.dart';

/// Renders the per-session projections (goal/plan/todos) and jobs above the
/// transcript.
class SessionStatusPanel extends StatelessWidget {
  const SessionStatusPanel({super.key, required this.connection, required this.sessionId});

  final ConnectionController connection;
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final projections = connection.projections(sessionId);
    final goal = projections['goal']?.value;
    final plan = projections['plan']?.value;
    final todos = projections['todos']?.value;
    final jobs = connection.jobs(sessionId);

    final sections = <Widget>[];
    if (goal is Map) sections.add(_ProjectionSection('目标', _goalText(goal)));
    if (plan is Map && (plan['active'] == true || plan['pending'] == true)) {
      sections.add(
        _ProjectionSection('计划', plan['active'] == true ? '计划模式进行中' : '计划模式即将开启'),
      );
    }
    if (todos is List && todos.isNotEmpty) {
      sections.add(_ProjectionSection('任务', _todoText(todos)));
    }
    if (jobs.isNotEmpty) {
      sections.add(_JobSection(jobs));
    }

    if (sections.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: sections,
    );
  }

  String _goalText(Map<Object?, Object?> goal) {
    final objective = goal['objective'];
    final phase = goal['phase'];
    return '${phase ?? '进行中'}：${objective ?? ''}';
  }

  String _todoText(List<Object?> todos) {
    final done = todos.whereType<Map>().where((t) => t['status'] == 'done').length;
    return '$done/${todos.length} 已完成';
  }
}

class _ProjectionSection extends StatelessWidget {
  const _ProjectionSection(this.title, this.text);

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        dense: true,
        leading: Icon(
          title == '目标' ? Icons.flag_outlined : Icons.checklist,
          size: 18,
          color: scheme.primary,
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(text),
      ),
    );
  }
}

class _JobSection extends StatelessWidget {
  const _JobSection(this.jobs);

  final List<JobView> jobs;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('后台任务', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            for (final job in jobs)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  job.status == 'running' ? Icons.play_circle : Icons.stop_circle,
                  color: job.status == 'running' ? Colors.green : Colors.grey,
                  size: 18,
                ),
                title: Text(job.label),
                subtitle: Text('${job.kind} · ${job.status}${job.detail != null ? ' · ${job.detail}' : ''}'),
              ),
          ],
        ),
      ),
    );
  }
}
