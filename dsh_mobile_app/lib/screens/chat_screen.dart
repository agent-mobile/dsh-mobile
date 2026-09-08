/// Chat screen: transcript, tool-call trees, approval cards, question sheet,
/// and the input dock, all driven by the live connection state.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dsh_dart_sdk/dsh_dart_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';

import '../screens/transcription_screen.dart';
import '../services/transcript_store.dart';
import '../state/connection_controller.dart';
import '../state/speech_controller.dart';
import '../state/speech_feed_cut.dart';
import '../state/speech_reveal.dart';
import '../state/transcription_controller.dart';
import '../state/voice_mode_controller.dart';
import '../widgets/approval_card.dart';
import '../widgets/context_meter.dart';
import '../widgets/directory_picker.dart';
import '../widgets/goal_dock.dart';
import '../widgets/queue_dock.dart';
import '../widgets/session_status_panel.dart';
import '../widgets/todo_panel.dart';
import '../widgets/question_sheet.dart';
import '../widgets/tool_card.dart';
import '../widgets/mascot/talk_mascot.dart';
import '../widgets/voice_dock.dart';
import '../widgets/workspace_hero.dart';

/// One chat over a session: transcript, input, and live updates.
/// What the user chose when staged images met a text-only model.
enum _ImageConflictChoice { cancel, textOnly, switchAndSend }

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.connection,
    required this.sessionId,
    required this.voiceModeController,
    this.transcriptionController,
  });

  final ConnectionController connection;
  final String sessionId;

  /// Global voice/text mode preference.
  final VoiceModeController voiceModeController;

  /// Transcription session owned by the live-transcription route; tests
  /// inject a pre-folded controller to drive the screen without a real
  /// `/s/ws` session. Null (production) creates a fresh one per opening.
  final TranscriptionController? transcriptionController;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  /// Distance from the transcript top at which an auto-loaded older page
  /// triggers (infinite scroll upward; the "加载更早" row stays as a fallback
  /// and progress indicator).
  static const double _kAutoLoadOlderTopPx = 120;

  /// Viewport distance from the bottom that still counts as "docked".
  static const double _kFollowThresholdPx = 80;

  final _inputController = TextEditingController();
  final _inputFocusNode = FocusNode();
  final _scrollController = ScrollController();
  final ImagePicker _imagePicker = ImagePicker();
  bool _sending = false;

  /// Captured/picked images staged for the next send.
  final List<({String name, String mediaType, Uint8List bytes})> _pendingImages =
      [];

  /// Image limits mirrored from the host (5MB/image, 20/message).
  static const int _kMaxImageBytes = 5 * 1024 * 1024;
  static const int _kMaxImages = 20;

  /// Current model name for the composer seat, refreshed on history load.
  String? _currentModelName;

  /// Speech controller for voice mode (recording + TTS playback).
  SpeechController? _speechController;

  /// Whether the initial open has landed on the latest content.
  bool _initialOpenHandled = false;

  /// Whether the transcript viewport is docked to the newest message; new
  /// content follows only while true. The user's own scrolling updates it.
  bool _following = true;

  /// Surface seq watermark for the follow-on-new-content decision (a single
  /// streamed assistant message grows without its count changing).
  int _lastSeq = -1;

  SessionSurface get _surface => widget.connection.surface(widget.sessionId);

  /// Whether the agent is mid-turn (the host's authoritative running signal).
  bool get _running => widget.connection.running(widget.sessionId) ?? false;

  /// Display title: the session's durable title, else a short id fallback.
  String? _title;

  /// Whether the session is blank (no turn yet), driving the hero empty state.
  bool _isBlank = false;

  /// Display title: the live `title` projection first, else the list snapshot,
  /// else a short id fallback.
  String get _sessionTitle {
    final live = widget.connection.projections(widget.sessionId)['title']?.value;
    if (live is String && live.isNotEmpty) return live;
    return _title ?? widget.sessionId.split('-').first;
  }

  /// Read a projection value as a map, or null.
  Map<String, Object?>? _proj(String key) {
    final value = widget.connection.projections(widget.sessionId)[key]?.value;
    return value is Map ? Map<String, Object?>.from(value) : null;
  }

  /// Read a projection value raw (the `todos` projection is a bare list).
  Object? _projectionRaw(String key) =>
      widget.connection.projections(widget.sessionId)[key]?.value;

  /// Current permission preset id + options from the `permissions` projection.
  ({String? current, List<({String value, String name, String? description})> options})?
      _permissions() {
    final proj = _proj('permissions');
    if (proj == null) return null;
    final rawOptions = proj['options'];
    final options = <({String value, String name, String? description})>[];
    if (rawOptions is List) {
      for (final item in rawOptions) {
        if (item is! Map) continue;
        final value = item['value'];
        if (value is! String) continue;
        options.add((
          value: value,
          name: item['name'] is String ? item['name'] as String : value,
          description: item['description'] as String?,
        ));
      }
    }
    return (current: proj['currentValue'] as String?, options: options);
  }

  /// Current workspace label for the hero chip; null shows the placeholder.
  String? get _workspaceLabel {
    final sessionId = widget.sessionId;
    for (final workspace in widget.connection.workspaceItems) {
      if (workspace.sessionIds.contains(sessionId)) return workspace.title;
    }
    return null;
  }

  /// Open the host-directory picker to choose the session's workspace.
  Future<void> _pickWorkspace() async {
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => DirectoryPickerScreen(connection: widget.connection),
      ),
    );
    if (picked == null) return;
    try {
      await widget.connection.workspaces.create(path: picked);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建工作区失败：$error')),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
    widget.connection.addListener(_onConnectionChanged);
    widget.voiceModeController.addListener(_onVoiceModeChanged);
    // Entered while voice mode was already on (the home rail toggle fired
    // before this route pushed): the change listener will never fire, so
    // apply the current mode here.
    if (widget.voiceModeController.isVoice) {
      unawaited(_getSpeechController().startConversation());
    }
  }

  @override
  void dispose() {
    // Close this session's live transcript channel and any voice loop this
    // screen started.
    unawaited(widget.connection.stopFollowing(widget.sessionId));
    unawaited(_speechController?.stopConversation());
    widget.connection.removeListener(_onConnectionChanged);
    widget.voiceModeController.removeListener(_onVoiceModeChanged);
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Voice mode changed: start/stop the speech loop and rebuild.
  void _onVoiceModeChanged() {
    if (!mounted) return;
    if (widget.voiceModeController.isVoice) {
      _getSpeechController().startConversation();
    } else {
      _speechController?.stopConversation();
      _spokenSeq = 0;
      _spokenChars = 0;
      _speechStreamOpen = false;
    }
    setState(() {});
  }

  /// The last assistant message seq fed to TTS, and how many characters of
  /// its streamed text were already enqueued (the partial tail is held back
  /// until a sentence boundary arrives).
  int _spokenSeq = 0;

  /// The newest seq fully handed to a finished speech session. A new turn's
  /// first fold still surfaces the PREVIOUS turn's reply as the latest text
  /// message (the new one is not folded yet); opening a session on it would
  /// re-speak that whole reply, so an open waits for a strictly newer seq.
  int _lastSpokenSeq = 0;

  int _spokenChars = 0;

  /// Last-seen full length of the spoken message's text; the reveal uses it
  /// to show a superseded message in full (its tail will never be spoken).
  int _spokenTextLength = 0;

  /// Karaoke reveal state: which message is being spoken and how many
  /// characters of it have been heard.
  final SpeechReveal _reveal = SpeechReveal();

  /// Whether a streamed TTS session is open for the current reply; closed
  /// once the turn stops running so playback drains and listening resumes.
  bool _speechStreamOpen = false;

  /// Lazily create or reuse the speech controller.
  SpeechController _getSpeechController() {
    if (_speechController == null) {
      _speechController = SpeechController(
        speechClient: DshSpeechClient(
          baseUrl: widget.connection.baseUrl,
          token: widget.connection.token,
        ),
        onResult: _sendVoiceText,
        onUnitStart: _onSpeechUnitStart,
      );
      _speechController!.addListener(() {
        if (mounted) setState(() {});
      });
    }
    return _speechController!;
  }

  /// A unit's audio started sounding: surface its text (karaoke reveal) and
  /// follow the growth — the revealed message is the newest content, and a
  /// docked viewport must keep it in view the same way a newly folded
  /// message does. Skipped while the user is scrolled away (`_following`
  /// false); the back-to-bottom FAB re-arms it.
  void _onSpeechUnitStart(int unitIndex) {
    if (!mounted) return;
    _reveal.unitStarted(unitIndex);
    setState(() {});
    _requestDock();
  }

  /// Karaoke: how many characters of a text block of message [seq] starting
  /// at [blockStart] (within the message's joined text) are visible, or null
  /// when the block renders in full — voice off, no active playback, or a
  /// message already fully heard. Messages not yet reached by playback show
  /// nothing, so text only ever appears as it is being spoken.
  int? _visibleTextChars(int seq, int blockStart) {
    if (!widget.voiceModeController.isVoice) return null;
    final speech = _speechController;
    if (speech == null || !speech.isSpeaking) return null;
    if (seq < _reveal.revealedSeq) return null;
    if (seq > _reveal.revealedSeq) return 0;
    final limit = _reveal.revealedChars - blockStart;
    return limit > 0 ? limit : 0;
  }

  /// A pending post-frame dock, so [dispose] can drop it if the viewport
  /// unmounts before the frame lands (a jump after unmount would touch a
  /// deactivated position).
  bool _pendingDock = false;

  /// A single connection notification: rebuild, and follow new content to the
  /// bottom while docked. The jump is deferred to post-frame so
  /// `maxScrollExtent` reflects the freshly laid-out content (jumping
  /// mid-notification would target the pre-growth extent).
  void _onConnectionChanged() {
    if (!mounted) return;
    final seq = _surface.lastSeq;
    final grow = seq > _lastSeq;
    _lastSeq = seq;
    setState(() {});
    if (grow && _following) _requestDock();
    _feedSpeech();
  }

  /// Feed the streaming assistant reply into the speech pipeline while a
  /// voice conversation is active. The controller's contract is ONE streamed
  /// session per reply: open once when the first text arrives, keep adding
  /// sentence units as the text streams (across every step of the turn), and
  /// close when the turn ends so playback drains and listening resumes.
  /// Re-opening per message would cancel the in-flight synthesis and swap
  /// the PCM player — every tool-call step would hard-cut the audio.
  /// Guarded by the live turn signal, so history folds never speak.
  void _feedSpeech() {
    if (!widget.voiceModeController.isVoice) return;
    final speech = _speechController;
    if (speech == null || !speech.isConversing) return;
    AssistantSessionMessage? latest;
    for (final message in _surface.messages) {
      if (message is AssistantSessionMessage && message.text.isNotEmpty) {
        latest = message;
      }
    }
    if (!_running) {
      if (_speechStreamOpen) {
        // The running=false frame races the final message fold (separate
        // streams): wait until the last step is no longer streaming before
        // flushing the tail and closing the session.
        if (latest != null && latest.streaming) return;
        _speechStreamOpen = false;
        _lastSpokenSeq = max(_lastSpokenSeq, _spokenSeq);
        if (latest != null && latest.seq == _spokenSeq) {
          _flushUnits(speech, latest.text);
        }
        speech.endStreamedSpeech();
      }
      return;
    }
    final state = speech.state;
    if (state == SpeechState.recording || state == SpeechState.transcribing) {
      return;
    }
    if (latest == null) return;
    // Open the streamed session ONCE per turn, and only for a message newer
    // than everything already spoken: while the model has not folded its new
    // reply yet, `latest` is still the previous turn's text, and opening on
    // it replays that reply from the top (logged: a 152-char turn re-fed as
    // one unit the moment the next turn began).
    if (!_speechStreamOpen) {
      if (latest.seq <= _lastSpokenSeq) return;
      _speechStreamOpen = true;
      _spokenSeq = latest.seq;
      _spokenChars = 0;
      _spokenTextLength = 0;
      _reveal.beginSessionAt(latest.seq);
      speech.beginStreamedSpeech();
    }
    // A newer step supersedes the held tail of the previous message. Forward
    // only: a stale fold can momentarily resurface an older step, and
    // re-zeroing there would re-feed text already spoken. The superseded
    // message reveals in full — its remaining text will never be spoken.
    if (latest.seq > _spokenSeq) {
      _reveal.supersede(_spokenSeq, _spokenTextLength);
      _spokenSeq = latest.seq;
      _spokenChars = 0;
      _spokenTextLength = 0;
    }
    // A settled step will not grow: flush its remainder in bounded units —
    // one giant unit (a whole long reply) makes the relay synthesize past
    // its timeout and the audio dies for the whole wait.
    if (!latest.streaming) {
      _flushUnits(speech, latest.text);
      return;
    }
    // Streaming: enqueue every complete unit the new text completes; the
    // partial tail waits for the next fold (or the turn-end flush).
    while (true) {
      final text = latest.text;
      if (text.length <= _spokenChars) break;
      final pending = text.substring(_spokenChars);
      final cut = _feedCut(pending);
      if (cut <= 0) break;
      final end = _spokenChars + cut;
      // Record before enqueueing: a zero-audio unit reveals synchronously
      // inside addSpeechSentence and must find its own entry already there.
      _reveal.unitEnqueued(latest.seq, end);
      if (!speech.addSpeechSentence(pending.substring(0, cut))) {
        _reveal.unitDropped();
      }
      _spokenChars = end;
      _spokenTextLength = text.length;
    }
  }

  /// The enqueue cut for [pending]; see [speechFeedCut] for the boundary
  /// rules and the hard unit-size contract. The first unit of a message
  /// cuts short (6/16 instead of 24/48) so the first audio — and with it
  /// the karaoke reveal — starts sooner.
  int _feedCut(String pending) => speechFeedCut(
    pending,
    weakChars: _spokenChars == 0 ? 6 : 24,
    hardChars: _spokenChars == 0 ? 16 : 48,
  );

  /// Enqueue every remaining character of [text] past `_spokenChars` as
  /// bounded units: best boundary per `_feedCut`, else the whole short
  /// remainder, never more than the hard cap per unit.
  void _flushUnits(SpeechController speech, String text) {
    while (text.length > _spokenChars) {
      final pending = text.substring(_spokenChars);
      var cut = _feedCut(pending);
      if (cut <= 0) cut = pending.length;
      final unit = pending.substring(0, cut);
      final end = _spokenChars + cut;
      // Record before enqueueing (see the streaming loop). Punctuation-only
      // units flow through as zero-audio placeholders — their text must
      // still reveal, so they are not filtered out here.
      _reveal.unitEnqueued(_spokenSeq, end);
      if (!speech.addSpeechSentence(unit)) _reveal.unitDropped();
      _spokenChars = end;
      _spokenTextLength = text.length;
    }
  }

  void _requestDock() {
    if (_pendingDock) return;
    _pendingDock = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingDock = false;
      if (mounted && _following) _jumpToBottom();
    });
  }

  Future<void> _bootstrap() async {
    await widget.connection.loadHistory(widget.sessionId);
    // 0.1.2 live transcript channel: open this session's session/follow stream
    // so new turn events append to the surface (the 0.1.1 global session/event
    // push no longer exists).
    await widget.connection.startFollowing(widget.sessionId);
    await _resolveMeta();
    _loadModelName();
    if (!mounted || _initialOpenHandled) return;
    if (widget.connection.historyState(widget.sessionId) == SessionHistoryState.open) {
      _initialOpenHandled = true;
      if (_surface.messages.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToBottom();
        });
      }
    }
  }

  /// Resolve the display title + blank flag. The list snapshot supplies the
  /// durable title when no structural frame has landed yet (a fresh chat open).
  Future<void> _resolveMeta() async {
    var summaries = widget.connection.structuralSessionList;
    if (summaries.isEmpty) {
      try {
        summaries = await widget.connection.sessions.list();
      } catch (_) {
        // Best-effort; the projection or id fallback still titles the bar.
      }
    }
    if (!mounted) return;
    final summary = summaries
        .where((s) => s.sessionId == widget.sessionId)
        .firstOrNull;
    _title = summary?.title;
    _isBlank = summary?.blank ?? _surface.messages.isEmpty;
  }

  Future<void> _loadModelName() async {
    try {
      final models = await widget.connection.sessions.models();
      if (!mounted) return;
      _catalog = models;
      final sel = models.defaultSelection;
      final model = sel['model'];
      if (model is String && model.isNotEmpty) _currentModelName = model;
    } catch (_) {
      // Best-effort label; the composer seat tolerates a missing name.
    }
  }

  /// The deployment's model catalog with capability annotations; null until
  /// the first load resolves (all capability guidance then stays passive).
  SessionModels? _catalog;

  /// The catalog entry of the session's current model. Best effort: the
  /// deployment default until this screen switches the model, matching the
  /// accuracy of the composer's model seat label.
  ModelCatalogModel? get _currentModel {
    final name = _currentModelName;
    final catalog = _catalog;
    if (name == null || catalog == null) return null;
    for (final group in catalog.groups) {
      for (final model in group.models) {
        if (model.id == name) return model;
      }
    }
    return null;
  }

  /// Nearest image-capable model: same provider group as the current model
  /// first, else the first annotated one overall. Null when none is known.
  ({String provider, ModelCatalogModel model})? get _visionCandidate {
    final catalog = _catalog;
    if (catalog == null) return null;
    ({String provider, ModelCatalogModel model})? fallback;
    for (final group in catalog.groups) {
      for (final model in group.models) {
        if (!model.supportsImageInput) continue;
        if (group.models.any((m) => m.id == _currentModelName)) {
          return (provider: group.id, model: model);
        }
        fallback ??= (provider: group.id, model: model);
      }
    }
    return fallback;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToBottom();
    });
  }

  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showError(String label, Object error) {
    // Host messages carry the actionable part ("Model X does not support
    // image input"); showing only the wire code would hide it.
    final message = error is RpcDomainException
        ? '$label（${error.error.code.wire}）：${error.error.message}'
        : '$label：$error';
    _snack(message);
  }

  // ---------------------------------------------------------------- send

  Future<void> _send({bool steer = false}) async {
    final text = _inputController.text.trim();
    if (text.isEmpty && _pendingImages.isEmpty) return;
    if (_sending) return;
    // Proactive guidance: the annotated catalog already says this model
    // refuses images, so ask before the host does it the hard way.
    if (_pendingImages.isNotEmpty && _currentModel?.refusesImageInput == true) {
      if (!await _resolveImageConflict()) return;
    }
    _sending = true;
    final controller = _inputController;
    controller.clear();
    final images = _pendingImages;
    _pendingImages.clear();
    setState(() {});
    var imageRefused = false;
    try {
      final content = <Map<String, Object?>>[];
      if (text.isNotEmpty) {
        content.add({'type': 'text', 'text': text});
      }
      for (final image in images) {
        content.add({
          'type': 'image',
          'mediaType': image.mediaType,
          'data': base64Encode(image.bytes),
        });
      }
      await widget.connection.sessions.prompt(
        sessionId: widget.sessionId,
        content: content,
        mode: _running && !steer ? 'steer' : 'queue',
      );
      _inputFocusNode.unfocus();
      // A send always re-docks the viewport, even if the user scrolled up.
      setState(() => _following = true);
      _scrollToBottom();
    } catch (error) {
      _showError('发送失败', error);
      if (text.isNotEmpty) controller.text = text;
      _pendingImages.addAll(images);
      imageRefused = _isImageRejection(error);
      setState(() {});
    } finally {
      _sending = false;
      setState(() {});
    }
    // Reactive fallback: the host refused the image input after all (a
    // catalog without modality annotations). _sending is already false here,
    // so the resend is safe.
    if (imageRefused && _pendingImages.isNotEmpty) {
      await _offerSwitchAndResend();
    }
  }

  /// Whether the host refused this prompt specifically over image input.
  bool _isImageRejection(Object error) {
    if (error is! RpcDomainException) return false;
    if (error.error.code.wire == 'session/attachment-invalid') return true;
    if (error.error.details['reason'] == 'MODEL_DOES_NOT_SUPPORT_IMAGES') {
      return true;
    }
    return error.error.message.contains('does not support image input');
  }

  /// Resolution options when images meet a text-only model.
  Future<bool> _resolveImageConflict() async {
    final candidate = _visionCandidate;
    if (candidate == null) {
      _snack('当前模型不支持图片输入，目录中没有可切换的视觉模型');
      return false;
    }
    final current = _currentModelName ?? '当前模型';
    final target = candidate.model.name ?? candidate.model.id;
    final choice = await showDialog<_ImageConflictChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('当前模型不支持图片'),
        content: Text('$current 不接受图片输入。要切换到 $target 再发送吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(_ImageConflictChoice.cancel),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(_ImageConflictChoice.textOnly),
            child: const Text('仅发送文字'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(_ImageConflictChoice.switchAndSend),
            child: const Text('切换并发送'),
          ),
        ],
      ),
    );
    if (choice == _ImageConflictChoice.cancel || choice == null) return false;
    if (choice == _ImageConflictChoice.textOnly) {
      setState(_pendingImages.clear);
      return true;
    }
    await _selectModel(candidate.provider, candidate.model.id, null);
    return true;
  }

  /// Post-refusal offer: switch to the nearest vision model and resend the
  /// restored draft (text and images are already back in the dock).
  Future<void> _offerSwitchAndResend() async {
    final candidate = _visionCandidate;
    if (candidate == null || !mounted) return;
    final target = candidate.model.name ?? candidate.model.id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('切换到视觉模型并重发？'),
        content: Text('刚刚的发送被拒绝：当前模型不支持图片输入。切换到 $target 并重新发送吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('不了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('切换并重发'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _selectModel(candidate.provider, candidate.model.id, null);
    await _send();
  }

  Future<void> _sendVoiceText(String text) async {
    if (text.trim().isEmpty) return;
    // The ASR result lands in the dock, then one send carries it together
    // with any staged images (image blocks ride the same content array).
    _inputController.text = text;
    await _send();
  }

  /// Pick an image (camera or gallery) and stage it for the next send.
  Future<void> _pickImage(ImageSource source) async {
    if (_pendingImages.length >= _kMaxImages) {
      _snack('图片数量已达上限（最多 $_kMaxImages 张）');
      return;
    }
    try {
      final file = await _imagePicker.pickImage(
        source: source,
        imageQuality: 80,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.length > _kMaxImageBytes) {
        _snack('图片超过 5MB 限制');
        return;
      }
      final name = file.name.isNotEmpty ? file.name : 'photo';
      final mediaType = _mediaTypeFor(name);
      if (mediaType == null) {
        _snack('仅支持 png / jpeg / webp / gif 图片');
        return;
      }
      setState(() {
        _pendingImages.add((name: name, mediaType: mediaType, bytes: bytes));
      });
    } catch (error) {
      if (mounted) _snack('选择图片失败：$error');
    }
  }

  String? _mediaTypeFor(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0) return null;
    final ext = filename.substring(dot + 1).toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      default:
        return null;
    }
  }

  // ------------------------------------------------------- model + effort

  Future<void> _openModelSheet() async {
    try {
      final models = await widget.connection.sessions.models();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _ModelSelectSheet(
          models: models,
          onSelectModel: (provider, model) async {
            await _selectModel(provider, model, null);
          },
          onSelectEffort: (provider, model, effort) async {
            await _selectModel(provider, model, effort);
          },
        ),
      );
    } catch (error) {
      if (mounted) _showError('模型列表加载失败', error);
    }
  }

  Future<void> _selectModel(String provider, String model, String? effort) async {
    try {
      await widget.connection.sessions.selectModel(
        sessionId: widget.sessionId,
        provider: provider,
        model: model,
        reasoningEffort: effort,
      );
      _currentModelName = model;
      setState(() {});
    } catch (error) {
      if (mounted) _showError('模型切换失败', error);
    }
  }

  // --------------------------------------------------------- permissions

  Future<void> _showPermissionMenu() async {
    final permissions = _permissions();
    if (permissions == null || permissions.options.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('权限信息暂不可用')),
        );
      }
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => _PermissionSheet(
        permissions: permissions,
        onSelect: (value) => _setPermission(value, current: permissions.current),
      ),
    );
  }

  /// Switch the session's permission preset. The web composer runs the same
  /// switch through the `/permission <value>` slash command; `custom` is a
  /// host-managed value that offers no preset switch.
  Future<void> _setPermission(String value, {String? current}) async {
    if (value == current) return;
    try {
      await widget.connection.commands.execute(
        agentId: widget.sessionId,
        line: '/permission $value',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('权限已切换：$value')),
        );
      }
    } catch (error) {
      if (mounted) _showError('权限切换失败', error);
    }
  }

  // ------------------------------------------------- live transcription + status

  /// Open the full-screen `/s/ws` live transcription session; in text mode
  /// the finished document lands in the input dock for review (staged images
  /// ride the same send), in voice mode it sends straight out because there
  /// is no input dock to stage it in.
  void _openLiveTranscription() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TranscriptionScreen(
          controller: widget.transcriptionController ??
              TranscriptionController(
                speechClient: DshSpeechClient(
                  baseUrl: widget.connection.baseUrl,
                  token: widget.connection.token,
                ),
              ),
          onSendToChat: (text) {
            if (!mounted) return;
            if (widget.voiceModeController.isVoice) {
              unawaited(_sendVoiceText(text));
            } else {
              setState(() => _inputController.text = text);
            }
          },
        ),
      ),
    );
  }

  /// Card tap on the goal strip: advance the phase (active→pause,
  /// paused→resume, complete→clear, blocked→pause) against the projection's
  /// ref; a missing projection or ref no-ops with a hint.
  Future<void> _goalPhaseAction(String phase) async {
    final goal = _proj('goal');
    final id = goal?['id'];
    final revision = goal?['revision'];
    if (goal == null || id is! String || revision is! num) {
      _snack('当前会话没有活动目标');
      return;
    }
    final ref = GoalRef(id: id, revision: revision.toInt());
    final agentId = widget.sessionId;
    try {
      switch (phase) {
        case 'paused':
          await widget.connection.goals.resume(agentId: agentId, ref: ref);
        case 'complete':
          await widget.connection.goals.clear(agentId: agentId, ref: ref);
        default:
          await widget.connection.goals.pause(agentId: agentId, ref: ref);
      }
    } catch (error) {
      if (mounted) _showError('目标操作失败', error);
    }
  }

  // ------------------------------------------------------------ slash menu

  Future<void> _openSlashMenu() async {
    
    try {
      final commands = await widget.connection.commands.listCommands(agentId: widget.sessionId);
      final skills = await widget.connection.commands.listSkills(
        sessionId: widget.sessionId,
      );
      final catalog = await widget.connection.subagents.list(
        parentSessionId: widget.sessionId,
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _SlashMenuSheet(
          commands: commands,
          skills: skills,
          subagents: catalog.entries,
          onCommand: (line) => _runSlash(line),
          onSkill: (name) async {
            await _runSlash('skill $name');
          },
          onSubagent: (id) => _snack('子智能体：$id'),
        ),
      );
    } catch (error) {
      if (mounted) _showError('命令列表加载失败', error);
    }
  }

  Future<void> _runSlash(String line) async {
    try {
      final result = await widget.connection.commands.execute(
        agentId: widget.sessionId,
        line: line,
      );
      if (mounted) _snack(result == null ? '已执行 $line' : '命令未生效：$line');
    } catch (error) {
      if (mounted) _showError('命令执行失败', error);
    }
  }

  Future<void> _openContextBreakdown(Map<String, Object?>? pressure) async {
    if (!mounted) return;
    await showContextBreakdownSheet(
      context,
      pressure: pressure,
      breakdown: _proj('context-breakdown'),
    );
  }

  // ------------------------------------------------------------- approve

  Future<bool> _decideApproval(
    ApprovalRequest request,
    ApprovalOutcome outcome,
  ) async {
    try {
      await widget.connection.interaction.answerApproval(
        request: request,
        outcome: outcome,
      );
      final sessionId = request.sessionId;
      if (sessionId != null) {
        widget.connection.clearApproval(sessionId, request.eventId);
      }
      return true;
    } catch (error) {
      if (mounted) _showError('审批失败', error);
      return false;
    }
  }

  Future<void> _submitQuestion(
    QuestionRequest request,
    QuestionAnswerBatch answer,
  ) async {
    try {
      await widget.connection.interaction.answerQuestions(
        request: request,
        answer: answer,
      );
      widget.connection.clearQuestion(widget.sessionId);
    } catch (error) {
      if (mounted) _showError('回答失败', error);
    }
  }

  // -------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final historyState = widget.connection.historyState(widget.sessionId);
    final loadingOlder = widget.connection.historyLoadingOlder(widget.sessionId);
    final pressure = _proj('context-pressure');
    final approvals = widget.connection.approvals(widget.sessionId).values.toList();
    final question = widget.connection.pendingQuestion(widget.sessionId);
    final running = _running;

    final transcript = _buildTranscript(
      historyState: historyState,
      loadingOlder: loadingOlder,
    );
    // The control strip rides INSIDE whichever input container is active
    // (web composer parity): model seat, permission, context ring along the
    // card's lower edge.
    final inputFooter = _ControlStrip(
      modelName: _currentModelName ?? '模型',
      pressure: pressure,
      onTapModel: _openModelSheet,
      onTapPermission: _showPermissionMenu,
      onTapContext: () => _openContextBreakdown(pressure),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(_sessionTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.mic),
            tooltip: '实时转录',
            onPressed: _openLiveTranscription,
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz),
            tooltip: '命令',
            onPressed: _openSlashMenu,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Goal/plan/todo/jobs projections live directly under the app
            // bar; the panel collapses to nothing when all are empty.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SessionStatusPanel(
                connection: widget.connection,
                sessionId: widget.sessionId,
              ),
            ),
            if (_workspaceLabel == null)
              WorkspaceHero(
                workspaceLabel: _workspaceLabel,
                onPickWorkspace: _pickWorkspace,
              ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(child: transcript),
                  // The mascot floats over the MIDDLE of the transcript as an
                  // overlay, not a layout slot. SQUARE tight constraints keep
                  // the sizeless CustomPaint visible; IgnorePointer lets taps
                  // and scrolls reach the transcript beneath.
                  if (widget.voiceModeController.isVoice)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Center(
                          child: SizedBox(
                            width: 160,
                            height: 160,
                            child: TalkMascot(
                              listening: _speechController != null &&
                                  (_speechController!.state ==
                                          SpeechState.recording ||
                                      _speechController!.state ==
                                          SpeechState.transcribing),
                              speaking: _speechController?.isSpeaking ?? false,
                              thinking: running &&
                                  !(_speechController?.isSpeaking ?? false) &&
                                  !(_speechController != null &&
                                      (_speechController!.state ==
                                              SpeechState.recording ||
                                          _speechController!.state ==
                                              SpeechState.transcribing)),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (running)
              TurnStatusRow(startTime: _surface.openTurnStartTime),
            GoalDock(
              goal: _proj('goal'),
              onAction: (phase) => unawaited(_goalPhaseAction(phase)),
            ),
            TodoPanel(todos: _projectionRaw('todos') is List
                ? _projectionRaw('todos')! as List<Object?>
                : const <Object?>[]),
            QueueDock(connection: widget.connection, sessionId: widget.sessionId),
            if (widget.voiceModeController.isVoice)
              VoiceDock(
                controller: _getSpeechController(),
                pendingImageStrip: _pendingImages.isEmpty
                    ? null
                    : _PendingImageStrip(
                        images: _pendingImages,
                        onRemove: _removePendingImage,
                      ),
                onAttach: _sending
                    ? null
                    : () {
                        unawaited(_openImageSource());
                      },
                footer: inputFooter,
              )
            else
              _InputDock(
                controller: _inputController,
                focusNode: _inputFocusNode,
                hint: _isBlank ? '描述你想要构建的内容' : '给智能体发消息',
                sending: _sending,
                running: running,
                voice: widget.voiceModeController.isVoice,
                pendingImages: _pendingImages,
                onSend: () => _send(),
                onSteer: () => _send(steer: true),
                onAttach: () => _openImageSource(),
                onRemoveImage: _removePendingImage,
                onStop: () => _stopTurn(),
                footer: inputFooter,
              ),
            if (question != null)
              _QuestionDock(question: question, onSubmit: (a) => _submitQuestion(question, a)),
            for (final approval in approvals)
              ApprovalCard(
                request: approval,
                onDecide: (outcome) => _decideApproval(approval, outcome),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _stopTurn() async {
    try {
      await widget.connection.sessions.cancel(sessionId: widget.sessionId);
    } catch (error) {
      if (mounted) _showError('停止失败', error);
    }
  }

  void _removePendingImage(int index) {
    if (index < 0 || index >= _pendingImages.length) return;
    setState(() => _pendingImages.removeAt(index));
  }

  Future<void> _openImageSource() async {
    final voice = widget.voiceModeController.isVoice;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              leading: Icon(Icons.photo_camera),
              title: Text('拍照'),
            ),
            ListTile(
              leading: Icon(Icons.photo_library),
              title: const Text('从相册选择'),
              onTap: () {
                Navigator.of(sheet).pop();
                _pickImage(ImageSource.gallery);
              },
            ),
            if (!voice)
              ListTile(
                leading: Icon(Icons.description_outlined),
                title: const Text('加载转录文件'),
                onTap: () {
                  Navigator.of(sheet).pop();
                  _pickTranscript();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickTranscript() async {
    try {
      final entries = await listTranscripts();
      if (entries.isEmpty) {
        _snack('暂无可用转录文件');
        return;
      }
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text('转录文件', style: Theme.of(sheet).textTheme.titleSmall),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final entry in entries)
                      ListTile(
                        title: Text(entry.filename),
                        subtitle: Text(
                          '${entry.turnCount} 轮 · ${entry.durationSeconds}s'
                          '${entry.diarized ? ' · 已说话人分离' : ''}',
                        ),
                        onTap: () {
                          Navigator.of(sheet).pop();
                          _loadTranscript(entry);
                        },
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () async {
                            await deleteTranscript(entry.file);
                            if (mounted) _snack('已删除 ${entry.filename}');
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    } catch (error) {
      if (mounted) _snack('读取转录失败：$error');
    }
  }

  Future<void> _loadTranscript(TranscriptEntry entry) async {
    try {
      final body = await loadTranscriptBody(entry.file);
      _inputController.text = body;
      _inputFocusNode.requestFocus();
    } catch (error) {
      if (mounted) _snack('读取转录失败：$error');
    }
  }

  Widget _buildTranscript({
    required SessionHistoryState historyState,
    required bool loadingOlder,
  }) {
    final hasMessages = _surface.messages.isNotEmpty;
    return Column(
      children: [
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification) {
                final pos = notification.metrics;
                _updateFollowing(
                  pos.pixels >= pos.maxScrollExtent - _kFollowThresholdPx,
                );
                if (pos.pixels <= _kAutoLoadOlderTopPx &&
                    widget.connection.historyHasMore(widget.sessionId)) {
                  widget.connection.loadOlder(widget.sessionId);
                }
              }
              return false;
            },
            child: hasMessages ? _messageList() : _EmptyState(blank: _isBlank),
          ),
        ),
        if (!hasMessages && historyState == SessionHistoryState.loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (!hasMessages && historyState == SessionHistoryState.error)
          _HistoryErrorView(
            message: widget.connection.historyError(widget.sessionId) ??
                '历史加载失败',
            onRetry: () => widget.connection.loadHistory(widget.sessionId),
          ),
        if (hasMessages && (widget.connection.historyHasMore(widget.sessionId)))
          _LoadOlderRow(
            loading: loadingOlder,
            onTap: () => widget.connection.loadOlder(widget.sessionId),
          ),
      ],
    );
  }

  /// The transcript list (oldest-first) plus a back-to-bottom control shown
  /// once the viewport detaches from the newest message.
  Widget _messageList() {
    final surface = _surface;
    final list = ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      itemCount: surface.messages.length,
      itemBuilder: (context, index) {
        final message = surface.messages[index];
        return _MessageTile(
          connection: widget.connection,
          sessionId: widget.sessionId,
          message: message,
          visibleTextChars: _visibleTextChars,
        );
      },
    );
    return Stack(
      children: [
        list,
        if (!_following)
          Positioned(
            right: 16,
            bottom: 16,
            child: _BackToBottomFab(onTap: _dockToBottom),
          ),
      ],
    );
  }

  void _updateFollowing(bool following) {
    if (following == _following) return;
    setState(() => _following = following);
  }

  void _dockToBottom() {
    setState(() => _following = true);
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }
}

/// The session control strip: the current-model seat plus the permission and
/// context actions (web ChatView's control row).
class _ControlStrip extends StatelessWidget {
  const _ControlStrip({
    required this.modelName,
    required this.pressure,
    required this.onTapModel,
    required this.onTapPermission,
    required this.onTapContext,
  });

  final String modelName;

  /// `contextPressure` projection value driving the occupancy ring; null
  /// paints no arc.
  final Map<String, Object?>? pressure;
  final VoidCallback onTapModel;
  final VoidCallback onTapPermission;
  final VoidCallback onTapContext;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Lives INSIDE the active input container's lower edge (text or voice
    // dock), so it carries no chrome of its own — the host card draws the
    // border and the divider above this row.
    return Row(
      children: [
        _IconButton(
          icon: Icons.memory_outlined,
          tooltip: '选择模型',
          onPressed: onTapModel,
          trailing: Text(
            modelName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ),
        const Spacer(),
        _IconButton(
          icon: Icons.shield_outlined,
          tooltip: '访问权限',
          onPressed: onTapPermission,
        ),
        // Web parity: the composer's context meter — the occupancy ring
        // wraps the trigger; the breakdown panel opens via onTapContext.
        // The ring supplies the percent tooltip, so the inner button has
        // none of its own.
        ContextRing(
          pressure: pressure,
          dimension: 26,
          child: IconButton(
            icon: const Icon(Icons.radar_outlined),
            onPressed: onTapContext,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            iconSize: 15,
          ),
        ),
      ],
    );
  }
}

/// A public running-turn status row (spinner + elapsed clock) shown at the
/// transcript tail while a turn is in flight.
class TurnStatusRow extends StatefulWidget {
  const TurnStatusRow({super.key, this.startTime, this.now});

  final int? startTime;

  /// Injectable clock for tests; defaults to [DateTime.now].
  final DateTime Function()? now;

  @override
  State<TurnStatusRow> createState() => _TurnStatusRowState();
}

class _TurnStatusRowState extends State<TurnStatusRow> {
  late final Timer _ticker = Timer.periodic(
    const Duration(seconds: 1),
    (_) => setState(() {}),
  );

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  int get _elapsedSeconds {
    final now = widget.now ?? DateTime.now;
    final start = widget.startTime;
    if (start == null) return 0;
    final ms = now().millisecondsSinceEpoch - start;
    return ms < 0 ? 0 : ms ~/ 1000;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            '深度潜行',
            style: TextStyle(color: scheme.outline, fontSize: 13),
          ),
          if (_elapsedSeconds >= 15) ...[
            const SizedBox(width: 8),
            Text(
              '${_elapsedSeconds}s',
              style: TextStyle(color: scheme.outline, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.blank});

  final bool blank;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          blank ? '这个会话还是空的，发第一条消息开始吧' : '加载中…',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

/// A transcript entry row (user message, or an assistant turn with its blocks).
class _MessageTile extends StatelessWidget {
  const _MessageTile({
    required this.connection,
    required this.sessionId,
    required this.message,
    this.visibleTextChars,
  });

  final ConnectionController connection;
  final String sessionId;
  final SessionMessage message;

  /// Karaoke hook: maps (message seq, text-block start offset) to the
  /// visible character count of that block, or null for no truncation.
  final int? Function(int seq, int blockStart)? visibleTextChars;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (message is UserSessionMessage) {
      final user = message as UserSessionMessage;
      return _UserMessageTile(content: user.content, scheme: scheme);
    }
    final assistant = message as AssistantSessionMessage;
    final blocks = assistant.blocks;
    if (blocks.isEmpty) {
      if (!assistant.streaming) return const SizedBox.shrink();
      return _BlinkingCursorRow();
    }
    final children = <Widget>[];
    // Text blocks concatenate into the message's joined text; each block's
    // karaoke cut needs its start offset within that concatenation.
    var textOffset = 0;
    for (final block in blocks) {
      children.add(_buildBlock(context, block, scheme, textOffset));
      if (block is AssistantTextBlock) textOffset += block.text.length;
    }
    if (assistant.streaming) children.add(const _BlinkingCursor());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _buildBlock(
    BuildContext context,
    AssistantBlock block,
    ColorScheme scheme,
    int blockStart,
  ) {
    switch (block) {
      case AssistantTextBlock(:final text):
        final visible = _visibleSlice(assistantSeq, blockStart, text);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: MarkdownBody(
            data: visible,
            styleSheet: MarkdownStyleSheet(
              p: TextStyle(color: scheme.onSurface),
              code: TextStyle(color: scheme.primary, backgroundColor: scheme.primary.withOpacity(0.08)),
            ),
          ),
        );
      case AssistantReasoningBlock(:final text):
        return _ReasoningDisclosure(summary: '深度思考', text: text, scheme: scheme);
      case AssistantToolCallBlock(:final callId, :final name, :final arguments, :final result, :final error):
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ToolCard(call: _toToolCall(callId, name, arguments, result, error)),
        );
      case AssistantOtherBlock(:final block):
        return _GenericBlockView(block: block, scheme: scheme);
    }
  }

  /// The block's text truncated to the karaoke reveal position, or the full
  /// text when no truncation applies.
  String _visibleSlice(int seq, int blockStart, String text) {
    final limit = visibleTextChars?.call(seq, blockStart);
    if (limit == null) return text;
    final within = limit - blockStart;
    if (within <= 0) return '';
    if (within >= text.length) return text;
    return text.substring(0, within);
  }

  int get assistantSeq => (message as AssistantSessionMessage).seq;
}

class _UserMessageTile extends StatelessWidget {
  const _UserMessageTile({required this.content, required this.scheme});

  final List<Map<String, Object?>> content;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final texts = content
        .where((part) => part['type'] == 'text')
        .map((part) => part['text'] as String? ?? '')
        .where((t) => t.isNotEmpty)
        .join('\n');
    final images = content.where((part) => part['type'] == 'image').toList();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // The scheme's container pair keeps the bubble readable in both
        // themes (dark: near-white text on dark gray-blue; light: dark text
        // on light blue). A translucent primary over the dark surface was
        // nearly black, and the text was hardcoded black — unreadable.
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (texts.isNotEmpty)
            Text(texts, style: TextStyle(color: scheme.onPrimaryContainer)),
          if (images.isNotEmpty)
            const SizedBox(height: 8),
          for (final image in images)
            _UserImageTile(content: image),
        ],
      ),
    );
  }
}

