package com.example.sylphy

import android.content.Context
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private external fun initializeVeilid(context: Context)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            System.loadLibrary("sylphy_core")
            initializeVeilid(applicationContext)
        } catch (_: UnsatisfiedLinkError) {
        }
    }
}
