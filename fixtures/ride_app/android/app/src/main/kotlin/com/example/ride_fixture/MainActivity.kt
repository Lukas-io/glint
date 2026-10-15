package com.example.ride_fixture

import android.os.Bundle
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

class MainActivity : FlutterActivity() {
    private var background: FlutterEngine? = null

    // A second, headless engine, as push and background-task plugins start one: its isolate registers Flutter's service extensions but has no widget tree.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val engine = FlutterEngine(applicationContext)
        val bundle = FlutterInjector.instance().flutterLoader().findAppBundlePath()
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(bundle, "backgroundMain"))
        background = engine
    }

    override fun onDestroy() {
        background?.destroy()
        background = null
        super.onDestroy()
    }
}
