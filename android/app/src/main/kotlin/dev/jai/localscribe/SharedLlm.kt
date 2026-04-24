package dev.jai.localscribe

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Process-wide single-engine holder for [LocalLlm].
 *
 * Why: the app has three keyword-trigger surfaces (chat in [MainActivity],
 * the in-line overlay in [TypiLikeAccessibilityService], and the system-share
 * popup in [ProcessTextActivity]) that all need to run the same on-device
 * model. Before this holder existed, each owned a private `llm` field and
 * would `LocalLlmFactory.create(...)` on first use. Logcat showed the
 * accessibility service happily serving requests from a warm engine, then
 * the user opening the share popup triggering a **second** full init of
 * the same 2.6 GB `.litertlm` file in the **same process** — ~13 s of
 * redundant OpenCL compile + section mmap, followed by a 600 ms GC pause
 * (199 skipped frames) as the heap strained under two copies of the weights.
 *
 * This holder collapses that down to a single warm engine. Callers ask for
 * an engine matching a [Key] (model path + max tokens + vision flag +
 * backend + sampler); if the cached one matches, they get it back without
 * paying any init cost. If any field differs, the previous engine is closed
 * and a fresh one is built.
 *
 * The holder intentionally does **not** free the engine in any Activity /
 * Service `onDestroy`. It lives for the application process, which is the
 * point — the whole fix is "build once per process, not once per surface".
 * Callers should use [invalidate] when the underlying model file changes
 * (download complete, model picked, model deleted) so the next [acquire]
 * re-reads settings and rebuilds.
 *
 * All public methods are thread-safe.
 */
object SharedLlm {

    private val lock = Any()

    @Volatile
    private var current: LocalLlm? = null
    private var currentKey: Key? = null

    /**
     * The set of parameters that uniquely identify a live engine. Any change
     * triggers a rebuild. Kept as a data class so equality is structural.
     */
    data class Key(
        val modelPath: String,
        val maxTokens: Int,
        val supportsVision: Boolean,
        val processingMode: String,
        val sampler: SamplerParams,
    )

    /**
     * Returns an engine matching [key]. Reuses the cached one when all fields
     * match; otherwise closes the previous engine and builds fresh.
     *
     * Returns null if the model file is missing or the factory throws. In
     * the null case the cache is cleared too so a subsequent acquire doesn't
     * hand back a stale half-built engine.
     */
    fun acquire(appContext: Context, key: Key): LocalLlm? = synchronized(lock) {
        if (!File(key.modelPath).exists()) {
            Log.e("LocalScribe", "[SharedLlm] Model file not found: ${key.modelPath}")
            closeLocked()
            return null
        }

        val existing = current
        if (existing != null && currentKey == key) {
            Log.d(
                "LocalScribe",
                "[SharedLlm] Reusing warm engine " +
                    "(mode=${key.processingMode}, vision=${key.supportsVision})"
            )
            return existing
        }

        // Anything else means we have to rebuild. Close first so we're not
        // holding two full models in memory simultaneously during the switch.
        closeLocked()

        return try {
            Log.i(
                "LocalScribe",
                "[SharedLlm] Building engine: file=${File(key.modelPath).name} " +
                    "mode=${key.processingMode} vision=${key.supportsVision}"
            )
            val engine = LocalLlmFactory.create(
                appContext,
                key.modelPath,
                key.maxTokens,
                key.supportsVision,
                key.processingMode,
                key.sampler,
            )
            current = engine
            // The factory may silently fall back GPU → CPU on init failure.
            // Lock the stored key to whatever backend the engine actually ended
            // up on, so the next acquire() with the same requested mode still
            // matches and we don't rebuild-and-fall-back again forever.
            currentKey = key.copy(processingMode = engine.activeBackend)
            engine
        } catch (e: Exception) {
            Log.e("LocalScribe", "[SharedLlm] Engine build failed: ${e.message}", e)
            current = null
            currentKey = null
            null
        }
    }

    /**
     * Explicitly discard and close the cached engine. Call this when the
     * underlying model changes in a way that [Key] doesn't capture directly,
     * e.g. a freshly-downloaded `.litertlm` replaced the file at the same
     * path. Idempotent.
     */
    fun invalidate() = synchronized(lock) { closeLocked() }

    /**
     * Returns the currently-cached engine, if any, without triggering a
     * rebuild. Useful for callers that want to know whether the holder is
     * warm (so they can e.g. pre-fetch a context UI without blocking).
     */
    fun peek(): LocalLlm? = current

    private fun closeLocked() {
        try {
            current?.close()
        } catch (_: Exception) {
            // best-effort; the native engine might already be in a torn-down
            // state if init threw partway through.
        }
        current = null
        currentKey = null
    }
}
