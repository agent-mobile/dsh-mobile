/// Speech API client for the dsh-speech plugin's `/s/api` surface.
///
/// Provides health probing, audio transcription (ASR), and text-to-speech
/// synthesis (TTS) against the dsh-speech plugin's token-gated HTTP routes.
/// Synthesis has a batch form ([DshSpeechClient.synthesize]) and a streamed
/// form ([DshSpeechClient.synthesizeStream]) that yields audio chunks as
/// the server produces them. Live transcription sessions run over the
/// plugin's `/s/ws` WebSocket through [DshSpeechClient.openSession].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Client for the dsh-speech `/s/api` surface.
class DshSpeechClient {
  DshSpeechClient({required this.baseUrl, required this.token});

  /// Server origin, e.g. `http://192.168.1.5:3080`.
  final Uri baseUrl;

  /// Bearer token authenticating every request.
  final String token;

  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  /// Headers for the pooled [http] calls: the bearer gate plus a fresh
  /// connection per call — the dsh webserver closes idle keep-alive sockets,
  /// and the pooled client's reuse of a severed one surfaces as connection
  /// resets (the same hazard the gateway's unary path works around).
  Map<String, String> get _pooledHeaders => {..._auth, 'connection': 'close'};

  /// Whether the speech plugin's `/s/api/health` endpoint answers 200.
  Future<bool> health() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/s/api/health'),
        headers: _pooledHeaders,
      ).timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Transcribe audio bytes to text via `/s/api/speech.transcribe`.
  ///
  /// [audio] is raw audio bytes; [mimeType] names the container (e.g.
  /// `audio/wav`); [language] is an optional BCP-47 hint. Throws
  /// [SpeechException] on a non-200 answer and on transport-level failure
  /// (the host closing the connection, a reset, or a timeout).
  Future<String> transcribe({
    required Uint8List audio,
    required String mimeType,
    String? language,
  }) async {
    final headers = <String, String>{
      ..._pooledHeaders,
      'Content-Type': mimeType,
      if (language != null && language.isNotEmpty) 'X-Speech-Language': language,
    };
    final http.Response response;
    try {
      response = await http.post(
        Uri.parse('$baseUrl/s/api/speech.transcribe'),
        headers: headers,
        body: audio,
      ).timeout(const Duration(seconds: 90));
    } catch (error) {
      throw SpeechException('SPEECH_NETWORK_ERROR', '语音识别连接失败: $error');
    }
    if (response.statusCode != 200) {
      final body = jsonDecode(response.body) as Map<String, Object?>;
      final error = body['error'] as Map<String, Object?>?;
      throw SpeechException(
        error?['code'] as String? ?? 'unknown',
        error?['message'] as String? ?? 'transcribe failed (${response.statusCode})',
      );
    }
    final body = jsonDecode(response.body) as Map<String, Object?>;
    return body['text'] as String? ?? '';
  }

  /// Synthesize text to audio via `/s/api/speech.synthesize`.
  ///
  /// Returns the raw audio bytes plus the content-type (e.g. `audio/wav`).
  /// Throws [SpeechException] on a non-200 answer and on transport-level
  /// failure (the host closing the connection, a reset, or a timeout).
  Future<SpeechAudio> synthesize({
    required String text,
    String? voice,
    String? format,
  }) async {
    final body = jsonEncode({
      'text': text,
      if (voice != null && voice.isNotEmpty) 'voice': voice,
      if (format != null) 'format': format,
    });
    final http.Response response;
    try {
      response = await http.post(
        Uri.parse('$baseUrl/s/api/speech.synthesize'),
        headers: {..._pooledHeaders, 'Content-Type': 'application/json'},
        body: body,
      ).timeout(const Duration(seconds: 60));
    } catch (error) {
      throw SpeechException('SPEECH_NETWORK_ERROR', '语音合成连接失败: $error');
    }
    if (response.statusCode != 200) {
      final errorBody = jsonDecode(response.body) as Map<String, Object?>;
      final error = errorBody['error'] as Map<String, Object?>?;
      throw SpeechException(
        error?['code'] as String? ?? 'unknown',
        error?['message'] as String? ?? 'synthesize failed (${response.statusCode})',
      );
    }
    return SpeechAudio(
      bytes: response.bodyBytes,
      mimeType: response.headers['content-type'] ?? 'audio/mpeg',
    );
  }

  /// The URL of the speech configuration page, with token embedded.
  String configPageUrl() => '$baseUrl/s/?token=$token';

  /// Open one live-transcription session over the plugin's `/s/ws` channel.
  ///
  /// [provider] pins a provider entry (null = the host's selector); audio
  /// frames fed through [DshSpeechSession.sendAudio] must be PCM16 LE at
  /// [sampleRateHz]; [diarization] asks for speaker-labeled segments. The
  /// session is ready once the [SpeechSessionReady] event arrives.
  Future<DshSpeechSession> openSession({
    String? provider,
    int sampleRateHz = 16000,
    bool diarization = true,
  }) {
    return DshSpeechSession.open(
      baseUrl: baseUrl,
      token: token,
      provider: provider,
      sampleRateHz: sampleRateHz,
      diarization: diarization,
    );
  }

  /// Streamed synthesis via `/s/api/speech.synthesize.stream`.
  ///
  /// Yields raw audio chunks in arrival order; the first chunk carries the
  /// container header, so playback can begin before the body completes.
  /// Non-200 responses throw [SpeechException] before the first yield, and
  /// transport-level failure (the host closing the connection before it
  /// answers, a reset, or a timeout) throws [SpeechException] at the point
  /// it happens — mid-stream it ends the stream with the error. The
  /// returned stream otherwise ends when the server closes the body;
  /// cancelling the subscription aborts the request.
  Stream<Uint8List> synthesizeStream({
    required String text,
    String? voice,
  }) async* {
    final client = HttpClient();
    try {
      final request = await client
          .postUrl(Uri.parse('$baseUrl/s/api/speech.synthesize.stream'))
          .timeout(const Duration(seconds: 30));
      request.headers.set('Authorization', 'Bearer $token');
      request.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.write(jsonEncode({
        'text': text,
        if (voice != null && voice.isNotEmpty) 'voice': voice,
      }));
      final response = await request.close().timeout(const Duration(seconds: 90));
      if (response.statusCode != 200) {
        final body = await response.fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        ).timeout(const Duration(seconds: 10));
        Map<String, Object?>? error;
        try {
          error = (jsonDecode(utf8.decode(body)) as Map<String, Object?>)['error']
              as Map<String, Object?>?;
        } catch (_) {}
        throw SpeechException(
          error?['code'] as String? ?? 'unknown',
          error?['message'] as String? ??
              'synthesize.stream failed (${response.statusCode})',
        );
      }
      await for (final chunk in response) {
        if (chunk.isNotEmpty) yield Uint8List.fromList(chunk);
      }
    } on SpeechException {
      rethrow;
    } catch (error) {
      throw SpeechException('SPEECH_NETWORK_ERROR', '语音合成连接失败: $error');
    } finally {
      client.close(force: true);
    }
  }
}

