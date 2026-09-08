/// Talk mascot: a layered-sprite character that animates through the voice
/// conversation states (idle / listening / speaking / thinking). Ported from
/// OpenClaw Android's TalkMascot.kt (state machine + keyframe timeline) and
/// SpriteMascotRenderer.kt (layered drawing); all pack geometry comes from
/// the pack's manifest.json under assets/mascots/.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'mascot_assets.dart';
import 'mascot_manifest.dart';

/// Voice-state modes, in display priority order (speaking wins over
/// listening, listening over thinking).
enum TalkMascotMode { idle, listening, speaking, thinking }

/// One frame's pose values — the shared time layer of the animation. Angles
/// are degrees; [floatOffset] is in 120-unit design space (the reference
/// scales a 120-unit design onto the canvas); ratios are 0..1. Mirrors the
/// reference's SpriteMascotPose.
class MascotPose {
  const MascotPose({
    required this.bodyTiltDeg,
    required this.floatOffset,
    required this.leftClawDeg,
    required this.rightClawDeg,
    required this.leftFootDeg,
    required this.rightFootDeg,
    required this.antennaDeg,
    required this.mouthOpen,
    required this.eyeBlink,
    required this.eyeGlowAlpha,
  });

  final double bodyTiltDeg;
  final double floatOffset;
  final double leftClawDeg;
  final double rightClawDeg;
  final double leftFootDeg;
  final double rightFootDeg;
  final double antennaDeg;

  /// Mouth crossfade amount: 0 = closed frame, 1 = open frame.
  final double mouthOpen;

  /// Eye squash factor (1 = open). The renderer clamps it to [0.3, 1].
  final double eyeBlink;

  /// Highlight-dot alpha multiplier (mode-colored dots on the eyes).
  final double eyeGlowAlpha;
}

/// Shared animation timeline, ported from TalkMascot.kt's keyframes with the
/// same periods, amplitudes, and per-mode selection. Pure function of time
/// so it can be unit-tested without a widget.
abstract final class MascotTimeline {
  static const double _twoPi = 2 * math.pi;

  /// One frame's pose. [leftClawBase], [rightClawBase] and [listenLeanDeg]
  /// are the mode-tweened listening offsets (the widget tweens them over
  /// 400ms on mode change); pass the steady-state targets (-25 / 25 / 12 for
  /// listening, 0 otherwise) for settled poses.
  static MascotPose pose({
    required double tSeconds,
    required TalkMascotMode mode,
    double leftClawBase = 0,
    double rightClawBase = 0,
    double listenLeanDeg = 0,
    double eyeGlowAlpha = 1,
  }) {
    final floatOffset = -10 * math.sin(_twoPi * tSeconds / 4); // float: 4s ±10
    final clawOsc = -15 * math.sin(_twoPi * tSeconds / 4); // claws idle: 4s ±15
    final walk = 14 * math.sin(_twoPi * tSeconds / 0.6); // feet: 600ms ±14

    double bodyTiltDeg;
    double leftClawDeg;
    double rightClawDeg;
    double antennaDeg;
    double mouthOpen;
    switch (mode) {
      case TalkMascotMode.idle:
        bodyTiltDeg = 0;
        leftClawDeg = clawOsc;
        rightClawDeg = -clawOsc;
        antennaDeg = 12 * math.sin(_twoPi * tSeconds / 2); // sway: 2s ±12
        mouthOpen = 0;
      case TalkMascotMode.listening:
        bodyTiltDeg = listenLeanDeg; // lean: tweened to 12
        leftClawDeg = leftClawBase + clawOsc; // base tweened to -25
        rightClawDeg = rightClawBase + clawOsc; // base tweened to 25
        antennaDeg = 8 * math.sin(_twoPi * tSeconds / 0.25); // tremor: 250ms ±8
        mouthOpen = 0;
      case TalkMascotMode.speaking:
        final swing = 12 * math.sin(_twoPi * tSeconds / 0.8); // body: 800ms ±12
        bodyTiltDeg = swing;
        leftClawDeg = -30 + (math.sin(_twoPi * tSeconds / 0.6) * 0.5 + 0.5) * 35;
        rightClawDeg =
            -5 + (math.sin(_twoPi * tSeconds / 0.6 + math.pi) * 0.5 + 0.5) * 35;
        antennaDeg = swing;
        mouthOpen = 0.5 + 0.5 * math.sin(_twoPi * tSeconds / 0.3); // 300ms 0..1
      case TalkMascotMode.thinking:
        bodyTiltDeg = 3 * math.sin(_twoPi * tSeconds / 0.5); // bob: 500ms ±3
        final tap = math.sin(_twoPi * tSeconds / 0.4); // taps: 400ms, alternating
        leftClawDeg = -8 * tap;
        rightClawDeg = 8 * tap;
        antennaDeg = 6 * math.sin(_twoPi * tSeconds / 0.18); // 180ms ±6
        mouthOpen = 0;
    }

    return MascotPose(
      bodyTiltDeg: bodyTiltDeg,
      floatOffset: floatOffset,
      leftClawDeg: leftClawDeg,
      rightClawDeg: rightClawDeg,
      leftFootDeg: walk,
      rightFootDeg: -walk,
      antennaDeg: antennaDeg,
      mouthOpen: mouthOpen,
      // The eye only blinks while idle; other modes hold it open.
      eyeBlink: mode == TalkMascotMode.idle ? blinkAmount(tSeconds % 3) : 1,
      eyeGlowAlpha: eyeGlowAlpha,
    );
  }

