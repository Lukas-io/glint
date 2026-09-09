import '../perception/scene_node.dart';

/// Argument maps for the Flutter inspector service extensions. The key names
/// differ per extension, so they live in one place: `disposeGroup` reads
/// `objectGroup`, the tree read reads `groupName`.
class InspectorParams {
  const InspectorParams._();

  static Map<String, String> rootWidgetTree({
    required String groupName,
    required bool isSummaryTree,
    bool withPreviews = true,
    bool fullDetails = false,
  }) =>
      {
        'groupName': groupName,
        'isSummaryTree': '$isSummaryTree',
        'withPreviews': '$withPreviews',
        'fullDetails': '$fullDetails',
      };

  static Map<String, String> detailsSubtree({
    required String inspectorId,
    required String groupName,
    int subtreeDepth = 5,
  }) =>
      {
        'arg': inspectorId,
        'objectGroup': groupName,
        'subtreeDepth': '$subtreeDepth',
      };

  static Map<String, String> selectionById({
    required String inspectorId,
    required String groupName,
  }) =>
      {'arg': inspectorId, 'objectGroup': groupName};

  /// `disposeGroup` force-unwraps `objectGroup`; sending `groupName` instead throws a null-check error in the app.
  static Map<String, String> disposeGroup(String groupName) =>
      {'objectGroup': groupName};

  /// `addPubRootDirectories` is var-args: arg0, arg1, … one per directory.
  static Map<String, String> pubRootDirectories(List<String> dirs) =>
      {for (var i = 0; i < dirs.length; i++) 'arg$i': dirs[i]};
}

/// The app's package root from its resolved main-library file URI: `file:///x/app/lib/main.dart` → `/x/app`. Null when there is no `/lib/` segment.
String? appRootFromMainScript(String? fileUri) {
  if (fileUri == null) return null;
  String path;
  try {
    path = Uri.parse(fileUri).toFilePath();
  } on Object {
    return null;
  }
  final i = path.lastIndexOf('/lib/');
  if (i < 0) return null;
  return path.substring(0, i);
}

/// True when the local-project filter reduced the summary tree to framework scaffolding: nothing below the root was created by the app.
bool isDegenerateTree(SceneNode root) {
  for (final n in root.walk().skip(1)) {
    if (n.createdByLocalProject) return false;
  }
  return true;
}
