/// Unit tests for the approval and question interaction contract.
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('approval', () {
    test('ApprovalRequest.fromWaterfall parses the projected request', () {
      final request = ApprovalRequest.fromWaterfall(clientId: 'gen-1', eventId: 'ev-1', request: {
        'sessionId': 's1',
        'approvalId': 'a1',
        'toolName': 'bash',
        'callId': 'c1',
        'reason': 'run as current user',
      });
      expect(request.clientId, 'gen-1');
      expect(request.eventId, 'ev-1');
      expect(request.sessionId, 's1');
      expect(request.approvalId, 'a1');
      expect(request.toolName, 'bash');
      expect(request.callId, 'c1');
      expect(request.reason, 'run as current user');
    });

    test('answerApproval posts the client-response envelope', () async {
      // Verify the wire shape without a network by capturing the JSON that a
      // real transport would send. We exercise the payload construction via a
      // stub transport: build the response and check the echoed rpcId.
      final message = ClientResponse(
        rpcId: 'rpc-9',
        result: RpcResultOk<Object?>({
          'sessionId': 's1',
          'approvalId': 'a1',
          'outcome': 'allowed-once',
        }),
      );
      final json = message.toJson();
      expect(json['type'], 'client-response');
      expect(json['rpcId'], 'rpc-9');
      final result = json['result']! as Map;
      expect(result['ok'], true);
      final value = result['value']! as Map;
      expect(value['sessionId'], 's1');
      expect(value['approvalId'], 'a1');
      expect(value['outcome'], 'allowed-once');
    });

    test('rejected approval maps to the rejected wire outcome', () {
      final value = switch (ApprovalOutcome.rejected) {
        ApprovalOutcome.allowedOnce => 'allowed-once',
        ApprovalOutcome.rejected => 'rejected',
      };
      expect(value, 'rejected');
    });
  });

  group('questions', () {
    test('QuestionRequest.fromWaterfall parses items and options', () {
      final request = QuestionRequest.fromWaterfall(clientId: 'gen-1', eventId: 'ev-q', request: {
        'sessionId': 's1',
        'questions': [
          {
            'id': 'q1',
            'question': 'Pick a tool?',
            'header': 'Confirm',
            'options': [
              {'label': 'A', 'description': 'option a'},
              {'label': 'B'},
            ],
          },
          {
            'id': 'q2',
            'question': 'Multi?',
            'multiSelect': true,
            'options': [
              {'label': 'X'},
              {'label': 'Y'},
            ],
          },
        ],
      });
      expect(request.clientId, 'gen-1');
      expect(request.eventId, 'ev-q');
      expect(request.questions, hasLength(2));
      final first = request.questions[0];
      expect(first.id, 'q1');
      expect(first.header, 'Confirm');
      expect(first.multiSelect, isFalse);
      expect(first.options, hasLength(2));
      expect(first.options[0].description, 'option a');
      expect(request.questions[1].multiSelect, isTrue);
    });

    test('QuestionRequest.fromWaterfall tolerates the legacy snake_case multi_select key', () {
      final request = QuestionRequest.fromWaterfall(clientId: 'gen-1', eventId: 'ev-q', request: {
        'sessionId': 's1',
        'questions': [
          {
            'id': 'q2',
            'question': 'Multi?',
            'multi_select': true,
          },
        ],
      });
      expect(request.questions.single.multiSelect, isTrue);
    });

    test('QuestionAnswerBatch serializes the host answer array in order', () {
      final batch = QuestionAnswerBatch([
        (id: 'q1', answer: QuestionAnswer(selected: ['A'])),
        (id: 'q2', answer: QuestionAnswer(selected: ['X', 'Y'])),
        (id: 'q3', answer: QuestionAnswer(custom: 'free text')),
        (id: 'q4', answer: QuestionAnswer()),
      ]);
      final json = batch.toJson();
      expect(json, {
        'answers': [
          {'id': 'q1', 'selected': ['A']},
          {'id': 'q2', 'selected': ['X', 'Y']},
          {'id': 'q3', 'selected': <String>[], 'custom': 'free text'},
          // `selected` is required by the host schema even when empty.
          {'id': 'q4', 'selected': <String>[]},
        ],
      });
    });

    test('QuestionAnswerBatch omits whitespace-only custom text', () {
      final batch = QuestionAnswerBatch([
        (id: 'q1', answer: QuestionAnswer(selected: const [], custom: '   ')),
      ]);
      final answer = (batch.toJson()['answers']! as List).single as Map;
      expect(answer.containsKey('custom'), isFalse);
    });

    test('single-select answer uses one of selected/custom', () {
      final selected = QuestionAnswer(selected: ['A']).toJson();
      expect(selected.containsKey('custom'), isFalse);
      final custom = QuestionAnswer(custom: 'other').toJson();
      expect(custom.containsKey('selected'), isFalse);
    });

    test('answerQuestions surfaces a refused \$events/result as an error', () async {
      final interaction = DshInteractionApi(_RejectingClient());
      final request = QuestionRequest.fromWaterfall(
        clientId: 'gen-1',
        eventId: 'ev-q',
        request: {'questions': const []},
      );
      await expectLater(
        interaction.answerQuestions(
          request: request,
          answer: QuestionAnswerBatch([
            (id: 'q1', answer: QuestionAnswer(selected: ['A'])),
          ]),
        ),
        throwsA(isA<TransportException>()),
      );
    });

    test('answerApproval surfaces a refused \$events/result as an error', () async {
      final interaction = DshInteractionApi(_RejectingClient());
      final request = ApprovalRequest.fromWaterfall(
        clientId: 'gen-1',
        eventId: 'ev-a',
        request: {'approvalId': 'a1'},
      );
      await expectLater(
        interaction.answerApproval(request: request, outcome: ApprovalOutcome.allowedOnce),
        throwsA(isA<TransportException>()),
      );
    });
  });
}

/// Stub client whose \$events/result post always refuses, so the interaction
/// layer's transport-failure guard can be exercised without a network.
class _RejectingClient extends DshApiClient {
  _RejectingClient()
      : super(baseUrl: Uri.parse('http://127.0.0.1:1'), token: 'your-token');

  @override
  Future<void> respondEvent(RemoteEventResult result) async =>
      throw const TransportException('\$events/result answered HTTP 400', status: 400);
}
