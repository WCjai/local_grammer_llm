package dev.jai.localscribe

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL

class ModelDownloadService : Service() {

    companion object {
        const val ACTION_START  = "dev.jai.localscribe.DOWNLOAD_START"
        const val ACTION_CANCEL = "dev.jai.localscribe.DOWNLOAD_CANCEL"

        // Broadcast actions sent to MainActivity
        const val BROADCAST_PROGRESS  = "dev.jai.localscribe.DOWNLOAD_PROGRESS"
        const val BROADCAST_DONE      = "dev.jai.localscribe.DOWNLOAD_DONE"
        const val BROADCAST_ERROR     = "dev.jai.localscribe.DOWNLOAD_ERROR"
        const val BROADCAST_CANCELLED = "dev.jai.localscribe.DOWNLOAD_CANCELLED"

        const val EXTRA_URL       = "url"
        const val EXTRA_PROGRESS  = "progress"
        const val EXTRA_PATH      = "path"
        const val EXTRA_MESSAGE   = "message"

        private const val NOTIF_CHANNEL_ID = "model_download"
        private const val NOTIF_ID = 9001
    }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var downloadJob: Job? = null
    private var activeConn: HttpURLConnection? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CANCEL -> {
                activeConn?.disconnect()
                activeConn = null
                downloadJob?.cancel()
                downloadJob = null
                sendLocalBroadcast(Intent(BROADCAST_CANCELLED))
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val url = intent.getStringExtra(EXTRA_URL) ?: run {
                    stopSelf(); return START_NOT_STICKY
                }
                startForeground(NOTIF_ID, buildNotification(0))
                startDownload(url)
            }
        }
        return START_NOT_STICKY
    }

    private fun startDownload(url: String) {
        downloadJob = serviceScope.launch {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val prefs = getSharedPreferences("local_llm_prefs", Context.MODE_PRIVATE)
            val filesDir = filesDir

            val rawName = url.substringAfterLast('/').takeIf { it.isNotBlank() } ?: "model.litertlm"
            val safeName = sanitizeName(rawName)
            val target   = File(filesDir, safeName)
            val partFile = File(filesDir, "$safeName.part")

            try {
                // HEAD request to get total size
                var totalSize = 0L
                try {
                    val head = URL(url).openConnection() as HttpURLConnection
                    head.requestMethod = "HEAD"
                    head.connectTimeout = 20_000
                    head.readTimeout = 20_000
                    head.instanceFollowRedirects = true
                    head.connect()
                    totalSize = head.contentLengthLong
                    head.disconnect()
                } catch (_: Exception) {}

                var downloaded = if (partFile.exists()) partFile.length() else 0L
                broadcastProgress(downloaded.toDouble() / maxOf(totalSize, 1).toDouble())

                val maxRetries = 15
                var retries = 0

                while (isActive) {
                    try {
                        val conn = URL(url).openConnection() as HttpURLConnection
                        activeConn = conn
                        conn.connectTimeout = 30_000
                        conn.readTimeout = 120_000
                        conn.instanceFollowRedirects = true
                        conn.addRequestProperty("Accept-Encoding", "identity")
                        conn.addRequestProperty("Connection", "keep-alive")
                        // Use larger TCP receive buffer hint
                        conn.addRequestProperty("Cache-Control", "no-cache")
                        if (downloaded > 0L && totalSize > 0L) {
                            conn.setRequestProperty("Range", "bytes=$downloaded-")
                        }
                        conn.connect()
                        if (totalSize <= 0L) totalSize = conn.contentLengthLong

                        val append = downloaded > 0L
                        FileOutputStream(partFile, append).buffered(2 * 1024 * 1024).use { out ->
                            conn.inputStream.use { inp ->
                                val buf = ByteArray(1024 * 1024) // 1 MB read buffer
                                var lastNotifPct = ((downloaded * 100) / maxOf(totalSize, 1)).toInt()
                                var rd = inp.read(buf)
                                while (rd >= 0 && isActive) {
                                    out.write(buf, 0, rd)
                                    downloaded += rd
                                    if (totalSize > 0L) {
                                        val pct = ((downloaded * 100) / totalSize).toInt()
                                        // Broadcast every 1% change
                                        if (pct != lastNotifPct) {
                                            lastNotifPct = pct
                                            val prog = downloaded.toDouble() / totalSize
                                            broadcastProgress(prog)
                                            nm.notify(NOTIF_ID, buildNotification(pct))
                                        }
                                    }
                                    rd = inp.read(buf)
                                }
                            }
                        }

                        activeConn = null
                        conn.disconnect()

                        if (!isActive) break // cancelled

                        if (totalSize <= 0L || downloaded >= totalSize) {
                            // Rename part → final
                            partFile.renameTo(target)
                            prefs.edit().putString("model_path", target.absolutePath).apply()
                            broadcastProgress(1.0)
                            val doneIntent = Intent(BROADCAST_DONE).apply {
                                putExtra(EXTRA_PATH, target.absolutePath)
                            }
                            sendLocalBroadcast(doneIntent)
                            withContext(Dispatchers.Main) {
                                stopForeground(STOP_FOREGROUND_REMOVE)
                                stopSelf()
                            }
                            return@launch
                        }
                    } catch (e: Exception) {
                        activeConn = null
                        if (!isActive) break
                        retries++
                        if (retries >= maxRetries) {
                            partFile.delete()
                            val errIntent = Intent(BROADCAST_ERROR).apply {
                                putExtra(EXTRA_MESSAGE, e.message ?: "Unknown error")
                            }
                            sendLocalBroadcast(errIntent)
                            withContext(Dispatchers.Main) {
                                stopForeground(STOP_FOREGROUND_REMOVE)
                                stopSelf()
                            }
                            return@launch
                        }
                        // Back-off: 5s, 10s … 60s
                        nm.notify(NOTIF_ID, buildNotification(-1)) // indeterminate
                        delay(minOf(5_000L * retries, 60_000L))
                    }
                }

                // Cancelled mid-stream
                sendLocalBroadcast(Intent(BROADCAST_CANCELLED))
                withContext(Dispatchers.Main) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }

            } catch (e: Exception) {
                val errIntent = Intent(BROADCAST_ERROR).apply {
                    putExtra(EXTRA_MESSAGE, e.message ?: "Unknown error")
                }
                sendLocalBroadcast(errIntent)
                withContext(Dispatchers.Main) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                }
            }
        }
    }

    private fun broadcastProgress(progress: Double) {
        val intent = Intent(BROADCAST_PROGRESS).apply {
            putExtra(EXTRA_PROGRESS, progress)
        }
        sendLocalBroadcast(intent)
    }

    /// Android 14+ silently drops implicit broadcasts. Always target the
    /// current app's package so context-registered receivers in MainActivity
    /// actually receive the intent.
    private fun sendLocalBroadcast(intent: Intent) {
        intent.setPackage(packageName)
        sendBroadcast(intent)
    }

    private fun buildNotification(progressPercent: Int) =
        NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Downloading Gemma model")
            .setContentText(
                when {
                    progressPercent < 0 -> "Reconnecting…"
                    progressPercent >= 100 -> "Download complete"
                    else -> "$progressPercent%  (~2.58 GB total)"
                }
            )
            .setProgress(100, progressPercent.coerceIn(0, 100), progressPercent < 0)
            .setOngoing(progressPercent in 0..99)
            .setOnlyAlertOnce(true)
            .setContentIntent(
                PendingIntent.getActivity(
                    this, 0,
                    packageManager.getLaunchIntentForPackage(packageName),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
            .build()

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIF_CHANNEL_ID,
                "Model Download",
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Shows progress while downloading the local AI model" }
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
    }

    private fun sanitizeName(name: String): String {
        val safe = name.trim().replace(Regex("[^A-Za-z0-9._-]"), "_")
        return if (safe.lowercase().endsWith(".task") || safe.lowercase().endsWith(".litertlm")) safe
        else "${safe}.litertlm"
    }
}
