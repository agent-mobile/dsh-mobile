/// Layered sprite mascot pack manifest, as produced by the mascot-plans
/// pipeline. Geometry is per-skin; the shared animation timeline in
/// talk_mascot.dart multiplies these values each frame. The manifest is the
/// single source of truth for all pack geometry — the renderer hardcodes no
/// coordinates.
library;

import 'dart:convert';

/// One point in pack-pixel space (the manifest canvas coordinate system).
class MascotPoint {
  const MascotPoint(this.x, this.y);

  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      other is MascotPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}

/// The pack canvas size in pixels; every layer shares it.
class MascotCanvasSize {
  const MascotCanvasSize(this.width, this.height);

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is MascotCanvasSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// Eye geometry: per-eye centers for the blink squash and the mode-colored
/// highlight dots ([highlightOffset] (0,0) disables the dots).
class MascotEyes {
  const MascotEyes({
    required this.leftCenter,
    required this.rightCenter,
    required this.radius,
    this.highlightOffset = const MascotPoint(0, 0),
  });

  final MascotPoint leftCenter;
  final MascotPoint rightCenter;

  /// Eye radius in pack pixels (highlight dots use `radius * 0.45`).
  final double radius;

  final MascotPoint highlightOffset;
}

/// Mouth geometry for the closed/open crossfade frames.
class MascotMouth {
  const MascotMouth({
    required this.center,
    required this.closedSize,
    required this.openMaxSize,
  });

  final MascotPoint center;

  /// Closed-frame extent in pack pixels.
  final ({double w, double h}) closedSize;

  /// Open-frame max extent in pack pixels.
  final ({double w, double h}) openMaxSize;
}

/// Per-pack amplitude multipliers: the shared timeline's degree values are
/// scaled by these before reaching a part, so packs can retune motion without
/// touching the animation code.
class MascotAmplitude {
  const MascotAmplitude({
    this.clawDegMultiplier = 1,
    this.handDegMultiplier = 1,
    this.footDegMultiplier = 1,
    this.antennaDegMultiplier = 1,
    this.bodySwingMultiplier = 1,
    this.floatMultiplier = 1,
  });

  final double clawDegMultiplier;
  final double handDegMultiplier;
  final double footDegMultiplier;
  final double antennaDegMultiplier;
  final double bodySwingMultiplier;
  final double floatMultiplier;

  @override
  bool operator ==(Object other) =>
      other is MascotAmplitude &&
      other.clawDegMultiplier == clawDegMultiplier &&
      other.handDegMultiplier == handDegMultiplier &&
      other.footDegMultiplier == footDegMultiplier &&
      other.antennaDegMultiplier == antennaDegMultiplier &&
      other.bodySwingMultiplier == bodySwingMultiplier &&
      other.floatMultiplier == floatMultiplier;

  @override
  int get hashCode => Object.hash(
        clawDegMultiplier,
        handDegMultiplier,
        footDegMultiplier,
        antennaDegMultiplier,
        bodySwingMultiplier,
        floatMultiplier,
      );
}

/// Parsed `assets/mascots/<id>/manifest.json`. [missing] lists part names
/// (e.g. `eye_right`) this character does not have; the loader leaves those
/// layers null and the renderer skips them.
class MascotManifest {
  const MascotManifest({
    required this.id,
    required this.name,
    required this.canvas,
    this.missing = const [],
    this.pivots = const {},
    required this.eyes,
    required this.mouth,
    this.amplitude = const MascotAmplitude(),
  });

  final String id;
  final String name;
  final MascotCanvasSize canvas;
  final List<String> missing;

  /// Rotation pivots per part name (`claw_left`, `antenna_right`, ...) in
  /// pack pixels.
  final Map<String, MascotPoint> pivots;
  final MascotEyes eyes;
  final MascotMouth mouth;
  final MascotAmplitude amplitude;

  bool isMissingPart(String part) => missing.contains(part);

  /// Parses a manifest document; null when required fields are absent or
  /// malformed (callers fall back to no mascot).
  static MascotManifest? tryParse(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;

    String? str(Object? v) => v is String && v.isNotEmpty ? v : null;
    double? asNum(Object? v) => v is num ? v.toDouble() : null;

    MascotPoint? point(Object? raw) {
      if (raw is! Map) return null;
      final x = asNum(raw['x']);
      final y = asNum(raw['y']);
      return x == null || y == null ? null : MascotPoint(x, y);
    }

    ({double w, double h})? extent(Object? raw) {
      if (raw is! Map) return null;
      final w = asNum(raw['w']);
      final h = asNum(raw['h']);
      return w == null || h == null ? null : (w: w, h: h);
    }

    final id = str(decoded['id']);
    final name = str(decoded['name']);
    if (id == null || name == null) return null;

    final canvasRaw = decoded['canvas'];
    if (canvasRaw is! Map) return null;
    final width = (canvasRaw['width'] as num?)?.toInt();
    final height = (canvasRaw['height'] as num?)?.toInt();
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }

    final eyesRaw = decoded['eyes'];
    if (eyesRaw is! Map) return null;
    final leftCenter = point(eyesRaw['left_center']);
    final rightCenter = point(eyesRaw['right_center']);
    final eyeRadius = asNum(eyesRaw['radius']);
    if (leftCenter == null || rightCenter == null || eyeRadius == null) {
      return null;
    }

    final mouthRaw = decoded['mouth'];
    if (mouthRaw is! Map) return null;
    final mouthCenter = point(mouthRaw['center']);
    final closedSize = extent(mouthRaw['closed_size']);
    final openMaxSize = extent(mouthRaw['open_max_size']);
    if (mouthCenter == null || closedSize == null || openMaxSize == null) {
      return null;
    }

    final missing = <String>[];
    if (decoded['missing'] is List) {
      for (final item in decoded['missing']! as List) {
        if (item is String) missing.add(item);
      }
    }

    final pivots = <String, MascotPoint>{};
    if (decoded['pivots'] is Map) {
      (decoded['pivots']! as Map).forEach((key, value) {
        final p = point(value);
        if (key is String && p != null) pivots[key] = p;
      });
    }

    MascotAmplitude amplitude = const MascotAmplitude();
    if (decoded['amplitude'] is Map) {
      final a = decoded['amplitude']! as Map;
      amplitude = MascotAmplitude(
        clawDegMultiplier: asNum(a['claw_deg_multiplier']) ?? 1,
        handDegMultiplier: asNum(a['hand_deg_multiplier']) ?? 1,
        footDegMultiplier: asNum(a['foot_deg_multiplier']) ?? 1,
        antennaDegMultiplier: asNum(a['antenna_deg_multiplier']) ?? 1,
        bodySwingMultiplier: asNum(a['body_swing_multiplier']) ?? 1,
        floatMultiplier: asNum(a['float_multiplier']) ?? 1,
      );
    }

    return MascotManifest(
      id: id,
      name: name,
      canvas: MascotCanvasSize(width, height),
      missing: missing,
      pivots: pivots,
      eyes: MascotEyes(
        leftCenter: leftCenter,
        rightCenter: rightCenter,
        radius: eyeRadius,
        highlightOffset: point(eyesRaw['highlight_offset']) ??
            const MascotPoint(0, 0),
      ),
      mouth: MascotMouth(
        center: mouthCenter,
        closedSize: closedSize,
        openMaxSize: openMaxSize,
      ),
      amplitude: amplitude,
    );
  }
}
