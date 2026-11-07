import 'dart:io';

import 'package:glint_core/glint_core.dart';

/// Stops [process] and everything below it: polite first, forceful after two seconds, and no signal once it is gone.
Future<void> killProcessTree(Process process) => killTree(process.pid, handle: process);
