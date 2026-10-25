// Runs yt-dlp + ffmpeg inside the app, so no PC or extra app is needed.
// Uses the youtubedl-android library (a copy of yt-dlp and ffmpeg packed into the app).
//
// IMPORTANT: change the package name on the next line to match the first line of
// your own MainActivity.kt (look in android/app/src/main/kotlin/...).
package com.example.ytmusicweb

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.engine.FlutterEngine
import java.io.File
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class YtDlpBridge private constructor(
    private val app: Context,
    private val channel: MethodChannel
) {
    companion object {
        private const val CHANNEL_NAME = "ytmusicweb/ytdlp"

        /** Call this once from MainActivity.configureFlutterEngine. */
        fun register(engine: FlutterEngine, context: Context) {
            val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            val bridge = YtDlpBridge(context.applicationContext, channel)
            channel.setMethodCallHandler { call, result -> bridge.onCall(call, result) }
        }
    }

    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile private var ready = false
    @Volatile private var updateTried = false

    /** Sends a progress / log message to the Dart side (always on the main thread). */
    private fun emit(progress: Double, eta: Long, line: String) {
        mainHandler.post {
            channel.invokeMethod(
                "progress",
                mapOf("progress" to progress, "eta" to eta, "line" to line)
            )
        }
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "download" -> {
                val url = call.argument<String>("url")
                val dir = call.argument<String>("dir")
                val id = call.argument<String>("id")
                val update = call.argument<Boolean>("update") ?: false
                // "0" = best (default); only these values are accepted.
                val quality = when (call.argument<String>("quality")) {
                    "192K" -> "192K"
                    "128K" -> "128K"
                    else -> "0"
                }
                if (url == null || dir == null || id == null) {
                    result.error("bad_args", "Missing arguments", null)
                    return
                }
                executor.execute {
                    try {
                        val path = download(url, dir, id, update, quality)
                        mainHandler.post { result.success(path) }
                    } catch (e: Throwable) {
                        val msg = e.message ?: e.toString()
                        mainHandler.post { result.error("ytdlp_failed", msg, null) }
                    }
                }
            }
            // Lists the songs of a playlist / channel page without downloading them.
            // Returns yt-dlp's JSON text; the Dart side reads the entries from it.
            "list" -> {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("bad_args", "Missing url", null)
                    return
                }
                executor.execute {
                    try {
                        ensureReady()
                        val r = YoutubeDLRequest(url)
                        r.addOption("--flat-playlist")
                        r.addOption("--yes-playlist")
                        r.addOption("-J")
                        // Same callback shape as in download(). If `.out` does not
                        // compile, try `.getOut()` or tell me the error.
                        val response = YoutubeDL.getInstance().execute(r, "list") { _, _, _ -> }
                        val text = response.out
                        mainHandler.post { result.success(text) }
                    } catch (e: Throwable) {
                        val msg = e.message ?: e.toString()
                        mainHandler.post { result.error("ytdlp_failed", msg, null) }
                    }
                }
            }
            // Settings -> "Check for yt-dlp update". Answers with the library's
            // update status text (e.g. DONE or ALREADY_UP_TO_DATE).
            "update" -> {
                executor.execute {
                    try {
                        ensureReady()
                        val status = YoutubeDL.getInstance()
                            .updateYoutubeDL(app, YoutubeDL.UpdateChannel.STABLE)
                        mainHandler.post { result.success(status.toString()) }
                    } catch (e: Throwable) {
                        val msg = e.message ?: e.toString()
                        mainHandler.post { result.error("ytdlp_failed", msg, null) }
                    }
                }
            }
            // "wifi", "mobile", "none" or "other" (ethernet, VPN, ...).
            "network" -> result.success(networkType())
            "cancel" -> {
                val id = call.argument<String>("id")
                try {
                    if (id != null) YoutubeDL.getInstance().destroyProcessById(id)
                } catch (_: Throwable) {
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun networkType(): String {
        return try {
            val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "none"
            when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile"
                else -> "other"
            }
        } catch (e: Throwable) {
            "other"
        }
    }

    @Synchronized
    private fun ensureReady() {
        if (ready) return
        emit(-1.0, -1, "Unpacking yt-dlp and ffmpeg (first run only)...")
        YoutubeDL.getInstance().init(app)
        FFmpeg.getInstance().init(app)
        ready = true
        emit(-1.0, -1, "yt-dlp is ready")
    }

    // yt-dlp bundled in the app gets old; YouTube changes often, so try to refresh it.
    // The update runs on its own thread and we only wait 40 seconds for it, so a
    // slow or hung connection can never block the download.
    private fun tryUpdate() {
        if (updateTried) return
        updateTried = true
        emit(-1.0, -1, "Checking for a yt-dlp update (gives up after 40s)...")
        val worker = Thread {
            try {
                val status = YoutubeDL.getInstance()
                    .updateYoutubeDL(app, YoutubeDL.UpdateChannel.STABLE)
                emit(-1.0, -1, "Update check finished: $status")
            } catch (e: Throwable) {
                emit(-1.0, -1, "Update skipped: ${e.message}")
            }
        }
        worker.isDaemon = true
        worker.start()
        worker.join(40_000)
        if (worker.isAlive) {
            emit(-1.0, -1, "Update is taking too long, continuing with the built-in yt-dlp")
        }
    }

    private fun buildRequest(
        url: String,
        template: String,
        withJsRuntime: Boolean,
        quality: String,
        embedTags: Boolean = true
    ): YoutubeDLRequest {
        val r = YoutubeDLRequest(url)
        r.addOption("--no-playlist")
        r.addOption("-f", "bestaudio/best")
        r.addOption("-x")
        r.addOption("--audio-format", "mp3")
        r.addOption("--audio-quality", quality)
        // Put title / artist / cover inside the MP3 itself, so the file still
        // makes sense if the app's list is lost. (Cover needs a jpg, not webp.)
        if (embedTags) {
            r.addOption("--embed-metadata")
            r.addOption("--embed-thumbnail")
            r.addOption("--convert-thumbnails", "jpg")
        }
        r.addOption("-o", template)
        // YouTube needs a JavaScript runtime; the library ships QuickJS (0.18.1+).
        if (withJsRuntime) r.addOption("--js-runtimes", "quickjs")
        return r
    }

    private fun download(url: String, dir: String, id: String, update: Boolean, quality: String): String {
        ensureReady()
        if (update) tryUpdate()

        val template = "$dir/$id.%(ext)s"
        emit(-1.0, -1, "Asking YouTube for the audio...")

        // If this line fails to compile because the callback has 2 parameters
        // instead of 3, change it to:  { p, eta -> emit(p.toDouble(), eta, "") }
        val onProgress: (Float, Long, String) -> Unit = { p, eta, line ->
            emit(p.toDouble(), eta, line)
        }

        try {
            YoutubeDL.getInstance().execute(buildRequest(url, template, true, quality), id, onProgress)
        } catch (e: Throwable) {
            val msg = e.message ?: ""
            // An older yt-dlp does not know --js-runtimes: retry without it.
            if (msg.contains("js-runtimes", ignoreCase = true) ||
                msg.contains("no such option", ignoreCase = true) ||
                msg.contains("unrecognized arguments", ignoreCase = true)
            ) {
                emit(-1.0, -1, "This yt-dlp is too old for --js-runtimes, retrying without it...")
                YoutubeDL.getInstance().execute(buildRequest(url, template, false, quality), id, onProgress)
            } else if (File("$dir/$id.mp3").let { it.exists() && it.length() > 0 }) {
                // The MP3 was made but adding tags / cover failed: keep the song.
                emit(-1.0, -1, "Could not embed tags or cover (${e.message}), keeping the MP3 anyway")
            } else {
                emit(-1.0, -1, "Download with tags failed (${e.message}), retrying without tags...")
                YoutubeDL.getInstance().execute(buildRequest(url, template, true, quality, false), id, onProgress)
            }
        }
        return "$dir/$id.mp3"
    }
}