/// One synthesized audio result.
class SpeechAudio {
  const SpeechAudio({required this.bytes, required this.mimeType});

  /// Raw audio bytes from the TTS endpoint.
  final Uint8List bytes;

  /// Content-Type of the audio (e.g. `audio/wav`, `audio/mpeg`).
  final String mimeType;
}

/// Speech API failure carrying the stable error code and message.
class SpeechException implements Exception {
  const SpeechException(this.code, this.message);

  /// Stable machine-routing code from the speech error vocabulary
  /// (`SPEECH_NETWORK_ERROR` marks a client-side transport failure).
  final String code;

  /// Human-readable failure detail.
  final String message;

  @override
  String toString() => 'SpeechException($code): $message';
}

/// Events a live-transcription session emits, in arrival order.
sealed class SpeechSessionEvent {
  const SpeechSessionEvent();
}

/// Negotiation finished: the host named the serving provider and its mode.
class SpeechSessionReady extends SpeechSessionEvent {
  const SpeechSessionReady({
    required this.provider,
    required this.mode,
    required this.partial,
    required this.diarization,
  });

  /// Provider entry id the host selected.
  final String provider;

  /// `vad` emits final turns per utterance; `streaming` also emits partials.
  final String mode;

  /// Whether [SpeechSessionPartial] events will arrive.
  final bool partial;

  /// Whether transcripts may carry speaker-labeled segments.
  final bool diarization;
}

/// Provisional text replacing the previous provisional.
class SpeechSessionPartial extends SpeechSessionEvent {
  const SpeechSessionPartial(this.text);

  /// Current provisional recognition of the ongoing utterance.
  final String text;
}

/// Finalized text plus optional speaker-labeled segments.
class SpeechSessionTranscript extends SpeechSessionEvent {
  const SpeechSessionTranscript(this.text, this.segments);

  /// Final recognized text of the turn.
  final String text;

  /// Speaker turns; empty when the provider has no diarization.
  final List<SpeechSessionSegment> segments;
}

