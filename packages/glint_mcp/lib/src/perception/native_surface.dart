import 'picker_cells.dart';
import 'scene_node.dart';
import 'scene_reader.dart';

/// What kind of native surface covers the app.
enum SurfaceKind { permissionPrompt, alert, picker, otherApp, unknown }

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
      SurfaceKind.picker => 'photo picker',
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

  /// The choice that grants or confirms, by its label; null when none is clearly affirmative, so a prompt is never steered to a deny.
  SurfaceChoice? get affirmative {
    for (final label in _affirmativeOrder) {
      for (final c in choices) {
        if (c.text.toLowerCase() == label) return c;
      }
    }
    return null;
  }

  /// The next step that answers this surface by text, naming every choice; null when it offers none.
  String? get answerStep {
    if (choices.isEmpty) return null;
    final all = choices.map((c) => c.text).join(' | ');
    final yes = affirmative;
    return yes == null
        ? 'answer it by tapping one of its choices by text (choices: $all)'
        : 'answer it by text, e.g. tap text:"${yes.text}" (choices: $all)';
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

/// Labels that grant or confirm, best first.
const _affirmativeOrder = [
  'allow while using app',
  'allow',
  'allow full access',
  'ok',
  'continue',
  'open',
  'allow once',
  'yes'
];

/// A reply summary with the surface's line on its own row, or unchanged when there is none.
extension SurfaceReplyLine on NativeSurface? {
  String get replyLine => this == null ? '' : '\n${this!.line}';
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

/// Labels of the button that commits a multi-select pick.
const pickerConfirmLabels = {'add', 'done', 'select', 'choose', 'open'};

const _minPickerCells = 3;

final _pickerProcess =
    RegExp(r'photopicker|providers\.media|documentsui|mobileslideshow|photosui', caseSensitive: false);
final _androidComponent = RegExp(r'^[\w.]+/');

/// A picker needs several photo cells, or (on Android, where [owner] is `package/window`) a known picker package showing any.
bool _showsPicker(List<PickerCell> cells, String? owner) {
  if (owner != null && _androidComponent.hasMatch(owner)) return cells.isNotEmpty && _pickerProcess.hasMatch(owner);
  return cells.length >= _minPickerCells;
}

final _permissionQuestion = RegExp(
  r'(would like to|wants to|to find devices|access (your|to)|send you notifications|use your location|'
  r'track your activity|allow [“"]|allow .+ to (access|use|send|record|take|find))',
  caseSensitive: false,
);

bool _isChoice(SceneNode n, bool isPicker) {
  final label = n.textPreview!.trim().toLowerCase();
  if (_choiceLabels.contains(label)) return true;
  return isPicker && n.isNativeEnabled == true && pickerConfirmLabels.contains(label);
}

/// Classifies [scene] (a native reader's snapshot) with its foreign [owner] window, when the platform names one.
NativeSurface classifySurface(Scene scene, {String? owner}) {
  final nodes = [
    for (final n in _walk(scene.root))
      if (n.axFrame != null && (n.textPreview?.trim().isNotEmpty ?? false)) n,
  ];
  final photoCells = pickerCells(nodes);
  final isPicker = _showsPicker(photoCells, owner);
  final cellLabels = {for (final c in photoCells) c.label};
  final choices = <SurfaceChoice>[
    for (final n in nodes)
      if (_isChoice(n, isPicker))
        (
          text: n.textPreview!.trim(),
          id: n.glintId ?? '',
          x: n.axFrame!.x + n.axFrame!.w / 2,
          y: n.axFrame!.y + n.axFrame!.h / 2,
        ),
  ];
  final texts = [
    for (final n in nodes)
      if (!choices.any((c) => c.id == n.glintId) && !(isPicker && cellLabels.contains(n.textPreview)))
        n.textPreview!.trim(),
  ];
  final question = texts.where(_permissionQuestion.hasMatch).firstOrNull;
  final permissionOwner =
      owner != null && RegExp('permissioncontroller|GrantPermissions', caseSensitive: false).hasMatch(owner);
  final kind = question != null || permissionOwner
      ? SurfaceKind.permissionPrompt
      : isPicker
          ? SurfaceKind.picker
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
