package dev.jai.localscribe

import android.content.Context
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions
import com.google.ai.edge.litertlm.Backend as LiteRtBackend
import com.google.ai.edge.litertlm.Engine as LiteRtEngine
import com.google.ai.edge.litertlm.EngineConfig as LiteRtEngineConfig
import java.io.File

/**
 * Thin runtime-agnostic facade over on-device LLMs.
 * Supports MediaPipe `.task` bundles and LiteRT-LM `.litertlm` models.
 */
interface LocalLlm {
    /** Runs one-shot generation and returns the model's raw response text. */
    fun generate(prompt: String): String

    /**
     * Returns an approximate token count for [prompt]. Implementations may return a
     * best-effort character-based estimate if the underlying runtime does not expose a tokenizer.
     */
    fun sizeInTokens(prompt: String): Int

    /** Releases native resources. Safe to call multiple times. */
    fun close()
}

object LocalLlmFactory {
    fun create(context: Context, modelPath: String, maxTokens: Int): LocalLlm {
        val ext = File(modelPath).extension.lowercase()
        return when (ext) {
            "task" -> MediaPipeLocalLlm(context, modelPath, maxTokens)
            "litertlm" -> LiteRtLmLocalLlm(modelPath, maxTokens)
            else -> throw IllegalStateException(
                "Unsupported model format: .$ext (expected .task or .litertlm)"
            )
        }
    }
}

private class MediaPipeLocalLlm(
    context: Context,
    modelPath: String,
    maxTokens: Int,
) : LocalLlm {
    private var engine: LlmInference? = run {
        val options = LlmInferenceOptions.builder()
            .setModelPath(modelPath)
            .setMaxTokens(maxTokens)
            .setMaxTopK(100)
            .build()
        LlmInference.createFromOptions(context.applicationContext, options)
    }

    override fun generate(prompt: String): String {
        val e = engine ?: throw IllegalStateException("MediaPipe LLM is closed")
        return e.generateResponse(prompt)
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
) : LocalLlm {
    private var engine: LiteRtEngine? = null

    init {
        val config = LiteRtEngineConfig(
            modelPath = modelPath,
            backend = LiteRtBackend.CPU(),
            // maxNumTokens must be null — passing an explicit value triggers LiteRT-LM's
            // magic-number replacement which mismatches the RESHAPE op's output shape spec,
            // causing "num_input_elements != num_output_elements" at inference time.
            maxNumTokens = null,
        )
        val e = LiteRtEngine(config)
        e.initialize()
        engine = e
    }

    override fun generate(prompt: String): String {
        val e = engine ?: throw IllegalStateException("LiteRT-LM engine is closed")
        // A fresh Conversation per call keeps each correction independent (no accumulated
        // history that would consume context tokens across requests).
        return e.createConversation().use { conversation ->
            conversation.sendMessage(prompt).toString()
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
