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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('glint counter fixture')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('You have pushed the button this many times:'),
            Text(
              '$_count',
              style: Theme.of(context).textTheme.headlineMedium,
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
