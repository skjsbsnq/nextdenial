/// DeskCenter 网格布局引擎（纯 Dart，无 Flutter 依赖）。
///
/// 逐行移植自 NextKde 仓库
/// `shell/desktop/modules/deskcenter/WidgetLayout.mjs`（63 行），
/// 注释中的 `:N-M` 均为该源文件行号锚点。语义约束：同输入同输出，
/// 不得改变算法行为（docs/TASK-01-layout.md）。
library;

/// 小部件尺寸档位，对应源 `sizeOrder`（WidgetLayout.mjs:1）。
enum WidgetSize { small, medium, large }

/// 对应源 `normalizedSize`（WidgetLayout.mjs:13-15）：
/// 非法/缺失值一律归一为 [WidgetSize.medium]。
WidgetSize normalizedSize(String? size) => switch (size) {
  'small' => WidgetSize.small,
  'large' => WidgetSize.large,
  _ => WidgetSize.medium,
};

/// 尺寸表，逐项对应源 `variants`（WidgetLayout.mjs:3-11）。
const Map<String, Map<WidgetSize, (int, int)>> _variants = {
  'clock': {
    WidgetSize.small: (1, 1),
    WidgetSize.medium: (2, 1),
    WidgetSize.large: (2, 2),
  },
  'weather': {
    WidgetSize.small: (2, 1),
    WidgetSize.medium: (3, 1),
    WidgetSize.large: (3, 2),
  },
  'calendar': {
    WidgetSize.small: (1, 1),
    WidgetSize.medium: (2, 1),
    WidgetSize.large: (2, 2),
  },
  'todo': {
    WidgetSize.small: (1, 1),
    WidgetSize.medium: (2, 1),
    WidgetSize.large: (2, 2),
  },
  'system': {
    WidgetSize.small: (1, 1),
    WidgetSize.medium: (2, 1),
    WidgetSize.large: (2, 2),
  },
  'activity': {
    WidgetSize.small: (1, 1),
    WidgetSize.medium: (2, 1),
    WidgetSize.large: (2, 2),
  },
  'music': {
    WidgetSize.small: (1, 1),
    WidgetSize.medium: (2, 1),
    WidgetSize.large: (2, 2),
  },
};

/// 对应源 `spanFor`（WidgetLayout.mjs:17-20）：返回 `(columns, rows)`；
/// 未知 widgetId 或尺寸表缺项兜底 `(1, 1)`（源 `?? [1,1]`）。
({int columns, int rows}) spanFor(String widgetId, WidgetSize size) {
  final pair = _variants[widgetId]?[size] ?? (1, 1);
  return (columns: pair.$1, rows: pair.$2);
}

/// `packWidgets` 的输入项（源定义项 `{id, columns, rows, priority,
/// row?, column?}`，WidgetLayout.mjs:22、30-35）。
final class WidgetDefinition {
  const WidgetDefinition({
    required this.id,
    required this.priority,
    required this.columns,
    required this.rows,
    this.row,
    this.column,
  });

  final String id;

  /// 排序键：降序，高优先级先占位（WidgetLayout.mjs:23-24）。
  final int priority;

  /// 横向跨度（格数）。
  final int columns;

  /// 纵向跨度（格数）。
  final int rows;

  /// 可选行约束：非 null 时只在该行尝试放置（源 `widget.row`，
  /// WidgetLayout.mjs:32-33）；null = 扫描全部可行行。
  final int? row;

  /// 可选列约束：非 null 时只在该列尝试放置（源 `widget.column`，
  /// WidgetLayout.mjs:34-35）；null = 扫描全部可行列。
  final int? column;
}

/// `packWidgets` 的输出项（源 `result.push({id, column, row, columns,
/// rows})`，WidgetLayout.mjs:56-57）。
final class WidgetPlacement {
  const WidgetPlacement({
    required this.id,
    required this.column,
    required this.row,
    required this.columns,
    required this.rows,
  });

  final String id;

  /// 落位左上角列索引。
  final int column;

  /// 落位左上角行索引。
  final int row;

