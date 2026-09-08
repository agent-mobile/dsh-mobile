/// Transcription controller: live-transcription session state machine
/// ported from the OpenClaw TranscriptionManager contract, speaking the
/// dsh-speech plugin's `/s/ws` channel through [DshSpeechSession].
///
/// Lifecycle: [start] opens the session and streams mic PCM16 frames into it;
/// [pause]/[resume] gate the mic without closing the session; [stop] closes
/// the session (flushing the host's pending utterance) and returns the whole
/// document; [retry] continues a failed session from the text already
/// captured. Transcript turns append to [liveText]; provisional text shows in
/// [partialText]; diarized turns land in [segments] with session-stable
/// speaker ids.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Live-transcription lifecycle states.
enum TranscriptionState {
  /// No session; nothing captured.
  idle,

  /// Session opening; mic not yet armed.
  connecting,

  /// Mic streaming into a live session.
  recording,

  /// Session open, mic gated by the user.
  paused,

  /// Session failed; captured text survives for [retry] or [stop].
  failed,
}

/// One speaker-labeled transcript turn.
class TranscriptionTurn {
  const TranscriptionTurn({
    required this.speaker,
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  /// Session-stable speaker id from the host linker.
  final int speaker;

  /// Finalized turn text.
  final String text;

  /// Turn start within the session, in ms.
  final int startMs;

  /// Turn end within the session, in ms.
  final int endMs;
}

/// Document returned when a session stops.
class TranscriptionSessionResult {
  const TranscriptionSessionResult({
    required this.text,
    required this.turns,
    required this.durationMs,
    required this.startedAt,
    required this.endedAt,
  });

  /// Whole-session text (turns joined by newlines).
  final String text;

  /// Speaker-labeled turns in order.
  final List<TranscriptionTurn> turns;

  /// Recording wall time excluding pauses, in ms.
  final int durationMs;

  /// Session start (wall clock).
  final DateTime startedAt;

  /// Session end (wall clock).
  final DateTime endedAt;

  /// Speaker-labeled document body: one line per turn, prefixed with
  /// `[说话人 N] ` when the session carries more than one speaker. Falls
  /// back to [text] when no turns were captured. Matches the saved
  /// transcript file body so display, send-to-chat, and save render alike.
  String get labeledText {
    if (turns.isEmpty) return text;
    final diarized = turns.any((turn) => turn.speaker != 0);
    return turns.map((turn) {
      final label = turn.speaker == 0 && !diarized
          ? ''
          : '[说话人 ${turn.speaker + 1}] ';
      return '$label${turn.text}';
    }).join('\n');
  }
}

/// Owns one live-transcription session plus its mic pipeline.
class TranscriptionController extends ChangeNotifier {
  TranscriptionController({required this.speechClient, this.provider});

  /// Speech client used to open the `/s/ws` session.
  final DshSpeechClient speechClient;

  /// Provider entry to pin; null uses the host's selector.
  final String? provider;

  TranscriptionState _state = TranscriptionState.idle;
  String _liveText = '';
  String _partialText = '';
  List<TranscriptionTurn> _turns = const [];
  double _level = 0;
  String? _error;
  bool _supportsPartial = false;
  bool _diarization = false;
  String? _providerId;

  DshSpeechSession? _session;
  StreamSubscription<Uint8List>? _mic;
  StreamSubscription<SpeechSessionEvent>? _events;
  Timer? _clock;
  final Stopwatch _elapsed = Stopwatch();
  // Lazy: constructing the recorder touches a platform channel, so pure
  // event-fold tests must not pay for it.
  AudioRecorder? _recorder;
  bool _stopping = false;

  AudioRecorder get _micRecorder => _recorder ??= AudioRecorder();

  /// Current lifecycle state.
  TranscriptionState get state => _state;

  /// Finalized text accumulated so far, turns joined by newlines.
  String get liveText => _liveText;

  /// Provisional recognition of the ongoing utterance (streaming modes).
  String get partialText => _partialText;

  /// Diarized turns in arrival order.
  List<TranscriptionTurn> get turns => _turns;

  /// Mic input level 0..1 for the waveform.
  double get level => _level;

  /// Last failure message; set when [state] is failed.
  String? get error => _error;

  /// Whether the session provider emits partials (from session.ready).
  bool get supportsPartial => _supportsPartial;

  /// Whether transcripts carry speaker labels (from session.ready).
  bool get diarization => _diarization;

  /// Provider entry serving this session; empty before ready.
  String get providerId => _providerId ?? '';

  /// Recording elapsed time, excluding pauses.
  int get elapsedMs => _elapsed.elapsedMilliseconds;

  /// Whether a session owns the mic pipeline.
  bool get isActive =>
      _state != TranscriptionState.idle && _state != TranscriptionState.failed;

  /// Open a session and arm the mic. No-op while one is active.
  Future<void> start() => _beginSession();

  /// Continue a failed session from the text already captured.
  Future<void> retry() async {
    if (_state != TranscriptionState.failed) return;
    await _beginSession();
  }

  Future<void> _beginSession() async {
    if (isActive) return;
    _error = null;
    _partialText = '';
    _state = TranscriptionState.connecting;
    _stopping = false;
    notifyListeners();

    try {
      final session = await speechClient.openSession(
        provider: provider,
        sampleRateHz: 16000,
        diarization: true,
      );
      if (_stopping) {
        await session.close();
        return;
      }
      _session = session;
      _events = session.events.listen(_onEvent);
      await _armMic();
      _elapsed.start();
      _startClock();
    } catch (e) {
      _state = TranscriptionState.failed;
      _error = e is SpeechException ? e.message : '连接失败: $e';
      notifyListeners();
    }
  }

  /// Gate the mic while leaving the session open.
  Future<void> pause() async {
    if (_state != TranscriptionState.recording) return;
    _state = TranscriptionState.paused;
    _elapsed.stop();
    await _mic?.cancel();
    _mic = null;
    await _stopRecorder();
    _level = 0;
    notifyListeners();
  }

  /// Re-arm the mic on a paused session.
  Future<void> resume() async {
    if (_state != TranscriptionState.paused) return;
    await _armMic();
    _elapsed.start();
    _state = TranscriptionState.recording;
    notifyListeners();
  }

  /// End the session, flush the host's pending utterance, return the document.
  Future<TranscriptionSessionResult?> stop() async {
    if (!isActive && _liveText.isEmpty && _turns.isEmpty) {
      _reset();
      return null;
    }
    final startedAt = DateTime.now().subtract(Duration(milliseconds: _elapsed.elapsedMilliseconds));
    _stopping = true;
    await _mic?.cancel();
    _mic = null;
    _level = 0;
    _clock?.cancel();
    _clock = null;
    _elapsed.stop();
    await _stopRecorder();
    try {
      await _session?.close().timeout(const Duration(seconds: 6));
    } catch (_) {
      // The document is already captured; a stuck close must not lose it.
      await _session?.done.timeout(const Duration(seconds: 1), onTimeout: () {});
    }
    final text = _liveText;
    final turns = _turns;
    final durationMs = _elapsed.elapsedMilliseconds;
    _reset();
    return TranscriptionSessionResult(
      text: text,
      turns: turns,
      durationMs: durationMs,
      startedAt: startedAt,
      endedAt: DateTime.now(),
    );
  }

  void _reset() {
    _state = TranscriptionState.idle;
    _liveText = '';
    _partialText = '';
    _turns = const [];
    _error = null;
    _session = null;
    _stopping = false;
    _elapsed.reset();
    notifyListeners();
  }

  /// Event-fold entry: applies one session event to the state machine.
  /// Public for tests; the live session subscription routes here.
  @visibleForTesting
  void handleSessionEvent(SpeechSessionEvent event) => _onEvent(event);

  void _onEvent(SpeechSessionEvent event) {
    switch (event) {
      case SpeechSessionReady():
        _providerId = event.provider;
        _supportsPartial = event.partial;
        _diarization = event.diarization;
        // A ready event means a live session exists; promote from any
        // pre-recording state.
        if (_state == TranscriptionState.connecting
            || _state == TranscriptionState.idle) {
          _state = TranscriptionState.recording;
        }
      case SpeechSessionPartial():
        _partialText = event.text;
      case SpeechSessionTranscript():
        final text = event.text.trim();
        if (text.isNotEmpty) {
          _liveText = _liveText.isEmpty ? text : '$_liveText\n$text';
        }
        if (event.segments.isNotEmpty) {
          _turns = [
            ..._turns,
            ...event.segments.map((segment) => TranscriptionTurn(
                  speaker: segment.spk,
                  text: segment.text,
                  startMs: segment.startMs,
                  endMs: segment.endMs,
                )),
          ];
        } else if (text.isNotEmpty) {
          _turns = [
            ..._turns,
            TranscriptionTurn(speaker: 0, text: text, startMs: 0, endMs: 0),
          ];
        }
        _partialText = '';
      case SpeechSessionError():
        if (!_stopping) {
          _state = TranscriptionState.failed;
          _error = event.message;
          _elapsed.stop();
          _level = 0;
        }
      case SpeechSessionClosed():
        if (!_stopping) {
          _state = TranscriptionState.failed;
          _error = event.reason ?? '会话被服务端关闭';
          _elapsed.stop();
          _level = 0;
        }
    }
    notifyListeners();
  }

  /// Release the mic, tolerating an absent or already-stopped recorder.
  Future<void> _stopRecorder() async {
    final recorder = _recorder;
    if (recorder == null) return;
    try {
      await recorder.stop();
    } catch (_) {
      // Recorder already stopped; nothing to release.
    }
  }

  Future<void> _armMic() async {
    if (!await _micRecorder.hasPermission()) {
      _state = TranscriptionState.failed;
      _error = '麦克风权限被拒绝';
      notifyListeners();
      return;
    }
    final session = _session;
    if (session == null) return;
    final stream = await _micRecorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
        autoGain: true,
        echoCancel: true,
        noiseSuppress: false,
      ),
    );
    _mic = stream.listen((frame) {
      session.sendAudio(frame);
      _smoothLevel(_frameLevel(frame));
    });
    _state = TranscriptionState.recording;
    notifyListeners();
  }

