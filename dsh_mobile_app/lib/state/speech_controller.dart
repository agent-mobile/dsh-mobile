/// Speech controller: voice mode state machine that owns the microphone
/// (record), ASR upload (DshSpeechClient.transcribe), and TTS playback —
/// including the streamed-speech pipeline that synthesizes and plays
/// assistant replies sentence by sentence while the text is still
/// generating.
///
/// States:
///   idle         → standby, or waiting for the model reply (loop active)
///   recording    → microphone capturing, waiting for silence / manual stop
///   transcribing → uploading audio to ASR
///   speaking     → streamed TTS session active (synthesizing or playing)
///
/// Streamed speech: [beginStreamedSpeech] opens a session,
/// [addSpeechSentence] enqueues text units, [endStreamedSpeech] closes the
/// stream. Each unit is synthesized through the streaming endpoint and its
/// audio chunks are fed, in submission order, into ONE continuous PCM
/// playback session (native AudioTrack stream mode): the first chunk of
/// the first unit starts playback in a few hundred milliseconds, later
/// units append with zero per-clip gap, and a unit's synthesis overlaps
/// the playback of everything before it. When the stream is closed and
/// synthesis and playback drain, the controller returns to idle and
/// re-arms the microphone (conversation loop active). The streaming
/// endpoint failing at any point falls back to the batch endpoint with
/// the same continuous-playback path.
///
/// The hands-free conversation loop ([startConversation] →
/// [stopConversation]) chains the phases automatically: record → silence
/// auto-stop → ASR → send ([onResult]) → wait for the reply → streamed TTS
/// playback → re-record. The user only taps the waveform twice: once to
/// start, once to interrupt and end.
///
/// VAD is amplitude-based: after the user starts speaking, a configurable
/// silence window triggers auto-stop and transcription.
library;

import 'dart:async';
import 'dart:io' show File, Directory;
import 'dart:math';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'pcm_stream_player.dart';

/// Voice interaction states.
enum SpeechState { idle, recording, transcribing, speaking }

/// Configuration for silence detection.
const _silenceThreshold = 0.02;
const _silenceDurationMs = 1500;
const _sampleRate = 16000;
const _mimeType = 'audio/wav';

/// A letter or digit in any script (CJK included); the minimum content for a
/// unit to be worth synthesizing.
final RegExp _speakable = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Manages the voice-mode lifecycle: recording, ASR, streamed TTS playback,
/// and the hands-free conversation loop between them.
class SpeechController extends ChangeNotifier {
  SpeechController({required this.speechClient, this.onResult, this.onUnitStart});

  final DshSpeechClient speechClient;

  /// Invoked once per successful transcription with the recognized text
  /// (non-empty). The parent sends it through session.prompt; the loop then
  /// waits for the reply's streamed TTS playback before re-arming the mic.
  final void Function(String text)? onResult;

  /// Invoked when playback reaches unit [unitIndex] (0-based, in
  /// submission order) — the moment that unit's audio starts being heard.
  /// The parent uses it to pace text display to the audio (karaoke
  /// subtitles): reveal unit i's text as it starts sounding. May fire
  /// slightly out of order around failed units; consumers take the max.
  final void Function(int unitIndex)? onUnitStart;

  final AudioRecorder _recorder = AudioRecorder();

  SpeechState _state = SpeechState.idle;

  /// Whether the hands-free conversation loop is active, between the first
  /// and second waveform taps.
  bool _conversing = false;

  /// Current amplitude (0..1) for waveform animation.
  double _amplitude = 0;
  String? _error;

  SpeechState get state => _state;
  double get amplitude => _amplitude;
  String? get error => _error;

  /// Transient, non-error guidance for the user (e.g. an empty recognition
  /// result); cleared when real speech is next detected.
  String? get hint => _hint;
  bool get isRecording => _state == SpeechState.recording;
  bool get isSpeaking => _state == SpeechState.speaking;
  bool get isConversing => _conversing;

  Timer? _amplitudeTimer;
  Timer? _silenceTimer;
  DateTime? _lastSpeechAt;

  /// Ambient-noise level estimate (0..1), adapted while the mic is idle;
  /// speech must clear a multiple of it, so a noisy room cannot hold the
  /// silence gate open forever.
  double _noiseFloor = _silenceThreshold;

