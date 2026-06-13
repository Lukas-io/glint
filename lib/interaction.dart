/// Module A — interaction layer. One barrel export covering actions,
/// targets, backends, the orchestrator, and the unified [DeviceTarget]
/// entry point.
library;

export 'src/interaction/action.dart';
export 'src/interaction/backend.dart';
export 'src/interaction/backends/adb_backend.dart';
export 'src/interaction/backends/ios_sim_backend.dart';
export 'src/interaction/device.dart';
export 'src/interaction/interactor.dart';
export 'src/interaction/result.dart';
export 'src/interaction/target.dart';