  /// Blink over a 3s cycle (reference keyframes): open until 2.5s, ease to
  /// 0.12 by 2.72s, hold closed to 2.92s, ease back open by 2.99s. The
  /// renderer clamps the result to [0.3, 1] before squashing the eye layer.
  static double blinkAmount(double phaseSeconds) {
    if (phaseSeconds < 2.5) return 1;
    if (phaseSeconds < 2.72) {
      return 1 - 0.88 * _ease((phaseSeconds - 2.5) / 0.22);
    }
    if (phaseSeconds < 2.92) return 0.12;
    if (phaseSeconds < 2.99) {
      return 0.12 + 0.88 * _ease((phaseSeconds - 2.92) / 0.07);
    }
    return 1;
  }

  /// Pulse-ring phase for the mode: listening 1500ms, speaking 600ms,
  /// thinking 800ms, idle none (0).
  static double pulseValue({
    required double tSeconds,
    required TalkMascotMode mode,
  }) =>
      switch (mode) {
        TalkMascotMode.idle => 0,
        TalkMascotMode.listening => (tSeconds % 1.5) / 1.5,
        TalkMascotMode.speaking => (tSeconds % 0.6) / 0.6,
        TalkMascotMode.thinking => (tSeconds % 0.8) / 0.8,
      };

  static double _ease(double x) {
    final c = x.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }
}

/// Animated mascot overlay. [listening]/[speaking]/[thinking] are driven by
/// the caller from the speech state; the widget sizes to its parent — wrap
/// it in a square SizedBox. Renders nothing until the sprite pack finishes
/// loading (and stays empty if the pack is missing, degrading to no overlay).
class TalkMascot extends StatefulWidget {
  const TalkMascot({
    super.key,
    required this.listening,
    required this.speaking,
    this.thinking = false,
    this.skinId = MascotSkinRegistry.deepseekId,
  });

  /// Microphone is capturing or the recording is being transcribed.
  final bool listening;

  /// TTS playback is active.
  final bool speaking;

  /// Text is generating while the microphone is closed (optional).
  final bool thinking;

  /// Sprite pack id under assets/mascots/.
  final String skinId;

  /// Display mode from the raw speech booleans: speaking wins over
  /// listening, listening over thinking.
  static TalkMascotMode modeOf({
    required bool listening,
    required bool speaking,
    required bool thinking,
  }) =>
      switch ((speaking, listening, thinking)) {
        (true, _, _) => TalkMascotMode.speaking,
        (_, true, _) => TalkMascotMode.listening,
        (_, _, true) => TalkMascotMode.thinking,
        _ => TalkMascotMode.idle,
      };

  @override
  State<TalkMascot> createState() => _TalkMascotState();
}