class _UserImageTile extends StatelessWidget {
  const _UserImageTile({required this.content});

  final Map<String, Object?> content;

  @override
  Widget build(BuildContext context) {
    final data = content['data'];
    if (data is! String) return const SizedBox.shrink();
    final bytes = base64Decode(data);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(bytes, height: 120, fit: BoxFit.cover),
    );
  }
}

class _BlinkingCursorRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 6),
    child: _BlinkingCursor(),
  );
}

class _GenericBlockView extends StatelessWidget {
  const _GenericBlockView({required this.block, required this.scheme});

  final Map<String, Object?> block;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final type = block['type'];
    if (type == 'image' || block['data'] is String) {
      final data = block['data'];
      if (data is String && data.isNotEmpty) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(base64Decode(data), height: 160, fit: BoxFit.cover),
        );
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        '$block',
        style: TextStyle(color: scheme.outline, fontSize: 12),
      ),
    );
  }
}

/// A tool call rendered through the shared [ToolCard].
AssistantToolCallBlock _toToolCall(
  String callId,
  String name,
  String arguments,
  String? result,
  Map<String, Object?>? error,
) =>
    AssistantToolCallBlock(
      callId: callId,
      name: name,
      arguments: arguments,
      result: result,
      error: error,
    );

/// A collapsible reasoning (deep-thinking) block.
class _ReasoningDisclosure extends StatelessWidget {
  const _ReasoningDisclosure({
    required this.summary,
    required this.text,
    required this.scheme,
  });

