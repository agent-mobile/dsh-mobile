/// Talk mascot coverage: the ported animation timeline (periods, amplitudes,
/// per-mode selection, blink), the deepseek sprite pack loading (manifest as
/// the single geometry source, missing parts skipped), and the widget's
/// mode-driven overlay alpha.
library;

import 'package:dsh_mobile_app/widgets/mascot/mascot_assets.dart';
import 'package:dsh_mobile_app/widgets/mascot/mascot_manifest.dart';
import 'package:dsh_mobile_app/widgets/mascot/talk_mascot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MascotTimeline', () {
    test('float: 4s period, ±10 design units', () {
      for (final t in [0.0, 1.0, 2.5, 3.9]) {
        final a = MascotTimeline.pose(tSeconds: t, mode: TalkMascotMode.idle);
        final b = MascotTimeline.pose(
            tSeconds: t + 4, mode: TalkMascotMode.idle);
        expect(a.floatOffset, moreOrLessEquals(b.floatOffset, epsilon: 1e-9));
      }
      var min = double.infinity;
      var max = -double.infinity;
      for (var i = 0; i < 400; i++) {
        final v = MascotTimeline.pose(
                tSeconds: i / 100, mode: TalkMascotMode.idle)
            .floatOffset;
        min = v < min ? v : min;
        max = v > max ? v : max;
      }
      expect(min, moreOrLessEquals(-10, epsilon: 0.1));
      expect(max, moreOrLessEquals(10, epsilon: 0.1));
    });

    test('idle: no tilt, closed mouth, anti-phase claws, antenna sways', () {
      for (final t in [0.3, 1.7, 2.9]) {
        final p = MascotTimeline.pose(tSeconds: t, mode: TalkMascotMode.idle);
        expect(p.bodyTiltDeg, 0);
        expect(p.mouthOpen, 0);
        expect(p.leftClawDeg, moreOrLessEquals(-p.rightClawDeg, epsilon: 1e-9));
      }
      // Antenna idle sway: 2s period.
      for (final t in [0.2, 0.7]) {
        final a = MascotTimeline.pose(tSeconds: t, mode: TalkMascotMode.idle)
            .antennaDeg;
        final b = MascotTimeline.pose(
                tSeconds: t + 2, mode: TalkMascotMode.idle)
            .antennaDeg;
        expect(a, moreOrLessEquals(b, epsilon: 1e-9));
      }
    });

    test('idle claws reach ±15 over a 4s cycle', () {
      var min = double.infinity;
      var max = -double.infinity;
      for (var i = 0; i < 800; i++) {
        final v = MascotTimeline.pose(
                tSeconds: i / 100, mode: TalkMascotMode.idle)
            .leftClawDeg;
        min = v < min ? v : min;
        max = v > max ? v : max;
      }
      expect(min, moreOrLessEquals(-15, epsilon: 0.2));
      expect(max, moreOrLessEquals(15, epsilon: 0.2));
    });

    test('listening (settled bases): lean 12, claw bases ∓25 + idle osc', () {
      final p = MascotTimeline.pose(
        tSeconds: 0,
        mode: TalkMascotMode.listening,
        leftClawBase: -25,
        rightClawBase: 25,
        listenLeanDeg: 12,
      );
      expect(p.bodyTiltDeg, 12);
      expect(p.leftClawDeg, -25); // clawOsc(0) = 0
      expect(p.rightClawDeg, 25);
    });

    test('listening antenna tremor: ±8 @250ms', () {
      var min = double.infinity;
      var max = -double.infinity;
      for (var i = 0; i < 500; i++) {
        final v = MascotTimeline.pose(
                tSeconds: i / 100, mode: TalkMascotMode.listening)
            .antennaDeg;
        min = v < min ? v : min;
        max = v > max ? v : max;
      }
      expect(min, moreOrLessEquals(-8, epsilon: 0.15));
      expect(max, moreOrLessEquals(8, epsilon: 0.15));
      // 250ms period.
      for (final t in [0.03, 0.11]) {
        final a = MascotTimeline.pose(
                tSeconds: t, mode: TalkMascotMode.listening)
            .antennaDeg;
        final b = MascotTimeline.pose(
                tSeconds: t + 0.25, mode: TalkMascotMode.listening)
            .antennaDeg;
        expect(a, moreOrLessEquals(b, epsilon: 1e-9));
      }
    });

    test('speaking: mouth 0..1 @300ms, claws -30..5 / -5..30 anti-phase', () {
      for (final t in [0.01, 0.07, 0.13]) {
        final p = MascotTimeline.pose(tSeconds: t, mode: TalkMascotMode.speaking);
        expect(p.mouthOpen, inInclusiveRange(0, 1));
        expect(p.leftClawDeg, inInclusiveRange(-30, 5));
        expect(p.rightClawDeg, inInclusiveRange(-5, 30));
        // Mouth is a 300ms oscillation: quarter period apart it complements.
        final q = MascotTimeline.pose(
                tSeconds: t + 0.15, mode: TalkMascotMode.speaking)
            .mouthOpen;
        expect(p.mouthOpen + q, moreOrLessEquals(1, epsilon: 1e-9));
      }
      // Claws are anti-phase: when the left is at its low end the right is
      // at its high end.
      var best = 0.0;
      for (var i = 0; i < 600; i++) {
        final t = i / 100;
        final p = MascotTimeline.pose(tSeconds: t, mode: TalkMascotMode.speaking);
        if (p.leftClawDeg < best) best = p.leftClawDeg;
      }
      expect(best, moreOrLessEquals(-30, epsilon: 0.2));
    });

    test('speaking body swing and antenna share the 800ms ±12 timeline', () {
      for (final t in [0.05, 0.2, 0.4]) {
        final p = MascotTimeline.pose(tSeconds: t, mode: TalkMascotMode.speaking);
        expect(p.antennaDeg, moreOrLessEquals(p.bodyTiltDeg, epsilon: 1e-9));
      }
      var max = -double.infinity;
      for (var i = 0; i < 800; i++) {
        final v = MascotTimeline.pose(
                tSeconds: i / 100, mode: TalkMascotMode.speaking)
            .bodyTiltDeg
            .abs();
        max = v > max ? v : max;
      }
      expect(max, moreOrLessEquals(12, epsilon: 0.15));
    });

    test('thinking: bob ±3 @500ms, alternating taps ±8 @400ms, antenna ±6', () {
      for (final t in [0.02, 0.1, 0.2]) {
        final p = MascotTimeline.pose(tSeconds: t, mode: TalkMascotMode.thinking);
        expect(p.mouthOpen, 0);
        // Alternating taps: opposite signs at every instant.
        expect(p.leftClawDeg * p.rightClawDeg, lessThanOrEqualTo(0));
      }
      var tapMax = -double.infinity;
      for (var i = 0; i < 400; i++) {
        final v = MascotTimeline.pose(
                tSeconds: i / 100, mode: TalkMascotMode.thinking)
            .leftClawDeg
            .abs();
        tapMax = v > tapMax ? v : tapMax;
      }
      expect(tapMax, moreOrLessEquals(8, epsilon: 0.2));
      // Tap period 400ms.
      for (final t in [0.03, 0.17]) {
        final a = MascotTimeline.pose(
                tSeconds: t, mode: TalkMascotMode.thinking)
            .leftClawDeg;
        final b = MascotTimeline.pose(
                tSeconds: t + 0.4, mode: TalkMascotMode.thinking)
            .leftClawDeg;
        expect(a, moreOrLessEquals(b, epsilon: 1e-9));
      }
    });

    test('feet walk anti-phase ±14 @600ms in every mode', () {
      for (final t in [0.05, 0.2, 0.35]) {
        for (final mode in TalkMascotMode.values) {
          final p = MascotTimeline.pose(tSeconds: t, mode: mode);
          expect(p.leftFootDeg, moreOrLessEquals(-p.rightFootDeg, epsilon: 1e-9));
        }
      }
      var max = -double.infinity;
      for (var i = 0; i < 600; i++) {
        final v = MascotTimeline.pose(
                tSeconds: i / 100, mode: TalkMascotMode.idle)
            .leftFootDeg
            .abs();
        max = v > max ? v : max;
      }
      expect(max, moreOrLessEquals(14, epsilon: 0.2));
    });

    test('blink: open until 2.5s, dips to 0.12, only in idle mode', () {
      expect(MascotTimeline.blinkAmount(0), 1);
      expect(MascotTimeline.blinkAmount(2.49), 1);
      expect(MascotTimeline.blinkAmount(2.8), moreOrLessEquals(0.12, epsilon: 1e-9));
      expect(MascotTimeline.blinkAmount(2.995), 1);
      // The raw dip is clamped to a 0.3 squash floor by the renderer; check
      // the timeline produces the documented dip so the clamp has work to do.
      expect(MascotTimeline.blinkAmount(2.8) < 0.3, isTrue);

      final idle = MascotTimeline.pose(tSeconds: 2.8, mode: TalkMascotMode.idle);
      expect(idle.eyeBlink, moreOrLessEquals(0.12, epsilon: 1e-9));
      for (final mode in [TalkMascotMode.listening, TalkMascotMode.speaking,
        TalkMascotMode.thinking]) {
        final p = MascotTimeline.pose(tSeconds: 2.8, mode: mode);
        expect(p.eyeBlink, 1);
      }
    });

    test('pulse phase per mode: listening 1500ms, speaking 600ms, thinking 800ms', () {
      expect(MascotTimeline.pulseValue(tSeconds: 1.23, mode: TalkMascotMode.idle), 0);
      for (final (mode, period) in [
        (TalkMascotMode.listening, 1.5),
        (TalkMascotMode.speaking, 0.6),
        (TalkMascotMode.thinking, 0.8),
      ]) {
        for (final t in [0.1, 0.37]) {
          final a = MascotTimeline.pulseValue(tSeconds: t, mode: mode);
          final b =
              MascotTimeline.pulseValue(tSeconds: t + period, mode: mode);
          expect(a, moreOrLessEquals(b, epsilon: 1e-9));
          expect(a, inInclusiveRange(0, 1));
        }
      }
    });

    test('mode priority: speaking > listening > thinking > idle', () {
      expect(TalkMascot.modeOf(speaking: true, listening: true, thinking: true),
          TalkMascotMode.speaking);
      expect(TalkMascot.modeOf(speaking: false, listening: true, thinking: true),
          TalkMascotMode.listening);
      expect(TalkMascot.modeOf(speaking: false, listening: false, thinking: true),
          TalkMascotMode.thinking);
      expect(TalkMascot.modeOf(speaking: false, listening: false, thinking: false),
          TalkMascotMode.idle);
    });
  });

  group('MascotManifest', () {
    test('parses the deepseek pack geometry from JSON only', () {
      const json = r'''
{
  "id": "deepseek",
  "name": "DeepSeek",
  "canvas": {"width": 1024, "height": 1024},
  "missing": ["eye_right", "antenna_right", "foot_right"],
  "pivots": {
    "antenna_left": {"x": 658.0, "y": 302.0},
    "claw_left": {"x": 308.0, "y": 450.0},
    "claw_right": {"x": 582.0, "y": 535.0},
    "foot_left": {"x": 520.0, "y": 720.0}
  },
  "eyes": {
    "left_center": {"x": 517.5, "y": 501.5},
    "right_center": {"x": 517.5, "y": 501.5},
    "radius": 20,
    "highlight_offset": {"x": 0, "y": 0}
  },
  "mouth": {
    "center": {"x": 384.5, "y": 625.5},
    "closed_size": {"w": 123, "h": 27},
    "open_max_size": {"w": 86, "h": 86}
  },
  "amplitude": {
    "claw_deg_multiplier": 0.3,
    "hand_deg_multiplier": 1.0,
    "foot_deg_multiplier": 0.5,
    "antenna_deg_multiplier": 1.0,
    "body_swing_multiplier": 0.5,
    "float_multiplier": 1.0
  }
}
''';
      final m = MascotManifest.tryParse(json);
      expect(m, isNotNull);
      expect(m!.id, 'deepseek');
      expect(m.canvas, const MascotCanvasSize(1024, 1024));
      expect(m.isMissingPart('eye_right'), isTrue);
      expect(m.isMissingPart('claw_left'), isFalse);
      expect(m.pivots['claw_left'], const MascotPoint(308, 450));
      expect(m.eyes.leftCenter, const MascotPoint(517.5, 501.5));
      expect(m.eyes.radius, 20);
      expect(m.mouth.closedSize.w, 123);
      expect(m.amplitude.clawDegMultiplier, 0.3);
      expect(m.amplitude.bodySwingMultiplier, 0.5);
    });

    test('defaults apply for omitted optional fields', () {
      const json = r'''
{
  "id": "x",
  "name": "X",
  "canvas": {"width": 100, "height": 100},
  "eyes": {
    "left_center": {"x": 30, "y": 40},
    "right_center": {"x": 70, "y": 40},
    "radius": 5
  },
  "mouth": {
    "center": {"x": 50, "y": 60},
    "closed_size": {"w": 10, "h": 4},
    "open_max_size": {"w": 8, "h": 8}
  }
}
''';
      final m = MascotManifest.tryParse(json);
      expect(m, isNotNull);
      expect(m!.missing, isEmpty);
      expect(m.pivots, isEmpty);
      expect(m.eyes.highlightOffset, const MascotPoint(0, 0));
      expect(m.amplitude, const MascotAmplitude());
    });

    test('rejects documents missing required fields', () {
      expect(MascotManifest.tryParse('not json'), isNull);
      expect(MascotManifest.tryParse(r'{"id": "x"}'), isNull);
      expect(
          MascotManifest.tryParse(
              r'{"id": "x", "name": "X", "canvas": {"width": 10, "height": 10}}'),
          isNull); // no eyes/mouth
    });
  });

  group('deepseek sprite pack', () {
    test('loads manifest and layers; missing parts stay null', () async {
      final pack = await MascotSkinRegistry.resolve(MascotSkinRegistry.deepseekId);
      expect(pack, isNotNull);
      final assets = pack!;
      expect(assets.manifest.id, 'deepseek');
      expect(assets.manifest.canvas, const MascotCanvasSize(1024, 1024));

      // Decoded at the registry's downscale width.
      expect(assets.body.width, 512);
      expect(assets.body.height, 512);

      // Present layers decode (single-eye, one-fin, one-tail character).
      for (final name in [
        'eye_left',
        'mouth_closed',
        'mouth_open',
        'antenna_left',
        'foot_left',
      ]) {
        expect(assets.layer(name), isNotNull, reason: name);
      }

      // Missing parts: second eye, second fin, second tail, and claws.
      for (final name in [
        'eye_right',
        'claw_left',
        'claw_right',
        'antenna_right',
        'foot_right',
      ]) {
        expect(assets.layer(name), isNull, reason: name);
      }
    });
  });

  group('TalkMascot widget', () {
    setUp(() async {
      // Warm the registry cache outside FakeAsync so the pump never touches
      // the asset channel (file IO cannot complete inside it).
      await MascotSkinRegistry.resolve(MascotSkinRegistry.deepseekId);
    });

    Widget harness({bool listening = false, bool speaking = false, bool thinking = false}) {
      return MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox.square(
              dimension: 260,
              child: TalkMascot(
                listening: listening,
                speaking: speaking,
                thinking: thinking,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('renders the sprite once the pack loads', (tester) async {
      await tester.pumpWidget(harness());
      // Let asset loading + decode settle.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(
        find.descendant(
          of: find.byType(TalkMascot),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
      // No exceptions from the painter across a few frames.
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });

    testWidgets('overlay alpha tweens to the mode target (400ms)',
        (tester) async {
      await tester.pumpWidget(harness());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }

      final Finder opacity = find.descendant(
        of: find.byType(TalkMascot),
        matching: find.byType(Opacity),
      );

      // Idle target.
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.widget<Opacity>(opacity).opacity,
          moreOrLessEquals(0.50, epsilon: 0.01));

      // Speaking target.
      await tester.pumpWidget(harness(speaking: true));
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.widget<Opacity>(opacity).opacity,
          moreOrLessEquals(0.85, epsilon: 0.01));

      // Listening target.
      await tester.pumpWidget(harness(listening: true));
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.widget<Opacity>(opacity).opacity,
          moreOrLessEquals(0.70, epsilon: 0.01));

      // Thinking target.
      await tester.pumpWidget(harness(thinking: true));
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.widget<Opacity>(opacity).opacity,
          moreOrLessEquals(0.65, epsilon: 0.01));
    });

    testWidgets('mode flips repaint without exceptions', (tester) async {
      await tester.pumpWidget(harness());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pumpWidget(harness(speaking: true));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(harness(listening: true));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(harness());
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    });
  });
}
