# 开发指南

本地运行、Web 代理、编译期配置与常用脚本。贡献流程见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

## 环境

- [Flutter SDK](https://docs.flutter.dev/get-started/install) `>=3.4`
- Dart SDK `>=3.4 <4.0`（随 Flutter 提供）
- Git
- Android：Android SDK 与 JDK 17
- iOS / macOS：macOS 与对应版本的 Xcode

```bash
git clone https://github.com/Shirolin/s1er.git
cd s1er
flutter doctor
flutter pub get
```

克隆后即可构建；麻将脸资源已入库于 `assets/emoticons/`，无需单独下载。

## 原生平台

```bash
flutter devices
flutter run -d <device-id>
```

原生端登录 Cookie 通过 `PersistCookieJar` 持久化，落盘内容使用 AES-256-GCM 加密，密钥保存在系统安全存储中。

## iOS 构建与运行

> **性能警告（置顶）**：`flutter run` 与 Xcode **Debug** 配置编译出的是 **debug 包**（Dart JIT、未优化、调试断言全开），iPhone 上滚动卡顿是**预期行为**，不代表应用真实性能。体验、回帖反馈与性能排查一律使用 **Release** 或 **Profile** 包。设置页「版本」一行会显示当前构建模式（`Debug` / `Profile` / `Release`），可先看这里确认装的是哪种包。

### 环境与签名

- macOS + Xcode 15+；工程最低支持 **iOS 13.0**（`IPHONEOS_DEPLOYMENT_TARGET`）。
- `ios/Podfile` **已入库**（锁定 `platform :ios, '13.0'`，与工程 target 一致；勿删，缺省时 CocoaPods 会赋 15.0 产生警告）；`Pods/` 与 `Podfile.lock` 由首次 `pod install`（`flutter build ios` 自动触发）生成，不入库。
- `ironpress` 依赖暂指向 git fork（xcframework 兼容性修复，见 AGENTS.md 已知约束）；首次 `flutter pub get` 会拉取该仓库。
- 真机签名：Xcode → `Runner` → Signing & Capabilities → 勾选 Automatically manage signing 并选择你的 Team。**免费个人 Apple ID 即可**真机安装（工程已是 `CODE_SIGN_STYLE = Automatic`，`DEVELOPMENT_TEAM` 不入库）。
- **CI**：默认 `.github/workflows/build.yml` 通过分析、测试、M3 审计后，在对应 runner 上构建 Android、Windows、Web 和 iOS；iOS 包含 plist 回归测试与 `flutter build ios --no-codesign`。提交 `main`、PR 或手动触发后可下载构建产物，见 [GitHub Actions 构建](ci-builds.md)。

### 构建命令

```bash
# 真机直接运行（体验用这个，不是 flutter run 默认的 debug）
flutter run --release -d <device-id>

# 性能排查（可连 DevTools 看 Performance overlay）
flutter run --profile -d <device-id>

# 产物构建：从 Xcode 打开后选择真机/模拟器 target 直接 Run，
# 或命令行出未签名包做冒烟（CI 同款）
flutter build ios --release            # 完整签名产物
flutter build ios --no-codesign        # 无签名冒烟，验证工程可构建
```

### 性能排查（回应「卡卡的」类反馈）

1. **先看构建模式**：设置 → 关于 → 版本行末尾的 `Debug` / `Release`。是 `Debug` 就先换 `--release` 重测。
2. **帧率掉帧统计**：运行中若发生掉帧，App 会自动以 `[frame-timing]` 打一条聚合警告（每秒最多一条，仅掉帧秒出现）。入口：设置 → 关于 → **连点「版本」5 下** 打开 Talker 日志页。
3. **正文渲染打点**：编译时加 `--dart-define=BBCODE_PROFILE=true`，BBCode 解析 / Html 首帧耗时以 `[bbcode-profile]` 写入 Talker（App 内可见，无需连控制台）。
4. **系统级分析**：`flutter run --profile` 后打开 DevTools Performance overlay，区分 UI 线程（build）与 Raster 线程瓶颈。

### 帖子阅读手势

- 帖子页使用 `S1SwipePaginationMode.smart`：自定义横向 Drag Recognizer 在 Gesture Arena 中与正文竖滚竞争；方向锁定后显示跟手邻页骨架预览，松手才确认翻页或用 200ms 动画回弹。动画仅更新 Transform，正文不随每帧重建。其它列表继续使用原有拖动翻页。
- 移动阶段，横向位移超过 `max(系统 touchSlop, 18dp)` 且为纵向的至少 1.7 倍时锁定横向意图，涵盖相对水平线约 30° 内的横滑；纵向先胜出则本次触摸不再翻页。松手时仍须保持横向意图，且净位移达到阅读区域宽度的 22%；速度不降低距离门槛。拖回阈值以内会取消。
- 不因横向锁定后的累计纵向偏移再次取消手势，否则半屏距离的斜向横滑会失效。惯性滚动中按下、多指、取消事件、先长按再拖动、鼠标拖选不提交翻页。系统交给 Flutter 的边缘事件正常参与识别；系统截获后通过 cancel 回弹，不另行禁用侧边 20% 等区域。
- 图片缩放等内容用 `S1ReadingSwipeBlocker` 避让，嵌套横向列表优先赢得手势竞争；选区变化用 `S1ReadingSwipeBlockNotification` 取消当前候选。普通 `S1ClickRegion` 由点击/横滑识别器竞争，不再整块禁用翻页。
- 分享多选期间关闭横滑；末页（含单页）仅在触底后确认左滑才刷新。纵向下拉刷新、触底刷新与底部分页按钮保留。
- 阈值集中在 `lib/utils/reading_swipe_intent.dart`，属于待真机调优的初始参数。回归：`flutter test test/utils/reading_swipe_intent_test.dart test/widgets/s1_reading_swipe_test.dart`。
- 参考：[共享会话中的智能手势方案](https://chatgpt.com/share/6ad89f43-80e8-83ec-929a-b00188186c33)；[Thunder 导航手势](https://github.com/thunder-app/thunder/blob/d5de00be11fd3256c9debcf4a8cea8bc9fe91ce3/lib/src/core/navigation/swipeable_page_route.dart) 的横向识别器、跟手更新与释放后完成/恢复结构。Thunder 处理的是路由返回，本项目独立实现页内翻页，未引入其依赖或复制路由实现。

### 已知限制

- `/forum/:fid`、`/thread/:tid` 使用无转场页面，iOS 边缘侧滑返回在这两个页面不生效；帖子页改用被动智能翻页后，该路由限制仍需独立评估（见 AGENTS.md 已知约束）。
- 升级弹窗在 iOS 回退 GitHub 发布页（清单 `channels.ios` 为空时）；网盘/Play 入口仅 Android 展示。

## Web 开发代理

S1 接口不允许浏览器直接跨域访问。请先启动仅监听 `localhost` 的开发代理，再启动 Flutter Web。

Windows 可使用一键脚本：

```powershell
.\scripts\start_dev.ps1
```

也可以分别启动两个进程：

```bash
# 终端 1：CORS / Cookie / 图片与图床代理
dart run scripts/proxy_server.dart

# 终端 2：Flutter Web
flutter run -d chrome
```

无头环境可将第二条命令替换为：

```bash
flutter run -d web-server --web-port 8080 --web-hostname 0.0.0.0
```

代理默认监听 `http://localhost:19080`，只接受 `localhost` Origin。开发模式下未设置 `PROXY_AUTH_TOKEN` 时不校验 token；如需显式启用，请在代理与 Flutter 编译参数中使用同一值：

```bash
# 终端 1
dart --define=PROXY_AUTH_TOKEN=replace_with_a_random_value run scripts/proxy_server.dart

# 终端 2
flutter run -d chrome --dart-define=PROXY_AUTH_TOKEN=replace_with_a_random_value
```

> [!WARNING]
> 该代理仅用于本地开发：Cookie 保存在进程内存中，进程结束后即丢失。不要将它暴露到公网，也不要把真实账号、密码、Cookie 或 token 提交到仓库。共享机器或非常驻开发环境建议设置 `PROXY_AUTH_TOKEN`；`/img-proxy` 仅转发论坛图域与 `p.sda1.dev`。

## 配置（`--dart-define`）

应用配置通过 `--dart-define` 在编译期注入，定义集中在 `lib/config/env_config.dart`。

| Key | 默认值 | 说明 |
|---|---:|---|
| `TALKER_ENABLED` | `true` | 是否启用 Talker |
| `TALKER_LOG_LEVEL` | `error` | `error` 仅记录错误，`all` 记录全部请求与响应 |
| `TALKER_MAX_HISTORY` | `500` | 日志历史条数上限 |
| `BBCODE_PROFILE` | `false` | 正文 BBCode parse / Html build 耗时打点（滑动卡顿排查）；输出到控制台与 Talker |
| `PROXY_PORT` | `19080` | Web 代理端口；代理与 Flutter 端必须一致 |
| `PROXY_AUTH_TOKEN` | 空 | 非空时启用本地代理 token 校验 |
| `CONNECT_TIMEOUT` | `20` | 连接超时，单位为秒 |
| `RECEIVE_TIMEOUT` | `30` | 响应超时，单位为秒 |
| `SEND_TIMEOUT` | `30` | 发送超时，单位为秒 |
| `IMAGE_UPLOAD_TIMEOUT` | `120` | 外链图床上传超时（Web `/ext-upload` 同步），单位为秒 |
| `UPDATE_MANIFEST_URL` | jsDelivr CDN `docs/release/latest.json` | 应用升级清单主 URL（须可公开访问；并发备用 GitHub raw） |
| `DISTRIBUTION` | `github` | 分发渠道：`github` / `play`（影响升级 CTA） |
| `UPDATE_ALLOW_LOCAL_HOST` | `false` | **仅 debug/profile**：允许升级下载走本地 http 环回主机，用于本地端到端测试覆盖更新；release 恒不生效 |
| `SENTRY_DSN` | 空 | 非空时启用 Sentry；详见 [Sentry 设置](sentry-setup.md) |
| `SENTRY_TRACES_SAMPLE_RATE` | `0` | 性能采样 0–1；默认仅错误 |
| `SENTRY_DEBUG_UPLOAD` | `false` | debug 是否实际上传（防本机刷配额） |

示例：

```bash
flutter run -d chrome \
  --dart-define=TALKER_LOG_LEVEL=all \
  --dart-define=TALKER_MAX_HISTORY=1000
```

如需修改代理端口，代理进程也必须使用相同的编译期定义：

```bash
dart --define=PROXY_PORT=19081 run scripts/proxy_server.dart
flutter run -d chrome --dart-define=PROXY_PORT=19081
```

代理还会读取 `S1_UPSTREAM_PROXY`，并依次兼容常见的 `HTTPS_PROXY`、`HTTP_PROXY` 与 `ALL_PROXY` 进程环境变量。

## 常用脚本

| 脚本 | 用途 |
|---|---|
| `scripts/start_dev.ps1` | 在 Windows 启动本地代理和 Chrome 开发环境 |
| `scripts/proxy_server.dart` | Web 开发用 CORS、Cookie、图片与图床代理 |
| `scripts/watch_proxy.ps1` | 监听代理文件变更并自动重启 |
| `scripts/download_emoticons.dart` | 从 s1emoticon GitHub Release 按 `download_list.txt` 导入；见 `ATTRIBUTION.md` |
| `scripts/audit_m3.dart` | 扫描 Material Design 3 合规问题 |
| `scripts/sync_app_icons.dart` | 按 `AppIconCatalog` 生成 Android/iOS 交替启动器图标；iOS Info.plist 只做 `APP_ICON_ICONS` 标记区间替换（缺标记拒绝写入，纯函数 `scripts/ios_info_plist_patch.dart`，回归测试 `test/ios_info_plist_test.dart`）；规则见 [启动器图标](app-icons.md) |
| `scripts/gen_windows_icon.dart` | 从黑底成品图生成 Windows `app_icon.ico`（无运行时切换） |
| `scripts/build.ps1` | Windows 交互式构建菜单；Release 项需要维护者签名配置 |
| `scripts/release.ps1` | 发版分步：bump / 本机构建 / 建空 Release /（可选）CLI 上传 / 写 `latest.json`；见 [发版说明](release/README.md) |

启动器图标（黑/白 solid-plate vs 成品主题图如 xb2）：见 [启动器图标](app-icons.md)。改 catalog 或 branding 后务必跑 sync 并提交生成资源。

麻将脸维护：原 png/gif **已入库**于 `assets/emoticons/`（不转 WebP）。包定义见 `packs.json`，下载清单见 `download_list.txt`，来源声明见 [`ATTRIBUTION.md`](../assets/emoticons/ATTRIBUTION.md)。维护脚本从 [kawaiidora/s1emoticon](https://github.com/kawaiidora/s1emoticon) 的 **GitHub Release zip** 按清单导入（该仓当前**无 LICENSE**，仅致谢再分发）；勿进 CI、勿扫论坛 CDN。

## 宣传站

产品介绍页源码在 [`site/`](../site/)，经 GitHub Actions 部署到 GitHub Pages：

- 站点地址：[https://shirolin.github.io/s1er/](https://shirolin.github.io/s1er/)
- 本地预览：在仓库根目录执行 `npx --yes serve site`（或任意静态文件服务器指向 `site/`）

**首次启用**：仓库 Settings → Pages → Build and deployment → Source 选择 **GitHub Actions**。之后推送 `main` 上 `site/**` 的变更（或手动运行 workflow「Deploy site to GitHub Pages」）即可更新站点。

**Cloudflare Pages 镜像**：站点经 CF Pages **原生 Git 集成**自动部署（每次推送的 "Cloudflare Pages" check 即其部署结果），无需配置仓库 secret；构建配置见 [`wrangler.jsonc`](../wrangler.jsonc)（`pages_build_output_dir: ./site`），`_headers` / `_redirects` 由 CF Pages 生效。

宣传站截图为 `site/assets/screenshots/*.webp`；源图 PNG（含中文文件名）保留在 [`assets/screenshot/`](../assets/screenshot/)。

## 论坛接口探测

对真实论坛接口做手动探测时，请控制频率并优先使用游客只读接口；勿对真实账号循环登录或高频写操作。`S1HttpClient` 内置每秒最多 2 个请求的限速，不要绕过。