  final String summary;
  final String text;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: false,
      tilePadding: EdgeInsets.zero,
      title: Row(
        children: [
          Icon(Icons.psychology_outlined, size: 16, color: scheme.outline),
          const SizedBox(width: 6),
          Text(summary, style: TextStyle(color: scheme.outline, fontSize: 12)),
        ],
      ),
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SelectableText(
            text,
            style: TextStyle(color: scheme.outline, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _BlinkingCursor extends StatelessWidget {
  const _BlinkingCursor();

  @override
  Widget build(BuildContext context) {
    // The streaming caret in the brand blue; a hardcoded black54 block is
    // invisible on the dark surface.
    final caret = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 8,
      height: 16,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: caret,
          borderRadius: const BorderRadius.all(Radius.circular(2)),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ input dock

class _InputDock extends StatefulWidget {
  const _InputDock({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.sending,
    required this.running,
    required this.voice,
    required this.pendingImages,
    required this.onSend,
    required this.onSteer,
    required this.onAttach,
    required this.onRemoveImage,
    required this.onStop,
    this.footer,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final bool sending;
  final bool running;
  final bool voice;
  final List<({String name, String mediaType, Uint8List bytes})> pendingImages;
  final VoidCallback onSend;
  final VoidCallback onSteer;
  final VoidCallback onAttach;
  final void Function(int) onRemoveImage;
  final VoidCallback onStop;

  /// The control strip rendered inside the card's lower edge, below the
  /// input row (model / permission / context ring). Null omits the divider.
  final Widget? footer;

  @override
  State<_InputDock> createState() => _InputDockState();
}

class _InputDockState extends State<_InputDock> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasInput = widget.controller.text.trim().isNotEmpty ||
        widget.pendingImages.isNotEmpty;
    // The bordered composer card: input row on top, control strip along the
    // card's lower edge (web composer parity).
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: scheme.outlineVariant),
        ),
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.pendingImages.isNotEmpty)
              _PendingImageStrip(
                images: widget.pendingImages,
                onRemove: widget.onRemoveImage,
              ),
            // IntrinsicHeight gives the stretch row a bounded height (the
            // tallest child — the send seat), so the text field fills the
            // whole input region top-to-bottom.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                // Hug the card's left edge: a raw InkWell with the glyph
                // left-aligned in a 28px box — IconButton's internal padding
                // left a ~22px hole between the glyph and the text field.
                Tooltip(
                  message: '添加图片',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: (widget.running && !widget.voice)
                          ? null
                          : widget.onAttach,
                      child: SizedBox(
                        width: 28,
                        height: 44,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Icon(
                            Icons.attach_file,
                            size: 22,
                            // The source menu is gated: closed while a turn runs
                            // in text mode (a mid-turn pick would race the
                            // prompt); in voice mode staging stays openable
                            // because staged images ride along with the next
                            // spoken line.
                            color: (widget.running && !widget.voice)
                                ? scheme.onSurface.withValues(alpha: 0.38)
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 120),
                    child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      maxLines: null,
                      minLines: 1,
                      // The row stretches the field to the card's full input
                      // region; keep the text centered inside as it grows.
                      textAlignVertical: TextAlignVertical.center,
                      decoration: InputDecoration(
                        hintText: widget.hint,
                        isDense: true,
                        // Fill matches the card container so the text area
                        // reads as one seamless surface (web composer parity).
                        filled: true,
                        fillColor: scheme.surface,
                        // The global inputDecorationTheme paints visible
                        // enabled/focused borders on every field; the composer
                        // field must override BOTH to stay frameless.
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                _SendSeat(
                  sending: widget.sending,
                  running: widget.running,
                  hasInput: hasInput,
                  onSend: widget.onSend,
                  onSteer: widget.onSteer,
                  onStop: widget.onStop,
                ),
                ],
              ),
            ),
            if (widget.footer != null) ...[
              Divider(height: 1, thickness: 0.5, color: scheme.outlineVariant),
              widget.footer!,
            ],
          ],
        ),
      ),
    );
  }
}

