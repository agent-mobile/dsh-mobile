/// Wire-protocol contract mirroring the dsh host 0.1.2 `/api` surface.
///
/// Two planes:
///
/// **Unary RPC** — `ClientRequest` / `ServerResponse` over
/// `POST /api/<ns>/<method>` (slash endpoint, not 0.1.1's dotted form). The
/// request body's `payload` is exactly one `args` object:
/// `{type:'client-request', rpcId, method:'<ns>/<method>', payload:{args:{...}}}`.
///
/// **Event plane** — a single logical stream multiplexer on the one
/// `/api/remote.mux` WebSocket. The client opens a logical stream with
/// `{type:'open', streamId, endpoint, payload}`; the host answers with
/// `{type:'item'|'end'|'error', streamId, ...}` frames. The application event
/// downlink is the `$events` stream, whose items are `RemoteEventDownlinkFrame`
/// (`ready` / `emit` / `waterfall` / `cancel`). Answerable interactions
/// (`waterfall`) are answered over `POST /api/$events/result` with a
/// `RemoteEventResult` — not 0.1.1's `/api/respond`.
library;

import 'dart:convert';
import 'dart:math';

/// Correlation id: minted by the initiator on a request, echoed by the
/// matching response. Implementations mint UUIDs.
typedef RpcId = String;

/// Error code → details map, the closed set mirrored from
/// `RpcErrorDetailsMap`. Every code the host can answer is listed so a client
/// can switch exhaustively.
enum RpcErrorCode {
  badRequest('bad-request'),
  cancelled('cancelled'),
  sessionNotFound('session-not-found'),
  modelUnavailable('model-unavailable'),
  sessionConflict('session-conflict'),
  invalidTimeZone('invalid-time-zone'),
  workspaceAttachFailed('workspace-attach-failed'),
  workspaceNotFound('workspace-not-found'),
  workspaceInvalidPath('workspace-invalid-path'),
  workspaceNameConflict('workspace-name-conflict'),
  workspaceMoveInvalid('workspace-move-invalid'),
  directoryUnreadable('directory-unreadable'),
  directoryExists('directory-exists'),
  directoryCreateFailed('directory-create-failed'),
  directoryPickerUnavailable('directory-picker-unavailable'),
  agentPresetReadOnly('agent-preset-read-only'),
  agentPresetLocked('agent-preset-locked'),
  agentPresetConflict('agent-preset-conflict'),
  agentPresetNotFound('agent-preset-not-found'),
  agentPresetInvalid('agent-preset-invalid'),
  agentBusy('agent-busy'),
  attachmentError('attachment-error'),
  queueItemNotFound('queue-item-not-found'),
  steerUnavailable('steer-unavailable'),
  commandError('command-error'),
  unknownCommand('unknown-command'),
  settingsRejected('settings-rejected'),
  settingsNotExposed('settings-not-exposed'),
  settingsConflict('settings-conflict'),
  credentialRejected('credential-rejected'),
  modelDiscoveryFailed('model-discovery-failed'),
  titleInvalid('title-invalid'),
  forkUnavailable('fork-unavailable'),
  subagentParentUnavailable('subagent-parent-unavailable'),
  subagentNotFound('subagent-not-found'),
  subagentCatalogDiagnostic('subagent-catalog-diagnostic'),
  subagentNotResumable('subagent-not-resumable'),
  subagentUnauthorized('subagent-unauthorized'),
  subagentDeliveryUnavailable('subagent-delivery-unavailable'),
  internal('internal');

  const RpcErrorCode(this.wire);

  /// The wire string as it travels in `code`.
  final String wire;

  /// Parse a wire code string; unknown codes map to [internal].
  static RpcErrorCode fromWire(String value) {
    for (final code in RpcErrorCode.values) {
      if (code.wire == value) return code;
    }
    return RpcErrorCode.internal;
  }
}

/// One business error: code discriminant plus message and details. `details`
/// is an opaque JSON object; typed access lives with the owning domain.
class RpcError {
  const RpcError({required this.code, required this.message, this.details = const {}});

  /// Wire discriminant.
  final RpcErrorCode code;

  /// Human-readable message from the host.
  final String message;

  /// Optional structured details (JSON object).
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => {
        'code': code.wire,
        'message': message,
        'details': details,
      };

  /// Parse an error object; tolerant of unknown codes and missing fields.
  factory RpcError.fromJson(Map<String, Object?> json) {
    final rawCode = json['code'];
    return RpcError(
      code: rawCode is String ? RpcErrorCode.fromWire(rawCode) : RpcErrorCode.internal,
      message: json['message'] is String ? json['message'] as String : '',
      details: json['details'] is Map ? Map<String, Object?>.from(json['details']! as Map) : const {},
    );
  }
}

/// Success/failure result: the result slot of every response.
sealed class RpcResult<T> {
  const RpcResult();
}

/// Successful result carrying the decoded value.
class RpcResultOk<T> extends RpcResult<T> {
  const RpcResultOk(this.value);
  final T value;
}

/// Failed result carrying the business error.
class RpcResultErr<T> extends RpcResult<T> {
  const RpcResultErr(this.error);
  final RpcError error;
}

