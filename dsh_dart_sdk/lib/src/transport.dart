/// HTTP/WebSocket transport for the dsh mobile-gateway `/m/api` surface.
///
/// Mirrors the TypeScript `AbstractApiClient`/`WebApiClient`: unary calls POST
/// `<prefix>/<method>` with a `client-request` and parse the `server-response`;
/// respond POSTs `<prefix>/respond`; the two event streams are downlink-only
/// WebSockets at `<prefix>/events.mux` and `<prefix>/events.host`. Bearer-token
/// authentication rides every HTTP request and both WebSocket handshakes.
///
/// [apiPrefix] defaults to `/m/api` (the dsh-mobile-gateway plugin's
/// token-gated surface); pass `/api` to talk to a host that composes its own
/// auth gate on the official surface instead.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart' as ws_io;
import 'package:web_socket_channel/web_socket_channel.dart' show WebSocketChannel;

import 'wire.dart';

/// The single `$events` application-event downlink: a multiplexed logical
/// stream on the host's one `/api/remote.mux` WebSocket.
///
/// 0.1.2 collapsed 0.1.1's two WebSocket downlinks (`events.mux` +
/// `events.host`) into this one logical stream. Frames are [RemoteEventFrame]s
/// (`ready`/`emit`/`waterfall`/`cancel`), not 0.1.1's `ServerRequest`s.
///
/// One instance = one socket + one opened `$events` stream. [frames] is a
/// broadcast stream so several consumers (state fold, session list, open chat)
/// can subscribe. [clientId] is set once the `ready` frame arrives and is
/// required to answer waterfalls via [DshApiClient.respondEvent].
abstract class EventStream {
  /// Parsed `$events` downlink frames.
  Stream<RemoteEventFrame> get frames;

  /// The generation id from the `ready` frame; null until it arrives.
  String? get clientId;

  /// Close the underlying socket and stop the stream.
  Future<void> close();
}

/// A transport exception carrying the HTTP status when one applies.
class TransportException implements Exception {
  const TransportException(this.message, {this.status});

  final String message;
  final int? status;

  @override
  String toString() => 'TransportException($message${status != null ? ', status $status' : ''})';
}

/// Client for the dsh host `/m/api` surface.
class DshApiClient {
  DshApiClient({
    required this.baseUrl,
    required this.token,
    http.Client? httpClient,
    this.apiPrefix = '/m/api',
    this.deviceId,
    this.deviceName,
    Duration unaryTimeout = const Duration(seconds: 30),
  })  : _http = httpClient ?? http.Client(),
        _unaryTimeout = unaryTimeout;

  /// Base origin, e.g. `http://192.168.1.5:3080`.
  final Uri baseUrl;

  /// Bearer token presented on every request and handshake.
  final String token;

  /// URL path prefix every call rides under: `/m/api` for the
  /// dsh-mobile-gateway plugin (default), `/api` for a host-side gate.
  final String apiPrefix;

  /// Stable device identity reported as `x-dsh-device` so the gateway's
  /// management page can list and block this install; null falls back to the
  /// client IP.
  final String? deviceId;

  /// Friendly device name reported as `x-dsh-device-name`.
  final String? deviceName;

  final http.Client _http;
  final Duration _unaryTimeout;

  /// Device-identity headers, present only when configured.
  Map<String, String> get _deviceHeaders => {
        if (deviceId != null) 'x-dsh-device': deviceId!,
        if (deviceName != null) 'x-dsh-device-name': deviceName!,
      };

  /// Call one unary method. Throws [TransportException] on transport failure;
  /// business failures come back as [RpcResultErr]. [timeout] overrides the
  /// client default per call (history carries large transcripts and relaxes it).
  ///
  /// [method] is the 0.1.2 slash endpoint (`session/list`); [args] is the
  /// named-argument object the host validates (sent as `payload.args`).
  Future<RpcResult<T>> callUnary<T>(
    String method,
    Map<String, Object?> args,
    T Function(Object?) decodeValue, {
    Duration? timeout,
  }) async {
    final rpcId = mintRpcId();
    final request = ClientRequest(rpcId: rpcId, method: method, args: args);
    final uri = baseUrl.replace(path: '$apiPrefix/$method');
    final http.Response response;
    try {
      response = await _http
          .post(uri, headers: _headers(), body: jsonEncode(request.toJson()))
          .timeout(timeout ?? _unaryTimeout);
    } catch (error) {
      throw TransportException('unary $method failed: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TransportException(
        'unary $method answered HTTP ${response.statusCode}',
        status: response.statusCode,
      );
    }
    final parsed = ServerResponse.parse(response.body, decodeValue);
    if (parsed.rpcId != rpcId) {
      throw TransportException('rpcId mismatch for $method: sent $rpcId, got ${parsed.rpcId}');
    }
    return parsed.result;
  }

