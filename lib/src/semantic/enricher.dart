import 'package:vm_service/vm_service.dart';

import '../../perception.dart';
import 'semantic_node.dart';
import 'semantic_scene.dart';

/// Post-classify pass that fills role-specific properties (hint,
/// currentValue, …) by talking to the live VM. Stays in Module C
/// because it operates on [SemanticNode]s, but takes a VM/inspector
/// dependency since pure SceneNode parsing can't surface this data.
abstract class SemanticEnricher {
  Future<void> enrich(SemanticScene scene);
}

/// Surfaces `hint` (InputDecoration.labelText) and `currentValue`
/// (the live EditableText controller text) on every [SemanticInput].
/// Bounded to [maxInputs] per scene — each input costs ~2 VM evals.
class InputEnricher implements SemanticEnricher {
  InputEnricher({
    required this.vm,
    required this.inspector,
    this.maxInputs = 10,
  });

  final VmClient vm;
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
    final svc = vm.service;
    final isolateId = vm.flutterIsolateId;
    final rootLib = vm.flutterIsolate.rootLib?.id;
    if (rootLib == null) return null;

    await svc.callServiceExtension(
      'ext.flutter.inspector.setSelectionById',
      isolateId: isolateId,
      args: {'arg': source.inspectorId, 'objectGroup': scene.groupName},
    );

    final raw = await svc.evaluate(
      isolateId,
      rootLib,
      '(WidgetInspectorService.instance.selection.currentElement!.widget '
          'as TextField).decoration?.labelText ?? ""',
    );
    return _stringFromRef(raw);
  }

  Future<String?> _readCurrentValue(Scene scene, SceneNode source) async {
    final svc = vm.service;
    final isolateId = vm.flutterIsolateId;
    final rootLib = vm.flutterIsolate.rootLib?.id;
    if (rootLib == null) return null;

    // Walk the TextField's subtree for an EditableText valueId.
    final subtree = await inspector.getDetailsSubtree(
      inspectorId: source.inspectorId,
      groupName: scene.groupName,
    );
    final editableId = _findEditableTextValueId(subtree);
    if (editableId == null) return null;

    await svc.callServiceExtension(
      'ext.flutter.inspector.setSelectionById',
      isolateId: isolateId,
      args: {'arg': editableId, 'objectGroup': scene.groupName},
    );

    final raw = await svc.evaluate(
      isolateId,
      rootLib,
      '(WidgetInspectorService.instance.selection.currentElement!.widget '
          'as EditableText).controller.text',
    );
    return _stringFromRef(raw);
  }

  /// `valueAsString` is the 128-char preview; refetch when truncated
  /// (same trick as CoordinateResolver).
  Future<String?> _stringFromRefAsync(InstanceRef ref) async {
    if (ref.valueAsString == null) return null;
    if (ref.valueAsStringIsTruncated != true) return ref.valueAsString;
    final full = await vm.service.getObject(vm.flutterIsolateId, ref.id!);
    return full is Instance ? full.valueAsString : ref.valueAsString;
  }

  Future<String?> _stringFromRef(Object? raw) async {
    if (raw is! InstanceRef) return null;
    final s = await _stringFromRefAsync(raw);
    return (s == null || s.isEmpty) ? null : s;
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
