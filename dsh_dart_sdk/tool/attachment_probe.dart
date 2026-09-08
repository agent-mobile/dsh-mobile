/// Live probe: the mobile app's image-attachment wire path against a running
/// host.
///
/// Flow: create a scratch session → send a prompt carrying an inline base64
/// PNG block (the exact shape the app's composer sends) → cancel the turn
/// immediately (no model cost) → page the session log and verify the image
/// block was persisted with identical bytes → read it back through
/// `session/attachment` and compare again.
///
/// Usage: dart run tool/attachment_probe.dart <server-url> <token>
library;

import 'dart:convert';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';

/// 1x1 red PNG.
const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Future<void> main(List<String> args) async {
  final base = Uri.parse(args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080');
  final token = args.length > 1 ? args[1] : 'your-token';
  final client = DshApiClient(baseUrl: base, token: token);
  final sessions = DshSessionApi(client);
  var failures = 0;

  void check(String label, bool ok, {Object? detail}) {
    // ignore: avoid_print
    print('${ok ? "PASS" : "FAIL"}  $label${detail == null ? '' : '  ($detail)'}');
    if (!ok) failures++;
  }

  final sessionId =
      'probe-attach-${DateTime.now().millisecondsSinceEpoch}';
  await sessions.create(sessionId: sessionId);
  // ignore: avoid_print
  print('scratch session: $sessionId');

  // 0. Text-mode attachment requires a vision-capable model; the deployment's
  // default (deepseek-v4-flash) rejects image input outright.
  await sessions.selectModel(
    sessionId: sessionId,
    provider: 'deepseek-official',
    model: 'deepseek-v4-flash-vision-exp',
  );
  // ignore: avoid_print
  print('model switched to deepseek-v4-flash-vision-exp');

  // 1. The app's exact prompt shape: inline image block first, text after.
  await sessions.prompt(
    sessionId: sessionId,
    content: [
      {
        'type': 'image',
        'mediaType': 'image/png',
        'data': _pngBase64,
        'name': 'probe.png',
      },
      {'type': 'text', 'text': '附件探针（会立即取消，无需回复）'},
    ],
    mode: 'queue',
  );
  check('session/prompt accepted inline image block', true);

  await sessions.cancel(sessionId: sessionId);
  // ignore: avoid_print
  print('turn cancelled (no model cost)');

  // 2. Learn the log cursor: page rejects throughSeq > cursor and names it.
  var cursor = -1;
  try {
    await sessions.history(sessionId: sessionId, throughSeq: 999999);
  } on RpcDomainException catch (e) {
    final m = RegExp(r'cursor (\d+)').firstMatch(e.error.message);
    if (m != null) cursor = int.parse(m.group(1)!);
  }
  check('session log has records (cursor=$cursor)', cursor >= 0);

  // 3. Page the log and find our user message's image block.
  // 3. Scan the log: prompt images persist inside agent/inbox/spliced
  // `inserted[].content[]`, with inline base64 replaced by a durable
  // content-addressed `attachment` descriptor.
  Map<String, Object?>? descriptor;
  if (cursor >= 0) {
    final page = await sessions.history(sessionId: sessionId, throughSeq: cursor);
    outer:
    for (final entry in page.entries) {
      final data = entry.event.data;
      if (data is! Map) continue;
      final inserted = data['inserted'];
      if (inserted is! List) continue;
      for (final item in inserted) {
        final content = item is Map ? item['content'] : null;
        if (content is! List) continue;
        for (final part in content) {
          if (part is Map &&
              part['type'] == 'image' &&
              part['attachment'] is Map) {
            descriptor = Map<String, Object?>.from(part['attachment'] as Map);
            break outer;
          }
        }
      }
    }
  }
  check('image attachment persisted in the session log', descriptor != null,
      detail: 'id=${descriptor?['attachmentId']}');
  check(
    'persisted size matches the upload (bytes)',
    descriptor?['bytes'] == 70 && descriptor?['mediaType'] == 'image/png',
    detail: 'bytes=${descriptor?['bytes']} mediaType=${descriptor?['mediaType']} name=${descriptor?['name']}',
  );

  // 4. Durable read-back through session/attachment.
  final attachmentId = descriptor?['attachmentId'];
  if (attachmentId is String && attachmentId.isNotEmpty) {
    final back = await sessions.attachment(
      sessionId: sessionId,
      attachmentId: attachmentId,
    );
    check(
      'session/attachment read-back bytes match',
      back.data == _pngBase64 && back.mediaType == 'image/png',
      detail: 'id=$attachmentId',
    );
  } else {
    // ignore: avoid_print
    print('SKIP  session/attachment read-back (no attachmentId on the block)');
  }

  client.dispose();
  // ignore: avoid_print
  print(failures == 0 ? '== attachment probe: ALL PASS ==' : '== attachment probe: $failures FAILURE(S) ==');
}