  /// Answer an answerable `$events` waterfall (approval/question) by posting a
  /// [RemoteEventResult] to the `$events/result` endpoint. 0.1.2 replaced
  /// 0.1.1's `/api/respond` with this; [clientId] is the generation id from
  /// the stream's `ready` frame, [eventId] the pending-interaction id from the
  /// `waterfall`. The result rides the shared unary envelope: the host's
  /// `/api` carrier validates every POST as a `client-request` whose payload
  /// carries exactly one `args` field — the raw [RemoteEventResult].
  Future<void> respondEvent(RemoteEventResult result) async {
    final request =
        ClientRequest(rpcId: mintRpcId(), method: '\$events/result', args: result.toJson());
    final uri = baseUrl.replace(path: '$apiPrefix/\$events/result');
    final http.Response response;
    try {
      response = await _http
          .post(uri, headers: _headers(), body: jsonEncode(request.toJson()))
          .timeout(_unaryTimeout);
    } catch (error) {
      throw TransportException('\$events/result failed: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TransportException(
        '\$events/result answered HTTP ${response.statusCode}',
        status: response.statusCode,
      );
    }
    final parsed = ServerResponse.parse(response.body, (raw) => raw);
    if (parsed.rpcId != request.rpcId) {
      throw TransportException(
        'rpcId mismatch for \$events/result: sent ${request.rpcId}, got ${parsed.rpcId}',
      );
    }
    final outcome = parsed.result;
    if (outcome is RpcResultErr) {
      throw TransportException(
        '\$events/result rejected: ${outcome.error.code} ${outcome.error.message}',
      );
    }
  }

  /// Open the single `$events` application-event downlink on the host's one
  /// `/api/remote.mux` WebSocket.
  ///
  /// The socket is a logical-stream multiplexer: we open exactly one logical
  /// stream, `$events`, with the empty standard payload. Every `item` frame for
  /// that streamId decodes to a [RemoteEventFrame]; `end`/`error` close the
  /// stream.
  Future<EventStream> openEvents() async {
    final wsUri = baseUrl.replace(
      path: '$apiPrefix/remote.mux',
      scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws',
    );
    final channel = await _connectWebSocket(wsUri);
    final streamId = mintRpcId();
    // Broadcast: several consumers subscribe to the same downlink. A
    // single-subscription controller would throw "Stream has already been
    // listened to" the moment a second widget subscribed.
    final controller = StreamController<RemoteEventFrame>.broadcast();
    final _WebSocketEventStream state = _WebSocketEventStream(channel, controller);
    final sub = channel.stream.listen(
      (data) {
        if (data is! String) return; // binary frames are a protocol violation; drop
        try {
          final message = RemoteStreamServerMessage.parse(data);
          if (message.streamId != streamId) return; // other logical streams (future)
          switch (message.type) {
            case 'item':
              if (message.value == null) return;
              final frame = RemoteEventFrame.fromJson(message.value);
              if (frame.type == 'ready' && frame.clientId != null) state.noteReady(frame.clientId);
              controller.add(frame);
            case 'error':
              if (!controller.isClosed) {
                controller.addError(TransportException(
                  '\$events stream error: ${message.error?['message'] ?? 'unknown'}',
                ));
              }
            case 'end':
              if (!controller.isClosed) controller.close();
            default:
              break;
          }
        } on FormatException {
          // One malformed frame must not kill the stream; gap detection covers it.
        }
      },
      onError: (Object error, StackTrace st) {
        if (!controller.isClosed) controller.addError(error, st);
      },
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
      cancelOnError: true,
    );
    state._sub = sub;
    // Open the $events logical stream (empty standard payload).
    final open = RemoteStreamClientMessage.open(
      streamId: streamId,
      endpoint: '\$events',
      payload: const {'args': <String, Object?>{}},
    );
    channel.sink.add(jsonEncode(open.toJson()));
    return state;
  }

