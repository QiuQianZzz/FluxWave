# audio_service 媒体通知相关：保留所有类和方法，防止 R8 混淆/移除
-keep class com.ryanheise.audioservice.** { *; }

# 保留 AndroidX media-compat 的 MediaBrowserServiceCompat 及内部回调
-keep class androidx.media.** { *; }

# 保留所有 R 子类及其字段（资源 ID），getIdentifier 反射回退依赖
-keep class **.R$drawable { *; }
-keep class **.R$mipmap { *; }
