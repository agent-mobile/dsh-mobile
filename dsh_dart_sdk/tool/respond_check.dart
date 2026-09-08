/// Verify the approval/question respond wire path against a live host.
///
/// A synthetic approval answer with a fresh rpcId is expected to be rejected
/// with `not-pending` (the host has no pending request for that id) — which
/// proves the `/api/respond` envelope round-trip works without needing a real
/// approval. Also exercises the question-batch wire shape the same way.
///
/// Usage: dart run tool/respond_check.dart <server-url> <token>
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';

Future<void> main(List<String> args) async {
  final base = Uri.parse(args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080');
  final token = args.length > 1 ? args[1] : 'your-token';
  final client = DshApiClient(baseUrl: base, token: token);

  print('== \$events/result wire check ==');

  // A fresh eventId has no pending waterfall on the host; the post is expected
  // to be refused, which proves the \$events/result envelope round-trips. The
  // value is the bare outcome string: the host's ApprovalService normalizes
  // any other return shape to the fail-closed 'unavailable'.
  Object? approvalError;
  try {
    await client.respondEvent(RemoteEventResult.result(
      clientId: mintRpcId(),
      eventId: mintRpcId(),
      value: 'allowed-once',
    ));
  } catch (e) {
    approvalError = e;
  }
  print('approval \$events/result: ${approvalError ?? 'accepted'}');

  Object? questionError;
  try {
    await client.respondEvent(RemoteEventResult.result(
      clientId: mintRpcId(),
      eventId: mintRpcId(),
      value: QuestionAnswerBatch([
        (id: 'q1', answer: QuestionAnswer(selected: ['A'])),
      ]).toJson(),
    ));
  } catch (e) {
    questionError = e;
  }
  print('question \$events/result: ${questionError ?? 'accepted'}');

  client.dispose();
  print('== respond check done ==');
}
