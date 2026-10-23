# 双登录态与读帖回退

一次提交用户名、密码和可选的安全提问，由 `AuthService` 先调用
`POST /2b/api/app/user/login` 取得 `{uid, username, sid}`，再完成原有 mobile
表单登录（30 天 Cookie）。两次均成功才报告登录成功；任一步失败都会清理两套
本地凭据并展示错误，不自动重试密码，也不保存密码或安全提问答案。

sid 单独存入 `FlutterSecureStorage` 的 `s1_app_session` 槽；原生 Cookie 继续使用
AES-256-GCM 加密的 `PersistCookieJar`。两者均不进入 Drift、ZIP 备份或 WebDAV 同步。
退出会清理两套凭据，迟到的资料响应不会恢复退出后的用户状态。

启动时恢复 sid 携带的用户身份；公开的 `GET app/user` 只补充资料，不能证明
sid 仍有效。首次鉴权读帖遇到 501/503 时清除失效 sid。旧版本只有 Cookie 的用户
可以继续使用，重新输入密码后取得第二套凭据。

## 请求选择

- 普通读帖：`POST app/thread/page` + `POST app/thread`，两次均走 `S1HttpClient`
  的限速、超时和 Web 代理，不注入 Cookie 通道的 formhash。
- app 的业务失败、网络错误、解析错误或不完整数据：该次请求尝试一次
  `mobile/viewthread`。临时失败保留 sid，下一次仍优先 app；501/503 才删除 sid。
- `data.totalCount` 已含首楼，适配为 `replies = totalCount - 1`；
  `pageSize → ppp`、`position → number`、`dateline → dbdateline`，HTML 正文不改写。
- “只看某作者”没有对应 app 参数，继续使用 mobile 的 `authorid`。
- 投票首屏以 app 正文为主，尽力补取 mobile 的投票表单；表单不可用时仍显示正文。
  app/user 缺失的帖子数、好友等统计由现有 mobile/profile 补齐。
- 版块列表、搜索、私信、收藏及写操作等 reference 未覆盖的能力仍使用原有
  mobile / 网页接口；不会猜测 app 端点，也不会对写操作自动重复提交。

mobile 返回主题元信息、空正文和权限 Message 时，显示中文权限提示。
PHP Warning HTML 前缀后的 app JSON 可救援解析。日志只记录失败类型，不记录
sid、密码、答案或 app 响应原文。

## 平台与验证

Web 通过已有本地 CORS 代理转发 app 表单，sid 放在表单中，不依赖代理转发
authorization 头。sid 随浏览器安全存储持久化；备用 Cookie 仍在代理内存中，
重启代理后需重新登录。原生端两套凭据均持久化。

自动化测试 `test/services/dual_auth_test.dart` 使用传输适配器和安全存储替身，
覆盖双登录、持久化恢复、退出、部分失败清理、请求回退、失效 sid、分页和权限错误。
Android / Windows 的关键路径使用目标平台模拟；`dual_auth_web_test.dart` 在 Chrome
中通过真实 Web 拦截器验证代理改写、formhash 隔离和双会话清理。它们不代表已经
用真实凭据验证服务端权限，也不替代 Android / Windows 实机联调。

```sh
flutter test
flutter test --platform chrome test/services/dual_auth_web_test.dart
flutter analyze
dart run scripts/audit_m3.dart --fail-on-error
flutter build web --release
```

协议依据为用户提供的 `api-app-reference.md`，字段另对照了 S1-Next 的公开
[AppService](https://github.com/ykrank/S1-Next/blob/master/app/src/main/java/me/ykrank/s1next/data/api/app/AppService.kt)、
[AppPostsWrapper](https://github.com/ykrank/S1-Next/blob/master/app/src/main/java/me/ykrank/s1next/data/api/app/model/AppPostsWrapper.kt)
和 [AppThread](https://github.com/ykrank/S1-Next/blob/master/app/src/main/java/me/ykrank/s1next/data/api/app/model/AppThread.kt)。
真实 sid 的有效期、是否轮换、受限版块权限和不同分页大小仍需真实账号联调；
本次未向真实论坛重复登录或写入。
