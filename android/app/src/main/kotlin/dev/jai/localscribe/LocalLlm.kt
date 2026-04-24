package dev.jai.localscribe

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions
import com.google.mediapipe.tasks.genai.llminference.LlmInference.Backend as MpBackend
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession.LlmInferenceSessionOptions
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
 * Sampler tuning knobs. Maps onto LiteRT-LM's [LiteRtSamplerConfig] and
 * partially onto MediaPipe's LlmInferenceOptions (MediaPipe exposes
 * temperature + topK; topP is ignored for .task models).
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
 * Supports MediaPipe `.task` bundles and LiteRT-LM `.litertlm` models.
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
    /** Substrings in model file names that imply vision / multimodal capability. */
    private val VISION_KEYWORDS = listOf(
        "gemma-3n", "gemma3n", "gemma-4n", "gemma4n",
        "gemma-4", "gemma4",
        "paligemma", "vision", "-mm-", "-it-vision", "multimodal"
    )

    /** Heuristically detect vision capability from the model file name. */
    fun detectVisionCapability(modelPath: String): Boolean {
        val name = File(modelPath).name.lowercase()
        return VISION_KEYWORDS.any { name.contains(it) }
    }

    /**
     * Create a [LocalLlm] for the given model file.
     * [supportsVision] defaults to the filename heuristic; callers can pass an explicit override
     * from SharedPreferences when the user has toggled it manually.
     */
    fun create(
        context: Context,
        modelPath: String,
        maxTokens: Int,
        supportsVision: Boolean = detectVisionCapability(modelPath),
        processingMode: String = "cpu",
        sampler: SamplerParams = SamplerParams(),
    ): LocalLlm {
        val ext = File(modelPath).extension.lowercase()
        return when (ext) {
            "task" -> createMediaPipeWithFallback(context, modelPath, maxTokens, supportsVision, processingMode, sampler)
            "litertlm" -> createLiteRtWithFallback(modelPath, maxTokens, supportsVision, processingMode, sampler)
            else -> throw IllegalStateException(
                "Unsupported model format: .$ext (expected .task or .litertlm)"
            )
        }
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

    private fun createMediaPipeWithFallback(
        context: Context,
        modelPath: String,
        maxTokens: Int,
        supportsVision: Boolean,
        processingMode: String,
        sampler: SamplerParams,
    ): LocalLlm {
        if (processingMode == "gpu") {
            try {
                return MediaPipeLocalLlm(context, modelPath, maxTokens, supportsVision, "gpu", sampler)
            } catch (t: Throwable) {
                Log.w(
                    "LocalScribe",
                    "MediaPipe GPU init failed (${t.message}); falling back to CPU.",
                    t,
                )
            }
        }
        return MediaPipeLocalLlm(context, modelPath, maxTokens, supportsVision, "cpu", sampler)
    }
}

