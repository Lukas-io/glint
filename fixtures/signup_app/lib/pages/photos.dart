import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../signup.dart';
import '../theme.dart';
import '../widgets.dart';

class PhotosPage extends StatefulWidget {
  const PhotosPage({super.key});

  @override
  State<PhotosPage> createState() => _PhotosPageState();
}

class _PhotosPageState extends State<PhotosPage> {
  final _photos = <String>[];
  bool _tip = true;
  String? _error;

  Future<void> _add() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_rounded, color: gold),
                title: const Text('Choose from library'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_rounded, color: gold),
                title: const Text('Take a photo'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.close_rounded, color: muted),
                title: const Text('Cancel'),
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null || !mounted) return;
    try {
      final picked = await ImagePicker().pickImage(source: source, maxWidth: 1200);
      if (picked == null || !mounted) return;
      setState(() {
        _photos.add(picked.path);
        _error = null;
      });
    } catch (_) {
      if (mounted) toast(context, 'The camera is not available on this device.');
    }
  }

  void _continue() {
    if (_photos.isEmpty) {
      setState(() => _error = 'Add at least one photo to continue');
      return;
    }
    signup.photoPath = _photos.first;
    Navigator.of(context).pushNamed('/interests');
  }

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      step: 5,
      title: 'Show your\nface',
      subtitle: 'Profiles with a clear photo get three times more replies. Add up to six.',
      cta: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EmberButton(label: 'Continue', onPressed: _continue),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () {},
            child: const Text('Skip for now', style: TextStyle(color: muted)),
          ),
        ],
      ),
      overlay: _tip ? _Tip(onDismiss: () => setState(() => _tip = false)) : null,
      children: [
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.75,
          children: [
            for (var i = 0; i < 6; i++)
              i < _photos.length ? _Photo(path: _photos[i], cover: i == 0) : _EmptySlot(onTap: _add, first: i == 0),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: danger)),
        ],
      ],
    );
  }
}

class _EmptySlot extends StatelessWidget {
  const _EmptySlot({required this.onTap, required this.first});

  final VoidCallback onTap;
  final bool first;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: first ? ember : surfaceHigh, width: first ? 2 : 1),
        ),
        child: Center(
          child: Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(shape: BoxShape.circle, gradient: emberGradient),
            child: const Icon(Icons.add_rounded, color: ink),
          ),
        ),
      ),
    );
  }
}

class _Photo extends StatelessWidget {
  const _Photo({required this.path, required this.cover});

  final String path;
  final bool cover;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(File(path), fit: BoxFit.cover),
          if (cover)
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(gradient: emberGradient, borderRadius: BorderRadius.circular(10)),
                child: const Text('Cover', style: TextStyle(color: ink, fontSize: 12, fontWeight: FontWeight.w800)),
              ),
            ),
        ],
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.72),
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(32),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: surface, borderRadius: BorderRadius.circular(28)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.tips_and_updates_rounded, color: gold, size: 32),
                const SizedBox(height: 14),
                const Text('Your first photo is your cover', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                const Text(
                  'It is the first thing people see. Pick one where your face is clear and the light is good.',
                  style: TextStyle(color: muted, height: 1.4),
                ),
                const SizedBox(height: 20),
                EmberButton(label: 'Got it', onPressed: onDismiss),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
