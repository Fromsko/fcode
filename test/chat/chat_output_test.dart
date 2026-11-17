// YCode — GPL-3.0-only.
import 'package:baocode_mobile/chat/chat_models.dart';
import 'package:baocode_mobile/chat/chat_output.dart';
import 'package:baocode_mobile/chat/step_folds.dart';
import 'package:baocode_mobile/chat/widgets/fold_line.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ToolCallItem _read(String target) => ToolCallItem(
  kind: ToolKind.read,
  tool: 'read',
  target: target,
  status: ToolStatus.succeeded,
);

CodeDiffItem _edit(String file, {int added = 1, int removed = 0}) =>
    CodeDiffItem(
      fileName: file,
      directory: 'lib',
      lines: const [],
      added: added,
      removed: removed,
    );

void main() {
  test('运行中的状态行和电脑一样，按上一步挑状态词：刚操作完浏览器就想浏览器', () {
    LiveStatusItem? liveAfter(ChatItem last) {
      final rows = foldRows(
        [
          const UserMessageItem(text: '看看页面'),
          last,
          const LiveStatusItem('Planning next move', whimsical: true),
        ],
        live: true,
        isOpen: (_) => true,
      );
      return rows.map((row) => row.shown).whereType<LiveStatusItem>().single;
    }

    expect(
      liveAfter(
        const ToolCallItem(kind: ToolKind.browser, tool: 'browser', target: ''),
      )?.cue?.topic,
      MusingTopic.browser,
    );
    // 上一步还在跑或是回答文字时，没有可想的，随便挑。
    expect(
      liveAfter(
        const ToolCallItem(
          kind: ToolKind.browser,
          tool: 'browser',
          target: '',
          status: ToolStatus.running,
        ),
      )?.cue,
      isNull,
    );
    expect(liveAfter(const AssistantTextItem('马上好'))?.cue, isNull);
  });

  test('运行中连续三个以上编辑合成一行，展开后逐个显示', () {
    final items = <ChatItem>[
      const UserMessageItem(text: '改一下'),
      _edit('a.dart', added: 8),
      _edit('b.dart', added: 2, removed: 2),
      _edit('c.dart', added: 24, removed: 1),
      const AssistantTextItem('在跑测试'),
    ];
    final closed = foldRows(items, live: true, isOpen: (_) => false);
    expect(closed, hasLength(3));
    final line = closed[1];
    expect(line.edits, isNotNull);
    expect(line.edits!.start, 1);
    expect(line.edits!.end, 4);
    expect(line.foldItems.whereType<CodeDiffItem>().map((e) => e.fileName), [
      'a.dart',
      'b.dart',
      'c.dart',
    ]);

    final open = foldRows(
      items,
      live: true,
      isOpen: (fold) => fold.key == line.edits!.key,
    );
    expect(open, hasLength(6));
    expect([
      for (final row in open.skip(2).take(3)) row.shown,
    ], everyElement(isA<CodeDiffItem>()));
  });

  test('两个编辑不合并', () {
    final rows = foldRows(
      [const UserMessageItem(text: '改一下'), _edit('a.dart'), _edit('b.dart')],
      live: true,
      isOpen: (_) => false,
    );
    expect(rows.where((row) => row.edits != null), isEmpty);
    expect(rows.where((row) => row.shown is CodeDiffItem), hasLength(2));
  });

  test('consecutive quiet steps fold into one row', () {
    final rows = foldRows(
      [
        const UserMessageItem(text: '看看'),
        _read('a.dart'),
        _read('b.dart'),
        const ToolCallItem(
          kind: ToolKind.grep,
          tool: 'grep',
          target: 'LinkMethods',
          status: ToolStatus.succeeded,
        ),
        const AssistantTextItem('完了'),
      ],
      live: false,
      isOpen: (_) => false,
    );
    // The answer's row, the fold's line, and the user message; the folded
    // steps have no rows of their own while closed.
    expect(rows.length, 3);
    final fold = rows[1];
    expect(fold.isFold, isTrue);
    expect(fold.steps, isNotNull);
    expect(fold.index, 1);
    expect(fold.foldItems, hasLength(3));
    expect(rows[2].shown, isA<AssistantTextItem>());
  });

  test('edits, subagents and single steps stay individual', () {
    final rows = foldRows(
      [
        _read('a.dart'),
        const ToolCallItem(
          kind: ToolKind.read,
          tool: 'read',
          target: 'with-output',
          status: ToolStatus.succeeded,
          output: 'void main() {}',
        ),
        const ToolCallItem(
          kind: ToolKind.edit,
          tool: 'edit',
          target: 'a.dart',
          status: ToolStatus.succeeded,
        ),
        const AgentItem(
          description: 'Explore',
          status: CommandStatus.succeeded,
        ),
      ],
      live: false,
      isOpen: (_) => false,
    );
    // The two reads fold together even with output on one (the desktop
    // run does not split on payloads); the edit and the subagent stand
    // apart, as they break a run.
    expect(rows.length, 3);
    expect(rows[0].isFold, isTrue);
    expect(rows[0].foldItems, hasLength(2));
    expect(rows[1].shown, isA<ToolCallItem>());
    expect(rows[2].shown, isA<AgentItem>());
  });

  test('raw wire maps (as the buffer stores them) fold too', () {
    final rows = foldRows(
      [
        {
          't': 'tool',
          'kind': 'grep',
          'tool': 'grep',
          'target': 'print(',
          'status': 'succeeded',
          'results': ['lib/main.dart:1'],
        },
        {
          't': 'tool',
          'kind': 'listDir',
          'target': 'lib',
          'status': 'succeeded',
        },
      ],
      live: false,
      isOpen: (_) => false,
    );
    expect(rows.length, 1);
    expect(rows.first.isFold, isTrue);
    expect(rows.first.foldItems, hasLength(2));
  });

  test('an open fold keeps every step as its own row', () {
    final rows = foldRows(
      [_read('a.dart'), _read('b.dart'), const AssistantTextItem('完了')],
      live: false,
      isOpen: (fold) => fold.kind == StepFoldKind.steps,
    );
    expect(rows.length, 4);
    expect(rows[0].isFold, isTrue, reason: 'the fold line still leads');
    expect(
      [
        for (final row in rows.skip(1).take(2))
          (row.shown as ToolCallItem).target,
      ],
      ['a.dart', 'b.dart'],
      reason: '展开后第一个步骤也有自己的一行',
    );
    expect(rows[1].isFold, isFalse);
    expect(rows[1].index, 0);
  });

  test('已处理和步骤折叠从同一处开始时各占一行，各按各的开合', () {
    final items = <ChatItem>[
      const UserMessageItem(text: '看看', worked: Duration(seconds: 30)),
      _read('a.dart'),
      _read('b.dart'),
      _edit('c.dart'),
      const AssistantTextItem('完了'),
    ];
    final open = <(StepFoldKind, int)>{(StepFoldKind.work, 1)};
    var rows = foldRows(
      items,
      live: false,
      isOpen: (f) => open.contains(f.key),
    );
    final lines = rows.where((row) => row.isFold).toList();
    expect(
      [for (final row in lines) (row.work?.key, row.steps?.key)],
      [((StepFoldKind.work, 1), null), (null, (StepFoldKind.steps, 1))],
    );
    expect(
      rows.where((row) => !row.isFold && row.shown is ToolCallItem),
      isEmpty,
      reason: '步骤折叠还关着，里面的步骤不单独成行',
    );

    open.add((StepFoldKind.steps, 1));
    rows = foldRows(items, live: false, isOpen: (f) => open.contains(f.key));
    expect(
      [
        for (final row in rows)
          if (!row.isFold && row.shown is ToolCallItem)
            (row.shown as ToolCallItem).target,
      ],
      ['a.dart', 'b.dart'],
    );
  });

  test('a live run shows its under-way step while folded', () {
    final rows = foldRows(
      [
        _read('a.dart'),
        _read('b.dart'),
        const ToolCallItem(
          kind: ToolKind.read,
          tool: 'read',
          target: 'busy',
          status: ToolStatus.running,
        ),
      ],
      live: true,
      isOpen: (_) => false,
    );
    expect(rows.length, 2);
    expect(rows[0].isFold, isTrue);
    expect(rows[1].shown, isA<ToolCallItem>());
    expect(
      (rows[1].shown! as ToolCallItem).target,
      'busy',
      reason: 'the run grows at its end; its last step shows as it goes',
    );
  });

  testWidgets('the steps line counts the run and opens to the cards', (
    tester,
  ) async {
    final strings = FoldStrings(false);
    var expanded = false;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                StepsFoldLine(
                  tally: StepTally([
                    _read('a.dart'),
                    _read('b.dart'),
                    const ToolCallItem(
                      kind: ToolKind.grep,
                      tool: 'grep',
                      target: 'LinkMethods',
                      status: ToolStatus.succeeded,
                    ),
                  ]),
                  expanded: expanded,
                  onToggle: () => setState(() => expanded = !expanded),
                  strings: strings,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Read 2 times'), findsOneWidget);
    expect(find.textContaining('a.dart'), findsNothing);
    await tester.tap(find.textContaining('Read 2 times'));
    await tester.pumpAndSettle();
    // The line itself carries the counts; opening is the caller's business
    // (the cards render under it, outside this widget).
    expect(find.textContaining('searched once'), findsOneWidget);
  });

  testWidgets('the work line says how long the turn worked', (tester) async {
    final strings = FoldStrings(false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkFoldLine(
            worked: const Duration(minutes: 4, seconds: 32),
            edits: (count: 2, added: 12, removed: 3),
            expanded: false,
            onToggle: () {},
            strings: strings,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Worked for 4m 32s'), findsOneWidget);
    expect(find.textContaining('edited 2 times +12 -3'), findsOneWidget);
  });

  test('同一文件改两次、读两段，都按次数算', () {
    final items = [
      _edit('a.dart', added: 3),
      _edit('a.dart', added: 2, removed: 1),
      _read('b.dart'),
      _read('b.dart'),
    ];
    expect(turnEdits(items), (count: 2, added: 5, removed: 1));
    expect(StepTally(items).counts[StepAction.read], 2);
    expect(
      StepsFoldLine.text(StepTally(items), strings: FoldStrings(true)),
      '读取 2 次',
    );
  });

  group('pendingPlans', () {
    PlanItem plan(int round, [PlanStatus status = PlanStatus.awaiting]) =>
        PlanItem(path: 'plan.md', round: round, status: status);

    test('只有最近那条还在等、之后没再说话的计划算数', () {
      final result = pendingPlans([
        plan(1),
        const UserMessageItem(text: '再改改'),
        plan(2),
        const AssistantTextItem('你看下计划'),
      ]);
      expect(result.pending, 2);
      expect((result.items[0] as PlanItem).status, PlanStatus.expired);
      expect((result.items[2] as PlanItem).status, PlanStatus.awaiting);
    });

    test('计划后面用户又发了话，就没有在等的', () {
      final result = pendingPlans([plan(1), const UserMessageItem(text: '继续')]);
      expect(result.pending, isNull);
      expect((result.items[0] as PlanItem).status, PlanStatus.expired);
    });

    test('电脑说过不在等的那条也不算；其他状态原样不动', () {
      final latest = plan(2);
      final result = pendingPlans(
        [plan(1, PlanStatus.approved), latest],
        lost: {planKey(latest)},
      );
      expect(result.pending, isNull);
      expect((result.items[0] as PlanItem).status, PlanStatus.approved);
      expect((result.items[1] as PlanItem).status, PlanStatus.expired);
    });
  });

  group('停止的回合', () {
    UserMessageItem prompt({bool stopped = false}) => UserMessageItem(
      text: '改一下',
      worked: const Duration(minutes: 1, seconds: 5),
      stopped: stopped,
    );
    StepFolds fold(List<ChatItem> items) =>
        StepFolds.of(items.length, (i) => items[i], live: false);

    test('没有回答也整段折叠，停止原因留在折叠外', () {
      final folds = fold([
        prompt(stopped: true),
        _read('a.dart'),
        _edit('b.dart'),
        const NoticeItem(NoticeKind.error, '已中断'),
      ]);
      final work = folds.workAt(1)!;
      expect((work.start, work.end, work.stopped), (1, 3, true));
      expect(folds.workAt(3), isNull);
    });

    test('有回答时照常折叠到回答前，并带上停止标记', () {
      final folds = fold([
        prompt(stopped: true),
        _read('a.dart'),
        _edit('b.dart'),
        const AssistantTextItem('先改到这里'),
      ]);
      final work = folds.workAt(1)!;
      expect((work.start, work.end, work.stopped), (1, 3, true));
    });

    test('没有停止也没有回答的回合保持展开', () {
      final folds = fold([prompt(), _read('a.dart'), _edit('b.dart')]);
      expect(folds.workAt(1), isNull);
    });

    test('Bot 聊天的处理行也带上停止标记', () {
      final rows = botRows([
        {'t': 'user', 'text': '查一下', 'worked': 65000, 'stopped': true},
        {
          't': 'tool',
          'kind': 'read',
          'target': 'a.dart',
          'status': 'succeeded',
        },
        {'t': 'text', 'text': '先查到这里'},
      ]);
      expect(rows.singleWhere((row) => row.isFold).work!.stopped, isTrue);
    });

    testWidgets('折叠行写明处理多久后停止', (tester) async {
      const worked = Duration(minutes: 1, seconds: 5);
      const none = (count: 0, added: 0, removed: 0);
      expect(
        WorkFoldLine.text(
          worked,
          none,
          stopped: true,
          strings: FoldStrings(true),
        ),
        '处理 1分5秒 后停止',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkFoldLine(
              worked: worked,
              edits: none,
              expanded: false,
              onToggle: () {},
              stopped: true,
              strings: FoldStrings(false),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Stopped after 1m 5s'), findsOneWidget);
      expect(find.textContaining('Worked for'), findsNothing);
    });
  });
}