/// Client-initiated unary call (POST `/api/<ns>/<method>` body).
///
/// `method` is the 0.1.2 slash endpoint (`session/list`), which must equal the
/// URL path segment the host derives; the host 400s a mismatch. `args` is the
/// named-argument object the endpoint owner validates — 0.1.2 wraps it as
/// `payload.args` (exactly one `args` key), so [payload] carries only `args`.
class ClientRequest {
  const ClientRequest({required this.rpcId, required this.method, required this.args});

  final RpcId rpcId;

  /// Slash endpoint, e.g. `session/list`.
  final String method;

  /// Named arguments; serialized as `payload: {args: ...}`.
  final Map<String, Object?> args;

  Map<String, Object?> toJson() => {
        'type': 'client-request',
        'rpcId': rpcId,
        'method': method,
        'payload': {'args': args},
      };
}

/// Response to a [ClientRequest] (HTTP response body); `rpcId` echoes.
class ServerResponse<T> {
  const ServerResponse({required this.rpcId, required this.result});

  final RpcId rpcId;
  final RpcResult<T> result;

  /// Parse the envelope, then decode the ok value with [decodeValue].
  /// Malformed or error results parse without the value decoder.
  factory ServerResponse.parse(
    String body,
    T Function(Object?) decodeValue,
  ) {
    final json = jsonDecode(body);
    if (json is! Map) throw const FormatException('server-response is not an object');
    final rpcId = json['rpcId'];
    if (rpcId is! String) throw const FormatException('server-response lacks string rpcId');
    final rawResult = json['result'];
    if (rawResult is! Map) throw const FormatException('server-response lacks result');
    final ok = rawResult['ok'];
    if (ok == true) {
      return ServerResponse(rpcId: rpcId, result: RpcResultOk(decodeValue(rawResult['value'])));
    }
    final error = rawResult['error'];
    if (error is! Map) throw const FormatException('server-response lacks error');
    return ServerResponse(
      rpcId: rpcId,
      result: RpcResultErr(RpcError.fromJson(Map<String, Object?>.from(error))),
    );
  }
}

/// Server-initiated frame on a downlink stream. Answerable interactions
/// (approval/question requested — stable rpcId, reused on replay) and pure
/// pushes (session/event etc.) share this shape.
class ServerRequest {
  const ServerRequest({required this.rpcId, required this.method, required this.payload});

  final RpcId rpcId;
  final String method;
  final Object? payload;

  /// Parse one downlink frame envelope.
  factory ServerRequest.parse(String body) {
    final json = jsonDecode(body);
    if (json is! Map) throw const FormatException('server-request is not an object');
    final rpcId = json['rpcId'];
    final method = json['method'];
    if (rpcId is! String || method is! String) {
      throw const FormatException('server-request lacks string rpcId or method');
    }
    return ServerRequest(rpcId: rpcId, method: method, payload: json['payload']);
  }
}

/// Client's answer to an answerable [ServerRequest] (POST `/api/respond` body).
class ClientResponse {
  const ClientResponse({required this.rpcId, required this.result});

  final RpcId rpcId;
  final RpcResult<Object?> result;

  Map<String, Object?> toJson() => switch (result) {
        RpcResultOk(:final value) => {
            'type': 'client-response',
            'rpcId': rpcId,
            'result': {'ok': true, 'value': value},
          },
        RpcResultErr(:final error) => {
            'type': 'client-response',
            'rpcId': rpcId,
            'result': {'ok': false, 'error': error.toJson()},
          },
      };
}

/// Carrier receipt (not an RpcMessage): the HTTP response body of the POST
/// carrying a client-response.
class RpcReceipt {
  const RpcReceipt({required this.accepted, this.reason});

  final bool accepted;

  /// Present when [accepted] is false: `not-pending` or `bad-response`.
  final String? reason;

  static RpcReceipt parse(String body) {
    final json = jsonDecode(body);
    if (json is! Map) throw const FormatException('rpc receipt is not an object');
    final accepted = json['accepted'];
    if (accepted == true) return const RpcReceipt(accepted: true);
    final reason = json['reason'];
    return RpcReceipt(
      accepted: false,
      reason: reason is String ? reason : 'bad-response',
    );
  }
}

/// One client→host message on a [remote.mux](../transport/transport.dart)
/// logical stream: open a stream by `endpoint`, or cancel one by id.
class RemoteStreamClientMessage {
  const RemoteStreamClientMessage.open({
    required this.streamId,
    required this.endpoint,
    required this.payload,
  }) : type = 'open';

  const RemoteStreamClientMessage.cancel({required this.streamId, this.endpoint, this.payload})
      : type = 'cancel';

  final String type;
  final String streamId;
  final String? endpoint;
  final Object? payload;

  Map<String, Object?> toJson() => switch (type) {
        'open' => {
            'type': 'open',
            'streamId': streamId,
            'endpoint': endpoint,
            'payload': payload,
          },
        _ => {'type': 'cancel', 'streamId': streamId},
      };
}

