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

/// Source labels whose children are pages laid side by side: every page stays in the tree, so which one is on screen is a geometry fact.
const Set<String> kPagedLabels = {'PageView', 'TabBarView'};

/// Marks each page under a PageView / TabBarView with [SemanticPage.onViewport], one geometry read per page, capped at [maxPages].
class PagedViewportEnricher implements SemanticEnricher {
  PagedViewportEnricher({required this.resolver, this.maxPages = 8});

  final CoordinateResolver resolver;
  final int maxPages;

  @override
  Future<void> enrich(SemanticScene scene) async {
    var budget = maxPages;
    for (final list in scene.allNodes().whereType<SemanticList>()) {
      final id = list.glintId;
      if (id == null) continue;
      final label = scene.sourceFor(id)?.baseLabel;
      if (label == null || !kPagedLabels.contains(label)) continue;
      for (final page in list.children.whereType<SemanticPage>()) {
        final pageId = page.glintId;
        if (pageId == null || budget-- <= 0) continue;
        try {
          final c = await resolver.resolve(scene.sourceScene, pageId);
          page.onViewport = c.centerOnViewport;
        } on Object {
          continue;
        }
      }
    }
  }
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
      final semantic = semanticizer.classifyNode(root, imageCandidates: true);
      // Flatten pass-through Unknown roots: surface children directly.
      final nodes = (semantic is SemanticUnknown && semantic.children.isNotEmpty) ? semantic.children : [semantic];
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
      if (n is SemanticImage && n.candidate) continue;
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

/// Reads the topmost ModalRoute's name + isFirst flag, or under a Router (go_router and other declarative routers) the router's location. Probes the innermost page first, then the outer one, so a nested route's null name does not win.
class NavigationEnricher implements SemanticEnricher {
  NavigationEnricher({required this.runtime});

  final FlutterRuntime runtime;

  /// `name|isFirst|routeType|pageBacked|routerLocation`; the location comes from `restoreRouteInformation`, which every Router parser implements.
  static const _routeExpr = '((Element e) { final m = ModalRoute.of(e); String loc = ""; '
      'try { final r = Router.maybeOf<Object?>(e); final c = (r?.routerDelegate as dynamic)?.currentConfiguration; '
      'if (r != null && c != null) loc = r.routeInformationParser?.restoreRouteInformation(c)?.uri.toString() ?? ""; } catch (_) {} '
      'return (m?.settings.name ?? "") + "|" + (m?.isFirst.toString() ?? "true") + "|" + (m?.runtimeType.toString() ?? "") '
      '+ "|" + (m?.settings is Page).toString() + "|" + loc; })(WidgetInspectorService.instance.selection.currentElement!)';

  @override
  Future<void> enrich(SemanticScene scene) async {
    // Probe only within the ACTIVE page — a covered sibling route would
    // answer with its own (wrong) name. No name beats a wrong name.
    final pages = [
      ...scene.root.walk().whereType<SemanticPage>().where((p) => p != scene.root).toList().reversed,
      scene.root,
    ];
    for (final page in pages) {
      final pageSource = page.glintId != null ? scene.sourceFor(page.glintId!) : null;
      if (await _probe(scene, pageSource)) return;
    }
  }

  Future<bool> _probe(SemanticScene scene, SceneNode? pageSource) async {
    for (final source in scene.sourceScene.addressableCandidates(within: pageSource)) {
      final result = await runtime.evaluateWithSelection(
        expression: _routeExpr,
        inspectorId: source.inspectorId,
        groupName: scene.sourceScene.groupName,
      );
      if (result == null) continue;
      final parts = result.split('|');
      if (parts.length < 5) continue;
      final name = _name(parts[0], parts[2], pageBacked: parts[3] == 'true', location: parts[4]);
      if (name == null) continue;
      final isDialog = parts[2].contains('Dialog');
      scene.routeStack = [
        RouteFrame(name: name, isModal: parts[1] == 'false' || isDialog),
      ];
      return true;
    }
    return false;
  }

