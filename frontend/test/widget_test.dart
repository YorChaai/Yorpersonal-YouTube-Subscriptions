import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';

void main() {
  testWidgets('Audit UI: Dropdown Tab Navigation, Minimal Compact Mode, Refresh YouTube button, and Filters', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpWidget(const PersonalYouTubeApp());
    await tester.pumpAndSettle();

    // 1. Cek Sidebar Subscriptions tampil
    expect(find.text('Fajrul Fx'), findsWidgets);
    expect(find.text('Ferry Irwandi'), findsWidgets);

    // 2. Cek Tombol Refresh YouTube tersedia di header
    expect(find.text('Refresh YouTube'), findsOneWidget);

    // 3. Cek 3 Tombol Sortir & Pilihan Permanen 25/50/100 Video
    expect(find.text('🔥 View Terbanyak'), findsOneWidget);
    expect(find.text('👍 Like Terbanyak'), findsOneWidget);
    expect(find.text('🕒 Waktu Upload'), findsOneWidget);
    expect(find.text('25 Video'), findsOneWidget);
    expect(find.text('50 Video'), findsOneWidget);
    expect(find.text('100 Video'), findsOneWidget);

    // 4. Cek Dropdown Navigasi Tab + Tombol Kiri (Sebelumnya) & Kanan (Berikutnya)
    expect(find.text('Total: 36 video'), findsOneWidget);
    expect(find.text('Tab 1 (1–25)'), findsWidgets);
    expect(find.text('Sebelumnya'), findsWidgets);
    expect(find.text('Berikutnya'), findsWidgets);

    // Klik Berikutnya -> pindah ke Tab 2 (26–36)
    await tester.tap(find.text('Berikutnya').first);
    await tester.pumpAndSettle();
    expect(find.text('Tab 2 (26–36)'), findsWidgets);

    // 5. Cek Fitur Minimalisasi Filter Bar (Compact Mode)
    expect(find.text('Minimal'), findsOneWidget);
    await tester.tap(find.text('Minimal'));
    await tester.pumpAndSettle();
    expect(find.text('Buka Filter'), findsOneWidget);

    // Buka kembali filter
    await tester.tap(find.text('Buka Filter'));
    await tester.pumpAndSettle();
    expect(find.text('Minimal'), findsOneWidget);

    // 6. Pastikan tombol '🔕 Unsubscribe' di bawah kartu video sudah dihapus (cukup lewat titik 3)
    expect(find.text('🔕 Unsubscribe'), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsWidgets);

    // 7. Pastikan filter waktu sampai Tahun Ini + Input Tahun Lalu tersedia
    expect(find.text('Tahun Ini'), findsOneWidget);
    expect(find.text('Tahun Lalu'), findsOneWidget);
  });
}
