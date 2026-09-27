import 'package:glint_mcp/interaction.dart';
import 'package:glint_mcp/perception.dart';
import 'package:test/test.dart';

Map<String, Object?> _window(String type, bool focused, List<Map<String, Object?>> kids) => {
      'type': type,
      'focused': focused,
      'root': {'class': 'android.widget.FrameLayout', 'bounds': [0, 0, 1080, 2400], 'children': kids},
    };

void main() {
  test('the focused window is read, labelled and tappable nodes only, in logical points', () {
    final reply = {
      'ok': true,
      'windows': [
        _window('application', false, [
          {'class': 'android.view.View', 'text': 'Ember', 'bounds': [0, 0, 100, 100]},
        ]),
        _window('system', true, [
          {'class': 'android.widget.TextView', 'text': "Ember isn't responding", 'bounds': [90, 1100, 990, 1200]},
          {'class': 'android.widget.Button', 'text': 'Close app', 'clickable': true, 'bounds': [90, 1260, 990, 1360]},
          {'class': 'android.view.View', 'bounds': [0, 0, 10, 10]},
        ]),
      ],
    };
    final scene = sceneFromServerWindows(reply, 2.625);
    final nodes = scene.root.children;
    expect(nodes.map((n) => n.glintId), ['native_ember_isn_t_responding', 'native_close_app']);
    expect(nodes.last.isNativeEnabled, isTrue);
    expect(nodes.last.axFrame!.y, closeTo(1260 / 2.625, 0.01));
  });

  test('with no focused window the application window is read', () {
    final reply = {
      'windows': [
        _window('inputMethod', false, [
          {'class': 'android.view.View', 'text': 'q', 'bounds': [0, 2000, 100, 2100]},
        ]),
        _window('application', false, [
          {'class': 'android.view.View', 'desc': 'Photo 1', 'clickable': true, 'bounds': [0, 0, 300, 300]},
        ]),
      ],
    };
    expect(sceneFromServerWindows(reply, 1).root.children.single.glintId, 'native_photo_1');
  });

  test('modifiers map to Android meta state with their left-hand flags', () {
    expect(androidMetaState(const {KeyModifier.ctrl}), 0x3000);
    expect(androidMetaState(const {KeyModifier.shift, KeyModifier.alt}), 0x41 | 0x12);
    expect(androidMetaState(const {}), 0);
  });
}
