package dev.jai.localscribe

import android.content.Context
import android.app.Activity
import android.content.ComponentName
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.accessibility.AccessibilityManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {

    private val CHANNEL = "local_llm"
    private val PROGRESS_CHANNEL = "local_llm_progress"
    private var llm: LocalLlm? = null
    private var initInProgress = false
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
    private val DEFAULT_MODEL_PATH = "/data/local/tmp/llm/model.task"
    private val DEFAULT_API_MODE = "local"
    private val DEFAULT_API_MODEL = "gemini-2.5-flash"
    private val DEFAULT_MAX_TOKENS = 512
    private val DEFAULT_OUTPUT_TOKENS = 128
    private var pendingPickResult: MethodChannel.Result? = null
    private val PICK_MODEL_REQUEST = 7010
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var progressSink: EventChannel.EventSink? = null
    private var currentModelPath: String? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, PROGRESS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    progressSink = events
                }

                override fun onCancel(arguments: Any?) {
                    progressSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {

                    "init" -> {
                        if (initInProgress) {
                            result.error("BUSY", "Init already in progress", null)
                            return@setMethodCallHandler
                        }
                        initInProgress = true
                        val modelPathArg = call.argument<String>("modelPath")
                        val modelPath = modelPathArg?.takeIf { it.isNotBlank() } ?: getSavedModelPath()

                        ioScope.launch {
                            try {
                                saveModelPath(modelPath)
                                // Pre-load model on background thread
                                ensureLlmReady()
                                withContext(Dispatchers.Main) {
                                    result.success(true)
                                }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("INIT_FAIL", e.message, null)
                                }
                            } finally {
                                initInProgress = false
                            }
                        }
                    }

                    "getModelPath" -> {
                        result.success(getSavedModelPath())
                    }

                    "hasModel" -> {
                        val path = getSavedModelPath()
                        result.success(File(path).exists())
                    }

                    "getModelName" -> {
                        val path = getSavedModelPath()
                        val name = try {
                            File(path).name
                        } catch (_: Exception) {
                            ""
                        }
                        result.success(name)
                    }

                    "isAccessibilityGranted" -> {
                        result.success(isAccessibilityServiceEnabled())
                    }

                    "getServiceEnabled" -> {
                        result.success(getServiceEnabled())
                    }

                    "setServiceEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        saveServiceEnabled(enabled)
                        result.success(true)
                    }

                    "getShowPreview" -> {
                        result.success(getShowPreview())
                    }

                    "setShowPreview" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        saveShowPreview(enabled)
                        result.success(true)
                    }

                    "getShowContext" -> {
                        result.success(getShowContext())
                    }

                    "setShowContext" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        saveShowContext(enabled)
                        result.success(true)
                    }

                    "getApiMode" -> {
                        result.success(getApiMode())
                    }

                    "setApiMode" -> {
                        val mode = call.argument<String>("mode")?.trim()?.lowercase()
                        if (mode.isNullOrBlank()) {
                            result.error("BAD_ARGS", "mode is required", null)
                            return@setMethodCallHandler
                        }
                        saveApiMode(mode)
                        result.success(true)
                    }

                    "getApiModel" -> {
                        result.success(getApiModel())
                    }

                    "setApiModel" -> {
                        val model = call.argument<String>("model")?.trim()
                        if (model.isNullOrBlank()) {
                            result.error("BAD_ARGS", "model is required", null)
                            return@setMethodCallHandler
                        }
                        saveApiModel(model)
                        result.success(true)
                    }

                    "getApiKey" -> {
                        result.success(getApiKey())
                    }

                    "setApiKey" -> {
                        val key = call.argument<String>("key")?.trim()
                        if (key.isNullOrBlank()) {
                            result.error("BAD_ARGS", "key is required", null)
                            return@setMethodCallHandler
                        }
                        saveApiKey(key)
                        result.success(true)
                    }

                    "validateApiKey" -> {
                        val model = call.argument<String>("model")?.trim()
                        val key = call.argument<String>("key")?.trim()
                        if (model.isNullOrBlank() || key.isNullOrBlank()) {
                            result.error("BAD_ARGS", "model and key are required", null)
                            return@setMethodCallHandler
                        }
                        ioScope.launch {
                            try {
                                val ok = validateApiKey(key, model)
                                withContext(Dispatchers.Main) {
                                    result.success(ok)
                                }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("VALIDATE_FAIL", e.message, null)
                                }
                            }
                        }
                    }

                    "openAccessibilitySettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_SETTINGS_FAIL", e.message, null)
                        }
                    }

                    "getPrompts" -> {
                        result.success(getPromptsForUi())
                    }

                    "addPrompt" -> {
                        val keyword = call.argument<String>("keyword")?.trim()?.lowercase()
                        val prompt = call.argument<String>("prompt")?.trim()
                        if (keyword.isNullOrBlank() || prompt.isNullOrBlank()) {
                            result.error("BAD_ARGS", "keyword and prompt are required", null)
                            return@setMethodCallHandler
                        }
                        if (isBuiltInKeyword(keyword)) {
                            result.error("READ_ONLY", "Cannot add or modify built-in prompt", null)
                            return@setMethodCallHandler
                        }
                        val updated = setCustomPrompt(keyword, prompt)
                        result.success(updated)
                    }

                    "updatePrompt" -> {
                        val oldKeyword = call.argument<String>("oldKeyword")?.trim()?.lowercase()
                        val keyword = call.argument<String>("keyword")?.trim()?.lowercase()
                        val prompt = call.argument<String>("prompt")?.trim()
                        if (keyword.isNullOrBlank() || prompt.isNullOrBlank()) {
                            result.error("BAD_ARGS", "keyword and prompt are required", null)
                            return@setMethodCallHandler
                        }
                        if (isBuiltInKeyword(keyword)) {
                            result.error("READ_ONLY", "Cannot edit built-in prompt", null)
                            return@setMethodCallHandler
                        }
                        if (!oldKeyword.isNullOrBlank() && oldKeyword != keyword) {
                            if (isBuiltInKeyword(oldKeyword)) {
                                result.error("READ_ONLY", "Cannot edit built-in prompt", null)
                                return@setMethodCallHandler
                            }
                            deleteCustomPrompt(oldKeyword)
                        }
                        val updated = setCustomPrompt(keyword, prompt)
                        result.success(updated)
                    }

                    "deletePrompt" -> {
                        val keyword = call.argument<String>("keyword")?.trim()?.lowercase()
                        if (keyword.isNullOrBlank()) {
                            result.error("BAD_ARGS", "keyword is required", null)
                            return@setMethodCallHandler
                        }
                        if (isBuiltInKeyword(keyword)) {
                            result.error("READ_ONLY", "Cannot delete built-in prompt", null)
                            return@setMethodCallHandler
                        }
                        val updated = deleteCustomPrompt(keyword)
                        result.success(updated)
                    }

                    "setModelPath" -> {
                        val modelPath = call.argument<String>("modelPath")
                        if (modelPath.isNullOrBlank()) {
                            result.error("BAD_ARGS", "modelPath is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            saveModelPath(modelPath)
                            llm?.close()
                            llm = null
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SET_PATH_FAIL", e.message, null)
                        }
                    }

                    "pickModel" -> {
                        if (pendingPickResult != null) {
                            result.error("BUSY", "Another pickModel request is in progress", null)
                            return@setMethodCallHandler
                        }
                        pendingPickResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/octet-stream"))
                        }
                        startActivityForResult(intent, PICK_MODEL_REQUEST)
                    }

                    "generate" -> {
                        val prompt = call.argument<String>("prompt") ?: ""
                        val mode = getApiMode()
                        CoroutineScope(Dispatchers.Default).launch {
                            try {
                                val out = when (mode) {
                                    "online" -> generateOnline(prompt)
                                    "best" -> tryOnlineThenLocal(prompt)
                                    else -> generateLocal(prompt)
                                }
                                withContext(Dispatchers.Main) {
                                    result.success(out)
                                }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("GEN_FAIL", e.message, null)
                                }
                            }
                        }
                    }

                    "close" -> {
                        try {
                            llm?.close()
                            llm = null
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("CLOSE_FAIL", e.message, null)
                        }
                    }

                    "getMaxTokens" -> {
                        result.success(getMaxTokens())
                    }

                    "setMaxTokens" -> {
                        val value = call.argument<Int>("value")
                        if (value == null) {
                            result.error("BAD_ARGS", "value is required", null)
                            return@setMethodCallHandler
                        }
                        saveMaxTokens(value)
                        result.success(true)
                    }

                    "getOutputTokens" -> {
                        result.success(getOutputTokens())
                    }

                    "setOutputTokens" -> {
                        val value = call.argument<Int>("value")
                        if (value == null) {
                            result.error("BAD_ARGS", "value is required", null)
                            return@setMethodCallHandler
                        }
                        saveOutputTokens(value)
                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }

        // Pre-warm the ProcessText Flutter engine so text-selection popup opens instantly
        ioScope.launch {
            kotlinx.coroutines.delay(2000)
            withContext(Dispatchers.Main) {
                try {
                    (applicationContext as? LocalScribeApp)?.getOrCreateProcessTextEngine()
                } catch (_: Exception) {}
            }
        }
    }

    override fun onDestroy() {
        try {
            llm?.close()
            llm = null
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    private fun getSavedModelPath(): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY_MODEL_PATH, DEFAULT_MODEL_PATH) ?: DEFAULT_MODEL_PATH
    }

    private fun saveModelPath(path: String) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_MODEL_PATH, path).apply()
    }

    private fun getCustomPrompts(): JSONObject {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_CUSTOM_PROMPTS, "{}") ?: "{}"
        return try {
            JSONObject(raw)
        } catch (_: Exception) {
            JSONObject()
        }
    }

    private fun saveCustomPrompts(obj: JSONObject) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_CUSTOM_PROMPTS, obj.toString()).apply()
    }

    private fun isBuiltInKeyword(keyword: String): Boolean {
        return when (keyword) {
            "fix",
            "rewrite",
            "scribe",
            "summ",
            "polite",
            "casual",
            "expand",
            "translate",
            "bullet",
            "improve",
            "rephrase",
            "formal" -> true
            else -> false
        }
    }

    private fun getPromptsForUi(): List<Map<String, Any>> {
        val list = mutableListOf<Map<String, Any>>()
        list.add(
            mapOf(
                "keyword" to "fix",
                "prompt" to "Correct grammar, spelling, and punctuation in the input text. Keep the same language. Return only the corrected text.",
                "builtIn" to true
            )
        )
        list.add(
            mapOf(
                "keyword" to "rewrite",
                "prompt" to "Rewrite the input text. You may add a style like formal, short, or friendly. Keep the same language. Preserve meaning. Return only the rewritten text.",
                "builtIn" to true
            )
        )
        list.add(
            mapOf(
                "keyword" to "scribe",
                "prompt" to "Respond in the same language as the input. Provide only the most relevant and complete answer. Do not add explanations, introductions, or extra text. Output only the answer.",
                "builtIn" to true
            )
        )
        list.add(
            mapOf(
                "keyword" to "summ",
                "prompt" to "Summarize the text in one or two sentences in the same language. Return only the summary.",
                "builtIn" to true
            )
        )
        list.add(
            mapOf(
                "keyword" to "polite",
                "prompt" to "Rewrite the text in a polite and professional tone in the same language. Return only the rewritten text.",
                "builtIn" to true
            )
        )
        list.add(
            mapOf(
                "keyword" to "casual",
                "prompt" to "Rewrite the text in a casual and friendly tone in the same language. Return only the rewritten text.",
                "builtIn" to true
            )
        )
        list.add(
            mapOf(
                "keyword" to "expand",
                "prompt" to "Expand the text with more detail while keeping the same language. Return only the expanded version.",
                "builtIn" to true
            )
        )
        list.add(
            mapOf(
                "keyword" to "translate",
                "prompt" to "Translate the text into English. Return only the translated text.",
                "builtIn" to true
            )
        )
        list.add(
            mapOf(
                "keyword" to "bullet",
                "prompt" to "Convert the text into clear bullet points. Keep the same language. Return only the list.",
                "builtIn" to true
            )
        )
        list.add(
            mapOf(
                "keyword" to "improve",
                "prompt" to "Improve writing clarity and quality while keeping meaning and language the same. Return only the improved text.",
                "builtIn" to true
            )
        )
        list.add(
            mapOf(
                "keyword" to "rephrase",
                "prompt" to "Rephrase the text completely while keeping the same meaning and language. Return only the rephrased text.",
                "builtIn" to true
            )
        )
        list.add(
            mapOf(
                "keyword" to "formal",
                "prompt" to "Rewrite the text in a formal, professional tone in the same language. Return only the rewritten text.",
                "builtIn" to true
            )
        )
        val custom = getCustomPrompts()
        val keys = custom.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            val value = custom.optString(key, "")
            if (value.isNotBlank()) {
                list.add(
                    mapOf(
                        "keyword" to key,
                        "prompt" to value,
                        "builtIn" to false
                    )
                )
            }
        }
        return list
    }

    private fun setCustomPrompt(keyword: String, prompt: String): Boolean {
        val obj = getCustomPrompts()
        obj.put(keyword, prompt)
        saveCustomPrompts(obj)
        return true
    }

    private fun deleteCustomPrompt(keyword: String): Boolean {
        val obj = getCustomPrompts()
        obj.remove(keyword)
        saveCustomPrompts(obj)
        return true
    }

    private fun getServiceEnabled(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_SERVICE_ENABLED, false)
    }

    private fun saveServiceEnabled(enabled: Boolean) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putBoolean(KEY_SERVICE_ENABLED, enabled).apply()
    }

    private fun getShowPreview(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_SHOW_PREVIEW, false)
    }

    private fun saveShowPreview(enabled: Boolean) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putBoolean(KEY_SHOW_PREVIEW, enabled).apply()
    }

    private fun getShowContext(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_SHOW_CONTEXT, false)
    }

    private fun saveShowContext(enabled: Boolean) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putBoolean(KEY_SHOW_CONTEXT, enabled).apply()
    }

    private fun getApiMode(): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY_API_MODE, DEFAULT_API_MODE) ?: DEFAULT_API_MODE
    }

    private fun saveApiMode(mode: String) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_API_MODE, mode).apply()
    }

    private fun getApiKey(): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY_API_KEY, "") ?: ""
    }

    private fun saveApiKey(key: String) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_API_KEY, key).apply()
    }

    private fun getApiModel(): String {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY_API_MODEL, DEFAULT_API_MODEL) ?: DEFAULT_API_MODEL
    }

    private fun saveApiModel(model: String) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_API_MODEL, model).apply()
    }

    private fun getMaxTokens(): Int {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getInt(KEY_MAX_TOKENS, DEFAULT_MAX_TOKENS)
    }

    private fun saveMaxTokens(value: Int) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putInt(KEY_MAX_TOKENS, value).apply()
    }

    private fun getOutputTokens(): Int {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getInt(KEY_OUTPUT_TOKENS, DEFAULT_OUTPUT_TOKENS)
    }

    private fun saveOutputTokens(value: Int) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putInt(KEY_OUTPUT_TOKENS, value).apply()
    }

    private fun isInternetAvailable(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun generateLocal(prompt: String): String {
        val engine = ensureLlmReady()
            ?: throw IllegalStateException("Model not initialized. Pick a model first.")
        ensurePromptFits(engine, prompt)
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

    @Synchronized
    private fun ensureLlmReady(): LocalLlm? {
        val path = getSavedModelPath()
        if (llm != null && currentModelPath == path) return llm
        return try {
            if (!File(path).exists()) return null
            llm?.close()
            llm = LocalLlmFactory.create(applicationContext, path, getMaxTokens())
            currentModelPath = path
            llm
        } catch (e: Exception) {
            android.util.Log.e("LocalScribe", "Failed to init LLM: ${e.message}", e)
            llm = null
            currentModelPath = null
            null
        }
    }

    private fun tryOnlineThenLocal(prompt: String): String {
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

    private fun generateOnline(prompt: String): String {
        val key = getApiKey()
        val model = getApiModel()
        if (key.isBlank()) throw IllegalStateException("No API key set \u2014 add one in AI Settings")
        if (!isInternetAvailable()) throw IllegalStateException("No internet connection")
        return callGemini(prompt, key, model)
    }

    private fun validateApiKey(key: String, model: String): Boolean {
        callGemini("ping", key, model)
        return true
    }

    private fun callGemini(prompt: String, apiKey: String, model: String, jsonMode: Boolean = false): String {
        val url = URL("https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent")
        val conn = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            setRequestProperty("Content-Type", "application/json; charset=utf-8")
            setRequestProperty("X-Goog-Api-Key", apiKey)
        }
        val body = JSONObject()
        val contents = org.json.JSONArray()
        val content = JSONObject()
        val parts = org.json.JSONArray()
        parts.put(JSONObject().put("text", prompt))
        content.put("role", "user")
        content.put("parts", parts)
        contents.put(content)
        body.put("contents", contents)
        if (jsonMode && model.startsWith("gemini")) {
            body.put("generationConfig", JSONObject().put("responseMimeType", "application/json"))
        }
        conn.outputStream.use { os ->
            os.write(body.toString().toByteArray(Charsets.UTF_8))
        }
        val code = conn.responseCode
        val stream = if (code in 200..299) conn.inputStream else conn.errorStream
        val text = BufferedReader(InputStreamReader(stream)).use { it.readText() }
        if (code == 429) {
            throw IOException("API quota exceeded \u2014 please wait a moment or switch to local mode")
        }
        if (code == 400) {
            throw IOException("Invalid API request \u2014 check your API key in AI Settings")
        }
        if (code !in 200..299) {
            throw IOException("Gemini API error ($code)")
        }
        val json = JSONObject(text)
        val candidates = json.optJSONArray("candidates") ?: return ""
        if (candidates.length() == 0) return ""
        val first = candidates.getJSONObject(0)
        val contentObj = first.optJSONObject("content") ?: return ""
        val partsArr = contentObj.optJSONArray("parts") ?: return ""
        if (partsArr.length() == 0) return ""
        // Skip parts with "thought":true (Gemma 4 / thinking models emit reasoning chunks)
        return buildString {
            for (i in 0 until partsArr.length()) {
                val part = partsArr.getJSONObject(i)
                if (!part.optBoolean("thought", false)) {
                    append(part.optString("text", ""))
                }
            }
        }.trim()
    }

    private fun handlePickResult(uri: Uri?) {
        val result = pendingPickResult
        pendingPickResult = null
        if (result == null) return
        if (uri == null) {
            emitProgress(1.0, true)
            result.error("PICK_CANCEL", "User cancelled picker", null)
            return
        }
        val displayName = getDisplayName(uri)
        val pathName = uri.path
        val isTask = (displayName?.endsWith(".task", true) == true) ||
                (displayName == null && pathName?.endsWith(".task", true) == true)
        val isLiteRt = (displayName?.endsWith(".litertlm", true) == true) ||
                (displayName == null && pathName?.endsWith(".litertlm", true) == true)

        if (!isTask && !isLiteRt) {
            emitProgress(1.0, true)
            result.error("BAD_TYPE", "Please select a .task or .litertlm file", null)
            return
        }
        ioScope.launch {
            try {
                val copied = copyModelToInternal(uri, displayName) { progress ->
                    emitProgress(progress, false)
                }
                saveModelPath(copied.absolutePath)
                llm?.close()
                llm = null
                emitProgress(1.0, true)
                runOnUiThread {
                    result.success(copied.absolutePath)
                }
            } catch (e: Exception) {
                emitProgress(1.0, true)
                runOnUiThread {
                    result.error("PICK_FAIL", e.message, null)
                }
            }
        }
    }

    @Throws(IOException::class)
    private fun copyModelToInternal(
        uri: Uri,
        displayName: String?,
        onProgress: (Double?) -> Unit
    ): File {
        val safeName = sanitizeModelName(displayName)
        val target = File(filesDir, safeName)
        val totalSize = getFileSize(uri)
        if (totalSize <= 0L) {
            onProgress(null)
        } else {
            onProgress(0.0)
        }
        contentResolver.openInputStream(uri).use { input ->
            if (input == null) throw IOException("Failed to open selected file")
            target.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var read = input.read(buffer)
                var copied = 0L
                var lastPercent = -1
                while (read >= 0) {
                    output.write(buffer, 0, read)
                    copied += read
                    if (totalSize > 0L) {
                        val percent = ((copied * 100) / totalSize).toInt()
                        if (percent != lastPercent) {
                            lastPercent = percent
                            onProgress(copied.toDouble() / totalSize.toDouble())
                        }
                    }
                    read = input.read(buffer)
                }
            }
        }
        return target
    }

    private fun sanitizeModelName(displayName: String?): String {
        val raw = (displayName ?: "model.task").trim()
        val name = raw.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val lower = name.lowercase()
        return if (lower.endsWith(".task") || lower.endsWith(".litertlm")) {
            name
        } else {
            "${name}.task"
        }
    }

    private fun clearXnnpackCache() {
        try {
            val files = cacheDir.listFiles() ?: return
            for (file in files) {
                if (file.name.endsWith(".xnnpack_cache")) {
                    file.delete()
                }
            }
        } catch (_: Exception) {
        }
    }

    private fun getDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) return cursor.getString(idx)
                }
            }
        return null
    }

    private fun getFileSize(uri: Uri): Long {
        contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (idx >= 0) return cursor.getLong(idx)
                }
            }
        return -1L
    }

    private fun emitProgress(progress: Double?, done: Boolean) {
        val payload = mapOf("progress" to progress, "done" to done)
        if (progressSink == null) return
        runOnUiThread {
            progressSink?.success(payload)
        }
    }

    private fun isAccessibilityServiceEnabled(): Boolean {
        val target = ComponentName(this, TypiLikeAccessibilityService::class.java)
            .flattenToString()
        val enabled = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false
        return enabled.split(':').any { it.equals(target, ignoreCase = true) }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_MODEL_REQUEST) return
        if (resultCode != Activity.RESULT_OK) {
            handlePickResult(null)
            return
        }
        handlePickResult(data?.data)
    }
}
