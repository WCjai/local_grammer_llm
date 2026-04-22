package dev.jai.localscribe

import android.graphics.Bitmap
import android.graphics.BitmapFactory

/**
 * Image preprocessing helpers for multimodal LLM calls. Prevents oversized screenshots
 * from ballooning vision-token counts (e.g. LiteRT-LM Gemma3 patch ceiling) and from
 * making Gemini inlineData payloads unnecessarily large.
 */
object ImageUtils {

    /**
     * Decodes [path] as a [Bitmap] whose longest side is at most [maxDim] pixels, using
     * [BitmapFactory.Options.inSampleSize] for memory-efficient sub-sampling and a final
     * exact scale pass when needed. Returns null if the file cannot be decoded.
     */
    fun decodeDownscaled(path: String, maxDim: Int = 1024): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val w = bounds.outWidth
        val h = bounds.outHeight
        if (w <= 0 || h <= 0) return null

        var sample = 1
        while (w / (sample * 2) >= maxDim || h / (sample * 2) >= maxDim) sample *= 2

        val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sample }
        val bmp = BitmapFactory.decodeFile(path, decodeOpts) ?: return null

        val longest = maxOf(bmp.width, bmp.height)
        if (longest <= maxDim) return bmp

        val scale = maxDim.toFloat() / longest
        val scaled = Bitmap.createScaledBitmap(
            bmp,
            (bmp.width * scale).toInt().coerceAtLeast(1),
            (bmp.height * scale).toInt().coerceAtLeast(1),
            true,
        )
        if (scaled !== bmp) bmp.recycle()
        return scaled
    }
}
