package dev.jai.localscribe

import android.content.Context
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityManager
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {

    private val CHANNEL = "local_llm"
    private val PROGRESS_CHANNEL = "local_llm_progress"
    private val GENERATION_CHANNEL = "local_llm_generation"
    private var llm: LocalLlm? = null
    private var initInProgress = false
    // Serializes engine lifecycle + generation so cancel/close/rebuild can't
    // race a live generateResponseAsync callback. Streaming still runs on the
    // native thread; we only hold this while handing off to/from the engine.
    private val generationMutex = Mutex()
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
    private val KEY_TEMPERATURE = "sampler_temperature"
    private val KEY_TOP_K = "sampler_top_k"
    private val KEY_TOP_P = "sampler_top_p"
    private val KEY_ADVANCED_MODE = "advanced_sampler_mode"
    private val DEFAULT_MODEL_PATH = "/data/local/tmp/llm/model.task"
    private val DEFAULT_API_MODE = "local"
    private val DEFAULT_API_MODEL = "gemini-2.5-flash"
    private val DEFAULT_MAX_TOKENS = 2048
    private val DEFAULT_TEMPERATURE = 0.3f
    private val DEFAULT_TOP_K = 40
    private val DEFAULT_TOP_P = 0.9f
    private var pendingPickResult: MethodChannel.Result? = null
    private val PICK_MODEL_REQUEST = 7010
    private val NOTIFICATION_PERMISSION_REQUEST = 7011
    private val ioScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var progressSink: EventChannel.EventSink? = null
    // Token-stream sink for `generateStream` consumers. We write small maps
    // {"token": String} / {"done": true} / {"error": String} so the Dart side
    // can distinguish events without a separate channel per event type.
    private var generationSink: EventChannel.EventSink? = null
    private var currentModelPath: String? = null
    // Snapshot of the sampler params that the current engine was built with.
    // When the user edits sliders we compare against this and rebuild only if
    // they actually changed.
    private var currentSampler: SamplerParams? = null
    // Download state delegated to ModelDownloadService
    private var pendingDownloadResult: MethodChannel.Result? = null
    private var downloadReceiver: BroadcastReceiver? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

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

        // Token stream for chat-style streaming generation. Emits maps:
        //   {"token": "partial text"}  — incremental chunk
        //   {"done": true}              — final chunk delivered, stream closed
        //   {"error": "message"}       — generation failed
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, GENERATION_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    generationSink = events
                }

                override fun onCancel(arguments: Any?) {
                    generationSink = null
                }
            })

        // Register broadcast receiver for ModelDownloadService updates
        val filter = IntentFilter().apply {
            addAction(ModelDownloadService.BROADCAST_PROGRESS)
            addAction(ModelDownloadService.BROADCAST_DONE)
            addAction(ModelDownloadService.BROADCAST_ERROR)
            addAction(ModelDownloadService.BROADCAST_CANCELLED)
        }
        downloadReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    ModelDownloadService.BROADCAST_PROGRESS -> {
                        val prog = intent.getDoubleExtra(ModelDownloadService.EXTRA_PROGRESS, -1.0)
                        runOnUiThread { emitProgress(prog, false) }
                    }
                    ModelDownloadService.BROADCAST_DONE -> {
                        val path = intent.getStringExtra(ModelDownloadService.EXTRA_PATH) ?: ""
                        llm?.close(); llm = null
                        // The model file on disk was just replaced; any
                        // engine cached in the process-wide holder now
                        // references the OLD file, so blow it away.
                        SharedLlm.invalidate()
                        emitProgress(1.0, true)
                        runOnUiThread {
                            pendingDownloadResult?.success(path)
                            pendingDownloadResult = null
                        }
                    }
                    ModelDownloadService.BROADCAST_ERROR -> {
                        val msg = intent.getStringExtra(ModelDownloadService.EXTRA_MESSAGE)
                        emitProgress(1.0, true)
                        runOnUiThread {
                            pendingDownloadResult?.error("DOWNLOAD_FAIL", msg, null)
                            pendingDownloadResult = null
                        }
                    }
                    ModelDownloadService.BROADCAST_CANCELLED -> {
                        emitProgress(1.0, true)
                        runOnUiThread {
                            pendingDownloadResult?.error("CANCELLED", "Download cancelled by user", null)
                            pendingDownloadResult = null
                        }
                    }
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(downloadReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(downloadReceiver, filter)
        }

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
                            val f = File(path)
                            // Don't surface the placeholder "model.task" basename
                            // from DEFAULT_MODEL_PATH when no real model exists.
                            if (f.exists()) f.name else ""
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
                            // Model switched — the holder's cached engine
                            // was built against a different path. Force a
                            // rebuild on the next acquire from any surface.
                            SharedLlm.invalidate()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SET_PATH_FAIL", e.message, null)
                        }
                    }

                    "cancelDownload" -> {
                        val cancelIntent = Intent(this, ModelDownloadService::class.java).apply {
                            action = ModelDownloadService.ACTION_CANCEL
                        }
                        startService(cancelIntent)
                        result.success(true)
                    }

                    "isDownloadActive" -> {
                        // A pendingDownloadResult is held while the foreground
                        // service is running. Used by widgets that mount
                        // mid-download to restore their UI.
                        result.success(pendingDownloadResult != null)
                    }

                    "downloadModel" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.error("BAD_ARGS", "url is required", null)
                            return@setMethodCallHandler
                        }
                        pendingDownloadResult = result
                        val svcIntent = Intent(this, ModelDownloadService::class.java).apply {
                            action = ModelDownloadService.ACTION_START
                            putExtra(ModelDownloadService.EXTRA_URL, url)
                        }
                        startForegroundService(svcIntent)
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

                    "getModelSupportsVision" -> {
                        val KEY_MODEL_SUPPORTS_VISION = "model_supports_vision"
                        val supported = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                            .getBoolean(KEY_MODEL_SUPPORTS_VISION, false)
                        result.success(supported)
                    }

                    "setModelSupportsVision" -> {
                        val enabled = call.argument<Boolean>("enabled")
                        if (enabled == null) {
                            result.error("BAD_ARGS", "enabled is required", null)
                            return@setMethodCallHandler
                        }
                        val KEY_MODEL_SUPPORTS_VISION = "model_supports_vision"
                        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                            .edit().putBoolean(KEY_MODEL_SUPPORTS_VISION, enabled).apply()

                        // Tear down + rebuild on IO so close()'s native teardown
                        // (which may block briefly if a generation is in flight)
                        // doesn't stall the main thread while the user is tapping
                        // through settings.
                        ioScope.launch {
                            try { llm?.close() } catch (_: Exception) {}
                            llm = null
                            currentModelPath = null
                            try {
                                ensureLlmReady()
                                Log.i("LocalScribe", "Vision toggle applied: supportsVision=$enabled, engine rebuilt")
                            } catch (e: Exception) {
                                Log.e("LocalScribe", "setModelSupportsVision init failed: ${e.message}", e)
                            }
                            withContext(Dispatchers.Main) { result.success(true) }
                        }
                    }

                    "deleteModel" -> {
                        ioScope.launch {
                            try {
                                llm?.close()
                                llm = null
                                // Model file is about to be removed; drop
                                // the holder's reference too so no other
                                // surface tries to generate from a deleted
                                // file.
                                SharedLlm.invalidate()
                                val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                                val path = prefs.getString(KEY_MODEL_PATH, null)
                                if (!path.isNullOrBlank()) {
                                    File(path).delete()
                                    File("${path}.part").delete()
                                    // Also delete any raw-name part files in filesDir
                                    filesDir.listFiles()?.filter {
                                        it.name.endsWith(".part")
                                    }?.forEach { it.delete() }
                                }
                                prefs.edit().remove(KEY_MODEL_PATH).apply()
                                withContext(Dispatchers.Main) { result.success(true) }
                            } catch (e: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("DELETE_FAIL", e.message, null)
                                }
                            }
                        }
                    }

                    "getProcessingMode" -> {
                        result.success(getProcessingMode())
                    }

                    "setProcessingMode" -> {
                        val requested = call.argument<String>("mode") ?: "cpu"
                        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                            .edit().putString("processing_mode", requested).apply()

                        // Tear down + rebuild on IO. close() can block on native
                        // teardown (esp. if a generation is still draining), and
                        // we don't want to freeze the processing-mode toggle UI
                        // while that happens.
                        ioScope.launch {
                            try { llm?.close() } catch (_: Exception) {}
                            llm = null
                            currentModelPath = null
                            val actual = try {
                                val engine = ensureLlmReady()
                                engine?.activeBackend ?: requested
                            } catch (e: Exception) {
                                Log.e("LocalScribe", "setProcessingMode init failed: ${e.message}", e)
                                "cpu"
                            }
                            // Persist the actually-used backend so the toggle reflects reality.
                            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                                .edit().putString("processing_mode", actual).apply()
                            withContext(Dispatchers.Main) {
                                result.success(actual)
                            }
                        }
                    }

                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                            // Android < 13 — runtime permission not needed
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        val granted = checkSelfPermission("android.permission.POST_NOTIFICATIONS") ==
                                android.content.pm.PackageManager.PERMISSION_GRANTED
                        if (granted) {
                            result.success(true)
                            return@setMethodCallHandler
                        }
                        pendingPermissionResult = result
                        requestPermissions(
                            arrayOf("android.permission.POST_NOTIFICATIONS"),
                            NOTIFICATION_PERMISSION_REQUEST
                        )
                    }

                    "generateStream" -> {
                        val prompt = call.argument<String>("prompt") ?: ""
                        // Streaming is local-only — online Gemini calls use the
                        // blocking "generate" method. If mode is "online"/"best"
                        // the Dart layer is responsible for falling back to that.
                        result.success(true)
                        ioScope.launch {
                            startLocalStream(prompt)
                        }
                    }

                    "cancelGenerate" -> {
                        val cancelled = try { llm?.cancel() ?: false } catch (_: Exception) { false }
                        result.success(cancelled)
                    }

                    "getTemperature" -> result.success(getTemperature().toDouble())
                    "setTemperature" -> {
                        val v = (call.argument<Number>("value"))?.toFloat()
                        if (v == null) { result.error("BAD_ARGS", "value is required", null); return@setMethodCallHandler }
                        saveTemperature(v)
                        invalidateEngineIfSamplerChanged()
                        // Also wipe the process-wide holder so the accessibility
                        // service + ProcessText popup rebuild with the new sampler
                        // on their next acquire. Without this they keep the old
                        // warm engine keyed on the previous SamplerParams.
                        SharedLlm.invalidate()
                        result.success(true)
                    }
                    "getTopK" -> result.success(getTopK())
                    "setTopK" -> {
                        val v = call.argument<Int>("value")
                        if (v == null) { result.error("BAD_ARGS", "value is required", null); return@setMethodCallHandler }
                        saveTopK(v)
                        invalidateEngineIfSamplerChanged()
                        SharedLlm.invalidate()
                        result.success(true)
                    }
                    "getTopP" -> result.success(getTopP().toDouble())
                    "setTopP" -> {
                        val v = (call.argument<Number>("value"))?.toFloat()
                        if (v == null) { result.error("BAD_ARGS", "value is required", null); return@setMethodCallHandler }
                        saveTopP(v)
                        invalidateEngineIfSamplerChanged()
                        SharedLlm.invalidate()
                        result.success(true)
                    }
                    "getAdvancedMode" -> result.success(getAdvancedMode())
                    "setAdvancedMode" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                            .edit().putBoolean(KEY_ADVANCED_MODE, enabled).apply()
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
        try { unregisterReceiver(downloadReceiver) } catch (_: Exception) {}
        downloadReceiver = null
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
        return prefs.getBoolean(KEY_SHOW_PREVIEW, true)
    }

    private fun saveShowPreview(enabled: Boolean) {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putBoolean(KEY_SHOW_PREVIEW, enabled).apply()
    }

    private fun getShowContext(): Boolean {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_SHOW_CONTEXT, true)
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

    private fun isInternetAvailable(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun generateLocal(prompt: String): String {
        // Hold the generation mutex across the entire call so concurrent
        // generate/cancel/close requests can't race against a live native
        // inference. runBlocking is safe here because generateLocal itself
        // already runs off the main thread (ioScope / Dispatchers.Default).
        return kotlinx.coroutines.runBlocking {
            generationMutex.withLock {
                val engine = ensureLlmReady()
                    ?: throw IllegalStateException("Model not initialized. Pick a model first.")
                ensurePromptFits(engine, prompt)
                engine.generate(prompt)
            }
        }
    }

    private fun ensurePromptFits(engine: LocalLlm, prompt: String) {
        val maxTokens = getMaxTokens()
        val tokens = engine.sizeInTokens(prompt)
        if (tokens <= maxTokens) return
        throw IllegalStateException(
            "Input too long for model (tokens=$tokens, maxTokens=$maxTokens). " +
                "Increase Max context tokens in AI Settings or use a model with a higher context limit."
        )
    }

    @Synchronized
    private fun getProcessingMode(): String {
        return getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString("processing_mode", "cpu") ?: "cpu"
    }

    private fun ensureLlmReady(): LocalLlm? {
        val path = getSavedModelPath()
        val sampler = SamplerParams(
            temperature = getTemperature(),
            topK = getTopK(),
            topP = getTopP(),
        )
        if (llm != null && currentModelPath == path && currentSampler == sampler) return llm
        return try {
            if (!File(path).exists()) return null
            llm?.close()
            val engine = LocalLlmFactory.create(
                applicationContext,
                path,
                getMaxTokens(),
                true,
                getProcessingMode(),
                sampler,
            )
            llm = engine
            currentModelPath = path
            currentSampler = sampler
            // If GPU was requested but the factory fell back to CPU, persist the
            // actually-used backend so the settings UI reflects reality on next read.
            val savedMode = getProcessingMode()
            if (savedMode != engine.activeBackend) {
                getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .edit().putString("processing_mode", engine.activeBackend).apply()
            }
            llm
        } catch (e: Exception) {
            android.util.Log.e("LocalScribe", "Failed to init LLM: ${e.message}", e)
            llm = null
            currentModelPath = null
            currentSampler = null
            null
        }
    }

    /**
     * Invoked from sampler setters. If the saved params differ from what the
     * current engine was built with, tear it down so the next generate call
     * rebuilds with the new values. We don't rebuild eagerly — init is
     * expensive and the user may be dragging a slider. Close is dispatched
     * to ioScope so the slider callback stays responsive even if the native
     * engine is still finishing a pending generation.
     */
    private fun invalidateEngineIfSamplerChanged() {
        val want = SamplerParams(getTemperature(), getTopK(), getTopP())
        if (currentSampler != null && currentSampler != want) {
            val stale = llm
            llm = null
            currentModelPath = null
            currentSampler = null
            if (stale != null) {
                ioScope.launch {
                    try { stale.close() } catch (_: Exception) {}
                }
            }
        }
    }

    private fun getTemperature(): Float {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getFloat(KEY_TEMPERATURE, DEFAULT_TEMPERATURE)
    }
    private fun saveTemperature(v: Float) {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putFloat(KEY_TEMPERATURE, v.coerceIn(0.0f, 2.0f)).apply()
    }
    private fun getTopK(): Int {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getInt(KEY_TOP_K, DEFAULT_TOP_K)
    }
    private fun saveTopK(v: Int) {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putInt(KEY_TOP_K, v.coerceIn(1, 100)).apply()
    }
    private fun getTopP(): Float {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getFloat(KEY_TOP_P, DEFAULT_TOP_P)
    }
    private fun saveTopP(v: Float) {
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putFloat(KEY_TOP_P, v.coerceIn(0.0f, 1.0f)).apply()
    }
    private fun getAdvancedMode(): Boolean {
        return getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_ADVANCED_MODE, false)
    }

    /**
     * Kicks off a streaming generation on the local engine. Token / done /
     * error frames are forwarded to [generationSink] on the UI thread so the
     * Flutter EventChannel delivers them in order.
     *
     * We hold [generationMutex] across the whole call so cancel/close can't
     * race the native callback path. The native runtime itself handles
     * threading — we just marshal events back to Dart.
     */
    private suspend fun startLocalStream(prompt: String) {
        generationMutex.withLock {
            val engine = ensureLlmReady()
            if (engine == null) {
                emitGenerationError("Model not initialized. Pick a model first.")
                return
            }
            try {
                ensurePromptFits(engine, prompt)
            } catch (e: Exception) {
                emitGenerationError(e.message ?: "Prompt too long")
                return
            }
            val completion = kotlinx.coroutines.CompletableDeferred<Unit>()
            try {
                engine.generateStream(
                    prompt,
                    onToken = { partial ->
                        runOnUiThread {
                            generationSink?.success(mapOf("token" to partial))
                        }
                    },
                    onDone = {
                        runOnUiThread {
                            generationSink?.success(mapOf("done" to true))
                        }
                        if (!completion.isCompleted) completion.complete(Unit)
                    },
                    onError = { t ->
                        val cleanMsg = cleanUpLiteRtErrorMessage(t.message ?: "Generation failed")
                        Log.w("LocalScribe", "[stream] Inference error: $cleanMsg", t)
                        runOnUiThread {
                            generationSink?.success(mapOf("error" to cleanMsg))
                        }
                        // The engine may be in an undefined state after an inference error
                        // (e.g. OOM, driver crash). Null it out so the next request triggers
                        // a clean rebuild instead of re-hitting the same broken native session.
                        val stale = llm
                        llm = null
                        currentModelPath = null
                        currentSampler = null
                        ioScope.launch { try { stale?.close() } catch (_: Exception) {} }
                        if (!completion.isCompleted) completion.complete(Unit)
                    },
                )
            } catch (t: Throwable) {
                val cleanMsg = cleanUpLiteRtErrorMessage(t.message ?: "Generation failed")
                Log.w("LocalScribe", "[stream] Synchronous launch error: $cleanMsg", t)
                emitGenerationError(cleanMsg)
                // Same engine-invalidation as the async onError path.
                val stale = llm
                llm = null
                currentModelPath = null
                currentSampler = null
                ioScope.launch { try { stale?.close() } catch (_: Exception) {} }
                return
            }
            // Wait for either onDone or onError so we keep holding the mutex
            // until the native side actually stops.
            completion.await()
        }
    }

    private fun emitGenerationError(msg: String) {
        runOnUiThread {
            generationSink?.success(mapOf("error" to msg))
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
        val isLiteRt = (displayName?.endsWith(".litertlm", true) == true) ||
                (displayName == null && pathName?.endsWith(".litertlm", true) == true)

        if (!isLiteRt) {
            emitProgress(1.0, true)
            result.error("BAD_TYPE", "Please select a .litertlm file", null)
            return
        }
        ioScope.launch {
            try {
                // Delete the previously stored model before accepting the new one
                val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val oldPath = prefs.getString(KEY_MODEL_PATH, null)
                if (!oldPath.isNullOrBlank()) {
                    File(oldPath).delete()
                    File("${oldPath}.part").delete()
                }
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
        val raw = (displayName ?: "model.litertlm").trim()
        val name = raw.replace(Regex("[^A-Za-z0-9._-]"), "_")
        val lower = name.lowercase()
        return if (lower.endsWith(".litertlm")) {
            name
        } else {
            "${name}.litertlm"
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST) {
            val granted = grantResults.isNotEmpty() &&
                    grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
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
