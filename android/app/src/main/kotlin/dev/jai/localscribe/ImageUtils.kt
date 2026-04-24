package dev.jai.localscribe

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import androidx.exifinterface.media.ExifInterface

/**
 * Image preprocessing helpers for multimodal LLM calls. Prevents oversized screenshots
 * from ballooning vision-token counts (e.g. LiteRT-LM Gemma3 patch ceiling) and from
 * making Gemini inlineData payloads unnecessarily large.
 *
 * Mirrors the pipeline used by Google's on-device Gallery sample:
 *   1. Bounds-only decode to read dimensions.
 *   2. Read EXIF orientation (so side-mounted phone screenshots aren't rotated 90° in
 *      the prompt).
 *   3. Power-of-two sub-sampled decode via [BitmapFactory.Options.inSampleSize].
 *   4. Apply the EXIF rotation/flip matrix.
 *   5. Aspect-preserving resize so the long edge equals [maxDim] exactly.
 */
object ImageUtils {

    /**
     * Decodes [path] as a [Bitmap] whose longest side is at most [maxDim] pixels,
     * with EXIF orientation already applied. Returns null if the file cannot be
     * decoded.
     *
     * Callers in the accessibility / share-popup path typically pass a small
     * cap (e.g. 512) to keep vision-token counts down and avoid the ANR we
     * previously hit handing full-resolution screenshots to the local model.
     */
    fun decodeDownscaled(path: String, maxDim: Int = 1024): Bitmap? {
        // 1. Bounds only.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val w = bounds.outWidth
        val h = bounds.outHeight
        if (w <= 0 || h <= 0) return null

        // 2. EXIF — read before decoding so we pick an inSampleSize against the
        //    post-rotation orientation. Defensive try/catch: some formats (PNG
        //    screenshots, most notably) have no EXIF segment, which is fine.
        val orientation = try {
            ExifInterface(path).getAttributeInt(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL,
            )
        } catch (_: Exception) {
            ExifInterface.ORIENTATION_NORMAL
        }

        // 3. Pick a power-of-two sample that keeps both dimensions >= maxDim so
        //    the subsequent exact-scale pass has clean input.
        var sample = 1
        while (w / (sample * 2) >= maxDim || h / (sample * 2) >= maxDim) sample *= 2

        val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = BitmapFactory.decodeFile(path, decodeOpts) ?: return null

        // 4. Apply EXIF rotation / flip.
        val rotated = rotateBitmap(decoded, orientation)

        // 5. Exact aspect-preserving resize.
        return resizeBitmap(rotated, maxDim)
    }

    /**
     * Applies the transform described by an EXIF orientation tag to [src].
     * Returns [src] unchanged when the tag is NORMAL or UNDEFINED. Recycles
     * [src] when a new bitmap is produced so the caller doesn't have to track
     * ownership.
     *
     * Covers all 8 orientations defined in the EXIF spec, including the rare
     * TRANSPOSE / TRANSVERSE variants (combined flip + rotate) that a few
     * stock camera apps produce.
     */
    private fun rotateBitmap(src: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_NORMAL,
            ExifInterface.ORIENTATION_UNDEFINED -> return src
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.preScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f); matrix.preScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(-90f); matrix.preScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(-90f)
            else -> return src
        }
        val out = Bitmap.createBitmap(src, 0, 0, src.width, src.height, matrix, true)
        if (out !== src) src.recycle()
        return out
    }

    /**
     * Aspect-preserving resize so the longer edge is exactly [maxDim]. If [src]
     * is already small enough, returns it untouched.
     */
    private fun resizeBitmap(src: Bitmap, maxDim: Int): Bitmap {
        val longest = maxOf(src.width, src.height)
        if (longest <= maxDim) return src
        val scale = maxDim.toFloat() / longest
        val out = Bitmap.createScaledBitmap(
            src,
            (src.width * scale).toInt().coerceAtLeast(1),
            (src.height * scale).toInt().coerceAtLeast(1),
            true,
        )
        if (out !== src) src.recycle()
        return out
    }
}

