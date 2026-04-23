package dev.jai.localscribe

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.PointF
import android.graphics.RectF
import android.os.Bundle
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.RelativeLayout
import android.widget.Toast
import java.io.File
import java.io.FileOutputStream

/**
 * Lightweight full-screen crop activity launched after a screenshot is captured.
 *
 * Flow:
 *  1. Receives the full-screenshot file path via [EXTRA_SCREENSHOT_PATH].
 *  2. Displays the bitmap with a draggable/resizable rectangular crop overlay.
 *  3. On "Done" → writes the cropped PNG to a temp file in cache, then:
 *       - Completes [TypiLikeAccessibilityService.pendingCropDeferred] with the crop path.
 *       - Sets `RESULT_OK` with [EXTRA_CROP_PATH] (for Activity callers).
 *  4. On "Cancel" / back → completes deferred with null, sets `RESULT_CANCELED`.
 */
class CropActivity : Activity() {

    companion object {
        const val EXTRA_SCREENSHOT_PATH = "ls_screenshot_path"
        const val EXTRA_CROP_PATH = "ls_crop_path"
    }

    private lateinit var sourceBitmap: Bitmap
    private lateinit var cropView: CropView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val screenshotPath = intent.getStringExtra(EXTRA_SCREENSHOT_PATH)
        if (screenshotPath == null) {
            deliverResult(null)
            finish()
            return
        }

        val bmp = BitmapFactory.decodeFile(screenshotPath)
        if (bmp == null) {
            Toast.makeText(this, "Could not load screenshot", Toast.LENGTH_SHORT).show()
            deliverResult(null)
            finish()
            return
        }
        sourceBitmap = bmp

