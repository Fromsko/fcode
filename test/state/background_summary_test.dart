import 'package:bao_link/bao_link.dart' show LinkSessionStatus;
import 'package:fromsko_mobile/state/background_summary.dart';
import 'package:flutter_test/flutter_test.dart';

String zh(String zh, String en) => zh;

BackgroundConversation session(
  String id, {
  String desktop = 'd1',
  String title = '重构登录页',
  LinkSessionStatus status = LinkSessionStatus.idle,
  BackgroundWait? wait,
  int minutes = 0,
}) => BackgroundConversation(
  desktopId: desktop,
  sessionId: id,
  title: title,
  updatedAt: DateTime(2026).add(Duration(minutes: minutes)),
  status: status,
  wait: wait,
);

const desk = (id: 'd1', name: 'MacBook', online: true);

void main() {
  group('等你的优先', () {
    test('一个在等：标题报数，正文说哪段、等什么', () {
      final summary = summarizeBackground(
        desktops: [desk],
        conversations: [
          session('a', wait: BackgroundWait.approval),
          session('b', status: LinkSessionStatus.running, minutes: 5),
        ],
        tr: zh,
      );
      expect(summary.title, '1 个对话在等你');
      expect(summary.body, '重构登录页 · 待批准');
      expect(summary.shortText, '待批准');
      expect(summary.target, (desktopId: 'd1', sessionId: 'a'));
    });

    test('多个在等：按批准、回答、待查看的急迫程度挑一个', () {
      final summary = summarizeBackground(
        desktops: [desk],
        conversations: [
          session('done', wait: BackgroundWait.done, minutes: 9),
          session('answer', wait: BackgroundWait.question, minutes: 7),
        ],
        tr: zh,
      );
      expect(summary.title, '2 个对话在等你');
      expect(summary.body, '重构登录页 · 待回答');
      expect(summary.target?.sessionId, 'answer');
    });

    test('同在等批准时，最近更新的那段优先', () {
      final summary = summarizeBackground(
        desktops: [desk],
        conversations: [
          session('old', title: '旧对话', wait: BackgroundWait.approval),
          session(
            'new',
            title: '新对话',
            wait: BackgroundWait.approval,
            minutes: 3,
          ),
        ],
        tr: zh,
      );
      expect(summary.body, '新对话 · 待批准');
      expect(summary.target?.sessionId, 'new');
    });

    test('跑着的对话排在等你的后面', () {
      final summary = summarizeBackground(
        desktops: [desk],
        conversations: [
          session('run', status: LinkSessionStatus.running, minutes: 30),
          session('wait', wait: BackgroundWait.question, minutes: 1),
        ],
        tr: zh,
      );
      expect(summary.title, '1 个对话在等你');
    });
  });

  group('没有在等的', () {
    test('一个在跑：正文是最近活跃的那段', () {
      final summary = summarizeBackground(
        desktops: [desk],
        conversations: [
          session(
            'old',
            title: '旧对话',
            status: LinkSessionStatus.running,
            minutes: 1,
          ),
          session(
            'new',
            title: '新对话',
            status: LinkSessionStatus.running,
            minutes: 10,
          ),
        ],
        tr: zh,
      );
      expect(summary.title, '2 个对话运行中');
      expect(summary.body, '新对话');
      expect(summary.shortText, '运行中');
      expect(summary.target, (desktopId: 'd1', sessionId: 'new'));
    });

    test('都闲着：只说已连接', () {
      final summary = summarizeBackground(
        desktops: [desk],
        conversations: [session('a')],
        tr: zh,
      );
      expect(summary.title, 'Fromsko 已连接');
      expect(summary.body, '没有在跑的对话');
      expect(summary.shortText, '在线');
      expect(summary.target, isNull);
    });

    test('电脑离线：报离线而不是说没在跑', () {
      final summary = summarizeBackground(
        desktops: [(id: 'd1', name: 'MacBook', online: false)],
        conversations: [
          session('a', status: LinkSessionStatus.running, wait: null),
        ],
        tr: zh,
      );
      expect(summary.title, 'Fromsko 后台连接');
      expect(summary.body, '电脑离线，正在重连');
      expect(summary.shortText, '离线');
      expect(summary.target, isNull);
    });

    test('还没配对电脑：说清楚', () {
      final summary = summarizeBackground(
        desktops: const [],
        conversations: const [],
        tr: zh,
      );
      expect(summary.body, '还没有配对电脑');
      expect(summary.target, isNull);
    });
  });

  group('多台电脑', () {
    test('正文带上电脑名，离线电脑上的对话不算', () {
      final summary = summarizeBackground(
        desktops: const [
          desk,
          (id: 'd2', name: '家里的电脑', online: false),
        ],
        conversations: [
          session('a', wait: BackgroundWait.approval),
          session(
            'b',
            desktop: 'd2',
            title: '离线对话',
            wait: BackgroundWait.approval,
            minutes: 20,
          ),
        ],
        tr: zh,
      );
      expect(summary.body, '重构登录页 · MacBook · 待批准');
      expect(summary.target?.desktopId, 'd1');
    });

    test('只有一台电脑时不带电脑名', () {
      final summary = summarizeBackground(
        desktops: [desk],
        conversations: [session('a', wait: BackgroundWait.approval)],
        tr: zh,
      );
      expect(summary.body, '重构登录页 · 待批准');
    });
  });

  test('英文走 tr 的另一半', () {
    final summary = summarizeBackground(
      desktops: [desk],
      conversations: [
        session('a', wait: BackgroundWait.question),
        session('b', wait: BackgroundWait.done),
      ],
      tr: (zh, en) => en,
    );
    expect(summary.title, '2 conversations waiting for you');
    expect(summary.body, '重构登录页 · Answer');
  });

  test('标题太长会截断，锁屏上放得下', () {
    final running = summarizeBackground(
      desktops: [desk],
      conversations: [
        session(
          'a',
          title: '一个特别特别长特别特别长特别特别长的对话标题用来测试截断是否生效',
          status: LinkSessionStatus.running,
        ),
      ],
      tr: zh,
    );
    expect(running.body.runes.length, lessThanOrEqualTo(28));
    expect(running.body, endsWith('…'));
  });

  test('参数带着目标，同一个摘要相等', () {
    final one = summarizeBackground(
      desktops: [desk],
      conversations: [
        session('a', wait: BackgroundWait.approval),
      ],
      tr: zh,
    );
    final two = summarizeBackground(
      desktops: [desk],
      conversations: [
        session('a', wait: BackgroundWait.approval),
      ],
      tr: zh,
    );
    expect(one, two);
    expect(one.toArguments(), {
      'title': '1 个对话在等你',
      'body': '重构登录页 · 待批准',
      'shortText': '待批准',
      'desktopId': 'd1',
      'sessionId': 'a',
    });
  });
}
