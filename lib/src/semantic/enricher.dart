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
      // Transient messages ride in an OverlayEntry too — flag them as such so
      // the agent reads the message but doesn't treat it as a blocking modal.
      if (l.contains('SnackBar')) return 'snackbar';
      if (l.contains('Toast')) return 'toast';
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

/// Marks a [SemanticText] tappable when its RichText carries a
/// [GestureRecognizer] on a span — inline links ("Sign in", Terms & Conditions,
/// "Resend") that render as plain text but navigate on tap. Without this they
/// show as static `-` and an agent can't discover them. Capped at [maxTexts]
/// (one eval each); runs at full detail only.
class LinkEnricher implements SemanticEnricher {
  LinkEnricher({required this.runtime, this.maxTexts = 30});

  final FlutterRuntime runtime;
  final int maxTexts;

  // Single-line (the CFE eval rejects newlines, not block bodies): true when
  // any span in the RichText's InlineSpan tree has a recognizer.
  static const _hasRecognizerExpr =
      '((r) { if (r is! RichText) return false; var f = false; '
      'r.text.visitChildren((s) { if (s is TextSpan && s.recognizer != null) f = true; return true; }); '
      'return f; })'
      '(WidgetInspectorService.instance.selection.currentElement!.widget).toString()';

  @override
  Future<void> enrich(SemanticScene scene) async {
    final texts = scene.root
        .walk()
        .whereType<SemanticText>()
        .where((t) => t.glintId != null && t.affordances.isEmpty)
        .toList();
    final budget = min(texts.length, maxTexts);
    for (var i = 0; i < budget; i++) {
      final node = texts[i];
      final source = scene.sourceFor(node.glintId!);
      if (source == null) continue;
      try {
        final r = await runtime.evaluateWithSelection(
          expression: _hasRecognizerExpr,
          inspectorId: source.inspectorId,
          groupName: scene.sourceScene.groupName,
        );
        if (r == 'true') node.affordances.add(Affordance.tappable);
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

  // Arrow-only (the CFE eval rejects statement-block lambdas): read a
  // TextField's labelText, falling back to hintText (placeholder).
  static const _labelExpr =
      '((w) => w is TextField ? (w.decoration?.labelText ?? '
      'w.decoration?.hintText ?? "") : "")'
      '(WidgetInspectorService.instance.selection.currentElement!.widget)';

  // Current validation error. TextFormField copies the FormField's errorText
  // into the inner TextField's decoration, so reading it here surfaces live
  // validation feedback (why a submit was rejected).
  static const _errorExpr =
      '((w) => w is TextField ? (w.decoration?.errorText ?? "") : "")'
      '(WidgetInspectorService.instance.selection.currentElement!.widget)';

  Future<void> _enrichOne(
      SceneNode source, Scene scene, SemanticInput target) async {
    // One subtree read serves both label and value lookups.
    Map<String, Object?>? subtree;
    try {
      subtree = await inspector.getDetailsSubtree(
        inspectorId: source.inspectorId,
        groupName: scene.groupName,
      );
    } on Object {
      // best-effort — fall back to the source node below
    }
    // The inner TextField carries decoration (label + errorText); resolve it
    // once and reuse for both reads.
    final fieldId = subtree == null
        ? source.inspectorId
        : (_findWidgetId(subtree, const {'TextField', 'CupertinoTextField'}) ??
            source.inspectorId);
    try {
      target.hint = await _readDecoration(scene, fieldId, _labelExpr);
    } on Object {
      // best-effort
    }
    try {
      target.error = await _readDecoration(scene, fieldId, _errorExpr);
    } on Object {
      // best-effort
    }
    try {
      target.currentValue = await _readCurrentValue(scene, subtree);
    } on Object {
      // best-effort
    }
  }

  /// Evaluates a decoration [expr] against the inner [fieldId] TextField. A
  /// [TextFormField] builds an inner TextField, so [fieldId] is resolved from
  /// the subtree rather than the source (which would be the FormField).
  Future<String?> _readDecoration(
      Scene scene, String fieldId, String expr) async {
    final v = await runtime.evaluateWithSelection(
      expression: expr,
      inspectorId: fieldId,
      groupName: scene.groupName,
    );
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<String?> _readCurrentValue(
      Scene scene, Map<String, Object?>? subtree) async {
    if (subtree == null) return null;
    final editableId = _findWidgetId(subtree, const {'EditableText'});
    if (editableId == null) return null;

    final v = await runtime.evaluateWithSelection(
      expression: '(WidgetInspectorService.instance.selection.currentElement!.widget'
          ' as EditableText).controller.text',
      inspectorId: editableId,
      groupName: scene.groupName,
    );
    return (v == null || v.isEmpty) ? null : v;
  }

  /// First subtree node whose widget type is in [types], returning its valueId.
  String? _findWidgetId(Map<String, Object?> node, Set<String> types) {
    final label = (node['description'] as String?) ?? '';
    final type = (node['widgetRuntimeType'] as String?) ?? '';
    if (types.contains(label) || types.contains(type)) {
      final id = node['valueId'] as String?;
      if (id != null && id.isNotEmpty) return id;
    }
    final kids = node['children'];
    if (kids is List) {
      for (final c in kids) {
        if (c is Map) {
          final found = _findWidgetId(c.cast<String, Object?>(), types);
          if (found != null) return found;
        }
      }
    }
    return null;
  }
}
