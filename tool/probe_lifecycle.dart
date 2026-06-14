import 'package:glint/glint.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('usage: dart run /tmp/probe_lifecycle.dart <vm-uri>');
    return;
  }
  final vm = VmClient();
  await vm.attach(Uri.parse(args[0]));
  final session = GlintSession();
  // hand-build a minimal device target for an iOS sim so attach() works
  await session.attach(
    vmUri: Uri.parse(args[0]),
    device: IosSimulator(
      udid: 'probe',
      logicalWidth: 402,
      logicalHeight: 874,
      devicePixelRatio: 3,
      bridgePath: '/tmp/unused',
    ),
  );
  final state = await session.lifecycleState();
  print('lifecycle: $state');
  await session.detach();
  await vm.disconnect();
}
