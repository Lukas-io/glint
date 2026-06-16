import 'dart:math' show min;

import '../../perception.dart';
import '../runtime/flutter_runtime.dart';
import 'icon_names.dart';
import 'semantic_node.dart';
import 'semantic_scene.dart';
import 'semanticizer.dart';

/// Post-classify pass that fills role-specific properties (hint,
/// currentValue, icon name, route info, …) by talking to the live
/// runtime. Stays in Module C because it operates on [SemanticNode]s,
/// but takes a [FlutterRuntime] dependency since pure SceneNode parsing
/// can't surface this data.
abstract class SemanticEnricher {
  Future<void> enrich(SemanticScene scene);
}

/// Classifies overlay dialog content from [Scene.overlayRoots] (nodes from
/// the full tree appended during [SceneReader.readSummary]) and populates
/// [SemanticScene.overlayLayers].
class OverlayEnricher implements SemanticEnricher {
  OverlayEnricher({required this.semanticizer});

  final Semanticizer semanticizer;

  @override
  Future<void> enrich(SemanticScene scene) async {
    final roots = scene.sourceScene.overlayRoots;
    if (roots.isEmpty) return;

    final layers = <SemanticOverlayLayer>[];
    for (final root in roots) {
      final semantic = semanticizer.classifyNode(root);
      // Flatten pass-through Unknown roots: surface children directly.
      final nodes = (semantic is SemanticUnknown && semantic.children.isNotEmpty)
          ? semantic.children
          : [semantic];
      layers.add(SemanticOverlayLayer(
        nodes: nodes,
        isBarriered: scene.sourceScene.hasBarrierOverlay,
        kind: _inferKind(root),
      ));
    }
    scene.overlayLayers = layers;
  }

  static String _inferKind(SceneNode root) {
    for (final n in root.walk()) {
      final l = n.label;
      if (l.contains('BottomSheet') || l.contains('Sheet')) return 'bottomSheet';
      if (l.contains('Dialog') || l.contains('Alert')) return 'dialog';
    }
    return 'dialog';
  }
}

/// Reads the topmost ModalRoute's name + isFirst flag. Uses shallow probe
/// nodes (above ShellRoute inner navigators) to guarantee the outer GoRouter
/// path is returned rather than a nested route's null name.
class NavigationEnricher implements SemanticEnricher {
  NavigationEnricher({required this.runtime});

  final FlutterRuntime runtime;

  static const _routeExpr =
      '(ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.settings.name ?? "")'
      ' + "|" + (ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.isFirst.toString() ?? "true")'
      ' + "|" + (ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.runtimeType.toString() ?? "")';

  @override
  Future<void> enrich(SemanticScene scene) async {
    for (final source in scene.sourceScene.addressableCandidates()) {
      final result = await runtime.evaluateWithSelection(
        expression: _routeExpr,
        inspectorId: source.inspectorId,
        groupName: scene.sourceScene.groupName,
      );
      if (result == null) continue;
      final parts = result.split('|');
      if (parts.length < 3 || parts[0].isEmpty) continue;
      final isDialog = parts[2].contains('Dialog');
      scene.routeStack = [
        RouteFrame(name: parts[0], isModal: parts[1] == 'false' || isDialog),
      ];
      return;
    }
  }
}

/// Reads [IconData.codePoint] for each [SemanticIcon] and resolves the
/// codepoint to a Material icon name. Capped at [maxIcons] to bound
/// eval cost.
class IconEnricher implements SemanticEnricher {
  IconEnricher({required this.runtime, this.maxIcons = 20});

  final FlutterRuntime runtime;
  final int maxIcons;

  @override
  Future<void> enrich(SemanticScene scene) async {
    final icons = scene.root.walk().whereType<SemanticIcon>().toList();
    final budget = min(icons.length, maxIcons);
    for (var i = 0; i < budget; i++) {
      final node = icons[i];
      if (node.glintId == null) continue;
      final source = scene.sourceScene.findByGlintId(node.glintId!);
      if (source == null) continue;
      try {
        await _enrichOne(source, scene.sourceScene.groupName, node);
      } on Object {
        // best-effort
      }
    }
  }

  Future<void> _enrichOne(
      SceneNode source, String groupName, SemanticIcon target) async {
    final raw = await runtime.evaluateWithSelection(
      expression: '(WidgetInspectorService.instance.selection.currentElement!.widget'
          ' as Icon).icon?.codePoint ?? -1',
      inspectorId: source.inspectorId,
      groupName: groupName,
    );
    if (raw == null) return;
    final codePoint = int.tryParse(raw);
    if (codePoint == null || codePoint < 0) return;
    target.codePoint = codePoint;
    target.name = kKnownIconNames[codePoint];
  }
}

/// Reads `hint` (InputDecoration.labelText) and `currentValue` (live
/// EditableText controller text) for each [SemanticInput]. Capped at
/// [maxInputs] to bound eval cost.
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
    final budget = min(inputs.length, maxInputs);
    for (var i = 0; i < budget; i++) {
      final node = inputs[i];
      if (node.glintId == null) continue;
      final source = scene.sourceScene.findByGlintId(node.glintId!);
      if (source == null) continue;
      await _enrichOne(source, scene.sourceScene, node);
    }
  }

  Future<void> _enrichOne(
      SceneNode source, Scene scene, SemanticInput target) async {
    try {
      target.hint = await _readLabelText(source, scene.groupName);
    } on Object {
      // best-effort
    }
    try {
      target.currentValue = await _readCurrentValue(source, scene);
    } on Object {
      // best-effort
    }
  }

  Future<String?> _readLabelText(SceneNode source, String groupName) async {
    final v = await runtime.evaluateWithSelection(
      expression: '(WidgetInspectorService.instance.selection.currentElement!.widget'
          ' as TextField).decoration?.labelText ?? ""',
      inspectorId: source.inspectorId,
      groupName: groupName,
    );
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<String?> _readCurrentValue(SceneNode source, Scene scene) async {
    final subtree = await inspector.getDetailsSubtree(
      inspectorId: source.inspectorId,
      groupName: scene.groupName,
    );
    final editableId = _findEditableTextId(subtree);
    if (editableId == null) return null;

    final v = await runtime.evaluateWithSelection(
      expression: '(WidgetInspectorService.instance.selection.currentElement!.widget'
          ' as EditableText).controller.text',
      inspectorId: editableId,
      groupName: scene.groupName,
    );
    return (v == null || v.isEmpty) ? null : v;
  }

  String? _findEditableTextId(Map<String, Object?> node) {
    final label = (node['description'] as String?) ?? '';
    final type = (node['widgetRuntimeType'] as String?) ?? '';
    if (label == 'EditableText' || type == 'EditableText') {
      final id = node['valueId'] as String?;
      if (id != null && id.isNotEmpty) return id;
    }
    final kids = node['children'];
    if (kids is List) {
      for (final c in kids) {
        if (c is Map) {
          final found = _findEditableTextId(c.cast<String, Object?>());
          if (found != null) return found;
        }
      }
    }
    return null;
  }
}
