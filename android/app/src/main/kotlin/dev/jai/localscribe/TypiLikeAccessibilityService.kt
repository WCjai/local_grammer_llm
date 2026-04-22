package dev.jai.localscribe

import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.PixelFormat
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.util.Base64
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import kotlinx.coroutines.*
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import android.widget.Toast

class QuotaExhaustedException(message: String) : IOException(message)

class TypiLikeAccessibilityService : AccessibilityService() {

    companion object {
        /**
         * Set just before [CropActivity] is launched. CropActivity completes this deferred
         * with the crop file path (or null on cancel). Using a companion object allows the
         * crop activity (running in the same process) to communicate back to this service
         * without needing startActivityForResult (which AccessibilityService doesn't support).
         */
        @Volatile
        var pendingCropDeferred: CompletableDeferred<String?>? = null

        /** Live service instance — set in [onServiceConnected], cleared in [onUnbind]. */
        @Volatile
        var instance: TypiLikeAccessibilityService? = null
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var llm: LocalLlm? = null

    // ---- prefs ----
    private val PREFS_NAME = "local_llm_prefs"
    private val KEY_MODEL_PATH = "model_path"
    private val KEY_SERVICE_ENABLED = "service_enabled"
    private val KEY_CUSTOM_PROMPTS = "custom_prompts"
    private val KEY_SHOW_PREVIEW = "show_preview"
    private val KEY_SHOW_CONTEXT = "show_context"
    private val KEY_API_MODE = "api_mode"
    private val KEY_API_KEY = "api_key"
    private val KEY_API_MODEL = "api_model"
    private val KEY_MAX_TOKENS = "max_tokens"
    private val KEY_OUTPUT_TOKENS = "output_tokens"
    private val KEY_MODEL_SUPPORTS_VISION = "model_supports_vision"

    /** Gemini API models that don't accept images natively; auto-promote to gemini-2.5-flash for multimodal. */
    private val NON_VISION_GEMINI_MODELS = setOf("gemma-3n-e2b-it", "gemma-3n-e4b-it")

    private val DEFAULT_MODEL_PATH = "/data/local/tmp/llm/model.task"
    private val DEFAULT_API_MODE = "local"
    private val DEFAULT_API_MODEL = "gemini-2.5-flash"
    private val DEFAULT_MAX_TOKENS = 512
    private val DEFAULT_OUTPUT_TOKENS = 128

    private var currentModelPath: String? = null

    // Avoid re-trigger loops
    private var busy = false
    private var lastAppliedHash: Int = 0

    // overlay
    private var overlayView: View? = null
    private var overlayLoadingCard: View? = null
    private var overlayProgress: ProgressBar? = null
    private var overlayCancelButton: Button? = null

    private var overlayPreviewBox: View? = null
    private var overlayPreviewCard: View? = null
    private var overlayPreviewScroll: ScrollView? = null
    private var overlayPreviewText: TextView? = null
    private var overlayPreviewCancel: Button? = null
    private var overlayPreviewCopy: Button? = null
    private var overlayPreviewApply: Button? = null

    private var overlayContextBox: View? = null
    private var overlayContextCard: View? = null
    private var overlayContextInput: EditText? = null
    private var overlayContextCancel: Button? = null
    private var overlayContextOk: Button? = null

    // ---- screenshot attachment views ----
    private var overlayBtnAttachScreenshot: ImageButton? = null
    private var overlayAttachedThumbWrap: View? = null
    private var overlayAttachedThumb: ImageView? = null
    private var overlayBtnDetachScreenshot: ImageButton? = null

    /** Persists across overlay show/hide so the pipeline can pick it up. */
    private var attachedScreenshotPath: String? = null
    /** Saved so we can re-add the overlay view to WM after it was detached for screenshot. */
    private var overlayLayoutParams: WindowManager.LayoutParams? = null
    /** Running crop capture coroutine — cancelled when overlay is dismissed. */
    private var captureJob: Job? = null

    private val wm by lazy { getSystemService(Context.WINDOW_SERVICE) as WindowManager }

    // generation control
    private var genJob: Job? = null
    private var generationId: Int = 0

    // prevent preview/context hangs if overlay disappears
    private var previewDeferred: CompletableDeferred<Boolean>? = null
    private var contextDeferred: CompletableDeferred<ContextDecision>? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event == null) return
        if (!isServiceEnabled()) return
        if (busy) return

        val type = event.eventType
        if (type != AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED &&
            type != AccessibilityEvent.TYPE_VIEW_FOCUSED
        ) return

        val node = event.source ?: return
        val editable = findEditableNode(node) ?: return

        val currentText = editable.text?.toString() ?: return
        if (currentText.isBlank()) return

        // Prevent infinite loops: if we just set this exact content, ignore
        val hash = currentText.hashCode()
        if (hash == lastAppliedHash) return

        val parsed = parseLastCommand(currentText) ?: return
        if (genJob?.isActive == true) return

        busy = true

