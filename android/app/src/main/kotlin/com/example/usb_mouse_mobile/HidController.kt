package com.example.usb_mouse_mobile

import android.util.Log
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream

class HidController {
    private val TAG = "HidController"

    private var keyboardStream: OutputStream? = null
    private var mouseStream: OutputStream? = null
    
    private var keyboardProcess: Process? = null
    private var mouseProcess: Process? = null

    // Поиск бинарника su в стандартных путях Android
    private fun findSuBinary(): String {
        val paths = arrayOf(
            "/system/bin/su",
            "/system/xbin/su",
            "/sbin/su",
            "/su/bin/su",
            "/system/sd/xbin/su",
            "/system/bin/failsafe/su",
            "/data/local/xbin/su",
            "/data/local/bin/su",
            "/data/local/su"
        )
        for (path in paths) {
            val file = File(path)
            if (file.exists() && file.canExecute()) {
                Log.d(TAG, "Found su binary at: $path")
                return path
            }
        }
        return "su" // Fallback к дефолтному PATH
    }

    // Проверка наличия root прав
    fun checkRoot(): Boolean {
        return try {
            val su = findSuBinary()
            val process = Runtime.getRuntime().exec(su)
            val os = DataOutputStream(process.outputStream)
            os.writeBytes("exit\n")
            os.flush()
            process.waitFor() == 0
        } catch (e: Exception) {
            Log.e(TAG, "Root check failed", e)
            false
        }
    }

