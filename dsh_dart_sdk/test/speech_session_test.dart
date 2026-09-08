/// Live-transcription session wire tests against a mock `/s/ws` server
/// speaking the dsh-speech plugin's session channel protocol.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late List<WebSocket> clients;
  late List<Object?> received;

  setUp(() async {
    clients = [];
    received = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      final path = request.uri.path;
      if (path == '/s/ws') {
        unawaited(
          WebSocketTransformer.upgrade(request).then((ws) {
            clients.add(ws);
            ws.listen((frame) {
              received.add(frame);
              if (frame is String) {
                final control = jsonDecode(frame) as Map<String, Object?>;
                if (control['type'] == 'session.create') {
                  ws.add(jsonEncode({
                    'type': 'session.ready',
                    'provider': 'mock',
                    'mode': 'streaming',
                    'partial': true,
                    'diarization': true,
                  }));
                }
                if (control['type'] == 'session.close') {
                  ws.add(jsonEncode({
                    'type': 'transcript',
                    'provider': 'mock',
                    'text': '你好世界',
                    'segments': [
                      {'spk': 0, 'text': '你好，', 'startMs': 0, 'endMs': 400},
                      {'spk': 1, 'text': '世界。', 'startMs': 400, 'endMs': 800},
                    ],
                  }));
                  ws.add(jsonEncode({'type': 'closed', 'provider': 'mock'}));
                }
              }
            });
          }),
        );
        return;
      }
      request.response.statusCode = 404;
      unawaited(request.response.close());
    });
  });

  tearDown(() async {
    for (final client in clients) {
      unawaited(client.close());
    }
    await server.close(force: true);
  });

  Uri base() => Uri.parse('http://127.0.0.1:${server.port}');

  /// The upgraded server-side socket of the most recent session connection.
  Future<WebSocket> serverSocket() async {
    while (clients.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return clients.first;
  }

  test('openSession negotiates, streams events, and closes with a flush',
      () async {
    final client = DshSpeechClient(baseUrl: base(), token: 'secret');
    final session = await client.openSession(provider: 'mock');

    final events = <SpeechSessionEvent>[];
    final sub = session.events.listen(events.add);

    final ready = await session.events
        .firstWhere((event) => event is SpeechSessionReady)
        .timeout(const Duration(seconds: 5));
    expect((ready as SpeechSessionReady).provider, 'mock');
    expect(ready.partial, isTrue);
    expect(ready.diarization, isTrue);

    session.sendAudio(Uint8List.fromList([1, 2, 3, 4]));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received.whereType<List<int>>(), isNotEmpty);

    await session.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final transcript = events.whereType<SpeechSessionTranscript>().single;
    expect(transcript.text, '你好世界');
    expect(transcript.segments, const [
      SpeechSessionSegment(spk: 0, text: '你好，', startMs: 0, endMs: 400),
      SpeechSessionSegment(spk: 1, text: '世界。', startMs: 400, endMs: 800),
    ]);
    expect(events.last, isA<SpeechSessionClosed>());
    await session.done;
    await sub.cancel();
  });

  test('partial events surface before finals', () async {
    final client = DshSpeechClient(baseUrl: base(), token: 'secret');
    final session = await client.openSession();
    final partialArrived = Completer<void>();
    final sub = session.events.listen((event) {
      if (event is SpeechSessionPartial && !partialArrived.isCompleted) {
        partialArrived.complete();
      }
    });
    final ws = await serverSocket();
    ws.add(jsonEncode({
      'type': 'partial',
      'provider': 'mock',
      'text': '你好世',
    }));
    await partialArrived.future.timeout(const Duration(seconds: 5));
    await sub.cancel();
    await session.close();
  });

  test('error events settle the session', () async {
    final client = DshSpeechClient(baseUrl: base(), token: 'secret');
    final session = await client.openSession();
    final failure = session.events
        .firstWhere((event) => event is SpeechSessionError)
        .timeout(const Duration(seconds: 5));
    (await serverSocket()).add(jsonEncode({
      'type': 'error',
      'code': 'SPEECH_UPSTREAM_FAILURE',
      'message': 'asr down',
    }));
    final event = await failure as SpeechSessionError;
    expect(event.code, 'SPEECH_UPSTREAM_FAILURE');
    await session.done;
    // Closing a settled session is a no-op, not a state error.
    await session.close();
  });

  test('session.create carries the negotiated facts on the wire', () async {
    final client = DshSpeechClient(baseUrl: base(), token: 'secret');
    final session = await client.openSession(
      sampleRateHz: 16000,
      diarization: false,
    );
    await session.events
        .firstWhere((event) => event is SpeechSessionReady)
        .timeout(const Duration(seconds: 5));
    final create = received
        .whereType<String>()
        .map((frame) => jsonDecode(frame) as Map<String, Object?>)
        .first;
    expect(create['type'], 'session.create');
    expect(create['sampleRateHz'], 16000);
    expect(create['encoding'], 'pcm16');
    expect(create['diarization'], false);
    expect(create.containsKey('provider'), isFalse);
    await session.close();
  });
}
