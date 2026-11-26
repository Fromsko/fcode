# 构建、签名与发布（Android）

应用名 **Fromsko**，包名 `local.fromsko.mobile`。正式版仅发布 arm64 APK。升级必须保持同一包名和正式签名，并使用更高的 Android 构建号，才能覆盖安装、保留配对和聊天记录。

## 本地环境

安装 Flutter、JDK 21、Android SDK/NDK、Rust 和 adb。设置 `ANDROID_HOME`（或 `ANDROID_SDK_ROOT`），将 Flutter 和 SDK 的 `platform-tools` 加入 `PATH`。JDK 不在标准位置时设置 `JAVA_HOME`；macOS 打包脚本也会尝试已安装的 Homebrew `openjdk@21`。

`android/local.properties` 仅保存本机路径，不提交，例如：

```properties
sdk.dir=/path/to/Android/sdk
flutter.sdk=/path/to/flutter
```

Windows 可以使用 `tool/prepare_android.ps1 -FlutterSdk <路径> -AndroidSdk <路径>`。首次构建前运行 `flutter pub get`。

## 正式签名：Mac 与 Windows 共用同一把密钥

密钥放在 `~/.android/fromsko-release.jks`，配置放在同目录的 `fromsko-release.properties`。Windows 的 `~` 是当前用户主目录；Git Bash 和 macOS 都使用同样的文件名和相对路径。

配置包含 `storeFile`、`storePassword`、`keyAlias`、`keyPassword` 四项。`storeFile` 写 `fromsko-release.jks`，相对配置所在目录解析，换电脑不用改。配置放在其他位置时，用 `FROMSKO_SIGNING` 指定完整路径。

**换电脑要安全地转移原有文件，不要重新生成密钥。** macOS 对两个文件执行 `chmod 600`。脚本不会输出口令，apksigner 通过环境变量读取口令，避免写入命令行参数。

密钥、配置和包含它们的压缩包都不能提交。请自行安全保存正式签名；丢失密钥后无法对已安装应用做同签名升级。

## 版本号与构建号

`pubspec.yaml` 的 `version` 必须是 `版本名+构建号`，如 `0.1.0+1`：

- 版本名是三段数字，设置页和 GitHub 标签按它比较版本。发布新版本时必须提升版本名。
- `+` 后的构建号从 `1` 开始，每次发布加 1，在 `pubspec.yaml` 中手动维护。发布过的构建号不能重复使用，也不能回退：构建号更小的安装包无法覆盖安装，只能卸载重装，会清空手机上的配对和数据。
- 构建号不依赖 Git 提交数，重建或精简仓库历史不影响升级。
- 打包脚本会把版本名通过 `APP_VERSION` 编译进应用；绕过脚本构建时也要传这个参数，否则设置页显示 `dev`。

## 构建与安装

```sh
tool/build_android.sh --no-install # 只构建并正式签名
tool/build_android.sh              # 另用 adb install -r 覆盖安装
```

脚本会：

1. 备份 `GeneratedPluginRegistrant.java` 当前内容，暂时移除 `integration_test` 注册。成功或失败后都恢复原样，不用 Git 覆盖已有本地修改。
2. 以 release 模式仅构建 arm64，从 `pubspec.yaml` 读取版本和构建号。
3. 用 Android build-tools 对齐、正式签名并校验，生成 `build/app/outputs/flutter-apk/fromsko-<版本名>-<构建号>.apk`。
4. 仅在未指定 `--no-install` 时执行 `adb install -r`，并打印设备上的版本信息。

build-tools 从 `ANDROID_HOME` / `ANDROID_SDK_ROOT` 或系统标准目录查找，也可以通过 `BUILD_TOOLS` 指向具体版本目录。签名配置缺失或不完整会报错退出，绝不回退到 debug 签名。

## 发布与检查更新

发布由 [`.github/workflows/release.yml`](../.github/workflows/release.yml) 自动完成：
推一个 `v*` 标签，CI 构建、签名、生成 `latest.json` 并发布 Release。

### 一次性准备：三个仓库 Secrets

| Secret | 内容 |
|---|---|
| `KEYSTORE_BASE64` | `base64 -w0 ~/.android/fromsko-release.jks` 的输出 |
| `KEYSTORE_PASSWORD` | `storePassword` 与 `keyPassword`（本项目两者相同） |
| `KEY_ALIAS` | `keyAlias`，默认 `fromsko` |

三个都配好，CI 才会签名并发布；缺任何一个就只构建，产物留在 Actions 的 artifact 里。

### 每次发版

1. 改 `pubspec.yaml` 的 `version`：版本名递增，`+` 后的构建号只增不减。
2. 在 `CHANGELOG.md` 和 `CHANGELOG_CN.md` 顶部各写一节 `## <版本名>`——CI 和
   `tool/release_manifest.dart` 都按这个标题找说明。
3. 提交，打标签 `v<版本名>`，推标签。CI 出包并发布。
4. 装一次验证：包名 `local.fromsko.mobile`、版本号、签名指纹是否与预期一致。

### CI 做了什么

- Flutter 3.47.9 + JDK 21 + Rust 1.97.1（带 Android 目标）+ Android SDK
- `flutter pub get`、`flutter analyze --no-pub`
- `flutter build apk --release --target-platform android-arm64`
- 用 Secrets 里的密钥 zipalign + apksigner 签名，产物名 `fromsko-<版本>-<构建号>.apk`
- 跑 `dart run tool/release_manifest.dart` 生成 `latest.json`
- `gh release create` 发布，说明取 `latest.json` 的 `body`（英文在前，`<!-- zh -->`
  之后是中文）

### 本地出包（不经 CI）

```sh
tool/build_android.sh --no-install    # 产物在 build/app/outputs/flutter-apk/
```

### 自动更新当前是关闭的

`lib/state/update_check.dart` 里 `fromskoUpdatesEnabled = false`。改名前它检查的是上游
`shuishani/ycode` 的 Releases，那里的包名和签名都不同，装不上。等本仓库开始发版后，把这个
常量改成 `true`，并把 `updateManifestUrl` / `updateReleaseApi` 指向
`https://github.com/Fromsko/fcode`，自动更新就会重新工作。

## 注意事项

- 签名不同的安装包（比如 debug 签名）不能覆盖安装正式版。只能卸载重装，会清空数据，必须先告知用户；不要擅自卸载。
- 不要删除或提交构建导致的 `GeneratedPluginRegistrant.java` 改动。删除它可能导致插件未注册。
- 每个 `FileProvider` 必须用各自的子类（如更新用的 `UpdateFileProvider`）。多个 `<provider>` 共用 `androidx.core.content.FileProvider` 类名时只有一个生效，系统安装器读不到更新包，会报“安装包已损坏”。
- 官方 BaoCode（`dev.baocode.mobile`）与本应用无关，不要操作它。
- adb 连接异常时先检查设备、USB 调试授权和 adb 服务，不要结束不明的共享服务或清除手机数据。
