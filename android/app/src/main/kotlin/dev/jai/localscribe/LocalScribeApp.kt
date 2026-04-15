package dev.jai.localscribe

import io.flutter.app.FlutterApplication
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.FlutterInjector

class LocalScribeApp : FlutterApplication() {

    @Volatile
    var processTextEngine: FlutterEngine? = null
        private set

    @Synchronized
    fun getOrCreateProcessTextEngine(): FlutterEngine {
        processTextEngine?.let { return it }

        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(applicationContext)
        }
        loader.ensureInitializationComplete(applicationContext, null)

        val engine = FlutterEngine(applicationContext)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                "processTextMain"
            )
        )
        processTextEngine = engine
        return engine
    }
}