  final int columns;
  final int rows;

  @override
  bool operator ==(Object other) =>
      other is WidgetPlacement &&
      other.id == id &&
      other.column == column &&
      other.row == row &&
      other.columns == columns &&
      other.rows == rows;

  @override
  int get hashCode => Object.hash(id, column, row, columns, rows);

  @override
  String toString() =>
      'WidgetPlacement($id, column: $column, row: $row, '
      '${columns}x$rows)';
}

/// 对应源 `packWidgets`（WidgetLayout.mjs:22-63）：priority 降序的
/// 首次适配（first-fit）装箱。
///
/// - 按 priority 降序排序，平局保持原相对顺序（与源 `slice().sort()`
///   的稳定性一致，WidgetLayout.mjs:23-24；Dart `List.sort` 不稳定，
///   故显式补下标次序）；
/// - `row`/`column` 约束非 null 时只尝试该一行/一列，否则扫全范围
///   （WidgetLayout.mjs:32-35）；
/// - 逐格检查占用矩阵，越界或已占用即跳过（WidgetLayout.mjs:38-50）；
/// - 放得下即写入占位并记录 placement（WidgetLayout.mjs:53-58）；
/// - 所有候选位置都不适配则丢弃该项（源行为：不 push 即丢弃）。
List<WidgetPlacement> packWidgets(
  List<WidgetDefinition> definitions, {
  required int columnCount,
  required int rowCount,
}) {
  // WidgetLayout.mjs:23-24 —— priority 降序排序（拷贝入参再排）。
  // JS `Array.prototype.sort` 稳定而 Dart `List.sort` 不稳定：
  // 显式带下标作 tiebreak，平局保持原相对顺序，行为逐行等价。
  final indexed =
      <({WidgetDefinition def, int index})>[
        for (var i = 0; i < definitions.length; i++)
          (def: definitions[i], index: i),
      ]..sort((left, right) {
        final byPriority = right.def.priority.compareTo(left.def.priority);
        return byPriority != 0 ? byPriority : left.index.compareTo(right.index);
      });
  final sorted = [for (final entry in indexed) entry.def];

  // WidgetLayout.mjs:25-28 —— 占用矩阵 occupied[row][column]。
  final occupied = List<List<bool>>.generate(
    rowCount,
    (_) => List<bool>.filled(columnCount, false),
    growable: false,
  );
  final result = <WidgetPlacement>[];

  // WidgetLayout.mjs:30-61 —— 逐 widget 首次适配。
  for (final widget in sorted) {
    var placed = false;
    // WidgetLayout.mjs:32-35 —— row/column 约束收窄扫描范围。
    final firstRow = widget.row ?? 0;
    final lastRow = widget.row ?? (rowCount - widget.rows);
    final firstColumn = widget.column ?? 0;
    final lastColumn = widget.column ?? (columnCount - widget.columns);
    for (var row = firstRow; row <= lastRow && !placed; row++) {
      for (
        var column = firstColumn;
        column <= lastColumn && !placed;
        column++
      ) {
        // WidgetLayout.mjs:38-50 —— 候选矩形逐格校验。
        var fits = true;
        for (var y = row; y < row + widget.rows && fits; y++) {
          if (y < 0 || y >= rowCount) {
            fits = false;
            break;
          }
          for (var x = column; x < column + widget.columns; x++) {
            if (x < 0 || x >= columnCount || occupied[y][x]) {
              fits = false;
              break;
            }
          }
        }
        if (!fits) continue;
        // WidgetLayout.mjs:53-55 —— 占位。
        for (var y = row; y < row + widget.rows; y++) {
          for (var x = column; x < column + widget.columns; x++) {
            occupied[y][x] = true;
          }
        }
        // WidgetLayout.mjs:56-58 —— 记录 placement。
        result.add(
          WidgetPlacement(
            id: widget.id,
            column: column,
            row: row,
            columns: widget.columns,
            rows: widget.rows,
          ),
        );
        placed = true;
      }
    }
    // 放不下即丢弃（源不 push）。
  }
  return result;
}
