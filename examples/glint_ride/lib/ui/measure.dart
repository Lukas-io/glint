import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Reports its child's height on every layout, including mid-animation, so the camera knows how much map is covered.
class HeightReporter extends SingleChildRenderObjectWidget {
  const HeightReporter({super.key, required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderHeight(onHeight);

  @override
  void updateRenderObject(BuildContext context, RenderHeight renderObject) => renderObject.onHeight = onHeight;
}

/// Render side of [HeightReporter].
class RenderHeight extends RenderProxyBox {
  RenderHeight(this.onHeight);

  ValueChanged<double> onHeight;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h == _last) return;
    _last = h;
    // Report after layout so listeners can set state safely.
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(h));
  }
}