    // Инициализация ConfigFS гаджета
    fun initUsbGadget(): Map<String, Any> {
        val script = """
            # Монтируем ConfigFS если нужно
            mount -t configfs none /config 2>/dev/null
            cd /config/usb_gadget || exit 1
            
            # Проверяем, если функции hid.usb0 уже созданы в g1, и UDC уже привязан,
            # то выходим с успехом без повторной инициализации, чтобы не вызвать kernel deadlock.
            if [ -d "g1" ] && [ -d "g1/functions/hid.usb0" ] && [ -n "${'$'}(cat g1/UDC 2>/dev/null)" ]; then
                echo "USB HID is already active in system gadget g1"
                exit 0
            fi
            
            # То же самое для кастомного гаджета usb_mouse_mobile_gadget
            if [ -d "usb_mouse_mobile_gadget" ] && [ -n "${'$'}(cat usb_mouse_mobile_gadget/UDC 2>/dev/null)" ]; then
                echo "USB HID is already active in custom gadget"
                exit 0
            fi

            UDC_CONTROLLER=${'$'}(ls /sys/class/udc | head -n 1)
            if [ -z "${'$'}UDC_CONTROLLER" ]; then
                echo "No UDC controller found" >&2
                exit 2
            fi
            
            # Если системный гаджет g1 существует, мы можем интегрировать HID прямо в него
            if [ -d "g1" ]; then
                echo "Integrating HID functions into system gadget g1"
                # Временно отвязываем от UDC, чтобы изменить конфигурацию
                echo "" > g1/UDC 2>/dev/null
                
                # Создаем функции hid.usb0 и hid.usb1 в g1 если их нет
                if [ ! -d "g1/functions/hid.usb0" ]; then
                    mkdir -p g1/functions/hid.usb0
                    echo 1 > g1/functions/hid.usb0/protocol
                    echo 1 > g1/functions/hid.usb0/subclass
                    echo 8 > g1/functions/hid.usb0/report_length
                    printf "\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0" > g1/functions/hid.usb0/report_desc
                fi
                
                if [ ! -d "g1/functions/hid.usb1" ]; then
                    mkdir -p g1/functions/hid.usb1
                    echo 2 > g1/functions/hid.usb1/protocol
                    echo 1 > g1/functions/hid.usb1/subclass
                    echo 5 > g1/functions/hid.usb1/report_length
                    printf "\x05\x01\x09\x02\xa1\x01\x09\x01\xa1\x00\x05\x09\x19\x01\x29\x05\x15\x00\x25\x01\x95\x05\x75\x01\x81\x02\x95\x01\x75\x03\x81\x03\x05\x01\x09\x30\x09\x31\x15\x81\x25\x7f\x75\x08\x95\x02\x81\x06\x09\x38\x15\x81\x25\x7f\x75\x08\x95\x01\x81\x06\x05\x0c\x0a\x38\x02\x15\x81\x25\x7f\x75\x08\x95\x01\x81\x06\xc0\xc0" > g1/functions/hid.usb1/report_desc
                fi
                
                # Привязываем функции к существующим конфигурациям
                for config_dir in g1/configs/*; do
                    if [ -d "${'$'}config_dir" ]; then
                        ln -s /config/usb_gadget/g1/functions/hid.usb0 "${'$'}config_dir/hid.usb0" 2>/dev/null
                        ln -s /config/usb_gadget/g1/functions/hid.usb1 "${'$'}config_dir/hid.usb1" 2>/dev/null
                    fi
                done
                
                # Привязываем UDC обратно
                echo "${'$'}UDC_CONTROLLER" > g1/UDC
                echo "USB HID integrated into g1 successfully"
            else
                echo "System gadget g1 not found, creating dedicated gadget"
                # Создаем кастомный гаджет, если g1 нет
                mkdir -p usb_mouse_mobile_gadget
                cd usb_mouse_mobile_gadget || exit 3
                
                echo 0x1d6b > idVendor
                echo 0x0104 > idProduct
                echo 0x0100 > bcdDevice
                echo 0x0200 > bcdUSB
                
                mkdir -p strings/0x409
                echo "123456789" > strings/0x409/serialnumber
                echo "Android" > strings/0x409/manufacturer
                echo "USB HID Simulator" > strings/0x409/product
                
                mkdir -p configs/c.1
                mkdir -p configs/c.1/strings/0x409
                echo "HID Composite" > configs/c.1/strings/0x409/configuration
                echo 120 > configs/c.1/MaxPower
                
                mkdir -p functions/hid.usb0
                echo 1 > functions/hid.usb0/protocol
                echo 1 > functions/hid.usb0/subclass
                echo 8 > functions/hid.usb0/report_length
                printf "\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0" > functions/hid.usb0/report_desc
                
                mkdir -p functions/hid.usb1
                echo 2 > functions/hid.usb1/protocol
                echo 1 > functions/hid.usb1/subclass
                echo 5 > functions/hid.usb1/report_length
                printf "\x05\x01\x09\x02\xa1\x01\x09\x01\xa1\x00\x05\x09\x19\x01\x29\x05\x15\x00\x25\x01\x95\x05\x75\x01\x81\x02\x95\x01\x75\x03\x81\x03\x05\x01\x09\x30\x09\x31\x15\x81\x25\x7f\x75\x08\x95\x02\x81\x06\x09\x38\x15\x81\x25\x7f\x75\x08\x95\x01\x81\x06\x05\x0c\x0a\x38\x02\x15\x81\x25\x7f\x75\x08\x95\x01\x81\x06\xc0\xc0" > functions/hid.usb1/report_desc
                
                ln -s functions/hid.usb0 configs/c.1/
                ln -s functions/hid.usb1 configs/c.1/
                
                echo "${'$'}UDC_CONTROLLER" > UDC
                echo "Custom USB HID gadget created successfully"
            fi
            
            # Отключаем принудительный режим SELinux
            setenforce 0 2>/dev/null

            # Разрешаем доступ к файлам устройств
            chmod 666 /dev/hidg0 2>/dev/null
            chmod 666 /dev/hidg1 2>/dev/null
            exit 0
        """.trimIndent()

        return try {
            val su = findSuBinary()
            val process = Runtime.getRuntime().exec(su)
            val os = DataOutputStream(process.outputStream)
            
            // Читаем потоки вывода процесса в отдельных потоках, чтобы избежать дедлока
            val stdoutStringBuilder = StringBuilder()
            val stderrStringBuilder = StringBuilder()
            
            val stdoutThread = Thread {
                try {
                    process.inputStream.bufferedReader().use { reader ->
                        var line: String?
                        while (reader.readLine().also { line = it } != null) {
                            stdoutStringBuilder.append(line).append("\n")
                        }
                    }
                } catch (e: Exception) {}
            }
            
            val stderrThread = Thread {
                try {
                    process.errorStream.bufferedReader().use { reader ->
                        var line: String?
                        while (reader.readLine().also { line = it } != null) {
                            stderrStringBuilder.append(line).append("\n")
                        }
                    }
                } catch (e: Exception) {}
            }
            
            stdoutThread.start()
            stderrThread.start()

            os.writeBytes(script + "\n")
            os.writeBytes("exit\n")
            os.flush()
            
            val exitCode = process.waitFor()
            
            stdoutThread.join(1000)
            stderrThread.join(1000)
            
            val stdout = stdoutStringBuilder.toString().trim()
            val stderr = stderrStringBuilder.toString().trim()
            
            if (stdout.isNotEmpty()) {
                Log.d(TAG, "ConfigFS init stdout:\n$stdout")
            }
            if (stderr.isNotEmpty()) {
                Log.e(TAG, "ConfigFS init stderr:\n$stderr")
            }
            
            mapOf(
                "success" to (exitCode == 0),
                "stdout" to stdout,
                "stderr" to stderr
            )
        } catch (e: Exception) {
            Log.e(TAG, "Gadget initialization failed", e)
            mapOf(
                "success" to false,
                "stdout" to "",
                "stderr" to (e.message ?: "Unknown Kotlin exception")
            )
        }
    }

