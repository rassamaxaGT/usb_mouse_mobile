import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../services/hid_service.dart';

class TouchpadWidget extends StatefulWidget {
  final HidService hidService;

  const TouchpadWidget({super.key, required this.hidService});

  @override
  State<TouchpadWidget> createState() => _TouchpadWidgetState();
}

class _TouchpadWidgetState extends State<TouchpadWidget> with SingleTickerProviderStateMixin {
  double sensitivity = 1.8;
  bool isLeftPressed = false;
  bool isRightPressed = false;

  // Отслеживание пальцев
  final Map<int, Offset> _pointerPositions = {};
  final Map<int, DateTime> _pointerDownTimes = {};
  final Map<int, Duration> _lastEventTimes = {};

  // Краевые зоны исключения и Palm Rejection
  final GlobalKey _touchpadKey = GlobalKey();
  final Map<int, bool> _blockedPointers = {};
  final Map<int, Offset> _pointerStartLocalPositions = {};

  // Временной ресемплинг для компенсации джиттера
  double _averageDt = 0.008;

  // One Euro Filter для каждого активного прикосновения
  final Map<int, OneEuroFilter> _pointerFilters = {};

  // Кольцевой буфер скоростей для расчета инерции при отрыве пальца
  final List<_VelocityPoint> _velocityBuffer = [];

  // Кинетическая инерция (Momentum)
  late final Ticker _inertialTicker;
  Offset _inertialVelocity = Offset.zero;
  Offset _inertialScrollVelocity = Offset.zero;

  // Субпиксельное накопление дельт перемещения
  double _subpixelX = 0.0;
  double _subpixelY = 0.0;
  double _subpixelScrollX = 0.0;
  double _subpixelScrollY = 0.0;

  // Параметры алгоритмов фильтрации и сглаживания
  static const double _startTouchSlop = 6.0; // Порог гистерезиса при первом касании
  static const int _joinWindowMs = 110; // Окно слияния касаний мультитача

  // Состояния жестов
  int _maxPointersThisGesture = 0;
  bool _gestureHasMovement = false;
  bool _hasForceClickedThisGesture = false;
  Offset? _singleFingerStartPos;
  DateTime? _lastLeftClickTime;
  DateTime? _firstFingerDownTime; // Для Join Window

  // Режим перетаскивания (Drag & Drop)
  bool _isDragging = false;

  // Жесты тремя пальцами (Three-finger drag)
  bool _isThreeFingerDragging = false;
  Offset? _threeFingerLastCenter;

  // Жесты четырьмя пальцами (System Swipes)
  bool _hasFourFingerSwiped = false;
  Offset? _fourFingerStartCenter;

  // Скроллинг
  Offset? _lastTwoFingerCenter;
  Offset? _twoFingerStartCenter;
  _ScrollAxis _scrollAxis = _ScrollAxis.none;

  @override
  void initState() {
    super.initState();
    _inertialTicker = createTicker(_handleInertialTick);
  }

  @override
  void dispose() {
    _inertialTicker.dispose();
    super.dispose();
  }

  // Клик левой кнопкой
  void _leftClick() async {
    HapticFeedback.lightImpact(); // Имитируем физический клик (Taptic Engine)
    setState(() => isLeftPressed = true);
    await widget.hidService.sendMouse(buttons: 1, dx: 0, dy: 0);
    await Future.delayed(const Duration(milliseconds: 60));
    await widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
    if (mounted) setState(() => isLeftPressed = false);
  }

  // Клик правой кнопкой
  void _rightClick() async {
    HapticFeedback.lightImpact(); // Имитируем физический клик (Taptic Engine)
    setState(() => isRightPressed = true);
    await widget.hidService.sendMouse(buttons: 2, dx: 0, dy: 0);
    await Future.delayed(const Duration(milliseconds: 60));
    await widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
    if (mounted) setState(() => isRightPressed = false);
  }

  // Клик средней кнопкой (колесо)
  void _middleClick() async {
    HapticFeedback.lightImpact(); // Имитируем физический клик (Taptic Engine)
    await widget.hidService.sendMouse(buttons: 4, dx: 0, dy: 0);
    await Future.delayed(const Duration(milliseconds: 60));
    await widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
  }

  // Сильный клик (Force Click)
  void _triggerForceClick() async {
    HapticFeedback.heavyImpact(); // Глубокий тактильный щелчок (Force Click)
    // Эмулируем клик колесиком мыши (средней кнопкой)
    await widget.hidService.sendMouse(buttons: 4, dx: 0, dy: 0);
    await Future.delayed(const Duration(milliseconds: 60));
    await widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
  }

