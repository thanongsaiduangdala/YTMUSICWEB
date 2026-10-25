RUN YT-DLP INSIDE YOUR APP (no PC, no extra app)
================================================

Only use this with music you own or have permission to download.

HOW IT WORKS
  The app bundles yt-dlp and ffmpeg (library: youtubedl-android). Tapping the
  download button runs them on the phone and gives you a real MP3.
  The first download is slow: it unpacks yt-dlp and checks for an update.

I COULD NOT COMPILE THIS. Some Kotlin lines come from the library's README and
my own knowledge, not from its source. If the build fails, see
"IF THE BUILD FAILS" at the bottom, each one is a one-line fix.


STEP 1 - FILES
  a) Copy lib/main.dart over your project's lib/main.dart
  b) Copy android_pack/YtDlpBridge.kt into
       android/app/src/main/kotlin/<your/package/path>/
     (same folder as MainActivity.kt).
     Open it and make the first line "package ..." match MainActivity.kt.
     (I guessed com.example.ytmusicweb.)

STEP 2 - MainActivity.kt
  Keep your existing class. Only add the two marked lines.
  Do not change what the class extends (audio_service needs it):

    import io.flutter.embedding.engine.FlutterEngine          // <-- add

    class MainActivity : AudioServiceActivity() {              // keep yours as is
        override fun configureFlutterEngine(flutterEngine: FlutterEngine) {   // <-- add (if missing)
            super.configureFlutterEngine(flutterEngine)                       // <-- add (if missing)
            YtDlpBridge.register(flutterEngine, this)                         // <-- add
        }                                                                      // <-- add (if missing)
    }

  If your MainActivity already has configureFlutterEngine, just add the
  YtDlpBridge.register(flutterEngine, this) line inside it.

STEP 3 - android/app/build.gradle  (or build.gradle.kts)
  Kotlin DSL (.kts):
    android {
        defaultConfig {
            minSdk = 24                       // library needs a recent Android; 24 is safe
            ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
        }
        packaging { jniLibs { useLegacyPackaging = true } }
    }
    dependencies {
        implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
        implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
    }

  Groovy (.gradle):
    android {
        defaultConfig {
            minSdkVersion 24
            ndk { abiFilters "arm64-v8a", "armeabi-v7a" }
        }
        packagingOptions { jniLibs { useLegacyPackaging = true } }
    }
    dependencies {
        implementation "io.github.junkfood02.youtubedl-android:library:0.18.1"
        implementation "io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1"
    }

  (If your project already has these blocks, add the lines inside them.)

STEP 4 - android/app/src/main/AndroidManifest.xml
  Make sure these exist:
    <uses-permission android:name="android.permission.INTERNET"/>
    <application ... android:extractNativeLibs="true" ...>

STEP 5 - pubspec.yaml
  The Dart YouTube package is no longer used. Remove it:
    flutter pub remove youtube_explode_dart
  (keep http, path_provider, file_picker etc.)

STEP 6 - RUN
  flutter clean
  flutter run
  The APK gets much bigger (yt-dlp + ffmpeg are inside). That is normal.


USING IT
  Play a song, open the full-screen player, tap the download button.
  Watch it in Download tab -> Downloading (progress + log).


IF THE BUILD FAILS
  - "Unresolved reference: UpdateChannel" (or updateYoutubeDL):
      In YtDlpBridge.kt delete the function tryUpdate() and the line
      "if (update) tryUpdate()".
  - Error about the callback / "Type mismatch" on onProgress:
      The progress callback has 2 parameters in your version. Replace the
      onProgress lines with:
        val onProgress: (Float, Long) -> Unit = { p, eta -> emit(p.toDouble(), eta, "") }
  - "Unresolved reference: FFmpeg":
      Check the second implementation(...) line in build.gradle and sync.
  - "Could not find io.github.junkfood02...":
      Make sure mavenCentral() is in the repositories of android/build.gradle.
  - Manifest merger / minSdk error: raise minSdk to what it asks for.

IF A DOWNLOAD FAILS
  Tap Copy in Download tab -> Downloading -> Log and paste it to me.
  - "Sign in to confirm you're not a bot": YouTube blocked this connection
    (same problem as before). Try mobile data instead of Wi-Fi, or wait.
  - "no JavaScript runtime": the bundled yt-dlp/QuickJS setup did not work.
