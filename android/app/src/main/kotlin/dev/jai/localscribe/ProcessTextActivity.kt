package dev.jai.localscribe

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.IOException
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInference.LlmInferenceOptions

class ProcessTextActivity : FlutterActivity() {

    private val CHANNEL = "process_text"
    private val PREFS_NAME = "local_llm_prefs"
    private val KEY_MODEL_PATH = "model_path"
    private val KEY_CUSTOM_PROMPTS = "custom_prompts"
    private val KEY_SHOW_PREVIEW = "show_preview"
    private val KEY_SHOW_CONTEXT = "show_context"
    private val KEY_API_MODE = "api_mode"
    private val KEY_API_KEY = "api_key"
    private val KEY_API_MODEL = "api_model"
    private val KEY_MAX_TOKENS = "max_tokens"
    private val KEY_OUTPUT_TOKENS = "output_tokens"

    private val DEFAULT_MODEL_PATH = "/data/local/tmp/llm/model.task"
    private val DEFAULT_API_MODE = "local"
    private val DEFAULT_API_MODEL = "gemini-2.5-flash"
    private val DEFAULT_MAX_TOKENS = 512
    private val DEFAULT_OUTPUT_TOKENS = 128

    private var llm: LlmInference? = null
    private var currentModelPath: String? = null
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private var inputText: String = ""
    private var isReadOnly: Boolean = true

