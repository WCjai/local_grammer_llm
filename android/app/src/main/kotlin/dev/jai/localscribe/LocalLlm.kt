package dev.jai.localscribe

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import com.google.ai.edge.litertlm.Backend as LiteRtBackend
import com.google.ai.edge.litertlm.Engine as LiteRtEngine
import com.google.ai.edge.litertlm.EngineConfig as LiteRtEngineConfig
import com.google.ai.edge.litertlm.Content as LiteRtContent
import com.google.ai.edge.litertlm.Contents as LiteRtContents
import com.google.ai.edge.litertlm.Conversation as LiteRtConversation
import com.google.ai.edge.litertlm.ConversationConfig as LiteRtConversationConfig
import com.google.ai.edge.litertlm.Message as LiteRtMessage
import com.google.ai.edge.litertlm.MessageCallback as LiteRtMessageCallback
import com.google.ai.edge.litertlm.SamplerConfig as LiteRtSamplerConfig
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * LiteRT-LM error messages append a verbose "=== Source Location Trace ===" section
 * to every exception. That section is useful in Logcat but clutters user-visible
 * error messages. Strip it so only the human-readable first paragraph is shown.
 *
 * Mirrors cleanUpMediapipeTaskErrorMessage() from the Google AI Edge Gallery.
 */
internal fun cleanUpLiteRtErrorMessage(message: String): String {
    val idx = message.indexOf("=== Source Location Trace")
    return if (idx >= 0) message.substring(0, idx).trimEnd() else message
}

/**
 * Sampler tuning knobs. Maps onto LiteRT-LM's [LiteRtSamplerConfig].
 *
 * Defaults are tuned for grammar / text-correction / prompt-suggestion:
 * low temperature keeps outputs deterministic. Chat-style exploration
 * should pass a higher temperature (~0.9–1.1) via the "Creativity"
 * slider in AI Settings.
 */
data class SamplerParams(
    val temperature: Float = 0.3f,
    val topK: Int = 40,
    val topP: Float = 0.9f,
)

/**
 * Thin runtime-agnostic facade over on-device LLMs.
 * Supports LiteRT-LM `.litertlm` models.
 */
interface LocalLlm {
    /** Whether this model instance supports multimodal (image) input. */
    val supportsVision: Boolean

    /** The backend that was actually used to create this engine ("cpu" or "gpu"). */
    val activeBackend: String
        get() = "cpu"

    /** Runs one-shot text-only generation and returns the model's raw response text. */
    fun generate(prompt: String): String

    /**
     * Runs generation with optional image context. Implementations that don't support vision
     * should fall back to [generate] with the text prompt only.
     */
    fun generate(prompt: String, images: List<Bitmap>): String = generate(prompt)

    /**
     * Streams generation token-by-token. [onToken] is called for each partial
     * chunk, [onDone] exactly once at the end (including after cancel), and
     * [onError] at most once on failure (mutually exclusive with [onDone]).
     *
     * Default impl degrades to a blocking [generate] + single [onToken] so
     * runtimes without real streaming still plug into the same caller code.
     */
    fun generateStream(
        prompt: String,
        onToken: (String) -> Unit,
        onDone: () -> Unit,
        onError: (Throwable) -> Unit,
    ) {
        try {
            val full = generate(prompt)
            onToken(full)
            onDone()
        } catch (t: Throwable) {
            onError(t)
        }
    }

    /**
     * Cancels any in-progress generation on this engine. Safe to call when
     * nothing is running. Returns true if a generation was actually
     * interrupted.
     */
    fun cancel(): Boolean = false

    /** Returns an approximate token count for [prompt]. */
    fun sizeInTokens(prompt: String): Int

    /** Releases native resources. Safe to call multiple times. */
    fun close()
}

object LocalLlmFactory {
    /** All .litertlm models support vision/image input by default. */
    @Suppress("UNUSED_PARAMETER")
    fun detectVisionCapability(modelPath: String): Boolean = true

    /**
     * Create a [LocalLlm] for the given model file.
     * Only `.litertlm` models are supported. All models have [supportsVision] = true.
     */
    fun create(
        context: Context,
        modelPath: String,
        maxTokens: Int,
        supportsVision: Boolean = true,
        processingMode: String = "cpu",
        sampler: SamplerParams = SamplerParams(),
    ): LocalLlm {
        val ext = File(modelPath).extension.lowercase()
        if (ext != "litertlm") {
            throw IllegalStateException(
                "Unsupported model format: .$ext (only .litertlm models are supported)"
            )
        }
        return createLiteRtWithFallback(modelPath, maxTokens, supportsVision, processingMode, sampler)
    }

