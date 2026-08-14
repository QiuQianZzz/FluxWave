package com.qiuqianzzz.fluxwave

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * WiFi 电源锁处理器。
 *
 * 后台播放期间保持 WiFi 射频活性：系统在息屏/省电时会关闭 WiFi 网卡电源，
 * 造成 DNS 解析失败（`errno=7`）等网络中断。播放时持有 WifiLock 能显著降低
 * 这种后台断网概率（Doze 深度休眠仍可能挂起，属兜底手段）。
 *
 * 与 WAKE_LOCK（CPU 锁，audio_service 已持有）配合：
 * - CPU 锁 → 进程/CPU 不休眠；
 * - WiFi 锁 → 网卡不休眠，网络请求能真正发出去。
 *
 * 引用计数式 acquire：多次 acquire 返回同一把锁，首次真正创建；release 次数
 * 与 acquire 匹配时才真正释放，避免 Dart 侧调用顺序抖动导致锁提前释放。
 */
class WifiLockHandler(private val context: Context) {

    private var wifiLock: WifiManager.WifiLock? = null
    private var acquireCount = 0
    private var available = true

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "acquire" -> {
                    acquire()
                    result.success(true)
                }
                "release" -> {
                    release()
                    result.success(true)
                }
                "isHeld" -> {
                    result.success(wifiLock != null && wifiLock?.isHeld == true)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // Java 常用：WifiLock 创建在部分 ROM 可能抛异常，失败不阻塞播放。
            Log.e(TAG, "wifi lock channel failed: ${call.method}", e)
            result.success(false)
        }
    }

    private fun acquire() {
        if (!available) return
        if (wifiLock == null) {
            try {
                val wm = context.applicationContext
                    .getSystemService(Context.WIFI_SERVICE) as WifiManager
                // 仅保持 WiFi 无线电电源（不点亮屏幕），标签用于调试 dump。
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "fluxwave_playback")
                wifiLock?.setReferenceCounted(false)
            } catch (e: Exception) {
                available = false
                Log.e(TAG, "createWifiLock failed, disable wifi lock", e)
                return
            }
        }
        acquireCount++
        wifiLock?.acquire()
        Log.i(TAG, "wifi lock acquired (count=$acquireCount)")
    }

    private fun release() {
        if (acquireCount <= 0) return
        acquireCount--
        if (acquireCount == 0) {
            try {
                wifiLock?.release()
            } catch (e: Exception) {
                Log.e(TAG, "release wifi lock failed", e)
            }
            Log.i(TAG, "wifi lock released")
        }
    }

    companion object {
        private const val TAG = "FluxWaveWifiLock"
        const val CHANNEL = "fluxwave/wifi_lock"
    }
}