/// End-to-end SDK smoke test against a live dsh web server.
///
/// Usage:
///   dart run tool/smoke.dart <server-url> <token>
///
/// Exercises 0.1.2 paths: auth (session/list), session create/prompt, the
/// single `$events` downlink (remote.mux), and session/page history.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080';
  final token = args.length > 1 ? args[1] : 'your-token';
  final base = Uri.parse(url);

  print('== connecting to $base ==');
  final client = DshApiClient(baseUrl: base, token: token);
  final sessions = DshSessionApi(client);

  // 1. Auth via session/list (0.1.2 has no host.describe).
  final listResult = await client.callUnary<Object?>('session/list', const {'_request': {}}, (v) => v);
  switch (listResult) {
    case RpcResultErr():
      print('AUTH FAILED: ${listResult.error.code.wire} ${listResult.error.message}');
      client.dispose();
      return;
    case RpcResultOk(:final value):
      final map = value is Map ? value : const <String, Object?>{};
      final items = map['items'];
      print('session/list OK: ${items is List ? items.length : 0} session(s)');
  }

  // 2. Session list.
  final list = await sessions.list();
  print('sessions.list: ${list.length} session(s)');

  // 3. Open the single $events downlink and capture forwarded application
  //    frames. 0.1.2 forwards an 18-event allowlist (api-session/*, approval
  //    and question waterfalls, …) — raw transcript events ride the
  //    per-session `session/follow` stream instead.
  final events = await client.openEvents();
  final seen = <String>[];
  final probeSession = <String?>[null];
  final sub = events.frames.listen((frame) {
    if (frame.type == 'ready') return;
    if (frame.type == 'waterfall' || frame.type == 'cancel') {
      seen.add(frame.type);
      return;
    }
    if (frame.type != 'emit') return;
    if (probeSession[0] != null) seen.add(frame.event ?? '?');
  });

  // 4. Create a session and send a message; the agent needs a model route,
  //    so send a trivial prompt and just verify acceptance + queue events.
  final sessionId = await sessions.create();
  probeSession[0] = sessionId;
  print('session/create: $sessionId');

  try {
    await sessions.prompt(
      sessionId: sessionId,
      content: [
        {'type': 'text', 'text': 'Reply with the single word: pong'},
      ],
    );
    print('session/prompt accepted');
  } catch (error) {
    print('session/prompt failed (model may be unconfigured): $error');
  }

  // 5. Open the per-session follow stream (the live transcript channel) and
  //    read its opening snapshot: `{type:'snapshot', cursor, records,
  //    hasMore, projections}`. The cursor anchors session/page windows.
  var followFrames = 0;
  var followCursor = -1;
  final follow = await client.openLogicalStream('session/follow', {
    'args': {
      'request': {
        'address': {'kind': 'session', 'sessionId': sessionId},
      },
    },
  });
  final followSub = follow.items.listen((item) {
    followFrames += 1;
    if (item is Map && item['type'] == 'snapshot' && item['cursor'] is int) {
      followCursor = item['cursor']! as int;
    }
  });

  // Wait briefly for the turn to progress and frames to arrive.
  await Future<void>.delayed(const Duration(seconds: 8));
  print('\$events frames seen: $seen');
  print('session/follow frames seen: $followFrames (cursor $followCursor)');

  // 6. Read back history via session/page against the snapshot cursor.
  final page = await sessions.history(
    sessionId: sessionId,
    throughSeq: followCursor,
  );
  print('session/page: ${page.entries.length} event(s), hasMore=${page.hasMore}');

  await followSub.cancel();
  await follow.close();
  await sub.cancel();
  await events.close();
  client.dispose();
  print('== smoke done ==');
}
