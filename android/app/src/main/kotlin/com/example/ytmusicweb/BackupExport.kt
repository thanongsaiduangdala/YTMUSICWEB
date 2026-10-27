// Lets the app hand a finished backup file (.zip) to the phone's "save as"
// screen, so it can be put in Downloads, on an SD card, in Google Drive, etc.
// The copy is streamed, so a backup of several GB never has to fit in memory.
package com.example.ytmusicweb

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class BackupExport private constructor(private val activity: Activity) {
    companion object {
        private const val CHANNEL_NAME = "ytmusicweb/backup"
        private const val REQUEST = 7421
        private var instance: BackupExport? = null

        /** Call once from MainActivity.configureFlutterEngine. */
        fun register(engine: FlutterEngine, activity: Activity) {
            val me = BackupExport(activity)
            instance = me
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
                .setMethodCallHandler { call, result ->
                    if (call.method == "exportFile") {
                        val path = call.argument<String>("path")
                        if (path == null) result.error("args", "No file given", null)
                        else me.start(path, result)
                    } else {
                        result.notImplemented()
                    }
                }
        }

        /** Call from MainActivity.onActivityResult; true = it was ours. */
        fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
            val me = instance ?: return false
            if (requestCode != REQUEST) return false
            me.finish(resultCode, data)
            return true
        }
    }

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var pendingFile: File? = null

    private fun start(path: String, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "Another save is already open", null)
            return
        }
        val file = File(path)
        if (!file.exists()) {
            result.error("missing", "The backup file is missing", null)
            return
        }
        pending = result
        pendingFile = file
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/zip"
            putExtra(Intent.EXTRA_TITLE, file.name)
        }
        try {
            activity.startActivityForResult(intent, REQUEST)
        } catch (e: Exception) {
            pending = null
            pendingFile = null
            result.error("save", e.message ?: "Could not open the save screen", null)
        }
    }

    private fun finish(resultCode: Int, data: Intent?) {
        val result = pending ?: return
        val file = pendingFile
        pending = null
        pendingFile = null
        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || file == null) {
            result.success(false)
            return
        }
        io.execute {
            try {
                activity.contentResolver.openOutputStream(uri, "w").use { out ->
                    if (out == null) throw java.io.IOException("Cannot write there")
                    file.inputStream().use { it.copyTo(out, 1 shl 20) }
                    out.flush()
                }
                main.post { result.success(true) }
            } catch (e: Exception) {
                main.post { result.error("save", e.message ?: "Could not save the file", null) }
            }
        }
    }
}
