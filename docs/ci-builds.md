# GitHub Actions 构建

默认 [Build workflow](../.github/workflows/build.yml) 在 `main` 推送、PR 和手动 `workflow_dispatch` 时运行。先通过 analyze、全量测试、M3 审计，再并行构建 Android、Windows、Web、iOS。Flutter 固定为 `3.47.5`，升级时同步检查 `pubspec.lock`。

主分支构建全部成功后，成品自动发布到本仓库的 **Releases**，tag 为 `v<pubspec name>`，例如 `v0.10.0`。PR 只验证构建，不发布 Release。Actions Artifacts 作为任务间传递与下载备份，保留 14 天。

| 平台 | 内容 |
| --- | --- |
| Android | release APK：universal、arm64-v8a、armeabi-v7a、x86_64 |
| Windows | x64 release ZIP，含 exe、DLL 与资源目录 |
| Web | release 静态站点 ZIP；论坛功能仍需配置 CORS 代理 |
| iOS | `s1er-<name>+<build>-ios-unsigned.ipa`，真机 release 构建；未签名，需要用个人/开发者证书重新签名后安装 |

原独立 iOS smoke 已合入默认 Build，保留 Info.plist 回归测试及 `flutter build ios --release --no-codesign`，避免重复跑两套 iOS 构建。

## Android 签名

默认 CI 使用 Android debug 证书签名 **release 优化构建**，可侧载测试，不是上游正式签名。不能覆盖安装使用其他证书签名的版本。不同 runner 的调试证书也可能不同；需要稳定升级安装时请配置自己的固定签名。

可在 fork 的 Settings → Secrets and variables → Actions 添加以下 repository secrets：

- `ANDROID_KEYSTORE_BASE64`：keystore 文件的 Base64。
- `ANDROID_KEY_ALIAS`：密钥别名。
- `ANDROID_KEYSTORE_PASSWORD`：keystore 密码。
- `ANDROID_KEY_PASSWORD`：密钥密码。

四项齐全时自动使用正式签名；不在日志中输出秘密，构建结束清理临时文件。来自其他 fork 的 PR 不获得 secrets，使用 CI 调试证书。正常本地发版没有 `S1_CI_BUILD=true`，继续要求既有的 release 签名配置。

## 发布与版本

所有平台的构建统一调用 `pwsh -File scripts/release.ps1 build -Platform ...`，脚本先 `flutter clean`；Android 四种 APK 与 iOS App 在上传前检查二进制中的 name/build。产物文件名包含 `pubspec.yaml` 的完整版本，发布前须先按 [发版流程](release/README.md) 更新版本、CHANGELOG 和应用内新功能说明。`+build` 必须严格递增；已存在的版本 tag 若属于另一个提交，发布会明确失败，须先提升产品版本后重新构建，不覆盖旧版本。

Release job 显式使用 `${{ github.repository }}`，先建立 draft，上传七个包，再执行 `release.ps1 manifest` 生成四个 APK 直链与 Windows/iOS 链接，上传 `latest.json` 后才公开 Release。自动提交生成的清单，提交带 `[skip ci]` 避免重复构建。清单不会沿用上游网盘链接。

CI 通过 `UPDATE_REPOSITORY` 与 `UPDATE_MANIFEST_URL` 将应用升级检查绑定到本 fork：主源为 Release 中的 `latest.json`，备用 raw/CDN 也来自相同仓库。
