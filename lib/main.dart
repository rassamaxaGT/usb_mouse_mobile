import 'package:flutter/material.dart';
import 'services/hid_service.dart';
import 'widgets/touchpad.dart';
import 'widgets/keyboard_view.dart';

void main() {
  runApp(const UsbMouseApp());
}

class UsbMouseApp extends StatelessWidget {
  const UsbMouseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'USB HID Sim',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(
          0xFF0B0F19,
        ), // Глубокий темно-синий
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1), // Indigo
          secondary: Color(0xFF10B981), // Emerald green
          surface: Color(0xFF161F30), // Dark steel blue
        ),
        fontFamily: 'Roboto',
        useMaterial3: true,
      ),
      home: const MainControlScreen(),
    );
  }
}

class MainControlScreen extends StatefulWidget {
  const MainControlScreen({super.key});

  @override
  State<MainControlScreen> createState() => _MainControlScreenScreenState();
}

class _MainControlScreenScreenState extends State<MainControlScreen>
    with SingleTickerProviderStateMixin {
  final HidService _hidService = HidService();
  late TabController _tabController;

  bool hasRoot = false;
  bool isGadgetInitialized = false;
  bool isConnected = false;
  bool isProcessing = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _checkInitialStatus();
  }

  // Первоначальная проверка статусов
  Future<void> _checkInitialStatus() async {
    setState(() => isProcessing = true);
    bool root = await _hidService.checkRoot();
    setState(() {
      hasRoot = root;
      isProcessing = false;
    });
  }

  // Инициализация ConfigFS
  Future<void> _setupConfigFS() async {
    if (isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cannot reconfigure USB Gadget while connected. Disconnect first.',
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    if (isGadgetInitialized) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ConfigFS is already configured and active.'),
          backgroundColor: Colors.blueGrey,
        ),
      );
      return;
    }

    if (!hasRoot) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Root permissions are required to initialize ConfigFS.',
          ),
        ),
      );
      return;
    }

    setState(() => isProcessing = true);
    final Map<String, dynamic> res = await _hidService.initUsbGadget();
    final bool ok = res['success'] ?? false;
    final String stderr = res['stderr'] ?? '';

    setState(() {
      isGadgetInitialized = ok;
      isProcessing = false;
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'ConfigFS USB Gadget successfully configured!'
                : 'ConfigFS failed: ${stderr.isNotEmpty ? stderr : "Ensure your kernel supports HID gadget."}',
          ),
          backgroundColor: ok ? const Color(0xFF10B981) : Colors.redAccent,
        ),
      );
    }
  }

  // Подключение / Отключение к /dev/hidg*
  Future<void> _toggleConnection() async {
    setState(() => isProcessing = true);
    if (isConnected) {
      await _hidService.disconnect();
      setState(() {
        isConnected = false;
        isProcessing = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Disconnected from USB HID interfaces.'),
            backgroundColor: Colors.white24,
          ),
        );
      }
    } else {
      final Map<String, dynamic> res = await _hidService.connect();
      final bool ok = res['success'] ?? false;
      final String error = res['error'] ?? '';

      setState(() {
        isConnected = ok;
        isProcessing = false;
      });

      if (mounted) {
        if (!ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Connection failed: ${error.isNotEmpty ? error : "Make sure USB Gadget is initialized"}',
              ),
              backgroundColor: Colors.redAccent,
              duration: const Duration(seconds: 4),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Connected to USB HID interfaces successfully!'),
              backgroundColor: Color(0xFF10B981),
            ),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    if (isLandscape && isConnected) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF0F172A), // Slate 900
                Color(0xFF020617), // Slate 950
              ],
            ),
          ),
          child: SafeArea(
            child: TouchpadWidget(hidService: _hidService),
          ),
        ),
      );
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0F172A), // Slate 900
              Color(0xFF020617), // Slate 950
            ],
          ),
        ),
        child: SafeArea(
          child: isLandscape && !isConnected
              ? SingleChildScrollView(
                  child: Column(
                    children: [
                      _buildHeader(),
                      _buildStatusPanel(),
                      const SizedBox(height: 16),
                      _buildConnectionPrompt(),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Если не подключено — показываем большую шапку и панель
                    if (!isConnected) ...[
                      _buildHeader(),
                      _buildStatusPanel(),
                    ],

                    // Если подключено — показываем компактную строчку статуса
                    if (isConnected) _buildConnectedHeader(),

                    const SizedBox(height: 8),

                    // Кастомный переключатель вкладок
                    _buildTabBar(),

                    // Содержимое вкладок (Тачпад / Клавиатура)
                    Expanded(
                      child: isConnected
                          ? TabBarView(
                              controller: _tabController,
                              physics: const NeverScrollableScrollPhysics(), // Отключаем свайп для избежания конфликта с тачпадом
                              children: [
                                TouchpadWidget(hidService: _hidService),
                                KeyboardView(hidService: _hidService),
                              ],
                            )
                          : _buildConnectionPrompt(),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  // Компактный заголовок при активном подключении
  Widget _buildConnectedHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF10B981),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'CONNECTED',
                style: TextStyle(
                  color: Color(0xFF10B981),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          TextButton.icon(
            onPressed: isProcessing ? null : _toggleConnection,
            icon: const Icon(Icons.power_settings_new, size: 14, color: Colors.redAccent),
            label: const Text(
              'DISCONNECT',
              style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: Colors.red.withValues(alpha: 0.1),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  // Дизайн Шапки
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'USB HID SIMULATOR',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: hasRoot ? const Color(0xFF10B981) : Colors.red,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color:
                              (hasRoot ? const Color(0xFF10B981) : Colors.red)
                                  .withValues(alpha: 0.5),
                          blurRadius: 4,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    hasRoot ? 'Root Access Granted' : 'No Root Access',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
          IconButton(
            onPressed: isProcessing ? null : _checkInitialStatus,
            icon: isProcessing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white70,
                    ),
                  )
                : const Icon(Icons.refresh, color: Colors.white70, size: 18),
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.04),
              padding: const EdgeInsets.all(8),
              minimumSize: const Size(36, 36),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Панель статуса и инициализации
  Widget _buildStatusPanel() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06), width: 1),
      ),
      child: Row(
        children: [
          // Кнопка Setup ConfigFS
          Expanded(
            child: InkWell(
              onTap: isProcessing ? null : _setupConfigFS,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: isGadgetInitialized
                      ? const Color(0xFF10B981).withValues(alpha: 0.12)
                      : Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isGadgetInitialized
                        ? const Color(0xFF10B981).withValues(alpha: 0.3)
                        : Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.usb,
                      size: 20,
                      color: isGadgetInitialized
                          ? const Color(0xFF10B981)
                          : Colors.white70,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isGadgetInitialized ? 'Gadget Ready' : 'Setup ConfigFS',
                      style: TextStyle(
                        color: isGadgetInitialized
                            ? const Color(0xFF10B981)
                            : Colors.white70,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Кнопка Connect / Disconnect
          Expanded(
            child: InkWell(
              onTap: isProcessing ? null : _toggleConnection,
              borderRadius: BorderRadius.circular(10),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  gradient: isConnected
                      ? const LinearGradient(
                          colors: [Color(0xFFEF4444), Color(0xFFDC2626)],
                        )
                      : LinearGradient(
                          colors: [
                            const Color(0xFF6366F1),
                            const Color(0xFF4F46E5),
                          ],
                        ),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: isConnected
                      ? []
                      : [
                          BoxShadow(
                            color: const Color(0xFF6366F1).withValues(alpha: 0.25),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                ),
                child: Column(
                  children: [
                    Icon(
                      isConnected ? Icons.power_settings_new : Icons.play_arrow,
                      size: 20,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isConnected ? 'Disconnect' : 'Connect HID',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Кастомный TabBar
  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: TabBar(
        controller: _tabController,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        indicator: BoxDecoration(
          color: const Color(0xFF6366F1),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6366F1).withValues(alpha: 0.35),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white30,
        labelStyle: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 12,
          letterSpacing: 1.0,
        ),
        tabs: const [
          Tab(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.mouse_outlined, size: 16),
                SizedBox(width: 6),
                Text('TOUCHPAD'),
              ],
            ),
          ),
          Tab(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.keyboard_outlined, size: 16),
                SizedBox(width: 6),
                Text('KEYBOARD'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Заглушка, если соединение не установлено
  Widget _buildConnectionPrompt() {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.02),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                ),
                child: Icon(
                  Icons.usb,
                  size: 80,
                  color: Colors.white.withValues(alpha: 0.15),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'HID Connection Required',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'To start simulating mouse and keyboard, please follow these steps:\n\n'
                '1. Connect your phone to PC via USB cable.\n'
                '2. Tap "Setup ConfigFS" to initialize the USB drivers.\n'
                '3. Tap "Connect HID" to start the simulation.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 13,
                  height: 1.6,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
