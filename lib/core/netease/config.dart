import 'dart:convert';

List<int> hex(String s) {
  final o = <int>[];
  for (var i = 0; i < s.length; i += 2) {
    o.add(int.parse(s.substring(i, i + 2), radix: 16));
  }
  return o;
}

List<int> utf8Bytes(String s) => utf8.encode(s);

const String kIv = '0102030405060708';
const String kPresetKey = '0CoJUm6Qyw8W8jud';
const String kLinuxApiKey = 'rFgB&h#%2?^eDg:Q';
const String kEapiKey = 'e82ckenh8dichen8';
const String kContentTypeForm = 'application/x-www-form-urlencoded';
const String kContentTypeFormWithCharset =
    'application/x-www-form-urlencoded;charset=utf-8';
const String kBase62 =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
const String kPublicKeyPem =
    '''-----BEGIN PUBLIC KEY-----MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB-----END PUBLIC KEY-----''';
const String kWebDomain = 'https://music.163.com';
const String kApiDomain = 'https://interface.music.163.com';
const String kXeapiDomain = 'https://interface3.music.163.com';
const Set<int> kSpecialStatusCodes = {201, 302, 400, 502, 800, 801, 802, 803};
const String kEncryptSalt = 'nobody%suse%smd5forencrypt';
const String kEapiEncoded = '%s-36cd479b6b5-%s-36cd479b6b5-%s';

/// 默认是否让服务端加密 eapi/weapi 响应，false=明文。
const bool kEncryptResponse = false;
final List<int> kXeapiStaticKey = hex(
  'ab1d5a430f6bb04a3f01e81ddd72bd916d5ce591248ac128714806d7f8fb1b84',
);
final List<int> kXeapiSignKey = utf8Bytes(
  'mUHCwVNWJbunMqAHf5MImuirT6plvs6VSFW62MGHstFQxhBGdEoIhLItH3djc4+FB/OKty3+lL2rGeoFBpVe5g==',
);
final List<int> kX25519SpkiPrefix = hex('302a300506032b656e032100');

enum NeteaseCryptoMode { weapi, linuxapi, eapi, api }

/// 客户端伪装：不同平台 os 对应的 appver / osver / channel。
const Map<String, Map<String, String>> kOsMap = {
  'pc': {
    'os': 'pc',
    'appver': '3.1.17.204416',
    'osver': 'Microsoft-Windows-10-Professional-build-19045-64bit',
    'channel': 'netease',
  },
  'linux': {
    'os': 'linux',
    'appver': '1.2.1.0428',
    'osver': 'Deepin 20.9',
    'channel': 'netease',
  },
  'android': {
    'os': 'android',
    'appver': '9.1.65.240927161425',
    'osver': '14',
    'channel': 'xiaomi',
  },
  'iphone': {
    'os': 'iPhone OS',
    'appver': '9.0.90',
    'osver': '16.2',
    'channel': 'distribution',
  },
};

/// 不同加密方式 + 设备类型的 User-Agent。
const Map<String, Map<String, String>> kUaMap = {
  'weapi': {
    'pc':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0',
  },
  'linuxapi': {
    'linux':
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/60.0.3112.90 Safari/537.36',
  },
  'api': {
    'pc':
        'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.0.18.203152',
    'android':
        'NeteaseMusic/9.1.65.240927161425(9001065);Dalvik/2.1.0 (Linux; U; Android 14; 23013RK75C Build/UKQ1.230804.001)',
    'iphone': 'NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)',
  },
};

/// eapi/api 在 cookie.os==='osx' 时的 UA：纯 Chrome（无 Edg/ 后缀）。
/// 与 weapi.pc（带 Edg/）不同，不可通用，单独保留以满足 macOS 客户端风控指纹。
const String kOsxUa =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