class _SendSeat extends StatefulWidget {
  const _SendSeat({
    required this.sending,
    required this.running,
    required this.hasInput,
    required this.onSend,
    required this.onSteer,
    required this.onStop,
  });

  final bool sending;
  final bool running;
  final bool hasInput;
  final VoidCallback onSend;
  final VoidCallback onSteer;
  final VoidCallback onStop;

  @override
  State<_SendSeat> createState() => _SendSeatState();
}

class _SendSeatState extends State<_SendSeat> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Running + input present: long-press steers, tap stops.
    final showStop = widget.running;
    final canSend = widget.hasInput && !widget.sending;
    return GestureDetector(
      onTap: showStop ? widget.onStop : widget.onSend,
      onLongPress: (widget.running && widget.hasInput) ? widget.onSteer : null,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: showStop
                ? scheme.error
                : (canSend ? scheme.primary : scheme.outlineVariant),
          ),
          child: Center(
            child: showStop
                ? const Icon(Icons.stop_circle, color: Colors.white)
                : Icon(
                    widget.sending ? Icons.hourglass_top : Icons.send,
                    color: canSend ? scheme.onPrimary : scheme.onSurface.withOpacity(0.5),
                  ),
          ),
        ),
      ),
    );
  }
}

class _PendingImageStrip extends StatelessWidget {
  const _PendingImageStrip({required this.images, required this.onRemove});

