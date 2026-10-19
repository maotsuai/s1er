class WebDavConfig {
  const WebDavConfig({
    required this.directoryUrl,
    required this.username,
    required this.password,
  });

  factory WebDavConfig.fromJson(Map<String, dynamic> json) => WebDavConfig(
        directoryUrl: json['directoryUrl'] as String,
        username: json['username'] as String,
        password: json['password'] as String,
      );

  final String directoryUrl;
  final String username;
  final String password;

  static const fileName = 's1er.s1backup.zip';

  Uri get directoryUri {
    final uri = Uri.tryParse(directoryUrl.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        !const ['https', 'http'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请输入有效的 WebDAV 目录地址，不含账号、查询参数或片段');
    }
    if (username.contains(':') || username.trim().isEmpty) {
      throw const FormatException('请输入有效的 WebDAV 用户名（不能含冒号）');
    }
    if (password.isEmpty) throw const FormatException('请输入 WebDAV 密码或应用专用密码');
    return uri.replace(
      path: uri.path.endsWith('/') ? uri.path : '${uri.path}/',
    );
  }

  Uri get fileUri => directoryUri.resolve(fileName);

  /// 用于隔离不同同步目标的本机合并基线，不含密码。
  String get targetId => '$fileUri|$username';

  Map<String, dynamic> toJson() => {
        'directoryUrl': directoryUri.toString(),
        'username': username,
        'password': password,
      };
}
