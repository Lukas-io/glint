import 'package:glint/glint.dart';
import 'package:test/test.dart';

void main() {
  group('StructuredResponse.error', () {
    test('flags isError, lifts errorKind + detail into data', () {
      final r = StructuredResponse.error(
        summary: 'bad arg',
        errorKind: GlintErrorKind.invalidArgument,
        detail: 'platform must be ios|android',
        nextSteps: const ['try platform: ios'],
      );
      expect(r.isError, isTrue);
      expect(r.summary, 'bad arg');
      expect(r.data?['errorKind'], 'invalidArgument');
      expect(r.data?['detail'], 'platform must be ios|android');
      expect(r.nextSteps, ['try platform: ios']);
    });

    test('serialises errorKind by enum name in structured content', () {
      for (final k in GlintErrorKind.values) {
        final r = StructuredResponse.error(summary: 'x', errorKind: k);
        expect(r.toStructuredContent()['errorKind'], k.name);
      }
    });
  });

  group('StructuredResponse.fromActionResult', () {
    test('copies summary/warnings/nextSteps and exposes ok via !isError', () {
      final action = const Tap(SymbolicTarget('foo'));
      final result = ActionResult.success(
        action: action,
        summary: 'tapped',
        warnings: const ['hint!'],
        nextSteps: const ['next'],
      );
      final env = StructuredResponse.fromActionResult(result);
      expect(env.isError, isFalse);
      expect(env.summary, 'tapped');
      expect(env.warnings, ['hint!']);
      expect(env.nextSteps, ['next']);
      expect(env.data?['ok'], isTrue);
    });

    test('marks failure with isError and surfaces errorKind name', () {
      final action = const Tap(SymbolicTarget('missing'));
      final result = ActionResult.failure(
        action: action,
        summary: 'no such id',
        errorKind: GlintErrorKind.unresolvedTarget,
        error: 'no such id',
      );
      final env = StructuredResponse.fromActionResult(result);
      expect(env.isError, isTrue);
      expect(env.data?['errorKind'], 'unresolvedTarget');
    });

    test('routes the failure reason to detail so renderText shows it', () {
      final result = ActionResult.failure(
        action: const Tap(SymbolicTarget('x')),
        summary: 'tap x',
        errorKind: GlintErrorKind.notHittable,
        error: 'an absorber covers the target',
      );
      final env = StructuredResponse.fromActionResult(result);
      expect(env.data?['detail'], 'an absorber covers the target');
      expect(env.data?.containsKey('error'), isFalse,
          reason: 'error is folded into detail, not duplicated');
      expect(env.renderText(), contains('detail: an absorber covers'));
    });

    test('does not duplicate summary/warnings/nextSteps inside data', () {
      final result = ActionResult.success(
        action: const Tap(SymbolicTarget('foo')),
        summary: 'tapped',
        warnings: const ['w'],
        nextSteps: const ['n'],
      );
      final data = StructuredResponse.fromActionResult(result).data!;
      expect(data.containsKey('summary'), isFalse);
      expect(data.containsKey('warnings'), isFalse);
      expect(data.containsKey('nextSteps'), isFalse);
      expect(data['ok'], isTrue, reason: 'ok stays — structuredContent needs it');
    });

    test('geometry stays out unless detail:true', () {
      final result = ActionResult.success(
        action: const Tap(SymbolicTarget('foo')),
        summary: 'tapped',
        physicalCenter: (x: 10, y: 20),
        devicePixelRatio: 3,
        painted: true,
        hittable: true,
      );
      final lean = StructuredResponse.fromActionResult(result).data!;
      expect(lean.containsKey('painted'), isFalse);
      expect(lean.containsKey('physicalCenter'), isFalse);
      final full = StructuredResponse.fromActionResult(result, detail: true).data!;
      expect(full['painted'], isTrue);
      expect(full['physicalCenter'], isNotNull);
    });
  });

  group('StructuredResponse copy helpers', () {
    final base = StructuredResponse(
      summary: 'ok',
      warnings: const ['w1'],
      nextSteps: const ['n1'],
      data: const {'a': 1},
    );

    test('copyWith replaces only the given fields', () {
      final c = base.copyWith(summary: 'changed', data: const {'b': 2});
      expect(c.summary, 'changed');
      expect(c.data, const {'b': 2});
      expect(c.warnings, const ['w1'], reason: 'untouched fields carry over');
      expect(c.nextSteps, const ['n1']);
    });

    test('mergeData unions into data, new keys win', () {
      final c = base.mergeData(const {'a': 9, 'b': 2});
      expect(c.data, const {'a': 9, 'b': 2});
      expect(c.summary, 'ok');
    });

    test('addWarnings appends; empty is a no-op returning the same instance', () {
      expect(base.addWarnings(const ['w2']).warnings, const ['w1', 'w2']);
      expect(identical(base.addWarnings(const []), base), isTrue);
    });
  });

  group('StructuredResponse.renderText', () {
    test('plain summary with no warnings or next steps', () {
      final r = StructuredResponse(summary: 'tapped fab');
      expect(r.renderText(), 'tapped fab');
    });

    test('appends sections in order: warnings, then next steps', () {
      final r = StructuredResponse(
        summary: 'tapped fab',
        warnings: const ['target not painted'],
        nextSteps: const ['try long_press'],
      );
      final text = r.renderText();
      expect(text, contains('warnings:'));
      expect(text, contains('  - target not painted'));
      expect(text, contains('next steps:'));
      expect(text, contains('  - try long_press'));
      expect(
        text.indexOf('warnings:') < text.indexOf('next steps:'),
        isTrue,
      );
    });
  });

  group('StructuredResponse.toCallResult', () {
    test('content carries text, structuredContent carries data', () {
      final r = StructuredResponse(
        summary: 'ok',
        data: const {'x': 1},
      );
      final call = r.toCallResult();
      expect(call.content.length, 1);
      expect(call.isError ?? false, isFalse);
      expect(call.structuredContent?['summary'], 'ok');
      expect(call.structuredContent?['x'], 1);
    });
  });
}