/// One speaker-labeled turn inside a transcript event.
class SpeechSessionSegment {
  const SpeechSessionSegment({
    required this.spk,
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  /// Session-stable speaker id.
  final int spk;

  /// Recognized text of the turn.
  final String text;

  /// Turn start within the session, in ms.
  final int startMs;

  /// Turn end within the session, in ms.
  final int endMs;

  @override
  bool operator ==(Object other) =>
      other is SpeechSessionSegment &&
      other.spk == spk &&
      other.text == text &&
      other.startMs == startMs &&
      other.endMs == endMs;

  @override
  int get hashCode => Object.hash(spk, text, startMs, endMs);
}

/// Host-side failure ending the session.
class SpeechSessionError extends SpeechSessionEvent {
  const SpeechSessionError(this.code, this.message);

  /// Stable machine-routing code from the speech error vocabulary.
  final String code;

  /// Human-readable failure detail.
  final String message;
}

/// The host closed the session (explicit close, policy, or provider exit).
class SpeechSessionClosed extends SpeechSessionEvent {
  const SpeechSessionClosed([this.reason]);

  /// Close reason when the host sends one.
  final String? reason;
}

/// One live-transcription session on the plugin's `/s/ws` channel.
///
/// Feed PCM16 LE frames through [sendAudio]; consume [events] until
/// [SpeechSessionClosed] or [SpeechSessionError] ends the stream. [close]
/// performs the protocol handshake (flush pending audio) and settles once
/// the host acknowledges.
class DshSpeechSession {
  DshSpeechSession._(this._channel);

  final WebSocketChannel _channel;
  final StreamController<SpeechSessionEvent> _controller =
      StreamController<SpeechSessionEvent>.broadcast();
  final Completer<void> _closed = Completer<void>();

  /// Session events in arrival order; a broadcast stream, so consumers may
  /// listen late without losing terminal-state awareness via [done].
  Stream<SpeechSessionEvent> get events => _controller.stream;

  /// Resolves when the host closes the session or the socket drops.
  Future<void> get done => _closed.future;

  /// Open the channel and negotiate a session.
  static Future<DshSpeechSession> open({
    required Uri baseUrl,
    required String token,
    String? provider,
    int sampleRateHz = 16000,
    bool diarization = true,
  }) async {
    // The query token keeps LAN callers admitted; loopback hosts skip the
    // token server-side either way.
    final wsUrl = baseUrl.replace(
      scheme: baseUrl.scheme == 'https' ? 'wss' : 'ws',
      path: '/s/ws',
      queryParameters: {'token': token},
    );
    final channel = WebSocketChannel.connect(wsUrl);
    await channel.ready.timeout(const Duration(seconds: 15));
    final session = DshSpeechSession._(channel);
    session._wire(
      provider: provider,
      sampleRateHz: sampleRateHz,
      diarization: diarization,
    );
    return session;
  }

  void _wire({
    String? provider,
    required int sampleRateHz,
    required bool diarization,
  }) {
    _channel.stream.listen(
      (frame) {
        if (frame is! String) return;
        Map<String, Object?> obj;
        try {
          obj = jsonDecode(frame) as Map<String, Object?>;
        } catch (_) {
          return;
        }
        final type = obj['type'] as String?;
        switch (type) {
          case 'session.ready':
            _controller.add(SpeechSessionReady(
              provider: obj['provider'] as String? ?? '',
              mode: obj['mode'] as String? ?? 'vad',
              partial: obj['partial'] == true,
              diarization: obj['diarization'] == true,
            ));
          case 'partial':
            _controller.add(SpeechSessionPartial(obj['text'] as String? ?? ''));
          case 'transcript':
            _controller.add(SpeechSessionTranscript(
              obj['text'] as String? ?? '',
              _decodeSegments(obj['segments']),
            ));
          case 'error':
            _controller.add(SpeechSessionError(
              obj['code'] as String? ?? 'unknown',
              obj['message'] as String? ?? 'session failed',
            ));
            _settle();
          case 'closed':
            _controller.add(SpeechSessionClosed(obj['reason'] as String?));
            _settle();
          default:
            break;
        }
      },
      onError: (Object _) {
        if (!_closed.isCompleted) {
          _controller.add(const SpeechSessionClosed('connection lost'));
          _closed.complete();
        }
      },
      onDone: () {
        if (!_closed.isCompleted) {
          _controller.add(const SpeechSessionClosed('connection closed'));
          _closed.complete();
        }
      },
      cancelOnError: false,
    );
    _channel.sink.add(jsonEncode({
      'type': 'session.create',
      if (provider != null && provider.isNotEmpty) 'provider': provider,
      'sampleRateHz': sampleRateHz,
      'encoding': 'pcm16',
      'diarization': diarization,
    }));
  }

  /// Feed one PCM16 LE audio frame; any chunk size the channel accepts.
  void sendAudio(Uint8List frame) {
    if (_closed.isCompleted) return;
    _channel.sink.add(frame);
  }

  /// End the session: flush pending audio, wait for the host's ack.
  Future<void> close() async {
    if (_closed.isCompleted) return;
    _channel.sink.add(jsonEncode({'type': 'session.close'}));
    await _closed.future.timeout(const Duration(seconds: 5), onTimeout: () {
      _settle();
    });
    await _channel.sink.close();
  }

  void _settle() {
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }

  static List<SpeechSessionSegment> _decodeSegments(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((segment) => SpeechSessionSegment(
              spk: segment['spk'] as int? ?? 0,
              text: segment['text'] as String? ?? '',
              startMs: segment['startMs'] as int? ?? 0,
              endMs: segment['endMs'] as int? ?? 0,
            ))
        .where((segment) => segment.text.isNotEmpty)
        .toList();
  }
}