/// Public API surface for the glint package.
///
/// Pre-MCP — Module B / Module A are accessed directly by `tool/` scripts
/// and tests during P1 and P2. The MCP server (P4) consumes the same
/// surface from inside `bin/glint.dart`.
library glint;

export 'src/interaction/action.dart'
    show
        Action,
        DoubleTap,
        HardwareButton,
        LongPress,
        PressHardwareButton,
        Swipe,
        Tap,
        TypeText;
export 'src/interaction/backend.dart'
    show
        BackendCapabilities,
        BackendToolError,
        InteractionBackend,
        UnsupportedBackendAction;
export 'src/interaction/backends/adb_backend.dart' show AdbBackend;
export 'src/interaction/backends/ios_sim_backend.dart' show IosSimBackend;
export 'src/interaction/interactor.dart'
    show Interactor, NotHittableRefused, UnresolvedTarget;
export 'src/interaction/result.dart' show ActionResult;
export 'src/interaction/target.dart'
    show CoordinateTarget, SymbolicTarget, Target;
export 'src/perception/geometry.dart'
    show CoordinateResolver, GeometryResolveError, ResolvedCoord;
export 'src/perception/inspector_client.dart'
    show InspectorClient, InspectorReadError;
export 'src/perception/scene_node.dart' show SceneNode, CreationLocation;
export 'src/perception/scene_reader.dart' show Scene, SceneReader;
export 'src/perception/stable_id.dart' show StableIdGenerator;
export 'src/vm/vm_client.dart' show VmClient;
