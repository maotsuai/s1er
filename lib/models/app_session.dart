/// App API 凭据。仅由安全存储持久化，不进入设置、备份或日志。
class AppSession {
  const AppSession({
    required this.uid,
    required this.username,
    required this.sid,
  });

  factory AppSession.fromJson(Map<String, dynamic> json) {
    final uid = json['uid']?.toString() ?? '';
    final username = json['username']?.toString() ?? '';
    final sid = json['sid']?.toString() ?? '';
    if (uid.isEmpty || uid == '0' || username.isEmpty || sid.isEmpty) {
      throw const FormatException('App 登录凭据不完整');
    }
    return AppSession(uid: uid, username: username, sid: sid);
  }

  final String uid;
  final String username;
  final String sid;

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'username': username,
        'sid': sid,
      };
}