class _TalkMascotState extends State<TalkMascot>
    with SingleTickerProviderStateMixin {
  /// Every timeline period (4s, 2s, 3s, 1.5s, 0.8s, 0.6s, 0.5s, 0.4s,
  /// 0.3s, 0.25s, 0.18s) divides this LCM, so the pose is exactly periodic
  /// in it: the wrapping controller yields absolute time with no drift and
  /// a seamless wrap.
  static const int _timelinePeriodMs = 36000;

  /// Per-frame tick driver; absolute time comes from its value plus the
  /// completed-cycle count, so the pure-function pose never drifts on
  /// dropped frames.
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _timelinePeriodMs),
  )..repeat();

  int _cycles = 0;

  SpriteMascotAssets? _assets;
  TalkMascotMode _lastMode = TalkMascotMode.idle;
  bool _animationsEnabled = true;

  // Mode-tweened scalars (reference: animateFloatAsState, tween 400ms).
  late final _Tweened _overlayAlpha = _Tweened(0.5);
  late final _Tweened _leftClawBase = _Tweened(0);
  late final _Tweened _rightClawBase = _Tweened(0);
  late final _Tweened _listenLean = _Tweened(0);
  late final _Tweened _eyeGlowAlpha = _Tweened(0.6);

  int get _nowMs =>
      _cycles * _timelinePeriodMs + (_clock.value * _timelinePeriodMs).round();

  @override
  void initState() {
    super.initState();
    _clock.addStatusListener((status) {
      if (status == AnimationStatus.completed) _cycles++;
    });
    _loadAssets(widget.skinId);
  }

  @override
  void didUpdateWidget(TalkMascot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.skinId != widget.skinId) _loadAssets(widget.skinId);
  }

  void _loadAssets(String skinId) {
    MascotSkinRegistry.resolve(skinId).then((assets) {
      if (!mounted || assets == null) return;
      setState(() => _assets = assets);
    });
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  void _retarget(TalkMascotMode mode, int nowMs) {
    final duration =
        _animationsEnabled ? const Duration(milliseconds: 400) : Duration.zero;
    _overlayAlpha.retarget(_overlayAlphaTarget(mode), duration, nowMs);
    _leftClawBase.retarget(mode == TalkMascotMode.listening ? -25 : 0, duration,
        nowMs);
    _rightClawBase.retarget(mode == TalkMascotMode.listening ? 25 : 0, duration,
        nowMs);
    _listenLean.retarget(mode == TalkMascotMode.listening ? 12 : 0, duration,
        nowMs);
    _eyeGlowAlpha.retarget(_eyeGlowTarget(mode), duration, nowMs);
  }

  static double _overlayAlphaTarget(TalkMascotMode mode) => switch (mode) {
        TalkMascotMode.speaking => 0.85,
        TalkMascotMode.listening => 0.70,
        TalkMascotMode.thinking => 0.65,
        TalkMascotMode.idle => 0.50,
      };

  static double _eyeGlowTarget(TalkMascotMode mode) => switch (mode) {
        TalkMascotMode.listening => 0.95,
        TalkMascotMode.speaking => 0.85,
        TalkMascotMode.thinking => 0.9,
        TalkMascotMode.idle => 0.6,
      };

  @override
  Widget build(BuildContext context) {
    _animationsEnabled = !MediaQuery.disableAnimationsOf(context);
    final assets = _assets;
    if (assets == null) return const SizedBox.shrink();

    final mode = TalkMascot.modeOf(
      listening: widget.listening,
      speaking: widget.speaking,
      thinking: widget.thinking,
    );

    return AnimatedBuilder(
      animation: _clock,
      builder: (context, _) {
        final nowMs = _nowMs;
        if (mode != _lastMode) {
          _lastMode = mode;
          _retarget(mode, nowMs);
        }
        final tSeconds = _animationsEnabled ? nowMs / 1000 : 0.0;
        final pose = MascotTimeline.pose(
          tSeconds: tSeconds,
          mode: mode,
          leftClawBase: _leftClawBase.value(nowMs),
          rightClawBase: _rightClawBase.value(nowMs),
          listenLeanDeg: _listenLean.value(nowMs),
          eyeGlowAlpha: _eyeGlowAlpha.value(nowMs),
        );
        return Semantics(
          label: _semanticsLabel(mode),
          child: Opacity(
            opacity: _overlayAlpha.value(nowMs),
            child: CustomPaint(
              painter: _SpriteMascotPainter(
                assets: assets,
                pose: pose,
                pulseVal: MascotTimeline.pulseValue(tSeconds: tSeconds, mode: mode),
                listening: widget.listening,
                speaking: widget.speaking,
                thinking: widget.thinking,
              ),
            ),
          ),
        );
      },
    );
  }

  String _semanticsLabel(TalkMascotMode mode) {
    final name = _assets?.manifest.name ?? 'mascot';
    return switch (mode) {
      TalkMascotMode.speaking => '$name 正在说话',
      TalkMascotMode.listening => '$name 正在聆听',
      TalkMascotMode.thinking => '$name 正在思考',
      TalkMascotMode.idle => '$name 等待中',
    };
  }
}

