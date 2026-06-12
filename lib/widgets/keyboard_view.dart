import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import '../services/hid_service.dart';

class KeyboardView extends StatefulWidget {
  final HidService hidService;

  const KeyboardView({super.key, required this.hidService});

  @override
  State<KeyboardView> createState() => _KeyboardViewState();
}

class _KeyboardViewState extends State<KeyboardView> {
  final TextEditingController _textController = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  final TextEditingController _macroController = TextEditingController(
    text: 'DELAY 1000\nGUI r\nDELAY 200\nSTRING notepad\nDELAY 200\nENTER\nDELAY 500\nSTRING Hello from USB Mouse Mobile Ducky!',
  );

  final TextEditingController _macroNameController = TextEditingController(text: 'My Macro');

  int _activeSubTab = 0; // 0 - Keyboard, 1 - Ducky Macro Studio, 2 - Visual Builder

  // Состояние зажатых модификаторов клавиатуры
  bool ctrlPressed = false;
  bool shiftPressed = false;
  bool altPressed = false;
  bool metaPressed = false; // Win/Cmd

  bool _isRunningMacro = false;
  String _macroStatus = 'Ready';
  final List<String> _macroLogs = [];

  // Сохраненные макросы и шаги конструктора
  List<SavedMacro> _savedMacros = [];
  final List<MacroStep> _builderSteps = [
    MacroStep(type: 'delay', delayMs: 1000),
    MacroStep(type: 'combo', gui: true, key: 'R'),
    MacroStep(type: 'delay', delayMs: 200),
    MacroStep(type: 'text', text: 'notepad'),
    MacroStep(type: 'delay', delayMs: 200),
    MacroStep(type: 'combo', key: 'ENTER'),
  ];

  // Маппинг кириллицы в латинские символы
  final Map<String, String> _ruToEn = {
    'й': 'q', 'ц': 'w', 'у': 'e', 'к': 'r', 'е': 't', 'н': 'y', 'г': 'u', 'ш': 'i', 'щ': 'o', 'з': 'p', 'х': '[', 'ъ': ']',
    'ф': 'a', 'ы': 's', 'в': 'd', 'а': 'f', 'п': 'g', 'р': 'h', 'о': 'j', 'л': 'k', 'д': 'l', 'ж': ';', 'э': '\'',
    'я': 'z', 'ч': 'x', 'с': 'c', 'м': 'v', 'и': 'b', 'т': 'n', 'ь': 'm', 'б': ',', 'ю': '.', 'ё': '`',
    'Й': 'Q', 'Ц': 'W', 'У': 'E', 'К': 'R', 'Е': 'T', 'Н': 'Y', 'Г': 'U', 'Ш': 'I', 'Щ': 'O', 'З': 'P', 'Х': '{', 'Ъ': '}',
    'Ф': 'A', 'Ы': 'S', 'В': 'D', 'А': 'F', 'П': 'G', 'Р': 'H', 'О': 'J', 'Л': 'K', 'Д': 'L', 'Ж': ':', 'Э': '"',
    'Я': 'Z', 'Ч': 'X', 'С': 'C', 'М': 'V', 'И': 'B', 'Т': 'N', 'Ь': 'M', 'Б': '<', 'Ю': '>', 'Ё': '~'
  };

  // Коды для небуквенных клавиш (HID Usage Table)
  final Map<String, int> _specialKeys = {
    'ENTER': 0x28,
    'ESC': 0x29,
    'BACKSPACE': 0x2A,
    'TAB': 0x2B,
    'SPACE': 0x2C,
    'UP': 0x52,
    'DOWN': 0x51,
    'LEFT': 0x50,
    'RIGHT': 0x4F,
    'F1': 0x3A, 'F2': 0x3B, 'F3': 0x3C, 'F4': 0x3D, 'F5': 0x3E, 'F6': 0x3F,
    'F7': 0x40, 'F8': 0x41, 'F9': 0x42, 'F10': 0x43, 'F11': 0x44, 'F12': 0x45,
    'DELETE': 0x4C, 'HOME': 0x4A, 'END': 0x4D, 'PAGEUP': 0x4B, 'PAGEDOWN': 0x4E,
  };

