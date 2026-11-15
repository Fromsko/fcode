import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_link/bao_link.dart';
import 'package:baocode_mobile/link/link_store.dart';
import 'package:baocode_mobile/models/user_facing_error.dart';
import 'package:baocode_mobile/state/app_state.dart';
import 'package:baocode_mobile/state/upload_file.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _State extends AppState {
  _State() : super(store: MemoryLinkStore());
  @override
  String tr(String zh, String en) => zh;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('local.baocode.mobile/platform');
  late _State state;
  setUp(() => state = _State());
  tearDown(() {
    state.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('系统选择取消不返回文件，也不调用上传', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pickUploadFile');
          return null;
        });
    expect(await pickUploadFile(state), isNull);
  });

  test('选择器只使用文件名和原始字节，拒绝超限及原生超限错误', () async {
    Object? response = {'name': '合成.pdf', 'bytes': Uint8List(8 * 1024 * 1024)};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          if (response is PlatformException) throw response;
          return response;
        });
    expect((await pickUploadFile(state))!.bytes.length, LinkLimits.upload);
    response = {'name': '合成.pdf', 'bytes': Uint8List(LinkLimits.upload + 1)};
    await expectLater(
      pickUploadFile(state),
      throwsA(
        isA<UserFacingError>().having(
          (e) => e.message,
          '中文上限',
          contains('8 MiB'),
        ),
      ),
    );
    response = PlatformException(code: 'upload_too_large', message: '内部路径不得回显');
    await expectLater(
      pickUploadFile(state),
      throwsA(
        isA<UserFacingError>().having(
          (e) => e.message,
          '中文上限',
          '单个文件不能超过 8 MiB。',
        ),
      ),
    );
  });

  test('真实Peer上传恰好8MiB原始字节，project参数及SSH路径保持原样', () async {
    final (client, server) = MemoryLinkConnection.pair();
    var requests = 0;
    final accepting = LinkPeer.accept(
      server,
      onRequest: (method, params) {
        requests++;
        expect(method, LinkMethods.upload);
        expect(params.keys.toSet(), {'project', 'name', 'data'});
        expect(params['project'], '合成项目');
        expect(params['name'], '合成日志.log');
        final bytes = base64Decode(params['data'] as String);
        expect(bytes.length, 8 * 1024 * 1024);
        expect(bytes.first, 42);
        return {'path': '/srv/合成目录/../上传目录/合成日志.log'};
      },
    );
    final phone = await LinkPeer.connect(client);
    final desktop = await accepting;
    addTearDown(phone.close);
    addTearDown(desktop.close);
    final bytes = Uint8List(LinkLimits.upload)..[0] = 42;
    expect(
      await uploadFile(
        state,
        desktop: '电脑',
        project: '合成项目',
        file: UploadFile('合成日志.log', bytes),
        request: (_, method, [params = const {}]) => phone.call(method, params),
      ),
      '/srv/合成目录/../上传目录/合成日志.log',
    );
    expect(requests, 1);
  });

  test('真实Peer Bot上传只带bot定位，不混入project或手机路径', () async {
    final (client, server) = MemoryLinkConnection.pair();
    final accepting = LinkPeer.accept(
      server,
      onRequest: (method, params) {
        expect(params, {
          'bot': '合成Bot',
          'name': '合成源码.dart',
          'data': base64Encode(utf8.encode('合成源码')),
        });
        return {'path': r'C:\合成目录\合成源码.dart'};
      },
    );
    final phone = await LinkPeer.connect(client);
    final desktop = await accepting;
    addTearDown(phone.close);
    addTearDown(desktop.close);
    expect(
      await uploadFile(
        state,
        desktop: '电脑',
        project: '不应发送',
        bot: '合成Bot',
        file: UploadFile('合成源码.dart', Uint8List.fromList(utf8.encode('合成源码'))),
        request: (_, method, [params = const {}]) => phone.call(method, params),
      ),
      r'C:\合成目录\合成源码.dart',
    );
  });

  test('原始字节超限在RPC之前拒绝，空文件仍可上传', () async {
    var calls = 0;
    Future<Object?> request(
      String _,
      String method, [
      Map<String, Object?> params = const {},
    ]) async {
      calls++;
      expect(params['data'], '');
      return {'path': '/tmp/合成空文件'};
    }

    await expectLater(
      uploadFile(
        state,
        desktop: '电脑',
        project: '项目',
        file: UploadFile('超限', Uint8List(LinkLimits.upload + 1)),
        request: request,
      ),
      throwsA(isA<UserFacingError>()),
    );
    expect(calls, 0);
    await uploadFile(
      state,
      desktop: '电脑',
      project: '项目',
      file: UploadFile('空文件', Uint8List(0)),
      request: request,
    );
    expect(calls, 1);
  });

  test('明确拒绝才提示更新，超时断线均不重试且不泄露异常', () async {
    for (final error in <Object>[
      const LinkRemoteException(LinkErrors.unknown, '不得回显的令牌'),
      const LinkRemoteException(LinkErrors.unsupported, '不得回显的路径'),
      TimeoutException('不得回显的令牌'),
      const LinkClosedException(),
    ]) {
      var calls = 0;
      Future<Object?> request(
        String _,
        String method, [
        Map<String, Object?> params = const {},
      ]) async {
        calls++;
        throw error;
      }

      await expectLater(
        uploadFile(
          state,
          desktop: '电脑',
          bot: '合成Bot',
          file: UploadFile('合成', Uint8List(0)),
          request: request,
        ),
        throwsA(
          isA<UserFacingError>().having(
            (e) => e.message,
            '安全中文提示',
            error is LinkRemoteException
                ? '此电脑不支持文件上传，请更新。'
                : contains('上传未确认'),
          ),
        ),
      );
      expect(calls, 1);
    }
  });

  test('真实Peer的unknown只请求一次，不自动降级重试', () async {
    final (client, server) = MemoryLinkConnection.pair();
    var calls = 0;
    final accepting = LinkPeer.accept(
      server,
      onRequest: (_, _) {
        calls++;
        throw const LinkRemoteException(LinkErrors.unknown, '不公开的错误');
      },
    );
    final phone = await LinkPeer.connect(client);
    final desktop = await accepting;
    addTearDown(phone.close);
    addTearDown(desktop.close);
    await expectLater(
      uploadFile(
        state,
        desktop: '电脑',
        project: '项目',
        file: UploadFile('合成', Uint8List(0)),
        request: (_, method, [params = const {}]) => phone.call(method, params),
      ),
      throwsA(
        isA<UserFacingError>().having(
          (e) => e.message,
          '明确拒绝',
          '此电脑不支持文件上传，请更新。',
        ),
      ),
    );
    expect(calls, 1);
  });

  test('真实Peer上传超时不确认且不重试，迟到应答不变成成功', () async {
    final (client, server) = MemoryLinkConnection.pair();
    var calls = 0;
    final answer = Completer<Object?>();
    final accepting = LinkPeer.accept(
      server,
      onRequest: (_, _) {
        calls++;
        return answer.future;
      },
    );
    final phone = await LinkPeer.connect(client);
    final desktop = await accepting;
    addTearDown(phone.close);
    addTearDown(desktop.close);
    await expectLater(
      uploadFile(
        state,
        desktop: '电脑',
        project: '项目',
        file: UploadFile('合成', Uint8List(0)),
        request: (_, method, [params = const {}]) =>
            phone.call(method, params, const Duration(milliseconds: 30)),
      ),
      throwsA(
        isA<UserFacingError>().having(
          (e) => e.message,
          '不确认',
          contains('上传未确认'),
        ),
      ),
    );
    answer.complete({'path': '/tmp/迟到合成文件'});
    await pumpEventQueue();
    expect(calls, 1);
  });

  test('tooLarge与缺失或非绝对路径绝不当成上传成功', () async {
    for (final response in <Object?>[
      {'tooLarge': true, 'path': '/tmp/不能成功'},
      null,
      {},
      {'path': ''},
      {'path': 'content://合成手机文件'},
      {'path': '相对/路径'},
      {'path': '/tmp/无法"引用'},
    ]) {
      await expectLater(
        uploadFile(
          state,
          desktop: '电脑',
          project: '项目',
          file: UploadFile('合成', Uint8List(0)),
          request: (_, _, [params = const {}]) async => response,
        ),
        throwsA(isA<UserFacingError>()),
      );
    }
  });

  test('路径前缀相撞不保留已被编辑掉的旧mentions', () {
    expect(hasFileMention('@/tmp/a-other', '/tmp/a'), isFalse);
    expect(hasFileMention('@/tmp/a.log', '/tmp/a'), isFalse);
    expect(hasFileMention('@/tmp/a/child', '/tmp/a'), isFalse);
    expect(hasFileMention('@/tmp/a-other @/tmp/a', '/tmp/a'), isTrue);
    expect(absoluteFileMentions('@/tmp/a-other'), {'/tmp/a-other'});
  });

  test('未加引号路径去除句末句号冒号，检测和编辑恢复一致', () {
    const path = '/tmp/example.log';
    for (final suffix in ['.', ':', '..:', ':..']) {
      final text = '请看 @$path$suffix';
      expect(hasFileMention(text, path), isTrue);
      expect(hasFileMention(text, '$path$suffix'), isFalse);
      expect(absoluteFileMentions(text), {path});
      expect(parseFileMention(text, 3)?.end, 3 + path.length + 1);
    }
  });

  test('带引号的中文空格路径精确匹配，不接受前缀和被改写路径', () {
    const path = '/tmp/合成 文档.pdf';
    expect(hasFileMention('@"$path-other"', path), isFalse);
    expect(hasFileMention('@"$path"。', path), isTrue);
    expect(absoluteFileMentions('@"$path"。'), {path});
    expect(hasFileMention('@$path', path), isFalse);
  });

  test('引号中的句末标点属于文件名，换行和未闭合引号不是引用', () {
    for (final path in ['/tmp/example.', '/tmp/example:']) {
      expect(fileMentionText(path), '@"$path"');
      expect(hasFileMention(fileMentionText(path), path), isTrue);
      expect(absoluteFileMentions(fileMentionText(path)), {path});
    }
    expect(parseFileMention('@"/tmp/未闭合', 0), isNull);
    expect(parseFileMention('@"/tmp/合成\n路径"', 0), isNull);
    expect(parseFileMention('@"/tmp/合成\r路径"', 0), isNull);
    expect(parseFileMention('@""', 0), isNull);
  });

  test('相对文件路径和目录遵循相同token语法，不把普通账号识别成文件', () {
    expect(hasFileMention('@lib/main.dart', 'lib/main.dart'), isTrue);
    expect(hasFileMention('@合成账号 @override', 'override'), isFalse);
    expect(parseFileMention('@lib/chat/', 0), (
      path: 'lib/chat',
      directory: true,
      end: 10,
    ));
    expect(parseFileMention('@"中文目录/"', 0)?.directory, isTrue);
    expect(absoluteFileMentions('@lib/main.dart @/tmp/example.log'), {
      '/tmp/example.log',
    });
  });

  test('扫描多个token跳过引号内的at符号，不制造额外文件引用', () {
    const quoted = '/tmp/合成 @/tmp/内部.log';
    final text = '${fileMentionText(quoted)} @/tmp/final.log.';
    expect(hasFileMention(text, '/tmp/内部.log'), isFalse);
    expect(hasFileMention(text, quoted), isTrue);
    expect(absoluteFileMentions(text), {quoted, '/tmp/final.log'});
    expect(parseFileMention('普通文字', 0), isNull);
    expect(parseFileMention('@/tmp/a', -1), isNull);
  });

  test('上传入口复用的向上箭头图标实际存在且是SVG资源', () {
    final asset = File('assets/icons/lucide-arrow-up.svg');
    expect(asset.existsSync(), isTrue);
    expect(asset.readAsStringSync(), contains('<svg'));
  });

  test('引用中文空格路径使用引号，编辑可恢复绝对路径且不改反斜线', () {
    const linux = '/srv/合成目录/合成 文件.pdf';
    const windows = r'C:\合成目录\合成 文件.pdf';
    expect(fileMentionText(linux), '@"$linux"');
    expect(fileMentionText('/tmp/example.log'), '@/tmp/example.log');
    expect(hasFileMention('说明 ${fileMentionText(windows)}', windows), isTrue);
    expect(
      absoluteFileMentions(
        '说明 ${fileMentionText(linux)} ${fileMentionText(windows)}',
      ),
      {linux, windows},
    );
  });
}
