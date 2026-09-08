/// Session surface fold: accumulate raw session events into a message
/// transcript, mirroring the TypeScript client's fold. Deterministic and
/// replayable by `seq`.
library;

import 'events.dart';

/// One message on the folded surface.
sealed class SessionMessage {
  const SessionMessage({required this.seq, required this.time});
  final int seq;
  final int time;
}

/// One content block of an assistant message, mirroring the web client's
/// `AssistantBlock`. A step's blocks are folded from `assistant/chunk` deltas
/// in arrival order and replaced verbatim by the final `assistant/message`.
sealed class AssistantBlock {
  const AssistantBlock();
}

/// Visible answer text streamed as `text` deltas.
class AssistantTextBlock extends AssistantBlock {
  const AssistantTextBlock(this.text);
  final String text;
}

/// Chain-of-thought streamed as `reasoning` deltas.
class AssistantReasoningBlock extends AssistantBlock {
  const AssistantReasoningBlock(this.text);
  final String text;
}

/// A tool invocation requested by the model.
class AssistantToolCallBlock extends AssistantBlock {
  AssistantToolCallBlock({
    required this.callId,
    required this.name,
    required this.arguments,
    this.result,
    this.error,
  });

  final String callId;
  final String name;

  /// Raw arguments JSON exactly as the model produced it.
  final String arguments;

  /// Result text, absent while pending. Populated by `tool/result`.
  String? result;

  /// Optional error identity from a failed tool call.
  Map<String, Object?>? error;
}

/// Any non-text, non-reasoning, non-tool-call block (image, plugin-owned).
class AssistantOtherBlock extends AssistantBlock {
  const AssistantOtherBlock(this.block);
  final Map<String, Object?> block;
}

/// An assistant message assembled from `assistant/chunk` deltas and settled by
/// `assistant/message`.
class AssistantSessionMessage extends SessionMessage {
  AssistantSessionMessage({
    required super.seq,
    required super.time,
    required this.turn,
    required this.step,
  }) : super();

  final int turn;
  final int step;

  /// Content blocks in model arrival order, interleaving text and tool calls.
  final List<AssistantBlock> blocks = [];

  /// Whether the step is still streaming (no final `assistant/message` yet).
  bool streaming = true;

  /// Optional token usage reported by the adapter.
  Map<String, Object?>? usage;

  /// Tool calls on this step, in arrival order (a stable view over [blocks]).
  List<AssistantToolCallBlock> get toolCalls =>
      [for (final block in blocks) if (block is AssistantToolCallBlock) block];

  /// Joined answer text (tool calls and reasoning excluded).
  String get text => blocks
      .whereType<AssistantTextBlock>()
      .map((block) => block.text)
      .join();
}

/// A user-role message (direct prompt, injected context, or goal round).
class UserSessionMessage extends SessionMessage {
  const UserSessionMessage({
    required super.seq,
    required super.time,
    required this.source,
    required this.content,
    this.rpcId,
  }) : super();

  final String source;
  final List<Map<String, Object?>> content;
  final String? rpcId;
}

/// The folded surface of one session: ordered messages plus current turn/step.
class SessionSurface {
  SessionSurface({required this.sessionId});

  final String sessionId;

  final List<SessionMessage> messages = [];

  /// Latest `turn/start` seq, when a turn is open.
  int? openTurnSeq;

  /// Epoch ms time of the latest `turn/start`, when a turn is open. Used by
  /// the running-turn clock; null when the boundary is outside the loaded
  /// window (the caller falls back to mount time).
  int? openTurnStartTime;

  /// Latest `turn/end` seq.
  int? lastTurnEndSeq;

  /// Latest seen seq (watermark for reconnect and projections).
  int lastSeq = -1;

  /// Seq of the earliest loaded event in the window (the head). Null when
  /// nothing has been loaded yet. `fold` only appends tail-side events, so
  /// older history pages fold through a scratch surface and splice their
  /// messages to the front: this field is that path's pagination anchor and
  /// continuity check (a page must end immediately before it).
  int? windowHeadSeq;

