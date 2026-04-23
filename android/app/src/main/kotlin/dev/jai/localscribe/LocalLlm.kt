package dev.jai.localscribe

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions
import com.google.mediapipe.tasks.genai.llminference.LlmInference.Backend as MpBackend
import com.google.ai.edge.litertlm.Backend as LiteRtBackend
import com.google.ai.edge.litertlm.Engine as LiteRtEngine
import com.google.ai.edge.litertlm.EngineConfig as LiteRtEngineConfig
import com.google.ai.edge.litertlm.Content as LiteRtContent
import com.google.ai.edge.litertlm.Contents as LiteRtContents
import java.io.ByteArrayOutputStream
import java.io.File

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
     * The default implementation ignores [images] and calls [generate].
     */
    fun generate(prompt: String, images: List<Bitmap>): String = generate(prompt)

    /**
     * Returns an approximate token count for [prompt]. Implementations may return a
     * best-effort character-based estimate if the underlying runtime does not expose a tokenizer.
     */
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
    ): LocalLlm {
        val ext = File(modelPath).extension.lowercase()
        return when (ext) {
            "task" -> createMediaPipeWithFallback(context, modelPath, maxTokens, supportsVision, processingMode)
            "litertlm" -> createLiteRtWithFallback(modelPath, maxTokens, supportsVision, processingMode)
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
    ): LocalLlm {
        if (processingMode == "gpu") {
            try {
                return LiteRtLmLocalLlm(modelPath, maxTokens, supportsVision, "gpu")
            } catch (t: Throwable) {
                Log.w(
                    "LocalScribe",
                    "LiteRT-LM GPU init failed (${t.message}); falling back to CPU.",
                    t,
                )
            }
        }
        return LiteRtLmLocalLlm(modelPath, maxTokens, supportsVision, "cpu")
    }

    private fun createMediaPipeWithFallback(
        context: Context,
        modelPath: String,
        maxTokens: Int,
        supportsVision: Boolean,
        processingMode: String,
    ): LocalLlm {
        if (processingMode == "gpu") {
            try {
                return MediaPipeLocalLlm(context, modelPath, maxTokens, supportsVision, "gpu")
            } catch (t: Throwable) {
                Log.w(
                    "LocalScribe",
                    "MediaPipe GPU init failed (${t.message}); falling back to CPU.",
                    t,
                )
            }
        }
        return MediaPipeLocalLlm(context, modelPath, maxTokens, supportsVision, "cpu")
    }
}

private class MediaPipeLocalLlm(
    context: Context,
    modelPath: String,
    maxTokens: Int,
    override val supportsVision: Boolean,
    processingMode: String = "cpu",
) : LocalLlm {
    override val activeBackend: String = processingMode
    private var engine: LlmInference? = run {
        val builder = LlmInferenceOptions.builder()
            .setModelPath(modelPath)
            .setMaxTokens(maxTokens)
            .setMaxTopK(100)
        // setPreferredBackend is only available in newer tasks-genai builds; guard with reflection-safe call
        builder.setPreferredBackend(
            if (processingMode == "gpu") MpBackend.GPU else MpBackend.CPU
        )
        LlmInference.createFromOptions(context.applicationContext, builder.build())
    }

    override fun generate(prompt: String): String {
        val e = engine ?: throw IllegalStateException("MediaPipe LLM is closed")
        return e.generateResponse(prompt)
    }

    /**
     * MediaPipe .task multimodal inference is not available through `tasks-genai` alone
     * (requires the `tasks-vision` artifact which we don't ship). Fall back to text-only
     * and warn loudly so the user can pick a LiteRT-LM model for vision.
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

    override fun sizeInTokens(prompt: String): Int {
        val e = engine ?: throw IllegalStateException("MediaPipe LLM is closed")
        return e.sizeInTokens(prompt)
    }

    override fun close() {
        try { engine?.close() } catch (_: Exception) {}
        engine = null
    }
}

private class LiteRtLmLocalLlm(
    modelPath: String,
    @Suppress("UNUSED_PARAMETER") maxTokens: Int,
    override val supportsVision: Boolean,
    processingMode: String = "cpu",
) : LocalLlm {
    override val activeBackend: String = processingMode
    private var engine: LiteRtEngine? = null

    init {
        val backend = if (processingMode == "gpu") LiteRtBackend.GPU() else LiteRtBackend.CPU()
        Log.i(
            "LocalScribe",
            "[LiteRT] Initializing engine: backend=$processingMode, supportsVision=$supportsVision, " +
                "visionBackend=${if (supportsVision) processingMode else "null (text-only)"}"
        )
        val config = LiteRtEngineConfig(
            modelPath = modelPath,
            backend = backend,
            // Enable vision backend only for models that support it.
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

    override fun generate(prompt: String): String {
        val e = engine ?: throw IllegalStateException("LiteRT-LM engine is closed")
        // A fresh Conversation per call keeps each correction independent (no accumulated
        // history that would consume context tokens across requests).
        return e.createConversation().use { conversation ->
            conversation.sendMessage(prompt).toString()
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
        // Google's reference (gallery/LlmChatModelHelper.kt) uses PNG bytes for Content.ImageBytes —
        // the native LiteRT-LM image decoder expects lossless PNG, not JPEG. Using JPEG silently
        // produces an unusable image (the model behaves as if no image was attached).
        val bmp = images.first()
        val bmpStream = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, bmpStream)
        val imgBytes = bmpStream.toByteArray()
        Log.d(
            "LocalScribe",
            "[LiteRT] Sending image to model: ${bmp.width}x${bmp.height}, pngBytes=${imgBytes.size}"
        )
        return e.createConversation().use { conversation ->
            conversation.sendMessage(
                LiteRtContents.of(
                    LiteRtContent.ImageBytes(imgBytes),
                    LiteRtContent.Text(prompt),
                )
            ).toString()
        }
    }

    /**
     * LiteRT-LM's Kotlin API does not expose a public tokenizer count method, so we fall
     * back to a character-based approximation. The engine still enforces the model's
     * compiled-in context length internally during generation.
     */
    override fun sizeInTokens(prompt: String): Int {
        // Rough heuristic: ~4 chars per token for English text.
        return (prompt.length / 4).coerceAtLeast(1)
    }

    override fun close() {
        try { engine?.close() } catch (_: Exception) {}
        engine = null
    }
}
