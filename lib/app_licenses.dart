// Fromsko — GPL-3.0-only.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 随应用分发的代码和图标的许可全文，显示在「开源许可」页；
/// 第三方 Dart 包的许可由 Flutter 自动收集，不在这里重复。
const _licenses = [
  (['Fromsko', 'BaoCode adapted sources'], 'assets/LICENSE-GPL-3.0.txt'),
  (['Lucide'], 'assets/licenses/lucide.txt'),
  (['Remix Icon'], 'assets/licenses/remix-icon-4.8.0.txt'),
  (['theSVG'], 'assets/licenses/thesvg.txt'),
  (['Material Icon Theme'], 'assets/material_icons/LICENSE'),
];

/// 上游署名。GPL-3.0 要求衍生版本保留原作者的版权声明，
/// 这段文字会作为一条独立条目出现在「开源许可」页最前面。
const _upstreamNotice = '''
Fromsko 是 YCode 的衍生版本，按 GPL-3.0-only 发布。

上游项目：YCode
版权所有 (C) 2026 shuishan
https://github.com/shuishani/ycode

本版本基于 YCode 0.2.2 开发。相对上游的修改包括：改名与重新打包
（应用名、包名、图标、界面文案）、新增 EasyTier 组网能力、关闭上游自动更新检查。
完整清单见仓库根目录的 NOTICE 文件。

除上述修改外，其余代码、文档与资源的版权归原作者 shuishan 及其贡献者所有。
''';

void registerAppLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Fromsko', 'YCode'], _upstreamNotice);
    for (final (packages, asset) in _licenses) {
      yield LicenseEntryWithLineBreaks(
        packages,
        await rootBundle.loadString(asset),
      );
    }
  });
}
