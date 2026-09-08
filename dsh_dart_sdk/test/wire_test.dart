/// Unit tests for the wire contract mirror.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('wire messages', () {
    test('mintRpcId produces UUID-shaped ids and no two match', () {
      final a = mintRpcId();
      final b = mintRpcId();
      expect(a, isNot(equals(b)));
      expect(a.split('-'), hasLength(5));
      expect(a[14], '4'); // version nibble
    });

    test('ClientRequest serializes with the four-quadrant type tag', () {
      const request = ClientRequest(rpcId: 'abc', method: 'session/list', args: {'cursor': null});
      final json = request.toJson();
      expect(json['type'], 'client-request');
      expect(json['rpcId'], 'abc');
      expect(json['method'], 'session/list');
      // 0.1.2 wraps the named args under payload.args.
      expect(json['payload'], {'args': {'cursor': null}});
    });

    test('ServerResponse.parse decodes an ok value', () {
      const body = '{"type":"server-response","rpcId":"abc",'
          '"result":{"ok":true,"value":{"items":[]}}}';
      final parsed = ServerResponse<Map<String, Object?>>.parse(
        body,
        (value) => value as Map<String, Object?>,
      );
      expect(parsed.rpcId, 'abc');
      expect(parsed.result, isA<RpcResultOk<Map<String, Object?>>>());
      expect((parsed.result as RpcResultOk).value, containsPair('items', []));
    });

    test('ServerResponse.parse decodes an error result', () {
      const body = '{"type":"server-response","rpcId":"abc",'
          '"result":{"ok":false,"error":{"code":"session-not-found",'
          '"message":"missing","details":{"sessionId":"s1"}}}}';
      final parsed = ServerResponse<Object?>.parse(body, (value) => value);
      final result = parsed.result;
      expect(result, isA<RpcResultErr<Object?>>());
      final error = (result as RpcResultErr).error;
      expect(error.code, RpcErrorCode.sessionNotFound);
      expect(error.message, 'missing');
    });

    test('ServerResponse.parse refuses an error result without an error body', () {
      const body = '{"type":"server-response","rpcId":"abc","result":{"ok":false}}';
      expect(
        () => ServerResponse<Object?>.parse(body, (value) => value),
        throwsA(isA<FormatException>()),
      );
    });

    test('ClientResponse serializes a failing result under result.error', () {
      const response = ClientResponse(
        rpcId: 'abc',
        result: RpcResultErr<Object?>(
          RpcError(code: RpcErrorCode.sessionNotFound, message: 'missing', details: const {'sessionId': 's1'}),
        ),
      );
      final json = response.toJson();
      final result = json['result'] as Map;
      expect(result['ok'], false);
      final error = result['error'] as Map;
      expect(error['code'], 'session-not-found');
      expect(error['message'], 'missing');
    });

    test('ServerRequest.parse reads the frame envelope', () {
      const body =
          '{"type":"server-request","rpcId":"push-1","method":"session/event",'
          '"payload":{"type":"session/event","sessionId":"s1","event":{}}}';
      final frame = ServerRequest.parse(body);
      expect(frame.rpcId, 'push-1');
      expect(frame.method, 'session/event');
      final payload = frame.payload! as Map;
      expect(payload['type'], 'session/event');
      expect(payload['sessionId'], 's1');
    });

    test('RpcReceipt.parse reads accepted and reason forms', () {
      expect(RpcReceipt.parse('{"accepted":true}').accepted, isTrue);
      final rejected = RpcReceipt.parse('{"accepted":false,"reason":"not-pending"}');
      expect(rejected.accepted, isFalse);
      expect(rejected.reason, 'not-pending');
    });

    test('RpcErrorCode.fromWire maps unknown codes to internal', () {
      expect(RpcErrorCode.fromWire('session-not-found'), RpcErrorCode.sessionNotFound);
      expect(RpcErrorCode.fromWire('future-code'), RpcErrorCode.internal);
    });
  });

  group('session surface fold', () {
    SessionEvent event({
      required int seq,
      required String type,
      Map<String, Object?> data = const {},
      int time = 1000,
    }) =>
        SessionEvent(seq: seq, type: type, time: time, data: data);

    test('folds streaming assistant text deltas and tool-call deltas', () {
      final surface = SessionSurface(sessionId: 's1');
      surface.fold(event(seq: 1, type: 'turn/start', data: {'turn': 1}));
      surface.fold(event(seq: 2, type: 'user/message', data: {
        'source': 'user',
        'content': [
          {'type': 'text', 'text': 'hello'},
        ],
      }));
      surface.fold(event(seq: 3, type: 'step/start', data: {'turn': 1, 'step': 1}));
      surface.fold(event(seq: 4, type: 'assistant/chunk', data: {
        'turn': 1,
        'step': 1,
        'chunk': {'type': 'block-start', 'index': 0, 'blockType': 'text'},
      }));
      surface.fold(event(seq: 5, type: 'assistant/chunk', data: {
        'turn': 1,
        'step': 1,
        'chunk': {'type': 'text-delta', 'index': 0, 'text': 'thinking '},
      }));
      surface.fold(event(seq: 6, type: 'assistant/chunk', data: {
        'turn': 1,
        'step': 1,
        'chunk': {'type': 'text-delta', 'index': 0, 'text': 'done'},
      }));
      surface.fold(event(seq: 7, type: 'assistant/chunk', data: {
        'turn': 1,
        'step': 1,
        'chunk': {'type': 'tool-call-delta', 'index': 1, 'id': 'call-1', 'name': 'bash', 'argumentsDelta': '{"command":"ls"}'},
      }));

      expect(surface.messages, hasLength(2));
      expect(surface.messages[0], isA<UserSessionMessage>());
      final assistant = surface.messages[1] as AssistantSessionMessage;
      expect(assistant.text, 'thinking done');
      expect(assistant.toolCalls, hasLength(1));
      expect(assistant.toolCalls[0].name, 'bash');
      expect(assistant.toolCalls[0].callId, 'call-1');
      expect(assistant.toolCalls[0].arguments, '{"command":"ls"}');
      expect(assistant.toolCalls[0].result, isNull);
      expect(assistant.streaming, isTrue);
    });

    test('block-end settles a tool call with its final block', () {
      final surface = SessionSurface(sessionId: 's1');
      surface.fold(event(seq: 1, type: 'assistant/chunk', data: {
        'turn': 1,
        'step': 1,
        'chunk': {
          'type': 'block-end',
          'index': 0,
          'block': {'type': 'tool-call', 'callId': 'c9', 'name': 'bash', 'arguments': '{"a":1}'},
        },
      }));

      final assistant = surface.messages.single as AssistantSessionMessage;
      expect(assistant.toolCalls, hasLength(1));
      expect(assistant.toolCalls[0].callId, 'c9');
      expect(assistant.toolCalls[0].arguments, '{"a":1}');
    });

    test('tool/result resolves the matching call via the result message', () {
      final surface = SessionSurface(sessionId: 's1');
      surface.fold(event(seq: 1, type: 'assistant/chunk', data: {
        'turn': 1,
        'step': 1,
        'chunk': {'type': 'tool-call-delta', 'index': 0, 'id': 'c1', 'name': 'bash', 'argumentsDelta': '{}'},
      }));
      surface.fold(event(seq: 2, type: 'tool/result', data: {
        'turn': 1,
        'step': 1,
        'message': {
          'role': 'user',
          'source': {'kind': 'tool', 'callId': 'c1'},
          'content': [
            {'type': 'tool-result', 'toolCallId': 'c1', 'content': [{'type': 'text', 'text': 'output'}]},
          ],
        },
      }));

      final assistant = surface.messages.single as AssistantSessionMessage;
      expect(assistant.toolCalls[0].result, 'output');
      expect(assistant.toolCalls[0].error, isNull);
    });

    test('tool/result carries an error identity on a failed call', () {
      final surface = SessionSurface(sessionId: 's1');
      surface.fold(event(seq: 1, type: 'assistant/chunk', data: {
        'turn': 1,
        'step': 1,
        'chunk': {'type': 'tool-call-delta', 'index': 0, 'id': 'c1', 'name': 'bash', 'argumentsDelta': '{}'},
      }));
      surface.fold(event(seq: 2, type: 'tool/result', data: {
        'turn': 1,
        'step': 1,
        'error': {'name': 'ToolError', 'code': 'exec-failed'},
        'message': {
          'role': 'user',
          'source': {'kind': 'tool', 'callId': 'c1'},
          'content': [
            {'type': 'tool-result', 'toolCallId': 'c1', 'isError': true, 'content': []},
          ],
        },
      }));

      final assistant = surface.messages.single as AssistantSessionMessage;
      expect(assistant.toolCalls[0].error, isNotNull);
    });

    test('assistant/message replaces the deltas with the final content', () {
      final surface = SessionSurface(sessionId: 's1');
      surface.fold(event(seq: 1, type: 'assistant/chunk', data: {
        'turn': 1,
        'step': 1,
        'chunk': {'type': 'text-delta', 'index': 0, 'text': 'partial'},
      }));
      surface.fold(event(seq: 2, type: 'assistant/message', data: {
        'turn': 1,
        'step': 1,
        'message': {'content': [
          {'type': 'text', 'text': 'final'},
        ]},
        'usage': {'inputTokens': 3, 'outputTokens': 4},
      }));

      final assistant = surface.messages.single as AssistantSessionMessage;
      expect(assistant.text, 'final');
      expect(assistant.streaming, isFalse);
      expect(assistant.usage, {'inputTokens': 3, 'outputTokens': 4});
    });

    test('user/message source resolves its kind from the wire source map', () {
      final surface = SessionSurface(sessionId: 's1');
      surface.fold(event(seq: 1, type: 'user/message', data: {
        'source': {'kind': 'user', 'rpcId': 'r1'},
        'content': [
          {'type': 'text', 'text': 'hi'},
        ],
      }));
      surface.fold(event(seq: 2, type: 'user/message', data: {
        'source': 'legacy-user',
        'content': [
          {'type': 'text', 'text': 'old'},
        ],
      }));
      surface.fold(event(seq: 3, type: 'user/message', data: {
        'source': null,
        'content': [
          {'type': 'text', 'text': 'x'},
        ],
      }));

      final users = surface.messages.whereType<UserSessionMessage>().toList();
      expect(users.map((m) => m.source), ['user', 'legacy-user', 'user']);
    });

    test('injected context sources never fold into the visible transcript', () {
      final surface = SessionSurface(sessionId: 's1');
      // The system-prompt plugin appends this snapshot before every turn.
      surface.fold(event(seq: 1, type: 'user/message', data: {
        'source': {
          'kind': 'plugin',
          'plugin': '@deepseek-ai/dsh-system-prompt',
          'form': 'snapshot',
          'sections': [
            {'name': 'sandbox:policy', 'text': 'Current DSH file policy: workspace-write.'},
          ],
        },
        'content': [
          {'type': 'text', 'text': 'Current runtime context. This snapshot supersedes earlier runtime-context snapshots.'},
        ],
      }));
      surface.fold(event(seq: 2, type: 'user/message', data: {
        'source': {'kind': 'agent-instructions', 'changes': []},
        'content': [
          {'type': 'text', 'text': 'AGENTS.md'},
        ],
      }));
      surface.fold(event(seq: 3, type: 'user/message', data: {
        'source': {'kind': 'user', 'rpcId': 'r2'},
        'content': [
          {'type': 'text', 'text': 'hello'},
        ],
      }));

      expect(surface.messages, hasLength(1));
      final only = surface.messages.single as UserSessionMessage;
      expect(only.source, 'user');
      expect(
        only.content.whereType<Map>().map((c) => c['text']),
        contains('hello'),
      );
    });

    test('stale seqs are ignored (reconnect baseline never overwrites)', () {
      final surface = SessionSurface(sessionId: 's1');
      surface.fold(event(seq: 1, type: 'turn/start', data: {'turn': 1}));
      surface.fold(event(seq: 2, type: 'user/message', data: {'source': 'user', 'content': []}));
      // A replay baseline with an older seq must be ignored.
      surface.fold(event(seq: 1, type: 'user/message', data: {'source': 'user', 'content': []}));
      expect(surface.messages, hasLength(1));
      expect(surface.lastSeq, 2);
    });
  });
}
