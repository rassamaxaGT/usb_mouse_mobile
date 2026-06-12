package com.example.usb_mouse_mobile

import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.usb_mouse_mobile/hid"
    private val hidController = HidController()

    // Отдельный пул потоков для всех блокирующих операций с HID.
    // Использование единственного потока гарантирует последовательность операций
    // и исключает гонки состояний при одновременных вызовах.
    private val ioExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {

                "checkRoot" -> {
                    ioExecutor.execute {
                        try {
                            val hasRoot = hidController.checkRoot()
                            runOnUiThread { result.success(hasRoot) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("ROOT_CHECK_FAILED", e.message, null) }
                        }
                    }
                }

                "initUsbGadget" -> {
                    ioExecutor.execute {
                        try {
                            val initialized = hidController.initUsbGadget()
                            runOnUiThread { result.success(initialized) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("INIT_FAILED", e.message, null) }
                        }
                    }
                }

                "connect" -> {
                    ioExecutor.execute {
                        try {
                            val connectResult = hidController.connect()
                            runOnUiThread { result.success(connectResult) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("CONNECT_FAILED", e.message, null) }
                        }
                    }
                }

                "sendMouseReport" -> {
                    val buttons = call.argument<Int>("buttons") ?: 0
                    val dx = call.argument<Int>("dx") ?: 0
                    val dy = call.argument<Int>("dy") ?: 0
                    val wheel = call.argument<Int>("wheel") ?: 0
                    val hWheel = call.argument<Int>("hWheel") ?: 0

                    ioExecutor.execute {
                        try {
                            val sent = hidController.sendMouseReport(buttons, dx, dy, wheel, hWheel)
                            runOnUiThread { result.success(sent) }
                        } catch (e: Exception) {
                            runOnUiThread { result.success(false) }
                        }
                    }
                }

                "sendKeyboardReport" -> {
                    val modifiers = call.argument<Int>("modifiers") ?: 0
                    val keycodesList = call.argument<List<Int>>("keycodes") ?: emptyList()
                    val keycodes = ByteArray(keycodesList.size) { keycodesList[it].toByte() }

                    ioExecutor.execute {
                        try {
                            val sent = hidController.sendKeyboardReport(modifiers, keycodes)
                            runOnUiThread { result.success(sent) }
                        } catch (e: Exception) {
                            runOnUiThread { result.success(false) }
                        }
                    }
                }

                "disconnect" -> {
                    // disconnect запускаем немедленно в отдельном потоке.
                    // Сразу возвращаем успех Flutter, не ждём завершения —
                    // блокировать UI thread ради cleanup недопустимо.
                    result.success(true)
                    ioExecutor.execute {
                        hidController.disconnect()
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onDestroy() {
        ioExecutor.execute { hidController.disconnect() }
        ioExecutor.shutdown()
        super.onDestroy()
    }
}
