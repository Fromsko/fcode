import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:baocode_mobile/chat/widgets/message_pictures.dart';
import 'package:baocode_mobile/link/link_store.dart';
import 'package:baocode_mobile/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _State extends AppState {
  _State() : super(store: MemoryLinkStore(), demo: true) {
    settings.language = 'zh';
  }
  final asked = <Map<String, Object?>>[];

  @override
  Future<Object?> request(
    String desktopId,
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    asked.add({'method': method, ...params});
    // 1×1 的透明 PNG。
    return {
      'type': 'image/png',
      'data': base64Encode(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
        ),
      ),
    };
  }
}

Future<_State> _pump(WidgetTester tester, String path) async {
  final state = _State();
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ProjectPicture(
          state: state,
          desktopId: 'd',
          projectId: 'p',
          path: path,
          label: '截图',
        ),
      ),
    ),
  );
  return state;
}

void main() {
  testWidgets('电脑上的 Windows 路径能点开加载，不当成外部链接', (tester) async {
    final state = await _pump(tester, 'C:/Users/me/AppData/Local/Temp/a.png');
    await tester.tap(find.text('加载图片：截图'));
    await tester.pumpAndSettle();
    expect(state.asked.single['method'], LinkMethods.image);
    expect(state.asked.single['path'], 'C:/Users/me/AppData/Local/Temp/a.png');
    expect(find.byType(MemoryPicture), findsOneWidget);
  });

  testWidgets('别的协议的地址仍然点不了', (tester) async {
    final state = await _pump(tester, 'ftp://host/a.png');
    await tester.tap(find.text('加载图片：截图'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(state.asked, isEmpty);
  });
}