  final List<({String name, String mediaType, Uint8List bytes})> images;
  final void Function(int) onRemove;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) => _PendingImageTile(
          bytes: images[index].bytes,
          onRemove: () => onRemove(index),
        ),
      ),
    );
  }
}

class _PendingImageTile extends StatelessWidget {
  const _PendingImageTile({required this.bytes, required this.onRemove});

  final Uint8List bytes;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(bytes, width: 56, height: 56, fit: BoxFit.cover),
        ),
        Positioned(
          top: 0,
          right: 0,
          child: IconButton(
            icon: const Icon(Icons.close, size: 16),
            color: Colors.white,
            onPressed: onRemove,
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------- smaller bits

class _IconButton extends StatelessWidget {
  const _IconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.trailing,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    if (trailing == null) {
      return IconButton(
        icon: Icon(icon),
        tooltip: tooltip,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
        iconSize: 15,
      );
    }
    // A labeled seat (icon + text) with one wide tap target.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15),
              const SizedBox(width: 4),
              trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

class _BackToBottomFab extends StatelessWidget {
  const _BackToBottomFab({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      shape: const CircleBorder(),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            Icons.keyboard_arrow_down,
            color: scheme.onPrimary,
          ),
        ),
      ),
    );
  }
}

class _LoadOlderRow extends StatelessWidget {
  const _LoadOlderRow({required this.loading, required this.onTap});

  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: TextButton.icon(
          onPressed: loading ? null : onTap,
          icon: loading
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.expand_less, size: 18),
          label: Text(loading ? '加载中' : '加载更早'),
        ),
      ),
    );
  }
}

