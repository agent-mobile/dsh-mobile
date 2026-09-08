/// Live transcription screen: one continuous `/s/ws` session rendered as
/// speaker-labeled turns with a live partial preview, elapsed clock, input
/// waveform, and pause/resume/stop controls. Stopping offers the finished
/// document with copy and send-to-chat actions.
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../services/transcript_store.dart';
import '../state/transcription_controller.dart';

/// Full-screen live transcription session.
class TranscriptionScreen extends StatefulWidget {
  const TranscriptionScreen({
    super.key,
    required this.controller,
    this.onSendToChat,
    this.autoStart = true,
  });

  /// Controller owning the session.
  final TranscriptionController controller;

  /// Delivers the finished document as a chat prompt; null hides the action.
  final void Function(String text)? onSendToChat;

  /// Whether opening the screen starts the session; false defers to a
  /// [TranscriptionController.start] call (embedded flows, tests).
  final bool autoStart;

  @override
  State<TranscriptionScreen> createState() => _TranscriptionScreenState();
}

class _TranscriptionScreenState extends State<TranscriptionScreen> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    if (widget.autoStart &&
        widget.controller.state == TranscriptionState.idle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.controller.start();
      });
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() {});
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent - position.pixels < 160) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      });
    }
  }

  Future<void> _stop() async {
    final result = await widget.controller.stop();
    if (!mounted || result == null) return;
    if (result.text.trim().isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    await _showDocument(result);
  }

  Future<void> _showDocument(TranscriptionSessionResult result) async {
    final send = widget.onSendToChat;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '转录完成 · ${(result.durationMs / 1000).toStringAsFixed(1)} 秒'
                ' · ${result.turns.length} 段',
                style: Theme.of(sheetContext).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectionArea(
                    child: Text(
                      result.labeledText.isEmpty ? '（无内容）' : result.labeledText,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () async {
                      final file = await saveTranscript(result);
                      if (!sheetContext.mounted) return;
                      final name = file.path.split(Platform.pathSeparator).last;
                      ScaffoldMessenger.of(
                        sheetContext,
                      ).showSnackBar(SnackBar(content: Text('已保存：$name')));
                      Navigator.of(sheetContext).pop();
                    },
                    child: const Text('保存到本地'),
                  ),
                  if (send != null)
                    FilledButton(
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        send(result.labeledText);
                      },
                      child: const Text('发送到对话'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final scheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: !controller.isActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmStop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('实时转录'),
          actions: [
            if (controller.isActive)
              IconButton(
                tooltip: controller.state == TranscriptionState.paused
                    ? '继续'
                    : '暂停',
                onPressed: () {
                  if (controller.state == TranscriptionState.paused) {
                    controller.resume();
                  } else if (controller.state == TranscriptionState.recording) {
                    controller.pause();
                  }
                },
                icon: Icon(
                  controller.state == TranscriptionState.paused
                      ? Icons.play_arrow
                      : Icons.pause,
                ),
              ),
            if (controller.isActive)
              IconButton(
                tooltip: '结束',
                onPressed: _stop,
                icon: const Icon(Icons.stop),
              ),
            if (controller.state == TranscriptionState.failed)
              IconButton(
                tooltip: '重试',
                onPressed: () => controller.retry(),
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        body: Column(
          children: [
            _statusStrip(controller, scheme),
            Expanded(child: _transcriptList(controller, scheme)),
          ],
        ),
      ),
    );
  }

  Widget _statusStrip(TranscriptionController controller, ColorScheme scheme) {
    final String status;
    switch (controller.state) {
      case TranscriptionState.idle:
        status = '未开始';
      case TranscriptionState.connecting:
        status = '连接中…';
      case TranscriptionState.recording:
        status = '聆听中';
      case TranscriptionState.paused:
        status = '已暂停';
      case TranscriptionState.failed:
        status = '已中断';
    }
    final elapsed = Duration(milliseconds: controller.elapsedMs);
    final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          Icon(
            controller.state == TranscriptionState.recording
                ? Icons.graphic_eq
                : Icons.mic_off,
            size: 18,
            color: controller.state == TranscriptionState.recording
                ? scheme.primary
                : scheme.outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$status · ${elapsed.inHours > 0 ? '${elapsed.inHours}:' : ''}$minutes:$seconds'
              '${controller.diarization ? ' · 说话人分离' : ''}'
              '${controller.supportsPartial ? ' · 逐字' : ' · 句级'}'
              '${controller.providerId.isEmpty ? '' : ' · ${controller.providerId}'}',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (controller.error != null)
            Expanded(
              flex: 2,
              child: Text(
                controller.error!,
                style: TextStyle(color: scheme.error, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          SizedBox(
            width: 72,
            child: LinearProgressIndicator(
              value: controller.state == TranscriptionState.recording
                  ? controller.level
                  : 0,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _transcriptList(
    TranscriptionController controller,
    ColorScheme scheme,
  ) {
    final turns = controller.turns;
    final partial = controller.partialText;
    if (turns.isEmpty && partial.isEmpty && controller.liveText.isEmpty) {
      return Center(
        child: Text(
          controller.state == TranscriptionState.connecting
              ? '正在建立会话…'
              : '开始说话，转录内容会实时出现在这里',
          style: TextStyle(color: scheme.outline),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: turns.length + (partial.isEmpty ? 0 : 1),
      itemBuilder: (context, index) {
        if (index < turns.length) {
          return _TurnTile(turn: turns[index], scheme: scheme);
        }
        return _TurnTile(
          turn: TranscriptionTurn(
            speaker: 0,
            text: partial,
            startMs: 0,
            endMs: 0,
          ),
          scheme: scheme,
          provisional: true,
        );
      },
    );
  }

  Future<void> _confirmStop() async {
    final stop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('结束转录？'),
        content: const Text('当前会话仍在录制，已识别的内容会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续转录'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('结束'),
          ),
        ],
      ),
    );
    if (stop == true && mounted) {
      await _stop();
    }
  }
}

/// One speaker-labeled transcript row.
class _TurnTile extends StatelessWidget {
  const _TurnTile({
    required this.turn,
    required this.scheme,
    this.provisional = false,
  });

  final TranscriptionTurn turn;
  final ColorScheme scheme;
  final bool provisional;

  static const _speakerColors = [
    Color(0xFF2F6FED),
    Color(0xFF1D9A5F),
    Color(0xFFD07A2C),
    Color(0xFF8E4EC6),
    Color(0xFFC2557A),
  ];

  @override
  Widget build(BuildContext context) {
    final color = _speakerColors[turn.speaker % _speakerColors.length];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // No badge on provisional lines: the upstream commits the speaker at
          // sentence end, so a mid-utterance label would be a guess.
          if (!provisional)
            Container(
              margin: const EdgeInsets.only(top: 2, right: 10),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '说话人 ${turn.speaker + 1}',
                style: TextStyle(color: color, fontSize: 12),
              ),
            ),
          Expanded(
            child: Text(
              turn.text,
              style: provisional
                  ? TextStyle(color: scheme.outline)
                  : Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ],
      ),
    );
  }
}
