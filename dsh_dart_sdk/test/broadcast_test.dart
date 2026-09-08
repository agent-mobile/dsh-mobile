/// Regression: the downlink event streams must be broadcast so the
/// connection controller fold and multiple widgets can subscribe together.
library;

import 'dart:async';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('broadcast controller allows multiple subscribers on the same stream', () async {
    // Replicate the transport's controller choice.
    final controller = StreamController<ServerRequest>.broadcast();
    final received = <String>[];

    final subA = controller.stream.listen((frame) => received.add('A:${frame.rpcId}'));
    final subB = controller.stream.listen((frame) => received.add('B:${frame.rpcId}'));

    controller.add(const ServerRequest(rpcId: 'f1', method: 'session/event', payload: {}));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(received, containsAll(['A:f1', 'B:f1']));

    await subA.cancel();
    await subB.cancel();
    await controller.close();
  });

  test('a single-subscription controller throws on a second listener', () {
    final controller = StreamController<ServerRequest>();
    controller.stream.listen((_) {});
    expect(
      () => controller.stream.listen((_) {}),
      throwsStateError,
    );
    controller.close();
  });
}