class _HistoryErrorView extends StatelessWidget {
  const _HistoryErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(message, style: TextStyle(color: scheme.error)),
          const SizedBox(height: 8),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _QuestionDock extends StatelessWidget {
  const _QuestionDock({required this.question, required this.onSubmit});

  final QuestionRequest question;
  final void Function(QuestionAnswerBatch) onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(12),
      child: QuestionSheet(
        question: question,
        onSubmit: (batch) {
          onSubmit(batch);
        },
      ),
    );
  }
}

// ----------------------------------------------------------- model sheet

enum _ModelPane { root, model, effort }

class _ModelSelectSheet extends StatefulWidget {
  const _ModelSelectSheet({
    required this.models,
    required this.onSelectModel,
    required this.onSelectEffort,
  });

  final SessionModels models;
  final void Function(String provider, String model) onSelectModel;
  final void Function(String provider, String model, String? effort) onSelectEffort;

  @override
  State<_ModelSelectSheet> createState() => _ModelSelectSheetState();
}

class _ModelSelectSheetState extends State<_ModelSelectSheet> {
  _ModelPane _pane = _ModelPane.root;
  ({String provider, String model})? _effortTarget;

  String _currentLabel() {
    final model = widget.models.defaultSelection['model'];
    if (model is String && model.isNotEmpty) return model;
    return 'Provider 默认';
  }

