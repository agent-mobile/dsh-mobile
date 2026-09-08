/// Transport tests: the per-call timeout override on [DshApiClient.callUnary]
/// and the relaxed history budget.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

/// Echo client that answers each unary request after a configurable delay by
/// reflecting the request's rpcId (the protocol demands an exact echo).
class _EchoClient extends http.BaseClient {
  _EchoClient({required this.respondAfter});

  final Duration respondAfter;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (respondAfter > Duration.zero) {
      await Future<void>.delayed(respondAfter);
    }
    final bytes = await request.finalize().toBytes();
    final body = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    final response = {
      'rpcId': body['rpcId'],
      'result': {'ok': true, 'value': {'echo': 1}},
    };
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(response))),
      200,
    );
  }
}

void main() {
  test('callUnary honors a per-call timeout override', () async {
    final client = DshApiClient(
      baseUrl: Uri.parse('http://fake:3080'),
      token: 't',
      httpClient: _EchoClient(respondAfter: const Duration(milliseconds: 50)),
    );

    // A shorter override fires the timeout (the default 30 s would succeed).
    await expectLater(
      client.callUnary('session.history', const {}, (value) => value,
          timeout: const Duration(milliseconds: 10)),
      throwsA(isA<TransportException>()),
    );

    // A matching override succeeds.
    final ok = await client.callUnary('session.history', const {}, (value) => value,
        timeout: const Duration(seconds: 1));
    expect(ok, isA<RpcResultOk>());

    client.dispose();
  });

  test('historyUnaryTimeout relaxes history to 60 s', () {
    expect(historyUnaryTimeout, const Duration(seconds: 60));
  });
}
