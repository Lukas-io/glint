import 'package:dart_mcp/server.dart';

import '../../interaction.dart';

/// Common reply shape: [summary] + optional [warnings] + [nextSteps].
/// Renders both human text and `structuredContent` so callers can
/// branch on [data] instead of parsing prose.
class StructuredResponse {
  StructuredResponse({
    required this.summary,
    this.warnings = const [],
    this.nextSteps = const [],
    this.data,
    this.isError = false,
  });

  factory StructuredResponse.error({
    required String summary,
    required String errorKind,
    String? detail,
    List<String> nextSteps = const [],
  }) {
    return StructuredResponse(
      summary: summary,
      isError: true,
      data: {
        'errorKind': errorKind,
        if (detail != null) 'detail': detail,
      },
      nextSteps: nextSteps,
    );
  }

  factory StructuredResponse.fromActionResult(ActionResult r) {
    return StructuredResponse(
      summary: r.summary,
      warnings: r.warnings,
      nextSteps: r.nextSteps,
      isError: !r.ok,
      data: {
        ...r.toJson(),
      },
    );
  }

  final String summary;
  final List<String> warnings;
  final List<String> nextSteps;
  final Map<String, Object?>? data;
  final bool isError;

  String renderText() {
    final buf = StringBuffer(summary);
    if (warnings.isNotEmpty) {
      buf.writeln();
      buf.writeln();
      buf.writeln('warnings:');
      for (final w in warnings) {
        buf.writeln('  - $w');
      }
    }
    if (nextSteps.isNotEmpty) {
      if (warnings.isEmpty) buf.writeln();
      buf.writeln();
      buf.writeln('next steps:');
      for (final s in nextSteps) {
        buf.writeln('  - $s');
      }
    }
    return buf.toString().trimRight();
  }

  Map<String, Object?> toStructuredContent() => {
        'summary': summary,
        if (warnings.isNotEmpty) 'warnings': warnings,
        if (nextSteps.isNotEmpty) 'nextSteps': nextSteps,
        if (data != null) ...data!,
      };

  CallToolResult toCallResult() {
    return CallToolResult(
      content: [Content.text(text: renderText())],
      structuredContent: toStructuredContent(),
      isError: isError,
    );
  }
}
