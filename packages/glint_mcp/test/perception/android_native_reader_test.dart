import 'dart:io';

import 'package:glint_mcp/perception.dart';
import 'package:test/test.dart';

const _picker = 'mCurrentFocus=Window{48b2dfd u0 com.google.android.providers.media.module/'
    'com.android.providers.media.photopicker.PhotoPickerGetContentActivity}';
const _app = 'mCurrentFocus=Window{e3e31c2 u0 com.example.signup_fixture/com.example.signup_fixture.MainActivity}';

AndroidNativeReader _reader(String dumpsys) => AndroidNativeReader(
      serial: 'emulator-5554',
      adbPath: 'adb',
      devicePixelRatio: () => 2.625,
      run: (_, args) async => ProcessResult(0, 0, args.contains('dumpsys') ? dumpsys : '', ''),
    );

void main() {
  test('reads the focused component', () {
    expect(parseFocusedComponent(_picker),
        'com.google.android.providers.media.module/com.android.providers.media.photopicker.PhotoPickerGetContentActivity');
    expect(parseFocusedComponent('mCurrentFocus=null'), isNull);
  });

  test('another package in front is a foreign surface; the app itself is not', () async {
    final picker = _reader(_picker)..appPackage = 'com.example.signup_fixture';
    expect(await picker.foreignSurface(), startsWith('com.google.android.providers.media.module/'));
    final app = _reader(_app)..appPackage = 'com.example.signup_fixture';
    expect(await app.foreignSurface(), isNull);
  });

  test('without a learned app package it never claims a foreign surface', () async {
    expect(await _reader(_picker).foreignSurface(), isNull);
  });

  test('a uiautomator dump becomes labelled nodes framed in logical points', () {
    const xml = '<?xml version="1.0"?><hierarchy rotation="0">'
        '<node index="0" text="" class="android.widget.FrameLayout" content-desc="" clickable="false" bounds="[0,0][1080,2400]">'
        '<node index="1" text="" class="android.widget.ImageButton" content-desc="Cancel" clickable="true" bounds="[0,339][147,486]" />'
        '<node index="2" text="Photos" class="android.widget.TextView" content-desc="" clickable="false" bounds="[345,387][461,438]" />'
        '<node index="3" text="" class="android.widget.ImageView" content-desc="Photo taken on Sep 27" clickable="true" bounds="[0,1900][354,2080]" />'
        '<node index="4" text="" class="android.widget.ImageView" content-desc="Photo taken on Sep 27" clickable="true" bounds="[363,1900][717,2080]" />'
        '</node></hierarchy>';
    final scene = sceneFromUiDump(xml, 2.625);
    final ids = scene.root.children.map((n) => n.glintId).toList();
    expect(ids, ['native_cancel', 'native_photos', 'native_photo_taken_on_sep_27', 'native_photo_taken_on_sep_27_2']);
    final cancel = scene.root.children.first;
    expect(cancel.isNativeEnabled, isTrue);
    expect(cancel.axFrame!.x, 0);
    expect(cancel.axFrame!.h, closeTo(147 / 2.625, 0.01));
    expect(NativeSceneReader.renderAsText(scene), contains('* native native_cancel Cancel @ 28,157'));
  });
}