/// Eases [value] toward a retargeted goal; captures the current value as the
/// new start so mid-flight retargets never jump. Until the first retarget the
/// target equals the initial value, so a widget that mounts in its steady
/// mode (e.g. idle) renders at the right level instead of the zero default.
class _Tweened {
  _Tweened(double value, [double? target])
      : _value = value,
        _target = target ?? value;

  double _value;
  double _from = 0;
  double _target;
  int _startMs = 0;
  int _durationMs = 0;

  void retarget(double target, Duration duration, int nowMs) {
    _from = value(nowMs);
    _target = target;
    _startMs = nowMs;
    _durationMs = duration.inMilliseconds;
  }

  double value(int nowMs) {
    if (_durationMs <= 0) {
      _value = _target;
      return _value;
    }
    final f = ((nowMs - _startMs) / _durationMs).clamp(0.0, 1.0);
    final c = f * f * (3 - 2 * f);
    _value = _from + (_target - _from) * c;
    return _value;
  }
}

/// Draws one frame of a layered sprite mascot using the shared pose values
/// and the pack manifest's geometry. Ported from SpriteMascotRenderer.kt:
/// every layer first takes the base transform (pack→screen scale, body tilt
/// around the canvas center, float) so parts stay glued to the body, then its
/// own local transform (rotation around a manifest pivot, or the eye blink
/// squash around the eye center).
class _SpriteMascotPainter extends CustomPainter {
  const _SpriteMascotPainter({
    required this.assets,
    required this.pose,
    required this.pulseVal,
    required this.listening,
    required this.speaking,
    required this.thinking,
  });

  final SpriteMascotAssets assets;
  final MascotPose pose;
  final double pulseVal;
  final bool listening;
  final bool speaking;
  final bool thinking;

  /// Reference design space: the renderer scales a 120-unit design onto the
  /// canvas, with pack pixels mapping to it via canvas.width/120.
  static const double _designSpace = 120;

  // Mode colors mirrored from the reference so all packs share one visual
  // language.
  static const Color _eyeGlow = Color(0xFF00E5CC);
  static const Color _listenGlow = Color(0xFF3EDB82);
  static const Color _speakAccent = Color(0xFFFF6B6B);
  static const Color _thinkColor = Color(0xFFA78BFA);

  @override
  void paint(Canvas canvas, Size size) {
    final manifest = assets.manifest;
    final packW = manifest.canvas.width.toDouble();
    final packH = manifest.canvas.height.toDouble();
    final minDim = math.min(size.width, size.height);
    if (minDim <= 0 || packW <= 0 || packH <= 0) return;

    final k = minDim / packW; // pack px -> screen px
    final d2p = packW / _designSpace; // design units -> pack px
    final amp = manifest.amplitude;

    final floatDy = pose.floatOffset * amp.floatMultiplier * d2p;
    final tiltRad =
        pose.bodyTiltDeg * amp.bodySwingMultiplier * math.pi / 180;
    final center = Offset(packW / 2, packH / 2);

    // Center the square sprite inside a possibly non-square box.
    canvas.save();
    canvas.translate((size.width - minDim) / 2, (size.height - minDim) / 2);

    // 1. Pulse rings behind everything, centered on the sprite body.
    if (pulseVal > 0) {
      final color = listening
          ? _listenGlow
          : speaking
              ? _speakAccent
              : thinking
                  ? _thinkColor
                  : _eyeGlow;
      canvas.save();
      canvas.scale(k, k);
      final pc = Offset(packW / 2, packH * 0.42);
      final r = (10 + pulseVal * 25) * d2p;
      final ring = Paint()
        ..style = PaintingStyle.stroke;
      ring.strokeWidth = 3 * d2p;
      ring.color = color.withValues(alpha: (1 - pulseVal) * 0.5);
      canvas.drawCircle(pc, r, ring);
      ring.strokeWidth = 2.5 * d2p;
      ring.color = color.withValues(alpha: (1 - pulseVal) * 0.35);
      canvas.drawCircle(pc, r * 0.6, ring);
      canvas.restore();
    }

    // Shared base transform for every layer. Issued after the pack->screen
    // scale; later-issued ops apply closer to the pixels, so the point
    // pipeline is local -> float -> tilt -> scale and parts ride the body.
    void base() {
      canvas.scale(k, k);
      canvas.translate(center.dx, center.dy);
      canvas.rotate(tiltRad);
      canvas.translate(-center.dx, -center.dy);
      canvas.translate(0, floatDy);
    }

    void drawLayer(ui.Image? image,
        {double alpha = 1, void Function()? local}) {
      if (image == null || alpha <= 0) return;
      final paint = Paint()
        ..color = Color.fromRGBO(255, 255, 255, alpha)
        ..filterQuality = FilterQuality.high;
      canvas.save();
      base();
      local?.call();
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(0, 0, packW, packH),
        paint,
      );
      canvas.restore();
    }

