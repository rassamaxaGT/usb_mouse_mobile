import 'package:flutter/services.dart';

class HidService {
  static const MethodChannel _channel = MethodChannel('com.example.usb_mouse_mobile/hid');

  // Проверить наличие root-прав
  Future<bool> checkRoot() async {
    try {
      final bool hasRoot = await _channel.invokeMethod('checkRoot') ?? false;
      return hasRoot;
    } on PlatformException catch (_) {
      return false;
    }
  }

  // Инициализировать ConfigFS
  Future<Map<String, dynamic>> initUsbGadget() async {
    try {
      final Map<dynamic, dynamic>? result = await _channel.invokeMethod('initUsbGadget');
      if (result != null) {
        return Map<String, dynamic>.from(result);
      }
      return {'success': false, 'stdout': '', 'stderr': 'Null result from native'};
    } on PlatformException catch (e) {
      return {'success': false, 'stdout': '', 'stderr': e.toString()};
    }
  }

  // Подключиться к файлам устройств (/dev/hidg0, /dev/hidg1)
  Future<Map<String, dynamic>> connect() async {
    try {
      final Map<dynamic, dynamic>? result = await _channel.invokeMethod('connect');
      if (result != null) {
        return Map<String, dynamic>.from(result);
      }
      return {'success': false, 'details': '', 'error': 'Null result from native'};
    } on PlatformException catch (e) {
      return {'success': false, 'details': '', 'error': e.toString()};
    }
  }

  // Отключить потоки и процессы
  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
    } on PlatformException catch (_) {
      // Игнорируем ошибки при отключении
    }
  }

  // Отправить HID репорт мыши
  Future<bool> sendMouse({int buttons = 0, int dx = 0, int dy = 0, int wheel = 0, int hWheel = 0}) async {
    try {
      final bool sent = await _channel.invokeMethod('sendMouseReport', {
        'buttons': buttons,
        'dx': dx,
        'dy': dy,
        'wheel': wheel,
        'hWheel': hWheel,
      }) ?? false;
      return sent;
    } on PlatformException catch (_) {
      return false;
    }
  }

  // Отправить HID репорт клавиатуры
  Future<bool> sendKeyboard({int modifiers = 0, List<int> keycodes = const []}) async {
    try {
      final bool sent = await _channel.invokeMethod('sendKeyboardReport', {
        'modifiers': modifiers,
        'keycodes': keycodes,
      }) ?? false;
      return sent;
    } on PlatformException catch (_) {
      return false;
    }
  }
}
