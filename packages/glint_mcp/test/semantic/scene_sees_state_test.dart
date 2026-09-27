import 'package:glint_mcp/perception.dart';
import 'package:glint_mcp/semantic.dart';
import 'package:glint_mcp/src/runtime/flutter_runtime.dart';
import 'package:test/test.dart';

/// Answers one batched eval with a fixed reply and records the expression.
class _Runtime implements FlutterRuntime {
  _Runtime(this.reply);
  final String reply;
  final expressions = <String>[];

  @override
  Future<String?> evaluateString(String expression,
      {bool rethrowErrors = false}) async {
    expressions.add(expression);
    return reply;
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

SceneNode _n(String label,
        {String? glintId, String? text, List<SceneNode> children = const []}) =>
    SceneNode(
      depth: 1,
      indexInParent: 0,
      description: label,
      type: '_Element',
      inspectorId: 'i-${glintId ?? label}',
      widgetRuntimeType: label,
      glintId: glintId,
      textPreview: text,
      createdByLocalProject: true,
      children: children,
    );

SemanticScene _semantic(SceneNode root) {
  StableIdGenerator().assignIds(root);
  return Semanticizer().semanticize(Scene.forTesting(root: root));
}

void main() {
  group('SemanticsFlagEnricher', () {
    test('marks the selected pill and reads checked into toggleState, in one eval', () async {
      final scene = _semantic(_n('Scaffold', children: [
        _n('Column', children: [
          _n('GestureDetector', children: [_n('Text', text: 'Woman')]),
          _n('GestureDetector', children: [_n('Text', text: 'Man')]),
          _n('GestureDetector', children: [_n('Text', text: 'Terms')]),
        ]),
      ]));
      final rt = _Runtime('false,;true,;,true');
      await SemanticsFlagEnricher(runtime: rt).enrich(scene);
      final buttons = scene.root.walk().whereType<SemanticButton>().toList();
      expect(buttons.map((b) => b.selected), [false, true, null]);
      expect(buttons[2].toggleState, 'on');
      expect(buttons[1].displayLabel, contains('[selected]'));
      expect(rt.expressions, hasLength(1), reason: 'every button in one eval');
      expect(rt.expressions.single, contains('toObject'));
    });

    test('a reply that does not line up with the buttons changes nothing', () async {
      final scene = _semantic(_n('Scaffold', children: [
        _n('GestureDetector', children: [_n('Text', text: 'Man')]),
      ]));
      await SemanticsFlagEnricher(runtime: _Runtime('true,;true,')).enrich(scene);
      expect(scene.root.walk().whereType<SemanticButton>().single.selected, isNull);
    });
  });

  group('ImageEnricher', () {
    test('names the file behind a CircleAvatar and an Image, with load state', () async {
      final scene = _semantic(_n('Scaffold', children: [
        _n('Column', children: [
          _n('CircleAvatar'),
          _n('Image'),
        ]),
      ]));
      await ImageEnricher(runtime: _Runtime(
              'FileImage("/tmp/picks/profile.jpg", scale: 1.0)|;'
              'NetworkImage("https://cdn.example.com/a/b/cover.png", scale: 1.0)|true'))
          .enrich(scene);
      final images = scene.root.walk().whereType<SemanticImage>().toList();
      expect(images.map((i) => i.source), ['profile.jpg', 'cdn.example.com/…/cover.png']);
      expect(images.map((i) => i.state), [null, 'loaded']);
      expect(images[1].displayLabel, 'cdn.example.com/…/cover.png (loaded)');
    });
  });

  group('imageSourceName', () {
    test('asset, memory and long picker names', () {
      expect(imageSourceName('AssetImage(bundle: null, name: "assets/logo.png")'), 'logo.png');
      expect(imageSourceName('MemoryImage(Uint8List#1a2b3, scale: 1.0)'), 'MemoryImage');
      expect(
          imageSourceName('FileImage("/x/image_picker_9ABC7ED8-0EF5-48B0-886F-EE12345678.jpg", scale: 1.0)'),
          'image_picker_…345678.jpg');
      expect(imageSourceName(''), isNull);
    });
  });

  group('ids under lazy lists follow the item', () {
    test('a wheel item keeps its id when the built window shifts', () {
      SceneNode wheel(List<String> years) => _n('Scaffold', children: [
            _n('ListWheelScrollView', children: [
              for (final y in years) _n('GestureDetector', children: [_n('Text', text: y)]),
            ]),
          ]);
      String idOf(SceneNode root, String year) => root
          .walk()
          .firstWhere((n) =>
              n.baseLabel == 'GestureDetector' &&
              n.walk().any((d) => d.textPreview == year))
          .glintId!;
      final before = wheel(['1998', '1999', '2000', '2001']);
      final after = wheel(['1996', '1997', '1998', '1999']);
      StableIdGenerator().assignIds(before);
      StableIdGenerator().assignIds(after);
      expect(idOf(after, '1998'), idOf(before, '1998'));
      expect(idOf(after, '1996'), isNot(idOf(before, '1998')));
    });
  });

  group('fold digest', () {
    test('a folded row keeps its label and its value', () {
      final row = SemanticContainer(hint: 'row', children: [
        SemanticText(content: 'Distance'),
        SemanticText(content: 'Up to 50 mi'),
        SemanticButton(label: 'Edit'),
      ]);
      expect(foldItemLabel(row), 'Distance · Up to 50 mi · Edit');
    });
  });
}