  /// Whether real speech has been detected in the current recording; the
  /// silence auto-stop only fires afterwards, so ambient noise alone never
  /// ends a turn.
  bool _speechStarted = false;

  String? _hint;

  /// Speech gate: the fixed floor or a multiple of the adapted noise floor.
  double get _speechThreshold => max(_silenceThreshold, _noiseFloor * 2.2);

  // ---- Streamed speech session ----

  /// Session generation: bumped to cancel every in-flight synthesis or
  /// playback coroutine belonging to an older session.
  int _speechGeneration = 0;

  /// Text units awaiting synthesis, in submission order.
  final List<String> _sentenceQueue = [];

  /// Whether [endStreamedSpeech] closed the stream; the session drains once
  /// the queue is empty, synthesis is idle, and the PCM stream has played
  /// out. A late [addSpeechSentence] reopens the stream.
  bool _speechStreamFinished = false;

  bool _synthesisInFlight = false;

  /// The one continuous PCM playback session serving this speech session;
  /// created lazily on the first audio chunk, released on cancel/drain.
  PcmStreamPlayer? _pcmPlayer;

  /// Whether the streaming endpoint is usable; cleared after a failure so
  /// subsequent units fall back to the batch endpoint for this session.
  bool _streamEndpointOk = true;

  // ---- Unit pacing (karaoke text reveal) ----

  /// Index of the unit currently feeding audio.
  int _feedingUnit = -1;

  /// Audio duration of each fed unit, in feed order.
  final List<Duration> _unitDurations = [];

  /// When playback of each unit (is scheduled to have) started.
  final List<DateTime> _unitStarts = [];

  /// Pending reveal timers for units whose scheduled start is in the future.
  final List<Timer> _revealTimers = [];

  /// Record the start of unit playback: unit 0 starts when its first audio
  /// chunk is fed (the queue is empty then); unit n starts at
  /// max(first-feed time, start(n-1) + duration(n-1)) — contiguous unless
  /// the queue starved. Fires [onUnitStart] now or via a timer.
  void _noteUnitStart(int gen) {
    _feedingUnit++;
    final index = _feedingUnit;
    final now = DateTime.now();
    if (index == 0) {
      _unitStarts.add(now);
      onUnitStart?.call(0);
      return;
    }
    final prevStart = _unitStarts[index - 1];
    final prevDuration = _unitDurations.length >= index
        ? _unitDurations[index - 1]
        : Duration.zero;
    final scheduled = prevStart.add(prevDuration);
    if (!scheduled.isAfter(now)) {
      _unitStarts.add(now);
      onUnitStart?.call(index);
      return;
    }
    _unitStarts.add(scheduled);
    _revealTimers.add(Timer(scheduled.difference(now), () {
      if (gen == _speechGeneration) onUnitStart?.call(index);
    }));
  }

  /// Record the audio duration of the unit that just finished feeding.
  void _noteUnitEnd(int pcmBytes) {
    final rate = _pcmPlayer?.sampleRate ?? 24000;
    final channels = _pcmPlayer?.channels ?? 1;
    final microseconds = (pcmBytes * 1e6 / (rate * channels * 2)).round();
    _unitDurations.add(Duration(microseconds: microseconds));
  }

  /// A unit that produced no audio (synthesis failure): zero duration,
  /// revealed immediately so its text is not stranded hidden.
  void _noteUnitFailed(int gen) {
    _noteUnitStart(gen);
    _noteUnitEnd(0);
  }

  void _clearRevealTimers() {
    for (final timer in _revealTimers) {
      timer.cancel();
    }
    _revealTimers.clear();
  }

  /// Start the hands-free loop: interrupts any active playback, then arms
  /// the microphone. The first call may pop the mic permission dialog; a
  /// denial or recorder failure rolls the loop back to standby.
  Future<void> startConversation() async {
    if (_conversing) return;
    _error = null;
    _cancelStreamedSpeech();
    _conversing = true;
    if (!await _beginRecording()) {
      _conversing = false;
    }
    notifyListeners();
  }

  /// End the loop, interrupting the active phase: a recording is discarded,
  /// a transcription in flight has its result dropped, and streamed speech
  /// playback is stopped. Returns to standby.
  Future<void> stopConversation() async {
    if (!_conversing) return;
    _conversing = false;
    switch (_state) {
      case SpeechState.recording:
        await _cancelRecording();
      case SpeechState.speaking:
        _cancelStreamedSpeech();
      case SpeechState.transcribing:
        _state = SpeechState.idle;
        _amplitude = 0;
        notifyListeners();
      case SpeechState.idle:
        break;
    }
  }

