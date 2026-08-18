/// Netease Cookie 解析与拼装。
/// - cookieToJson: 把长串 "k=v; k2=v2" 转成 Map。
/// - cookieObjToString: 把 Map 转回字符串(对 key/value 做百分号编码)。
Map<String, String> cookieToJson(String? cookie) {
  if (cookie == null || cookie.isEmpty) return {};
  final map = <String, String>{};
  for (final item in cookie.split(';')) {
    final idx = item.indexOf('=');
    if (idx <= 0) continue;
    map[item.substring(0, idx).trim()] = item.substring(idx + 1).trim();
  }
  return map;
}

String cookieObjToString(Map<String, Object> cookies) {
  return cookies.entries
      .map(
        (e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value.toString())}',
      )
      .join('; ');
}

/// 从 set-cookie 列表收集 cookie 到对象。
/// 每条 `Set-Cookie: name=value; attr=...` 中：只把第一个 `name=value` 存入；
/// 后续均为属性(expires/path/domain/max-age/httponly/secure...)，不入库。
/// 若 `max-age`<=0 或 `expires` 为已过去的时刻，则删除该 name(删除标记)。
void mergeSetCookies(Map<String, String> target, List<String> setCookies) {
  for (final raw in setCookies) {
    final parts = raw.split(';');
    final eq = parts.first.indexOf('=');
    if (eq <= 0) continue;
    final name = parts.first.substring(0, eq).trim();
    final value = parts.first.substring(eq + 1).trim();

    var expire = false;
    for (final attr in parts.skip(1)) {
      final ae = attr.indexOf('=');
      final key = ((ae >= 0 ? attr.substring(0, ae) : attr).trim())
          .toLowerCase();
      final av = ae >= 0 ? attr.substring(ae + 1).trim() : '';
      if (key == 'max-age') {
        final ma = int.tryParse(av);
        if (ma != null && ma <= 0) expire = true;
      } else if (key == 'expires' && av.isNotEmpty) {
        final t = DateTime.tryParse(av);
        if (t != null && t.isBefore(DateTime.now())) expire = true;
      }
    }
    if (expire) {
      target.remove(name);
    } else {
      target[name] = value;
    }
  }
}
