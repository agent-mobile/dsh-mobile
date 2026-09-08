/// Regression: TalkMascot must load the shipped sprite pack and render an
/// actual paint. The build's `CustomPaint` has no intrinsic size, so the
/// widget only shows inside square tight constraints — loose width collapses
/// it to 0x0, which used to leave an invisible slot (a black hole) in the
/// chat screen's voice-mode layout.
library;

import 'package:dsh_mobile_app/widgets/mascot/mascot_assets.dart';
import 'package:dsh_mobile_app/widgets/mascot/talk_mascot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('loads the deepseek pack and paints inside square constraints',
      (tester) async {
    // Warm the registry outside fake async: real asset file I/O never
    // completes under the test binding's FakeAsync zone. On a device the
    // widget's own resolve() call performs this load naturally; in tests the
    // shared cache makes the widget's call complete immediately.
    final assets = await tester.runAsync(() => MascotSkinRegistry.resolve('deepseek'));
    expect(assets, isNotNull, reason: 'the shipped sprite pack must load');

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 180,
              child: TalkMascot(listening: true, speaking: false),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // The assets branch renders a CustomPaint with a painter; the unloaded
    // branch renders SizedBox.shrink and would find nothing here.
    final painted = find.descendant(
      of: find.byType(TalkMascot),
      matching: find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter != null,
      ),
    );
    expect(painted, findsOneWidget);

    final box = tester.renderObject<RenderBox>(find.byType(TalkMascot));
    expect(box.size, const Size(180, 180));
  });

  testWidgets('loose width collapses the paint (documents the slot contract)',
      (tester) async {
    await tester.runAsync(() => MascotSkinRegistry.resolve('deepseek'));
    // Height-only box: width stays loose, so CustomPaint takes Size.zero —
    // the exact misuse that produced the chat screen's black hole.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: 180,
              child: TalkMascot(listening: true, speaking: false),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final box = tester.renderObject<RenderBox>(find.byType(TalkMascot));
    expect(box.size.width, 0, reason: 'loose width must not be relied on');
  });
}