    /** GPU init can fail or hard-crash on some devices; transparently fall back to CPU. */
    private fun createLiteRtWithFallback(
        modelPath: String,
        maxTokens: Int,
        supportsVision: Boolean,
        processingMode: String,
        sampler: SamplerParams,
    ): LocalLlm {
        if (processingMode == "gpu") {
            try {
                return LiteRtLmLocalLlm(modelPath, maxTokens, supportsVision, "gpu", sampler)
            } catch (t: Throwable) {
                Log.w(
                    "LocalScribe",
                    "LiteRT-LM GPU init failed (${t.message}); falling back to CPU.",
                    t,
                )
            }
        }
        return LiteRtLmLocalLlm(modelPath, maxTokens, supportsVision, "cpu", sampler)
    }
}

private class LiteRtLmLocalLlm(
    modelPath: String,
    private val maxTokens: Int,
    override val supportsVision: Boolean,
    processingMode: String = "cpu",
    private val sampler: SamplerParams = SamplerParams(),
) : LocalLlm {
    override val activeBackend: String = processingMode
    private var engine: LiteRtEngine? = null

    // Most-recently-started Conversation, retained so [cancel] can call
    // cancelProcess() on it. Each generate*() creates a fresh one so requests
    // stay stateless (no KV-cache carryover across prompts).
    @Volatile
    private var activeConversation: LiteRtConversation? = null

    init {
        val backend = if (processingMode == "gpu") LiteRtBackend.GPU() else LiteRtBackend.CPU()
        // Vision encoding always runs on CPU regardless of the main backend.
        //
        // Rationale: on GPU mode the main prefill/decode graph alone occupies ~2.26 GB of
        // OpenCL memory (Gemma-4-E4B). The vision encoder is an additional 219 MB upload.
        // On mid-range devices (Snapdragon 778G+, shared system/GPU RAM) uploading both
        // simultaneously exhausts available memory and kills the process — the lost-device
        // crash in logcat at "Replacing 2245 out of 2245 node(s) with delegate (LITERT_CL)"
        // was caused by exactly this. The vision adapter already has section_backend_constraint=cpu
        // baked into the model metadata, so only the encoder is relevant here.
        // Keeping the encoder on CPU costs ~10–30 ms extra per image encode but prevents OOM.
        val visionBackend = if (supportsVision) LiteRtBackend.CPU() else null
        Log.i(
            "LocalScribe",
            "[LiteRT] Initializing engine: backend=$processingMode, supportsVision=$supportsVision, " +
                "visionBackend=${if (supportsVision) "cpu (always CPU to avoid GPU OOM)" else "null (text-only)"}, " +
                "sampler=$sampler"
        )
        val config = LiteRtEngineConfig(
            modelPath = modelPath,
            backend = backend,
            visionBackend = visionBackend,
            // maxNumTokens must be null — passing an explicit value triggers LiteRT-LM's
            // magic-number replacement which mismatches the RESHAPE op's output shape spec,
            // causing "num_input_elements != num_output_elements" at inference time.
            maxNumTokens = null,
        )
        val e = LiteRtEngine(config)
        e.initialize()
        engine = e
        Log.i("LocalScribe", "[LiteRT] Engine initialized successfully")
    }

    private fun buildConversationConfig(): LiteRtConversationConfig {
        // Log once per generate so the Logcat trail makes it obvious which
        // sampler values are actually reaching the native sampler. LiteRT-LM
        // applies these per-Conversation, not at engine init, so the engine
        // init log (which shows a default max_top_k: 1 in its backend buffer)
        // does NOT reflect your slider values — this line does.
        Log.i(
            "LocalScribe",
            "[LiteRT] Conversation sampler: topK=${sampler.topK} " +
                "topP=${sampler.topP} temperature=${sampler.temperature} maxTokens=$maxTokens"
        )
        return LiteRtConversationConfig(
            samplerConfig = LiteRtSamplerConfig(
                topK = sampler.topK,
                topP = sampler.topP.toDouble(),
                temperature = sampler.temperature.toDouble(),
            ),
        )
    }

    override fun generate(prompt: String): String {
        val e = engine ?: throw IllegalStateException("LiteRT-LM engine is closed")
        val conv = e.createConversation(buildConversationConfig())
        activeConversation = conv
        return try {
            conv.sendMessage(prompt).toString()
        } finally {
            if (activeConversation === conv) activeConversation = null
            try { conv.close() } catch (_: Exception) {}
        }
    }

    override fun generate(prompt: String, images: List<Bitmap>): String {
        if (images.isEmpty()) {
            Log.d("LocalScribe", "[LiteRT] No images provided, falling back to text-only")
            return generate(prompt)
        }
        if (!supportsVision) {
            Log.w(
                "LocalScribe",
                "[LiteRT] Image(s) provided but engine was built with visionBackend=null. " +
                    "Re-pick the model with 'Image input support' enabled in AI Settings."
            )
            return generate(prompt)
        }
        val e = engine ?: throw IllegalStateException("LiteRT-LM engine is closed")
        // Mirror Google's AI-Edge Gallery reference (LlmChatModelHelper.kt): encode
        // each image as lossless PNG, append all image Content entries first, then
        // the Text prompt last — the comment in Gallery's source says this ordering
        // is required "for the accurate last token".
        val contents = buildList<LiteRtContent> {
            for (bmp in images) {
                val bmpStream = ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.PNG, 100, bmpStream)
                val imgBytes = bmpStream.toByteArray()
                Log.d(
                    "LocalScribe",
                    "[LiteRT] Sending image to model: ${bmp.width}x${bmp.height}, pngBytes=${imgBytes.size}"
                )
                add(LiteRtContent.ImageBytes(imgBytes))
            }
            if (prompt.trim().isNotEmpty()) add(LiteRtContent.Text(prompt))
        }
        val conv = e.createConversation(buildConversationConfig())
        activeConversation = conv
        return try {
            conv.sendMessage(LiteRtContents.of(contents)).toString()
        } finally {
            if (activeConversation === conv) activeConversation = null
            try { conv.close() } catch (_: Exception) {}
        }
    }

    override fun generateStream(
        prompt: String,
        onToken: (String) -> Unit,
        onDone: () -> Unit,
        onError: (Throwable) -> Unit,
    ) {
        val e = engine
        if (e == null) {
            onError(IllegalStateException("LiteRT-LM engine is closed"))
            return
        }
        val conv = try {
            e.createConversation(buildConversationConfig())
        } catch (t: Throwable) {
            onError(t); return
        }
        activeConversation = conv

        // Some runtimes fire both onDone and onError on cancellation paths;
        // we want a single cleanup so the conversation isn't closed twice.
        val finished = AtomicBoolean(false)
        fun finalizeConversation() {
            if (!finished.compareAndSet(false, true)) return
            if (activeConversation === conv) activeConversation = null
            try { conv.close() } catch (_: Exception) {}
        }

        try {
            conv.sendMessageAsync(
                LiteRtContents.of(LiteRtContent.Text(prompt)),
                object : LiteRtMessageCallback {
                    override fun onMessage(message: LiteRtMessage) {
                        if (finished.get()) return
                        val text = message.toString()
                        if (text.isNotEmpty()) onToken(text)
                    }

                    override fun onDone() {
                        finalizeConversation()
                        onDone()
                    }

                    override fun onError(throwable: Throwable) {
                        finalizeConversation()
                        if (throwable is CancellationException) {
                            Log.i("LocalScribe", "[LiteRT] Generation cancelled by user")
                            onDone()
                        } else {
                            onError(throwable)
                        }
                    }
                },
                emptyMap(),
            )
        } catch (t: Throwable) {
            finalizeConversation()
            onError(t)
        }
    }

    override fun cancel(): Boolean {
        val conv = activeConversation ?: return false
        return try {
            conv.cancelProcess()
            Log.i("LocalScribe", "[LiteRT] cancelProcess() invoked")
            true
        } catch (t: Throwable) {
            Log.w("LocalScribe", "[LiteRT] cancelProcess failed: ${t.message}")
            false
        }
    }

    /**
     * LiteRT-LM's Kotlin API doesn't expose a public tokenizer count method,
     * so we approximate. The engine still enforces the model's compiled-in
     * context length internally during generation.
     */
    override fun sizeInTokens(prompt: String): Int {
        return (prompt.length / 4).coerceAtLeast(1)
    }

    override fun close() {
        // Best-effort: interrupt any in-flight generation so close() doesn't
        // block on a still-decoding conversation.
        try { activeConversation?.cancelProcess() } catch (_: Exception) {}
        try { activeConversation?.close() } catch (_: Exception) {}
        activeConversation = null
        try { engine?.close() } catch (_: Exception) {}
        engine = null
    }
}
