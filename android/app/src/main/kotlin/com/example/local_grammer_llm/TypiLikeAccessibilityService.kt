package com.example.local_grammer_llm

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.graphics.PixelFormat
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Bundle
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions
import kotlinx.coroutines.*
import java.io.BufferedReader
import java.io.File
import java.io.IOException
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

class TypiLikeAccessibilityService : AccessibilityService() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var llm: LlmInference? = null

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

    private val DEFAULT_MODEL_PATH = "/data/local/tmp/llm/model.task"
    private val DEFAULT_API_MODE = "local"
    private val DEFAULT_API_MODEL = "gemini-2.5-flash"
    private val LLM_MAX_TOKENS = 512
    private val LLM_OUTPUT_TOKENS = 128

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
    private var overlayPreviewApply: Button? = null

    private var overlayContextBox: View? = null
    private var overlayContextCard: View? = null
    private var overlayContextInput: EditText? = null
    private var overlayContextCancel: Button? = null
    private var overlayContextOk: Button? = null

    private val wm by lazy { getSystemService(Context.WINDOW_SERVICE) as WindowManager }

    // generation control
    private var genJob: Job? = null
    private var generationId: Int = 0

    // prevent preview/context hangs if overlay disappears
    private var previewDeferred: CompletableDeferred<Boolean>? = null
    private var contextDeferred: CompletableDeferred<ContextDecision>? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        ensureLlmReady()
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

                // Context UI (context only)
                var contextText = ""
                if (isShowContextEnabled() && parsed.command != "scribe") {
                    val ctx = awaitContextInput(myGenId)
                    if (ctx.include) contextText = ctx.text
                    withContext(Dispatchers.Main) { showLoadingUi() }
                }

                val finalPrompt = if (parsed.command == "scribe") {
                    buildScribePrompt(parsed.before.trimEnd(), contextText)
                } else {
                    val customTask = getCustomTaskIfAny(parsed.command)
                    val task = customTask ?: mapCommandToTask(parsed.command, parsed.arg)

                    // ✅ Tag-delimited input + JSON output requirement
                    buildTaggedPrompt(
                        task = task,
                        text = parsed.before.trimEnd(),
                        context = contextText
                    )
                }

                val raw = withTimeout(20_000) { generateAccordingToMode(finalPrompt) }

                val resultText = if (parsed.command == "scribe") {
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
            } catch (e: Exception) {
                Log.e("LocalScribe", "Generation error: ${e.message}", e)
            } finally {
                withContext(Dispatchers.Main) { hideOverlay() }
                busy = false
            }
        }
    }



    override fun onInterrupt() {}

    override fun onDestroy() {
        hideOverlay()
        try { llm?.close() } catch (_: Exception) {}
        llm = null
        scope.cancel()
        super.onDestroy()
    }

    // ------------------------------------------------------------
    // Prompt system (TAG-DELIMITED INPUT + JSON OUTPUT)
    // ------------------------------------------------------------

    private fun buildTaggedPrompt(task: String, text: String, context: String?): String {
        val ctx = context?.trim().orEmpty()

        val rules = """
Keep the same language as the input unless the task says otherwise.
Keep the SAME point of view and pronouns (do NOT change I/you/She/He/they).
Preserve the original meaning and intent exactly.
Do not add new facts or remove unique details.
keep names, numbers,dates and places unchanged.
Do not mention the task, rules, or context in the output.
Output only the final answer (no explanations, no quotes, no formatting).
""".trimIndent()

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

[CONTEXT]
${if (ctx.isBlank()) "(none)" else ctx}
[/CONTEXT]

[RULES]
$rules
[/RULES]

[TEXT]
$text
[/TEXT]
""".trimIndent()
    }

    private fun buildScribePrompt(text: String, context: String?): String {
        val ctx = context?.trim().orEmpty()
        return if (ctx.isBlank()) {
            "Respond in the same language as the input. Provide only the final answer. No explanations. Input: \"$text\""
        } else {
            "Respond in the same language as the input. Use this context: \"$ctx\". Provide only the final answer. No explanations. Input: \"$text\""
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
            text = text.replace(Regex("```$"), "")
        }
        return text.trim()
    }

    // ------------------------------------------------------------
    // Local/Online generation (online runs on IO)
    // ------------------------------------------------------------

    private suspend fun generateAccordingToMode(prompt: String): String {
        return when (getApiMode()) {
            "online" -> generateOnline(prompt)
            "best" -> tryOnlineThenLocal(prompt)
            else -> generateLocal(prompt)
        }
    }

    private fun generateLocal(prompt: String): String {
        val engine = ensureLlmReady() ?: throw IllegalStateException("LLM not ready")
        ensurePromptFits(engine, prompt)
        return engine.generateResponse(prompt)
    }

    private fun ensurePromptFits(engine: LlmInference, prompt: String) {
        val maxInputTokens = (LLM_MAX_TOKENS - LLM_OUTPUT_TOKENS).coerceAtLeast(1)
        val tokens = engine.sizeInTokens(prompt)
        if (tokens <= maxInputTokens) return
        throw IllegalStateException(
            "Input too long for model (tokens=$tokens, maxInput=$maxInputTokens). " +
                "Shorten the input or use a model with a higher token limit."
        )
    }

    private suspend fun tryOnlineThenLocal(prompt: String): String {
        val key = getApiKey()
        val model = getApiModel()
        if (key.isNotBlank() && isInternetAvailable()) {
            try {
                return callGemini(prompt, key, model)
            } catch (_: Exception) {
                // fall back to local
            }
        }
        return generateLocal(prompt)
    }

    private suspend fun generateOnline(prompt: String): String {
        val key = getApiKey()
        val model = getApiModel()
        if (key.isBlank()) throw IllegalStateException("API key not set")
        if (!isInternetAvailable()) throw IllegalStateException("No internet connection")
        return callGemini(prompt, key, model)
    }

    private suspend fun callGemini(prompt: String, apiKey: String, model: String): String =
        withContext(Dispatchers.IO) {
            val url = URL("https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
                setRequestProperty("X-Goog-Api-Key", apiKey)
            }

            val body = org.json.JSONObject().apply {
                put("contents", org.json.JSONArray().apply {
                    put(org.json.JSONObject().apply {
                        put("role", "user")
                        put("parts", org.json.JSONArray().apply {
                            put(org.json.JSONObject().put("text", prompt))
                        })
                    })
                })
            }

            conn.outputStream.use { os ->
                os.write(body.toString().toByteArray(Charsets.UTF_8))
            }

            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = BufferedReader(InputStreamReader(stream)).use { it.readText() }
            if (code !in 200..299) throw IOException("Gemini API error: $text")

            val json = org.json.JSONObject(text)
            val candidates = json.optJSONArray("candidates") ?: return@withContext ""
            if (candidates.length() == 0) return@withContext ""
            val first = candidates.getJSONObject(0)
            val contentObj = first.optJSONObject("content") ?: return@withContext ""
            val partsArr = contentObj.optJSONArray("parts") ?: return@withContext ""
            if (partsArr.length() == 0) return@withContext ""
            return@withContext partsArr.getJSONObject(0).optString("text", "")
        }

    // ------------------------------------------------------------
    // LLM init (model-path validation + reuse)
    // ------------------------------------------------------------

    private fun ensureLlmReady(): LlmInference? {
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
            val options = LlmInferenceOptions.builder()
                .setModelPath(modelPath)
                .setMaxTokens(LLM_MAX_TOKENS)
                .setMaxTopK(100)
                .build()
            llm = LlmInference.createFromOptions(applicationContext, options)
            currentModelPath = modelPath
            llm
        } catch (e: Exception) {
            Log.e("LocalScribe", "Failed to init LLM: ${e.message}", e)
            llm = null
            currentModelPath = null
            null
        }
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
        val re = Regex("""(?i)\?($pattern)(?:\s+(\w+))?\b""")

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
        val re = Regex("""(?i)\?($pattern)(?:\s+\w+)?\b""")

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
        overlayPreviewApply = view.findViewById(R.id.btnPreviewApply)

        overlayContextBox = view.findViewById(R.id.contextBox)
        overlayContextCard = view.findViewById(R.id.contextCard)
        overlayContextInput = view.findViewById(R.id.contextInput)
        overlayContextCancel = view.findViewById(R.id.btnContextCancel)
        overlayContextOk = view.findViewById(R.id.btnContextOk)

        overlayCancelButton?.setOnClickListener { onCancel() }

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

        wm.addView(view, params)
        overlayView = view
    }

    private fun hideOverlay() {
        // prevent deferred hangs
        previewDeferred?.takeIf { !it.isCompleted }?.complete(false)
        previewDeferred = null
        contextDeferred?.takeIf { !it.isCompleted }?.complete(ContextDecision(false, ""))
        contextDeferred = null

        overlayView?.let {
            try { wm.removeView(it) } catch (_: Exception) {}
        }
        overlayView = null
        overlayLoadingCard = null
        overlayProgress = null
        overlayCancelButton = null

        overlayPreviewBox = null
        overlayPreviewCard = null
        overlayPreviewScroll = null
        overlayPreviewText = null
        overlayPreviewCancel = null
        overlayPreviewApply = null

        overlayContextBox = null
        overlayContextCard = null
        overlayContextInput = null
        overlayContextCancel = null
        overlayContextOk = null
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
        overlayPreviewApply?.setOnClickListener { onApply() }
    }

    private fun showContextUi(onCancel: () -> Unit, onOk: () -> Unit) {
        overlayContextInput?.setText("")
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

    private data class ContextDecision(val include: Boolean, val text: String)

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
                    decision.complete(ContextDecision(false, text))
                },
                onOk = {
                    if (decision.isCompleted) return@showContextUi
                    val text = overlayContextInput?.text?.toString().orEmpty()
                    decision.complete(ContextDecision(true, text))
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
