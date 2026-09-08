/// Test fixtures for the 0.1.2 `session/follow` live transcript channel:
/// a controllable logical stream plus snapshot-frame builders, installed via
/// `ConnectionController.installFollowForTest` so bootstrap exercises the
/// same fold path as a live host.
library;

import 'dart:async';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:dsh_mobile_app/state/connection_controller.dart';

/// A controllable follow stream: push frames, then close.
class TestFollowStream extends LogicalStream {
  final StreamController<Object?> _controller = StreamController<Object?>.broadcast();

  @override
  Stream<Object?> get items => _controller.stream;

  void add(Object? frame) => _controller.add(frame);

  @override
  Future<void> close() async {
    await _controller.close();
  }
}

/// One follow `snapshot` frame carrying [entries] as event records.
Map<String, Object?> snapshotFrame({
  required List<HistoryEntry> entries,
  int cursor = 0,
  bool hasMore = false,
  Map<String, Object?>? projections,
}) =>
    {
      'type': 'snapshot',
      'cursor': cursor,
      'records': [
        for (final entry in entries)
          {
            'type': 'event',
            'event': {
              'seq': entry.event.seq,
              'type': entry.event.type,
              'time': entry.event.time,
              'data': entry.event.data,
            },
          },
      ],
      'hasMore': hasMore,
      if (projections != null) 'projections': projections,
    };

/// Install one follow stream for [sessionId] replaying [snapshot].
void installSnapshot(
  ConnectionController connection,
  String sessionId,
  Map<String, Object?> snapshot,
) {
  final stream = TestFollowStream();
  // Install first (starts listening), then push: the broadcast controller
  // drops frames pushed before any listener attached.
  connection.installFollowForTest(sessionId, stream);
  stream.add(snapshot);
}

/// Install an empty follow snapshot (no history, nothing older).
void installEmptySnapshot(ConnectionController connection, String sessionId) {
  installSnapshot(connection, sessionId, snapshotFrame(entries: const []));
}
