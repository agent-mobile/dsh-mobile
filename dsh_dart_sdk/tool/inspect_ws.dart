/// Inspect the raw session.list rows to see if projections/title ride along.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';

Future<void> main(List<String> args) async {
  final base = Uri.parse(args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080');
  final token = args.length > 1 ? args[1] : 'your-token';
  final client = DshApiClient(baseUrl: base, token: token);

  final result = await client.callUnary<Object?>('session.list', const {}, (v) => v);
  if (result is RpcResultErr) {
    print('ERR: ${result.error.message}');
    return;
  }
  final map = (result as RpcResultOk).value! as Map;
  final items = map['items'] as List;
  print('items: ${items.length}');
  if (items.isNotEmpty) {
    final first = items[0] as Map;
    print('row keys: ${first.keys.toList()}');
    if (first['projections'] is Map) {
      final proj = first['projections'] as Map;
      print('projections keys: ${proj.keys.toList()}');
      final values = proj['values'];
      if (values is Map) print('values keys: ${values.keys.toList()}');
    }
  }
  // workspace.list
  final ws = await client.callUnary<Object?>('workspace.list', const {}, (v) => v);
  if (ws is RpcResultOk) {
    final wsMap = ws.value! as Map;
    print('workspace.list: ${(wsMap['items'] as List).length} rows');
    for (final w in (wsMap['items'] as List).take(5)) {
      final wm = w as Map;
      print('  ws: id=${wm['workspaceId']} title=${wm['title']} path=${wm['path']} sessions=${(wm['sessionIds'] as List? ?? []).length}');
    }
  } else {
    print('workspace.list ERR: ${(ws as RpcResultErr).error.message}');
  }
  client.dispose();
}
