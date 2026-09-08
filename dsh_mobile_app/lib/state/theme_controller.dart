/// App-level appearance preference: dark / light / system, persisted on the
/// device with flutter_secure_storage (the same store as server/token). This
/// is a per-device preference — it does not read or write the host-side
/// `ui-theme` settings namespace, which drives the web client's rendering.
library;

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The app's appearance preference. Holds the current [ThemeMode] and
/// persists changes so the choice survives app restarts.
class ThemeController extends ChangeNotifier {
  ThemeController({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _storageKey = 'dsh_theme';

  final FlutterSecureStorage _storage;

  ThemeMode _mode = ThemeMode.dark;

  /// Current appearance preference; defaults to dark (the shipped product
  /// identity) before [load] resolves.
  ThemeMode get mode => _mode;

  /// Restore the persisted preference; a missing or unreadable value keeps
  /// the dark default.
  Future<void> load() async {
    try {
      final stored = await _storage.read(key: _storageKey);
      if (stored == null) return;
      final mode = switch (stored) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };
      if (mode != _mode) {
        _mode = mode;
        notifyListeners();
      }
    } catch (_) {
      // Storage unavailable (e.g. widget tests); keep the default.
    }
  }

  /// Persist and apply a new preference.
  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    try {
      await _storage.write(key: _storageKey, value: switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.system => 'system',
        ThemeMode.dark => 'dark',
      });
    } catch (_) {
      // Storage unavailable; the in-memory preference still applies for this run.
    }
  }
}
