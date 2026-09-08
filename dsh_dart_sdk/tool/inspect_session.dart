/// Inspect session.list rows and history-tail projections for title/workspace.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';

Future<void> main(List<String> args) async {
  final base = Uri.parse(args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080');
  final token = args.length > 1 ? args[1] : 'your-token';
  final client = DshApiClient(baseUrl: base, token: token);
  final sessions = DshSessionApi(client);

  final list = await sessions.list();
  print('session.list: ${list.length} rows');
  for (final s in list.take(6)) {
    print('  id=${s.sessionId} blank=${s.blank} running=${s.running} cwd=${s.cwd} agentPreset=${s.agentPreset}');
  }

  // Tail page projections for the first non-blank session.
  final target = list.where((s) => !s.blank).firstOrNull;
  if (target != null) {
    final page = await sessions.history(sessionId: target.sessionId, throughSeq: 0);
    print('history projections for ${target.sessionId}:');
    print('  asOfSeq=${page.projections?['asOfSeq']} keys=${page.projections?.keys}');
    final values = page.projections?['values'];
    if (values is Map) {
      print('  projection values keys: ${values.keys.toList()}');
      final title = values['title'];
      print('  title=$title');
    }
  }

  client.dispose();
}