    // Подключение к файлам устройств с диагностикой
    fun connect(): Map<String, Any> {
        disconnect()

        val su = findSuBinary()
        
        // 0. Переводим SELinux в permissive и принудительно задаем права доступа 666
        try {
            val processSetenforce = Runtime.getRuntime().exec(arrayOf(su, "-c", "setenforce 0"))
            processSetenforce.waitFor()
            
            val processChmod = Runtime.getRuntime().exec(arrayOf(su, "-c", "chmod 666 /dev/hidg0 /dev/hidg1"))
            processChmod.waitFor()
        } catch (e: Exception) {
            Log.e(TAG, "SELinux/Chmod setup failed in connect", e)
        }

        // 1. Проверяем существование и тип файлов устройств
        var kExists = false
        var kIsChar = false
        var mExists = false
        var mIsChar = false
        var lsOutput = ""
        
        try {
            val processLs = Runtime.getRuntime().exec(arrayOf(su, "-c", "ls -l /dev/hidg*"))
            lsOutput = processLs.inputStream.bufferedReader().readText().trim()
            
            val processK = Runtime.getRuntime().exec(arrayOf(su, "-c", "[ -e /dev/hidg0 ] && echo YES || echo NO"))
            kExists = processK.inputStream.bufferedReader().readLine()?.trim() == "YES"
            
            val processKChar = Runtime.getRuntime().exec(arrayOf(su, "-c", "[ -c /dev/hidg0 ] && echo YES || echo NO"))
            kIsChar = processKChar.inputStream.bufferedReader().readLine()?.trim() == "YES"
            
            val processM = Runtime.getRuntime().exec(arrayOf(su, "-c", "[ -e /dev/hidg1 ] && echo YES || echo NO"))
            mExists = processM.inputStream.bufferedReader().readLine()?.trim() == "YES"
            
            val processMChar = Runtime.getRuntime().exec(arrayOf(su, "-c", "[ -c /dev/hidg1 ] && echo YES || echo NO"))
            mIsChar = processMChar.inputStream.bufferedReader().readLine()?.trim() == "YES"
        } catch (e: Exception) {
            Log.e(TAG, "Diagnostics failed", e)
            lsOutput = "Diagnostics failed: ${e.message}"
        }

        val details = """
            Devices list (ls -l):
            $lsOutput
            
            Keyboard device (/dev/hidg0):
            - Exists: $kExists
            - Is Character Device: $kIsChar
            
            Mouse device (/dev/hidg1):
            - Exists: $mExists
            - Is Character Device: $mIsChar
        """.trimIndent()

        Log.d(TAG, "Connection diagnostics:\n$details")

        if (!kIsChar || !mIsChar) {
            return mapOf(
                "success" to false,
                "details" to details,
                "error" to "HID device nodes are not character devices. Kernel may not support CONFIG_USB_F_HID."
            )
        }

        val kFile = File("/dev/hidg0")
        val mFile = File("/dev/hidg1")

        try {
            if (kFile.exists() && kFile.canWrite()) {
                keyboardStream = FileOutputStream(kFile)
                Log.d(TAG, "Direct access to keyboard device obtained")
            }
        } catch (e: Exception) {
            Log.d(TAG, "Direct keyboard access failed, falling back to root bridge", e)
        }

        try {
            if (mFile.exists() && mFile.canWrite()) {
                mouseStream = FileOutputStream(mFile)
                Log.d(TAG, "Direct access to mouse device obtained")
            }
        } catch (e: Exception) {
            Log.d(TAG, "Direct mouse access failed, falling back to root bridge", e)
        }

        var keyboardErr = ""
        var mouseErr = ""

        if (keyboardStream == null) {
            try {
                val proc = Runtime.getRuntime().exec(arrayOf(su, "-c", "dd of=/dev/hidg0 bs=1"))
                keyboardProcess = proc
                keyboardStream = proc.outputStream
                Log.d(TAG, "Root bridge for keyboard opened")
                
                // Даем процессу запуститься и проверяем статус
                Thread.sleep(50)
                if (!proc.isAlive) {
                    val errText = proc.errorStream.bufferedReader().readText().trim()
                    val exitVal = proc.exitValue()
                    keyboardErr = "Keyboard dd died immediately (code $exitVal): $errText"
                    Log.e(TAG, keyboardErr)
                    keyboardStream = null
                }
            } catch (e: Exception) {
                keyboardErr = "Failed to start keyboard dd: ${e.message}"
                Log.e(TAG, keyboardErr, e)
            }
        }

        if (mouseStream == null) {
            try {
                val proc = Runtime.getRuntime().exec(arrayOf(su, "-c", "dd of=/dev/hidg1 bs=1"))
                mouseProcess = proc
                mouseStream = proc.outputStream
                Log.d(TAG, "Root bridge for mouse opened")
                
                // Даем процессу запуститься и проверяем статус
                Thread.sleep(50)
                if (!proc.isAlive) {
                    val errText = proc.errorStream.bufferedReader().readText().trim()
                    val exitVal = proc.exitValue()
                    mouseErr = "Mouse dd died immediately (code $exitVal): $errText"
                    Log.e(TAG, mouseErr)
                    mouseStream = null
                }
            } catch (e: Exception) {
                mouseErr = "Failed to start mouse dd: ${e.message}"
                Log.e(TAG, mouseErr, e)
            }
        }

        val success = keyboardStream != null && mouseStream != null
        val combinedErrors = listOf(keyboardErr, mouseErr).filter { it.isNotEmpty() }.joinToString("\n")
        
        return mapOf(
            "success" to success,
            "details" to details,
            "error" to if (success) "" else (if (combinedErrors.isNotEmpty()) combinedErrors else "Failed to open streams to device nodes.")
        )
    }

