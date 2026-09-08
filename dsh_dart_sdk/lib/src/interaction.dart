/// Approval and user-question interaction domains.
///
/// Mirrors the TypeScript `approvals.ts` / `questions.ts` contract. Approval
/// requests and user questions arrive as answerable `server-request` frames on
/// the mux stream; the client answers via `POST /api/$events/result` keyed by
/// the generation id and the waterfall's event id. The posted value rides as
/// the waterfall's return value, so its shape must match the host answerer's
/// return type verbatim (a bare outcome string / a bare `{answers:[...]}`).
library;

import 'transport.dart';
import 'wire.dart';

/// One requested approval (a `$events` `waterfall` for `approval/request`).
///
/// 0.1.2 correlates the answer by the waterfall's [eventId] and the
/// generation's [clientId] (from the `ready` frame), not a frame rpcId. The
/// [request] carries the projected approval fields (`agent`/`signal` stripped
/// — the projection keeps only `{toolName, callId?, reason?}`, so the owning
/// session id is NOT in there; it rides on the frame's agent id and must be
/// passed via [sessionId]).
class ApprovalRequest {
  const ApprovalRequest({
    required this.clientId,
    required this.eventId,
    required this.request,
    this.sessionId,
  });

  /// The `$events` generation id (from the `ready` frame) needed to answer.
  final String clientId;

  /// The pending waterfall id (from the `waterfall` frame) needed to answer.
  final String eventId;

  /// The projected approval request object (`agent`/`signal` stripped).
  final Map<String, Object?> request;

  /// The session the waterfall belongs to (the frame's agent id). Null only
  /// for hand-built requests; answerers key their pending-entry cleanup on it.
  final String? sessionId;

  String? get approvalId => request['approvalId'] as String?;
  String? get toolName => request['toolName'] as String?;
  String? get callId => request['callId'] as String?;
  String? get reason => request['reason'] as String?;

  /// Build from one `waterfall` frame's [eventId], the generation [clientId],
  /// and the projected [request] object. [sessionId] is the frame's agent id.
  factory ApprovalRequest.fromWaterfall({
    required String clientId,
    required String eventId,
    required Map<String, Object?> request,
    String? sessionId,
  }) =>
      ApprovalRequest(
        clientId: clientId,
        eventId: eventId,
        request: request,
        sessionId: sessionId,
      );
}

/// The only outcomes a client may give (cancelled/unavailable are host-side).
enum ApprovalOutcome { allowedOnce, rejected }

/// An approval resolution: `approval/resolved` frame payload.
class ApprovalResolution {
  const ApprovalResolution({
    required this.sessionId,
    required this.approvalId,
    required this.outcome,
  });

  final String sessionId;
  final String approvalId;

  /// Host-side outcome: `allowed-once`, `rejected`, `cancelled`, or
  /// `unavailable`.
  final String outcome;

  factory ApprovalResolution.fromPayload(Map<String, Object?> payload) => ApprovalResolution(
        sessionId: payload['sessionId'] as String? ?? '',
        approvalId: payload['approvalId'] as String? ?? '',
        outcome: payload['outcome'] as String? ?? '',
      );
}

/// One question item inside an `ask_user_question` batch.
class QuestionItem {
  const QuestionItem({
    required this.id,
    required this.question,
    this.header,
    this.options = const [],
    this.multiSelect = false,
  });

  final String id;
  final String question;
  final String? header;
  final List<QuestionOption> options;
  final bool multiSelect;

  factory QuestionItem.fromJson(Map<String, Object?> json) {
    final rawOptions = json['options'];
    final options = rawOptions is List
        ? rawOptions
            .whereType<Map>()
            .map((option) => QuestionOption.fromJson(Map<String, Object?>.from(option)))
            .toList()
        : const <QuestionOption>[];
    return QuestionItem(
      id: json['id'] as String? ?? '',
      question: json['question'] as String? ?? '',
      header: json['header'] as String?,
      options: options,
      // The host serializes the TS `AskUserQuestionItem` as camelCase
      // `multiSelect`; keep the legacy snake_case key as a fallback.
      multiSelect: json['multiSelect'] == true || json['multi_select'] == true,
    );
  }
}

/// One selectable option within a question item.
class QuestionOption {
  const QuestionOption({required this.label, this.description});

  final String label;
  final String? description;

  factory QuestionOption.fromJson(Map<String, Object?> json) => QuestionOption(
        label: json['label'] as String? ?? '',
        description: json['description'] as String?,
      );
}

