import 'dart:async';

import 'package:design_kit/design_kit.dart';
import 'package:flutter/material.dart';

/// An incoming call answered with design-system buttons, then a connected view whose controls fade out.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  bool _connected = false;
  bool _controls = true;
  bool _muted = false;
  String? _ended;
  Timer? _hide;

  void _show() {
    _hide?.cancel();
    setState(() => _controls = true);
    _hide = Timer(const Duration(seconds: 4), () => mounted ? setState(() => _controls = false) : null);
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF081C15),
    appBar: AppBar(title: const Text('Call')),
    body: _ended != null
        ? Center(
            child: Text(_ended!, style: const TextStyle(color: Colors.white)),
          )
        : _connected
        ? _connectedView()
        : _incomingView(),
  );

  Widget _incomingView() => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const Text('Moyin is calling', style: TextStyle(color: Colors.white, fontSize: 22)),
      const SizedBox(height: 32),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 16,
        children: [
          KitButton(
            label: 'Decline',
            color: const Color(0xFF9B2226),
            onPressed: () => setState(() => _ended = 'Call declined'),
          ),
          KitButton(
            label: 'Accept',
            onPressed: () {
              setState(() => _connected = true);
              _show();
            },
          ),
        ],
      ),
    ],
  );

  Widget _connectedView() => Stack(
    children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _show,
          child: const Center(
            child: Text('Moyin', style: TextStyle(color: Colors.white70, fontSize: 28)),
          ),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 48,
        child: AnimatedOpacity(
          opacity: _controls ? 1 : 0,
          duration: const Duration(milliseconds: 250),
          child: IgnorePointer(
            ignoring: !_controls,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 24,
              children: [
                IconButton.filled(
                  tooltip: _muted ? 'Unmute' : 'Mute',
                  onPressed: () => setState(() => _muted = !_muted),
                  icon: Icon(_muted ? Icons.mic_off : Icons.mic),
                ),
                KitButton(
                  label: 'End call',
                  color: const Color(0xFF9B2226),
                  onPressed: () => setState(() => _ended = 'Call ended'),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}
