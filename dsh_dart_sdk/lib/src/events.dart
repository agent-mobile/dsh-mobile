/// Session-event vocabulary for the 0.1.2 `$events` downlink and history pages.
///
/// The 0.1.2 host forwards application events over a single logical `$events`
/// stream (see [RemoteEventFrame]); each `emit` frame names a Cordis event and
/// carries it positionally in `args`. This module decodes the session-event
/// vocabulary shared by live `emit`s and the `session/page` history records.
library;

import 'dart:convert';

/// A raw session event as carried by `session/event` frames and history pages.
///
/// The event vocabulary mirrors `SessionEventMap`; `type` is the discriminant
/// and `data` carries the type-specific fields (turn/step/chunk/message/tool).
class SessionEvent {
  const SessionEvent({
    required this.seq,
    required this.type,
    required this.time,
    required this.data,
  });

  /// Monotonic sequence, the replay and pagination authority.
  final int seq;

  /// Event type, e.g. `turn/start`, `user/message`, `assistant/chunk`,
  /// `tool/call`, `todo/write`.
  final String type;

  /// Epoch ms timestamp.
  final int time;

  /// Type-specific fields.
  final Map<String, Object?> data;

  factory SessionEvent.fromJson(Map<String, Object?> json) {
    final seq = json['seq'];
    final type = json['type'];
    final time = json['time'];
    if (seq is! num || type is! String || time is! num) {
      throw const FormatException('session event lacks seq/type/time');
    }
    return SessionEvent(
      seq: seq.toInt(),
      type: type,
      time: time.toInt(),
      data: json['data'] is Map ? Map<String, Object?>.from(json['data']! as Map) : const {},
    );
  }
}

/// One history page entry: the raw event plus an optional host-computed render
/// intent for tool events.
class HistoryEntry {
  const HistoryEntry(this.event, this.view);

  final SessionEvent event;
  final Map<String, Object?>? view;
}

/// A user message on the model-visible surface: `user/message` event data.
class UserMessage {
  const UserMessage({required this.source, required this.content, this.rpcId, this.clientTimeZone});

  /// Message source: `user` (direct human), `agent` (injected context), or a
  /// goal continuation round.
  final String source;

  /// Content blocks (text, image refs, tool uses).
  final List<Map<String, Object?>> content;

  /// The originating prompt's rpcId, present when sent from the UI; used to
  /// reconcile the optimistic echo.
  final String? rpcId;

  final String? clientTimeZone;
}

/// An assembled assistant message: `assistant/message` event data.
class AssistantMessage {
  const AssistantMessage({required this.content, this.usage});

  final List<Map<String, Object?>> content;
  final Map<String, Object?>? usage;
}

/// Stream chunk: incremental text of an assistant turn (`assistant/chunk`).
class StreamChunk {
  const StreamChunk(this.content, {this.reasoning});

  final List<Map<String, Object?>> content;
  final Map<String, Object?>? reasoning;
}

/// Decode helper: read an event's `data` as a typed map (tolerant).
Map<String, Object?> eventData(SessionEvent event) => event.data;

/// JSON decode helper shared by frame parsing.
Object? decodeJson(String source) => jsonDecode(source);