  /// Re-arm the microphone when the loop is active but idle (e.g. a send
  /// failure left the loop waiting for a reply that will not come).
  void resumeListening() => _resumeListening();

  /// Open a streamed speech session, replacing any active one (one-shot or
  /// streamed). Units added afterwards are synthesized and played in order.
  void beginStreamedSpeech() {
    _cancelStreamedSpeech();
    _speechStreamFinished = false;
    _error = null;
    _state = SpeechState.speaking;
    notifyListeners();
  }

  /// Enqueue one text unit (a sentence, or a whole one-shot text) into the
  /// active streamed session. Returns whether the unit was accepted (a
  /// dropped unit consumes no playback index, so callers that track unit
  /// positions must not count it). Units without a single letter or digit
  /// are accepted but synthesized as zero-audio placeholders: providers
  /// reject them (DashScope answers 400 "invalid text"), and playing them
  /// as silence keeps the karaoke reveal from stranding their text.
  bool addSpeechSentence(String sentence) {
    if (sentence.isEmpty) return false;
    if (_state != SpeechState.speaking) return false;
    _speechStreamFinished = false;
    _sentenceQueue.add(sentence);
    _pumpSynthesis(_speechGeneration);
    return true;
  }

  /// Close the streamed session: once both queues drain and nothing is in
  /// flight, playback ends and the loop resumes listening.
  void endStreamedSpeech() {
    if (_state != SpeechState.speaking) return;
    _speechStreamFinished = true;
    _checkSpeechDrained(_speechGeneration);
  }

  /// Speak text via TTS: a streamed session holding exactly one unit,
  /// drained immediately. Skipped while recording or transcribing —
  /// playback must not cut into capture.
  void speak(String text) {
    if (text.trim().isEmpty) return;
    if (_state == SpeechState.recording || _state == SpeechState.transcribing) {
      return;
    }
    beginStreamedSpeech();
    addSpeechSentence(text);
    endStreamedSpeech();
  }

  /// Arm the microphone from idle. Returns false on permission denial or a
  /// recorder failure ([_error] carries the reason).
  Future<bool> _beginRecording() async {
    if (_state != SpeechState.idle) return false;
    try {
      if (!await _recorder.hasPermission()) {
        _error = '麦克风权限被拒绝';
        notifyListeners();
        return false;
      }

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: _sampleRate,
          numChannels: 1,
          bitRate: 256000,
        ),
        path: await _tempPath(),
      );

      _state = SpeechState.recording;
      _amplitude = 0;
      _lastSpeechAt = DateTime.now();
      _speechStarted = false;
      _noiseFloor = _silenceThreshold;
      notifyListeners();

