package com.example.ytmusicweb

import android.content.Intent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        YtDlpBridge.register(flutterEngine, this)
        AudioFx.register(flutterEngine)
        BackupExport.register(flutterEngine, this)
    }

    // The "save backup" screen answers here; everything else goes on to Flutter
    // and its plugins (file picker, ...).
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (BackupExport.onActivityResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