/// One host→client frame on a [remote.mux](../transport/transport.dart)
/// logical stream: an item, an error, or end-of-stream.
class RemoteStreamServerMessage {
  const RemoteStreamServerMessage({required this.type, required this.streamId, this.value, this.error});

  /// `item`, `error`, or `end`.
  final String type;
  final String streamId;

  /// Present on `item`: the decoded stream value.
  final Object? value;

  /// Present on `error`: `{code, message, details}`.
  final Map<String, Object?>? error;

  factory RemoteStreamServerMessage.parse(String text) {
    final json = jsonDecode(text);
    if (json is! Map) throw const FormatException('stream frame is not an object');
    final type = json['type'];
    final streamId = json['streamId'];
    if (type is! String || streamId is! String) {
      throw const FormatException('stream frame lacks type/streamId');
    }
    final error = json['error'];
    return RemoteStreamServerMessage(
      type: type,
      streamId: streamId,
      value: json['value'],
      error: error is Map ? Map<String, Object?>.from(error) : null,
    );
  }
}

/// One item on the `$events` application-event downlink (a `RemoteStreamServerMessage`
/// with `type:'item'` whose [value] decodes to this).
///
/// Four shapes, discriminated by [type]:
/// * `ready` — opening frame binding later results to this generation
///   ([clientId], host [home]).
/// * `emit` — a pushed Cordis event: [event] name + positional [args].
/// * `waterfall` — an answerable interaction: [event] name, [eventId],
///   [agentId], [request] object. Answered via [RemoteEventResult].
/// * `cancel` — cancellation of a pending [waterfall] under [eventId].
class RemoteEventFrame {
  const RemoteEventFrame._({
    required this.type,
    this.clientId,
    this.home,
    this.event,
    this.args = const [],
    this.eventId,
    this.agentId,
    this.request,
  });

  final String type;

  /// `ready` only: this generation's client id (echoed on results).
  final String? clientId;

  /// `ready` only: host account home.
  final String? home;

  /// `emit`/`waterfall`: the Cordis event name (e.g. `session/event`).
  final String? event;

  /// `emit`: positional event arguments.
  final List<Object?> args;

  /// `waterfall`/`cancel`: the pending-interaction correlation id.
  final String? eventId;

  /// `waterfall`: the scoped agent identity.
  final String? agentId;

  /// `waterfall`: the projected request object (fields minus `agent`/`signal`).
  final Map<String, Object?>? request;

  /// Decode one `$events` stream item value (the `value` of an `item` frame).
  factory RemoteEventFrame.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('\$events item is not an object');
    final json = Map<String, Object?>.from(value);
    final type = json['type'];
    if (type is! String) throw const FormatException('\$events item lacks type');
    final argsRaw = json['args'];
    final request = json['request'];
    final homeObj = json['home'];
    String? home;
    if (homeObj is Map && homeObj['home'] is String) home = homeObj['home'] as String;
    return RemoteEventFrame._(
      type: type,
      clientId: json['clientId'] is String ? json['clientId'] as String : null,
      home: home,
      event: json['event'] is String ? json['event'] as String : null,
      args: argsRaw is List ? argsRaw : const [],
      eventId: json['eventId'] is String ? json['eventId'] as String : null,
      agentId: json['agentId'] is String ? json['agentId'] as String : null,
      request: request is Map ? Map<String, Object?>.from(request) : null,
    );
  }
}

/// Client response to one answerable `$events` waterfall delivery
/// (POST `/api/$events/result` body).
class RemoteEventResult {
  const RemoteEventResult._({required this.clientId, required this.eventId, required this.outcome});

  final String clientId;
  final String eventId;
  final Map<String, Object?> outcome;

  /// Answer a waterfall with a value (or no value).
  factory RemoteEventResult.result({required String clientId, required String eventId, Object? value}) =>
      RemoteEventResult._(
        clientId: clientId,
        eventId: eventId,
        outcome: value == null ? {'kind': 'result'} : {'kind': 'result', 'value': value},
      );

  /// Advance the waterfall chain without producing a value.
  factory RemoteEventResult.next({required String clientId, required String eventId}) =>
      RemoteEventResult._(clientId: clientId, eventId: eventId, outcome: {'kind': 'next'});

  /// Reject a waterfall with a wire-safe error.
  factory RemoteEventResult.rejected({
    required String clientId,
    required String eventId,
    required String name,
    required String message,
    String? code,
    Object? details,
  }) =>
      RemoteEventResult._(
        clientId: clientId,
        eventId: eventId,
        outcome: {
          'kind': 'rejected',
          'error': {
            'name': name,
            'message': message,
            if (code != null) 'code': code,
            if (details != null) 'details': details,
          },
        },
      );

  Map<String, Object?> toJson() => {'clientId': clientId, 'eventId': eventId, 'outcome': outcome};
}

/// Mint a fresh correlation id (UUID v4) from the platform CSPRNG.
String mintRpcId() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// A domain-level failure wrapping a wire [RpcError].
class RpcDomainException implements Exception {
  const RpcDomainException(this.method, this.error);

  final String method;
  final RpcError error;

  @override
  String toString() => 'RpcDomainException($method: ${error.code.wire}) ${error.message}';
}
