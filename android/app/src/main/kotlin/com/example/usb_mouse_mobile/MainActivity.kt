package com.example.usb_mouse_mobile

import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.usb_mouse_mobile/hid"
    private val hidController = HidController()

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "checkRoot" -> {
                    val hasRoot = hidController.checkRoot()
                    result.success(hasRoot)
                }
                "initUsbGadget" -> {
                    val initialized = hidController.initUsbGadget()
                    result.success(initialized)
                }
                "connect" -> {
                    val connectResult = hidController.connect()
                    result.success(connectResult)
                }
                "sendMouseReport" -> {
                    val buttons = call.argument<Int>("buttons") ?: 0
                    val dx = call.argument<Int>("dx") ?: 0
                    val dy = call.argument<Int>("dy") ?: 0
                    val wheel = call.argument<Int>("wheel") ?: 0
                    val hWheel = call.argument<Int>("hWheel") ?: 0
                    
                    val sent = hidController.sendMouseReport(buttons, dx, dy, wheel, hWheel)
                    result.success(sent)
                }
                "sendKeyboardReport" -> {
                    val modifiers = call.argument<Int>("modifiers") ?: 0
                    val keycodesList = call.argument<List<Int>>("keycodes") ?: emptyList()
                    val keycodes = ByteArray(keycodesList.size)
                    for (i in keycodesList.indices) {
                        keycodes[i] = keycodesList[i].toByte()
                    }
                    
                    val sent = hidController.sendKeyboardReport(modifiers, keycodes)
                    result.success(sent)
                }
                "disconnect" -> {
                    hidController.disconnect()
                    result.success(true)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onDestroy() {
        hidController.disconnect()
        super.onDestroy()
    }
}

