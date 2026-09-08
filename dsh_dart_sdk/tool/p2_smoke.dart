/// P2 smoke: exercise settings/llm/goal/search/credentials against a live host.
///
/// Usage: dart run tool/p2_smoke.dart <server-url> <token>
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';

Future<void> main(List<String> args) async {
  final base = Uri.parse(args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080');
  final token = args.length > 1 ? args[1] : 'your-token';
  final client = DshApiClient(baseUrl: base, token: token);
  final config = DshConfigApi(client);
  final sessions = DshSessionApi(client);
  final goals = DshGoalApi(client);

  print('== P2 smoke ==');

  // settings.describe
  final describe = await config.settingsDescribe();
  print('settings.describe: writable=${describe.writable} namespaces=${describe.namespaces.length}');
  for (final ns in describe.namespaces) {
    print('  ns=${ns.ns} applies=${ns.applies} secrets=${ns.secrets.length}');
  }

  // llm.providers
  final providers = await config.llmProviders();
  print('llm.providers: ${providers.length}');
  for (final p in providers) {
    print('  ${p.provider} (${p.displayName}) active=${p.active}');
  }

  // llm.models
  try {
    final catalog = await config.llmModels();
    print('llm.models: ${catalog.groups.length} groups');
    for (final g in catalog.groups) {
      print('  ${g.id}: ${g.models.map((m) => m.id).join(', ')}');
    }
  } catch (e) {
    print('llm.models failed: $e');
  }

  // session.list then the deployment model catalog (0.1.2: no per-session form)
  final list = await sessions.list();
  if (list.isNotEmpty) {
    try {
      final models = await sessions.models();
      print('session/modelCatalog: routable=${models.routableProviders.length} groups=${models.groups.length}');
    } catch (e) {
      print('session/modelCatalog failed: $e');
    }
  }

  // goal.create on a fresh session (0.1.2: scoped by the agent identity)
  final sessionId = await sessions.create();
  try {
    final ref = await goals.create(agentId: sessionId, objective: 'verify goal API');
    print('goals/create: id=${ref.id} revision=${ref.revision}');
    await goals.clear(agentId: sessionId, ref: ref);
    print('goals/clear: ok');
  } catch (e) {
    print('goals/create/clear failed: $e');
  }

  // session.search
  try {
    final result = await sessions.search('pong');
    print('session/search: ${result.items.length} items hasMore=${result.hasMore}');
  } catch (e) {
    print('session/search failed: $e');
  }

  client.dispose();
  print('== P2 smoke done ==');
}
