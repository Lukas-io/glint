import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

void main() => runApp(const CounterApp());

class CounterApp extends StatelessWidget {
  const CounterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'glint counter fixture',
      theme: ThemeData(colorSchemeSeed: Colors.teal),
      home: const CounterPage(),
    );
  }
}

class CounterPage extends StatefulWidget {
  const CounterPage({super.key});

  @override
  State<CounterPage> createState() => _CounterPageState();
}

class _CounterPageState extends State<CounterPage> {
  int _count = 0;
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('glint counter fixture')),
      body: SingleChildScrollView(
        controller: _scrollController,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text('You have pushed the button this many times:'),
            ),
            Text(
              '$_count',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 24),
            const Divider(),
            // Painted/hittable edge cases — P1 verification surface.
            const _FlagsLab(),
            // Tall block of items so the page genuinely overflows the
            // viewport on every supported simulator (iPhone 17 Pro down
            // to iPhone SE). 30 × 80pt rows = 2400 logical px — taller
            // than any current iPhone.
            for (var i = 0; i < 30; i++)
              SizedBox(
                height: 80,
                child: Center(
                  child: Text(
                    'scroll row $i',
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _count++),
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// Top-level helper for the smoke harness — exposed so glint's Module B
/// can read the current scroll offset of the counter page's
/// SingleChildScrollView. The harness uses this to verify swipe
/// behaviour without guessing from widget Y coordinates.
@pragma('vm:entry-point')
double glintReadScrollOffset() {
  // Find the first ScrollPosition currently mounted. SingleChildScrollView
  // attaches its position to a global ScrollController; the inspector
  // doesn't surface that directly, so we walk the element tree.
  double? out;
  void visit(Element e) {
    if (out != null) return;
    final dynamic w = e.widget;
    if (w is Scrollable) {
      final dynamic state = (e as dynamic);
      // ignore: avoid_dynamic_calls
      out = (state.state?.position?.pixels as double?) ?? 0.0;
      return;
    }
    e.visitChildren(visit);
  }
  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return out ?? -1;
}

/// Three buttons that should resolve as:
/// - `elevated_button_in_visible_row` — painted=true,  hittable=true
/// - `elevated_button_in_opacity_zero_row` — painted=false, hittable=true
///   (Flutter Opacity(0) still receives hits; that's the canonical
///   painted-vs-hittable divergence.)
/// - `elevated_button_in_absorb_pointer_row` — painted=true, hittable=false
///   (AbsorbPointer eats the tap; button still paints.)
class _FlagsLab extends StatelessWidget {
  const _FlagsLab();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('flags lab', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _LabRow(
            label: 'visible',
            child: ElevatedButton(
              onPressed: () {},
              child: const Text('tap me'),
            ),
          ),
          const SizedBox(height: 8),
          _LabRow(
            label: 'opacity_zero',
            child: Opacity(
              opacity: 0,
              child: ElevatedButton(
                onPressed: () {},
                child: const Text('opacity-0'),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _LabRow(
            label: 'absorb_pointer',
            child: AbsorbPointer(
              absorbing: true,
              child: ElevatedButton(
                onPressed: () {},
                child: const Text('absorbed'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LabRow extends StatelessWidget {
  const _LabRow({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 120, child: Text(label)),
        Expanded(child: child),
      ],
    );
  }
}

// =====================================================================
// P0 smoke hooks (FIXTURE-ONLY).
//
// These helpers exist purely so the smoke harness can drive the loop
// via single-expression VM-service evaluate() calls, which can't host
// statement-block lambdas. They are NOT how Module B (P1) will work —
// Module B reads the live inspector tree server-side and computes
// coordinates from the diagnostic JSON, without any in-app cooperation.
// The zero-modification principle (see source-of-truth §3) applies to
// real target apps; this fixture is allowed to cooperate so P0 can
// prove the end-to-end loop on both platforms.
// =====================================================================

@pragma('vm:entry-point')
String glintLocateByRuntimeType(String typeName) {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return '';
  final stack = <Element>[root];
  while (stack.isNotEmpty) {
    final e = stack.removeLast();
    if (e.widget.runtimeType.toString() == typeName) {
      final ro = e.renderObject;
      if (ro is RenderBox && ro.hasSize) {
        final c = ro.localToGlobal(ro.size.center(Offset.zero));
        return '${c.dx},${c.dy},${View.of(e).devicePixelRatio}';
      }
      return '';
    }
    e.visitChildren(stack.add);
  }
  return '';
}

@pragma('vm:entry-point')
String glintSyntheticTap(double x, double y) {
  final p = Offset(x, y);
  final b = WidgetsBinding.instance;
  b.handlePointerEvent(PointerDownEvent(position: p, pointer: 7));
  b.handlePointerEvent(PointerUpEvent(position: p, pointer: 7));
  return 'ok';
}
