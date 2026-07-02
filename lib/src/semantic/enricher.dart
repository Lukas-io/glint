import 'dart:math' show min;

import '../../perception.dart';
import '../runtime/flutter_runtime.dart';
import 'icon_names.dart';
import 'semantic_node.dart';
import 'semantic_scene.dart';
import 'semanticizer.dart';

/// Post-classify pass that fills role-specific properties (hint, currentValue,
/// icon name, route info, …) by talking to the live runtime — data pure
/// SceneNode parsing can't surface.
abstract class SemanticEnricher {
  Future<void> enrich(SemanticScene scene);
}

/// Classifies overlay dialog content from [Scene.overlayRoots] into
/// [SemanticScene.overlayLayers]. Must run before the renderer.
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
      // Skip entirely-unknown layers (e.g. MouseRegion / Focus plumbing
      // overlays in debug mode) — no content, just `--- dialog ---` noise.
      if (!_hasContent(nodes)) continue;
      layers.add(SemanticOverlayLayer(
        nodes: nodes,
        isBarriered: scene.sourceScene.hasBarrierOverlay,
        kind: _inferKind(root),
      ));
    }
    scene.overlayLayers = layers;
  }

  static bool _hasContent(List<SemanticNode> nodes) {
    for (final n in nodes) {
      if (n is! SemanticUnknown) return true;
      if (_hasContent(n.children)) return true;
    }
    return false;
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

/// Reads the topmost ModalRoute's name + isFirst flag. Uses shallow probe nodes
/// (above ShellRoute inner navigators) so the outer GoRouter path is returned,
/// not a nested route's null name.
class NavigationEnricher implements SemanticEnricher {
  NavigationEnricher({required this.runtime});

  final FlutterRuntime runtime;

  static const _routeExpr =
      '(ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.settings.name ?? "")'
      ' + "|" + (ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.isFirst.toString() ?? "true")'
      ' + "|" + (ModalRoute.of(WidgetInspectorService.instance.selection.currentElement!)?.runtimeType.toString() ?? "")';

  @override
  Future<void> enrich(SemanticScene scene) async {
    // Probe only within the ACTIVE page — a covered sibling route would
    // answer with its own (wrong) name. No name beats a wrong name.
    final pageId = scene.root.glintId;
    final pageSource = pageId != null ? scene.sourceFor(pageId) : null;
    for (final source
        in scene.sourceScene.addressableCandidates(within: pageSource)) {
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

/// Reads [IconData.codePoint] for each [SemanticIcon] and resolves it to a
/// Material icon name. Capped at [maxIcons] to bound eval cost.
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
      final source = scene.sourceFor(node.glintId!);
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

/// Reads the live `value` of Checkbox / Switch-shaped toggles into
/// [SemanticButton.toggleState] ('on'/'off'). Radio is excluded — its `value`
/// is the option, not the checked state. Capped at [maxToggles].
class ToggleEnricher implements SemanticEnricher {
  ToggleEnricher({required this.runtime, this.maxToggles = 10});

  final FlutterRuntime runtime;
  final int maxToggles;

  static const _valueToggles = {
    'Checkbox',
    'Switch',
    'CupertinoSwitch',
    'CupertinoCheckbox',
    'CheckboxListTile',
    'SwitchListTile',
  };

  @override
  Future<void> enrich(SemanticScene scene) async {
    final toggles = scene.root
        .walk()
        .whereType<SemanticButton>()
        .where((b) => b.isToggle)
        .toList();
    final budget = min(toggles.length, maxToggles);
    for (var i = 0; i < budget; i++) {
      final node = toggles[i];
      if (node.glintId == null) continue;
      final source = scene.sourceFor(node.glintId!);
      if (source == null) continue;
      if (!_valueToggles.contains(source.baseLabel)) continue;
      try {
        final raw = await runtime.evaluateWithSelection(
          expression:
              '((WidgetInspectorService.instance.selection.currentElement!.widget'
              ' as dynamic).value).toString()',
          inspectorId: source.inspectorId,
          groupName: scene.sourceScene.groupName,
        );
        node.toggleState = switch (raw) {
          'true' => 'on',
          'false' => 'off',
          _ => null,
        };
      } on Object {
        // best-effort
      }
    }
  }
}

/// Reads `hint` (InputDecoration.labelText) and `currentValue` (live
/// EditableText controller text) for each [SemanticInput]. Capped at [maxInputs].
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
      final source = scene.sourceFor(node.glintId!);
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
