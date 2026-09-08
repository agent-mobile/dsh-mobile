/// List the host's model catalog with capability flags, to find which models
/// accept image input. Usage: dart run tool/models_probe.dart <url> <token>
library;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';

Future<void> main(List<String> args) async {
  final base = Uri.parse(args.isNotEmpty ? args[0] : 'http://127.0.0.1:3080');
  final token = args.length > 1 ? args[1] : 'your-token';
  final client = DshApiClient(baseUrl: base, token: token);
  final result = await client.callUnary(
    'session/modelCatalog',
    const {},
    (value) => value,
  );
  switch (result) {
    case RpcResultErr(:final error):
      // ignore: avoid_print
      print('ERR ${error.code.wire}: ${error.message}');
      // ignore: avoid_print
      print('data: ${error.details}');
    case RpcResultOk(:final value):
      // ignore: avoid_print
      print('models: $value');
  }
  client.dispose();
}