  void _startClock() {
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_state == TranscriptionState.recording) notifyListeners();
    });
  }

  /// Peak-follower for the meter bar: fast attack so speech pops the fill
  /// up immediately, slow release so it eases down between words instead of
  /// flickering with raw per-chunk RMS.
  void _smoothLevel(double raw) {
    final alpha = raw > _level ? 0.6 : 0.15;
    _level += (raw - _level) * alpha;
  }

  /// RMS level of one PCM16 frame mapped to 0..1 on a dBFS curve: -45 dB
  /// (quiet room noise) reads as 0 and -6 dB (loud speech) fills the bar.
  /// A linear scale squashes normal speech (RMS 1000–3000) into the bottom
  /// ~10% of the range, which reads as a stuck meter.
  static double _frameLevel(Uint8List frame) {
    var sum = 0.0;
    final samples = frame.length ~/ 2;
    if (samples == 0) return 0;
    for (var i = 0; i + 1 < frame.length; i += 2) {
      final sample = frame[i] | (frame[i + 1] << 8);
      final signed = sample.toSigned(16);
      sum += signed * signed;
    }
    final rms = math.sqrt(sum / samples);
    if (rms <= 0) return 0;
    final db = 20 * math.log(rms / 32768) / math.ln10;
    return ((db + 45) / 39).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _stopping = true;
    _mic?.cancel();
    _events?.cancel();
    _clock?.cancel();
    _recorder?.dispose();
    super.dispose();
  }
}
