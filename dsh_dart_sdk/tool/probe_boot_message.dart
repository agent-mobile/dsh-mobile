import 'dart:convert';
import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  final token = args.length > 1 ? args[1] : '';
  final client = DshApiClient(baseUrl: Uri.parse(url), token: token);
  final sessions = DshSessionApi(client);
  final id = await sessions.create();
  print('session $id');
  await Future<void>.delayed(const Duration(seconds: 2));
  await sessions.prompt(
    sessionId: id,
    content: [
      {'type': 'text', 'text': '回复一个字：好'},
    ],
    clientTimeZone: 'Asia/Shanghai',
  );
  print('prompt sent');
  await Future<void>.delayed(const Duration(seconds: 25));
  print('paging...');

  // Discover the log cursor, then page the newest window.
  var cursor = -1;
  for (var probe = 64; probe <= 1048576; probe *= 2) {
    final result = await client.callUnary<Object?>('session/page', {
      'request': {
        'address': {'kind': 'session', 'sessionId': id},
        'throughSeq': probe,
        'maxMessages': 1,
      },
    }, (value) => value);
    if (result is RpcResultOk) {
      cursor = probe;
      break;
    }
    final message = result is RpcResultErr ? result.error.message : '';
    final match = RegExp('cursor (\d+)').firstMatch(message);
    if (match != null) {
      cursor = int.parse(match.group(1)!);
      break;
    }
    print('probe $probe err: $message');
  }
  print('cursor=$cursor');
  if (cursor < 0) { client.dispose(); return; }
  final result = await client.callUnary<Object?>('session/page', {
    'request': {
      'address': {'kind': 'session', 'sessionId': id},
      'throughSeq': cursor,
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
          print('  text[:220]=${flat.substring(0, flat.length > 220 ? 220 : flat.length)}');
        } else {
          print('EVENT $type seq=${event['seq']}');
        }
      }
    }
  } else if (result is RpcResultErr) {
    print('final page err: ${result.error.message}');
  }
  client.dispose();
}