private class MediaPipeLocalLlm(
    context: Context,
    modelPath: String,
    maxTokens: Int,
    override val supportsVision: Boolean,
    processingMode: String = "cpu",
    private val sampler: SamplerParams = SamplerParams(),
) : LocalLlm {
    override val activeBackend: String = processingMode

    // Suppress further token callbacks when the user cancels. MediaPipe's async
    // generation also exposes a real hard cancel via
    // LlmInferenceSession.cancelGenerateResponseAsync() which we invoke below.
    private val streamingActive = AtomicBoolean(false)

    // The currently in-flight streaming session, retained only so [cancel]
    // can call cancelGenerateResponseAsync() on it. Cleared when the stream
    // completes (success, error, or user cancel).
    @Volatile
    private var activeSession: LlmInferenceSession? = null

    private var engine: LlmInference? = run {
        // tasks-genai 0.10.x moved setTemperature/setTopK/setTopP off
        // LlmInferenceOptions onto LlmInferenceSessionOptions. We build
        // the top-level engine without sampler tuning here and apply
        // [sampler] by opening a fresh [LlmInferenceSession] around each
        // generate() / generateStream() call (see [newSession]).
        val builder = LlmInferenceOptions.builder()
            .setModelPath(modelPath)
            .setMaxTokens(maxTokens)
        builder.setPreferredBackend(
            if (processingMode == "gpu") MpBackend.GPU else MpBackend.CPU
        )
        LlmInference.createFromOptions(context.applicationContext, builder.build())
    }

    /**
     * Builds a per-request [LlmInferenceSession] seeded with the user's
     * current sampler knobs (temperature / topK / topP). Caller owns the
     * session and must close it.
     */
    private fun newSession(): LlmInferenceSession {
        val e = engine ?: throw IllegalStateException("MediaPipe LLM is closed")
        Log.i(
            "LocalScribe",
            "[MediaPipe] Session sampler: topK=${sampler.topK} " +
                "topP=${sampler.topP} temperature=${sampler.temperature}"
        )
        val opts = LlmInferenceSessionOptions.builder()
            .setTemperature(sampler.temperature)
            .setTopK(sampler.topK)
            .setTopP(sampler.topP)
            .build()
        return LlmInferenceSession.createFromOptions(e, opts)
    }

    override fun generate(prompt: String): String {
        val session = newSession()
        return try {
            session.addQueryChunk(prompt)
            session.generateResponse()
        } finally {
            try { session.close() } catch (_: Exception) {}
        }
    }

    /**
     * MediaPipe .task multimodal inference requires the `tasks-vision` artifact
     * which we don't ship. Fall back to text-only and warn loudly so the user
     * can pick a LiteRT-LM model for vision.
     */
    override fun generate(prompt: String, images: List<Bitmap>): String {
        if (images.isNotEmpty()) {
            Log.w(
                "LocalScribe",
                "MediaPipe .task runtime does not support image input in this build; dropping ${images.size} image(s). Use a .litertlm model for multimodal.",
            )
        }
        return generate(prompt)
    }

    override fun generateStream(
        prompt: String,
        onToken: (String) -> Unit,
        onDone: () -> Unit,
        onError: (Throwable) -> Unit,
    ) {
        val session = try {
            newSession()
        } catch (t: Throwable) {
            onError(t); return
        }
        activeSession = session
        streamingActive.set(true)
        try {
            session.addQueryChunk(prompt)
            // tasks-genai 0.10.x streams deltas with a final `done` flag.
            session.generateResponseAsync { partial, done ->
                if (!streamingActive.get()) return@generateResponseAsync
                if (!partial.isNullOrEmpty()) onToken(partial)
                if (done) {
                    streamingActive.set(false)
                    activeSession = null
                    try { session.close() } catch (_: Exception) {}
                    onDone()
                }
            }
        } catch (t: Throwable) {
            streamingActive.set(false)
            activeSession = null
            try { session.close() } catch (_: Exception) {}
            onError(t)
        }
    }

    override fun cancel(): Boolean {
        val wasActive = streamingActive.getAndSet(false)
        val session = activeSession
        activeSession = null
        if (session != null) {
            try { session.cancelGenerateResponseAsync() } catch (_: Exception) {}
            try { session.close() } catch (_: Exception) {}
        }
        if (wasActive) Log.i("LocalScribe", "[MediaPipe] Generation cancelled")
        return wasActive
    }

    override fun sizeInTokens(prompt: String): Int {
        val e = engine ?: throw IllegalStateException("MediaPipe LLM is closed")
        return e.sizeInTokens(prompt)
    }

    override fun close() {
        streamingActive.set(false)
        val session = activeSession
        activeSession = null
        if (session != null) {
            try { session.cancelGenerateResponseAsync() } catch (_: Exception) {}
            try { session.close() } catch (_: Exception) {}
        }
        try { engine?.close() } catch (_: Exception) {}
        engine = null
    }
}

private class LiteRtLmLocalLlm(
    modelPath: String,
    @Suppress("UNUSED_PARAMETER") maxTokens: Int,
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
        Log.i(
            "LocalScribe",
            "[LiteRT] Initializing engine: backend=$processingMode, supportsVision=$supportsVision, " +
                "visionBackend=${if (supportsVision) processingMode else "null (text-only)"}, " +
                "sampler=$sampler"
        )
        val config = LiteRtEngineConfig(
            modelPath = modelPath,
            backend = backend,
            visionBackend = if (supportsVision) backend else null,
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
                "topP=${sampler.topP} temperature=${sampler.temperature}"
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
