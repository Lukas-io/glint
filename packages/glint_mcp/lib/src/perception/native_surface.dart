import 'scene_node.dart';
import 'scene_reader.dart';

/// What kind of native surface covers the app.
enum SurfaceKind { permissionPrompt, alert, otherApp, unknown }

/// One tappable choice on a native surface, at its center in logical points.
typedef SurfaceChoice = ({String text, String id, double x, double y});

/// A native surface read as data: its kind, its question, the choices it offers, and the other text on it.
class NativeSurface {
  const NativeSurface({required this.kind, this.title, this.choices = const [], this.texts = const [], this.owner});

  final SurfaceKind kind;
  final String? title;
  final List<SurfaceChoice> choices;
  final List<String> texts;

  /// The window or app in front, when the platform names it.
  final String? owner;

  static const _maxTexts = 8;

  /// The surface [toJson] wrote, for rendering a reply's text.
  factory NativeSurface.fromJson(Map<String, Object?> json) => NativeSurface(
        kind: SurfaceKind.values.where((k) => k.name == json['kind']).firstOrNull ?? SurfaceKind.unknown,
        title: json['title'] as String?,
        choices: [
          for (final c in (json['choices'] as List? ?? const []).cast<Map<String, Object?>>())
            (text: '${c['text']}', id: '${c['id']}', x: 0, y: 0),
        ],
        texts: [for (final t in json['texts'] as List? ?? const []) '$t'],
        owner: json['owner'] as String?,
      );

  /// Whether it says anything beyond its kind, so a screenshot adds nothing.
  bool get hasContent => title != null || choices.isNotEmpty || texts.isNotEmpty;

  /// One line for a reply: kind, question, choices with their ids, or the text it shows.
  String get line {
    final name = switch (kind) {
      SurfaceKind.permissionPrompt => 'permission prompt',
      SurfaceKind.alert => 'alert',
      SurfaceKind.otherApp => 'another app${owner == null ? '' : ' ($owner)'}',
      SurfaceKind.unknown => 'native surface',
    };
    final parts = [
      if (title != null) '"$title"',
      if (choices.isNotEmpty) 'choices: ${choices.map((c) => '${c.text} (${c.id})').join(', ')}',
      if (choices.isEmpty && texts.isNotEmpty) 'reads: ${texts.take(_maxTexts).map((t) => '"$t"').join(', ')}',
    ];
    return 'surface: $name${parts.isEmpty ? '' : ' · ${parts.join(' · ')}'}';
  }

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        if (title != null) 'title': title,
        if (choices.isNotEmpty)
          'choices': [
            for (final c in choices) {'text': c.text, 'id': c.id}
          ],
        if (texts.isNotEmpty) 'texts': texts.take(_maxTexts).toList(),
        if (owner != null) 'owner': owner,
      };
}

/// Words that label a choice on iOS and Android system dialogs.
const _choiceLabels = {
  'allow',
  "don't allow",
  'don’t allow',
  'allow once',
  'allow while using app',
  'allow full access',
  'limit access…',
  'limit access...',
  'select photos…',
  'select photos...',
  'keep current selection',
  'ok',
  'cancel',
  'not now',
  'settings',
  'close',
  'continue',
  'ask app not to track',
  'allow paste',
  "don't allow paste",
  'don’t allow paste',
  'open',
  'delete',
  'done',
  'deny',
  'only this time',
  'while using the app',
  'allow all',
  'no thanks',
  'later',
  'got it',
  'dismiss',
};

final _permissionQuestion = RegExp(
  r'(would like to|wants to|to find devices|access (your|to)|send you notifications|use your location|'
  r'track your activity|allow [“"]|allow .+ to (access|use|send|record|take|find))',
  caseSensitive: false,
);

/// Classifies [scene] (a native reader's snapshot) with its foreign [owner] window, when the platform names one.
NativeSurface classifySurface(Scene scene, {String? owner}) {
  final nodes = [
    for (final n in _walk(scene.root))
      if (n.axFrame != null && (n.textPreview?.trim().isNotEmpty ?? false)) n,
  ];
  final choices = <SurfaceChoice>[
    for (final n in nodes)
      if (_choiceLabels.contains(n.textPreview!.trim().toLowerCase()))
        (
          text: n.textPreview!.trim(),
          id: n.glintId ?? '',
          x: n.axFrame!.x + n.axFrame!.w / 2,
          y: n.axFrame!.y + n.axFrame!.h / 2,
        ),
  ];
  final texts = [
    for (final n in nodes)
      if (!choices.any((c) => c.id == n.glintId)) n.textPreview!.trim(),
  ];
  final question = texts.where(_permissionQuestion.hasMatch).firstOrNull;
  final permissionOwner =
      owner != null && RegExp('permissioncontroller|GrantPermissions', caseSensitive: false).hasMatch(owner);
  final kind = question != null || permissionOwner
      ? SurfaceKind.permissionPrompt
      : choices.isNotEmpty
          ? SurfaceKind.alert
          : owner != null
              ? SurfaceKind.otherApp
              : SurfaceKind.unknown;
  final title = question ?? texts.where((t) => t.endsWith('?') || t.length > 24).firstOrNull;
  return NativeSurface(
      kind: kind, title: title, choices: choices, texts: texts.where((t) => t != title).toList(), owner: owner);
}

Iterable<SceneNode> _walk(SceneNode n) sync* {
  yield n;
  for (final c in n.children) {
    yield* _walk(c);
  }
}
