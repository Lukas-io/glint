import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'driver_screen.dart';
import 'link/link.dart';
import 'rider_screen.dart';
import 'ui/theme.dart';

/// Which side of the trip this phone plays: --dart-define=ROLE=rider|driver wins.
const _role = String.fromEnvironment('ROLE');

late final bool isDriver;

/// Android drives; on iOS the first simulator to claim the link port rides and the next one drives, as simulators share the Mac's network.
Future<bool> _pickDriver() async {
  if (_role.isNotEmpty) return _role == 'driver';
  if (Platform.isAndroid) return true;
  try {
    final probe = await ServerSocket.bind(InternetAddress.anyIPv4, linkPort);
    await probe.close();
    return false;
  } on SocketException {
    return true;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.dark);
  isDriver = await _pickDriver();
  runApp(const GlintRide());
}

class GlintRide extends StatelessWidget {
  const GlintRide({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'glint Ride',
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      home: isDriver ? const DriverScreen() : const RiderScreen(),
    );
  }
}