  // Детектирование силы нажатия (Force Touch)
  void _detectForceClick(PointerEvent event) {
    if (_hasForceClickedThisGesture) return;

    final double pressure = event.pressure;
    final double size = event.size;

    bool isForce = false;

    if (pressure > 0.1 && pressure != 1.0 && pressure > 0.75) {
      isForce = true;
    } else if (size > 0.18) {
      isForce = true;
    }

    if (isForce) {
      _hasForceClickedThisGesture = true;
      _triggerForceClick();
    }
  }

  // Отправка клавиатурных сочетаний
  Future<void> _sendKeyCombo(int modifiers, List<int> keycodes) async {
    await widget.hidService.sendKeyboard(modifiers: modifiers, keycodes: keycodes);
    await Future.delayed(const Duration(milliseconds: 20));
    await widget.hidService.sendKeyboard(modifiers: 0, keycodes: const []);
  }

  // Сброс инерции при новом касании
  void _stopInertia() {
    _inertialVelocity = Offset.zero;
    _inertialScrollVelocity = Offset.zero;
    if (_inertialTicker.isTicking) {
      _inertialTicker.stop();
    }
    _velocityBuffer.clear();
  }

  // Инициализация инерции при отрыве пальца
  void _startInertia() {
    if (_velocityBuffer.length < 2) return;

    final now = DateTime.now();
    // Фильтруем точки за последние 120 мс
    final recentPoints = _velocityBuffer
        .where((p) => now.difference(p.time).inMilliseconds < 120)
        .toList();

    if (recentPoints.length < 2) return;

    final first = recentPoints.first;
    final last = recentPoints.last;
    final double durationSec = last.time.difference(first.time).inMicroseconds / 1000000.0;

    if (durationSec <= 0.0) return;

    final Offset totalDelta = last.position - first.position;
    final Offset avgVelocity = totalDelta * (1.0 / durationSec); // пикселей в секунду

    if (_maxPointersThisGesture == 1 && _gestureHasMovement && !_isDragging) {
      // Инерция движения курсора (активируется при быстрых свайпах)
      if (avgVelocity.distance > 180.0) {
        _inertialVelocity = avgVelocity;
        _inertialTicker.start();
      }
    } else if (_maxPointersThisGesture == 2) {
      // Инерция скроллинга двумя пальцами по одной заблокированной оси
      double vx = avgVelocity.dx * 0.09; // уменьшено пропорционально новой базовой чувствительности скролла
      double vy = -avgVelocity.dy * 0.09;

      if (_scrollAxis == _ScrollAxis.vertical) {
        vx = 0.0;
      } else if (_scrollAxis == _ScrollAxis.horizontal) {
        vy = 0.0;
      }

      final Offset scrollVel = Offset(vx, vy);
      if (scrollVel.distance > 15.0) { // снижен порог запуска инерции для плавного подхвата
        _inertialScrollVelocity = scrollVel;
        _inertialTicker.start();
      }
    }
  }

  // Обработка тиков инерционной анимации
  void _handleInertialTick(Duration elapsed) {
    const double dt = 0.016; // Шаг кадра 60Hz
    bool active = false;

    if (_inertialVelocity != Offset.zero) {
      // Экспоненциальное затухание скорости курсора (вязкое трение)
      _inertialVelocity = _inertialVelocity * 0.91;
      if (_inertialVelocity.distance < 15.0) {
        _inertialVelocity = Offset.zero;
      } else {
        final Offset delta = _inertialVelocity * dt;
        _sendMouseDelta(delta);
        active = true;
      }
    }

    if (_inertialScrollVelocity != Offset.zero) {
      // Экспоненциальное затухание скорости скроллинга по двум осям
      _inertialScrollVelocity = _inertialScrollVelocity * 0.93;
      if (_inertialScrollVelocity.distance < 5.0) {
        _inertialScrollVelocity = Offset.zero;
      } else {
        final double scrollValX = (_inertialScrollVelocity.dx * dt).clamp(-127.0, 127.0);
        final double scrollValY = (_inertialScrollVelocity.dy * dt).clamp(-127.0, 127.0);
        
        _subpixelScrollX += scrollValX;
        _subpixelScrollY += scrollValY;

        final int roundedScrollX = _subpixelScrollX.truncate();
        final int roundedScrollY = _subpixelScrollY.truncate();

        _subpixelScrollX -= roundedScrollX;
        _subpixelScrollY -= roundedScrollY;

        if (roundedScrollX != 0 || roundedScrollY != 0) {
          widget.hidService.sendMouse(
            buttons: 0,
            dx: 0,
            dy: 0,
            wheel: roundedScrollY,
            hWheel: roundedScrollX,
          );
        }
        active = true;
      }
    }

    if (!active) {
      _inertialTicker.stop();
    }
  }