  /// Fold one raw event. Idempotent under replay by seq: an event whose seq is
  /// not greater than [lastSeq] is ignored (a stale baseline must never
  /// overwrite a newer push).
  void fold(SessionEvent event) {
    if (event.seq <= lastSeq) return;
    lastSeq = event.seq;
    switch (event.type) {
      case 'turn/start':
        openTurnSeq = event.seq;
        openTurnStartTime = event.time;
      case 'turn/end':
        openTurnSeq = null;
        openTurnStartTime = null;
        lastTurnEndSeq = event.seq;
      case 'user/message':
        final source = event.data['source'];
        // Web parity (ui-chat message.ts): a wire source MAP whose kind is
        // not 'user' is injected context — the system-prompt plugin's
        // per-turn "Current runtime context…" snapshot, agent instructions,
        // goal rounds, compaction checkpoints — routed on the web to a
        // context lane the mobile chat does not surface, never a user
        // bubble. Legacy string sources predate the map shape and keep the
        // historical visible behavior.
        if (source is Map) {
          final kind = source['kind'];
          if (kind is String && kind.isNotEmpty && kind != 'user') break;
        }
        final content = event.data['content'];
        final rpcId = event.data['rpcId'];
        messages.add(UserSessionMessage(
          seq: event.seq,
          time: event.time,
          source: _messageSourceKind(source),
          content: content is List ? List<Map<String, Object?>>.from(content.cast()) : const [],
          rpcId: rpcId is String ? rpcId : null,
        ));
      case 'assistant/chunk':
        _foldChunk(event);
      case 'assistant/message':
        _finalizeAssistant(event);
      case 'tool/result':
        _foldToolResult(event);
      default:
        // Log-only or unrelated events (request/header, session/end-seed,
        // compaction, plugin-owned) do not participate in the surface.
        break;
    }
  }

  void _foldChunk(SessionEvent event) {
    final assistant = _currentAssistant(event);
    if (assistant == null) return;
    final chunk = event.data['chunk'];
    if (chunk is! Map) return;
    final type = chunk['type'];
    if (type is! String) return;
    final index = (chunk['index'] as num?)?.toInt() ?? 0;
    // Grow the block list to the delta's index, seeding an empty accumulator.
    while (assistant.blocks.length <= index) {
      assistant.blocks.add(const AssistantOtherBlock({}));
    }
    switch (type) {
      case 'block-start':
        // A concrete seed; superseded by the deltas or the block-end.
        final blockType = chunk['blockType'];
        assistant.blocks[index] = blockType == 'text'
            ? const AssistantTextBlock('')
            : blockType == 'reasoning'
                ? const AssistantReasoningBlock('')
                : AssistantOtherBlock({});
      case 'text-delta':
        final text = chunk['text'];
        if (text is! String) return;
        final previous = assistant.blocks[index];
        assistant.blocks[index] =
            AssistantTextBlock((previous is AssistantTextBlock ? previous.text : '') + text);
      case 'reasoning-delta':
        final text = chunk['text'];
        if (text is! String) return;
        final previous = assistant.blocks[index];
        assistant.blocks[index] =
            AssistantReasoningBlock((previous is AssistantReasoningBlock ? previous.text : '') + text);
      case 'tool-call-delta':
        final previous = assistant.blocks[index];
        final base = previous is AssistantToolCallBlock
            ? previous
            : AssistantToolCallBlock(callId: '', name: '', arguments: '');
        final id = chunk['id'];
        assistant.blocks[index] = AssistantToolCallBlock(
          callId: (base.callId.isNotEmpty ? base.callId : id is String ? id : ''),
          name: chunk['name'] is String ? chunk['name'] as String : base.name,
          arguments:
              base.arguments + (chunk['argumentsDelta'] is String ? chunk['argumentsDelta'] as String : ''),
          result: base.result,
          error: base.error,
        );
      case 'block-end':
        final block = chunk['block'];
        if (block is Map) assistant.blocks[index] = _toAssistantBlock(Map<String, Object?>.from(block));
        break;
      // 'usage' and 'finish' carry no block content; the final
      // assistant/message records usage for the step.
      case 'usage':
      case 'finish':
      default:
        break;
    }
  }

