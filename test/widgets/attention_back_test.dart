import 'package:bao_link/bao_link.dart';
import 'package:baocode_mobile/link/link_store.dart';
import 'package:baocode_mobile/link/phone_link.dart' show KeptDesktop;
import 'package:baocode_mobile/state/app_state.dart';
import 'package:baocode_mobile/ui/widgets/mobile_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _State extends AppState {
  _State() : super(store: MemoryLinkStore()) {
    settings
      ..language = 'zh'
      ..desktop = '甲';
  }
  var status = LinkSessionStatus.needsInput;

  @override
  List<KeptDesktop> get desktops => const [
    KeptDesktop(id: '甲', name: '电脑甲', publicKey: ''),
  ];

  void settle() {
    status = LinkSessionStatus.running;
    notifyListeners();
  }

  @override
  List<SessionRef> get sessions => [
    SessionRef(
      '甲',
      SessionSummary(
        id: '1',
        project: 'p',
        title: '别的对话',
        updatedAt: DateTime(2026, 11, 15),
        status: status,
      ),
    ),
  ];
}

void main() {
  testWidgets('返回键在别处有对话等着时带小点，没了就收起，按下照常返回', (tester) async {
    final state = _State();
    addTearDown(state.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Text('列表')),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(leading: AttentionBackButton(state: state)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Badge badge() => tester.widget<Badge>(
      find.descendant(
        of: find.byKey(const ValueKey('attention-back')),
        matching: find.byType(Badge),
      ),
    );
    expect(badge().isLabelVisible, isTrue);

    state.settle();
    await tester.pump();
    expect(badge().isLabelVisible, isFalse);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('列表'), findsOneWidget);
  });
}