  // Безопасная отправка дельты мыши с субпиксельным накоплением
  void _sendMouseDelta(Offset delta) {
    _subpixelX += delta.dx;
    _subpixelY += delta.dy;

    int sendX = _subpixelX.round();
    int sendY = _subpixelY.round();

    _subpixelX -= sendX;
    _subpixelY -= sendY;

    if (sendX != 0 || sendY != 0) {
      int buttons = _isDragging ? 1 : 0;
      if (isLeftPressed) buttons |= 1;
      if (isRightPressed) buttons |= 2;
      widget.hidService.sendMouse(buttons: buttons, dx: sendX, dy: sendY);
    }
  }

  void _handlePointerDown(PointerEvent event) {
    _stopInertia();

    _pointerPositions[event.pointer] = event.position;
    _pointerDownTimes[event.pointer] = DateTime.now();
    _lastEventTimes[event.pointer] = event.timeStamp;
    
    // Инициализируем One Euro Filter для нового касания
    _pointerFilters[event.pointer] = OneEuroFilter(
      minCutoff: 0.35, // максимальное сглаживание в покое
      beta: 0.04,      // рост чувствительности при ускорении
      dCutoff: 1.0,    // фильтрация скорости изменения
    );

    // Детектирование краевой зоны (Edge Exclusion Zones)
    final RenderBox? renderBox = _touchpadKey.currentContext?.findRenderObject() as RenderBox?;
    bool isBlocked = false;
    if (renderBox != null) {
      final Size size = renderBox.size;
      final Offset localPos = renderBox.globalToLocal(event.position);
      _pointerStartLocalPositions[event.pointer] = localPos;
      if (localPos.dx < size.width * 0.05 ||
          localPos.dx > size.width * 0.95 ||
          localPos.dy < size.height * 0.08) {
        isBlocked = true;
      }
    }
    _blockedPointers[event.pointer] = isBlocked;

    final activeCount = _pointerPositions.keys.where((id) => _blockedPointers[id] != true).length;

    if (activeCount > _maxPointersThisGesture) {
      _maxPointersThisGesture = activeCount;
    }

    if (activeCount == 1 && !_blockedPointers.values.contains(true)) {
      _singleFingerStartPos = event.position;
      _gestureHasMovement = false;
      _hasForceClickedThisGesture = false;
      _firstFingerDownTime = DateTime.now();
      _subpixelX = 0.0;
      _subpixelY = 0.0;
      _subpixelScrollX = 0.0;
      _subpixelScrollY = 0.0;

      // Проверка на двойной тап с удержанием (Drag & Drop)
      final now = DateTime.now();
      if (_lastLeftClickTime != null &&
          now.difference(_lastLeftClickTime!).inMilliseconds < 250) {
        _isDragging = true;
        widget.hidService.sendMouse(buttons: 1, dx: 0, dy: 0);
      }
    } else if (activeCount == 2) {
      if (_isDragging) {
        _isDragging = false;
        widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
      }
      _scrollAxis = _ScrollAxis.none;
      final List<int> keys = _pointerPositions.keys.where((id) => _blockedPointers[id] != true).toList();
      if (keys.length >= 2) {
        final Offset fPos1 = _pointerFilters[keys[0]]?.previousFilteredValue ?? _pointerPositions[keys[0]]!;
        final Offset fPos2 = _pointerFilters[keys[1]]?.previousFilteredValue ?? _pointerPositions[keys[1]]!;
        _lastTwoFingerCenter = (fPos1 + fPos2) / 2;
      } else {
        final values = _pointerPositions.values.toList();
        _lastTwoFingerCenter = (values[0] + values[1]) / 2;
      }
      _twoFingerStartCenter = _lastTwoFingerCenter;
    } else if (activeCount == 3) {
      if (_isDragging) {
        _isDragging = false;
        widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
      }
      final List<int> keys = _pointerPositions.keys.where((id) => _blockedPointers[id] != true).toList();
      Offset center = Offset.zero;
      if (keys.length >= 3) {
        final Offset fPos1 = _pointerFilters[keys[0]]?.previousFilteredValue ?? _pointerPositions[keys[0]]!;
        final Offset fPos2 = _pointerFilters[keys[1]]?.previousFilteredValue ?? _pointerPositions[keys[1]]!;
        final Offset fPos3 = _pointerFilters[keys[2]]?.previousFilteredValue ?? _pointerPositions[keys[2]]!;
        center = (fPos1 + fPos2 + fPos3) / 3;
      } else {
        final values = _pointerPositions.values.toList();
        center = values.reduce((a, b) => a + b) / values.length.toDouble();
      }
      _threeFingerLastCenter = center;
      _isThreeFingerDragging = true;
      _gestureHasMovement = true;
      // Сразу зажимаем левую кнопку мыши для перетаскивания (Three-finger drag)
      widget.hidService.sendMouse(buttons: 1, dx: 0, dy: 0);
      HapticFeedback.lightImpact();
    } else if (activeCount == 4) {
      if (_isThreeFingerDragging) {
        _isThreeFingerDragging = false;
        widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
      }
      final List<int> keys = _pointerPositions.keys.where((id) => _blockedPointers[id] != true).toList();
      Offset center = Offset.zero;
      if (keys.length >= 4) {
        final Offset fPos1 = _pointerFilters[keys[0]]?.previousFilteredValue ?? _pointerPositions[keys[0]]!;
        final Offset fPos2 = _pointerFilters[keys[1]]?.previousFilteredValue ?? _pointerPositions[keys[1]]!;
        final Offset fPos3 = _pointerFilters[keys[2]]?.previousFilteredValue ?? _pointerPositions[keys[2]]!;
        final Offset fPos4 = _pointerFilters[keys[3]]?.previousFilteredValue ?? _pointerPositions[keys[3]]!;
        center = (fPos1 + fPos2 + fPos3 + fPos4) / 4;
      } else {
        final values = _pointerPositions.values.toList();
        center = values.reduce((a, b) => a + b) / values.length.toDouble();
      }
      _fourFingerStartCenter = center;
      _hasFourFingerSwiped = false;
      _gestureHasMovement = true;
    }
  }

