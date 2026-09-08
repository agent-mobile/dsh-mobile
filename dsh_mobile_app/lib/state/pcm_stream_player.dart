/// Continuous PCM playback: an AudioTrack-style feed sink for streamed
/// speech audio. WAV bytes are fed as they arrive; the header parser strips
/// the RIFF container on the first chunk, and PCM frames are queued to the
/// native stream player, which plays them back-to-back with no per-clip
/// gaps. One [PcmStreamPlayer] instance serves one speech session; [stop]
/// drops the queue and releases the audio route so a following recording
/// can take the microphone.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';/// Reassembles a chunked WAV stream: buffers until the RIFF header is fully
/// parsed, then passes through raw PCM16 frames (any chunk alignment).
class WavFrameExtractor {
  bool _headerConsumed = false;
  final List<int> _pending = [];

  /// Sample rate declared by the WAV header; null before it is parsed.
  int? sampleRate;

  /// Channels declared by the WAV header; null before it is parsed.
  int? channels;

  /// Feed one stream chunk; returns the PCM bytes it completed (empty when
  /// the chunk only carried header material).
  Uint8List feed(Uint8List chunk) {
    if (_headerConsumed) return chunk;
    _pending.addAll(chunk);
    final pcm = _parseHeader();
    if (pcm == null) return Uint8List(0);
    return pcm;
  }

  /// Walk RIFF chunks to locate `data`; returns the PCM that followed in
  /// the pending buffer, or null when the header is still incomplete.
  Uint8List? _parseHeader() {
    final b = _pending;
    bool isAscii(int off, String tag) =>
        b.length >= off + 4 && tag.codeUnits.every((c) => b[off + tag.indexOf(String.fromCharCode(c))] == c);
    if (b.length < 12) return null;
    if (!(isAscii(0, 'RIFF') && isAscii(8, 'WAVE'))) {
      // Not a WAV header at all: treat the whole stream as raw PCM.
      _headerConsumed = true;
      return Uint8List.fromList(b);
    }
    var offset = 12;
    int? rate;
    int? ch;
    while (offset + 8 <= b.length) {
      final chunkId = String.fromCharCodes(b.sublist(offset, offset + 4));
      final chunkSize = b[offset + 4] |
          (b[offset + 5] << 8) |
          (b[offset + 6] << 16) |
          (b[offset + 7] << 24);
      final body = offset + 8;
      if (body + chunkSize > b.length) return null; // header chunk incomplete
      if (chunkId == 'fmt ') {
        if (chunkSize < 16) {
          _headerConsumed = true;
          return Uint8List(0);
        }
        ch = b[body] | (b[body + 1] << 8);
        rate = b[body + 4] |
            (b[body + 5] << 8) |
            (b[body + 6] << 16) |
            (b[body + 7] << 24);
      } else if (chunkId == 'data') {
        // Streamed WAV writers declare the FINAL data size (or a rough
        // estimate) in the header while the body is still arriving, so the
        // declared size must never gate extraction: everything after the
        // data-chunk header is PCM, from here to the end of the stream.
        sampleRate = rate;
        channels = ch ?? 1;
        _headerConsumed = true;
        final pcm = Uint8List.fromList(b.sublist(body));
        _pending.clear();
        return pcm;
      }
      offset = body + chunkSize + (chunkSize % 2);
    }
    return null; // data chunk not reached yet
  }
}

/// A continuous PCM16 playback sink backed by flutter_pcm_sound's native
/// AudioTrack (stream mode). Feeding is non-blocking; the native queue
/// drains at playback pace.
class PcmStreamPlayer {
  bool _setup = false;
  final WavFrameExtractor _extractor = WavFrameExtractor();

  /// Sample rate of the stream, known once the WAV header parsed.
  int? get sampleRate => _extractor.sampleRate;

  /// Channel count of the stream, known once the WAV header parsed.
  int? get channels => _extractor.channels;

  /// Future completing when the fed audio has fully played after
  /// [armDrain], or on [stop].
  Future<void> get drained => _drained.future;

  final Completer<void> _drained = Completer<void>();

  bool _stopped = false;

  /// Drain is armed only after the input stream closes: the native queue
  /// legitimately hits zero between sentences mid-stream, and those
  /// zero-crossings must not end the session or truncate the tail.
  bool _drainArmed = false;
  DateTime? _lastFeedAt;
  DateTime? _lastZeroAt;

  /// Feed one chunk of the WAV stream. The first feed triggers native
  /// setup with the header's sample rate. Trailing odd bytes (a split
  /// PCM16 frame) are held back until the next feed. Returns the PCM byte
  /// count queued (0 while only header material arrived).
  final List<int> _tail = [];

  Future<int> feed(Uint8List wavChunk) async {
    if (_stopped) return 0;
    final pcm = _extractor.feed(wavChunk);
    if (!_setup) {
      final rate = _extractor.sampleRate;
      if (rate == null) return 0; // header not complete yet; wait for more
      await FlutterPcmSound.setup(sampleRate: rate, channelCount: _extractor.channels ?? 1);
      await FlutterPcmSound.setFeedThreshold(0);
      FlutterPcmSound.setFeedCallback((remaining) {
        if (remaining == 0) {
          _lastZeroAt = DateTime.now();
          _maybeCompleteDrain();
        }
      });
      _setup = true;
    }
    _lastFeedAt = DateTime.now();
    var bytes = _tail.toList()..addAll(pcm);
    _tail.clear();
    if (bytes.isEmpty) return 0;
    if (bytes.length.isOdd) {
      _tail.add(bytes.removeLast());
    }
    if (bytes.isEmpty) return 0;
    await FlutterPcmSound.feed(
      PcmArrayInt16(bytes: Uint8List.fromList(bytes).buffer.asByteData()),
    );
    return bytes.length;
  }

  /// Arm drain detection: [drained] completes once the native queue next
  /// empties (or immediately, when playback already finished after the
  /// last feed). Before this, zero-crossings are ignored.
  void armDrain() {
    if (_drained.isCompleted) return;
    if (!_setup) {
      _drained.complete();
      return;
    }
    _drainArmed = true;
    _maybeCompleteDrain();
  }

  void _maybeCompleteDrain() {
    if (!_drainArmed || _drained.isCompleted) return;
    final fed = _lastFeedAt;
    final zero = _lastZeroAt;
    // Drained only when a zero-crossing happened after the last feed; a
    // pending queue will produce one when it empties.
    if (fed != null && zero != null && zero.isAfter(fed)) {
      _drained.complete();
    }
  }

  /// Drop queued audio, release the native player, and complete [drained].
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    if (!_drained.isCompleted) _drained.complete();
    try {
      await FlutterPcmSound.release();
    } catch (_) {}
  }
}
