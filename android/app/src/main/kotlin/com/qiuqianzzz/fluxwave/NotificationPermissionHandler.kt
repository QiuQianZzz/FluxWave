package com.qiuqianzzz.fluxwave

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 通知权限处理器。
 *
 * Android 13+ (API 33) 需要运行时申请 POST_NOTIFICATIONS 权限。
 * 本类通过 MethodChannel 提供权限检查、申请和跳转系统设置功能。
 */
class NotificationPermissionHandler(private val activity: Activity) {

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestNotificationPermission" -> {
                requestPermission(result)
            }
            "checkNotificationPermission" -> {
                checkPermission(result)
            }
            "openNotificationSettings" -> {
                openNotificationSettings(result)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * 检查通知权限是否已授予。
     */
    private fun checkPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // Android 13 以下不需要运行时申请
            result.success(true)
            return
        }

        val granted = ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED

        result.success(granted)
    }

    /**
     * 申请通知权限。
     */
    private fun requestPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // Android 13 以下不需要运行时申请
            result.success(true)
            return
        }

        // 已授权
        if (ContextCompat.checkSelfPermission(
                activity,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }

        // 申请权限
        pendingResult = result
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_CODE_NOTIFICATION_PERMISSION
        )
    }

    /**
     * 跳转到系统通知设置页面。
     */
    private fun openNotificationSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent().apply {
                action = Settings.ACTION_APP_NOTIFICATION_SETTINGS
                putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
            }
            activity.startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            // 部分系统可能不支持，尝试跳转到应用详情页
            try {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = android.net.Uri.parse("package:${activity.packageName}")
                }
                activity.startActivity(intent)
                result.success(true)
            } catch (e2: Exception) {
                result.success(false)
            }
        }
    }

    /**
     * 处理权限申请结果。
     *
     * 在 Activity.onRequestPermissionsResult 中调用。
     */
    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode != REQUEST_CODE_NOTIFICATION_PERMISSION) return

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED

        pendingResult?.success(granted)
        pendingResult = null
    }

    companion object {
        private const val REQUEST_CODE_NOTIFICATION_PERMISSION = 1001
        private var pendingResult: MethodChannel.Result? = null
    }
}