  /// The catalog entry of the deployment-default model, when annotated.
  ModelCatalogModel? get _currentEntry {
    final id = widget.models.defaultSelection['model'];
    for (final group in widget.models.groups) {
      for (final model in group.models) {
        if (model.id == id) return model;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = widget.models.groups;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  if (_pane != _ModelPane.root)
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: '返回',
                      onPressed: () => setState(() => _pane = _ModelPane.root),
                    ),
                  Expanded(
                    child: Text(
                      switch (_pane) {
                        _ModelPane.root => '模型选择',
                        _ModelPane.model => '选择模型',
                        _ModelPane.effort => '推理强度',
                      },
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  if (_pane == _ModelPane.root)
                    Flexible(
                      child: Text(
                        // $_currentLabel() would interpolate the tear-off and
                        // print a closure; the call must sit inside ${}.
                        '当前：${_currentLabel()}'
                        '${_currentEntry?.refusesImageInput == true ? '（不支持图片）' : ''}',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: switch (_pane) {
                _ModelPane.root => _groupList(groups, scheme),
                _ModelPane.model => _modelList(),
                _ModelPane.effort => _effortList(),
              },
            ),
          ],
        );
      },
    );
  }

  Widget _groupList(List<ModelProviderGroup> groups, ColorScheme scheme) {
    if (widget.models.routableProviders.isEmpty) {
      return const Center(child: Text('（不可路由）'));
    }
    return ListView(
      children: [
        for (final group in groups)
          ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                group.name,
                style: TextStyle(color: scheme.outline, fontSize: 12),
              ),
            ),
            for (final model in group.models)
              ListTile(
                title: Row(
                  children: [
                    Flexible(
                      child: Text(model.name ?? model.id, overflow: TextOverflow.ellipsis),
                    ),
                    if (model.supportsImageInput) ...[
                      const SizedBox(width: 6),
                      _VisionBadge(scheme: scheme),
                    ],
                  ],
                ),
                subtitle: model.description != null
                    ? Text(model.description!)
                    : null,
                trailing: widget.models.defaultSelection['model'] == model.id
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                onTap: () {
                  setState(() {
                    _pane = _ModelPane.model;
                    _effortTarget = (provider: group.id, model: model.id);
                  });
                },
              ),
          ],
      ],
    );
  }

  Widget _modelList() {
    final target = _effortTarget;
    if (target == null) return const SizedBox.shrink();
    final group = widget.models.groups
        .where((g) => g.id == target.provider)
        .firstOrNull;
    final model = group?.models.where((m) => m.id == target.model).firstOrNull;
    return ListView(
      children: [
        ListTile(
          title: Text(model?.name ?? target.model),
          subtitle: model?.description != null
              ? Text(model!.description!)
              : null,
          trailing: model?.reasoning != null
              ? const Icon(Icons.psychology_outlined)
              : null,
          onTap: () async {
            if (model?.reasoning == null) {
              widget.onSelectModel(target.provider, target.model);
              if (mounted) Navigator.of(context).pop();
            } else {
              setState(() => _pane = _ModelPane.effort);
            }
          },
        ),
      ],
    );
  }

  Widget _effortList() {
    final target = _effortTarget;
    if (target == null) return const SizedBox.shrink();
    final group = widget.models.groups
        .where((g) => g.id == target.provider)
        .firstOrNull;
    final model = group?.models.where((m) => m.id == target.model).firstOrNull;
    final reasoning = model?.reasoning;
    final efforts = reasoning?.efforts ?? const <ModelReasoningEffort>[];
    final defaultEffort = reasoning?.defaultEffort;
    return ListView(
      children: [
        for (final effort in efforts)
          ListTile(
            title: Text(effort.name ?? effort.id),
            subtitle: effort.description != null
                ? Text(effort.description!)
                : null,
            trailing: effort.id == defaultEffort
                ? const Icon(Icons.check, color: Colors.green)
                : null,
            onTap: () {
              widget.onSelectEffort(target.provider, target.model, effort.id);
              if (mounted) Navigator.of(context).pop();
            },
          ),
        if (efforts.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: Text('该模型不支持推理强度设置')),
          ),
      ],
    );
  }
}

