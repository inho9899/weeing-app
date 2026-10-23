package com.example.weeing_app

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// 업데이트 APK 를 설치 화면에 넘길 때만 쓴다. 플러그인이 androidx FileProvider 를
// 이미 선언하면 같은 클래스 이름으로는 매니페스트 병합이 충돌해서 하위 클래스로 둔다.
class UpdateFileProvider : FileProvider()

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // lib/utils/app_update.dart 가 쓴다.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "weeing/app_update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "currentBuild" -> result.success(currentBuild())
                    "versionName" -> result.success(
                        packageManager.getPackageInfo(packageName, 0).versionName
                    )
                    "updateDir" -> result.success(
                        File(cacheDir, "updates").apply { mkdirs() }.absolutePath
                    )
                    "install" -> result.success(install(call.argument<String>("path")!!))
                    else -> result.notImplemented()
                }
            }
    }

    private fun currentBuild(): Long {
        val info = packageManager.getPackageInfo(packageName, 0)
        @Suppress("DEPRECATION")
        return if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
    }

    // "permission": "출처를 알 수 없는 앱 설치" 허용 화면을 띄웠다. 허용하고 돌아와서 다시 눌러야 한다.
    // "started": Android 설치 화면을 띄웠다. 설치는 사용자가 [설치]를 눌러야 진행된다.
    private fun install(path: String): String {
        if (Build.VERSION.SDK_INT >= 26 && !packageManager.canRequestPackageInstalls()) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
            )
            return "permission"
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.updates", File(path))
        startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        })
        return "started"
    }
}
