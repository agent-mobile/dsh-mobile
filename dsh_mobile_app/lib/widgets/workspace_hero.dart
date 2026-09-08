/// Empty-session hero, mirroring web's HeroShell: "探索未至之境" headline
/// with a "预览版" preview badge and the workspace-choice row over the glow
/// area. Copy mirrors the web locale verbatim. The composer stays in the
/// bottom input dock, whose hint switches to the hero placeholder on blank
/// sessions.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Renders the centered hero chrome for a blank session.
class WorkspaceHero extends StatelessWidget {
  const WorkspaceHero({
    super.key,
    required this.workspaceLabel,
    required this.onPickWorkspace,
  });

  /// Current workspace label (null = "选择工作区").
  final String? workspaceLabel;

  final VoidCallback onPickWorkspace;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Headline row: logo mark + "探索未至之境" + "预览版" badge
            // (web HeroShell .headlineStack).
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.explore_outlined,
                  size: 20,
                  color: dswColor(context, dark: DswColors.deepseek400, light: DswColors.deepseek500),
                ),
                const SizedBox(width: 8),
                Text(
                  '探索未至之境',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: dswColor(context, dark: DswColors.bluish50, light: DswColors.bluish1000),
                  ),
                ),
                const SizedBox(width: 8),
                _PreviewBadge(),
              ],
            ),
            const SizedBox(height: 16),
            // Workspace-choice row (web WorkspaceChip posture).
            OutlinedButton.icon(
              onPressed: onPickWorkspace,
              icon: Icon(
                workspaceLabel == null ? Icons.folder_outlined : Icons.folder_open,
                size: 16,
              ),
              label: Text(workspaceLabel ?? '选择工作区'),
              style: OutlinedButton.styleFrom(
                foregroundColor: dswColor(context, dark: DswColors.bluish50, light: DswColors.bluish1000),
                side: BorderSide(color: dswColor(context, dark: DswColors.borderL2, light: DswColors.lightBorderL2)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "预览版" pill badge (web HeroShell .previewBadge).
class _PreviewBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: dswColor(context, dark: DswColors.bluish850, light: DswColors.bluish150),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: dswColor(context, dark: DswColors.borderL2, light: DswColors.lightBorderL2)),
      ),
      child: Text(
        '预览版',
        style: TextStyle(
          fontSize: 11,
          color: dswColor(context, dark: DswColors.bluish400, light: DswColors.bluish600),
        ),
      ),
    );
  }
}