    void rotateAround(Offset pivot, double deg) {
      canvas.translate(pivot.dx, pivot.dy);
      canvas.rotate(deg * math.pi / 180);
      canvas.translate(-pivot.dx, -pivot.dy);
    }

    // A part rotates around its manifest pivot; missing parts or pivots are
    // skipped.
    void drawAppendage(ui.Image? image, String name, double deg) {
      final pivot = manifest.pivots[name];
      if (image == null || pivot == null) return;
      drawLayer(image, local: () => rotateAround(Offset(pivot.x, pivot.y), deg));
    }

    // 2. Body.
    drawLayer(assets.body);

    // 3. Mouth: pure crossfade between closed and open frames (both are real
    // art, so no scaleY stretching — scaling real frames looks unnatural).
    if (pose.mouthOpen < 0.98) {
      drawLayer(assets.mouthClosed, alpha: 1 - pose.mouthOpen);
    }
    if (pose.mouthOpen > 0.02) {
      drawLayer(assets.mouthOpen, alpha: pose.mouthOpen);
    }

    // 4. Claws bend around the shoulder and feet walk anti-phase around the
    // hip, both inheriting float + tilt.
    final handMult = amp.handDegMultiplier * amp.clawDegMultiplier;
    drawAppendage(assets.clawLeft, 'claw_left', pose.leftClawDeg * handMult);
    drawAppendage(
        assets.clawRight, 'claw_right', pose.rightClawDeg * handMult);
    drawAppendage(assets.footLeft, 'foot_left',
        pose.leftFootDeg * amp.footDegMultiplier);
    drawAppendage(assets.footRight, 'foot_right',
        pose.rightFootDeg * amp.footDegMultiplier);

    // 5. Antennae.
    drawAppendage(assets.antennaLeft, 'antenna_left',
        pose.antennaDeg * amp.antennaDegMultiplier);
    drawAppendage(assets.antennaRight, 'antenna_right',
        pose.antennaDeg * amp.antennaDegMultiplier);

    // 6. Eyes: prefer split eye layers, each squashed around its own center;
    // single-eye characters are fine. Falls back to the combined eyes layer
    // (midpoint squash).
    final blink = pose.eyeBlink.clamp(0.3, 1.0);
    final eyesCfg = manifest.eyes;
    final splitEyes = <(ui.Image, MascotPoint)>[
      if (assets.eyeLeft != null) (assets.eyeLeft!, eyesCfg.leftCenter),
      if (assets.eyeRight != null) (assets.eyeRight!, eyesCfg.rightCenter),
    ];
    void squashAround(Offset c) {
      canvas.translate(c.dx, c.dy);
      canvas.scale(1, blink);
      canvas.translate(-c.dx, -c.dy);
    }

    if (splitEyes.isNotEmpty) {
      for (final (image, eyeCenter) in splitEyes) {
        drawLayer(image, local: () => squashAround(Offset(eyeCenter.x, eyeCenter.y)));
      }
    } else if (assets.eyes != null) {
      final mid = Offset(
        (eyesCfg.leftCenter.x + eyesCfg.rightCenter.x) / 2,
        (eyesCfg.leftCenter.y + eyesCfg.rightCenter.y) / 2,
      );
      drawLayer(assets.eyes, local: () => squashAround(mid));
    }

    // 7. Mode-colored highlight dots on the eyes; they inherit the same base
    // transform as the body so they never detach while floating/tilting.
    final ho = eyesCfg.highlightOffset;
    if (ho.x != 0 || ho.y != 0) {
      final glow = listening
          ? _listenGlow
          : speaking
              ? _speakAccent
              : thinking
                  ? _thinkColor
                  : _eyeGlow;
      final dot = Paint()
        ..color = glow.withValues(
            alpha: (pose.eyeGlowAlpha * blink).clamp(0.0, 1.0));
      canvas.save();
      base();
      for (final eyeCenter in {eyesCfg.leftCenter, eyesCfg.rightCenter}) {
        canvas.drawCircle(
          Offset(eyeCenter.x + ho.x, eyeCenter.y + ho.y * blink),
          eyesCfg.radius * 0.45,
          dot,
        );
      }
      canvas.restore();
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpriteMascotPainter oldDelegate) => true;
}
