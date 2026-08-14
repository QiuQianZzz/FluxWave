package com.qiuqianzzz.fluxwave

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    private lateinit var notificationPermissionHandler: NotificationPermissionHandler
    private lateinit var wifiLockHandler: WifiLockHandler

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 强制设置 Activity 标题，确保最近任务显示正确的应用名
        // （audio_service 的 FlutterActivity 初始化可能重置标题）
        title = getString(R.string.app_name)
        notificationPermissionHandler = NotificationPermissionHandler(this)
        wifiLockHandler = WifiLockHandler(this)

        // 后台播放 WiFi 电源锁通道（息屏时保持网卡活性，见 WifiLockHandler）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WifiLockHandler.CHANNEL)
            .setMethodCallHandler { call, result ->
                wifiLockHandler.handleMethodCall(call, result)
            }

        // 桌面图标切换通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setLauncherIcon" -> {
                        try {
                            setLauncherIcon(call.arguments as? String ?: DEFAULT_ICON_ID)
                        } catch (e: Exception) {
                            // alias 均为本包组件，正常不会失败；兜底记录并仍回成功，
                            // 避免 Dart 侧因异常吞掉而表现不一。
                            Log.e(TAG, "setLauncherIcon failed", e)
                        } finally {
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // 通知权限申请通道
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERMISSION_CHANNEL)
            .setMethodCallHandler { call, result ->
                notificationPermissionHandler.handleMethodCall(call, result)
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        notificationPermissionHandler.onRequestPermissionsResult(
            requestCode,
            permissions,
            grantResults
        )
    }

    /**
     * 启用指定 id 的桌面图标 activity-alias，禁用其余全部（含已被禁用的），
     * 即时生效且持久（无需重启）。
     *
     * alias 命名约定：`com.qiuqianzzz.fluxwave.LauncherIcon_<id>`。
     * queryIntentActivities 会用本机全部 LAUNCHER 入口做匹配，这里先按本包名
     * 过滤，只处理我们自己定义的 icon-alias（其它应用的组件对其调用
     * setComponentEnabledSetting 会抛 SecurityException，也不应去碰）。
     * MATCH_DISABLED_COMPONENTS 确保已被禁用的 alias 也被枚举到，因此新增图标
     * 只需在 AndroidManifest 加一个 alias（必须带 MAIN/LAUNCHER intent-filter，
     * 否则不会被视为启动入口、也无法被枚举）+ 对应 mipmap，此处无需改动。
     *
     * 注意：Android 会"销毁/结束"当前正通过被禁用 alias 启动并运行着的
     * Activity，因此切换后设置页会关闭（进程保留），从桌面重新打开即为新图标。
     *
     * 兜底：若目标 alias 不在本包启动入口里（如 manifest 与 appIconOptions
     * 不同步），回退启用默认图标（LauncherIcon_default），绝不允许把所有
     * alias 都禁用而让应用从桌面消失；若连默认 alias 都不存在则保持现状不动。
     *
     * 开发注意事项（非产品问题）：`flutter run` 会以 manifest 里第一个
     * MAIN/LAUNCHER 组件名（即 LauncherIcon_default）硬编码启动应用，若它被
     * 运行时禁用（用户刚切到别的图标），`am start` 会报 "Activity class does
     * not exist" 并导致 flutter run 中断。普通用户点桌面图标不受影响（桌面
     * 始终指向"当前启用的 alias"），且组件开关态跨应用更新保留，发布后更新
     * 不会复现此问题。解阻塞：卸载重装，或执行
     * `adb shell pm enable com.qiuqianzzz.fluxwave/com.qiuqianzzz.fluxwave.LauncherIcon_default`。
     */
    private fun setLauncherIcon(id: String) {
        val pm = packageManager
        val launch = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val target = "com.qiuqianzzz.fluxwave.LauncherIcon_$id"
        val aliases = pm.queryIntentActivities(
            launch,
            PackageManager.MATCH_DISABLED_COMPONENTS
        ).mapNotNull { it.activityInfo }
            .filter { it.packageName == packageName }
            .map { ComponentName(it.packageName, it.name) }
        Log.i(TAG, "setLauncherIcon id=$id target=$target matched=${aliases.size}")
        // 先启用目标图标（保证新图标已可用），再禁用其余——避免某时刻桌面无图标。
        var targetName = aliases.firstOrNull { it.className == target }
        if (targetName == null) {
            // 目标 alias 不存在（如 manifest 与 appIconOptions 不同步）：回退启用
            // 默认图标，绝不允许"全部禁用导致桌面找不到应用"。
            Log.e(TAG, "target not found, fall back to default: $target")
            targetName = aliases.firstOrNull { it.className == DEFAULT_ALIAS }
        }
        if (targetName == null) {
            // 连默认 alias 都不在（异常状态）：保持现状，避免误禁用掉仅剩的启动入口。
            Log.e(TAG, "no launcher alias available: $aliases")
            return
        }
        pm.setComponentEnabledSetting(
            targetName,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP
        )
        Log.i(TAG, "  enable ${targetName.className}")
        for (name in aliases) {
            if (name == targetName) continue
            Log.i(TAG, "  disable ${name.className}")
            pm.setComponentEnabledSetting(
                name,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.DONT_KILL_APP
            )
        }
    }

    companion object {
        private const val TAG = "FluxWaveIcon"
        private const val CHANNEL = "fluxwave/launcher_icon"
        private const val PERMISSION_CHANNEL = "com.qiuqianzzz.fluxwave/permissions"
        private const val DEFAULT_ICON_ID = "default"
        private const val DEFAULT_ALIAS = "com.qiuqianzzz.fluxwave.LauncherIcon_default"
    }
}