  void _handlePointerMove(PointerEvent event) {
    if (!_pointerPositions.containsKey(event.pointer)) return;

    _detectForceClick(event);
    _pointerPositions[event.pointer] = event.position;

    // Вычисляем dt
    final Duration lastTime = _lastEventTimes[event.pointer] ?? event.timeStamp;
    _lastEventTimes[event.pointer] = event.timeStamp;
    double dt = (event.timeStamp - lastTime).inMicroseconds / 1000000.0;
    if (dt <= 0.0) dt = 0.008; // 120Hz fallback

    // Edge Exclusion Zones (Palm Rejection)
    if (_blockedPointers[event.pointer] == true) {
      // Сценарий B: Быстрый жест ввода в центр
      final RenderBox? renderBox = _touchpadKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox != null) {
        final Size size = renderBox.size;
        final Offset localPos = renderBox.globalToLocal(event.position);
        final Offset startPos = _pointerStartLocalPositions[event.pointer] ?? localPos;
        final Offset delta = localPos - startPos;
        final int elapsedMs = DateTime.now().difference(_pointerDownTimes[event.pointer]!).inMilliseconds;
        
        if (elapsedMs < 250) {
          bool unlock = false;
          if (startPos.dx < size.width * 0.05 && delta.dx > 15.0) {
            unlock = true;
          } else if (startPos.dx > size.width * 0.95 && delta.dx < -15.0) {
            unlock = true;
          } else if (startPos.dy < size.height * 0.08 && delta.dy > 15.0) {
            unlock = true;
          }
          if (unlock) {
            _blockedPointers[event.pointer] = false;
          }
        }
      }
    }

    // Если палец заблокирован - полностью игнорируем его перемещения
    if (_blockedPointers[event.pointer] == true) {
      return;
    }

    // 1. Применяем One Euro Filter к абсолютной координате
    final filter = _pointerFilters[event.pointer]!;
    final Offset filteredOldPos = filter.previousFilteredValue ?? event.position;
    final Offset filteredPos = filter.filter(event.position, event.timeStamp);
    final Offset filteredDelta = filteredPos - filteredOldPos;

    // Двухфазный гистерезис: проверяем превышение стартового порога
    if (_singleFingerStartPos != null && !_gestureHasMovement) {
      final double dist = (event.position - _singleFingerStartPos!).distance;
      if (dist > _startTouchSlop) {
        _gestureHasMovement = true;
      }
    }

