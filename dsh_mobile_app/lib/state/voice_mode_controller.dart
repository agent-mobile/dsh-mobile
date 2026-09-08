/// Global voice/text mode controller: persists the user's choice across app
/// restarts using flutter_secure_storage (same pattern as ThemeController).
///
/// In text mode the chat input dock stays as-is; in voice mode the input dock
/// is replaced by a voice waveform recorder and assistant replies are spoken
/// via TTS. The choice is global — it applies to all sessions.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The two interaction modes.
enum VoiceMode { text, voice }

/// Stringified values persisted in secure storage.
const _textMode = 'text';
const _voiceMode = 'voice';

/// Global voice/text mode preference persisted across restarts.
class VoiceModeController extends ChangeNotifier {
  VoiceModeController({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _storageKey = 'dsh_voice_mode';

  final FlutterSecureStorage _storage;

  VoiceMode _mode = VoiceMode.text;

  /// Current mode; defaults to text before [load] resolves.
  VoiceMode get mode => _mode;

  /// Whether the app is in voice mode.
  bool get isVoice => _mode == VoiceMode.voice;

  /// Restore the persisted preference.
  Future<void> load() async {
    try {
      final stored = await _storage.read(key: _storageKey);
      if (stored == _voiceMode) {
        _mode = VoiceMode.voice;
        notifyListeners();
      } else {
        _mode = VoiceMode.text;
      }
    } catch (_) {
      // Storage unavailable (e.g. widget tests); keep the default.
    }
  }

  /// Persist and apply a new mode.
  Future<void> setMode(VoiceMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    try {
      await _storage.write(
        key: _storageKey,
        value: mode == VoiceMode.voice ? _voiceMode : _textMode,
      );
    } catch (_) {
      // Storage unavailable; in-memory mode still applies for this run.
    }
  }

  /// Toggle between text and voice.
  Future<void> toggle() => setMode(isVoice ? VoiceMode.text : VoiceMode.voice);
}