  /// Open one arbitrary logical stream on a fresh `/api/remote.mux` socket and
  /// yield its `item` values raw (the caller decodes them).
  ///
  /// Used for per-session `session/follow` (the 0.1.2 transcript live channel;
  /// 0.1.1's global `session/event` push no longer exists). [endpoint] is the
  /// Remote stream name (e.g. `session/follow`); [payload] is the open args
  /// (e.g. `{'args': {'address': ..., 'throughSeq': ...}}`). Each yielded item
  /// is the decoded JSON of one stream value (a `SessionFollowFrame`).
  Future<LogicalStream> openLogicalStream(String endpoint, Map<String, Object?> payload) async {
    final wsUri = baseUrl.replace(
      path: '$apiPrefix/remote.mux',
      scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws',
    );
    final channel = await _connectWebSocket(wsUri);
    final streamId = mintRpcId();
    final controller = StreamController<Object?>.broadcast();
    final sub = channel.stream.listen(
      (data) {
        if (data is! String) return;
        try {
          final message = RemoteStreamServerMessage.parse(data);
          if (message.streamId != streamId) return;
          switch (message.type) {
            case 'item':
              controller.add(message.value);
            case 'error':
              if (!controller.isClosed) {
                controller.addError(TransportException(
                  '$endpoint stream error: ${message.error?['message'] ?? 'unknown'}',
                ));
              }
            case 'end':
              if (!controller.isClosed) controller.close();
            default:
              break;
          }
        } on FormatException {
          // One malformed frame must not kill the stream.
        }
      },
      onError: (Object error, StackTrace st) {
        if (!controller.isClosed) controller.addError(error, st);
      },
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
      cancelOnError: true,
    );
    final open = RemoteStreamClientMessage.open(
      streamId: streamId,
      endpoint: endpoint,
      payload: payload,
    );
    channel.sink.add(jsonEncode(open.toJson()));
    return _LogicalStream(channel, controller, sub);
  }

  Future<WebSocketChannel> _connectWebSocket(Uri uri) async {
    // IOWebSocketChannel.connect attaches the Authorization header to the
    // dart:io WebSocket handshake, exactly what the host's upgrade guard reads.
    return ws_io.IOWebSocketChannel.connect(
      uri,
      headers: {
        'Host': '${uri.host}:${uri.port}',
        'Authorization': 'Bearer $token',
        ..._deviceHeaders,
      },
    );
  }

  Map<String, String> _headers() => {
        'content-type': 'application/json',
        // Request a fresh connection per unary call: the dsh webserver closes
        // idle keep-alive sockets, and dart:io's IOClient reuse of a severed
        // socket surfaces as intermittent 10053 resets. A per-call connection
        // trades a little latency for reliable delivery.
        'connection': 'close',
        'Host': '${baseUrl.host}:${baseUrl.port}',
        'Authorization': 'Bearer $token',
        ..._deviceHeaders,
      };

  /// Close the underlying HTTP client.
  void dispose() {
    _http.close();
  }
}

class _WebSocketEventStream implements EventStream {
  _WebSocketEventStream(this._channel, this._controller);

  final WebSocketChannel _channel;
  final StreamController<RemoteEventFrame> _controller;
  late final StreamSubscription<dynamic> _sub;

  String? _clientId;

  @override
  String? get clientId => _clientId;

  /// Record the generation id when a `ready` frame passes the broadcast.
  void noteReady(String? clientId) => _clientId = clientId;

  @override
  Stream<RemoteEventFrame> get frames => _controller.stream;

  @override
  Future<void> close() async {
    await _sub.cancel();
    await _channel.sink.close();
    if (!_controller.isClosed) await _controller.close();
  }
}

/// One opened arbitrary logical stream (e.g. a per-session `session/follow`).
/// [items] yields the raw decoded JSON of each stream value.
abstract class LogicalStream {
  Stream<Object?> get items;

  Future<void> close();
}

class _LogicalStream implements LogicalStream {
  _LogicalStream(this._channel, this._controller, this._sub);

  final WebSocketChannel _channel;
  final StreamController<Object?> _controller;
  final StreamSubscription<dynamic> _sub;

  @override
  Stream<Object?> get items => _controller.stream;

  @override
  Future<void> close() async {
    await _sub.cancel();
    await _channel.sink.close();
    if (!_controller.isClosed) await _controller.close();
  }
}