    // Отправка репорта мыши (5 байт)
    fun sendMouseReport(buttons: Int, dx: Int, dy: Int, wheel: Int, hWheel: Int): Boolean {
        val stream = mouseStream ?: return false
        return try {
            val report = ByteArray(5)
            report[0] = (buttons and 0xFF).toByte()
            report[1] = (dx and 0xFF).toByte()
            report[2] = (dy and 0xFF).toByte()
            report[3] = (wheel and 0xFF).toByte()
            report[4] = (hWheel and 0xFF).toByte()

            stream.write(report)
            stream.flush()
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error writing mouse report", e)
            disconnect()
            false
        }
    }

    // Отправка репорта клавиатуры (8 байт)
    fun sendKeyboardReport(modifiers: Int, keycodes: ByteArray): Boolean {
        val stream = keyboardStream ?: return false
        return try {
            val report = ByteArray(8)
            report[0] = (modifiers and 0xFF).toByte()
            report[1] = 0 // reserved
            for (i in 0 until 6) {
                report[2 + i] = if (i < keycodes.size) keycodes[i] else 0
            }

            stream.write(report)
            stream.flush()
            true
        } catch (e: Exception) {
            Log.e(TAG, "Error writing keyboard report", e)
            disconnect()
            false
        }
    }

    // Закрытие всех ресурсов
    fun disconnect() {
        // Сначала синхронно в текущем потоке закрываем потоки и процессы Java,
        // чтобы немедленно заблокировать запись новых отчетов и освободить дескрипторы.
        try {
            keyboardStream?.close()
        } catch (e: Exception) {}
        keyboardStream = null

        try {
            mouseStream?.close()
        } catch (e: Exception) {}
        mouseStream = null

        try {
            keyboardProcess?.destroy()
        } catch (e: Exception) {}
        keyboardProcess = null

        try {
            mouseProcess?.destroy()
        } catch (e: Exception) {}
        mouseProcess = null

        // Запускаем фоновый поток для очистки системных процессов dd
        Thread {
            val su = findSuBinary()
            try {
                Runtime.getRuntime().exec(arrayOf(su, "-c", "pkill -9 -f 'dd of=/dev/hidg'")).waitFor()
                Log.d(TAG, "Killed all dd processes writing to hidg in background")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to kill dd processes", e)
            }
            Log.d(TAG, "Disconnected and cleaned up resources successfully")
        }.start()
    }
}