      _amplitudeTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) async {
          if (_state != SpeechState.recording) return;
          try {
            final amp = await _recorder.getAmplitude();
            _amplitude = dbToAmplitude(amp.current);
            if (_amplitude > _speechThreshold) {
              _speechStarted = true;
              _hint = null;
              _lastSpeechAt = DateTime.now();
              _silenceTimer?.cancel();
              _silenceTimer = null;
            } else {
              // Adapt the noise floor only while quiet, so speech does not
              // drag the gate up with it.
              _noiseFloor = _noiseFloor * 0.9 + _amplitude * 0.1;
              _silenceTimer ??= Timer.periodic(
                const Duration(milliseconds: 200),
                _checkSilence,
              );
            }
            notifyListeners();
          } catch (_) {}
        },
      );
      return true;
    } catch (e) {
      _error = '录音启动失败: $e';
      _state = SpeechState.idle;
      notifyListeners();
      return false;
    }
  }

  /// Stop recording and transcribe. A non-empty result is delivered through
  /// [onResult] (the loop then waits for the reply's streamed TTS); an empty
  /// result re-arms the microphone immediately. Any failure ends the loop so
  /// a persistent recorder/ASR fault cannot spin.
  Future<String?> _stopAndTranscribe() async {
    if (_state != SpeechState.recording) return null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;

    _state = SpeechState.transcribing;
    _amplitude = 0;
    notifyListeners();

    try {
      final path = await _recorder.stop();
      if (path == null || path.isEmpty) {
        return _finishTranscription(null, '录音文件为空');
      }
      final file = File(path);
      if (!await file.exists()) {
        return _finishTranscription(null, '录音文件不存在');
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        return _finishTranscription(null, '录音数据为空');
      }
      final text = await speechClient.transcribe(
        audio: Uint8List.fromList(bytes),
        mimeType: _mimeType,
      );
      return _finishTranscription(text, null);
    } catch (e) {
      return _finishTranscription(
        null,
        e is SpeechException ? e.message : '识别失败: $e',
      );
    }
  }

  /// Settle a finished transcription: drop it if the loop was ended mid-
  /// upload, otherwise reset state, surface any error, deliver non-empty
  /// text, and re-arm the microphone when nothing was sent.
  String? _finishTranscription(String? text, String? error) {
    if (!_conversing) return null;
    _state = SpeechState.idle;
    _error = error;
    if (error != null) _conversing = false;
    notifyListeners();
    if (error == null && text != null && text.trim().isNotEmpty) {
      onResult?.call(text);
    } else if (_conversing) {
      // An empty recognition is silent in every other way; leave a visible
      // hint so "spoke, nothing happened" is diagnosable on the device.
      if (error == null) _hint = '未识别到内容，请再说一遍';
      _resumeListening();
    }
    return text;
  }

  /// Discard the current recording without transcribing.
  Future<void> _cancelRecording() async {
    if (_state != SpeechState.recording) return;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _amplitudeTimer?.cancel();
    _amplitudeTimer = null;
    try {
      await _recorder.cancel();
    } catch (_) {}
    _state = SpeechState.idle;
    _amplitude = 0;
    notifyListeners();
  }

  /// Cancel the streamed speech session: retire the generation (in-flight
  /// coroutines fail the generation check and drop their results), drop the
  /// text queue, and stop the PCM stream player.
  void _cancelStreamedSpeech() {
    _speechGeneration++;
    _sentenceQueue.clear();
    _speechStreamFinished = false;
    _synthesisInFlight = false;
    _streamEndpointOk = true;
    _clearRevealTimers();
    _feedingUnit = -1;
    _unitDurations.clear();
    _unitStarts.clear();
    final player = _pcmPlayer;
    _pcmPlayer = null;
    if (player != null) {
      player.stop();
    }
    if (_state == SpeechState.speaking) {
      _state = SpeechState.idle;
      notifyListeners();
    }
  }

  /// Synthesize queued units one at a time, feeding each chunk into the
  /// continuous PCM player as it arrives: playback of earlier audio
  /// overlaps synthesis of later units. A streaming-endpoint failure falls
  /// back to the batch endpoint for the remainder of the session; a unit
  /// that fails on both is skipped with its error surfaced.
  void _pumpSynthesis(int gen) {
    if (_synthesisInFlight) return;
    if (_sentenceQueue.isEmpty) {
      _checkSpeechDrained(gen);
      return;
    }
    _synthesisInFlight = true;
    final sentence = _sentenceQueue.removeAt(0);
    () async {
      var unitStarted = false;
      var pcmTotal = 0;
      try {
        if (!_speakable.hasMatch(sentence)) {
          // Zero-audio placeholder: schedule the reveal start like a real
          // unit (it sounds when the previous unit's audio ends) but touch
          // no network — no provider can voice punctuation or emoji. The
          // shared tail below closes it with a zero duration.
          unitStarted = true;
          _noteUnitStart(gen);
        } else if (_streamEndpointOk) {
          try {
            await for (final chunk in speechClient.synthesizeStream(text: sentence)) {
              if (gen != _speechGeneration) return;
              if (!unitStarted) {
                unitStarted = true;
                _noteUnitStart(gen);
              }
              pcmTotal += await _pcmPlayerFor(gen).feed(chunk);
            }
          } on SpeechException catch (e) {
            if (gen != _speechGeneration) return;
            if (unitStarted) {
              // Mid-stream failure: partial audio already feeds the player;
              // re-synthesizing would duplicate it. Close the unit with
              // what fed and surface the error.
              _noteUnitEnd(pcmTotal);
              _error = e.message;
              notifyListeners();
            } else {
              // The streaming endpoint is optional; a 404/403 means the
              // host runs an older dsh-speech. Fall back for this session.
              _streamEndpointOk = false;
              await _synthesizeBatchInto(gen, sentence, e);
            }
            return;
          }
        } else {
          await _synthesizeBatchInto(gen, sentence, null);
        }
        if (gen == _speechGeneration && unitStarted) {
          _noteUnitEnd(pcmTotal);
        }
      } catch (e) {
        if (gen == _speechGeneration) {
          if (!unitStarted) {
            _noteUnitFailed(gen);
          } else {
            _noteUnitEnd(pcmTotal);
          }
          _error = e is SpeechException ? e.message : '语音合成失败: $e';
          notifyListeners();
        }
      } finally {
        if (gen == _speechGeneration) {
          _synthesisInFlight = false;
          _checkSpeechDrained(gen);
          _pumpSynthesis(gen);
        }
      }
    }();
  }

  /// Batch fallback: synthesize [sentence] in one request and feed the
  /// complete WAV document into the PCM player (its header parser strips
  /// the container, so the stream stays continuous).
  Future<void> _synthesizeBatchInto(int gen, String sentence, Object? streamError) async {
    try {
      final result = await speechClient.synthesize(text: sentence);
      if (gen != _speechGeneration) return;
      _noteUnitStart(gen);
      final pcm = await _pcmPlayerFor(gen).feed(result.bytes);
      _noteUnitEnd(pcm);
    } catch (e) {
      if (gen != _speechGeneration) return;
      _noteUnitFailed(gen);
      if (streamError != null) {
        _error = e is SpeechException ? e.message : '语音合成失败: $e';
        notifyListeners();
      } else {
        rethrow;
      }
    }
  }

  /// The session's PCM player, created on first audio.
  PcmStreamPlayer _pcmPlayerFor(int gen) => _pcmPlayer ??= PcmStreamPlayer();

  /// Finish the session when the stream is closed, the text queue is
  /// empty, synthesis is idle, and the PCM stream has played out: retire
  /// the generation, return to idle, and re-arm the microphone for the
  /// conversation loop.
  void _checkSpeechDrained(int gen) {
    if (gen != _speechGeneration) return;
    if (!_speechStreamFinished) return;
    if (_sentenceQueue.isNotEmpty || _synthesisInFlight) return;
    final player = _pcmPlayer;
    if (player == null) {
      _finishSpeechSession();
      return;
    }
    // Arm first: if playback already drained after the last feed, this
    // completes immediately; otherwise the next native zero-crossing does.
    player.armDrain();
    player.drained.then((_) {
      if (gen != _speechGeneration) return;
      _finishSpeechSession();
    });
  }

  void _finishSpeechSession() {
    _speechGeneration++;
    _speechStreamFinished = false;
    _state = SpeechState.idle;
    _clearRevealTimers();
    _feedingUnit = -1;
    _unitDurations.clear();
    _unitStarts.clear();
    final player = _pcmPlayer;
    _pcmPlayer = null;
    if (player != null) player.stop();
    notifyListeners();
    _resumeListening();
  }

  /// Re-arm the microphone when the loop is active and nothing else is
  /// running.
  void _resumeListening() {
    if (!_conversing || _state != SpeechState.idle) return;
    _beginRecording();
  }

  void _checkSilence(Timer _) {
    if (_state != SpeechState.recording) return;
    // A recording with no detected speech never auto-stops: ambient noise
    // must not end (and upload) a turn the user never began.
    if (!_speechStarted) return;
    final last = _lastSpeechAt;
    if (last == null) return;
    final elapsed = DateTime.now().difference(last).inMilliseconds;
    if (elapsed >= _silenceDurationMs) {
      _stopAndTranscribe();
    }
  }

  /// Generate a temp file path for the recording.
  Future<String> _tempPath() async {
    final dir = await Directory.systemTemp.createTemp('dsh_voice');
    return '${dir.path}\\rec.wav';
  }
  static double dbToAmplitude(double db) {
    if (db >= 0) return 1;
    const minDb = -50.0;
    final clamped = db.clamp(minDb, 0.0);
    return pow((clamped - minDb) / (-minDb), 2).toDouble();
  }

  @override
  void dispose() {
    _conversing = false;
    _speechGeneration++;
    _sentenceQueue.clear();
    _clearRevealTimers();
    _pcmPlayer?.stop();
    _pcmPlayer = null;
    _silenceTimer?.cancel();
    _amplitudeTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }
}
