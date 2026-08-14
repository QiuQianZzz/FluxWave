# audio_service 媒体通知：只保留入口类，允许 R8 优化传递依赖
-keep,allowoptimization,allowshrinking class com.ryanheise.audioservice.AudioService
-keep,allowoptimization,allowshrinking class com.ryanheise.audioservice.AudioServicePlugin
-keep,allowoptimization,allowshrinking class com.ryanheise.audioservice.AudioServicePlugin$*
-keep,allowoptimization,allowshrinking class com.ryanheise.audioservice.AudioServiceActivity
-keep,allowoptimization,allowshrinking class com.ryanheise.audioservice.MediaButtonReceiver

# R 子类（资源 ID 反射回退依赖）
-keep,allowoptimization class **.R$drawable { *; }
-keep,allowoptimization class **.R$mipmap { *; }
