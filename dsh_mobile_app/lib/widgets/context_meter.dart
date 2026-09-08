/// Context-occupancy ring (display only) plus the breakdown panel sheet,
/// mirroring web's ContextMeter. The ring wraps an arbitrary child and paints
/// the token occupancy arc from the `contextPressure` projection; the panel
/// is opened explicitly by the caller (the Appbar entry in the chat screen)
/// so the ring never competes for gestures.
library;

import 'package:flutter/material.dart';

/// Occupancy percent (0-100) from a `contextPressure` projection, or null
/// when the projection is absent or malformed.
int? _toInt(Object? value) => value is int ? value : (value is double ? value.toInt() : null);

double? contextPercentOf(Map<String, Object?>? pressure) {
  final tokens = _toInt(pressure?['pressureTokens']);
  final window = _toInt(pressure?['contextWindow']);
  if (tokens == null || window == null || window == 0) return null;
  return (tokens / window * 100).clamp(0, 100).toDouble();
}

/// Pure-display occupancy ring around [child]. Paints nothing when
/// [pressure] is absent; never registers gestures.
class ContextRing extends StatelessWidget {
  const ContextRing({
    super.key,
    required this.pressure,
    required this.child,
    this.dimension = 40.0,
  });

  /// `contextPressure` projection value, or null when absent.
  final Map<String, Object?>? pressure;

  /// The control wrapped by the ring, centered.
  final Widget child;

  /// Square side of the ring box; the arc hugs this box. Compact hosts
  /// (the chat control strip) pass less than the 40 default.
  final double dimension;

  @override
  Widget build(BuildContext context) {
    final percent = contextPercentOf(pressure);
    final ring = CustomPaint(
      painter: _RingPainter(
        percent: percent ?? 0,
        color: Theme.of(context).colorScheme.primary,
        visible: percent != null,
      ),
      child: SizedBox.square(
        dimension: dimension,
        child: Center(child: child),
      ),
    );
    if (percent == null) return ring;
    return Tooltip(
      message: '上下文已用 ${percent.round()}%',
      child: ring,
    );
  }
}

/// Show the context breakdown panel as a modal bottom sheet. [pressure] and
/// [breakdown] are the `contextPressure` / `contextBreakdown` projection
/// values (null-safe: an empty panel renders placeholders).
Future<void> showContextBreakdownSheet(
  BuildContext context, {
  required Map<String, Object?>? pressure,
  required Map<String, Object?>? breakdown,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => _ContextPanel(
      percent: contextPercentOf(pressure),
      pressure: pressure,
      breakdown: breakdown,
    ),
  );
}

/// Bottom-sheet context breakdown panel.
class _ContextPanel extends StatelessWidget {
  const _ContextPanel({
    required this.percent,
    required this.pressure,
    required this.breakdown,
  });

  final double? percent;
  final Map<String, Object?>? pressure;
  final Map<String, Object?>? breakdown;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final percent = this.percent;

    final usedTokens = _toInt(pressure?['pressureTokens']);
    final contextWindow = _toInt(pressure?['contextWindow']);
    final system = _toInt(breakdown?['systemTokens']);
    final tools = _toInt(breakdown?['toolsTokens']);
    final messages = _toInt(breakdown?['messageTokens']);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  percent == null
                      ? '暂无上下文用量数据'
                      : '上下文已用 ${percent.round()}%',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (usedTokens != null && contextWindow != null)
                  Text(
                    '~${_formatTokens(usedTokens)} / ${_formatTokens(contextWindow)}',
                    style: TextStyle(color: scheme.outline, fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // Segmented occupancy bar.
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 6,
                child: Row(
                  children: [
                    if (system != null && system > 0)
                      Expanded(flex: system, child: Container(color: scheme.primary)),
                    if (tools != null && tools > 0)
                      Expanded(flex: tools, child: Container(color: Colors.teal)),
                    if (messages != null && messages > 0)
                      Expanded(flex: messages, child: Container(color: Colors.amber)),
                    if ((system ?? 0) + (tools ?? 0) + (messages ?? 0) <= 0)
                      Container(color: scheme.outlineVariant),
                  ],
                ),
              ),
            ),
            if (breakdown != null) ...[
              const SizedBox(height: 12),
              _row(context, '系统提示词', system, scheme.primary),
              _row(context, '工具', tools, Colors.teal),
              _row(context, '对话消息', messages, Colors.amber),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, int? value, Color color) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13)),
          const Spacer(),
          Text(
            value == null ? '-' : '~${_formatTokens(value)}',
            style: TextStyle(fontSize: 13, color: scheme.outline),
          ),
        ],
      ),
    );
  }

  String _formatTokens(int n) {
    if (n >= 1_000_000) return '${(n / 1_000_000).toStringAsFixed(1)}M';
    if (n >= 1_000) return '${(n / 1_000).toStringAsFixed(1)}k';
    return '$n';
  }
}

/// Ring painter: track + filled arc; invisible when not [visible].
class _RingPainter extends CustomPainter {
  _RingPainter({required this.percent, required this.color, required this.visible});

  final double percent;
  final Color color;
  final bool visible;

  @override
  void paint(Canvas canvas, Size size) {
    if (!visible) return;
    const stroke = 2.0;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color.withValues(alpha: 0.2);
    canvas.drawCircle(center, radius, track);
    final fill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -3.1416 / 2, // start at top
      percent / 100 * 2 * 3.1416,
      false,
      fill,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.percent != percent || oldDelegate.color != color || oldDelegate.visible != visible;
}
