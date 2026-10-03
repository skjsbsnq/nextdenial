// DeskCenter 网格布局引擎单元测试。
//
// 断言点等价于 NextKde 仓库
// `shell/desktop/modules/deskcenter/test_widget_layout.mjs`（43 行）：
// 7 种小部件 × 3 尺寸跨度、三尺寸下 4×8 网格全量装箱且不重叠、
// 4×3 矮网格丢弃低优先级项；另补 TASK-01 验收要求的精确跨度表、
// 行/列约束、空输入、未知 widgetId 兜底、normalizedSize 非法值。

import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/layout/widget_layout.dart';

/// 与 WidgetLayout.mjs:4 的 `ids` 一致的完整小部件清单。
const _ids = [
  'clock',
  'weather',
  'calendar',
  'todo',
  'system',
  'activity',
  'music',
];

/// 与 WidgetLayout.mjs:1 的 `sizeOrder` 一致。
const _sizeOrder = [WidgetSize.small, WidgetSize.medium, WidgetSize.large];

void main() {
  group('normalizedSize（WidgetLayout.mjs:13-15）', () {
    test('合法值原样归一', () {
      expect(normalizedSize('small'), WidgetSize.small);
      expect(normalizedSize('medium'), WidgetSize.medium);
      expect(normalizedSize('large'), WidgetSize.large);
    });

    test('非法值与 null 归一为 medium（源 String(size) 不在 sizeOrder）', () {
      expect(normalizedSize('huge'), WidgetSize.medium);
      expect(normalizedSize(''), WidgetSize.medium);
      expect(normalizedSize('SMALL'), WidgetSize.medium);
      expect(normalizedSize(null), WidgetSize.medium);
    });
  });

  group('spanFor（WidgetLayout.mjs:17-20 + variants:3-11）', () {
    // 逐字对照源 variants 表的完整期望值（7 种 × 3 尺寸）。
    const expected = <String, Map<WidgetSize, (int, int)>>{
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

    for (final id in _ids) {
      for (final size in _sizeOrder) {
        test('$id/$size 跨度与源表一致', () {
          final pair = spanFor(id, size);
          final want = expected[id]![size]!;
          expect(pair.columns, want.$1, reason: '$id/${size.name} columns');
          expect(pair.rows, want.$2, reason: '$id/${size.name} rows');
          // 源 test_widget_layout.mjs:9-10 的范围断言。
          expect(pair.columns, inInclusiveRange(1, 3));
          expect(pair.rows, inInclusiveRange(1, 2));
        });
      }
    }

    test('未知 widgetId 兜底 (1,1)（源 ?? [1,1]）', () {
      for (final size in _sizeOrder) {
        final pair = spanFor('unknown-widget', size);
        expect(pair.columns, 1);
        expect(pair.rows, 1);
      }
    });
  });

  group('packWidgets（WidgetLayout.mjs:22-63）', () {
    // 源 test_widget_layout.mjs:14-33：每种尺寸下 7 个小部件在 4×8
    // 网格全部放得下、在界内、互不重叠。
    for (final size in _sizeOrder) {
      test('${size.name}: 7 个小部件全部落位且不重叠', () {
        final definitions = [
          for (var index = 0; index < _ids.length; index++)
            WidgetDefinition(
              id: _ids[index],
              columns: spanFor(_ids[index], size).columns,
              rows: spanFor(_ids[index], size).rows,
              priority: 100 - index,
            ),
        ];
        final placements = packWidgets(
          definitions,
          columnCount: 4,
          rowCount: 8,
        );
        expect(
          placements.length,
          _ids.length,
          reason: '${size.name} widgets all fit',
        );
        // priority 降序：最高优先级（clock, 100）最先落位。
        expect(placements.first.id, 'clock');
        final cells = <String>{};
        for (final placement in placements) {
          for (
            var row = placement.row;
            row < placement.row + placement.rows;
            row++
          ) {
            for (
              var column = placement.column;
              column < placement.column + placement.columns;
              column++
            ) {
              expect(
                column,
                lessThan(4),
                reason: '${placement.id} remains in bounds',
              );
              expect(
                row,
                lessThan(8),
                reason: '${placement.id} remains in bounds',
              );
              final key = '$column:$row';
              expect(
                cells.contains(key),
                isFalse,
                reason: '${placement.id} does not overlap',
              );
              cells.add(key);
            }
          }
        }
      });
    }

    // 源 test_widget_layout.mjs:35-41：4×3 矮网格丢弃低优先级小部件，
    // 最高优先级的 clock 仍首先落位。
    test('矮网格丢弃低优先级小部件，最高优先级仍在首位', () {
      final definitions = [
        for (var index = 0; index < _ids.length; index++)
          WidgetDefinition(
            id: _ids[index],
            columns: spanFor(_ids[index], WidgetSize.large).columns,
            rows: spanFor(_ids[index], WidgetSize.large).rows,
            priority: 100 - index,
          ),
      ];
      final placements = packWidgets(definitions, columnCount: 4, rowCount: 3);
      expect(
        placements.length,
        lessThan(_ids.length),
        reason: 'short screens drop lower priority widgets',
      );
      expect(
        placements.first.id,
        'clock',
        reason: 'highest priority widget remains first',
      );
    });

    test('priority 降序排序：争夺同一位置时高优先级胜出', () {
      // 两者都被钉在 (0,0)，高优先级占位后低优先级无位可去。
      final placements = packWidgets(
        const [
          WidgetDefinition(
            id: 'low',
            priority: 1,
            columns: 4,
            rows: 4,
            row: 0,
            column: 0,
          ),
          WidgetDefinition(
            id: 'high',
            priority: 99,
            columns: 4,
            rows: 4,
            row: 0,
            column: 0,
          ),
        ],
        columnCount: 4,
        rowCount: 4,
      );
      expect(placements, hasLength(1));
      expect(placements.single.id, 'high');
      expect(placements.single.column, 0);
      expect(placements.single.row, 0);
    });

    test('平局保持稳定次序（JS sort 稳定性，WidgetLayout.mjs:23-24）', () {
      // 三个同优先级 4×4 全尺寸小部件争一个格位，先入表的胜出。
      final placements = packWidgets(
        const [
          WidgetDefinition(id: 'a', priority: 5, columns: 4, rows: 4),
          WidgetDefinition(id: 'b', priority: 5, columns: 4, rows: 4),
          WidgetDefinition(id: 'c', priority: 5, columns: 4, rows: 4),
        ],
        columnCount: 4,
        rowCount: 4,
      );
      expect(placements, hasLength(1));
      expect(placements.single.id, 'a');
    });

    test('row/column 约束收窄到指定行列（WidgetLayout.mjs:32-35）', () {
      final placements = packWidgets(
        const [
          WidgetDefinition(
            id: 'pinned',
            priority: 10,
            columns: 2,
            rows: 1,
            row: 3,
            column: 2,
          ),
        ],
        columnCount: 4,
        rowCount: 4,
      );
      expect(placements, hasLength(1));
      expect(placements.single.row, 3);
      expect(placements.single.column, 2);
    });

    test('row 约束与跨度越界时丢弃（源 firstRow=lastRow=row）', () {
      // rows=2 钉在最后一行（row=3, 网格 4 行）→ 越界放不下，丢弃。
      final placements = packWidgets(
        const [
          WidgetDefinition(
            id: 'overflow-row',
            priority: 10,
            columns: 1,
            rows: 2,
            row: 3,
          ),
        ],
        columnCount: 4,
        rowCount: 4,
      );
      expect(placements, isEmpty);
    });

    test('column 约束下水平不可行则丢弃', () {
      // columns=3 钉在 column=2（网格 4 列）→ 2+3>4，丢弃。
      final placements = packWidgets(
        const [
          WidgetDefinition(
            id: 'overflow-column',
            priority: 10,
            columns: 3,
            rows: 1,
            column: 2,
          ),
        ],
        columnCount: 4,
        rowCount: 4,
      );
      expect(placements, isEmpty);
    });

    test('空输入返回空结果', () {
      expect(packWidgets(const [], columnCount: 4, rowCount: 8), isEmpty);
    });
  });
}