  // Маппинг клавиш DuckyScript к HID сканкодам
  final Map<String, int> _duckySpecialKeys = {
    'ENTER': 0x28,
    'ESCAPE': 0x29,
    'ESC': 0x29,
    'BACKSPACE': 0x2A,
    'TAB': 0x2B,
    'SPACE': 0x2C,
    'PRINTSCREEN': 0x46,
    'SCROLLLOCK': 0x47,
    'PAUSE': 0x48,
    'INSERT': 0x49,
    'HOME': 0x4A,
    'PAGEUP': 0x4B,
    'DELETE': 0x4C,
    'END': 0x4D,
    'PAGEDOWN': 0x4E,
    'RIGHT': 0x4F,
    'LEFT': 0x50,
    'DOWN': 0x51,
    'UP': 0x52,
    'NUMLOCK': 0x53,
    'CAPSLOCK': 0x39,
    'APP': 0x65,
    'MENU': 0x65,
    'F1': 0x3A, 'F2': 0x3B, 'F3': 0x3C, 'F4': 0x3D, 'F5': 0x3E, 'F6': 0x3F,
    'F7': 0x40, 'F8': 0x41, 'F9': 0x42, 'F10': 0x43, 'F11': 0x44, 'F12': 0x45,
  };

  final Map<String, int> _duckyModifiers = {
    'CTRL': 0x01,
    'CONTROL': 0x01,
    'SHIFT': 0x02,
    'ALT': 0x04,
    'GUI': 0x08,
    'WINDOWS': 0x08,
  };

  // Список доступных клавиш для конструктора
  final List<String> _availableKeys = [
    'ENTER', 'ESCAPE', 'TAB', 'SPACE', 'BACKSPACE', 'DELETE',
    'UP', 'DOWN', 'LEFT', 'RIGHT',
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
    'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
    'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12',
    'HOME', 'END', 'PAGEUP', 'PAGEDOWN', 'INSERT', 'PRINTSCREEN'
  ];

  // Маппинг символов к HID сканкодам и флагу Shift
  static final Map<String, KeyStroke> _charToStroke = {
    'a': KeyStroke(0x04, false), 'A': KeyStroke(0x04, true),
    'b': KeyStroke(0x05, false), 'B': KeyStroke(0x05, true),
    'c': KeyStroke(0x06, false), 'C': KeyStroke(0x06, true),
    'd': KeyStroke(0x07, false), 'D': KeyStroke(0x07, true),
    'e': KeyStroke(0x08, false), 'E': KeyStroke(0x08, true),
    'f': KeyStroke(0x09, false), 'F': KeyStroke(0x09, true),
    'g': KeyStroke(0x0A, false), 'G': KeyStroke(0x0A, true),
    'h': KeyStroke(0x0B, false), 'H': KeyStroke(0x0B, true),
    'i': KeyStroke(0x0C, false), 'I': KeyStroke(0x0C, true),
    'j': KeyStroke(0x0D, false), 'J': KeyStroke(0x0D, true),
    'k': KeyStroke(0x0E, false), 'K': KeyStroke(0x0E, true),
    'l': KeyStroke(0x0F, false), 'L': KeyStroke(0x0F, true),
    'm': KeyStroke(0x10, false), 'M': KeyStroke(0x10, true),
    'n': KeyStroke(0x11, false), 'N': KeyStroke(0x11, true),
    'o': KeyStroke(0x12, false), 'O': KeyStroke(0x12, true),
    'p': KeyStroke(0x13, false), 'P': KeyStroke(0x13, true),
    'q': KeyStroke(0x14, false), 'Q': KeyStroke(0x14, true),
    'r': KeyStroke(0x15, false), 'R': KeyStroke(0x15, true),
    's': KeyStroke(0x16, false), 'S': KeyStroke(0x16, true),
    't': KeyStroke(0x17, false), 'T': KeyStroke(0x17, true),
    'u': KeyStroke(0x18, false), 'U': KeyStroke(0x18, true),
    'v': KeyStroke(0x19, false), 'V': KeyStroke(0x19, true),
    'w': KeyStroke(0x1A, false), 'W': KeyStroke(0x1A, true),
    'x': KeyStroke(0x1B, false), 'X': KeyStroke(0x1B, true),
    'y': KeyStroke(0x1C, false), 'Y': KeyStroke(0x1C, true),
    'z': KeyStroke(0x1D, false), 'Z': KeyStroke(0x1D, true),
    '1': KeyStroke(0x1E, false), '!': KeyStroke(0x1E, true),
    '2': KeyStroke(0x1F, false), '@': KeyStroke(0x1F, true),
    '3': KeyStroke(0x20, false), '#': KeyStroke(0x20, true),
    '4': KeyStroke(0x21, false), '\$': KeyStroke(0x21, true),
    '5': KeyStroke(0x22, false), '%': KeyStroke(0x22, true),
    '6': KeyStroke(0x23, false), '^': KeyStroke(0x23, true),
    '7': KeyStroke(0x24, false), '&': KeyStroke(0x24, true),
    '8': KeyStroke(0x25, false), '*': KeyStroke(0x25, true),
    '9': KeyStroke(0x26, false), '(': KeyStroke(0x26, true),
    '0': KeyStroke(0x27, false), ')': KeyStroke(0x27, true),
    ' ': KeyStroke(0x2C, false), '\n': KeyStroke(0x28, false), '\t': KeyStroke(0x2B, false),
    '-': KeyStroke(0x2D, false), '_': KeyStroke(0x2D, true),
    '=': KeyStroke(0x2E, false), '+': KeyStroke(0x2E, true),
    '[': KeyStroke(0x2F, false), '{': KeyStroke(0x2F, true),
    ']': KeyStroke(0x30, false), '}': KeyStroke(0x30, true),
    '\\': KeyStroke(0x31, false), '|': KeyStroke(0x31, true),
    ';': KeyStroke(0x33, false), ':': KeyStroke(0x33, true),
    '\'': KeyStroke(0x34, false), '"': KeyStroke(0x34, true),
    '`': KeyStroke(0x35, false), '~': KeyStroke(0x35, true),
    ',': KeyStroke(0x36, false), '<': KeyStroke(0x36, true),
    '.': KeyStroke(0x37, false), '>': KeyStroke(0x37, true),
    '/': KeyStroke(0x38, false), '?': KeyStroke(0x38, true),
  };

