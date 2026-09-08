import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
Future<void> main(List<String> args) async {
  final client = DshApiClient(baseUrl: Uri.parse('http://127.0.0.1:3080'), token: args[0]);
  for (final id in args.skip(1)) {
    try {
      await client.callUnary('session/cancel', {'_request': {'sessionId': id}}, (v) => v);
      print('cancelled $id');
    } catch (e) {
      print('cancel $id: $e');
    }
  }
  client.dispose();
}
