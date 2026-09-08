import 'dart:convert';
import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';

Future<void> main(List<String> args) async {
  final client = DshApiClient(baseUrl: Uri.parse(args[0]), token: args[1]);
  final result = await client.callUnary<Object?>('session/page', {
    'request': {
      'address': {'kind': 'session', 'sessionId': args[2]},
      'throughSeq': 44,
      'maxMessages': 40,
    },
  }, (value) => value);
  if (result is RpcResultOk && result.value is Map) {
    final records = (result.value as Map)['records'];
    print('records=${records is List ? records.length : 0}');
    if (records is List) {
      for (final record in records) {
        final event = record is Map ? record['event'] : null;
        if (event is! Map) continue;
        final type = event['type'];
        final data = event['data'];
        if (type == 'user/message' && data is Map) {
          var text = '';
          final content = data['content'];
          if (content is List) {
            for (final c in content) {
              if (c is Map && c['text'] is String) text += c['text'] as String;
            }
          }
          final flat = text.replaceAll('\n', ' ');
          print('USER seq=${event['seq']} source=${const JsonEncoder().convert(data['source'])}');
          print('  text[:240]=${flat.substring(0, flat.length > 240 ? 240 : flat.length)}');
        } else {
          print('EVENT $type seq=${event['seq']}');
        }
      }
    }
  } else if (result is RpcResultErr) {
    print('err: ${result.error.message}');
  }
  client.dispose();
}
