/// Voice dock: the bottom recording interface shown in voice mode instead of
/// the text input dock. A single tap on the waveform starts the hands-free
/// conversation loop (record → silence auto-stop → ASR → send → TTS →
/// re-record); a second tap interrupts whatever phase is running (recording,
/// transcription, or playback) and returns to standby. Between the two taps
/// everything is automatic — no per-turn buttons.
library;

import 'dart:math' show pi, sin;

import 'package:flutter/material.dart';

import '../state/speech_controller.dart';

/// The bottom voice input widget, replacing _InputDock in voice mode.
class VoiceDock extends StatefulWidget {
  const VoiceDock({
    super.key,
    required this.controller,
    this.pendingImageStrip,
    this.onAttach,
    this.footer,
  });

  /// The speech controller driving the conversation loop.
  final SpeechController controller;

  /// Staged-image strip rendered above the dock card. Built by the chat
  /// screen so it can reuse its private tile widget; collapses to zero
  /// height when nothing is staged.
  final Widget? pendingImageStrip;

  /// Opens the image source menu (same flow as the text-mode attach button);
  /// null greys the control out while a prompt is in flight.
  final VoidCallback? onAttach;

  /// The control strip rendered inside the card's lower edge, below the
  /// waveform (model / permission / context ring). Null omits the divider.
  final Widget? footer;

  @override
  State<VoiceDock> createState() => _VoiceDockState();
}

class _VoiceDockState extends State<VoiceDock> {
  SpeechController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Toggle the loop: the first tap arms the microphone, the second
  /// interrupts and ends the conversation.
  void _handleWaveTap() {
    if (_controller.isConversing) {
      _controller.stopConversation();
    } else {
      _controller.startConversation();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = _controller.state;
    final attachEnabled = widget.onAttach != null;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.pendingImageStrip != null) widget.pendingImageStrip!,
            if (_controller.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  _controller.error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.error,
                  ),
                ),
              ),
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: scheme.outlineVariant),
              ),
              // The control-strip footer hugs the card's lower edge: with a
              // footer the bottom inset shrinks so the strip's own hit area
              // provides the breathing room.
              padding: EdgeInsets.fromLTRB(
                16,
                6,
                16,
                widget.footer != null ? 2 : 6,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Attach control (same paperclip style as the text-mode
                      // dock). A sibling of the waveform gesture surface so a
                      // tap on it never starts or ends the conversation. It
                      // spans the waveform + status rows vertically (centered).
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Material(
                          color: attachEnabled
                              ? scheme.primary.withValues(alpha: 0.12)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: widget.onAttach,
                            child: Tooltip(
                              message: '添加图片（拍照或相册）',
                              child: SizedBox.square(
                                dimension: 40,
                                child: Icon(
                                  Icons.attach_file,
                                  size: 20,
                                  color: attachEnabled
                                      ? scheme.primary
                                      : scheme.outlineVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Waveform + status stack to the attach button's right;
                      // both spacings are kept tight so the card stays short.
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: _handleWaveTap,
                                behavior: HitTestBehavior.translucent,
                                child: SizedBox(
                                  height: 36,
                                  child: Center(
                                    child: _Waveform(
                                      amplitude: _controller.amplitude,
                                      active: state == SpeechState.recording,
                                      color: scheme.primary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 1),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_controller.isConversing &&
                                    state == SpeechState.idle)
                                  const Padding(
                                    padding: EdgeInsets.only(right: 5),
                                    child: _BreathingDot(),
                                  ),
                                _StatusLabel(
                                  state: state,
                                  conversing: _controller.isConversing,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (_controller.hint != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        _controller.hint!,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (widget.footer != null) ...[
                    Divider(
                      height: 1,
                      thickness: 0.5,
                      color: scheme.outlineVariant,
                    ),
                    widget.footer!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Animated waveform bar reflecting the current recording amplitude.
class _Waveform extends StatelessWidget {
  const _Waveform({
    required this.amplitude,
    required this.active,
    required this.color,
  });

  final double amplitude;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final bars = 32;
    final amp = active ? amplitude : 0.0;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 200;
    return SizedBox(
      height: 22,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(bars, (i) {
          final phase = (i / bars) * pi * 2;
          final heightFactor = 0.15 + amp * 0.85 * (0.5 + 0.5 * sin(phase + now));
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1.5),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width: 3,
              height: 22 * heightFactor,
              decoration: BoxDecoration(
                color: color.withValues(alpha: active ? 1 : 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Status text shown below the waveform.
class _StatusLabel extends StatelessWidget {
  const _StatusLabel({required this.state, required this.conversing});

  final SpeechState state;

  /// Distinguishes standby idle ("tap to start") from the loop's waiting-
  /// for-reply idle ("tap to end").
  final bool conversing;

  @override
  Widget build(BuildContext context) {
    return Text(
      switch (state) {
        SpeechState.idle => conversing ? '等待回复…（点击结束）' : '点击开始语音对话',
        SpeechState.recording => '正在聆听…（点击结束）',
        SpeechState.transcribing => '识别中…（点击结束）',
        SpeechState.speaking => '正在播报…（点击结束）',
      },
      style: TextStyle(
        fontSize: 14,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// A small dot that breathes in opacity, shown next to "等待回复…" to
/// signal the system is still active while the model generates its reply.
class _BreathingDot extends StatefulWidget {
  const _BreathingDot();

  @override
  State<_BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<_BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
        ..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Theme.of(context).colorScheme.primary.withValues(
            alpha: 0.25 + 0.6 * (0.5 + 0.5 * _ctrl.value),
          ),
        ),
      ),
    );
  }
}
