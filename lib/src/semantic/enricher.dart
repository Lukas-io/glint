import '../../perception.dart';
import '../runtime/flutter_runtime.dart';
import 'icon_names.dart';
import 'semantic_node.dart';
import 'semantic_scene.dart';

/// Post-classify pass that fills role-specific properties (hint,
/// currentValue, icon name, route info, …) by talking to the live
/// runtime. Stays in Module C because it operates on [SemanticNode]s,
/// but takes a [FlutterRuntime] dependency since pure SceneNode parsing
/// can't surface this data.
abstract class SemanticEnricher {
  Future<void> enrich(SemanticScene scene);
}

/// Topmost ModalRoute's settings.name + whether it's first/dialog.
/// Full stack walking deferred; this covers "did a dialog or page push
/// happen" cases.
class NavigationEnricher implements SemanticEnricher {
  NavigationEnricher({required this.runtime});

  final FlutterRuntime runtime;

  @override
  Future<void> enrich(SemanticScene scene) async {
    final probeId = scene.sourceScene.firstAddressableId();
    if (probeId == null) return;
    final source = scene.sourceScene.findByGlintId(probeId);
    if (source == null) return;

    try {
      await runtime.setInspectorSelection(
        inspectorId: source.inspectorId,
        groupName: scene.sourceScene.groupName,
      );
      final result = await runtime.evaluateString(
        '((ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.settings.name ?? "")'
            ' + "|" + (ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.isFirst.toString() ?? "true")'
            ' + "|" + (ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.runtimeType.toString() ?? ""))',
      );
      if (result == null) return;
      final parts = result.split('|');
      if (parts.length < 3) return;
      final name = parts[0].isEmpty ? '/' : parts[0];
      final isFirst = parts[1] != 'false';
      final rtType = parts[2];
      final isDialog = rtType.contains('Dialog');

      scene.routeStack = [
        RouteFrame(name: name, isModal: !isFirst || isDialog),
      ];
    } on Object {
      // best-effort
    }
  }
}

/// IconData codepoint per [SemanticIcon]; populates [SemanticIcon.name]
/// when the codepoint matches a known Material icon. Capped at [maxIcons].
class IconEnricher implements SemanticEnricher {
  IconEnricher({required this.runtime, this.maxIcons = 20});

  final FlutterRuntime runtime;
  final int maxIcons;

  @override
  Future<void> enrich(SemanticScene scene) async {
    final icons = scene.root.walk().whereType<SemanticIcon>().toList();
    final budget = icons.length > maxIcons ? maxIcons : icons.length;
    for (var i = 0; i < budget; i++) {
      final node = icons[i];
      final glintId = node.glintId;
      if (glintId == null) continue;
      final source = scene.sourceScene.findByGlintId(glintId);
      if (source == null) continue;
      try {
        await _enrichOne(scene.sourceScene, source, node);
      } on Object {
        // best-effort
      }
    }
  }

  Future<void> _enrichOne(
      Scene scene, SceneNode source, SemanticIcon target) async {
    await runtime.setInspectorSelection(
      inspectorId: source.inspectorId,
      groupName: scene.groupName,
    );
    final raw = await runtime.evaluateString(
      '(WidgetInspectorService.instance.selection.currentElement!.widget '
          'as Icon).icon?.codePoint ?? -1',
    );
    if (raw == null) return;
    final codePoint = int.tryParse(raw);
    if (codePoint == null || codePoint < 0) return;
    target.codePoint = codePoint;
    target.name = kKnownIconNames[codePoint];
  }
}

/// `hint` (InputDecoration.labelText) + `currentValue` (live EditableText
/// controller text) per [SemanticInput]. Bounded — each input costs
/// ~2 VM evals.
class InputEnricher implements SemanticEnricher {
  InputEnricher({
    required this.runtime,
    required this.inspector,
    this.maxInputs = 10,
  });

  final FlutterRuntime runtime;
  final InspectorClient inspector;
  final int maxInputs;

  @override
  Future<void> enrich(SemanticScene scene) async {
    final inputs = scene.root.walk().whereType<SemanticInput>().toList();
    final budget = inputs.length > maxInputs ? maxInputs : inputs.length;
    for (var i = 0; i < budget; i++) {
      final node = inputs[i];
      final glintId = node.glintId;
      if (glintId == null) continue;
      final source = scene.sourceScene.findByGlintId(glintId);
      if (source == null) continue;
      await _enrichOne(scene.sourceScene, source, node);
    }
  }

  Future<void> _enrichOne(
      Scene scene, SceneNode source, SemanticInput target) async {
    try {
      target.hint = await _readLabelText(scene, source);
    } on Object {
      // best-effort; never bubble
    }
    try {
      target.currentValue = await _readCurrentValue(scene, source);
    } on Object {
      // best-effort; never bubble
    }
  }

  Future<String?> _readLabelText(Scene scene, SceneNode source) async {
    await runtime.setInspectorSelection(
      inspectorId: source.inspectorId,
      groupName: scene.groupName,
    );
    final v = await runtime.evaluateString(
      '(WidgetInspectorService.instance.selection.currentElement!.widget '
          'as TextField).decoration?.labelText ?? ""',
    );
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<String?> _readCurrentValue(Scene scene, SceneNode source) async {
    final subtree = await inspector.getDetailsSubtree(
      inspectorId: source.inspectorId,
      groupName: scene.groupName,
    );
    final editableId = _findEditableTextValueId(subtree);
    if (editableId == null) return null;

    await runtime.setInspectorSelection(
      inspectorId: editableId,
      groupName: scene.groupName,
    );
    final v = await runtime.evaluateString(
      '(WidgetInspectorService.instance.selection.currentElement!.widget '
          'as EditableText).controller.text',
    );
    return (v == null || v.isEmpty) ? null : v;
  }

  String? _findEditableTextValueId(Map<String, Object?> node) {
    if ((node['description'] as String?) == 'EditableText' ||
        (node['widgetRuntimeType'] as String?) == 'EditableText') {
      final id = node['valueId'] as String?;
      if (id != null && id.isNotEmpty) return id;
    }
    final kids = node['children'];
    if (kids is List) {
      for (final c in kids) {
        if (c is Map) {
          final found = _findEditableTextValueId(c.cast<String, Object?>());
          if (found != null) return found;
        }
      }
    }
    return null;
  }
}
