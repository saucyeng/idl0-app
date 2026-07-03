import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../providers/workspace_provider.dart';
import 'chart_workspace.dart';
import 'workbook_bar.dart';

/// Root widget for Tab 4 — Analyze. See §15.5.
///
/// Composes a [WorkbookBar] (workbook/worksheet selector) above a
/// [ChartWorkspace] (chart area). The workspace is keyed on the active
/// worksheet's stable UUID so that switching worksheets disposes and rebuilds
/// [ChartWorkspace], resetting its scroll position.
class AnalyzeTab extends ConsumerWidget {
  /// Creates [AnalyzeTab].
  const AnalyzeTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final worksheetId =
        ref.watch(workspaceProvider).activeWorksheet.id;

    return Column(
      children: [
        const WorkbookBar(),
        Expanded(
          child: ChartWorkspace(
            key: ValueKey(worksheetId),
          ),
        ),
      ],
    );
  }
}
