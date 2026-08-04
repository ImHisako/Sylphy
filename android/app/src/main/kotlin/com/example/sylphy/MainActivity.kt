package com.example.sylphy

import android.content.Context
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private external fun initializeVeilid(context: Context)

    override fun onCreate(savedInstanceState: Bundle?) {
        try {
            System.loadLibrary("sylphy_core")
            initializeVeilid(applicationContext)
        } catch (error: Throwable) {
            Log.e("Sylphy", "Native Veilid initialization failed", error)
        }
        // Veilid needs Android's Context/JVM before Flutter can invoke FFI.
        super.onCreate(savedInstanceState)
    }
}