    override fun onCreate(savedInstanceState: Bundle?) {
        inputText = intent?.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString() ?: ""
        isReadOnly = intent?.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true) ?: true
        super.onCreate(savedInstanceState)
    }

    override fun getDartEntrypointFunctionName(): String = "processTextMain"

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "getProcessTextData" -> {
                        result.success(mapOf(
                            "text" to inputText,
                            "readOnly" to isReadOnly
                        ))
                    }

                    "getPrompts" -> {
                        result.success(getPromptsForUi())
                    }

                    "getShowPreview" -> {
                        result.success(getShowPreview())
                    }

                    "getShowContext" -> {
                        result.success(getShowContext())
                    }

                    "generate" -> {
                        val text = call.argument<String>("text") ?: ""
                        val command = call.argument<String>("command") ?: ""
                        val arg = call.argument<String>("arg")
                        val context = call.argument<String>("context") ?: ""

                        val isScribe = command == "scribe"
                        ioScope.launch {
                            try {
                                val prompt = if (isScribe) {
                                    buildScribePrompt(text, context)
                                } else {
                                    val customTask = getCustomTaskIfAny(command)
                                    val task = customTask ?: mapCommandToTask(command, arg)
                                    buildTaggedPrompt(task, text, context)
                                }

                                val raw = withTimeout(20_000) {
                                    generateAccordingToMode(prompt, jsonMode = !isScribe)
                                }

                                val processed = if (isScribe) {
                                    removeThinkOnly(raw).trim()
                                } else {
                                    postProcessOutput(raw)
                                }

                                withContext(Dispatchers.Main) {
                                    result.success(processed)
                                }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("GEN_FAIL", e.message, null)
                                }
                            }
                        }
                    }

                    "finishWithResult" -> {
                        val text = call.argument<String>("text") ?: ""
                        val resultIntent = Intent().apply {
                            putExtra(Intent.EXTRA_PROCESS_TEXT, text)
                        }
                        setResult(RESULT_OK, resultIntent)
                        finish()
                        result.success(true)
                    }

                    "dismiss" -> {
                        setResult(RESULT_CANCELED)
                        finish()
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        try {
            llm?.close()
            llm = null
        } catch (_: Exception) {}
        super.onDestroy()
    }

    // ---- Prompt building ----

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

    private fun getCustomTaskIfAny(cmd: String): String? {
        val custom = getCustomPrompts()
        val prompt = custom.optString(cmd, "").trim()
        return prompt.ifBlank { null }
    }

    // ---- Output processing ----

    private fun postProcessOutput(raw: String): String {
        var text = removeThinkOnly(raw)
        text = stripJsonWrappers(text)
        val jsonOut = extractJsonOutput(text)
        text = jsonOut ?: text.trim()
        return normalizeLineBreaks(text).trim()
    }

    private fun removeThinkOnly(raw: String): String {
        return raw.replace(Regex("(?is)<\\s*think\\b[^>]*>.*?</\\s*think\\s*>"), "").trim()
    }

    private fun extractJsonOutput(raw: String): String? {
        val cleaned = stripJsonWrappers(raw).trim()
        if (!cleaned.startsWith("{")) return null

        try {
            val obj = JSONObject(cleaned)
            val out = obj.optString("output", "")
            if (out.isNotBlank()) return out
            if (obj.has("output")) return ""
        } catch (_: Exception) {}

        val marker = "\"output\""
        val idx = cleaned.indexOf(marker)
        if (idx == -1) return null
        val start = cleaned.lastIndexOf("{", idx)
        val end = cleaned.indexOf("}", idx)
        if (start == -1 || end == -1 || end <= start) return null

        return try {
            val obj = JSONObject(cleaned.substring(start, end + 1))
            obj.optString("output", "")
        } catch (_: Exception) { null }
    }

    private fun normalizeLineBreaks(text: String): String {
        return text.replace("\\r\\n", "\n").replace("\\n", "\n").replace("/n", "\n")
    }

    private fun stripJsonWrappers(raw: String): String {
        var text = raw.trim()
        if (text.startsWith("'''") && text.endsWith("'''") && text.length >= 6)
            text = text.substring(3, text.length - 3).trim()
        if (text.startsWith("\"\"\"") && text.endsWith("\"\"\"") && text.length >= 6)
            text = text.substring(3, text.length - 3).trim()
        if (text.startsWith("```")) {
            text = text.replace(Regex("^```[a-zA-Z]*\\s*"), "")
            text = text.replace(Regex("```$"), "")
        }
        return text.trim()
    }

    // ---- LLM generation ----

    private suspend fun generateAccordingToMode(prompt: String, jsonMode: Boolean = false): String {
        return when (getApiMode()) {
            "online" -> generateOnline(prompt, jsonMode)
            "best" -> tryOnlineThenLocal(prompt, jsonMode)
            else -> generateLocal(prompt)
        }
    }

    private fun generateLocal(prompt: String): String {
        val engine = ensureLlmReady()
            ?: throw IllegalStateException("LLM not ready. Pick a model first.")
        val maxInputTokens = (getMaxTokens() - getOutputTokens()).coerceAtLeast(1)
        val tokens = engine.sizeInTokens(prompt)
        if (tokens > maxInputTokens) {
            throw IllegalStateException(
                "Input too long for model (tokens=$tokens, maxInput=$maxInputTokens)"
            )
        }
        return engine.generateResponse(prompt)
    }

    private suspend fun tryOnlineThenLocal(prompt: String, jsonMode: Boolean = false): String {
        val key = getApiKey()
        val model = getApiModel()
        if (key.isNotBlank() && isInternetAvailable()) {
            try { return callGemini(prompt, key, model, jsonMode) } catch (_: Exception) {}
        }
        return generateLocal(prompt)
    }

    private suspend fun generateOnline(prompt: String, jsonMode: Boolean = false): String {
        val key = getApiKey()
        val model = getApiModel()
        if (key.isBlank()) throw IllegalStateException("No API key set \u2014 add one in AI Settings")
        if (!isInternetAvailable()) throw IllegalStateException("No internet connection")
        return callGemini(prompt, key, model, jsonMode)
    }

    private suspend fun callGemini(prompt: String, apiKey: String, model: String, jsonMode: Boolean = false): String =
        withContext(Dispatchers.IO) {
            val url = URL("https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
                setRequestProperty("X-Goog-Api-Key", apiKey)
            }
            val body = JSONObject().apply {
                put("contents", JSONArray().apply {
                    put(JSONObject().apply {
                        put("role", "user")
                        put("parts", JSONArray().apply {
                            put(JSONObject().put("text", prompt))
                        })
                    })
                })
                if (jsonMode && model.startsWith("gemini")) {
                    put("generationConfig", JSONObject().put("responseMimeType", "application/json"))
                }
            }
            conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = BufferedReader(InputStreamReader(stream)).use { it.readText() }
            if (code !in 200..299) throw IOException("Gemini API error: $text")
            val json = JSONObject(text)
            val candidates = json.optJSONArray("candidates") ?: return@withContext ""
            if (candidates.length() == 0) return@withContext ""
            val first = candidates.getJSONObject(0)
            val contentObj = first.optJSONObject("content") ?: return@withContext ""
            val partsArr = contentObj.optJSONArray("parts") ?: return@withContext ""
            if (partsArr.length() == 0) return@withContext ""
            partsArr.getJSONObject(0).optString("text", "")
        }

    // ---- LLM init ----

    private fun ensureLlmReady(): LlmInference? {
        val path = getSavedModelPath()
        if (!File(path).exists()) { llm = null; currentModelPath = null; return null }
        if (llm != null && currentModelPath == path) return llm
        return try {
            llm?.close()
            val options = LlmInferenceOptions.builder()
                .setModelPath(path)
                .setMaxTokens(getMaxTokens())
                .setMaxTopK(100)
                .build()
            llm = LlmInference.createFromOptions(applicationContext, options)
            currentModelPath = path
            llm
        } catch (_: Exception) {
            llm = null; currentModelPath = null; null
        }
    }

    // ---- SharedPreferences helpers ----

    private fun getSavedModelPath(): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY_MODEL_PATH, DEFAULT_MODEL_PATH) ?: DEFAULT_MODEL_PATH
    }

    private fun getShowPreview(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_SHOW_PREVIEW, false)
    }

    private fun getShowContext(): Boolean {
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

    private fun getCustomPrompts(): JSONObject {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_CUSTOM_PROMPTS, "{}") ?: "{}"
        return try { JSONObject(raw) } catch (_: Exception) { JSONObject() }
    }

    private fun isBuiltInKeyword(keyword: String): Boolean {
        return when (keyword) {
            "fix", "rewrite", "scribe", "summ", "polite", "casual",
            "expand", "translate", "bullet", "improve", "rephrase", "formal" -> true
            else -> false
        }
    }

    private fun getPromptsForUi(): List<Map<String, Any>> {
        val list = mutableListOf<Map<String, Any>>()
        list.add(mapOf("keyword" to "fix", "prompt" to "Correct grammar, spelling, and punctuation in the input text. Keep the same language. Return only the corrected text.", "builtIn" to true))
        list.add(mapOf("keyword" to "rewrite", "prompt" to "Rewrite the input text. You may add a style like formal, short, or friendly. Keep the same language. Preserve meaning. Return only the rewritten text.", "builtIn" to true))
        list.add(mapOf("keyword" to "scribe", "prompt" to "Respond in the same language as the input. Provide only the most relevant and complete answer. Do not add explanations, introductions, or extra text. Output only the answer.", "builtIn" to true))
        list.add(mapOf("keyword" to "summ", "prompt" to "Summarize the text in one or two sentences in the same language. Return only the summary.", "builtIn" to true))
        list.add(mapOf("keyword" to "polite", "prompt" to "Rewrite the text in a polite and professional tone in the same language. Return only the rewritten text.", "builtIn" to true))
        list.add(mapOf("keyword" to "casual", "prompt" to "Rewrite the text in a casual and friendly tone in the same language. Return only the rewritten text.", "builtIn" to true))
        list.add(mapOf("keyword" to "expand", "prompt" to "Expand the text with more detail while keeping the same language. Return only the expanded version.", "builtIn" to true))
        list.add(mapOf("keyword" to "translate", "prompt" to "Translate the text into English. Return only the translated text.", "builtIn" to true))
        list.add(mapOf("keyword" to "bullet", "prompt" to "Convert the text into clear bullet points. Keep the same language. Return only the list.", "builtIn" to true))
        list.add(mapOf("keyword" to "improve", "prompt" to "Improve writing clarity and quality while keeping meaning and language the same. Return only the improved text.", "builtIn" to true))
        list.add(mapOf("keyword" to "rephrase", "prompt" to "Rephrase the text completely while keeping the same meaning and language. Return only the rephrased text.", "builtIn" to true))
        list.add(mapOf("keyword" to "formal", "prompt" to "Rewrite the text in a formal, professional tone in the same language. Return only the rewritten text.", "builtIn" to true))

        val custom = getCustomPrompts()
        val keys = custom.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value = custom.optString(key, "")
            if (value.isNotBlank()) {
                list.add(mapOf("keyword" to key, "prompt" to value, "builtIn" to false))
            }
        }
        return list
    }
}
