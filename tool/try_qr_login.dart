// 二维码登录「服务层」示例（联网）：
//   dart run tool/try_qr_login.dart
// 演示：newKey 拿 unikey -> qrUrl 拼 URL -> check 查询一次状态(通常 801)。
// 注意：这里只用服务层的**单次原语**；真正 App 里请用 Timer 循环驱动 check，
// 并在 isSuccess(803) 后读取 profile()。本脚本只演示单次调用，不做循环。
import 'package:fluxwave/core/netease/netease_api.dart';
import 'package:fluxwave/core/netease/netease_auth.dart';
import 'package:fluxwave/core/netease/netease_client.dart';

Future<void> main() async {
  final login = NeteaseQrLogin(NeteaseApi(NeteaseClient()));

  print('===== 1) 获取 unikey =====');
  final key = await login.newKey();
  print('unikey: $key');

  print('\n===== 2) 扫码 URL(可�渲染) =====');
  print(login.qrUrl(key));

  print('\n===== 3) 单次查询状态(不循环，见注释) =====');
  final st = await login.check(key);
  print(st);
  print('isWaitingScan=${st.isWaitingScan} isSuccess=${st.isSuccess}');

  print('\nisLoggedIn: ${login.isLoggedIn}');
  if (login.isLoggedIn) {
    final p = await login.profile();
    print('profile: ${p?['nickname']}');
  }
}