/// Sprite mascot pack loading: decodes the layer PNGs of a pack folder
/// (assets/mascots/, one directory per id) together with the pack manifest,
/// cached once per process. Flutter cannot enumerate asset directories on
/// mobile, so packs are registered by id in [MascotSkinRegistry.knownIds] —
/// adding a pack is copying its folder into assets/mascots/ and appending
/// its id there.
library;

import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;

import 'mascot_manifest.dart';

/// Decoded sprite layers for one mascot pack. All layers share the manifest
/// canvas size (each is a full-canvas PNG with the part drawn in place);
/// parts listed in `manifest.missing` are null and skipped by the renderer.
class SpriteMascotAssets {
  const SpriteMascotAssets({
    required this.manifest,
    required this.body,
    this.eyes,
    this.eyeLeft,
    this.eyeRight,
    this.mouthClosed,
    this.mouthOpen,
    this.clawLeft,
    this.clawRight,
    this.footLeft,
    this.footRight,
    this.antennaLeft,
    this.antennaRight,
  });

  final MascotManifest manifest;

  /// The body silhouette with cut-outs for the other layers; required — a
  /// pack without it is rejected at load time.
  final ui.Image body;

  /// Combined eyes fallback layer, used only when neither split eye exists.
  final ui.Image? eyes;
  final ui.Image? eyeLeft;
  final ui.Image? eyeRight;
  final ui.Image? mouthClosed;

  /// Open-mouth frame; falls back to [mouthClosed] when the pack ships none.
  final ui.Image? mouthOpen;
  final ui.Image? clawLeft;
  final ui.Image? clawRight;
  final ui.Image? footLeft;
  final ui.Image? footRight;
  final ui.Image? antennaLeft;
  final ui.Image? antennaRight;

  /// The layer for [name], or null when the manifest marks it missing.
  ui.Image? layer(String name) {
    if (manifest.isMissingPart(name)) return null;
    return switch (name) {
      'eyes' => eyes,
      'eye_left' => eyeLeft,
      'eye_right' => eyeRight,
      'mouth_closed' => mouthClosed,
      'mouth_open' => mouthOpen,
      'claw_left' => clawLeft,
      'claw_right' => clawRight,
      'foot_left' => footLeft,
      'foot_right' => footRight,
      'antenna_left' => antennaLeft,
      'antenna_right' => antennaRight,
      _ => null,
    };
  }
}

/// Resolves and caches sprite mascot packs by id.
abstract final class MascotSkinRegistry {
  static const String deepseekId = 'deepseek';

  /// Pack ids shipped in assets/mascots/.
  static const List<String> knownIds = [deepseekId];

  /// Asset keys keep the full package-relative path, including the
  /// `assets/` prefix of the declared directory.
  static const String _assetsRoot = 'assets/mascots';

  /// Downscale factor for decoded layers: full-res 1024px layers are ~32MB
  /// RGBA across the pack; 512px is indistinguishable at display size.
  static const int _decodeWidth = 512;

  static final Map<String, SpriteMascotAssets?> _resolved = {};
  static final Map<String, Future<SpriteMascotAssets?>> _inflight = {};

  /// Decodes the pack for [id], or null when the manifest is missing/broken
  /// or a required layer fails to decode. Repeated calls share one load; a
  /// resolved id returns a fresh future in the caller's zone (a cached
  /// future completed elsewhere would not notify listeners registered from
  /// another zone, e.g. inside a FakeAsync test body).
  static Future<SpriteMascotAssets?> resolve(String id) {
    if (_resolved.containsKey(id)) return Future.value(_resolved[id]);
    return _inflight.putIfAbsent(id, () async {
      final value = await _load(id);
      _resolved[id] = value;
      _inflight.remove(id);
      return value;
    });
  }

  static Future<SpriteMascotAssets?> _load(String id) async {
    try {
      final source = await rootBundle.loadString('$_assetsRoot/$id/manifest.json');
      final manifest = MascotManifest.tryParse(source);
      if (manifest == null || manifest.id != id) return null;
      if (manifest.isMissingPart('body')) return null;

      final body = await _layer(id, 'body');
      if (body == null) return null;
      final eyeLeft = await _optionalLayer(id, manifest, 'eye_left');
      final eyeRight = await _optionalLayer(id, manifest, 'eye_right');
      final mouthClosed = await _optionalLayer(id, manifest, 'mouth_closed');
      return SpriteMascotAssets(
        manifest: manifest,
        body: body,
        // The combined layer is only needed when no split eye exists.
        eyes: (eyeLeft == null && eyeRight == null)
            ? await _optionalLayer(id, manifest, 'eyes')
            : null,
        eyeLeft: eyeLeft,
        eyeRight: eyeRight,
        mouthClosed: mouthClosed,
        // A pack without an open-mouth frame reuses the closed one.
        mouthOpen: await _optionalLayer(id, manifest, 'mouth_open') ??
            mouthClosed,
        clawLeft: await _optionalLayer(id, manifest, 'claw_left'),
        clawRight: await _optionalLayer(id, manifest, 'claw_right'),
        footLeft: await _optionalLayer(id, manifest, 'foot_left'),
        footRight: await _optionalLayer(id, manifest, 'foot_right'),
        antennaLeft: await _optionalLayer(id, manifest, 'antenna_left'),
        antennaRight: await _optionalLayer(id, manifest, 'antenna_right'),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image?> _optionalLayer(
    String id,
    MascotManifest manifest,
    String name,
  ) async {
    if (manifest.isMissingPart(name)) return null;
    try {
      return await _layer(id, name);
    } catch (_) {
      return null;
    }
  }

  static Future<ui.Image?> _layer(String id, String name) async {
    final data = await rootBundle.load('$_assetsRoot/$id/$name.png');
    final bytes =
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    final decoder = await ui.instantiateImageCodec(bytes, targetWidth: _decodeWidth);
    return (await decoder.getNextFrame()).image;
  }
}
