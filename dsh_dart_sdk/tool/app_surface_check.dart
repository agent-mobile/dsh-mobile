/// App-surface integration check against a live host: exercises exactly the
/// calls the mobile app makes, in the shapes the app sends them.
///
/// Usage: dart run tool/app_surface_check.dart <server-url> <token>
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  final token = args.length > 1 ? args[1] : 'your-token';
  final client = DshApiClient(baseUrl: Uri.parse(url), token: token);
  final sessions = DshSessionApi(client);
  final commands = DshCommandsApi(client);
  final workspaces = DshWorkspaceApi(client);

  final list = await sessions.list();
  print('session/list: ${list.length} row(s)');
  final live = list.firstWhere((s) => !s.blank, orElse: () => list.first);

  final cmds = await commands.listCommands(agentId: live.sessionId);
  print('commands/list (${live.sessionId}): ${cmds.length} command(s)');

  final skills = await commands.listSkills(sessionId: live.sessionId);
  print('skills/list: ${skills.length} skill(s)');

  final subs = await client
      .callUnary('subagents/list', {'parentSessionId': live.sessionId}, (v) => v);
  print('subagents/list ok: ${subs is RpcResultOk}');

  final ws = await workspaces.list();
  print('workspace/follow baseline: ${ws.items.length} workspace(s), '
      '${ws.archivedSessionIds.length} archived');

  final dir = await workspaces.listDirectory();
  print('directoryPicker/list: ${dir.entries.length} entr(ies)');

  final models = await sessions.models();
  print('session/modelCatalog: ${models.groups.length} group(s), '
      'default=${models.defaultSelection}');

  client.dispose();
  print('== app surface done ==');
}