        genJob = scope.launch {
            val myGenId = ++generationId

            withContext(Dispatchers.Main) {
                showOverlay {
                    genJob?.cancel()
                    generationId++

                    val target = getFocusedEditableNode() ?: editable
                    val cur = target.text?.toString().orEmpty()
                    val cleaned = removeLastCommand(cur)
                    if (cleaned != cur) {
                        setNodeText(target, cleaned)
                        lastAppliedHash = cleaned.hashCode()
                    }

                    hideOverlay()
                    busy = false
                }
            }

            try {
                if (parsed.before.trim().isEmpty()) {
                    withContext(Dispatchers.Main) {
                        val target = getFocusedEditableNode() ?: editable
                        val cur = target.text?.toString().orEmpty()
                        val cleaned = removeLastCommand(cur)
                        if (cleaned != cur) {
                            setNodeText(target, cleaned)
                            lastAppliedHash = cleaned.hashCode()
                        }
                    }
                    return@launch
                }

                // Context UI (text + optional screenshot)
                var contextText = ""
                var contextImagePath: String? = null
                if (isShowContextEnabled()) {
                    val ctx = awaitContextInput(myGenId)
                    if (ctx.include) {
                        contextText = ctx.text
                        contextImagePath = ctx.imagePath
                    }
                    withContext(Dispatchers.Main) { showLoadingUi() }
                }

                val hasImage = contextImagePath != null
                val finalPrompt = if (parsed.command == "scribe") {
                    buildScribePrompt(parsed.before.trimEnd(), contextText, hasImage)
                } else {
                    val customTask = getCustomTaskIfAny(parsed.command)
                    val task = customTask ?: mapCommandToTask(parsed.command, parsed.arg)

                    // ✅ Tag-delimited input + JSON output requirement
                    buildTaggedPrompt(
                        task = task,
                        text = parsed.before.trimEnd(),
                        context = contextText,
                        hasImage = hasImage,
                    )
                }

                val isScribe = parsed.command == "scribe"
                val timeoutMs = if (contextImagePath != null) 120_000L else 20_000L
                val raw = withTimeout(timeoutMs) { generateAccordingToMode(finalPrompt, jsonMode = !isScribe, imagePath = contextImagePath) }

                val resultText = if (isScribe) {
                    removeThinkOnly(raw).trim()
                } else {
                    postProcessOutput(raw) // extracts {"output": "..."} if possible
                }

                if (resultText.isNotBlank()) {
                    val newText = resultText + parsed.after

                    if (isShowPreviewEnabled()) {
                        val apply = awaitPreviewDecision(newText, editable, myGenId)
                        if (apply) {
                            withContext(Dispatchers.Main) {
                                if (myGenId != generationId) return@withContext
                                val target = getFocusedEditableNode() ?: editable
                                if (setNodeText(target, newText)) {
                                    lastAppliedHash = newText.hashCode()
                                }
                            }
                        }
                    } else {
                        withContext(Dispatchers.Main) {
                            if (myGenId != generationId) return@withContext
                            val target = getFocusedEditableNode() ?: editable
                            if (setNodeText(target, newText)) {
                                lastAppliedHash = newText.hashCode()
                            }
                        }
                    }
                }
            } catch (_: CancellationException) {
                // cancelled
            } catch (_: TimeoutCancellationException) {
                // timeout
            } catch (e: QuotaExhaustedException) {
                Log.e("LocalScribe", "API quota exhausted: ${e.message}")
                withContext(Dispatchers.Main) {
                    val target = getFocusedEditableNode() ?: editable
                    val cur = target.text?.toString().orEmpty()
                    val cleaned = removeLastCommand(cur)
                    if (cleaned != cur) {
                        setNodeText(target, cleaned)
                        lastAppliedHash = cleaned.hashCode()
                    }
                    Toast.makeText(
                        this@TypiLikeAccessibilityService,
                        "API quota exceeded \u2014 please wait or switch to local mode",
                        Toast.LENGTH_LONG
                    ).show()
                }
            } catch (e: Exception) {
                Log.e("LocalScribe", "Generation error: ${e.message}", e)
                withContext(Dispatchers.Main) {
                    val target = getFocusedEditableNode() ?: editable
                    val cur = target.text?.toString().orEmpty()
                    val cleaned = removeLastCommand(cur)
                    if (cleaned != cur) {
                        setNodeText(target, cleaned)
                        lastAppliedHash = cleaned.hashCode()
                    }
                    val msg = when {
                        e.message?.contains("API key", ignoreCase = true) == true ->
                            "No API key set \u2014 add one in AI Settings"
                        e.message?.contains("internet", ignoreCase = true) == true ->
                            "No internet connection"
                        else -> "Generation failed: ${e.message ?: "unknown error"}"
                    }
                    Toast.makeText(
                        this@TypiLikeAccessibilityService,
                        msg,
                        Toast.LENGTH_LONG
                    ).show()
                }
            } finally {
                withContext(Dispatchers.Main) { hideOverlay() }
                busy = false
            }
        }
    }



    override fun onInterrupt() {}

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        hideOverlay()
        try { llm?.close() } catch (_: Exception) {}
        llm = null
        scope.cancel()
        super.onDestroy()
    }

    // ------------------------------------------------------------
    // Prompt system (TAG-DELIMITED INPUT + JSON OUTPUT)
    // ------------------------------------------------------------

    private fun buildTaggedPrompt(task: String, text: String, context: String?, hasImage: Boolean = false): String {
        val ctx = context?.trim().orEmpty()

        val contextSection = when {
            ctx.isNotBlank() -> """
[CONTEXT]
$ctx
[/CONTEXT]"""
            else -> ""
        }

        val imageSection = if (hasImage) """
[IMAGE_CONTEXT]
A screenshot is attached. Use it as visual reference to understand the subject matter, identify key details, and improve the quality of the output. The image and the text below refer to the same topic.
[/IMAGE_CONTEXT]""" else ""

        val rules = buildString {
            appendLine("Keep the same language as the input unless the task says otherwise.")
            appendLine("Keep the SAME point of view and pronouns (do NOT change I/you/She/He/they).")
            appendLine("Preserve the original meaning and intent exactly.")
            appendLine("Do not add new facts or remove unique details.")
            appendLine("Keep names, numbers, dates and places unchanged.")
            appendLine("Do not mention the task, rules, or context in the output.")
            if (hasImage && ctx.isNotBlank())
                appendLine("The screenshot and the context text together form the background — use both to inform the task.")
            else if (hasImage)
                appendLine("Use insights from the attached screenshot to inform the task.")
            else if (ctx.isNotBlank())
                appendLine("Use the provided context to inform the task.")
            append("Output only the final answer (no explanations, no quotes, no formatting).")
        }.trimEnd()

        return """
You are a writing engine.

OUTPUT FORMAT (mandatory):
Return ONLY valid JSON exactly like:
{"output":"..."}
No other keys. No extra text. No markdown.
If you cannot comply, return: {"output":""}

[TASK]
$task
[/TASK]
$contextSection
$imageSection
[RULES]
$rules
[/RULES]

[TEXT]
$text
[/TEXT]
""".trimIndent()
    }

    private fun buildScribePrompt(text: String, context: String?, hasImage: Boolean = false): String {
        val ctx = context?.trim().orEmpty()
        val hasCtx = ctx.isNotBlank()

        return buildString {
            append("Respond in the same language as the input. Provide only the final answer. No explanations.")
            if (hasCtx && hasImage) {
                append(" The following context and the attached screenshot both provide background — use them together: \"$ctx\".")
            } else if (hasCtx) {
                append(" Use this context: \"$ctx\".")
            } else if (hasImage) {
                append(" An attached screenshot provides visual context — use it to inform your response.")
            }
            append(" Input: \"$text\"")
        }
    }

    private fun mapCommandToTask(cmd: String, arg: String?): String {
        return when (cmd) {
            "fix" -> "Correct grammar, spelling, and punctuation in the same language."
            "rewrite" -> {
                when (arg?.lowercase()) {
                    "formal" -> "Rewrite the text in a formal and professional tone in the same language."
                    "friendly" -> "Rewrite the text in a friendly tone in the same language."
                    "short" -> "Rewrite the text shorter while preserving meaning in the same language."
                    else -> "Rewrite the text clearly while preserving meaning in the same language."
                }
            }
            "polite" -> "Rewrite the text in a polite and professional tone in the same language."
            "casual" -> "Rewrite the text in a casual and friendly tone in the same language."
            "summ" -> "Summarize the text in one or two sentences in the same language."
            "expand" -> "Expand the text with more detail while keeping the same language."
            "translate" -> "Translate the text into English."
            "bullet" -> "Convert the text into clear bullet points in the same language."
            "improve" -> "Improve writing clarity and quality while keeping meaning and language the same."
            "rephrase" -> "Rephrase the text completely while keeping the same meaning and language."
            "formal" -> "Rewrite the text in a formal, professional tone in the same language."
            else -> "Rewrite the text clearly while preserving meaning in the same language."
        }
    }

    // Custom prompts support:
    // - If user provided a custom prompt for cmd, use it as the TASK text in [TASK] ... [/TASK].
    private fun getCustomTaskIfAny(cmd: String): String? {
        val custom = getCustomPrompts()
        val customPrompt = custom.optString(cmd, "").trim()
        return customPrompt.ifBlank { null }
    }

    // ------------------------------------------------------------
    // Output processing
    // ------------------------------------------------------------

    private fun postProcessOutput(raw: String): String {
        var text = removeThinkOnly(raw)
        text = stripJsonWrappers(text)

        // Try JSON output extraction first
        val jsonOut = extractJsonOutput(text)
        if (jsonOut != null) {
            text = jsonOut
        } else {
            // Fallback: if a model returned plain text, accept it (last resort)
            text = text.trim()
        }

        return normalizeLineBreaks(text).trim()
    }

    private fun removeThinkOnly(raw: String): String {
        return raw.replace(Regex("(?is)<\\s*think\\b[^>]*>.*?</\\s*think\\s*>"), "").trim()
    }

    private fun extractJsonOutput(raw: String): String? {
        val cleaned = stripJsonWrappers(raw).trim()
        if (!cleaned.startsWith("{")) return null

        // Fast path: exact JSON
        try {
            val obj = org.json.JSONObject(cleaned)
            val out = obj.optString("output", "")
            if (out.isNotBlank()) return out
            if (obj.has("output")) return "" // explicit empty output
        } catch (_: Exception) {}

        // Fallback: find a JSON object containing "output"
        val marker = "\"output\""
        val idx = cleaned.indexOf(marker)
        if (idx == -1) return null
        val start = cleaned.lastIndexOf("{", idx)
        val end = cleaned.indexOf("}", idx)
        if (start == -1 || end == -1 || end <= start) return null

        return try {
            val obj = org.json.JSONObject(cleaned.substring(start, end + 1))
            obj.optString("output", "").also { /* may be empty */ }
        } catch (_: Exception) {
            null
        }
    }

    private fun normalizeLineBreaks(text: String): String {
        return text
            .replace("\\r\\n", "\n")
            .replace("\\n", "\n")
            .replace("/n", "\n")
    }

    private fun stripJsonWrappers(raw: String): String {
        var text = raw.trim()
        if (text.startsWith("'''") && text.endsWith("'''") && text.length >= 6) {
            text = text.substring(3, text.length - 3).trim()
        }
        if (text.startsWith("\"\"\"") && text.endsWith("\"\"\"") && text.length >= 6) {
            text = text.substring(3, text.length - 3).trim()
        }
        if (text.startsWith("```")) {
            text = text.replace(Regex("^```[a-zA-Z]*\\s*"), "")
            text = text.replace(Regex("```\\s*$"), "")
        }
        return text.trim()
    }

    // ------------------------------------------------------------
    // Local/Online generation (online runs on IO)
    // ------------------------------------------------------------

    private suspend fun generateAccordingToMode(prompt: String, jsonMode: Boolean = false, imagePath: String? = null): String {
        return when (getApiMode()) {
            "online" -> generateOnline(prompt, jsonMode, imagePath)
            "best" -> tryOnlineThenLocal(prompt, jsonMode, imagePath)
            else -> generateLocalWithImage(prompt, imagePath)
        }
    }

    private fun generateLocal(prompt: String): String {
        val engine = ensureLlmReady() ?: throw IllegalStateException("LLM not ready")
        ensurePromptFits(engine, prompt)
        return engine.generate(prompt)
    }

    private fun generateLocalWithImage(prompt: String, imagePath: String?): String {
        val engine = ensureLlmReady() ?: throw IllegalStateException("LLM not ready")
        ensurePromptFits(engine, prompt)
        Log.d("LocalScribe", "[Service] imagePath=$imagePath supportsVision=${engine.supportsVision}")
        if (imagePath != null && engine.supportsVision) {
            // Downscale to cap vision-token count (LiteRT-LM patch limits) and reduce latency.
            val bitmap = try { ImageUtils.decodeDownscaled(imagePath, 1024) } catch (_: Exception) { null }
            if (bitmap != null) {
                try {
                    Log.d("LocalScribe", "[Service] Sending image (${bitmap.width}x${bitmap.height}) to LLM")
                    return engine.generate(prompt, listOf(bitmap))
                } catch (e: Exception) {
                    Log.w("LocalScribe", "Multimodal local generation failed, falling back to text-only: ${e.message}")
                } finally {
                    bitmap.recycle()
                }
            } else {
                Log.w("LocalScribe", "[Service] decodeDownscaled returned null for $imagePath")
            }
        }
        return engine.generate(prompt)
    }

    private fun ensurePromptFits(engine: LocalLlm, prompt: String) {
        val maxInputTokens = (getMaxTokens() - getOutputTokens()).coerceAtLeast(1)
        val tokens = engine.sizeInTokens(prompt)
        if (tokens <= maxInputTokens) return
        throw IllegalStateException(
            "Input too long for model (tokens=$tokens, maxInput=$maxInputTokens). " +
                "Shorten the input or use a model with a higher token limit."
        )
    }

    private suspend fun tryOnlineThenLocal(prompt: String, jsonMode: Boolean = false, imagePath: String? = null): String {
        val key = getApiKey()
        val model = getApiModel()
        if (key.isNotBlank() && isInternetAvailable()) {
            try {
                return callGemini(prompt, key, model, jsonMode, imagePath)
            } catch (e: QuotaExhaustedException) {
                throw e // don't fall back — surface quota error to user
            } catch (e: Exception) {
                Log.w("LocalScribe", "[best] Gemini failed, falling back to local: ${e.message}")
            }
        }
        return generateLocalWithImage(prompt, imagePath)
    }

    private suspend fun generateOnline(prompt: String, jsonMode: Boolean = false, imagePath: String? = null): String {
        val key = getApiKey()
        val model = getApiModel()
        if (key.isBlank()) throw IllegalStateException("No API key set \u2014 add one in AI Settings")
        if (!isInternetAvailable()) throw IllegalStateException("No internet connection")
        return callGemini(prompt, key, model, jsonMode, imagePath)
    }

    private suspend fun callGemini(
        prompt: String,
        apiKey: String,
        model: String,
        jsonMode: Boolean = false,
        imagePath: String? = null,
    ): String =
        withContext(Dispatchers.IO) {
            // Auto-promote text-only Gemma models when an image is attached
            val effectiveModel = if (imagePath != null && model in NON_VISION_GEMINI_MODELS) {
                Log.i("LocalScribe", "Auto-promoting $model → gemini-2.5-flash for multimodal call")
                "gemini-2.5-flash"
            } else model

            val url = URL("https://generativelanguage.googleapis.com/v1beta/models/$effectiveModel:generateContent")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
                setRequestProperty("X-Goog-Api-Key", apiKey)
            }

            val partsArray = org.json.JSONArray().apply {
                // Gemini recommends image BEFORE text for best grounding.
                if (imagePath != null) {
                    try {
                        val imageBytes = File(imagePath).readBytes()
                        val b64 = Base64.encodeToString(imageBytes, Base64.NO_WRAP)
                        put(org.json.JSONObject().apply {
                            put("inlineData", org.json.JSONObject().apply {
                                put("mimeType", "image/png")
                                put("data", b64)
                            })
                        })
                    } catch (e: Exception) {
                        Log.w("LocalScribe", "Could not attach image to Gemini request: ${e.message}")
                    }
                }
                put(org.json.JSONObject().put("text", prompt))
            }

            val body = org.json.JSONObject().apply {
                put("contents", org.json.JSONArray().apply {
                    put(org.json.JSONObject().apply {
                        put("role", "user")
                        put("parts", partsArray)
                    })
                })
                if (jsonMode && effectiveModel.startsWith("gemini")) {
                    put("generationConfig", org.json.JSONObject().put("responseMimeType", "application/json"))
                }
            }

            conn.outputStream.use { os ->
                os.write(body.toString().toByteArray(Charsets.UTF_8))
            }

            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = BufferedReader(InputStreamReader(stream)).use { it.readText() }
            if (code == 429) throw QuotaExhaustedException("API quota exceeded. Please wait or switch to local mode.")
            if (code !in 200..299) throw IOException("Gemini API error: $text")

            val json = org.json.JSONObject(text)
            val candidates = json.optJSONArray("candidates") ?: return@withContext ""
            if (candidates.length() == 0) return@withContext ""
            val first = candidates.getJSONObject(0)
            val contentObj = first.optJSONObject("content") ?: return@withContext ""
            val partsArr = contentObj.optJSONArray("parts") ?: return@withContext ""
            if (partsArr.length() == 0) return@withContext ""
            // Skip parts with "thought":true (Gemma 4 / thinking models emit reasoning chunks)
            return@withContext buildString {
                for (i in 0 until partsArr.length()) {
                    val part = partsArr.getJSONObject(i)
                    if (!part.optBoolean("thought", false)) {
                        append(part.optString("text", ""))
                    }
                }
            }.trim()
        }

    // ------------------------------------------------------------
    // LLM init (model-path validation + reuse)
    // ------------------------------------------------------------

    @Synchronized
    private fun ensureLlmReady(): LocalLlm? {
        val modelPath = getSavedModelPath()

        if (!File(modelPath).exists()) {
            Log.e("LocalScribe", "Model file not found: $modelPath")
            llm = null
            currentModelPath = null
            return null
        }

        if (llm != null && currentModelPath == modelPath) return llm

        return try {
            llm?.close()
            val visionSupport = getModelVisionSupport(modelPath)
            llm = LocalLlmFactory.create(applicationContext, modelPath, getMaxTokens(), visionSupport)
            currentModelPath = modelPath
            llm
        } catch (e: Exception) {
            Log.e("LocalScribe", "Failed to init LLM: ${e.message}", e)
            llm = null
            currentModelPath = null
            null
        }
    }

    /** Returns whether the user has indicated their model supports vision/image input. */
    private fun getModelVisionSupport(@Suppress("UNUSED_PARAMETER") modelPath: String): Boolean {
        return getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_MODEL_SUPPORTS_VISION, false)
    }

    /**
     * Returns true if the "Attach Screenshot" button should be enabled.
     * Requires API 30+. In local-only mode, also requires the loaded model to support vision.
     */
    private fun isAttachVisionEnabled(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        return getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_MODEL_SUPPORTS_VISION, false)
    }

    // ------------------------------------------------------------
    // Accessibility helpers (stale node fix)
    // ------------------------------------------------------------

    private fun getFocusedEditableNode(): AccessibilityNodeInfo? {
        val root = rootInActiveWindow ?: return null
        val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return null
        return findEditableNode(focused)
    }

    private fun findEditableNode(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isEditable) return node

        var p: AccessibilityNodeInfo? = node.parent
        var depth = 0
        while (p != null && depth < 6) {
            if (p.isEditable) return p
            p = p.parent
            depth++
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            if (child.isEditable) return child
        }
        return null
    }

    private fun setNodeText(node: AccessibilityNodeInfo, text: String): Boolean {
        if (!node.isEditable) return false
        val args = Bundle()
        args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    // ------------------------------------------------------------
    // Parsing commands
    // ------------------------------------------------------------

    data class Parsed(val before: String, val after: String, val command: String, val arg: String?)

    private fun parseLastCommand(full: String): Parsed? {
        val keywords = getAllKeywords()
        if (keywords.isEmpty()) return null
        val pattern = keywords.joinToString("|") { Regex.escape(it) }
        // Use colon-delimited arg (?rewrite:super-formal) so text after the command is preserved.
        // Argument charset allows hyphens so multi-word tags like `super-formal` parse intact.
        val re = Regex("""(?i)\?($pattern)(?::([\w-]+))?\b""")

        val matches = re.findAll(full).toList()
        if (matches.isEmpty()) return null
        val m = matches.last()

        val cmd = m.groupValues[1].lowercase()
        val arg = m.groupValues.getOrNull(2)?.ifBlank { null }

        val before = full.substring(0, m.range.first)
        val after = full.substring(m.range.last + 1)

        return Parsed(before, after, cmd, arg)
    }

    private fun removeLastCommand(full: String): String {
        val keywords = getAllKeywords()
        if (keywords.isEmpty()) return full
        val pattern = keywords.joinToString("|") { Regex.escape(it) }
        // Match colon-delimited arg only (?rewrite:super-formal), not space-separated
        val re = Regex("""(?i)\?($pattern)(?::[\w-]+)?\b""")

        val matches = re.findAll(full).toList()
        if (matches.isEmpty()) return full
        val m = matches.last()

        val before = full.substring(0, m.range.first)
        val after = full.substring(m.range.last + 1)
        return (before + after).trimEnd()
    }

    // ------------------------------------------------------------
    // Overlay UI
    // ------------------------------------------------------------

    private fun applyDarkOverlayTheme(view: View) {
        // Card backgrounds
        view.findViewById<View>(R.id.previewCard)?.setBackgroundResource(R.drawable.overlay_card_dark)
        view.findViewById<View>(R.id.contextCard)?.setBackgroundResource(R.drawable.overlay_card_dark)

        // Title text
        view.findViewById<TextView>(R.id.previewTitle)?.setTextColor(0xFFE8E4F4.toInt())
        view.findViewById<TextView>(R.id.contextTitle)?.setTextColor(0xFFE8E4F4.toInt())

        // Body text
        overlayPreviewText?.setTextColor(0xFFD0CCE4.toInt())
        overlayContextInput?.setTextColor(0xFFD0CCE4.toInt())
        overlayContextInput?.setHintTextColor(0xFF6A6090.toInt())

        // Dividers
        val dividerColor = 0x18FFFFFF
        view.findViewById<View>(R.id.previewDivider1)?.setBackgroundColor(dividerColor)
        view.findViewById<View>(R.id.previewDivider2)?.setBackgroundColor(dividerColor)
        view.findViewById<View>(R.id.contextDivider1)?.setBackgroundColor(dividerColor)
        view.findViewById<View>(R.id.contextDivider2)?.setBackgroundColor(dividerColor)

        // Ghost buttons
        view.findViewById<Button>(R.id.btnPreviewCancel)?.apply {
            setBackgroundResource(R.drawable.ghost_rect_dark)
            setTextColor(0xFF9B80E8.toInt())
        }
        view.findViewById<Button>(R.id.btnPreviewCopy)?.apply {
            setBackgroundResource(R.drawable.ghost_rect_dark)
            setTextColor(0xFF9B80E8.toInt())
        }
        view.findViewById<Button>(R.id.btnContextCancel)?.apply {
            setBackgroundResource(R.drawable.ghost_rect_dark)
            setTextColor(0xFF9B80E8.toInt())
        }
    }

    private fun showOverlay(onCancel: () -> Unit) {
        if (overlayView != null) return

        val view = LayoutInflater.from(this).inflate(R.layout.llm_overlay, null, false)

        overlayLoadingCard = view.findViewById(R.id.loadingCard)
        overlayProgress = view.findViewById(R.id.progress)
        overlayCancelButton = view.findViewById(R.id.btnCancel)

        overlayPreviewBox = view.findViewById(R.id.previewBox)
        overlayPreviewCard = view.findViewById(R.id.previewCard)
        overlayPreviewScroll = view.findViewById(R.id.previewScroll)

        overlayPreviewText = view.findViewById(R.id.previewText)
        overlayPreviewCancel = view.findViewById(R.id.btnPreviewCancel)
        overlayPreviewCopy = view.findViewById(R.id.btnPreviewCopy)
        overlayPreviewApply = view.findViewById(R.id.btnPreviewApply)

        overlayContextBox = view.findViewById(R.id.contextBox)
        overlayContextCard = view.findViewById(R.id.contextCard)
        overlayContextInput = view.findViewById(R.id.contextInput)
        overlayContextCancel = view.findViewById(R.id.btnContextCancel)
        overlayContextOk = view.findViewById(R.id.btnContextOk)

        overlayBtnAttachScreenshot = view.findViewById(R.id.btnAttachScreenshot)
        overlayAttachedThumbWrap = view.findViewById(R.id.attachedThumbWrap)
        overlayAttachedThumb = view.findViewById(R.id.attachedThumb)
        overlayBtnDetachScreenshot = view.findViewById(R.id.btnDetachScreenshot)

        overlayCancelButton?.setOnClickListener { onCancel() }

        // Apply dark mode theming if enabled
        val flutterPrefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        if (flutterPrefs.getBoolean("flutter.is_dark_mode", false)) {
            applyDarkOverlayTheme(view)
        }

        // Keep your existing sizing behavior
        scaleLoadingUiPercent()

        showLoadingUi()

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_FULLSCREEN,
            PixelFormat.TRANSLUCENT
        )
        params.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE

        overlayLayoutParams = params
        wm.addView(view, params)
        overlayView = view
    }

    private fun hideOverlay() {
        // Cancel any in-flight crop operation first
        captureJob?.cancel()
        captureJob = null
        pendingCropDeferred?.takeIf { !it.isCompleted }?.complete(null)
        pendingCropDeferred = null

        // prevent deferred hangs
        previewDeferred?.takeIf { !it.isCompleted }?.complete(false)
        previewDeferred = null
        contextDeferred?.takeIf { !it.isCompleted }?.complete(ContextDecision(false, ""))
        contextDeferred = null

        overlayView?.let {
            try { wm.removeView(it) } catch (_: Exception) {}
        }
        overlayView = null
        overlayLayoutParams = null
        overlayLoadingCard = null
        overlayProgress = null
        overlayCancelButton = null

        overlayPreviewBox = null
        overlayPreviewCard = null
        overlayPreviewScroll = null
        overlayPreviewText = null
        overlayPreviewCancel = null
        overlayPreviewCopy = null
        overlayPreviewApply = null

        overlayContextBox = null
        overlayContextCard = null
        overlayContextInput = null
        overlayContextCancel = null
        overlayContextOk = null

        overlayBtnAttachScreenshot = null
        overlayAttachedThumbWrap = null
        overlayAttachedThumb = null
        overlayBtnDetachScreenshot = null
        attachedScreenshotPath = null
    }

    private fun showLoadingUi() {
        overlayLoadingCard?.visibility = View.VISIBLE
        overlayPreviewBox?.visibility = View.GONE
        overlayContextBox?.visibility = View.GONE
    }

    private fun showPreviewUi(text: String, onCancel: () -> Unit, onApply: () -> Unit) {
        overlayPreviewText?.text = text
        overlayPreviewBox?.visibility = View.VISIBLE
        overlayLoadingCard?.visibility = View.GONE
        overlayContextBox?.visibility = View.GONE

        capPreviewToTrue20Percent()

        overlayPreviewCancel?.setOnClickListener { onCancel() }
        overlayPreviewCopy?.setOnClickListener {
            val text = overlayPreviewText?.text?.toString().orEmpty()
            if (text.isNotEmpty()) {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("Local Scribe", text))
                Toast.makeText(this, "Copied to clipboard", Toast.LENGTH_SHORT).show()
            }
        }
        overlayPreviewApply?.setOnClickListener { onApply() }
    }

    private fun showContextUi(onCancel: () -> Unit, onOk: () -> Unit) {
        overlayContextInput?.setText("")
        // Reset attachment state for this fresh dialog session
        attachedScreenshotPath = null
        overlayAttachedThumbWrap?.visibility = View.GONE
        overlayBtnAttachScreenshot?.visibility = View.VISIBLE

        overlayContextBox?.visibility = View.VISIBLE
        overlayLoadingCard?.visibility = View.GONE
        overlayPreviewBox?.visibility = View.GONE

        overlayContextBox?.let { box ->
            ViewCompat.setOnApplyWindowInsetsListener(box) { v, insets ->
                val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
                v.setPadding(0, 0, 0, ime.bottom)
                insets
            }
            ViewCompat.requestApplyInsets(box)
        }

        capContextToTrue20Percent()

        overlayContextCancel?.setOnClickListener {
            hideKeyboard()
            onCancel()
        }
        overlayContextOk?.setOnClickListener {
            hideKeyboard()
            onOk()
        }

        // ---- Attach Screenshot button ----
        val attachBtn = overlayBtnAttachScreenshot
        if (attachBtn != null) {
            val visionEnabled = isAttachVisionEnabled()
            attachBtn.isEnabled = visionEnabled
            attachBtn.alpha = if (visionEnabled) 1.0f else 0.35f
            attachBtn.setOnClickListener {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                    Toast.makeText(this, "Screenshot capture requires Android 11+", Toast.LENGTH_SHORT).show()
                    return@setOnClickListener
                }
                captureJob?.cancel()
                captureJob = scope.launch { captureAndCrop() }
            }
        }

        overlayBtnDetachScreenshot?.setOnClickListener {
            attachedScreenshotPath = null
            overlayAttachedThumbWrap?.visibility = View.GONE
            overlayBtnAttachScreenshot?.visibility = View.VISIBLE
        }
    }

    /**
     * Temporarily removes the overlay from WindowManager (so it doesn't appear in the
     * screenshot), captures the screen, opens [CropActivity] for the user to select a region,
     * then re-adds the overlay and shows a thumbnail of the cropped image.
     */
    private suspend fun captureAndCrop() {
        val viewRef = overlayView ?: return
        val params = overlayLayoutParams ?: return

        // 1. Detach overlay so it's not visible in the screenshot
        withContext(Dispatchers.Main) {
            try { wm.removeView(viewRef) } catch (_: Exception) {}
            overlayView = null
        }
        // Small delay — give the compositor one vsync to redraw without our overlay
        delay(200)

        // 2. Capture the screen
        val bitmap = try {
            ScreenshotCaptureHelper.captureViaA11y(this@TypiLikeAccessibilityService)
        } catch (e: ScreenshotUnsupportedException) {
            withContext(Dispatchers.Main) {
                reAttachOverlay(viewRef, params)
                Toast.makeText(this@TypiLikeAccessibilityService, e.message, Toast.LENGTH_LONG).show()
            }
            return
        } catch (e: Exception) {
            withContext(Dispatchers.Main) {
                reAttachOverlay(viewRef, params)
                Toast.makeText(this@TypiLikeAccessibilityService, "Screenshot failed: ${e.message}", Toast.LENGTH_SHORT).show()
            }
            return
        }

        // 3. Write full screenshot to temp file (background)
        val screenshotFile = withContext(Dispatchers.IO) {
            try {
                val dir = File(cacheDir, "ls_screenshots").apply { mkdirs() }
                val f = File(dir, "ss_${System.currentTimeMillis()}.png")
                FileOutputStream(f).use { fos -> bitmap.compress(Bitmap.CompressFormat.PNG, 90, fos) }
                bitmap.recycle()
                f
            } catch (e: Exception) {
                bitmap.recycle()
                null
            }
        }

        if (screenshotFile == null) {
            withContext(Dispatchers.Main) {
                reAttachOverlay(viewRef, params)
                Toast.makeText(this@TypiLikeAccessibilityService, "Failed to save screenshot", Toast.LENGTH_SHORT).show()
            }
            return
        }

        // 4. Prepare a deferred to receive the crop result, then launch CropActivity
        val deferred = CompletableDeferred<String?>()
        pendingCropDeferred = deferred

        withContext(Dispatchers.Main) {
            val intent = Intent(this@TypiLikeAccessibilityService, CropActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(CropActivity.EXTRA_SCREENSHOT_PATH, screenshotFile.absolutePath)
            }
            startActivity(intent)
        }

        // 5. Wait for crop result (max 2 minutes; user may take time to crop)
        val cropPath = try {
            withTimeoutOrNull(120_000L) { deferred.await() }
        } finally {
            if (!deferred.isCompleted) deferred.complete(null)
            if (pendingCropDeferred === deferred) pendingCropDeferred = null
        }

        // Clean up the full screenshot temp file
        withContext(Dispatchers.IO) { screenshotFile.delete() }

        // 6. Re-attach the overlay and update the thumbnail
        withContext(Dispatchers.Main) {
            reAttachOverlay(viewRef, params)
            if (cropPath != null) {
                attachedScreenshotPath = cropPath
                val thumb = BitmapFactory.decodeFile(cropPath)
                if (thumb != null) {
                    val scaledThumb = Bitmap.createScaledBitmap(thumb, 112, 112, true)
                    overlayAttachedThumb?.setImageBitmap(scaledThumb)
                    overlayAttachedThumbWrap?.visibility = View.VISIBLE
                    overlayBtnAttachScreenshot?.visibility = View.GONE
                    if (thumb !== scaledThumb) thumb.recycle()
                }
            }
        }
    }

    private fun reAttachOverlay(view: View, params: WindowManager.LayoutParams) {
        try { wm.addView(view, params) } catch (_: Exception) {}
        overlayView = view
        overlayLayoutParams = params
    }

    private fun hideKeyboard() {
        val imm = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        val token = overlayContextInput?.windowToken
        if (token != null) imm.hideSoftInputFromWindow(token, 0)
    }

    // ---- preview/context awaiters (no hangs) ----

    private suspend fun awaitPreviewDecision(
        previewText: String,
        editable: AccessibilityNodeInfo,
        genId: Int
    ): Boolean {
        val decision = CompletableDeferred<Boolean>()
        previewDeferred = decision

        withContext(Dispatchers.Main) {
            if (genId != generationId) {
                if (!decision.isCompleted) decision.complete(false)
                return@withContext
            }

            showPreviewUi(
                previewText,
                onCancel = {
                    if (decision.isCompleted) return@showPreviewUi

                    val target = getFocusedEditableNode() ?: editable
                    val cur = target.text?.toString().orEmpty()
                    val cleaned = removeLastCommand(cur)
                    if (cleaned != cur) {
                        setNodeText(target, cleaned)
                        lastAppliedHash = cleaned.hashCode()
                    }
                    decision.complete(false)
                },
                onApply = {
                    if (!decision.isCompleted) decision.complete(true)
                }
            )
        }

        val r = decision.await()
        if (previewDeferred === decision) previewDeferred = null
        return r
    }

    private data class ContextDecision(val include: Boolean, val text: String, val imagePath: String? = null)

    private suspend fun awaitContextInput(genId: Int): ContextDecision {
        val decision = CompletableDeferred<ContextDecision>()
        contextDeferred = decision

        withContext(Dispatchers.Main) {
            if (genId != generationId) {
                if (!decision.isCompleted) decision.complete(ContextDecision(false, ""))
                return@withContext
            }

            showContextUi(
                onCancel = {
                    if (decision.isCompleted) return@showContextUi
                    val text = overlayContextInput?.text?.toString().orEmpty()
                    decision.complete(ContextDecision(false, text, imagePath = null))
                },
                onOk = {
                    if (decision.isCompleted) return@showContextUi
                    val text = overlayContextInput?.text?.toString().orEmpty()
                    decision.complete(ContextDecision(true, text, imagePath = attachedScreenshotPath))
                }
            )
        }

        val r = decision.await()
        if (contextDeferred === decision) contextDeferred = null
        return r
    }

    // ------------------------------------------------------------
    // Sizing helpers (UNCHANGED)
    // ------------------------------------------------------------

    private fun dpToPx(dp: Float): Int {
        return (dp * resources.displayMetrics.density).toInt()
    }

    private fun scaleLoadingUiPercent() {
        val pb = overlayProgress ?: return
        val btn = overlayCancelButton ?: return

        val metrics = resources.displayMetrics
        val minDim = minOf(metrics.widthPixels, metrics.heightPixels).toFloat()

        val progressPx = (minDim * 0.30f).toInt()
        val cancelPx = (minDim * 0.22f).toInt()

        val progressClamped = progressPx.coerceIn(dpToPx(56f), dpToPx(160f))
        val cancelClamped = cancelPx.coerceIn(dpToPx(40f), dpToPx(120f))

        pb.layoutParams = pb.layoutParams.apply {
            width = progressClamped
            height = progressClamped
        }
        pb.requestLayout()

        btn.layoutParams = btn.layoutParams.apply {
            width = cancelClamped
            height = cancelClamped
        }
        btn.minWidth = cancelClamped
        btn.minHeight = cancelClamped

        val cancelDp = cancelClamped / metrics.density
        val textSp = (cancelDp * 0.38f).coerceIn(16f, 26f)
        btn.textSize = textSp
    }

    private fun capPreviewToTrue20Percent() {
        val card = overlayPreviewCard ?: return

        val screenH = resources.displayMetrics.heightPixels
        val maxCardH = (screenH * 0.60f).toInt()

        val screenW = resources.displayMetrics.widthPixels
        val maxW = (screenW - dpToPx(40f)).coerceAtLeast(dpToPx(240f))

        card.post {
            val wSpec = View.MeasureSpec.makeMeasureSpec(maxW, View.MeasureSpec.AT_MOST)
            val hSpec = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)

            card.layoutParams = card.layoutParams.apply {
                height = WindowManager.LayoutParams.WRAP_CONTENT
            }
            card.measure(wSpec, hSpec)

            val naturalH = card.measuredHeight
            val finalH = minOf(naturalH, maxCardH)

            card.layoutParams = card.layoutParams.apply {
                height = finalH
            }
            card.requestLayout()
        }
    }

    private fun capContextToTrue20Percent() {
        val card = overlayContextCard ?: return

        val screenH = resources.displayMetrics.heightPixels
        val maxCardH = (screenH * 0.60f).toInt()

        val screenW = resources.displayMetrics.widthPixels
        val maxW = (screenW - dpToPx(40f)).coerceAtLeast(dpToPx(240f))

        card.post {
            val wSpec = View.MeasureSpec.makeMeasureSpec(maxW, View.MeasureSpec.AT_MOST)
            val hSpec = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)

            card.layoutParams = card.layoutParams.apply {
                height = WindowManager.LayoutParams.WRAP_CONTENT
            }
            card.measure(wSpec, hSpec)

            val naturalH = card.measuredHeight
            val finalH = minOf(naturalH, maxCardH)

            card.layoutParams = card.layoutParams.apply {
                height = finalH
            }
            card.requestLayout()
        }
    }

    // ------------------------------------------------------------
    // Prefs + keyword list
    // ------------------------------------------------------------

    private fun getSavedModelPath(): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY_MODEL_PATH, DEFAULT_MODEL_PATH) ?: DEFAULT_MODEL_PATH
    }

    private fun isServiceEnabled(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_SERVICE_ENABLED, false)
    }

    private fun isShowPreviewEnabled(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_SHOW_PREVIEW, false)
    }

    private fun isShowContextEnabled(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_SHOW_CONTEXT, false)
    }

    private fun getApiMode(): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY_API_MODE, DEFAULT_API_MODE) ?: DEFAULT_API_MODE
    }

    private fun getApiKey(): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY_API_KEY, "") ?: ""
    }

    private fun getApiModel(): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY_API_MODEL, DEFAULT_API_MODEL) ?: DEFAULT_API_MODEL
    }

    private fun getMaxTokens(): Int {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getInt(KEY_MAX_TOKENS, DEFAULT_MAX_TOKENS)
    }

    private fun getOutputTokens(): Int {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getInt(KEY_OUTPUT_TOKENS, DEFAULT_OUTPUT_TOKENS)
    }

    private fun isInternetAvailable(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun getCustomPrompts(): org.json.JSONObject {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_CUSTOM_PROMPTS, "{}") ?: "{}"
        return try {
            org.json.JSONObject(raw)
        } catch (_: Exception) {
            org.json.JSONObject()
        }
    }

    private fun getAllKeywords(): List<String> {
        val base = mutableListOf(
            "fix", "rewrite", "scribe", "summ", "polite", "casual",
            "expand", "translate", "bullet", "improve", "rephrase", "formal"
        )
        val custom = getCustomPrompts()
        val keys = custom.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            if (k.isNotBlank()) base.add(k.lowercase())
        }
        return base.distinct()
    }
}
