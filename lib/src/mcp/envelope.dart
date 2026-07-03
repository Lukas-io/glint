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
    required GlintErrorKind errorKind,
    String? detail,
    List<String> nextSteps = const [],
  }) {
    return StructuredResponse(
      summary: summary,
      isError: true,
      data: {
        'errorKind': errorKind.name,
        if (detail != null) 'detail': detail,
      },
      nextSteps: nextSteps,
    );
  }

  /// Builds a response from an [ActionResult]. The envelope already carries
  /// `summary`/`warnings`/`nextSteps` at the top level, so those are dropped
  /// from `data` rather than duplicated. Geometry (painted, hittable,
  /// physicalCenter) is omitted unless [detail] is true — the agent only needs
  /// `ok` + the changed-signal to continue. The failure reason is routed to the
  /// shared `detail` key so it surfaces in prose and the action log.
  factory StructuredResponse.fromActionResult(
    ActionResult r, {
    bool detail = false,
  }) {
    const dup = {'summary', 'warnings', 'nextSteps', 'error'};
    const geometry = {'painted', 'hittable', 'physicalCenter'};
    final data = <String, Object?>{
      for (final e in r.toJson().entries)
        if (!dup.contains(e.key) && (detail || !geometry.contains(e.key)))
          e.key: e.value,
    };
    if (r.error != null) data['detail'] = r.error;
    return StructuredResponse(
      summary: r.summary,
      warnings: r.warnings,
      nextSteps: r.nextSteps,
      isError: !r.ok,
      data: data,
    );
  }

  final String summary;
  final List<String> warnings;
  final List<String> nextSteps;
  final Map<String, Object?>? data;
  final bool isError;

  /// Returns a copy with the given fields replaced — so callers augmenting a
  /// response don't re-list all five fields by hand.
  StructuredResponse copyWith({
    String? summary,
    List<String>? warnings,
    List<String>? nextSteps,
    Map<String, Object?>? data,
    bool? isError,
  }) =>
      StructuredResponse(
        summary: summary ?? this.summary,
        warnings: warnings ?? this.warnings,
        nextSteps: nextSteps ?? this.nextSteps,
        data: data ?? this.data,
        isError: isError ?? this.isError,
      );

  /// Merges [extra] into [data] (extra keys win).
  StructuredResponse mergeData(Map<String, Object?> extra) =>
      copyWith(data: {...?data, ...extra});

  /// Appends [extra] to [warnings] (no-op when empty).
  StructuredResponse addWarnings(List<String> extra) =>
      extra.isEmpty ? this : copyWith(warnings: [...warnings, ...extra]);

  String renderText() {
    final buf = StringBuffer(summary);
    // Surface the first line of detail on errors so agents see the real reason
    // without having to parse structuredContent.
    if (isError) {
      final detail = data?['detail'] as String?;
      if (detail != null) {
        final firstLine = detail.split('\n').first.trim();
        if (firstLine.isNotEmpty && firstLine != summary) {
          buf.writeln();
          buf.writeln('detail: $firstLine');
        }
      }
    }
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
