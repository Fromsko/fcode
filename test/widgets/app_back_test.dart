import 'package:fromsko_mobile/link/link_store.dart';
import 'package:fromsko_mobile/main.dart';
import 'package:fromsko_mobile/state/app_state.dart';
import 'package:fromsko_mobile/ui/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 冷启动时生命周期还没就绪，Flutter 会丢掉页面报的返回状态；应用记着它，
  // 生命周期一变就再报给系统，不然安卓按一下返回就退出。
  testWidgets('生命周期变化时把页面要接管返回键再报给系统', (tester) async {
    final handles = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
          handles.add(call.arguments);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final state = AppState(store: MemoryLinkStore(), demo: true);
    await state.initialize();
    await tester.pumpWidget(MobileApp(state: state));
    await tester.pump();
    expect(find.byType(HomeShell), findsOneWidget);

    handles.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(handles, isNotEmpty);
    expect(handles.every((handles) => handles == true), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
