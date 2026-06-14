import 'package:glint/glint.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('usage: dart run tool/probe_uistate.dart <vm-uri>');
    return;
  }
  final session = GlintSession();
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
  final ui = await session.uiState();
  final lifecycle = await session.lifecycleState();
  print('focusedType: ${ui.focusedType}');
  print('keyboardBottomPx: ${ui.keyboardBottomPx}');
  print('lifecycle: $lifecycle');
  await session.detach();
}
