// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:usb_mouse_mobile/main.dart';

void main() {
  testWidgets('HID Simulator basic rendering test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const UsbMouseApp());

    // Verify that the header and initial prompt exist.
    expect(find.text('USB HID SIMULATOR'), findsOneWidget);
    expect(find.text('HID Connection Required'), findsOneWidget);
  });
}

