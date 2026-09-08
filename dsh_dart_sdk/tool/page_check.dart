import 'dart:convert';
import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
Future<void> main(List<String> args) async {
  final client = DshApiClient(baseUrl: Uri.parse('http://127.0.0.1:3080'), token: args[0]);
  final sessions = DshSessionApi(client);
  var cursor = 0;
  try {
    await sessions.history(sessionId: args[1], throughSeq: 1 << 30);
  } on RpcDomainException catch (e) {
    final m = RegExp(r'past cursor (\d+)').firstMatch(e.toString());
    if (m != null) cursor = int.parse(m.group(1)!);
  }
  final page = await sessions.history(sessionId: args[1], throughSeq: cursor);
  final want = args.skip(2).isEmpty ? null : args.skip(2).toSet();
  for (final e in page.entries) {
    if (want != null && !want.contains('${e.event.seq}')) continue;
    final s = const JsonEncoder.withIndent('  ').convert({'type': e.event.type, 'data': e.event.data});
    print('---- seq ${e.event.seq} ${e.event.type}');
    print(s.length > 900 ? s.substring(0, 900) : s);
  }
  client.dispose();
}
