# GitHub Actions 构建

默认 [Build workflow](../.github/workflows/build.yml) 在 `main` 推送、PR 和手动 `workflow_dispatch` 时运行。先通过 analyze、全量测试、M3 审计，再并行构建 Android、Windows、Web、iOS。Flutter 固定为 `3.47.5`，升级时同步检查 `pubspec.lock`。

成品在该次 Actions run 的 **Artifacts** 中下载，保留 14 天，名称包含平台和提交 SHA：

| 平台 | 内容 |
| --- | --- |
| Android | release APK：universal、arm64-v8a、armeabi-v7a、x86_64 |
| Windows | x64 release ZIP，含 exe、DLL 与资源目录 |
| Web | release 静态站点 ZIP；论坛功能仍需配置 CORS 代理 |
| iOS | `s1er-ios-unsigned.ipa`，真机 release 构建；未签名，需要用个人/开发者证书重新签名后安装 |

原独立 iOS smoke 已合入默认 Build，保留 Info.plist 回归测试及 `flutter build ios --release --no-codesign`，避免重复跑两套 iOS 构建。

## Android 签名

默认 CI 使用 Android debug 证书签名 **release 优化构建**，可侧载测试，不是上游正式签名。不能覆盖安装使用其他证书签名的版本。不同 runner 的调试证书也可能不同；需要稳定升级安装时请配置自己的固定签名。

可在 fork 的 Settings → Secrets and variables → Actions 添加以下 repository secrets：

- `ANDROID_KEYSTORE_BASE64`：keystore 文件的 Base64。
- `ANDROID_KEY_ALIAS`：密钥别名。
- `ANDROID_KEYSTORE_PASSWORD`：keystore 密码。
- `ANDROID_KEY_PASSWORD`：密钥密码。

四项齐全时自动使用正式签名；不在日志中输出秘密，构建结束清理临时文件。来自其他 fork 的 PR 不获得 secrets，使用 CI 调试证书。正常本地发版没有 `S1_CI_BUILD=true`，继续要求既有的 release 签名配置。

此 workflow 仅生成 Actions artifacts，不发布 Release，不改版本号或升级清单。正式发布仍遵循 [发版流程](release/README.md)。