class _PermissionSheet extends StatelessWidget {
  const _PermissionSheet({required this.permissions, required this.onSelect});

  final ({String? current, List<({String value, String name, String? description})> options})
      permissions;

  /// Runs the preset switch for one option value (`/permission <value>`).
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        return ListView(
          controller: scrollController,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  const Text(
                    '访问权限',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ],
              ),
            ),
            for (final option in permissions.options)
              if (option.value != 'custom')
                ListTile(
                  title: Text(option.name),
                  subtitle: option.description != null
                      ? Text(option.description!)
                      : null,
                  trailing: option.value == permissions.current
                      ? const Icon(Icons.check, color: Colors.green)
                      : null,
                  onTap: () {
                    Navigator.of(context).pop();
                    onSelect(option.value);
                  },
                ),
          ],
        );
      },
    );
  }
}

class _SlashMenuSheet extends StatelessWidget {
  const _SlashMenuSheet({
    required this.commands,
    required this.skills,
    required this.subagents,
    required this.onCommand,
    required this.onSkill,
    required this.onSubagent,
  });

  final List<CommandDescriptor> commands;
  final List<SkillEntry> skills;
  final List<SubagentListEntry> subagents;
  final ValueChanged<String> onCommand;
  final ValueChanged<String> onSkill;
  final ValueChanged<String> onSubagent;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      builder: (context, scrollController) {
        void pick(VoidCallback action) {
          Navigator.of(context).pop();
          action();
        }

        return ListView(
          controller: scrollController,
          children: [
            if (commands.isNotEmpty) ...[
              _sectionHeader(context, '命令'),
              for (final command in commands)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.terminal, size: 20),
                  title: Text('/${command.name}'),
                  subtitle: command.description.isNotEmpty
                      ? Text(command.description, maxLines: 1, overflow: TextOverflow.ellipsis)
                      : null,
                  onTap: () => pick(() => onCommand('/${command.name}')),
                ),
            ],
            if (skills.isNotEmpty) ...[
              _sectionHeader(context, '技能'),
              for (final skill in skills)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.auto_awesome, size: 20),
                  title: Text(skill.name),
                  subtitle: skill.description.isNotEmpty
                      ? Text(skill.description, maxLines: 1, overflow: TextOverflow.ellipsis)
                      : null,
                  onTap: () => pick(() => onSkill(skill.name)),
                ),
            ],
            if (subagents.isNotEmpty) ...[
              _sectionHeader(context, '子智能体'),
              for (final entry in subagents)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.account_tree_outlined, size: 20),
                  title: Text(entry.label ?? entry.id),
                  subtitle: entry.activity != null
                      ? Text(
                          '${entry.kind}${entry.activity != null ? ' · ${entry.activity}' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null,
                  onTap: () => pick(() => onSubagent(entry.id)),
                ),
            ],
          ],
        );
      },
    );
  }

  Widget _sectionHeader(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.outline,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The 「视觉」 marker on catalog entries whose model declares image input.
class _VisionBadge extends StatelessWidget {
  const _VisionBadge({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_outlined, size: 11, color: scheme.onPrimaryContainer),
          const SizedBox(width: 2),
          Text(
            '视觉',
            style: TextStyle(fontSize: 10, color: scheme.onPrimaryContainer),
          ),
        ],
      ),
    );
  }
}
