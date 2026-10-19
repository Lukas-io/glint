import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glintride/ui/sheet.dart';

void main() {
  testWidgets('tapping the handle opens and closes the sheet', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: RideSheet(more: [Text('more')], children: [Text('less')]),
          ),
        ),
      ),
    );
    expect(find.text('less'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Show more'));
    await t.pumpAndSettle();
    expect(find.text('more'), findsOneWidget);
    await t.drag(find.text('more'), const Offset(0, 300));
    await t.pumpAndSettle();
    expect(find.text('less'), findsOneWidget);
    await t.fling(find.text('less'), const Offset(0, -200), 1000);
    await t.pumpAndSettle();
    expect(find.text('more'), findsOneWidget);
  });
}
