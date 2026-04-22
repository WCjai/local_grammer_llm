package dev.jai.localscribe

import android.accessibilityservice.AccessibilityService
import android.graphics.Bitmap
import android.os.Build
import android.view.Display
import androidx.annotation.RequiresApi
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

/** Thrown when the device API level is too old to support `takeScreenshot`. */
class ScreenshotUnsupportedException(msg: String) : Exception(msg)

object ScreenshotCaptureHelper {

    /**
     * Captures a screenshot of the default display using [AccessibilityService.takeScreenshot].
     * Requires Android 11 (API 30). Converts the hardware-backed buffer to a software ARGB_8888
     * [Bitmap] so it can be compressed and passed to downstream callers.
     *
     * Must be called while [service] is connected and has `canTakeScreenshot="true"` in its
     * accessibility config XML.
     */
    suspend fun captureViaA11y(service: AccessibilityService): Bitmap {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            throw ScreenshotUnsupportedException(
                "Screenshot capture requires Android 11 (API 30) or newer."
            )
        }
        return captureInternal(service)
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private suspend fun captureInternal(service: AccessibilityService): Bitmap =
        suspendCancellableCoroutine { cont ->
            service.takeScreenshot(
                Display.DEFAULT_DISPLAY,
                service.mainExecutor,
                object : AccessibilityService.TakeScreenshotCallback {
                    override fun onSuccess(result: AccessibilityService.ScreenshotResult) {
                        try {
                            val hwBuffer = result.hardwareBuffer
                            val colorSpace = result.colorSpace
                            val hwBitmap = Bitmap.wrapHardwareBuffer(hwBuffer, colorSpace)
                                ?: throw IllegalStateException("Failed to wrap hardware buffer into Bitmap")
                            hwBuffer.close()
                            // Copy to a software bitmap so it can be read/compressed by CPU code.
                            val softBitmap = hwBitmap.copy(Bitmap.Config.ARGB_8888, false)
                            hwBitmap.recycle()
                            cont.resume(softBitmap)
                        } catch (e: Exception) {
                            cont.resumeWithException(e)
                        }
                    }

                    override fun onFailure(errorCode: Int) {
                        cont.resumeWithException(
                            IllegalStateException("takeScreenshot failed with errorCode=$errorCode")
                        )
                    }
                }
            )
        }
}