  /// The router's location wins; a route pushed above it without a page (Navigator.push) is named after it, so the push still reads as a route change.
  static String? _name(String routeName, String routeType, {required bool pageBacked, required String location}) {
    if (location.isEmpty) return routeName.isEmpty ? null : routeName;
    if (pageBacked || routeType.isEmpty) return location;
    final pushed = routeName.isNotEmpty ? routeName : routeType.split('<').first;
    return '$location > $pushed';
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
    final icons = scene.allNodes().whereType<SemanticIcon>().toList();
    final budget = min(icons.length, maxIcons);
    for (var i = 0; i < budget; i++) {
      final node = icons[i];
      if (node.glintId == null) continue;
      final source = scene.sourceFor(node.glintId!);
      if (source == null) continue;
      try {
        await _enrichOne(source, groupFor(scene.sourceScene, source), node);
      } on Object {
        // best-effort
      }
    }
  }

  Future<void> _enrichOne(SceneNode source, String groupName, SemanticIcon target) async {
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
    final toggles = scene.root.walk().whereType<SemanticButton>().where((b) => b.isToggle).toList();
    final budget = min(toggles.length, maxToggles);
    for (var i = 0; i < budget; i++) {
      final node = toggles[i];
      if (node.glintId == null) continue;
      final source = scene.sourceFor(node.glintId!);
      if (source == null) continue;
      if (!_valueToggles.contains(source.baseLabel)) continue;
      try {
        final raw = await runtime.evaluateWithSelection(
          expression: '((WidgetInspectorService.instance.selection.currentElement!.widget'
              ' as dynamic).value).toString()',
          inspectorId: source.inspectorId,
          groupName: groupFor(scene.sourceScene, source),
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
  static const _hasRecognizerExpr = '((r) { if (r is! RichText) return false; var f = false; '
      'r.text.visitChildren((s) { if (s is TextSpan && s.recognizer != null) f = true; return true; }); '
      'return f; })'
      '(WidgetInspectorService.instance.selection.currentElement!.widget).toString()';

  @override
  Future<void> enrich(SemanticScene scene) async {
    final texts =
        scene.root.walk().whereType<SemanticText>().where((t) => t.glintId != null && t.affordances.isEmpty).toList();
    final budget = min(texts.length, maxTexts);
    for (var i = 0; i < budget; i++) {
      final node = texts[i];
      final source = scene.sourceFor(node.glintId!);
      if (source == null) continue;
      try {
        final r = await runtime.evaluateWithSelection(
          expression: _hasRecognizerExpr,
          inspectorId: source.inspectorId,
          groupName: groupFor(scene.sourceScene, source),
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
    final inputs = scene.allNodes().whereType<SemanticInput>().toList();
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
  static const _labelExpr = '((w) => w is TextField ? (w.decoration?.labelText ?? '
      'w.decoration?.hintText ?? "") : "")'
      '(WidgetInspectorService.instance.selection.currentElement!.widget)';

  // Current validation error. TextFormField copies the FormField's errorText
  // into the inner TextField's decoration, so reading it here surfaces live
  // validation feedback (why a submit was rejected).
  static const _errorExpr = '((w) => w is TextField ? (w.decoration?.errorText ?? "") : "")'
      '(WidgetInspectorService.instance.selection.currentElement!.widget)';

  Future<void> _enrichOne(SceneNode source, Scene scene, SemanticInput target) async {
    final group = groupFor(scene, source);
    // One subtree read serves both label and value lookups.
    Map<String, Object?>? subtree;
    try {
      subtree = await inspector.getDetailsSubtree(
        inspectorId: source.inspectorId,
        groupName: group,
      );
    } on Object {
      // best-effort — fall back to the source node below
    }
    // The inner TextField carries decoration (label + errorText); resolve it
    // once and reuse for both reads.
    final fieldId = subtree == null
        ? source.inspectorId
        : (_findWidgetId(subtree, const {'TextField', 'CupertinoTextField'}) ?? source.inspectorId);
    try {
      target.hint = await _readDecoration(group, fieldId, _labelExpr);
    } on Object {
      // best-effort
    }
    try {
      target.error = await _readDecoration(group, fieldId, _errorExpr);
    } on Object {
      // best-effort
    }
    try {
      target.setReadValue(await _readCurrentValue(group, subtree));
    } on Object {
      // best-effort
    }
  }

  /// Evaluates a decoration [expr] against the inner [fieldId] TextField. A
  /// [TextFormField] builds an inner TextField, so [fieldId] is resolved from
  /// the subtree rather than the source (which would be the FormField).
  Future<String?> _readDecoration(String group, String fieldId, String expr) async {
    final v = await runtime.evaluateWithSelection(
      expression: expr,
      inspectorId: fieldId,
      groupName: group,
    );
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<String?> _readCurrentValue(String group, Map<String, Object?>? subtree) async {
    if (subtree == null) return null;
    final editableId = _findWidgetId(subtree, const {'EditableText'});
    if (editableId == null) return null;

    final v = await runtime.evaluateWithSelection(
      expression: _currentValueExpr,
      inspectorId: editableId,
      groupName: group,
    );
    return (v == null || v.isEmpty) ? null : v;
  }

  static const _editable = '(WidgetInspectorService.instance.selection.currentElement!.widget as EditableText)';

  /// A field with obscureText set returns only [obscuredValuePrefix] and its length, so its text never leaves the app.
  static const _currentValueExpr = '$_editable.obscureText'
      ' ? \'$obscuredValuePrefix\' + $_editable.controller.text.length.toString()'
      ' : $_editable.controller.text';

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

/// Evaluates one expression over many elements at once: `f` is a block-bodied lambda taking an [Element] and returning a String; results come back `;`-joined in [ids] order.
/// The inspector group that owns [source]'s id: overlay nodes come from the full-tree read, whose ids the summary group cannot look up.
String groupFor(Scene scene, SceneNode source) {
  final id = source.glintId;
  return id != null && scene.isInOverlay(id) ? (scene.fullGroupName ?? scene.groupName) : scene.groupName;
}

String batchOverElements(List<String> ids, String f) => "<String>[${ids.map((i) => "'$i'").join(',')}]"
    '.map((id) => ($f)(WidgetInspectorService.instance.toObject(id) as Element))'
    ".join(';')";

/// Reads selection and checked state for buttons from the widget (`selected` on chips) or its nearest `Semantics` wrapper, in one eval. Capped at [maxNodes].
class SemanticsFlagEnricher implements SemanticEnricher {
  SemanticsFlagEnricher({required this.runtime, this.maxNodes = 40});

  final FlutterRuntime runtime;
  final int maxNodes;

  /// A segment's selection sits on the `Semantics(selected:)` (older Flutter: `checked:`) wrapped around each segment, about 40 elements above its label and below the SegmentedButton.
  static const _flags = '(Element e) { bool? s; bool? c; '
      'try { s = (e.widget as dynamic).selected as bool?; } catch (_) {} '
      'bool? seg; var k = 0; e.visitAncestorElements((a) { k++; final w = a.widget; '
      'if (w is Semantics) seg ??= w.properties.selected ?? w.properties.checked; '
      "if (w.runtimeType.toString().startsWith('SegmentedButton')) { s ??= seg; return false; } return k < 80; }); "
      'var n = 0; if (s == null) e.visitAncestorElements((a) { n++; final w = a.widget; '
      'if (w is Semantics) { s ??= w.properties.selected; c ??= w.properties.checked ?? w.properties.toggled; return false; } '
      'return n < 6; }); '
      "return (s == null ? '' : s.toString()) + ',' + (c == null ? '' : c.toString()); }";

  @override
  Future<void> enrich(SemanticScene scene) async {
    final nodes = <(SemanticButton, String)>[];
    for (final b in scene.allNodes().whereType<SemanticButton>()) {
      final id = b.glintId;
      final source = id == null ? null : scene.sourceFor(id);
      if (source == null || source.inspectorId.isEmpty) continue;
      nodes.add((b, source.inspectorId));
      if (nodes.length >= maxNodes) break;
    }
    if (nodes.isEmpty) return;
    final String? raw;
    try {
      raw = await runtime.evaluateString(batchOverElements([for (final n in nodes) n.$2], _flags));
    } on Object {
      return;
    }
    final parts = raw?.split(';') ?? const <String>[];
    if (parts.length != nodes.length) return;
    for (final (i, part) in parts.indexed) {
      final (node, _) = nodes[i];
      final f = part.split(',');
      if (f.isEmpty) continue;
      node.selected = switch (f[0]) { 'true' => true, 'false' => false, _ => null };
      if (f.length > 1 && node.toggleState == null && f[1].isNotEmpty) {
        node.toggleState = f[1] == 'true' ? 'on' : 'off';
      }
    }
  }
}

/// Names what each image shows (file, asset or URL from its provider) and whether it painted, in one eval. Capped at [maxImages]; containers that might paint a decoration image ride the same eval, capped at [maxDecorationCandidates].
class ImageEnricher implements SemanticEnricher {
  ImageEnricher({
    required this.runtime,
    this.maxImages = 20,
    this.maxDecorationCandidates = 12,
  });

  final FlutterRuntime runtime;
  final int maxImages;
  final int maxDecorationCandidates;

  static const _image = '(Element e) { final w = e.widget as dynamic; Object? p; bool d = false; '
      'try { p = w.image; } catch (_) {} '
      'if (p == null) { try { p = w.backgroundImage; } catch (_) {} } '
      'if (p == null) { try { p = w.foregroundImage; } catch (_) {} } '
      'if (p == null) { try { p = w.decoration?.image?.image; d = p != null; } catch (_) {} } '
      'bool? ok; void v(Element c) { if (ok != null) return; '
      'if (c.widget is RawImage) { ok = (c.widget as RawImage).image != null; return; } c.visitChildren(v); } '
      'if (!d) e.visitChildren(v); '
      "return (p == null ? '' : p.toString().replaceAll(';', ',').replaceAll('|', '/')) + '|' + (ok == null ? '' : ok.toString()); }";

  @override
  Future<void> enrich(SemanticScene scene) async {
    try {
      await _resolve(scene);
    } finally {
      dropCandidates(scene);
    }
  }

  /// Removes decoration-image candidates nothing confirmed, leaving the scene as if they had been dissolved.
  static void dropCandidates(SemanticScene scene) {
    bool unconfirmed(SemanticNode n) => n is SemanticImage && n.candidate;
    for (final node in scene.allNodes().toList()) {
      if (node.children.any(unconfirmed)) node.children.removeWhere(unconfirmed);
    }
    for (final layer in scene.overlayLayers) {
      layer.nodes.removeWhere(unconfirmed);
    }
  }

  Future<void> _resolve(SemanticScene scene) async {
    final nodes = <(SemanticImage, String)>[];
    var images = 0;
    var candidates = 0;
    for (final img in scene.allNodes().whereType<SemanticImage>()) {
      if (img.candidate ? candidates >= maxDecorationCandidates : images >= maxImages) {
        continue;
      }
      final id = img.glintId;
      final source = id == null ? null : scene.sourceFor(id);
      if (source == null || source.inspectorId.isEmpty) continue;
      nodes.add((img, source.inspectorId));
      img.candidate ? candidates++ : images++;
    }
    if (nodes.isEmpty) return;
    final String? raw;
    try {
      raw = await runtime.evaluateString(batchOverElements([for (final n in nodes) n.$2], _image));
    } on Object {
      return;
    }
    final parts = raw?.split(';') ?? const <String>[];
    if (parts.length != nodes.length) return;
    for (final (i, part) in parts.indexed) {
      final (node, _) = nodes[i];
      final bar = part.lastIndexOf('|');
      if (bar < 0) continue;
      node.source = imageSourceName(part.substring(0, bar));
      if (node.candidate) {
        node.candidate = node.source == null;
        continue;
      }
      node.state = switch (part.substring(bar + 1)) {
        'true' => 'loaded',
        'false' => 'not loaded',
        _ => null,
      };
    }
  }
}

/// Short name for an ImageProvider's `toString()`: a file's base name, an asset name, a URL's host and last segment, else the provider type.
String? imageSourceName(String provider) {
  if (provider.isEmpty) return null;
  final quoted = RegExp(r'"([^"]+)"').firstMatch(provider)?.group(1);
  if (quoted == null) return provider.split('(').first.trim();
  final uri = Uri.tryParse(quoted);
  if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
    final last = uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    return last == null ? uri.host : '${uri.host}/…/$last';
  }
  return _middleCut(quoted.split('/').last);
}

/// Keeps both ends of a long file name (the start and the extension) so the label stays short.
String _middleCut(String name, {int max = 24}) =>
    name.length <= max ? name : '${name.substring(0, max - 11)}…${name.substring(name.length - 10)}';

/// Names the tabs of each navigation bar and marks the selected one, from the bar's destinations or items, whose labels are plain strings the scene never sees.
class TabLabelEnricher implements SemanticEnricher {
  TabLabelEnricher({required this.runtime});

  final FlutterRuntime runtime;

  static const _labels = '(Element e) { final w = e.widget as dynamic; var l = <String>[]; int? sel; '
      "String text(Object? x) => x is String ? x : (x is Text ? (x.data ?? '') : ''); "
      'try { l = [for (final d in w.destinations) text(d.label)]; sel = w.selectedIndex as int?; } catch (_) {} '
      'if (l.isEmpty) { try { l = [for (final t in w.tabs) (t.text as String?) ?? text(t.child)]; '
      'Object? c; try { c = w.controller; } catch (_) {} '
      "if (c == null) e.visitAncestorElements((a) { if (a.widget.runtimeType.toString() == '_TabControllerScope') { c = (a.widget as dynamic).controller; return false; } return true; }); "
      'sel = (c as dynamic)?.index as int?; } catch (_) {} } '
      'if (l.isEmpty) { try { l = [for (final i in w.items) text(i.label)]; sel = w.currentIndex as int?; } catch (_) {} } '
      "return l.map((s) => s.replaceAll(';', ',')).join('\\u001f') + '\\u001e' + (sel?.toString() ?? ''); }";

  @override
  Future<void> enrich(SemanticScene scene) async {
    final bars = <(SemanticContainer, String)>[];
    for (final c in scene.allNodes().whereType<SemanticContainer>()) {
      final id = c.glintId;
      final source = id == null ? null : scene.sourceFor(id);
      if (c.hint == 'tabs' && source != null && source.inspectorId.isNotEmpty) bars.add((c, source.inspectorId));
    }
    if (bars.isEmpty) return;
    final String? raw;
    try {
      raw = await runtime.evaluateString(batchOverElements([for (final b in bars) b.$2], _labels));
    } on Object {
      return;
    }
    final parts = raw?.split(';') ?? const <String>[];
    if (parts.length != bars.length) return;
    for (final (i, part) in parts.indexed) {
      final (bar, _) = bars[i];
      final halves = part.split('\u001e');
      final labels = halves.first.isEmpty ? const <String>[] : halves.first.split('\u001f');
      final selected = halves.length > 1 ? int.tryParse(halves[1]) : null;
      final tabs = bar.children.whereType<SemanticButton>().toList();
      if (labels.length != tabs.length) continue;
      for (final (j, tab) in tabs.indexed) {
        if (labels[j].isNotEmpty && tab.label == null) {
          tab.label = labels[j];
          if (tab.children.isNotEmpty && tab.children.every((c) => c is SemanticIcon)) tab.children.clear();
        }
        if (selected != null) tab.selected = j == selected;
      }
    }
  }
}

/// Reads what each button and list tile would do: a tile with a tap handler becomes tappable, a button with none reads `[disabled]`, and an icon-only button takes its tooltip as its label. Capped at [maxNodes].
class ButtonFactsEnricher implements SemanticEnricher {
  ButtonFactsEnricher({required this.runtime, this.maxNodes = 80});

  final FlutterRuntime runtime;
  final int maxNodes;

  /// App bar buttons whose null `onPressed` means "do the default" (pop, open the drawer), not disabled.
  static const _defaultActionButtons = {
    'BackButton',
    'CloseButton',
    'DrawerButton',
    'EndDrawerButton',
    'CupertinoNavigationBarBackButton'
  };

  static const _facts = '(Element e) { final w = e.widget as dynamic; bool? on; String? tip; '
      'bool has(Object? Function() f) { try { return f() != null; } catch (_) { return false; } } '
      'bool known(Object? Function() f) { try { f(); return true; } catch (_) { return false; } } '
      'if (known(() => w.onPressed)) on = has(() => w.onPressed) || has(() => w.onLongPress); '
      'else if (known(() => w.onTap)) on = has(() => w.onTap) || has(() => w.onLongPress) || has(() => w.onDoubleTap) '
      '|| has(() => w.onPanStart) || has(() => w.onPanUpdate) || has(() => w.onVerticalDragUpdate) || has(() => w.onHorizontalDragUpdate) '
      '|| has(() => w.onScaleUpdate) || has(() => w.onTapDown) || has(() => w.onTapUp); '
      'try { tip = w.tooltip as String?; } catch (_) {} '
      "return (on == null ? '' : on.toString()) + '|' + (tip ?? '').replaceAll(';', ',').replaceAll('|', '/'); }";

  @override
  Future<void> enrich(SemanticScene scene) async {
    final nodes = <(SemanticNode, String)>[];
    for (final n in scene.allNodes()) {
      final isTile = n is SemanticContainer && n.hint == 'tile';
      if (n is! SemanticButton && !isTile) continue;
      final id = n.glintId;
      final source = id == null ? null : scene.sourceFor(id);
      if (source == null || source.inspectorId.isEmpty) continue;
      if (_defaultActionButtons.contains(source.baseLabel)) continue;
      nodes.add((n, source.inspectorId));
      if (nodes.length >= maxNodes) break;
    }
    if (nodes.isEmpty) return;
    final String? raw;
    try {
      raw = await runtime.evaluateString(batchOverElements([for (final n in nodes) n.$2], _facts));
    } on Object {
      return;
    }
    final parts = raw?.split(';') ?? const <String>[];
    if (parts.length != nodes.length) return;
    for (final (i, part) in parts.indexed) {
      final (node, _) = nodes[i];
      final f = part.split('|');
      final on = switch (f.first) { 'true' => true, 'false' => false, _ => null };
      final tip = f.length > 1 && f[1].isNotEmpty ? f[1] : null;
      if (node is SemanticContainer) {
        if (on == true) node.affordances.add(Affordance.tappable);
        continue;
      }
      final button = node as SemanticButton;
      if (on == false && !button.isToggle) {
        button.enabled = false;
        button.affordances.remove(Affordance.tappable);
      }
      if (tip != null && (button.label == null || button.label!.isEmpty)) button.label = tip;
    }
  }
}

/// Reads inside widgets whose build is outside the app (a design-system package): one that takes taps becomes a button labelled by its painted text, one that only paints text becomes text. Capped at [maxNodes].
class OpaqueWidgetEnricher implements SemanticEnricher {
  OpaqueWidgetEnricher({required this.runtime, this.maxNodes = 40});

  final FlutterRuntime runtime;
  final int maxNodes;

  static const _handlers =
      "const {'InkWell', 'InkResponse', 'GestureDetector', 'TextButton', 'ElevatedButton', 'FilledButton', "
      "'OutlinedButton', 'IconButton', 'CupertinoButton', 'RawMaterialButton', 'MaterialButton', 'FloatingActionButton'}";

  static const _inside = '(Element e) { '
      'bool has(Object? Function() f) { try { return f() != null; } catch (_) { return false; } } '
      'final root = e.widget as dynamic; '
      'final self = has(() => root.onPressed) || has(() => root.onTap); '
      'var taps = 0; var seen = 0; final texts = <String>[]; '
      'void visit(Element c) { if (seen++ > 400) return; final w = c.widget as dynamic; final n = c.widget.runtimeType.toString(); '
      "if (n == 'RichText') { final s = (w.text.toPlainText() as String).replaceAll('\\uFFFC', '').trim(); "
      'if (s.isNotEmpty && texts.length < 4) texts.add(s); return; } '
      'if ($_handlers.contains(n) && (has(() => w.onTap) || has(() => w.onPressed) || has(() => w.onLongPress))) taps++; '
      'c.visitChildren(visit); } '
      'e.visitChildren(visit); '
      "return (self ? 'self' : '\$taps') + '|' + texts.join(' ').replaceAll(';', ',').replaceAll('|', '/'); }";

  @override
  Future<void> enrich(SemanticScene scene) async {
    final slots = <(List<SemanticNode>, int, String)>[];
    void visit(SemanticNode n) {
      for (final (i, c) in n.children.indexed) {
        final id = c.glintId;
        if (c is SemanticUnknown && c.children.isEmpty && id != null && slots.length < maxNodes) {
          final source = scene.sourceFor(id);
          if (source != null && source.inspectorId.isNotEmpty) slots.add((n.children, i, source.inspectorId));
        }
        visit(c);
      }
    }

    for (final layer in scene.overlayLayers) {
      layer.nodes.forEach(visit);
    }
    visit(scene.root);
    if (slots.isEmpty) return;
    final String? raw;
    try {
      raw = await runtime.evaluateString(batchOverElements([for (final s in slots) s.$3], _inside));
    } on Object {
      return;
    }
    final parts = raw?.split(';') ?? const <String>[];
    if (parts.length != slots.length) return;
    for (final (i, part) in parts.indexed) {
      final (siblings, at, _) = slots[i];
      final f = part.split('|');
      final text = f.length > 1 ? f[1].trim() : '';
      final unknown = siblings[at];
      final tappable = f.first == 'self' || f.first == '1';
      if (tappable) {
        siblings[at] = SemanticButton(glintId: unknown.glintId, label: text.isEmpty ? null : text);
      } else if (f.first == '0' && text.isNotEmpty) {
        siblings[at] = SemanticText(glintId: unknown.glintId, content: text);
      }
    }
  }
}

/// Marks controls a person cannot use right now: faded to opacity 0 ([Inert.hidden]) or under an active IgnorePointer / AbsorbPointer ([Inert.ignoresTouches]); they lose their tap and type markers. Capped at [maxNodes].
class InertEnricher implements SemanticEnricher {
  InertEnricher({required this.runtime, this.maxNodes = 80});

  final FlutterRuntime runtime;
  final int maxNodes;

  static const _cover = '(Element e) { var r = \'\'; '
      'bool zero(Object? Function() f) { try { final v = f(); return v is num ? v == 0 : (v as dynamic).value == 0; } catch (_) { return false; } } '
      'bool on(Object? Function() f) { try { return f() == true; } catch (_) { return false; } } '
      'e.visitAncestorElements((a) { final d = a.widget as dynamic; final n = a.widget.runtimeType.toString(); '
      "if (const {'Opacity', 'AnimatedOpacity', 'SliverOpacity', 'SliverAnimatedOpacity', 'FadeTransition', 'SliverFadeTransition'}.contains(n) "
      "&& zero(() => d.opacity)) { r = 'hidden'; return false; } "
      "if (r.isEmpty && (n == 'IgnorePointer' || n == 'SliverIgnorePointer') && on(() => d.ignoring)) r = 'ignored'; "
      "if (r.isEmpty && n == 'AbsorbPointer' && on(() => d.absorbing)) r = 'ignored'; "
      'return true; }); return r; }';

  @override
  Future<void> enrich(SemanticScene scene) async {
    final nodes = <(SemanticNode, String)>[];
    for (final n in scene.allNodes()) {
      if (!n.affordances.contains(Affordance.tappable) && !n.affordances.contains(Affordance.typeable)) continue;
      final id = n.glintId;
      final source = id == null ? null : scene.sourceFor(id);
      if (source == null || source.inspectorId.isEmpty) continue;
      nodes.add((n, source.inspectorId));
      if (nodes.length >= maxNodes) break;
    }
    if (nodes.isEmpty) return;
    final String? raw;
    try {
      raw = await runtime.evaluateString(batchOverElements([for (final n in nodes) n.$2], _cover));
    } on Object {
      return;
    }
    final parts = raw?.split(';') ?? const <String>[];
    if (parts.length != nodes.length) return;
    for (final (i, part) in parts.indexed) {
      final inert = switch (part) { 'hidden' => Inert.hidden, 'ignored' => Inert.ignoresTouches, _ => null };
      if (inert == null) continue;
      final node = nodes[i].$1;
      node.inert = inert;
      node.affordances.removeAll(const {Affordance.tappable, Affordance.typeable});
    }
  }
}