  final Map<String, String> _presets = {
    'Demo Notepad': 'DELAY 1000\nGUI r\nDELAY 200\nSTRING notepad\nDELAY 200\nENTER\nDELAY 500\nSTRING Hello from USB Mouse Mobile Ducky!',
    'Lock PC': 'DELAY 200\nGUI l',
    'Open CMD (Admin)': 'DELAY 500\nGUI r\nDELAY 200\nSTRING cmd\nDELAY 200\nCTRL SHIFT ENTER\nDELAY 800\nALT y',
    'Minimize All': 'DELAY 200\nGUI d',
  };

  @override
  void initState() {
    super.initState();
    _loadSavedMacros();
  }

  // Загрузка сохраненных макросов из локальной памяти
  Future<void> _loadSavedMacros() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? jsonStr = prefs.getString('user_macros');
      if (jsonStr != null) {
        final List<dynamic> list = jsonDecode(jsonStr);
        setState(() {
          _savedMacros = list.map((item) => SavedMacro.fromJson(item)).toList();
        });
      }
    } catch (e) {
      debugPrint('Error loading saved macros: $e');
    }
  }

  // Сохранение текущего макроса из конструктора
  Future<void> _saveMacro() async {
    final String name = _macroNameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a macro name first'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final int index = _savedMacros.indexWhere((m) => m.name == name);
    final SavedMacro newMacro = SavedMacro(
      name: name,
      steps: List.from(_builderSteps),
    );

    setState(() {
      if (index >= 0) {
        _savedMacros[index] = newMacro;
      } else {
        _savedMacros.add(newMacro);
      }
    });

    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String jsonStr = jsonEncode(_savedMacros.map((m) => m.toJson()).toList());
      await prefs.setString('user_macros', jsonStr);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Macro "$name" saved successfully!'),
            backgroundColor: const Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error saving macro: $e');
    }
  }

  // Удаление макроса
  Future<void> _deleteMacro(String name) async {
    setState(() {
      _savedMacros.removeWhere((m) => m.name == name);
    });

    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String jsonStr = jsonEncode(_savedMacros.map((m) => m.toJson()).toList());
      await prefs.setString('user_macros', jsonStr);
    } catch (e) {
      debugPrint('Error deleting macro: $e');
    }
  }

  // Загрузка макроса в конструктор
  void _loadMacroIntoBuilder(SavedMacro macro) {
    setState(() {
      _macroNameController.text = macro.name;
      _builderSteps.clear();
      _builderSteps.addAll(macro.steps.map((s) => MacroStep(
            type: s.type,
            delayMs: s.delayMs,
            text: s.text,
            key: s.key,
            ctrl: s.ctrl,
            shift: s.shift,
            alt: s.alt,
            gui: s.gui,
          )));
    });
    Navigator.of(context).pop();
  }

  // Получить текущую битовую маску модификаторов
  int _getModifiers({bool forceShift = false}) {
    int mod = 0;
    if (ctrlPressed) mod |= 0x01;
    if (shiftPressed || forceShift) mod |= 0x02;
    if (altPressed) mod |= 0x04;
    if (metaPressed) mod |= 0x08;
    return mod;
  }

  // Отправить одиночное нажатие клавиши по её HID-коду
  Future<void> _sendKey(int code, {bool forceShift = false}) async {
    int modifiers = _getModifiers(forceShift: forceShift);
    await widget.hidService.sendKeyboard(modifiers: modifiers, keycodes: [code]);
    await Future.delayed(const Duration(milliseconds: 15));
    await widget.hidService.sendKeyboard(modifiers: _getModifiers(), keycodes: []);
  }

  // Обработка текстового ввода
  void _onTextChanged(String text) async {
    if (text.isEmpty) return;
    String char = text.substring(text.length - 1);
    _textController.clear();

    if (_ruToEn.containsKey(char)) {
      char = _ruToEn[char]!;
    }

    final KeyStroke? stroke = _charToStroke[char];
    if (stroke != null) {
      await widget.hidService.sendKeyboard(
        modifiers: stroke.shift ? 0x02 : 0x00,
        keycodes: [stroke.code],
      );
      await Future.delayed(const Duration(milliseconds: 15));
      await widget.hidService.sendKeyboard(modifiers: 0, keycodes: []);
    }
  }

  // Отправка специальной клавиши
  void _pressSpecialKey(String keyName) {
    if (_specialKeys.containsKey(keyName)) {
      _sendKey(_specialKeys[keyName]!);
    }
  }

  void _logMacro(String msg) {
    if (!mounted) return;
    setState(() {
      _macroLogs.add('[${DateTime.now().toString().substring(11, 19)}] $msg');
    });
  }

  // Парсинг и запуск макроса
  Future<void> _runDuckyScript(String script) async {
    if (_isRunningMacro) return;

    setState(() {
      _isRunningMacro = true;
      _macroLogs.clear();
      _macroStatus = 'Running...';
    });

    final List<String> lines = script.split('\n');
    int defaultDelay = 50;

    try {
      for (int i = 0; i < lines.length; i++) {
        if (!_isRunningMacro) {
          _logMacro('Execution cancelled.');
          break;
        }

        final String line = lines[i].trim();
        if (line.isEmpty || line.startsWith('REM')) {
          continue;
        }

        final List<String> tokens = line.split(RegExp(r'\s+'));
        final String command = tokens[0].toUpperCase();

        if (command == 'DEFAULT_DELAY' || command == 'DEFAULTDELAY') {
          if (tokens.length > 1) {
            defaultDelay = int.tryParse(tokens[1]) ?? 50;
            _logMacro('Set default delay to $defaultDelay ms');
          }
        } else if (command == 'DELAY') {
          if (tokens.length > 1) {
            final int ms = int.tryParse(tokens[1]) ?? 100;
            _logMacro('Delay: $ms ms');
            await Future.delayed(Duration(milliseconds: ms));
          }
        } else if (command == 'STRING') {
          final String text = line.substring(line.indexOf(tokens[1]));
          _logMacro('Typing: "$text"');
          for (int c = 0; c < text.length; c++) {
            if (!_isRunningMacro) break;
            final String char = text[c];
            String lookupChar = char;

            if (_ruToEn.containsKey(char)) {
              lookupChar = _ruToEn[char]!;
            }

            final KeyStroke? stroke = _charToStroke[lookupChar];
            if (stroke != null) {
              await widget.hidService.sendKeyboard(
                modifiers: stroke.shift ? 0x02 : 0x00,
                keycodes: [stroke.code],
              );
              await Future.delayed(const Duration(milliseconds: 15));
              await widget.hidService.sendKeyboard(modifiers: 0, keycodes: []);
              await Future.delayed(Duration(milliseconds: defaultDelay));
            }
          }
        } else {
          // Парсинг комбинаций клавиш
          int modifiers = 0;
          final List<int> keycodes = [];

          for (final String token in tokens) {
            final String upperToken = token.toUpperCase();
            if (_duckyModifiers.containsKey(upperToken)) {
              modifiers |= _duckyModifiers[upperToken]!;
            } else if (_duckySpecialKeys.containsKey(upperToken)) {
              keycodes.add(_duckySpecialKeys[upperToken]!);
            } else if (token.length == 1) {
              String char = token;
              if (_ruToEn.containsKey(char)) {
                char = _ruToEn[char]!;
              }
              final KeyStroke? stroke = _charToStroke[char];
              if (stroke != null) {
                if (stroke.shift) modifiers |= 0x02;
                keycodes.add(stroke.code);
              }
            }
          }

          if (modifiers != 0 || keycodes.isNotEmpty) {
            _logMacro('Keys combo: $line');
            await widget.hidService.sendKeyboard(modifiers: modifiers, keycodes: keycodes);
            await Future.delayed(const Duration(milliseconds: 20));
            await widget.hidService.sendKeyboard(modifiers: 0, keycodes: []);
            await Future.delayed(Duration(milliseconds: defaultDelay));
          }
        }
      }

      setState(() {
        _macroStatus = _isRunningMacro ? 'Completed!' : 'Stopped';
        _isRunningMacro = false;
      });
    } catch (e) {
      _logMacro('Error: ${e.toString()}');
      setState(() {
        _macroStatus = 'Error occurred';
        _isRunningMacro = false;
      });
    }
  }

  // Перемещение шага в конструкторе
  void _moveStep(int index, int direction) {
    final int newIndex = index + direction;
    if (newIndex < 0 || newIndex >= _builderSteps.length) return;
    setState(() {
      final step = _builderSteps.removeAt(index);
      _builderSteps.insert(newIndex, step);
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _macroController.dispose();
    _macroNameController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          // Под-вкладки (Keyboard / Ducky Macro Studio / Visual Builder)
          _buildSubTabBar(),
          const SizedBox(height: 12),

          // Переключение отображаемого контента
          Expanded(
            child: _activeSubTab == 0
                ? _buildKeyboardLayout()
                : _activeSubTab == 1
                    ? _buildDuckyMacroStudio()
                    : _buildVisualBuilder(),
          ),
        ],
      ),
    );
  }

  // Под-таббар
  Widget _buildSubTabBar() {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          _buildSubTabButton(0, 'KEYS'),
          _buildSubTabButton(1, 'DUCKY STUDIO'),
          _buildSubTabButton(2, 'VISUAL BUILDER'),
        ],
      ),
    );
  }

  Widget _buildSubTabButton(int index, String label) {
    final bool isActive = _activeSubTab == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _activeSubTab = index),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF6366F1) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isActive ? Colors.white : Colors.white60,
              fontWeight: FontWeight.bold,
              fontSize: 10,
            ),
          ),
        ),
      ),
    );
  }

  // Клавиатурный интерфейс
  Widget _buildKeyboardLayout() {
    return Column(
      children: [
        // Панель ввода
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  focusNode: _focusNode,
                  onChanged: _onTextChanged,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Tap here to type on Host PC...',
                    hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
                    border: InputBorder.none,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_hide, color: Colors.white70, size: 18),
                onPressed: () => _focusNode.unfocus(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Модификаторы
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildModifierButton('CTRL', ctrlPressed, (val) => setState(() => ctrlPressed = val)),
            _buildModifierButton('SHIFT', shiftPressed, (val) => setState(() => shiftPressed = val)),
            _buildModifierButton('ALT', altPressed, (val) => setState(() => altPressed = val)),
            _buildModifierButton('WIN', metaPressed, (val) => setState(() => metaPressed = val)),
          ],
        ),
        const SizedBox(height: 12),

        // Спецклавиши
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.015),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Row(
                  children: [
                    _buildSpecialButton('ESC', flex: 1),
                    _buildSpecialButton('TAB', flex: 1),
                    _buildSpecialButton('BACKSPACE', flex: 2, icon: Icons.backspace_outlined),
                    _buildSpecialButton('DELETE', flex: 1),
                  ],
                ),
                Row(
                  children: [
                    _buildSpecialButton('F1'),
                    _buildSpecialButton('F5'),
                    _buildSpecialButton('F11'),
                    _buildSpecialButton('F12'),
                  ],
                ),
                Row(
                  children: [
                    _buildSpecialButton('HOME'),
                    _buildSpecialButton('PAGEUP', icon: Icons.arrow_upward_sharp),
                    _buildSpecialButton('PAGEDOWN', icon: Icons.arrow_downward_sharp),
                    _buildSpecialButton('END'),
                  ],
                ),
                Row(
                  children: [
                    _buildSpecialButton('SPACE', flex: 2, icon: Icons.space_bar),
                    _buildSpecialButton('ENTER', flex: 1, icon: Icons.keyboard_return),
                    Expanded(
                      flex: 2,
                      child: Container(
                        height: 64,
                        margin: const EdgeInsets.only(left: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.03),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildArrowButton('LEFT', Icons.arrow_left),
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _buildArrowButton('UP', Icons.arrow_drop_up),
                                _buildArrowButton('DOWN', Icons.arrow_drop_down),
                              ],
                            ),
                            _buildArrowButton('RIGHT', Icons.arrow_right),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Метод выбора и открытия файла из памяти телефона
  Future<void> _openScriptFile() async {
    try {
      final FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'ducky'],
      );

      if (result != null && result.files.single.path != null) {
        final File file = File(result.files.single.path!);
        final String content = await file.readAsString();
        setState(() {
          _macroController.text = content;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Loaded "${result.files.single.name}" successfully!'),
              backgroundColor: const Color(0xFF10B981),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error picking file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load file: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // Текстовый эмулятор Ducky Macro Studio
  Widget _buildDuckyMacroStudio() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Пресеты
        Row(
          children: [
            ActionChip(
              avatar: const Icon(Icons.folder_open, color: Color(0xFF6366F1), size: 14),
              label: const Text('Open TXT', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
              backgroundColor: const Color(0xFF6366F1).withValues(alpha: 0.12),
              side: BorderSide(color: const Color(0xFF6366F1).withValues(alpha: 0.3), width: 1),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              onPressed: _openScriptFile,
            ),
            const SizedBox(width: 10),
            const Icon(Icons.flash_on, color: Color(0xFF10B981), size: 16),
            const SizedBox(width: 6),
            const Text(
              'Presets:',
              style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _presets.keys.map((name) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        label: Text(name),
                        backgroundColor: Colors.white.withValues(alpha: 0.04),
                        labelStyle: const TextStyle(color: Colors.white, fontSize: 10),
                        padding: const EdgeInsets.all(4),
                        onPressed: () {
                          setState(() {
                            _macroController.text = _presets[name]!;
                          });
                        },
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Текстовый редактор
        Expanded(
          flex: 3,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: TextField(
              controller: _macroController,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(
                color: Color(0xFFF3F4F6),
                fontFamily: 'monospace',
                fontSize: 12,
              ),
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.all(12),
                border: InputBorder.none,
                hintText: 'Enter DuckyScript / Macro script here...',
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),

        // Панель управления и статус
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: _isRunningMacro ? const Color(0xFF6366F1) : const Color(0xFF10B981),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Status: $_macroStatus',
                      style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(_isRunningMacro ? Icons.stop : Icons.play_arrow),
              onPressed: () {
                if (_isRunningMacro) {
                  setState(() => _isRunningMacro = false);
                } else {
                  _runDuckyScript(_macroController.text);
                }
              },
              style: IconButton.styleFrom(
                backgroundColor: _isRunningMacro ? Colors.redAccent : const Color(0xFF6366F1),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Логи
        const Text(
          'EXECUTION LOGS',
          style: TextStyle(color: Colors.white30, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1),
        ),
        const SizedBox(height: 4),
        Expanded(
          flex: 2,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.04)),
            ),
            child: _macroLogs.isEmpty
                ? const Center(
                    child: Text('No logs yet. Run macro to see activity.',
                        style: TextStyle(color: Colors.white24, fontSize: 11)),
                  )
                : ListView.builder(
                    itemCount: _macroLogs.length,
                    itemBuilder: (context, index) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          _macroLogs[index],
                          style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 10),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  // Графический конструктор Visual Builder
  Widget _buildVisualBuilder() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Шапка конструктора с именем и кнопками Сохранить/Загрузить
        Row(
          children: [
            Expanded(
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: TextField(
                  controller: _macroNameController,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  decoration: const InputDecoration(
                    hintText: 'Macro Name',
                    hintStyle: TextStyle(color: Colors.white24),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.save, size: 18),
              tooltip: 'Save Macro',
              onPressed: _saveMacro,
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.folder_open, size: 18),
              tooltip: 'Load Saved Macros',
              onPressed: _showMacrosDirectory,
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Список шагов
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: _builderSteps.isEmpty
                ? const Center(
                    child: Text('No steps added yet.\nUse the buttons below to build your macro.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white30, fontSize: 12, height: 1.5)),
                  )
                : ListView.builder(
                    itemCount: _builderSteps.length,
                    padding: const EdgeInsets.all(8),
                    itemBuilder: (context, index) {
                      return _buildBuilderStepRow(index);
                    },
                  ),
          ),
        ),
        const SizedBox(height: 8),

        // Кнопки добавления шагов
        Row(
          children: [
            _buildAddStepButton('Delay', Colors.amber, () {
              setState(() {
                _builderSteps.add(MacroStep(type: 'delay', delayMs: 100));
              });
            }),
            const SizedBox(width: 6),
            _buildAddStepButton('Text', Colors.green, () {
              setState(() {
                _builderSteps.add(MacroStep(type: 'text', text: ''));
              });
            }),
            const SizedBox(width: 6),
            _buildAddStepButton('Combo', Colors.indigo, () {
              setState(() {
                _builderSteps.add(MacroStep(type: 'combo', key: 'ENTER'));
              });
            }),
          ],
        ),
        const SizedBox(height: 8),

        // Кнопка экспорта и запуска
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('RUN IN STUDIO'),
                onPressed: () {
                  final String script = _builderSteps.map((s) => s.toDuckyScript()).join('\n');
                  setState(() {
                    _macroController.text = script;
                    _activeSubTab = 1;
                  });
                  _runDuckyScript(script);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.code, size: 18),
                label: const Text('EXPORT CODE'),
                onPressed: () {
                  final String script = _builderSteps.map((s) => s.toDuckyScript()).join('\n');
                  setState(() {
                    _macroController.text = script;
                    _activeSubTab = 1;
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Macro exported to Ducky Studio editor tab!'),
                      backgroundColor: Color(0xFF6366F1),
                    ),
                  );
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // Виджет кнопки добавления шага
  Widget _buildAddStepButton(String label, Color color, VoidCallback onTap) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Строка с шагом макроса в конструкторе
  Widget _buildBuilderStepRow(int index) {
    final MacroStep step = _builderSteps[index];

    IconData icon;
    Color color;
    Widget editor;

    if (step.type == 'delay') {
      icon = Icons.timer_outlined;
      color = Colors.amber;
      editor = Row(
        children: [
          const Text('Delay: ', style: TextStyle(color: Colors.white60, fontSize: 11)),
          Container(
            width: 55,
            height: 24,
            margin: const EdgeInsets.only(left: 4),
            child: TextField(
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white, fontSize: 11),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                isDense: true,
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.15))),
                focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.amber)),
              ),
              controller: TextEditingController(text: step.delayMs.toString())
                ..selection = TextSelection.fromPosition(TextPosition(offset: step.delayMs.toString().length)),
              onChanged: (val) {
                step.delayMs = int.tryParse(val) ?? 0;
              },
            ),
          ),
          const SizedBox(width: 4),
          const Text('ms', style: TextStyle(color: Colors.white60, fontSize: 11)),
        ],
      );
    } else if (step.type == 'text') {
      icon = Icons.text_fields_outlined;
      color = Colors.green;
      editor = Row(
        children: [
          const Text('Type: ', style: TextStyle(color: Colors.white60, fontSize: 11)),
          Expanded(
            child: Container(
              height: 24,
              margin: const EdgeInsets.only(left: 4),
              child: TextField(
                style: const TextStyle(color: Colors.white, fontSize: 11),
                decoration: InputDecoration(
                  hintText: 'Enter text...',
                  hintStyle: const TextStyle(color: Colors.white24, fontSize: 11),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                  isDense: true,
                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.15))),
                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Colors.green)),
                ),
                controller: TextEditingController(text: step.text)
                  ..selection = TextSelection.fromPosition(TextPosition(offset: step.text.length)),
                onChanged: (val) {
                  step.text = val;
                },
              ),
            ),
          ),
        ],
      );
    } else {
      icon = Icons.keyboard_outlined;
      color = Colors.indigo;
      editor = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Key: ', style: TextStyle(color: Colors.white60, fontSize: 11)),
              Container(
                height: 22,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: DropdownButton<String>(
                  value: _availableKeys.contains(step.key) ? step.key : 'ENTER',
                  dropdownColor: const Color(0xFF1E1E2E),
                  underline: Container(),
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  icon: const Icon(Icons.arrow_drop_down, color: Colors.white30, size: 14),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        step.key = val;
                      });
                    }
                  },
                  items: _availableKeys.map<DropdownMenuItem<String>>((String value) {
                    return DropdownMenuItem<String>(
                      value: value,
                      child: Text(value),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              _buildStepModifierChip(step, 'CTRL', step.ctrl, (val) => setState(() => step.ctrl = val)),
              const SizedBox(width: 3),
              _buildStepModifierChip(step, 'SHIFT', step.shift, (val) => setState(() => step.shift = val)),
              const SizedBox(width: 3),
              _buildStepModifierChip(step, 'ALT', step.alt, (val) => setState(() => step.alt = val)),
              const SizedBox(width: 3),
              _buildStepModifierChip(step, 'WIN', step.gui, (val) => setState(() => step.gui = val)),
            ],
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Маленькая цветная марка
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 14),
          ),
          const SizedBox(width: 8),

          // Редактор
          Expanded(child: editor),

          const SizedBox(width: 6),

          // Перемещение и удаление
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 13),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                color: Colors.white38,
                onPressed: index > 0 ? () => _moveStep(index, -1) : null,
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.arrow_downward, size: 13),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                color: Colors.white38,
                onPressed: index < _builderSteps.length - 1 ? () => _moveStep(index, 1) : null,
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 15, color: Colors.redAccent),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  setState(() {
                    _builderSteps.removeAt(index);
                  });
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Модификатор-чип в визуальном шаге
  Widget _buildStepModifierChip(MacroStep step, String label, bool active, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () => onChanged(!active),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF6366F1) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: active ? const Color(0xFF818CF8) : Colors.white.withValues(alpha: 0.08)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? Colors.white : Colors.white38,
            fontSize: 8,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  // BottomSheet директория сохраненных макросов
  void _showMacrosDirectory() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Saved Macros',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  _savedMacros.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Text(
                            'No saved macros found.\nCreate one in the builder and tap Save.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.5),
                          ),
                        )
                      : Flexible(
                          child: ListView.builder(
                            itemCount: _savedMacros.length,
                            shrinkWrap: true,
                            itemBuilder: (context, index) {
                              final SavedMacro macro = _savedMacros[index];
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.03),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.settings_suggest, color: Color(0xFF6366F1), size: 20),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            macro.name,
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${macro.steps.length} steps',
                                            style: const TextStyle(color: Colors.white38, fontSize: 10),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.folder_open, color: Color(0xFF10B981), size: 18),
                                      onPressed: () => _loadMacroIntoBuilder(macro),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                      onPressed: () {
                                        _deleteMacro(macro.name);
                                        setModalState(() {});
                                      },
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // Кнопка модификатора клавиатуры
  Widget _buildModifierButton(String label, bool isPressed, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () {
        onChanged(!isPressed);
        widget.hidService.sendKeyboard(
          modifiers: _getModifiers(forceShift: !isPressed && label == 'SHIFT'),
          keycodes: [],
        );
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 76,
        height: 40,
        decoration: BoxDecoration(
          color: isPressed ? const Color(0xFF6366F1) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isPressed ? const Color(0xFF818CF8) : Colors.white.withValues(alpha: 0.1),
            width: 1.5,
          ),
          boxShadow: isPressed
              ? [
                  BoxShadow(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.4),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  )
                ]
              : [],
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: isPressed ? Colors.white : Colors.white70,
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }

  // Кнопки специальные
  Widget _buildSpecialButton(String label, {int flex = 1, IconData? icon}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(3.0),
        child: InkWell(
          onTap: () => _pressSpecialKey(label),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Center(
              child: icon != null
                  ? Icon(icon, color: Colors.white, size: 18)
                  : Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 11,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  // Кнопки стрелок
  Widget _buildArrowButton(String direction, IconData icon) {
    return InkWell(
      onTap: () => _pressSpecialKey(direction),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.all(2.0),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}

// Вспомогательные классы для макросов
class KeyStroke {
  final int code;
  final bool shift;
  KeyStroke(this.code, this.shift);
}

class SavedMacro {
  final String name;
  final List<MacroStep> steps;

  SavedMacro({required this.name, required this.steps});

  Map<String, dynamic> toJson() => {
        'name': name,
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  factory SavedMacro.fromJson(Map<String, dynamic> json) {
    final List<dynamic> stepsList = json['steps'] as List? ?? [];
    return SavedMacro(
      name: json['name'] ?? 'Unnamed Macro',
      steps: stepsList.map((s) => MacroStep.fromJson(s)).toList(),
    );
  }
}

class MacroStep {
  String type; // 'delay', 'text', 'combo'
  int delayMs;
  String text;
  String key; // 'ENTER', 'ESCAPE', etc.
  bool ctrl;
  bool shift;
  bool alt;
  bool gui;

  MacroStep({
    required this.type,
    this.delayMs = 100,
    this.text = '',
    this.key = 'ENTER',
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
    this.gui = false,
  });

  Map<String, dynamic> toJson() => {
        'type': type,
        'delayMs': delayMs,
        'text': text,
        'key': key,
        'ctrl': ctrl,
        'shift': shift,
        'alt': alt,
        'gui': gui,
      };

  factory MacroStep.fromJson(Map<String, dynamic> json) {
    return MacroStep(
      type: json['type'] ?? 'delay',
      delayMs: json['delayMs'] ?? 100,
      text: json['text'] ?? '',
      key: json['key'] ?? 'ENTER',
      ctrl: json['ctrl'] ?? false,
      shift: json['shift'] ?? false,
      alt: json['alt'] ?? false,
      gui: json['gui'] ?? false,
    );
  }

  String toDuckyScript() {
    if (type == 'delay') {
      return 'DELAY $delayMs';
    } else if (type == 'text') {
      return 'STRING $text';
    } else if (type == 'combo') {
      final List<String> mods = [];
      if (ctrl) mods.add('CTRL');
      if (shift) mods.add('SHIFT');
      if (alt) mods.add('ALT');
      if (gui) mods.add('GUI');

      if (mods.isEmpty) {
        return key;
      } else {
        return '${mods.join(' ')} ${key.toLowerCase()}';
      }
    }
    return '';
  }
}
