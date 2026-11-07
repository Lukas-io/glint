import 'dart:async';
import 'dart:ffi';

int Function()? _getppid() {
  try {
    return DynamicLibrary.process().lookupFunction<Int32 Function(), int Function()>('getppid');
  } on Object {
    return null;
  }
}

/// Calls [onGone] once when the process that started this one exits (the parent changes to launchd); null where the platform cannot say.
Timer? watchParentDeath(void Function() onGone, {Duration every = const Duration(seconds: 3)}) {
  final getppid = _getppid();
  if (getppid == null) return null;
  final original = getppid();
  if (original <= 1) return null;
  late final Timer timer;
  timer = Timer.periodic(every, (_) {
    if (getppid() == original) return;
    timer.cancel();
    onGone();
  });
  return timer;
}
