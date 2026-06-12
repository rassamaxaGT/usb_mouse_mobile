package com.example.usb_mouse_mobile

import android.util.Log
import java.io.DataOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class HidController {
    private val TAG = "HidController"

    @Volatile private var keyboardStream: OutputStream? = null
    @Volatile private var mouseStream: OutputStream? = null

    @Volatile private var keyboardProcess: Process? = null
    @Volatile private var mouseProcess: Process? = null

    // Атомарный флаг: true когда disconnect уже запущен.
    // Позволяет прервать зависший write() и не начинать новые операции.
    private val isDisconnecting = AtomicBoolean(false)

    // ─────────────────────────────────────────────────────────────────────────
    // Вспомогательные методы
    // ─────────────────────────────────────────────────────────────────────────

    private fun findSuBinary(): String {
        val paths = arrayOf(
            "/system/bin/su", "/system/xbin/su", "/sbin/su",
            "/su/bin/su", "/system/sd/xbin/su", "/system/bin/failsafe/su",
            "/data/local/xbin/su", "/data/local/bin/su", "/data/local/su"
        )
        for (path in paths) {
            val file = File(path)
            if (file.exists() && file.canExecute()) {
                Log.d(TAG, "Found su binary at: $path")
                return path
            }
        }
        return "su"
    }

    /**
     * Выполняет shell-команду через su с жёстким таймаутом.
     * Возвращает пару (stdout, exitCode). При таймауте убивает процесс.
     */
    private fun runSuCommand(command: String, timeoutSec: Long = 10): Pair<String, Int> {
        val su = findSuBinary()
        val process = Runtime.getRuntime().exec(su)
        val os = DataOutputStream(process.outputStream)

        val stdoutBuilder = StringBuilder()
        val stderrBuilder = StringBuilder()

        val outThread = Thread {
            try { process.inputStream.bufferedReader().forEachLine { stdoutBuilder.append(it).append("\n") } } catch (_: Exception) {}
        }
        val errThread = Thread {
            try { process.errorStream.bufferedReader().forEachLine { stderrBuilder.append(it).append("\n") } } catch (_: Exception) {}
        }
        outThread.start(); errThread.start()

        os.writeBytes("$command\nexit\n"); os.flush()

        val finished = process.waitFor(timeoutSec, TimeUnit.SECONDS)
        if (!finished) {
            Log.e(TAG, "Command timed out after ${timeoutSec}s: ${command.take(80)}")
            process.destroyForcibly()
        }
        outThread.join(1000); errThread.join(1000)

        val exitCode = if (finished) process.exitValue() else -1
        val stdout = stdoutBuilder.toString().trim()
        if (stderrBuilder.isNotEmpty()) Log.e(TAG, "stderr: ${stderrBuilder.toString().trim()}")
        return Pair(stdout, exitCode)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Публичное API
    // ─────────────────────────────────────────────────────────────────────────

    fun checkRoot(): Boolean {
        return try {
            val (_, code) = runSuCommand("echo ok", 5)
            code == 0
        } catch (e: Exception) {
            Log.e(TAG, "Root check failed", e)
            false
        }
    }

    fun initUsbGadget(): Map<String, Any> {
        val script = """
            mount -t configfs none /config 2>/dev/null
            cd /config/usb_gadget || exit 1

            if [ -d "g1" ] && [ -d "g1/functions/hid.usb0" ] && [ -n "$(cat g1/UDC 2>/dev/null)" ]; then
                echo "USB HID is already active in system gadget g1"
                exit 0
            fi

            if [ -d "usb_mouse_mobile_gadget" ] && [ -n "$(cat usb_mouse_mobile_gadget/UDC 2>/dev/null)" ]; then
                echo "USB HID is already active in custom gadget"
                exit 0
            fi

            UDC_CONTROLLER=$(ls /sys/class/udc | head -n 1)
            if [ -z "${'$'}UDC_CONTROLLER" ]; then
                echo "No UDC controller found" >&2
                exit 2
            fi

            if [ -d "g1" ]; then
                echo "Integrating HID functions into system gadget g1"
                echo "" > g1/UDC 2>/dev/null
                sleep 0.3

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

                for config_dir in g1/configs/*; do
                    if [ -d "${'$'}config_dir" ]; then
                        ln -s /config/usb_gadget/g1/functions/hid.usb0 "${'$'}config_dir/hid.usb0" 2>/dev/null
                        ln -s /config/usb_gadget/g1/functions/hid.usb1 "${'$'}config_dir/hid.usb1" 2>/dev/null
                    fi
                done

                echo "${'$'}UDC_CONTROLLER" > g1/UDC
                echo "USB HID integrated into g1 successfully"
            else
                echo "Creating dedicated gadget"
                mkdir -p usb_mouse_mobile_gadget
                cd usb_mouse_mobile_gadget || exit 3
                echo 0x1d6b > idVendor; echo 0x0104 > idProduct
                echo 0x0100 > bcdDevice; echo 0x0200 > bcdUSB
                mkdir -p strings/0x409
                echo "123456789" > strings/0x409/serialnumber
                echo "Android" > strings/0x409/manufacturer
                echo "USB HID Simulator" > strings/0x409/product
                mkdir -p configs/c.1/strings/0x409
                echo "HID Composite" > configs/c.1/strings/0x409/configuration
                echo 120 > configs/c.1/MaxPower
                mkdir -p functions/hid.usb0
                echo 1 > functions/hid.usb0/protocol; echo 1 > functions/hid.usb0/subclass
                echo 8 > functions/hid.usb0/report_length
                printf "\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x03\x95\x05\x75\x01\x05\x08\x19\x01\x29\x05\x91\x02\x95\x01\x75\x03\x91\x03\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0" > functions/hid.usb0/report_desc
                mkdir -p functions/hid.usb1
                echo 2 > functions/hid.usb1/protocol; echo 1 > functions/hid.usb1/subclass
                echo 5 > functions/hid.usb1/report_length
                printf "\x05\x01\x09\x02\xa1\x01\x09\x01\xa1\x00\x05\x09\x19\x01\x29\x05\x15\x00\x25\x01\x95\x05\x75\x01\x81\x02\x95\x01\x75\x03\x81\x03\x05\x01\x09\x30\x09\x31\x15\x81\x25\x7f\x75\x08\x95\x02\x81\x06\x09\x38\x15\x81\x25\x7f\x75\x08\x95\x01\x81\x06\x05\x0c\x0a\x38\x02\x15\x81\x25\x7f\x75\x08\x95\x01\x81\x06\xc0\xc0" > functions/hid.usb1/report_desc
                ln -s functions/hid.usb0 configs/c.1/
                ln -s functions/hid.usb1 configs/c.1/
                echo "${'$'}UDC_CONTROLLER" > UDC
                echo "Custom USB HID gadget created successfully"
            fi

            setenforce 0 2>/dev/null
            chmod 666 /dev/hidg0 2>/dev/null
            chmod 666 /dev/hidg1 2>/dev/null
            exit 0
        """.trimIndent()

        return try {
            val (stdout, exitCode) = runSuCommand(script, 30)
            Log.d(TAG, "ConfigFS init stdout:\n$stdout")
            mapOf("success" to (exitCode == 0), "stdout" to stdout, "stderr" to "")
        } catch (e: Exception) {
            Log.e(TAG, "Gadget initialization failed", e)
            mapOf("success" to false, "stdout" to "", "stderr" to (e.message ?: "Unknown error"))
        }
    }

    fun connect(): Map<String, Any> {
        disconnect()
        isDisconnecting.set(false)

        val su = findSuBinary()

        // Сбрасываем SELinux и права
        try {
            val p = Runtime.getRuntime().exec(arrayOf(su, "-c", "setenforce 0; chmod 666 /dev/hidg0 /dev/hidg1"))
            p.waitFor(5, TimeUnit.SECONDS)
            p.destroyForcibly()
        } catch (e: Exception) { Log.e(TAG, "SELinux/chmod failed", e) }

        // Диагностика устройств
        val lsOutput = try {
            val p = Runtime.getRuntime().exec(arrayOf(su, "-c", "ls -l /dev/hidg*"))
            val out = p.inputStream.bufferedReader().readText().trim()
            p.waitFor(3, TimeUnit.SECONDS); p.destroyForcibly(); out
        } catch (e: Exception) { "ls failed: ${e.message}" }

        fun checkDev(dev: String): Boolean {
            return try {
                val p = Runtime.getRuntime().exec(arrayOf(su, "-c", "[ -c $dev ] && echo YES || echo NO"))
                val result = p.inputStream.bufferedReader().readLine()?.trim() == "YES"
                p.waitFor(3, TimeUnit.SECONDS); p.destroyForcibly(); result
            } catch (e: Exception) { false }
        }

        val kIsChar = checkDev("/dev/hidg0")
        val mIsChar = checkDev("/dev/hidg1")

        val details = "Devices: $lsOutput | hidg0 char: $kIsChar | hidg1 char: $mIsChar"
        Log.d(TAG, "Connection diagnostics:\n$details")

        if (!kIsChar || !mIsChar) {
            return mapOf(
                "success" to false,
                "details" to details,
                "error" to "HID device nodes not found or not character devices."
            )
        }

        // Пробуем прямой доступ
        val kFile = File("/dev/hidg0")
        val mFile = File("/dev/hidg1")

        try {
            if (kFile.exists() && kFile.canWrite()) {
                keyboardStream = FileOutputStream(kFile)
                Log.d(TAG, "Direct keyboard access obtained")
            }
        } catch (e: Exception) { Log.d(TAG, "Direct keyboard access failed", e) }

        try {
            if (mFile.exists() && mFile.canWrite()) {
                mouseStream = FileOutputStream(mFile)
                Log.d(TAG, "Direct mouse access obtained")
            }
        } catch (e: Exception) { Log.d(TAG, "Direct mouse access failed", e) }

        var keyboardErr = ""
        var mouseErr = ""

        // Если прямой доступ недоступен — используем dd bridge через su
        if (keyboardStream == null) {
            try {
                val proc = Runtime.getRuntime().exec(arrayOf(su, "-c", "dd of=/dev/hidg0 bs=8"))
                keyboardProcess = proc
                keyboardStream = proc.outputStream
                Thread.sleep(80)
                if (!proc.isAlive) {
                    keyboardErr = "Keyboard dd died immediately (code ${proc.exitValue()})"
                    Log.e(TAG, keyboardErr)
                    keyboardStream = null; keyboardProcess = null
                } else {
                    Log.d(TAG, "Root bridge for keyboard opened")
                }
            } catch (e: Exception) {
                keyboardErr = "Failed to start keyboard dd: ${e.message}"
                Log.e(TAG, keyboardErr, e)
            }
        }

        if (mouseStream == null) {
            try {
                val proc = Runtime.getRuntime().exec(arrayOf(su, "-c", "dd of=/dev/hidg1 bs=5"))
                mouseProcess = proc
                mouseStream = proc.outputStream
                Thread.sleep(80)
                if (!proc.isAlive) {
                    mouseErr = "Mouse dd died immediately (code ${proc.exitValue()})"
                    Log.e(TAG, mouseErr)
                    mouseStream = null; mouseProcess = null
                } else {
                    Log.d(TAG, "Root bridge for mouse opened")
                }
            } catch (e: Exception) {
                mouseErr = "Failed to start mouse dd: ${e.message}"
                Log.e(TAG, mouseErr, e)
            }
        }

        val success = keyboardStream != null && mouseStream != null
        val errors = listOf(keyboardErr, mouseErr).filter { it.isNotEmpty() }.joinToString("; ")
        return mapOf(
            "success" to success,
            "details" to details,
            "error" to if (success) "" else errors.ifEmpty { "Failed to open device streams." }
        )
    }

    fun sendMouseReport(buttons: Int, dx: Int, dy: Int, wheel: Int, hWheel: Int): Boolean {
        if (isDisconnecting.get()) return false
        val stream = mouseStream ?: return false
        return try {
            val report = byteArrayOf(
                (buttons and 0xFF).toByte(),
                (dx and 0xFF).toByte(),
                (dy and 0xFF).toByte(),
                (wheel and 0xFF).toByte(),
                (hWheel and 0xFF).toByte()
            )
            stream.write(report)
            stream.flush()
            true
        } catch (e: Exception) {
            if (!isDisconnecting.get()) {
                Log.e(TAG, "Error writing mouse report", e)
                disconnect()
            }
            false
        }
    }

    fun sendKeyboardReport(modifiers: Int, keycodes: ByteArray): Boolean {
        if (isDisconnecting.get()) return false
        val stream = keyboardStream ?: return false
        return try {
            val report = ByteArray(8)
            report[0] = (modifiers and 0xFF).toByte()
            report[1] = 0
            for (i in 0 until 6) {
                report[2 + i] = if (i < keycodes.size) keycodes[i] else 0
            }
            stream.write(report)
            stream.flush()
            true
        } catch (e: Exception) {
            if (!isDisconnecting.get()) {
                Log.e(TAG, "Error writing keyboard report", e)
                disconnect()
            }
            false
        }
    }

    fun disconnect() {
        // Флаг заставляет sendMouseReport/sendKeyboardReport сразу вернуть false
        // и не блокировать поток на следующем write().
        isDisconnecting.set(true)

        // Захватываем ссылки и обнуляем поля — после этого новые send() не начнутся
        val kStream = keyboardStream; keyboardStream = null
        val mStream = mouseStream;   mouseStream = null
        val kProc = keyboardProcess; keyboardProcess = null
        val mProc = mouseProcess;    mouseProcess = null

        // Принудительно убиваем процессы dd — это разблокирует их inputStream/outputStream
        // ещё до попытки закрыть наши стримы.
        try { kProc?.destroyForcibly() } catch (_: Exception) {}
        try { mProc?.destroyForcibly() } catch (_: Exception) {}

        // Закрываем стримы уже после убийства процессов
        try { kStream?.close() } catch (_: Exception) {}
        try { mStream?.close() } catch (_: Exception) {}

        // Убиваем системные фоновые процессы dd через pkill
        val su = findSuBinary()
        Thread {
            try {
                val p = Runtime.getRuntime().exec(arrayOf(su, "-c", "pkill -9 -f 'dd of=/dev/hidg'"))
                p.waitFor(5, TimeUnit.SECONDS)
                p.destroyForcibly()
                Log.d(TAG, "Disconnected and cleaned up dd processes")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to kill dd processes", e)
            }
            isDisconnecting.set(false)
        }.start()
    }
}