    final activePointers = _pointerPositions.keys.where((id) => _blockedPointers[id] != true).toList();

    // Временной ресемплинг дельт для компенсации джиттера
    _averageDt = 0.9 * _averageDt + 0.1 * dt;
    final double timeCorrection = (_averageDt / dt).clamp(0.5, 2.0);
    final Offset resampledDelta = filteredDelta * timeCorrection;

    if (activePointers.length == 1) {
      // Сохраняем отфильтрованную точку движения в буфер скоростей для 1 пальца
      _velocityBuffer.add(_VelocityPoint(filteredPos, DateTime.now()));
      if (_velocityBuffer.length > 5) {
        _velocityBuffer.removeAt(0);
      }

      // 2. Окно слияния касаний мультитача (Join Window)
      if (_firstFingerDownTime != null) {
        final int elapsedMs = DateTime.now().difference(_firstFingerDownTime!).inMilliseconds;
        if (elapsedMs < _joinWindowMs) {
          return;
        }
      }

      if (_gestureHasMovement) {
        // Вычисляем физический DPI экрана для Apple баллистики
        final double devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
        final double dpi = devicePixelRatio * 160.0;

        // 3. Вычисление непрерывной кубической баллистики Apple
        final Offset acceleratedDelta = _calculateAppleBallistics(resampledDelta, dt, dpi);
        _sendMouseDelta(acceleratedDelta);
      }
    } else if (activePointers.length == 2) {
      // Скроллинг двумя пальцами на основе отфильтрованных координат обоих пальцев
      final List<int> keys = activePointers;
      final Offset fPos1 = keys[0] == event.pointer 
          ? filteredPos 
          : (_pointerFilters[keys[0]]?.previousFilteredValue ?? _pointerPositions[keys[0]]!);
      final Offset fPos2 = keys[1] == event.pointer 
          ? filteredPos 
          : (_pointerFilters[keys[1]]?.previousFilteredValue ?? _pointerPositions[keys[1]]!);
      
      final Offset currentCenter = (fPos1 + fPos2) / 2;

      // Сохраняем отфильтрованный центр в буфер скоростей для 2 пальцев
      _velocityBuffer.add(_VelocityPoint(currentCenter, DateTime.now()));
      if (_velocityBuffer.length > 5) {
        _velocityBuffer.removeAt(0);
      }

      if (_lastTwoFingerCenter != null) {
        final Offset centerDelta = (currentCenter - _lastTwoFingerCenter!) * timeCorrection;
        
        // Определяем ось скролла по накопленному сдвигу с момента прикосновения (Scroll Slop)
        if (_scrollAxis == _ScrollAxis.none && _twoFingerStartCenter != null) {
          final Offset totalOffset = currentCenter - _twoFingerStartCenter!;
          if (totalOffset.distance > 1.8) {
            _gestureHasMovement = true; // Указываем, что жест имеет движение
            if (totalOffset.dy.abs() > totalOffset.dx.abs()) {
              _scrollAxis = _ScrollAxis.vertical;
            } else {
              _scrollAxis = _ScrollAxis.horizontal;
            }
          }
        }

        double scrollY = 0.0;
        double scrollX = 0.0;

        if (_scrollAxis != _ScrollAxis.none) {
          // Вычисляем скорость перемещения центра для динамической баллистики скролла
          final double scrollSpeed = centerDelta.distance / dt;
          double scrollGain = 0.035 + (scrollSpeed * 0.00008);
          scrollGain = scrollGain.clamp(0.035, 0.28);

          if (_scrollAxis == _ScrollAxis.vertical) {
            scrollY = -centerDelta.dy * scrollGain;
          } else if (_scrollAxis == _ScrollAxis.horizontal) {
            scrollX = centerDelta.dx * scrollGain;
          }
        }
        
        _subpixelScrollY += scrollY;
        _subpixelScrollX += scrollX;

        final int scrollValY = _subpixelScrollY.truncate();
        final int scrollValX = _subpixelScrollX.truncate();

        _subpixelScrollY -= scrollValY;
        _subpixelScrollX -= scrollValX;

        if (scrollValY != 0 || scrollValX != 0) {
          widget.hidService.sendMouse(
            buttons: 0, 
            dx: 0, 
            dy: 0, 
            wheel: scrollValY,
            hWheel: scrollValX,
          );
        }
      }
      _lastTwoFingerCenter = currentCenter;
    } else if (activePointers.length == 3) {
      // Three-finger drag: перемещение курсора с зажатой левой кнопкой
      final List<int> keys = activePointers;
      final Offset fPos1 = keys[0] == event.pointer 
          ? filteredPos 
          : (_pointerFilters[keys[0]]?.previousFilteredValue ?? _pointerPositions[keys[0]]!);
      final Offset fPos2 = keys[1] == event.pointer 
          ? filteredPos 
          : (_pointerFilters[keys[1]]?.previousFilteredValue ?? _pointerPositions[keys[1]]!);
      final Offset fPos3 = keys[2] == event.pointer 
          ? filteredPos 
          : (_pointerFilters[keys[2]]?.previousFilteredValue ?? _pointerPositions[keys[2]]!);
      
      final Offset currentCenter = (fPos1 + fPos2 + fPos3) / 3;

      if (_threeFingerLastCenter != null) {
        final Offset centerDelta = (currentCenter - _threeFingerLastCenter!) * timeCorrection;
        
        // Перемещаем курсор с зажатой левой кнопкой мыши (buttons: 1)
        final double devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
        final double dpi = devicePixelRatio * 160.0;
        final Offset acceleratedDelta = _calculateAppleBallistics(centerDelta, dt, dpi);

        _subpixelX += acceleratedDelta.dx;
        _subpixelY += acceleratedDelta.dy;

        int sendX = _subpixelX.round();
        int sendY = _subpixelY.round();

        _subpixelX -= sendX;
        _subpixelY -= sendY;

        if (sendX != 0 || sendY != 0) {
          widget.hidService.sendMouse(buttons: 1, dx: sendX, dy: sendY);
        }
      }
      _threeFingerLastCenter = currentCenter;
    } else if (activePointers.length == 4) {
      // Жесты четырьмя пальцами (Системные свайпы)
      final List<int> keys = activePointers;
      final Offset fPos1 = keys[0] == event.pointer 
          ? filteredPos 
          : (_pointerFilters[keys[0]]?.previousFilteredValue ?? _pointerPositions[keys[0]]!);
      final Offset fPos2 = keys[1] == event.pointer 
          ? filteredPos 
          : (_pointerFilters[keys[1]]?.previousFilteredValue ?? _pointerPositions[keys[1]]!);
      final Offset fPos3 = keys[2] == event.pointer 
          ? filteredPos 
          : (_pointerFilters[keys[2]]?.previousFilteredValue ?? _pointerPositions[keys[2]]!);
      final Offset fPos4 = keys[3] == event.pointer 
          ? filteredPos 
          : (_pointerFilters[keys[3]]?.previousFilteredValue ?? _pointerPositions[keys[3]]!);
      
      final Offset currentCenter = (fPos1 + fPos2 + fPos3 + fPos4) / 4;

      if (_fourFingerStartCenter != null && !_hasFourFingerSwiped) {
        final Offset totalOffset = currentCenter - _fourFingerStartCenter!;
        if (totalOffset.distance > 40.0) {
          _hasFourFingerSwiped = true;
          HapticFeedback.mediumImpact(); // Тактильный щелчок перехода

          if (totalOffset.dy.abs() > totalOffset.dx.abs()) {
            if (totalOffset.dy < 0) {
              // Свайп вверх -> Mission Control / Task View (Win + Tab)
              _sendKeyCombo(0x08, const [43]);
            } else {
              // Свайп вниз -> Показать рабочий стол (Win + D)
              _sendKeyCombo(0x08, const [7]);
            }
          } else {
            if (totalOffset.dx < 0) {
              // Свайп влево -> Следующий рабочий стол (Ctrl + Win + Right)
              _sendKeyCombo(0x01 | 0x08, const [79]);
            } else {
              // Свайп вправо -> Предыдущий рабочий стол (Ctrl + Win + Left)
              _sendKeyCombo(0x01 | 0x08, const [80]);
            }
          }
        }
      }
    }
  }

  // Кубическая модель Apple CD-Gain
  Offset _calculateAppleBallistics(Offset filteredDelta, double dt, double dpi) {
    if (dt <= 0.0 || filteredDelta == Offset.zero) return filteredDelta;
    
    // 1. Длина вектора в миллиметрах экрана
    double deltaMm = filteredDelta.distance / dpi * 25.4;
    // 2. Скорость движения в мм/мс
    double velocityMmMs = deltaMm / (dt * 1000.0);

    // 3. Формула кубического ускорения Apple: Gain = C_low + C_mid * V + C_high * V^2
    const double cLow = 0.12;
    const double cMid = 0.015;
    const double cHigh = 0.006;
    
    double gain = (cLow + cMid * velocityMmMs + cHigh * math.pow(velocityMmMs, 2)) * sensitivity * 14.5;
    gain = gain.clamp(0.08, 8.0); // лимиты передачи

    return filteredDelta * gain;
  }

  void _handlePointerUp(PointerEvent event) {
    final DateTime downTime = _pointerDownTimes[event.pointer] ?? DateTime.now();
    final DateTime startTime = _firstFingerDownTime ?? downTime;
    final int durationMs = DateTime.now().difference(startTime).inMilliseconds;
    final bool wasBlocked = _blockedPointers[event.pointer] ?? false;

    _pointerPositions.remove(event.pointer);
    _pointerFilters.remove(event.pointer);
    _pointerDownTimes.remove(event.pointer);
    _lastEventTimes.remove(event.pointer);
    _blockedPointers.remove(event.pointer);
    _pointerStartLocalPositions.remove(event.pointer);

    final activeCountAfterRemove = _pointerPositions.keys.where((id) => _blockedPointers[id] != true).length;

    if (activeCountAfterRemove < 3 && _isThreeFingerDragging) {
      _isThreeFingerDragging = false;
      widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
      HapticFeedback.lightImpact();
    }

    if (activeCountAfterRemove == 0) {
      if (!wasBlocked) {
        _startInertia();
      }
      _firstFingerDownTime = null;
      if (_isDragging) {
        _isDragging = false;
        widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
      } else if (_isThreeFingerDragging) {
        _isThreeFingerDragging = false;
        widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
        HapticFeedback.lightImpact();
      } else {
        if (!wasBlocked && !_gestureHasMovement && durationMs < 300) {
          if (_maxPointersThisGesture == 1) {
            _leftClick();
            _lastLeftClickTime = DateTime.now();
          } else if (_maxPointersThisGesture == 2) {
            _rightClick();
          } else if (_maxPointersThisGesture == 3) {
            _middleClick();
          }
        }
      }
      _maxPointersThisGesture = 0;
      _lastTwoFingerCenter = null;
      _twoFingerStartCenter = null;
      _threeFingerLastCenter = null;
      _fourFingerStartCenter = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Тонкая панель настройки чувствительности
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          child: Row(
            children: [
              const Icon(Icons.tune, color: Colors.white60, size: 18),
              const SizedBox(width: 8),
              const Text(
                'Sensitivity',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: sensitivity,
                  min: 0.5,
                  max: 4.0,
                  activeColor: const Color(0xFF6366F1),
                  inactiveColor: Colors.white12,
                  onChanged: (value) {
                    setState(() {
                      sensitivity = value;
                    });
                  },
                ),
              ),
              Text(
                sensitivity.toStringAsFixed(1),
                style: const TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),

        // Сенсорная панель во всю доступную ширину и высоту
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Listener(
              key: _touchpadKey,
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerUp,
              onPointerCancel: _handlePointerUp,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _isDragging 
                        ? const Color(0xFF6366F1).withValues(alpha: 0.5) 
                        : Colors.white.withValues(alpha: 0.08),
                    width: _isDragging ? 2.0 : 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 12,
                      spreadRadius: -4,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    children: [
                      // Текстура сетки
                      Positioned.fill(
                        child: CustomPaint(
                          painter: GridPainter(),
                        ),
                      ),
                      // Индикатор перетаскивания (Drag & Drop)
                      if (_isDragging)
                        Positioned(
                          top: 12,
                          left: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF6366F1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.drag_indicator, size: 14, color: Colors.white),
                                SizedBox(width: 4),
                                Text(
                                  'DRAG LOCK ACTIVE',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.touch_app_outlined,
                              size: 44,
                              color: Colors.white.withValues(alpha: 0.12),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '1 Finger: Move Cursor  •  1 Tap: Left Click\n'
                              '2 Fingers Tap: Right Click  •  2 Fingers Drag: Scroll\n'
                              '3 Fingers Tap: Middle Click  •  Double Tap & Hold: Drag & Drop',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.35),
                                fontSize: 11,
                                height: 1.6,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),

        // Компактные кнопки мыши снизу
        Padding(
          padding: const EdgeInsets.only(left: 10, right: 10, bottom: 8, top: 4),
          child: Row(
            children: [
              // Левая кнопка мыши
              Expanded(
                child: GestureDetector(
                  onTapDown: (_) async {
                    setState(() => isLeftPressed = true);
                    await widget.hidService.sendMouse(buttons: 1, dx: 0, dy: 0);
                  },
                  onTapUp: (_) async {
                    setState(() => isLeftPressed = false);
                    await widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
                  },
                  onTapCancel: () async {
                    setState(() => isLeftPressed = false);
                    await widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 80),
                    height: 46,
                    decoration: BoxDecoration(
                      gradient: isLeftPressed
                          ? const LinearGradient(
                              colors: [Color(0xFF4F46E5), Color(0xFF4338CA)],
                            )
                          : LinearGradient(
                              colors: [
                                Colors.white.withValues(alpha: 0.06),
                                Colors.white.withValues(alpha: 0.03),
                              ],
                            ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isLeftPressed
                            ? const Color(0xFF818CF8)
                            : Colors.white.withValues(alpha: 0.08),
                        width: 1.2,
                      ),
                    ),
                    child: const Center(
                      child: Text(
                        'LEFT CLICK',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),

              // Правая кнопка мыши
              Expanded(
                child: GestureDetector(
                  onTapDown: (_) async {
                    setState(() => isRightPressed = true);
                    await widget.hidService.sendMouse(buttons: 2, dx: 0, dy: 0);
                  },
                  onTapUp: (_) async {
                    setState(() => isRightPressed = false);
                    await widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
                  },
                  onTapCancel: () async {
                    setState(() => isRightPressed = false);
                    await widget.hidService.sendMouse(buttons: 0, dx: 0, dy: 0);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 80),
                    height: 46,
                    decoration: BoxDecoration(
                      gradient: isRightPressed
                          ? const LinearGradient(
                              colors: [Color(0xFF4F46E5), Color(0xFF4338CA)],
                            )
                          : LinearGradient(
                              colors: [
                                Colors.white.withValues(alpha: 0.06),
                                Colors.white.withValues(alpha: 0.03),
                              ],
                            ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isRightPressed
                            ? const Color(0xFF818CF8)
                            : Colors.white.withValues(alpha: 0.08),
                        width: 1.2,
                      ),
                    ),
                    child: const Center(
                      child: Text(
                        'RIGHT CLICK',
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Вспомогательный класс для сохранения точек вектора скорости
class _VelocityPoint {
  final Offset position;
  final DateTime time;
  _VelocityPoint(this.position, this.time);
}

// Имплементация адаптивного One Euro Filter
class OneEuroFilter {
  final double minCutoff;
  final double beta;
  final double dCutoff;

  Offset? _xPrev;
  Offset _dxPrev = Offset.zero;
  Duration? _tPrev;

  OneEuroFilter({
    this.minCutoff = 0.35,
    this.beta = 0.04,
    this.dCutoff = 1.0,
  });

  Offset? get previousFilteredValue => _xPrev;

  Offset filter(Offset x, Duration t) {
    if (_tPrev == null || _xPrev == null) {
      _xPrev = x;
      _tPrev = t;
      return x;
    }

    double te = (t - _tPrev!).inMicroseconds / 1000000.0;
    if (te <= 0.0) te = 0.008; // 120Hz fallback

    // Вычисляем производную мгновенной скорости
    final Offset dx = (x - _xPrev!) * (1.0 / te);

    // Сглаживаем производную скорости
    final double alphaD = _calculateAlpha(te, dCutoff);
    final Offset dxFiltered = dx * alphaD + _dxPrev * (1.0 - alphaD);

    // Вычисляем динамическую частоту среза на основе скорости
    final double speed = dxFiltered.distance;
    final double cutoff = minCutoff + beta * speed;

    // Сглаживаем исходные координаты
    final double alpha = _calculateAlpha(te, cutoff);
    final Offset xFiltered = x * alpha + _xPrev! * (1.0 - alpha);

    _xPrev = xFiltered;
    _dxPrev = dxFiltered;
    _tPrev = t;

    return xFiltered;
  }

  double _calculateAlpha(double te, double cutoff) {
    final double tau = 1.0 / (2.0 * math.pi * cutoff);
    return 1.0 / (1.0 + tau / te);
  }
}

// Отрисовщик сетки тачпада
class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.015)
      ..strokeWidth = 1;

    const double step = 24.0;

    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

enum _ScrollAxis {
  none,
  vertical,
  horizontal,
}