        // ---- Build layout programmatically (no XML dep) ----
        val root = RelativeLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }

        cropView = CropView(this, sourceBitmap)
        root.addView(
            cropView,
            RelativeLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            ).apply { addRule(RelativeLayout.ABOVE, android.R.id.custom) }
        )

        // Button bar anchored to bottom
        val btnBarId = View.generateViewId()
        val btnBar = LinearLayout(this).apply {
            id = btnBarId
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.argb(210, 0, 0, 0))
            val padPx = (20 * resources.displayMetrics.density).toInt()
            val botPx = (32 * resources.displayMetrics.density).toInt()
            setPadding(padPx, padPx, padPx, botPx)
        }

        val cancelBtn = Button(this).apply {
            text = "Cancel"
            setTextColor(Color.WHITE)
            textSize = 15f
            setBackgroundColor(Color.argb(0, 0, 0, 0))
            val hPx = (48 * resources.displayMetrics.density).toInt()
            val wPx = (140 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(wPx, hPx).apply {
                marginEnd = (12 * resources.displayMetrics.density).toInt()
            }
            setOnClickListener {
                deliverResult(null)
                finish()
            }
        }

        val doneBtn = Button(this).apply {
            text = "Done"
            setTextColor(Color.WHITE)
            textSize = 15f
            setBackgroundColor(Color.parseColor("#6C4AD5"))
            val hPx = (48 * resources.displayMetrics.density).toInt()
            val wPx = (140 * resources.displayMetrics.density).toInt()
            layoutParams = LinearLayout.LayoutParams(wPx, hPx)
            setOnClickListener { cropAndFinish() }
        }

        btnBar.addView(cancelBtn)
        btnBar.addView(doneBtn)

        val btnBarParams = RelativeLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { addRule(RelativeLayout.ALIGN_PARENT_BOTTOM) }
        root.addView(btnBar, btnBarParams)

        // Constrain cropView above button bar
        (cropView.layoutParams as RelativeLayout.LayoutParams).apply {
            addRule(RelativeLayout.ABOVE, btnBarId)
        }

        setContentView(root)
    }

    private fun cropAndFinish() {
        val cropped = cropView.getCroppedBitmap()
        val outDir = File(cacheDir, "ls_screenshots").apply { mkdirs() }
        val outFile = File(outDir, "crop_${System.currentTimeMillis()}.png")
        try {
            FileOutputStream(outFile).use { fos ->
                cropped.compress(Bitmap.CompressFormat.PNG, 100, fos)
            }
            cropped.recycle()
            deliverResult(outFile.absolutePath)
        } catch (e: Exception) {
            Toast.makeText(this, "Failed to save crop: ${e.message}", Toast.LENGTH_SHORT).show()
            cropped.recycle()
            deliverResult(null)
        } finally {
            finish()
        }
    }

    private fun deliverResult(cropPath: String?) {
        android.util.Log.d("LocalScribe", "[CropActivity] deliverResult cropPath=$cropPath serviceDeferred=${TypiLikeAccessibilityService.pendingCropDeferred != null}")
        // Complete the AccessibilityService deferred (if active).
        TypiLikeAccessibilityService.pendingCropDeferred
            ?.takeIf { !it.isCompleted }
            ?.complete(cropPath)

        // Standard Activity result (for any Activity calling via startActivityForResult).
        if (cropPath != null) {
            setResult(RESULT_OK, Intent().putExtra(EXTRA_CROP_PATH, cropPath))
        } else {
            setResult(RESULT_CANCELED)
        }
    }

    override fun onBackPressed() {
        deliverResult(null)
        super.onBackPressed()
    }

    override fun onDestroy() {
        if (::sourceBitmap.isInitialized && !sourceBitmap.isRecycled) {
            sourceBitmap.recycle()
        }
        super.onDestroy()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CropView — custom View rendering the bitmap with a draggable crop rectangle
// ─────────────────────────────────────────────────────────────────────────────

private class CropView(
    context: android.content.Context,
    private val bitmap: Bitmap,
) : View(context) {

    // ---- paint helpers ----
    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val overlayPaint = Paint().apply {
        style = Paint.Style.FILL
        color = Color.argb(130, 0, 0, 0)
    }
    private val borderPaint = Paint().apply {
        style = Paint.Style.STROKE
        color = Color.WHITE
        strokeWidth = 2f
    }
    private val handlePaint = Paint().apply {
        style = Paint.Style.FILL
        color = Color.WHITE
    }
    private val handleTouchPaint = Paint().apply {
        style = Paint.Style.FILL
        color = Color.argb(180, 108, 74, 213) // purple glow when dragged
    }

    // ---- geometry ----
    private val bitmapMatrix = Matrix()
    private var scale = 1f
    private var offsetX = 0f
    private var offsetY = 0f

    // Crop rect in bitmap-pixel coordinates
    private val rawCrop = RectF()

    // Active drag state
    private enum class Handle { NONE, TL, TR, BL, BR, MOVE }
    private var activeHandle = Handle.NONE
    private var lastTouchX = 0f
    private var lastTouchY = 0f

    private val handleRadiusPx: Float get() = 18f * resources.displayMetrics.density
    private val handleTouchPx: Float get() = handleRadiusPx * 2.2f
    private val minCropPx = 80f // minimum crop size in bitmap pixels

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w == 0 || h == 0) return

        scale = minOf(w.toFloat() / bitmap.width, h.toFloat() / bitmap.height)
        offsetX = (w - bitmap.width * scale) / 2f
        offsetY = (h - bitmap.height * scale) / 2f

        bitmapMatrix.reset()
        bitmapMatrix.setScale(scale, scale)
        bitmapMatrix.postTranslate(offsetX, offsetY)

        // Default crop: 80% of bitmap, centered
        val margin = 0.10f
        rawCrop.set(
            bitmap.width * margin,
            bitmap.height * margin,
            bitmap.width * (1f - margin),
            bitmap.height * (1f - margin),
        )
    }

    private fun btv(bx: Float, by: Float) = PointF(bx * scale + offsetX, by * scale + offsetY)
    private fun vtb(vx: Float, vy: Float) = PointF((vx - offsetX) / scale, (vy - offsetY) / scale)

    override fun onDraw(canvas: Canvas) {
        canvas.drawBitmap(bitmap, bitmapMatrix, bitmapPaint)

        val vTL = btv(rawCrop.left, rawCrop.top)
        val vBR = btv(rawCrop.right, rawCrop.bottom)
        val bLeft = offsetX
        val bTop = offsetY
        val bRight = offsetX + bitmap.width * scale
        val bBottom = offsetY + bitmap.height * scale

        // Darken outside the crop
        canvas.drawRect(bLeft, bTop, bRight, vTL.y, overlayPaint)
        canvas.drawRect(bLeft, vBR.y, bRight, bBottom, overlayPaint)
        canvas.drawRect(bLeft, vTL.y, vTL.x, vBR.y, overlayPaint)
        canvas.drawRect(vBR.x, vTL.y, bRight, vBR.y, overlayPaint)

        // Crop border
        canvas.drawRect(vTL.x, vTL.y, vBR.x, vBR.y, borderPaint)

        // Corner handles
        val corners = listOf(
            Handle.TL to PointF(vTL.x, vTL.y),
            Handle.TR to PointF(vBR.x, vTL.y),
            Handle.BL to PointF(vTL.x, vBR.y),
            Handle.BR to PointF(vBR.x, vBR.y),
        )
        for ((h, pt) in corners) {
            val p = if (h == activeHandle) handleTouchPaint else handlePaint
            canvas.drawCircle(pt.x, pt.y, handleRadiusPx, p)
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val vTL = btv(rawCrop.left, rawCrop.top)
                val vBR = btv(rawCrop.right, rawCrop.bottom)
                activeHandle = when {
                    dist(event.x, event.y, vTL.x, vTL.y) < handleTouchPx -> Handle.TL
                    dist(event.x, event.y, vBR.x, vTL.y) < handleTouchPx -> Handle.TR
                    dist(event.x, event.y, vTL.x, vBR.y) < handleTouchPx -> Handle.BL
                    dist(event.x, event.y, vBR.x, vBR.y) < handleTouchPx -> Handle.BR
                    event.x in vTL.x..vBR.x && event.y in vTL.y..vBR.y -> Handle.MOVE
                    else -> Handle.NONE
                }
                lastTouchX = event.x
                lastTouchY = event.y
                return activeHandle != Handle.NONE
            }
            MotionEvent.ACTION_MOVE -> {
                if (activeHandle == Handle.NONE) return false
                val dx = (event.x - lastTouchX) / scale
                val dy = (event.y - lastTouchY) / scale
                when (activeHandle) {
                    Handle.TL -> {
                        rawCrop.left = (rawCrop.left + dx).coerceIn(0f, rawCrop.right - minCropPx)
                        rawCrop.top = (rawCrop.top + dy).coerceIn(0f, rawCrop.bottom - minCropPx)
                    }
                    Handle.TR -> {
                        rawCrop.right = (rawCrop.right + dx).coerceIn(rawCrop.left + minCropPx, bitmap.width.toFloat())
                        rawCrop.top = (rawCrop.top + dy).coerceIn(0f, rawCrop.bottom - minCropPx)
                    }
                    Handle.BL -> {
                        rawCrop.left = (rawCrop.left + dx).coerceIn(0f, rawCrop.right - minCropPx)
                        rawCrop.bottom = (rawCrop.bottom + dy).coerceIn(rawCrop.top + minCropPx, bitmap.height.toFloat())
                    }
                    Handle.BR -> {
                        rawCrop.right = (rawCrop.right + dx).coerceIn(rawCrop.left + minCropPx, bitmap.width.toFloat())
                        rawCrop.bottom = (rawCrop.bottom + dy).coerceIn(rawCrop.top + minCropPx, bitmap.height.toFloat())
                    }
                    Handle.MOVE -> {
                        val w = rawCrop.width()
                        val h = rawCrop.height()
                        rawCrop.left = (rawCrop.left + dx).coerceIn(0f, bitmap.width - w)
                        rawCrop.top = (rawCrop.top + dy).coerceIn(0f, bitmap.height - h)
                        rawCrop.right = rawCrop.left + w
                        rawCrop.bottom = rawCrop.top + h
                    }
                    Handle.NONE -> {}
                }
                lastTouchX = event.x
                lastTouchY = event.y
                invalidate()
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                activeHandle = Handle.NONE
                invalidate()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    fun getCroppedBitmap(): Bitmap {
        val l = rawCrop.left.toInt().coerceIn(0, bitmap.width - 1)
        val t = rawCrop.top.toInt().coerceIn(0, bitmap.height - 1)
        val r = rawCrop.right.toInt().coerceIn(l + 1, bitmap.width)
        val b = rawCrop.bottom.toInt().coerceIn(t + 1, bitmap.height)
        return Bitmap.createBitmap(bitmap, l, t, r - l, b - t)
    }

    private fun dist(x1: Float, y1: Float, x2: Float, y2: Float): Float {
        val dx = x1 - x2
        val dy = y1 - y2
        return Math.sqrt((dx * dx + dy * dy).toDouble()).toFloat()
    }
}
