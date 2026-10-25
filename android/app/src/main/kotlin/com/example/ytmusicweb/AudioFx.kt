package com.example.ytmusicweb

import android.media.audiofx.BassBoost
import android.media.audiofx.PresetReverb
import android.media.audiofx.Virtualizer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Width (virtualizer), bass enhancer and room (reverb) for downloaded songs. */
object AudioFx {
    private var session = -1
    private var virt: Virtualizer? = null
    private var bass: BassBoost? = null
    private var reverb: PresetReverb? = null

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "ytmusicweb/fx")
            .setMethodCallHandler { call, result ->
                if (call.method != "apply") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val id = call.argument<Int>("session") ?: 0
                val wide = call.argument<Double>("wide") ?: 0.0
                val bassAmt = call.argument<Double>("bass") ?: 0.0
                val room = call.argument<Double>("room") ?: 0.0
                result.success(apply(id, wide, bassAmt, room))
            }
    }

    private fun release() {
        try { virt?.release() } catch (_: Throwable) {}
        try { bass?.release() } catch (_: Throwable) {}
        try { reverb?.release() } catch (_: Throwable) {}
        virt = null; bass = null; reverb = null
    }

    private fun apply(id: Int, wide: Double, bassAmt: Double, room: Double): Map<String, Boolean> {
        val ok = mutableMapOf("virtualizer" to true, "bass" to true, "reverb" to true)
        if (id <= 0) return ok
        if (id != session) { release(); session = id }
        try {
            if (virt == null && wide > 0) virt = Virtualizer(0, id)
            virt?.let {
                if (it.strengthSupported) it.setStrength((wide * 1000).toInt().toShort())
                it.enabled = wide > 0
            }
        } catch (_: Throwable) { ok["virtualizer"] = false }
        try {
            if (bass == null && bassAmt > 0) bass = BassBoost(0, id)
            bass?.let {
                if (it.strengthSupported) it.setStrength((bassAmt * 1000).toInt().toShort())
                it.enabled = bassAmt > 0
            }
        } catch (_: Throwable) { ok["bass"] = false }
        try {
            if (reverb == null && room > 0) reverb = PresetReverb(0, id)
            reverb?.let {
                it.preset = when {
                    room <= 0 -> PresetReverb.PRESET_NONE
                    room < 0.25 -> PresetReverb.PRESET_SMALLROOM
                    room < 0.5 -> PresetReverb.PRESET_MEDIUMROOM
                    room < 0.75 -> PresetReverb.PRESET_LARGEROOM
                    else -> PresetReverb.PRESET_LARGEHALL
                }
                it.enabled = room > 0
            }
        } catch (_: Throwable) { ok["reverb"] = false }
        return ok
    }
}
