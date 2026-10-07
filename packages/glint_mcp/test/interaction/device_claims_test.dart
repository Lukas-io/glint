import 'dart:io';

import 'package:glint_mcp/interaction.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('glint-claims'));
  tearDown(() => dir.deleteSync(recursive: true));

  DeviceClaims as(int pid, {Set<int> alive = const {}}) =>
      DeviceClaims(dir: dir.path, ownPid: pid, isAlive: alive.contains);

  test('a device another live session claimed is held by it', () {
    as(100).claim('0C3A-UDID', app: 'Ember');
    final held = as(200, alive: {100}).heldByOther('0C3A-UDID');
    expect(held?.pid, 100);
    expect(held?.describe, contains('Ember'));
  });

  test('our own claim and a dead session\'s claim do not count', () {
    as(100).claim('emulator-5554');
    expect(as(100, alive: {100}).heldByOther('emulator-5554'), isNull);
    expect(as(200).heldByOther('emulator-5554'), isNull);
  });

  test('an unclaimed device is free', () {
    expect(as(200, alive: {100}).heldByOther('emulator-5556'), isNull);
  });
}
