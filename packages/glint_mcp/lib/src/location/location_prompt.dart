import '../perception/scene_node.dart';

/// One button of a native prompt, centered in logical points.
typedef PromptButton = ({String label, double x, double y});

/// The answers `location op:answer` gives, with the labels iOS and Android put on them.
final locationAnswers = <String, RegExp>{
  'whileUsing': RegExp(r'^(Allow While Using App|While using the app)$', caseSensitive: false),
  'once': RegExp(r'^(Allow Once|Only this time)$', caseSensitive: false),
  'deny': RegExp(r'^Don.t allow$', caseSensitive: false),
  'always': RegExp(r'^(Change to Always Allow|Allow all the time)$', caseSensitive: false),
  'keepWhileUsing': RegExp(r'^(Keep Only While Using|Keep while app is in use)$', caseSensitive: false),
};

/// Android's accuracy choice on its location prompt.
final _precision = <bool, RegExp>{
  true: RegExp(r'^Precise$', caseSensitive: false),
  false: RegExp(r'^Approximate$', caseSensitive: false),
};

/// A system location prompt read from native nodes: its question and the answers it offers.
class LocationPrompt {
  LocationPrompt(this.title, this.answers, this.precision);

  final String title;
  final Map<String, PromptButton> answers;

  /// Android's Precise and Approximate choices, keyed true and false; empty where the prompt has none.
  final Map<bool, PromptButton> precision;

  /// The location prompt among [nodes], or null when the surface asks something else.
  static LocationPrompt? find(Iterable<SceneNode> nodes) {
    PromptButton? at(SceneNode n) {
      final f = n.axFrame;
      final label = n.textPreview;
      if (f == null || label == null) return null;
      return (label: label, x: f.x + f.w / 2, y: f.y + f.h / 2);
    }

    final list = nodes.toList();
    final title = list.map((n) => n.textPreview ?? '').firstWhere((t) => RegExp('location', caseSensitive: false).hasMatch(t), orElse: () => '');
    final answers = <String, PromptButton>{};
    final precision = <bool, PromptButton>{};
    for (final n in list) {
      final label = (n.textPreview ?? '').trim();
      final button = at(n);
      if (button == null || n.isNativeEnabled == false) continue;
      for (final e in locationAnswers.entries) {
        if (e.value.hasMatch(label)) answers.putIfAbsent(e.key, () => button);
      }
      for (final e in _precision.entries) {
        if (e.value.hasMatch(label)) precision.putIfAbsent(e.key, () => button);
      }
    }
    if (title.isEmpty || answers.isEmpty) return null;
    return LocationPrompt(title, answers, precision);
  }
}
