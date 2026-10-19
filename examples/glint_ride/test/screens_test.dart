import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glintride/driver_screen.dart';
import 'package:glintride/trip/geo.dart';
import 'package:glintride/trip/live.dart';
import 'package:glintride/ui/live_bar.dart';
import 'package:glintride/ui/parts.dart';
import 'package:glintride/ui/sheet.dart';
import 'package:glintride/ui/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Renders the sheets and banner over a static map picture, to compare with the design canvas.
Future<void> _fonts() async {
  Future<void> load(String family, String path) async {
    final l = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
    await l.load();
  }

  final pub = '${Platform.environment['HOME']}/.pub-cache/hosted/pub.dev';
  final flutter = Platform.environment['FLUTTER_ROOT'] ?? '/home/claude/sdk/flutter';
  await load('InstrumentSans', 'assets/fonts/InstrumentSans.ttf');
  await load(
    'packages/lucide_icons_flutter/Lucide',
    Directory('$pub/lucide_icons_flutter-4.0.0/assets')
        .listSync()
        .whereType<File>()
        .firstWhere((f) => f.path.endsWith('lucide.ttf'))
        .path,
  );
  await load('MaterialIcons', '$flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
}

Widget _frame(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: appTheme(),
  home: MediaQuery(
    data: const MediaQueryData(size: Size(390, 844), devicePixelRatio: 2, padding: EdgeInsets.only(top: 54)),
    child: Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Color(0xFFE9EAEE))),
          child,
        ],
      ),
    ),
  ),
);

void main() {
  setUpAll(_fonts);
  final route = lekkiPickupRoute;
  final s = LiveStats.of(route, route.pointAt(route.length - 610), 6.7);

  testWidgets('rider collapsed', (t) async {
    t.view.physicalSize = const Size(780, 1688);
    t.view.devicePixelRatio = 2;
    await t.pumpWidget(
      _frame(
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: RideSheet(
            children: [
              LiveBar(
                title: 'Arriving in ${s.minutes} min',
                mood: 'eta',
                trailing: '8:42 am',
                left: '${fmtDistance(s.remaining)} away · 24 km/h',
                right: 'Admiralty Way',
              ),
              const CompactPerson(
                initials: 'TA',
                top: 'KJA 482 AB',
                sub: 'Tunde A. · Silver Toyota Corolla',
                call: 'Call',
              ),
            ],
          ),
        ),
      ),
    );
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/rider.png'));
  });

  testWidgets('driver collapsed with directions', (t) async {
    t.view.physicalSize = const Size(780, 1688);
    t.view.devicePixelRatio = 2;
    final d = Directions.of(route, 230);
    await t.pumpWidget(
      _frame(
        Stack(
          children: [
            Positioned(left: 12, right: 12, top: 58, child: DirectionsBanner(d)),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: RideSheet(
                children: [
                  LiveBar(
                    title: 'Ada in 2 min',
                    mood: 'eta',
                    trailing: '8:42 am',
                    left: '${fmtDistance(route.length - 230)} · 24 km/h',
                    right: d.then!.text,
                  ),
                  PrimaryButton('Arrived', onTap: () {}),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/driver.png'));
  });

  testWidgets('rider pulled up', (t) async {
    t.view.physicalSize = const Size(780, 1688);
    t.view.devicePixelRatio = 2;
    await t.pumpWidget(
      _frame(
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: RideSheet(
            more: [
              const LiveBar(
                title: 'Tunde is here',
                mood: 'here',
                trailing: '8:40 am',
                left: 'Free waiting · 4:18 left',
                right: 'Look for KJA 482 AB',
              ),
              const PersonCard(
                initials: 'TA',
                rating: '4.9',
                name: 'Tunde A.',
                sub: 'Top-rated driver',
                big: 'KJA 482 AB',
                bigSub: 'Silver Toyota Corolla',
                message: 'Any pickup notes?',
                call: 'Call',
              ),
              const ActionRows([(LucideIcons.share, 'Share trip'), (LucideIcons.x, 'Cancel ride')]),
            ],
            children: const [SizedBox()],
          ),
        ),
      ),
    );
    await t.tap(find.bySemanticsLabel('Show more'));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await t.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/rider_open.png'));
  });
}