  void _finalizeAssistant(SessionEvent event) {
    final assistant = _currentAssistant(event);
    if (assistant == null) return;
    assistant.streaming = false;
    final message = event.data['message'];
    if (message is Map) {
      final content = message['content'];
      if (content is List) {
        // The final content is authoritative: it replaces the deltas.
        assistant.blocks
          ..clear()
          ..addAll([
            for (final block in content)
              if (block is Map) _toAssistantBlock(Map<String, Object?>.from(block)),
          ]);
      }
    }
    final usage = event.data['usage'];
    if (usage is Map) assistant.usage = Map<String, Object?>.from(usage);
  }

  void _foldToolResult(SessionEvent event) {
    final message = event.data['message'];
    if (message is! Map) return;
    final messageMap = Map<String, Object?>.from(message);
    // The correlation id lives on the result message (source.callId) or the
    // inner tool-result block (toolCallId), never at data top level.
    final callId = _resultCallId(messageMap);
    if (callId == null) return;
    final error = event.data['error'];
    final failed = error is Map;
    for (final m in messages) {
      if (m is! AssistantSessionMessage) continue;
      for (final block in m.blocks) {
        if (block is AssistantToolCallBlock && block.callId == callId) {
          block.result = _resultText(messageMap);
          if (failed) block.error = Map<String, Object?>.from(error);
        }
      }
    }
  }

  /// Resolve the call id a `tool/result` message belongs to.
  String? _resultCallId(Map<String, Object?> message) {
    final source = message['source'];
    final fromSource = source is Map ? source['callId'] : null;
    if (fromSource is String) return fromSource;
    final content = message['content'];
    if (content is List) {
      for (final block in content) {
        if (block is Map && block['toolCallId'] is String) {
          return block['toolCallId'] as String;
        }
      }
    }
    return null;
  }

  /// Extract the human-readable output of a `tool/result` message.
  String? _resultText(Map<String, Object?> message) {
    final content = message['content'];
    if (content is! List || content.isEmpty) return null;
    final first = content.first;
    if (first is! Map) return first.toString();
    // tool-result block: content is a list of blocks; join their text.
    final blocks = first['content'];
    if (blocks is List) {
      final buffer = StringBuffer();
      for (final block in blocks) {
        if (block is Map && block['text'] is String) buffer.write(block['text'] as String);
      }
      return buffer.toString();
    }
    return first['text'] is String ? first['text'] as String : null;
  }

  AssistantSessionMessage? _currentAssistant(SessionEvent event) {
    final turn = (event.data['turn'] as num?)?.toInt() ?? 0;
    final step = (event.data['step'] as num?)?.toInt() ?? 0;
    // Find the open assistant message for this turn/step, or append one.
    for (final message in messages.reversed) {
      if (message is AssistantSessionMessage &&
          message.turn == turn &&
          message.step == step) {
        return message;
      }
    }
    final created = AssistantSessionMessage(
      seq: event.seq,
      time: event.time,
      turn: turn,
      step: step,
    );
    messages.add(created);
    return created;
  }
}

/// Resolve the source kind of a `user/message` from its wire `source` value:
/// a `MessageSource` map (`{kind: ...}`, possibly `plugin`/`context`/`agent-
/// instructions`/`skill-catalog` for injected context) yields its `kind`; a
/// legacy string passes through; unreadable sources fall back to `user`.
String _messageSourceKind(Object? source) {
  if (source is String && source.isNotEmpty) return source;
  if (source is Map) {
    final kind = source['kind'];
    if (kind is String && kind.isNotEmpty) return kind;
  }
  return 'user';
}

/// Classify a final ContentBlock into its [AssistantBlock] form (web
/// `toAssistantBlock`).
AssistantBlock _toAssistantBlock(Map<String, Object?> block) {
  switch (block['type']) {
    case 'text':
      return AssistantTextBlock(block['text'] is String ? block['text'] as String : '');
    case 'reasoning':
      return AssistantReasoningBlock(block['text'] is String ? block['text'] as String : '');
    case 'image':
    case 'tool-result':
      return AssistantOtherBlock(block);
    case 'tool-call':
      final args = block['arguments'] ?? block['argsRaw'];
      return AssistantToolCallBlock(
        callId: block['callId'] is String ? block['callId'] as String : '',
        name: block['name'] is String ? block['name'] as String : '',
        arguments: args is String ? args : '',
      );
    default:
      return AssistantOtherBlock(block);
  }
}