/// A pending `ask_user_question` batch (a `$events` `waterfall` for
/// `user-questions/request`). 0.1.2 correlates the answer by the waterfall's
/// [eventId] and the generation's [clientId].
class QuestionRequest {
  const QuestionRequest({required this.clientId, required this.eventId, required this.questions});

  /// The `$events` generation id (from the `ready` frame) needed to answer.
  final String clientId;

  /// The pending waterfall id (from the `waterfall` frame) needed to answer.
  final String eventId;

  final List<QuestionItem> questions;

  /// Build from one `waterfall` frame's projected `request` object. The batch
  /// rides under `request.questions`; [clientId]/[eventId] come from the frame.
  factory QuestionRequest.fromWaterfall({
    required String clientId,
    required String eventId,
    required Map<String, Object?> request,
  }) {
    final raw = request['questions'];
    final questions = raw is List
        ? raw.whereType<Map>().map((q) => QuestionItem.fromJson(Map<String, Object?>.from(q))).toList()
        : const <QuestionItem>[];
    return QuestionRequest(clientId: clientId, eventId: eventId, questions: questions);
  }
}

/// One answered question item, validated to mirror the host's rules: a
/// single-select item uses exactly one of [selected] / [custom]; a multi-select
/// item may carry both; custom text must be non-empty.
class QuestionAnswer {
  QuestionAnswer({this.selected = const [], this.custom});

  /// Option labels selected (single-select: exactly one).
  final List<String> selected;

  /// Free text for an "other" answer; single-select items use exactly one of
  /// selected or custom.
  final String? custom;

  /// JSON value for the wire answer.
  Map<String, Object?> toJson() => {
        if (selected.isNotEmpty) 'selected': selected,
        if (custom != null && custom!.isNotEmpty) 'custom': custom,
      };
}

/// One answered question in a batch: the question item id plus its answer.
typedef QuestionAnswerEntry = ({String id, QuestionAnswer answer});

/// The wire answer batch for one `ask` (`AskUserQuestionAnswer`).
class QuestionAnswerBatch {
  const QuestionAnswerBatch(this.answers);

  /// One entry per question item, in the request's question order: the host
  /// correlates the answer array positionally with the requested questions.
  final List<QuestionAnswerEntry> answers;

  Map<String, Object?> toJson() => {
        'answers': [
          for (final entry in answers)
            {
              'id': entry.id,
              // The host schema requires `selected` on every item; an empty
              // array is the valid "no option" answer (custom-only or skipped).
              'selected': entry.answer.selected,
              if (entry.answer.custom?.trim().isNotEmpty ?? false) 'custom': entry.answer.custom,
            },
        ],
      };
}

/// High-level interaction methods over the transport.
class DshInteractionApi {
  DshInteractionApi(this._client);

  final DshApiClient _client;

  /// Answer one approval `waterfall` delivered on the `$events` stream.
  ///
  /// 0.1.2 answers are posted to `/api/$events/result` keyed by the generation
  /// [request.clientId] (from the `ready` frame) and the pending
  /// [request.eventId] (from the `waterfall` frame). The posted value IS the
  /// waterfall's return value: the host's `ApprovalService` type-checks it
  /// against the outcome vocabulary verbatim and normalizes anything else
  /// (any wrapping object) to the fail-closed `'unavailable'`, so the value
  /// must be the bare outcome string — the web UI returns the same.
  Future<void> answerApproval({
    required ApprovalRequest request,
    required ApprovalOutcome outcome,
  }) async {
    await _client.respondEvent(RemoteEventResult.result(
      clientId: request.clientId,
      eventId: request.eventId,
      value: switch (outcome) {
        ApprovalOutcome.allowedOnce => 'allowed-once',
        ApprovalOutcome.rejected => 'rejected',
      },
    ));
  }

  /// Answer one user-question `waterfall` batch. The answer is one whole batch
  /// for the ask (never split per question), posted to `/api/$events/result`.
  /// The posted value IS the waterfall's return value — the host's
  /// `ask_user_question` tool reads `result.answers` off it directly, so the
  /// [QuestionAnswerBatch.toJson] object must ride bare (no `answer` wrapper).
  Future<void> answerQuestions({
    required QuestionRequest request,
    required QuestionAnswerBatch answer,
  }) async {
    await _client.respondEvent(RemoteEventResult.result(
      clientId: request.clientId,
      eventId: request.eventId,
      value: answer.toJson(),
    ));
  }
}
