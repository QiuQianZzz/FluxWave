# NetEase (网易云) 加解密核心 — 开发文档

> 本模块是 `fluxwave` 跨平台音乐播放器的“网易云音源适配层”的**加解密部分**。
>
> **取长补短来源说明（重要）**：所有密钥、加密方式、设备指纹逻辑均取自参考项目的真实代码：
> - S-Player-Next：`electron/main/apis/netease/core/`（src/apis/utils）
> - SPlayer / Noxiana Player：`core/api/netease/NeteaseCrypto.kt`
>
> ⚠️ 网易云会不定期升级 key / 盐 / xeapi 协议。本文档由本项目作者依据上述源码整理，
> **不保证 100% 与官方现行版本一致**；任何一步失效时，请优先对照参考项目源码核对，
> 而不是直接修改本模块的“印象值”。

## 1. 目录结构与对照

| 本模块文件 | 对应参考实现 | 职责 |
| ---------- | ------------ | ---- |
| `config.dart` | `config.ts` / `NeteaseCrypto.kt` | 密钥、域名、UA、加密盐、OS 伪装常量 |
| `crypto.dart` | `crypto.ts` / `NeteaseCrypto.kt` | AES/RSA/MD5/HMAC 原语 + weapi/eapi/linuxapi 协议 |
| `device.dart` | `device.ts` + `NeteaseCrypto.kt` | deviceId、WNMCID、请求号、匿名令牌、encodeId |
| `cookie.dart` | `cookie.ts` | cookie 字符串 ↔ 对象 |
| `request.dart` | `request.ts`（createRequest） | 组装 URL / Header / Body |
| `netease_client.dart` | IPC/请求层 | dart:io 发送 + 解密 + cookie 回流 |
| `xeapi.dart` | `crypto.ts`(xeapi 段) + `xeapi.ts` | xeapi 签名/X25519会话/B-S-R 加解密 |

### 2. 加密方式选择(NeteaseMode)

| 模式 | 用途 | 加密细节 |
| ---- | ---- | -------- |
| **weapi** | 网页端保底接口 | AES-128-**CBC**×2(预设key→随机key) + **裸RSA**加密随机key |
| **linuxapi** | Linux 协议转发 | AES-128-**ECB** |
| **eapi** | 播放直链/歌单等关键接口 | MD5 签名 + AES-128-ECB(**hex 大写**) |
| **api** | 明文客户端接口 | 不加密，仅带 header |
| **xeapi** | 二期反爬(游客注册/登录) | 反爬公钥(HTTP明文) + X25519 ECDH + AES-128-GCM 封装「B/S/R」(见下方) |

### 3. 关键注意点（踩坑清单）

1. **weapi 的 RSA 是无填充“裸模幂”**：把明文字节左侧补 0 到 128 字节，再 `c^e mod n`。参考代码用 Java `BigInteger.modPow` / Node `RSA_NO_PADDING`；Dart 里直接用 `BigInt.modPow` 等价实现，输出补齐 128 字节(256 hex)。
2. **eapi 响应解密**与 **eapi 请求解密(e/auth)** 方向相反；`eapiReqDecrypt` 能还原出 `{url, body}` 用于调试。

2+. **eapi/weapi 响应是否加密由 body 里 `e_r` 控制(默认 `false`→明文)**。对齐 SNext `ENCRYPT_RESPONSE=false`：`buildRequest(..., useER:true)` 时服务端才返回密文，此时**响应体为原始二进制**，需 `bytes -> 大写 hex` 后再 AES(ECB,eapiKey) 解密+解压。`needDecrypt = e_r`。
3. **eapi 的 MD5 用的是 `nobody${uri}use${text}md5forencrypt`**，不是在 uri 用 `/api`。注意路径归一化：外部统一传 `/api/xxx`。
4. **AES 一律 PKCS7**(Node/Java 默认)，Dart 里用 pointycastle `PaddedBlockCipherImpl(PKCS7Padding(), ...)`。
5. **xeapi**：`B/S/R` 三段的运算全部要严格照 `crypto.ts` 的 `xeapi` 函数来：
   - `B = AES-ECB(dynamicKey, midTransform(AES-ECB(staticKey, plaintext)))`；
   - `S = [ephRaw32][iv12][ct][tag16]`，X25519 ECDH + AES-128-GCM，派生密钥用 HMAC 两次(`_deriveAesKey`)；
   - `R = AES-ECB(staticKey, version|(有会话?sessionId:""))`。
   - **登录只有一次往返时 `sessionKey/sessionId` 为空** → `dynamicKey` 取随机 16 字节，`R` 的 activeSession 为空串；多请求需回传响应头的 `x-encr-ssid/sskey` 更新会话。
   - `xeapiSign = HMAC-SHA256(signKey, ts+nonce) -> base64`；**signKey 用字符串 UTF-8 字节，不 base64 解码**。
   - `/security/key/get` 为**明文 HTTP POST**(非加密)，需校验返回 `signature === xeapiSign(timestamp, nonce)` 后用 `xeapiDecryptPublicKey(encryptedData)` 得 `{version, publicKey, sk}`。
   - 端点为 `interface3`(kXeapiDomain)，路径 `/xeapi/<uri去掉/api>`；响应体先 AES-ECB(eapiKey) 解密，再检测 gzip(1f8b) 解压。

### 4. 已实现 vs 待办

**✅ 已实现**
- weapi / eapi / linuxapi 加解密（含往返自检测试 `test/netease_crypto_test.dart`）
- AES-CBC / AES-ECB(PKCS7)、裸 RSA、MD5、HMAC-SHA256
- deviceId / WNMCID / 匿名令牌、`encodeId` / `registerUsername`（匿名注册 username）
- **xeapi**：签名 / 公钥包解密 / X25519+ECDH+AES-GCM 的 B-S-R 封装 / 响应解密 / 游客注册 `registerAnon()`
- `buildRequest` 按 createRequest 拼 URL/Header/Body
- `NeteaseClient` 发送 + eapi/xeapi 解密 + set-cookie 回流
- **二维码登录** `NeteaseApi`：`loginQrKey()`(unikey) / `loginQrUrl()` / `loginQrCheck()`(800/801/802/803，803 消费 Set-Cookie 的 MUSIC_U 写回 `ctx.musicU`) / `loginStatus()`(weapi) / `loginRefresh()`(eapi)

**⏳ 待办（下一步建议）**
1. **登录态持久化**：把 `MUSIC_U`/`MUSIC_A` 加密落盘重启后 reload 进 `ctx`；UI 层做 `loginQrCheck` 轮询(801→802→803)。
2. **xeapi 会话复用**：把响应头 `x-encr-sskey/ssid` 回写进 `NeteaseClient` 状态，供多请求复用（当前仅 anonymous 注册单次往返，未用会话）。
3. **播放层**：`song_url`(eapi) 已可用；登录后处理高音质 level、试听(freeTrialInfo)与换源兜底。

### 5. 运行与校验

```bash
flutter pub get
flutter test test/netease_crypto_test.dart   # 全部通过即加密内核可用
dart analyze lib/core/netease
```

### 6. 配置热替换

若网易更新了 `kPresetKey / kEapiKey / PUBLIC_KEY`，只需改 `config.dart`，无需改协议逻辑——这正是把密钥(“可换配置”)与算法分离设计的初衷。