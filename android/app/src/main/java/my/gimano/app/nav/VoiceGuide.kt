package my.gimano.app.nav

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.TextToSpeech
import my.gimano.app.core.GLog
import my.gimano.app.core.format.Lang
import java.util.Locale

/** TextToSpeech wrapper for English and Bahasa Melayu prompts. */
class VoiceGuide(
    context: Context,
    /** App voice volume 0..1 (sound panel slider), applied per utterance on top of the phone's media volume. */
    private val volume: () -> Float = { 1f },
) : TextToSpeech.OnInitListener, Speaker {
    private val audio = context.applicationContext.getSystemService(AudioManager::class.java)
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private val focus = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
        .setAudioAttributes(attributes)
        .setOnAudioFocusChangeListener { change ->
            if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) stop()
        }.build()
    private val utterances = mutableSetOf<String>()
    private var nextUtterance = 0L
    private val tts = TextToSpeech(context.applicationContext, this)
    private var ready = false
    private var currentLang: Lang? = null
    private val pending = ArrayList<Pair<String, Lang>>()

    override fun onInit(status: Int) {
        ready = status == TextToSpeech.SUCCESS
        if (ready) {
            tts.setAudioAttributes(attributes)
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(id: String?) = Unit
                override fun onDone(id: String?) = finished(id)
                @Deprecated("Platform callback") override fun onError(id: String?) = finished(id)
                override fun onError(id: String?, errorCode: Int) = finished(id)
                override fun onStop(id: String?, interrupted: Boolean) = finished(id)
            })
            pending.forEach { (t, l) -> speak(t, l) }
        }
        pending.clear()
    }

    private fun applyLang(lang: Lang) {
        if (currentLang == lang) return
        currentLang = lang
        val candidates = if (lang == Lang.MS) listOf(Locale("ms", "MY"), Locale("ms"), Locale("id", "ID")) else listOf(Locale("en", "MY"), Locale("en", "GB"), Locale.US)
        for (loc in candidates) {
            val r = tts.isLanguageAvailable(loc)
            if (r >= TextToSpeech.LANG_AVAILABLE) {
                tts.language = loc
                return
            }
        }
        GLog.w("VoiceGuide", "No TTS voice for $lang, using default")
    }

    override fun speak(text: String, lang: Lang, flush: Boolean) {
        if (!ready) {
            pending += text to lang
            return
        }
        applyLang(lang)
        val params = android.os.Bundle().apply { putFloat(TextToSpeech.Engine.KEY_PARAM_VOLUME, volume().coerceIn(0f, 1f)) }
        synchronized(utterances) {
            // Android Auto routes speech to the car only when navigation focus is requested.
            if (audio.requestAudioFocus(focus) != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) return
            if (flush) utterances.clear()
            val id = "manotu-voice-${++nextUtterance}"
            utterances.add(id)
            if (tts.speak(text, if (flush) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD, params, id) == TextToSpeech.ERROR)
                finished(id)
        }
    }

    private fun finished(id: String?) = synchronized(utterances) {
        if (utterances.remove(id) && utterances.isEmpty()) audio.abandonAudioFocusRequest(focus)
        Unit
    }

    override fun stop() {
        pending.clear()
        if (ready) tts.stop()
        synchronized(utterances) {
            utterances.clear()
            audio.abandonAudioFocusRequest(focus)
        }
    }

    fun shutdown() {
        stop()
        tts.shutdown()
    }
}
