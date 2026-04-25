package dev.jai.localscribe

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

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

    private val DEFAULT_MODEL_PATH = "/data/local/tmp/llm/model.litertlm"
    private val DEFAULT_API_MODE = "local"
    private val DEFAULT_API_MODEL = "gemini-2.5-flash"
    private val DEFAULT_MAX_TOKENS = 512
    private val DEFAULT_OUTPUT_TOKENS = 128
    private val KEY_MODEL_SUPPORTS_VISION = "model_supports_vision"
    private val NON_VISION_GEMINI_MODELS = setOf("gemma-3n-e2b-it", "gemma-3n-e4b-it")
    private val CROP_SCREENSHOT_REQUEST = 7021

    private var llm: LocalLlm? = null
    private var currentModelPath: String? = null
    private var currentVisionSupport: Boolean = false
    private var currentProcessingMode: String? = null
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var methodChannel: MethodChannel? = null
    /** Holds the pending MethodChannel.Result for an in-progress captureScreenshot call. */
    private var pendingCaptureResult: MethodChannel.Result? = null

    private var inputText: String = ""
    private var isReadOnly: Boolean = true

    override fun onCreate(savedInstanceState: Bundle?) {
        inputText = intent?.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString() ?: ""
        isReadOnly = intent?.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true) ?: true
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        inputText = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString() ?: ""
        isReadOnly = intent.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, true)
        methodChannel?.invokeMethod("onNewText", mapOf(
            "text" to inputText,
            "readOnly" to isReadOnly
        ))
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine {
        return (applicationContext as LocalScribeApp).getOrCreateProcessTextEngine()
    }

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
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

                    "getModelSupportsVision" -> {
                        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                        result.success(prefs.getBoolean(KEY_MODEL_SUPPORTS_VISION, true))
                    }

                    "captureScreenshot" -> {
                        val svc = TypiLikeAccessibilityService.instance
                        if (svc == null) {
                            result.error("NO_SERVICE", "Accessibility service not running — enable it in Settings to use screenshot capture", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
                            result.error("API_TOO_LOW", "Screenshot capture requires Android 11+", null)
                            return@setMethodCallHandler
                        }
                        if (pendingCaptureResult != null) {
                            result.error("BUSY", "Already capturing a screenshot", null)
                            return@setMethodCallHandler
                        }
                        pendingCaptureResult = result
                        ioScope.launch {
                            val bitmap = try {
                                ScreenshotCaptureHelper.captureViaA11y(svc)
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    pendingCaptureResult?.error("CAPTURE_FAIL", e.message, null)
                                    pendingCaptureResult = null
                                }
                                return@launch
                            }
                            val screenshotFile = try {
                                val dir = File(cacheDir, "ls_screenshots").apply { mkdirs() }
                                val f = File(dir, "ss_${System.currentTimeMillis()}.png")
                                FileOutputStream(f).use { bitmap.compress(Bitmap.CompressFormat.PNG, 90, it) }
                                bitmap.recycle()
                                f
                            } catch (e: Exception) {
                                bitmap.recycle()
                                withContext(Dispatchers.Main) {
                                    pendingCaptureResult?.error("SAVE_FAIL", e.message, null)
                                    pendingCaptureResult = null
                                }
                                return@launch
                            }
                            withContext(Dispatchers.Main) {
                                val intent = Intent(this@ProcessTextActivity, CropActivity::class.java).apply {
                                    putExtra(CropActivity.EXTRA_SCREENSHOT_PATH, screenshotFile.absolutePath)
                                }
                                @Suppress("DEPRECATION")
                                startActivityForResult(intent, CROP_SCREENSHOT_REQUEST)
                            }
                        }
                    }

                    "generate" -> {
                        val text = call.argument<String>("text") ?: ""
                        val command = call.argument<String>("command") ?: ""
                        val arg = call.argument<String>("arg")
                        val context = call.argument<String>("context") ?: ""
                        val imagePath = call.argument<String>("imagePath")

                        ioScope.launch {
                            try {
                                val customTask = getCustomTaskIfAny(command)
                                val isCustom = customTask != null
                                val kind = PromptBuilder.classify(command, isCustom)
                                // For built-in `rewrite` the arg is already baked into the task
                                // by mapBuiltInTask; pass null so PromptBuilder doesn't also
                                // append it as a "Style modifier" line and duplicate it.
                                val argForBuilder = if (!isCustom && command == "rewrite") null else arg
                                val task = customTask ?: PromptBuilder.mapBuiltInTask(command, arg)
                                val built = PromptBuilder.build(
                                    task = task,
                                    text = text,
                                    context = context,
                                    arg = argForBuilder,
                                    hasImage = imagePath != null,
                                    kind = kind,
                                )

                                val raw = withTimeout(if (imagePath != null) 120_000L else 20_000L) {
                                    generateAccordingToMode(built.prompt, jsonMode = built.jsonMode, imagePath = imagePath)
                                }

                                val processed = if (built.jsonMode) {
                                    postProcessOutput(raw)
                                } else {
                                    removeThinkOnly(raw).trim()
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

        // Push text to Dart so the cached engine gets the new text
        channel.invokeMethod("onNewText", mapOf(
            "text" to inputText,
            "readOnly" to isReadOnly
        ))
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == CROP_SCREENSHOT_REQUEST) {
            val pending = pendingCaptureResult
            pendingCaptureResult = null
            if (resultCode == Activity.RESULT_OK) {
                val cropPath = data?.getStringExtra(CropActivity.EXTRA_CROP_PATH)
                pending?.success(cropPath)
            } else {
                pending?.success(null)
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }

    override fun onDestroy() {
        // Don't close — the engine is owned by [SharedLlm] for the whole
        // app process and is probably still serving the accessibility
        // service or the chat screen. Just drop our local reference.
        llm = null
        super.onDestroy()
    }

    // ---- Prompt building ----
    // Prompt assembly lives in [PromptBuilder]. The only thing this class
    // still owns is loading the user's own custom prompts from prefs so the
    // dispatcher above can decide whether to treat the keyword as built-in
    // or custom.

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
            text = text.replace(Regex("```\\s*$"), "")
        }
        return text.trim()
    }

    // ---- LLM generation ----

    private suspend fun generateAccordingToMode(prompt: String, jsonMode: Boolean = false, imagePath: String? = null): String {
        return when (getApiMode()) {
            "online" -> generateOnline(prompt, jsonMode, imagePath)
            "best" -> tryOnlineThenLocal(prompt, jsonMode, imagePath)
            else -> if (imagePath != null) generateLocalWithImage(prompt, imagePath) else generateLocal(prompt)
        }
    }

    private fun generateLocalWithImage(prompt: String, imagePath: String): String {
        val engine = ensureLlmReady() ?: throw IllegalStateException("LLM not ready. Pick a model first.")
        Log.d("LocalScribe", "[ProcessText] imagePath=$imagePath supportsVision=${engine.supportsVision}")
        if (!engine.supportsVision) {
            Log.w("LocalScribe", "[ProcessText] Model does not support vision, ignoring image")
            return engine.generate(prompt)
        }
        // Downscale aggressively to keep vision-token count low. LiteRT-LM
        // Gemma3's 2520-patch ceiling is easy to hit with portrait screenshots
        // at higher resolutions — 768 long-edge can push prefill over 3s on
        // mid-range devices, stalling the UI thread. 512 cuts patches ~2x
        // while remaining readable for typical text-extraction flows.
        val bmp = try { ImageUtils.decodeDownscaled(imagePath, 512) } catch (_: Exception) { null }
        if (bmp == null) {
            Log.w("LocalScribe", "[ProcessText] decodeDownscaled returned null for $imagePath, falling back to text-only")
            return engine.generate(prompt)
        }
        return try {
            Log.d("LocalScribe", "[ProcessText] Sending image (${bmp.width}x${bmp.height}) to LLM")
            engine.generate(prompt, listOf(bmp))
        } catch (e: Exception) {
            Log.w("LocalScribe", "Multimodal generation failed, retrying text-only: ${e.message}")
            engine.generate(prompt)
        } finally {
            bmp.recycle()
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
        return engine.generate(prompt)
    }

    private suspend fun tryOnlineThenLocal(prompt: String, jsonMode: Boolean = false, imagePath: String? = null): String {
        val key = getApiKey()
        val model = getApiModel()
        if (key.isNotBlank() && isInternetAvailable()) {
            try { return callGemini(prompt, key, model, jsonMode, imagePath) } catch (e: Exception) {
                Log.w("LocalScribe", "[best] Gemini failed, falling back to local: ${e.message}")
            }
        }
        return if (imagePath != null) generateLocalWithImage(prompt, imagePath) else generateLocal(prompt)
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
        imagePath: String? = null
    ): String = withContext(Dispatchers.IO) {
        val effectiveModel = if (imagePath != null && model in NON_VISION_GEMINI_MODELS) "gemini-2.5-flash" else model
        val url = URL("https://generativelanguage.googleapis.com/v1beta/models/$effectiveModel:generateContent")

        // Downscale + JPEG-encode the image once to keep payload size reasonable.
        val imgBytes: ByteArray? = if (imagePath != null) {
            try {
                val bmp = ImageUtils.decodeDownscaled(imagePath, 1024)
                if (bmp != null) {
                    val out = ByteArrayOutputStream()
                    bmp.compress(Bitmap.CompressFormat.JPEG, 85, out)
                    bmp.recycle()
                    out.toByteArray()
                } else null
            } catch (_: Exception) { null }
        } else null

        val partsArray = JSONArray()
        if (imgBytes != null) {
            partsArray.put(JSONObject().apply {
                put("inlineData", JSONObject().apply {
                    put("mimeType", "image/jpeg")
                    put("data", Base64.encodeToString(imgBytes, Base64.NO_WRAP))
                })
            })
        }
        partsArray.put(JSONObject().put("text", prompt))
        val body = JSONObject().apply {
            put("contents", JSONArray().apply {
                put(JSONObject().apply {
                    put("role", "user")
                    put("parts", partsArray)
                })
            })
            if (jsonMode && effectiveModel.startsWith("gemini")) {
                put("generationConfig", JSONObject().put("responseMimeType", "application/json"))
            }
        }
        val bodyBytes = body.toString().toByteArray(Charsets.UTF_8)

        var lastError: String? = null
        for (attempt in 0..1) {
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Content-Type", "application/json; charset=utf-8")
                setRequestProperty("X-Goog-Api-Key", apiKey)
            }
            try {
                conn.outputStream.use { it.write(bodyBytes) }
                val code = conn.responseCode
                val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                val text = BufferedReader(InputStreamReader(stream)).use { it.readText() }
                if (code in 200..299) {
                    val json = JSONObject(text)
                    val candidates = json.optJSONArray("candidates") ?: return@withContext ""
                    if (candidates.length() == 0) return@withContext ""
                    val first = candidates.getJSONObject(0)
                    val contentObj = first.optJSONObject("content") ?: return@withContext ""
                    val partsArr = contentObj.optJSONArray("parts") ?: return@withContext ""
                    if (partsArr.length() == 0) return@withContext ""
                    return@withContext buildString {
                        for (i in 0 until partsArr.length()) {
                            val part = partsArr.getJSONObject(i)
                            if (!part.optBoolean("thought", false)) {
                                append(part.optString("text", ""))
                            }
                        }
                    }.trim()
                }
                lastError = text
                if (attempt == 0 && (code == 500 || code == 503)) {
                    Log.w("LocalScribe", "Gemini HTTP $code (transient), retrying once")
                    delay(500)
                    continue
                }
                throw IOException("Gemini API error: $text")
            } finally {
                try { conn.disconnect() } catch (_: Exception) {}
            }
        }
        throw IOException("Gemini API error: ${lastError ?: "unknown"}")
    }

    // ---- LLM init ----

    @Synchronized
    private fun ensureLlmReady(): LocalLlm? {
        val path = getSavedModelPath()
        val visionSupport = getModelVisionSupport(path)
        val processingMode = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString("processing_mode", "cpu") ?: "cpu"

        // Share a single process-wide engine with the accessibility service
        // and (via invalidate hooks) the chat activity. Pre-holder, opening
        // this popup after the service had warmed up spent ~13 s cold-initing
        // a second copy of the same model in the same process.
        // Read committed sampler params so the share-popup engine matches
        // whatever the user applied in AI Settings. Without this the holder
        // keyed on default SamplerParams() and never rebuilt on edits.
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val sampler = SamplerParams(
            temperature = prefs.getFloat("sampler_temperature", 0.3f),
            topK = prefs.getInt("sampler_top_k", 40),
            topP = prefs.getFloat("sampler_top_p", 0.9f),
        )
        val engine = SharedLlm.acquire(
            applicationContext,
            SharedLlm.Key(
                modelPath = path,
                maxTokens = getMaxTokens(),
                supportsVision = visionSupport,
                processingMode = processingMode,
                sampler = sampler,
            ),
        )
        llm = engine
        currentModelPath = if (engine != null) path else null
        currentVisionSupport = visionSupport
        currentProcessingMode = processingMode
        return engine
    }

    private fun getModelVisionSupport(@Suppress("UNUSED_PARAMETER") modelPath: String): Boolean = true

    // ---- SharedPreferences helpers ----

    private fun getSavedModelPath(): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY_MODEL_PATH, DEFAULT_MODEL_PATH) ?: DEFAULT_MODEL_PATH
    }

    private fun getShowPreview(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_SHOW_PREVIEW, true)
    }

    private fun getShowContext(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_SHOW_CONTEXT, true)
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
