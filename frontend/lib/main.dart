import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(const PersonalYouTubeApp());
}

class PersonalYouTubeApp extends StatelessWidget {
  const PersonalYouTubeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Personal YouTube Subscriptions',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF0033),
          surface: Color(0xFF212121),
        ),
      ),
      home: const YouTubeHomeScreen(),
    );
  }
}

class YouTubeHomeScreen extends StatefulWidget {
  const YouTubeHomeScreen({super.key});

  @override
  State<YouTubeHomeScreen> createState() => _YouTubeHomeScreenState();
}

class _YouTubeHomeScreenState extends State<YouTubeHomeScreen> {
  String baseUrl = Uri.base.port == 8000 ? Uri.base.origin : 'http://127.0.0.1:8000';
  String sidebarMode = 'full'; // 'full' (240px) | 'mini' (72px ikon saja) | 'hidden' (0px)
  bool filterMinimized = false; // Opsi meminimalkan bar urutan/filter agar area video lebih luas
  bool loading = false;
  bool refreshingYouTube = false;
  int refreshProgress = 0; // 0..100 persen
  bool refreshReadyGreen = false; // True jika 100% selesai sync dan tombol berubah HIJAU siap diklik
  int refreshNewVideosCount = 0;
  Timer? _refreshPollTimer;
  bool isStandaloneMode = false; // Otomatis aktif di HP jika tanpa backend Python

  // Filter & Pagination State
  String sortBy = 'time'; // 'views' | 'likes' | 'time'
  String period = 'all'; // 'all' | 'week' | 'month' | 'year' | '2y' | '3y' | '4y'
  String selectedChannelId = '';
  String searchQuery = '';
  int limit = 25; // 25 | 50 | 100
  int defaultLimit = 25;
  Map<String, int> tabLimits = {}; // Penyimpanan permanen jumlah video per tab/channel
  int currentPage = 1;
  int totalVideos = 0;
  int totalPages = 1;
  RangeValues durationRange = const RangeValues(0, 120); // 0 menit s/d 120 menit (2 jam)
  DateTime? skipUnsubscribeConfirmUntil; // Mode 10 menit langsung Unsubscribe tanpa konfirmasi

  List<Map<String, dynamic>> channels = [];
  List<Map<String, dynamic>> videos = [];
  bool hasApiKey = false;
  String apiKeyPreview = '';
  String localApiKey = '';
  String localOauthToken = '';
  String localMyChannelId = '';
  bool _bundledDataLoaded = false;
  final Set<String> _localUnsubscribedIds = {};

  // Database lokal mandiri di dalam aplikasi (untuk jalan sendiri di HP tanpa Python backend)
  final List<Map<String, dynamic>> _localChannels = [];
  final List<Map<String, dynamic>> _localVideos = [];

  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _yearInputCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initLocalSeedData();
    _restoreSessionAndFetch();
  }

  @override
  void dispose() {
    _refreshPollTimer?.cancel();
    _searchCtrl.dispose();
    _yearInputCtrl.dispose();
    super.dispose();
  }

  void _initLocalSeedData() {
    if (_localChannels.isNotEmpty) return;
    final now = DateTime.now().toUtc();
    final demoChannels = [
      ('UC_demo_fajrul', 'Fajrul Fx', '@FajrulFx', 'https://i.ytimg.com/vi/M7lc1UVf-VE/hqdefault.jpg'),
      ('UC_demo_anim', 'Animated History', '@AnimatedHistory', 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg'),
      ('UC_demo_malaka', 'MALAKA', '@malaka_project', 'https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg'),
      ('UC_demo_radit', 'Raditya Dika', '@RadityaDika', 'https://i.ytimg.com/vi/9bZkp7q19f0/hqdefault.jpg'),
      ('UC_demo_justin', 'Justin Sung', '@JustinSung', 'https://i.ytimg.com/vi/kJQP7kiw5Fk/hqdefault.jpg'),
      ('UC_demo_ferry', 'Ferry Irwandi', '@FerryIrwandi', 'https://i.ytimg.com/vi/RgKAFK5djSk/hqdefault.jpg'),
    ];
    for (final c in demoChannels) {
      _localChannels.add({
        'channel_id': c.$1,
        'title': c.$2,
        'handle': c.$3,
        'thumbnail_url': c.$4,
        'uploads_playlist_id': 'UU${c.$1.substring(2)}',
        'source': 'demo',
        'video_count': 6,
      });
    }

    const ytThumbs = [
      'dQw4w9WgXcQ', 'M7lc1UVf-VE', 'jNQXAC9IVRw', '9bZkp7q19f0',
      'kJQP7kiw5Fk', 'RgKAFK5djSk', 'OPf0YbXqDm0', 'fJ9rUzIMcZQ',
      'CevxZvSJLk8', 'JGwWNGJdvx8', 'YQHsXMglC9A', 'hT_nvWreIhg',
    ];

    final samples = [
      // Minggu ini (1 - 6 hari lalu)
      ('UC_demo_ferry', 'Ferry Irwandi', 'Kenapa Bank Terbesar di Paraguay Bisa Kolaps? - Kasus Ueno', 1, 512000, 41200, '18:13'),
      ('UC_demo_fajrul', 'Fajrul Fx', 'Apa yang Terjadi pada Tubuh Saat Makan Sekali Sehari (Jam demi Jam)', 2, 440000, 32900, '10:18'),
      ('UC_demo_malaka', 'MALAKA', 'Cara Berpikir Kritis di Era Banjir Informasi (Minggu Ini)', 3, 690000, 58100, '24:14'),
      ('UC_demo_radit', 'Raditya Dika', 'Stand Up Comedy Spesial Minggu Ini: Cerita Finansial', 4, 920000, 74500, '31:45'),
      ('UC_demo_justin', 'Justin Sung', 'How to Study 3x Faster Without Memorizing (This Week)', 5, 310000, 27400, '16:20'),
      ('UC_demo_anim', 'Animated History', 'Sejarah Runtuhnya Kekaisaran Romawi dalam 15 Menit', 6, 780000, 63000, '15:08'),
      // Bulan ini (9 - 27 hari lalu)
      ('UC_demo_ferry', 'Ferry Irwandi', 'Bedah Logika & Stoikisme Untuk Anak Muda (Bulan Ini)', 9, 830000, 69300, '28:40'),
      ('UC_demo_malaka', 'MALAKA', 'Pendidikan & Masa Depan Kerja di Indonesia', 12, 1120000, 94000, '42:10'),
      ('UC_demo_radit', 'Raditya Dika', 'Podcast Cerita Horor Kantor Baru (Bulan Ini)', 15, 1450000, 112000, '54:20'),
      ('UC_demo_fajrul', 'Fajrul Fx', 'Eksperimen Sains: Tidur 4 Jam vs 8 Jam Selama Sebulan', 19, 610000, 48700, '14:55'),
      ('UC_demo_justin', 'Justin Sung', 'Mind Mapping Technique for Deep Understanding', 23, 495000, 39100, '21:12'),
      ('UC_demo_anim', 'Animated History', 'Perang Dunia II dari Sudut Pandang Ekonomi', 27, 950000, 81200, '19:33'),
      // Tahun ini (65 - 310 hari lalu)
      ('UC_demo_radit', 'Raditya Dika', 'Tur Rumah Baru & Studio Podcast (Tahun Ini)', 65, 2850000, 198000, '38:15'),
      ('UC_demo_ferry', 'Ferry Irwandi', 'Investigasi Fenomena Judi Online & Psikologi Bandar', 110, 3600000, 285000, '35:48'),
      ('UC_demo_malaka', 'MALAKA', 'Monolog: Kenapa Kita Sering Merasa Tertinggal?', 160, 1940000, 164000, '29:10'),
      ('UC_demo_fajrul', 'Fajrul Fx', 'Fisika Kuantum Dijelaskan dengan Bahasa Tongkrongan', 210, 1150000, 97500, '17:42'),
      ('UC_demo_justin', 'Justin Sung', 'Complete Guide to Self-Regulated Learning (This Year)', 260, 870000, 71000, '26:05'),
      ('UC_demo_anim', 'Animated History', 'Kebangkitan dan Keruntuhan Majapahit (Animasi Lengkap)', 310, 2210000, 175000, '33:20'),
      // 2 Tahun Lalu (420 - 690 hari lalu)
      ('UC_demo_ferry', 'Ferry Irwandi', 'Revolusi Industri Kreatif & Konten (2 Tahun Lalu)', 420, 1420000, 108000, '22:18'),
      ('UC_demo_radit', 'Raditya Dika', 'Belajar Investasi dari Nol untuk Pemula (2 Tahun Lalu)', 480, 3100000, 240000, '41:00'),
      ('UC_demo_malaka', 'MALAKA', 'Episode Perdana: Membangun Manusia Merdeka (2 Tahun Lalu)', 530, 2540000, 215000, '47:30'),
      ('UC_demo_fajrul', 'Fajrul Fx', 'Sejarah Penemuan Listrik & Konflik Tesla vs Edison', 590, 980000, 82400, '16:11'),
      ('UC_demo_justin', 'Justin Sung', 'Why Re-reading Notes Does Not Work (2 Years Ago)', 640, 1320000, 104000, '15:45'),
      ('UC_demo_anim', 'Animated History', 'Peta Perdagangan Jalur Sutra Kuno (2 Tahun Lalu)', 690, 1650000, 129000, '20:04'),
      // 3 Tahun Lalu (790 - 1060 hari lalu)
      ('UC_demo_radit', 'Raditya Dika', 'Cerita Masa Kuliah di Luar Negeri (3 Tahun Lalu)', 790, 4200000, 310000, '27:50'),
      ('UC_demo_ferry', 'Ferry Irwandi', 'Mindset Keuangan di Usia 20-an (3 Tahun Lalu)', 850, 1780000, 142000, '19:25'),
      ('UC_demo_fajrul', 'Fajrul Fx', 'Bagaimana Cara Kerja Mesin Waktu Menurut Teori Relativitas?', 910, 1540000, 126000, '14:30'),
      ('UC_demo_justin', 'Justin Sung', 'Top 1% Student Study Routine (3 Years Ago)', 960, 2450000, 195000, '18:55'),
      ('UC_demo_anim', 'Animated History', 'Sejarah Nusantara Sebelum Era Kolonial (3 Tahun Lalu)', 1020, 2890000, 224000, '25:40'),
      ('UC_demo_malaka', 'MALAKA', 'Diskusi Filsafat Klasik untuk Kehidupan Modern (3 Tahun Lalu)', 1060, 1190000, 96000, '36:12'),
      // 4 Tahun Lalu (1150 - 1430 hari lalu)
      ('UC_demo_radit', 'Raditya Dika', 'Bongkar Rahasia Menulis Buku & Skenario Film (4 Tahun Lalu)', 1150, 3850000, 290000, '34:10'),
      ('UC_demo_fajrul', 'Fajrul Fx', 'Video Sains Pertama: Kenapa Langit Berwarna Biru? (4 Tahun Lalu)', 1220, 890000, 73000, '11:20'),
      ('UC_demo_justin', 'Justin Sung', 'How I Transitioned from Medical School to Teaching (4 Years Ago)', 1290, 1620000, 134000, '22:00'),
      ('UC_demo_anim', 'Animated History', 'Asal Usul Peradaban Mesopotamia (4 Tahun Lalu)', 1350, 3120000, 248000, '21:45'),
      ('UC_demo_ferry', 'Ferry Irwandi', 'Belajar Videografi & Storytelling Sinematik (4 Tahun Lalu)', 1400, 1250000, 99500, '16:50'),
      ('UC_demo_malaka', 'MALAKA', 'Arsip Pemikiran: Membaca Ulang Sejarah Bangsa (4 Tahun Lalu)', 1430, 1410000, 115000, '39:05'),
    ];

    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final ytId = ytThumbs[i % ytThumbs.length];
      _localVideos.add({
        'video_id': 'demo_${(i + 1).toString().padLeft(2, '0')}_$ytId',
        'channel_id': s.$1,
        'channel_title': s.$2,
        'channel_thumbnail': 'https://i.ytimg.com/vi/$ytId/default.jpg',
        'title': s.$3,
        'thumbnail_url': 'https://i.ytimg.com/vi/$ytId/hqdefault.jpg',
        'published_at': now.subtract(Duration(days: s.$4)).toIso8601String(),
        'view_count': s.$5,
        'like_count': s.$6,
        'duration': s.$7,
        'is_demo': 1,
      });
    }
  }

  Future<void> _loadBundledInitialDataIfNeeded() async {
    if (_bundledDataLoaded) return;
    _bundledDataLoaded = true;
    if (WidgetsBinding.instance.runtimeType.toString().contains('Test')) return;
    try {
      final rawJson = await rootBundle.loadString('assets/initial_data.json');
      if (rawJson.isNotEmpty) {
        final parsed = jsonDecode(rawJson) as Map<String, dynamic>;
        final bundledKey = (parsed['api_key'] ?? '').toString();
        final bundledCid = (parsed['my_channel_id'] ?? '').toString();
        final bundledChs = (parsed['channels'] as List?) ?? [];
        final bundledVids = (parsed['videos'] as List?) ?? [];
        if (bundledChs.isNotEmpty) {
          _localChannels
            ..clear()
            ..addAll(bundledChs.map((e) => Map<String, dynamic>.from(e as Map)));
          _sortChannelsByWatchedDesc(_localChannels);
        }
        if (bundledVids.isNotEmpty) {
          _localVideos
            ..clear()
            ..addAll(bundledVids.map((e) => Map<String, dynamic>.from(e as Map)));
        }
        if (bundledKey.isNotEmpty) {
          localApiKey = bundledKey;
          hasApiKey = true;
          apiKeyPreview = bundledKey.length > 8
              ? '${bundledKey.substring(0, 6)}...${bundledKey.substring(bundledKey.length - 4)}'
              : 'Terpasang';
        }
        if (bundledCid.isNotEmpty) {
          localMyChannelId = bundledCid;
        }
      }
    } catch (_) {}
  }

  void _applyLocalFilterAndPagination() {
    final now = DateTime.now().toUtc();
    String? startIso;
    String? endIso;
    if (period == 'week') {
      startIso = now.subtract(const Duration(days: 7)).toIso8601String();
    } else if (period == 'month') {
      startIso = now.subtract(const Duration(days: 30)).toIso8601String();
    } else if (period == 'year') {
      startIso = now.subtract(const Duration(days: 365)).toIso8601String();
    } else if (period.endsWith('y') && int.tryParse(period.substring(0, period.length - 1)) != null) {
      final yrs = int.parse(period.substring(0, period.length - 1));
      if (yrs >= 1) {
        startIso = now.subtract(Duration(days: 365 * yrs)).toIso8601String();
        if (yrs > 1) {
          endIso = now.subtract(Duration(days: 365 * (yrs - 1))).toIso8601String();
        }
      }
    }

    final qLower = searchQuery.trim().toLowerCase();
    final minSec = durationRange.start.round() * 60;
    final maxSec = durationRange.end.round() * 60;
    final filtered = _localVideos.where((v) {
      if (selectedChannelId.isNotEmpty && v['channel_id'] != selectedChannelId) {
        return false;
      }
      if (minSec > 0 || durationRange.end.round() < 120) {
        final durSec = (v['duration_seconds'] as int?) ?? _durationToSeconds((v['duration'] ?? '').toString());
        if (minSec > 0 && durSec < minSec) return false;
        if (durationRange.end.round() < 120 && durSec > maxSec) return false;
      }
      if (qLower.isNotEmpty) {
        final t = (v['title'] ?? '').toString().toLowerCase();
        final ct = (v['channel_title'] ?? '').toString().toLowerCase();
        if (!t.contains(qLower) && !ct.contains(qLower)) return false;
      }
      if (startIso != null || endIso != null) {
        final pubStr = (v['published_at'] ?? '').toString();
        if (pubStr.isEmpty) return false;
        if (startIso != null && pubStr.compareTo(startIso) < 0) return false;
        if (endIso != null && pubStr.compareTo(endIso) >= 0) return false;
      }
      return true;
    }).toList();

    filtered.sort((a, b) {
      if (sortBy == 'views') {
        return ((b['view_count'] ?? 0) as int).compareTo((a['view_count'] ?? 0) as int);
      } else if (sortBy == 'likes') {
        return ((b['like_count'] ?? 0) as int).compareTo((a['like_count'] ?? 0) as int);
      }
      return (b['published_at'] ?? '').toString().compareTo((a['published_at'] ?? '').toString());
    });

    final total = filtered.length;
    final pages = total == 0 ? 1 : ((total + limit - 1) ~/ limit);
    final safePage = currentPage > pages ? pages : currentPage;
    final startIdx = (safePage - 1) * limit;
    final endIdx = (startIdx + limit > total) ? total : startIdx + limit;

    setState(() {
      isStandaloneMode = true;
      channels = List<Map<String, dynamic>>.from(_localChannels);
      totalVideos = total;
      totalPages = pages;
      currentPage = safePage;
      videos = startIdx < total ? filtered.sublist(startIdx, endIdx) : [];
      loading = false;
    });
  }

  Future<void> _restoreSessionAndFetch() async {
    setState(() => loading = true);
    await _loadBundledInitialDataIfNeeded();
    try {
      http.Response? stateRes;
      final candidates = <String>{
        baseUrl,
        'http://127.0.0.1:8000',
        'http://172.18.164.232:8000',
        'http://192.168.68.54:8000',
      };
      for (final candidate in candidates) {
        try {
          final r = await http
              .get(Uri.parse('$candidate/api/state'))
              .timeout(const Duration(milliseconds: 1200));
          if (r.statusCode == 200) {
            baseUrl = candidate;
            stateRes = r;
            break;
          }
        } catch (_) {}
      }
      if (stateRes != null && stateRes.statusCode == 200) {
        final sData = jsonDecode(stateRes.body);
        final sess = (sData['session_state'] as Map?) ?? {};
        final rawTabLimits = (sData['tab_limits'] as Map?) ?? {};
        final parsedTabLimits = <String, int>{};
        rawTabLimits.forEach((k, v) {
          final iv = int.tryParse(v.toString());
          if (iv != null && (iv == 25 || iv == 50 || iv == 100)) {
            parsedTabLimits[k.toString()] = iv;
          }
        });
        final defLim = (sData['default_limit'] as int?) ?? 25;
        final sessChannel = (sess['channel_id'] ?? '').toString();
        final activeLim = parsedTabLimits[sessChannel.isEmpty ? 'home' : sessChannel] ?? defLim;
        final minM = ((sess['min_minutes'] ?? 0) as num).toDouble().clamp(0.0, 120.0);
        final maxM = ((sess['max_minutes'] ?? 120) as num).toDouble().clamp(minM, 120.0);
        final rState = (sData['refresh_state'] as Map?) ?? {};
        final rRunning = (rState['running'] as bool?) ?? false;
        final rReady = (rState['done_ready'] as bool?) ?? false;
        final rProg = (rState['progress'] as int?) ?? 0;
        final rNewVids = (rState['new_videos'] as int?) ?? 0;

        setState(() {
          isStandaloneMode = false;
          channels = List<Map<String, dynamic>>.from(sData['channels'] ?? []);
          _sortChannelsByWatchedDesc(channels);
          hasApiKey = sData['has_api_key'] ?? false;
          apiKeyPreview = sData['api_key_preview'] ?? '';
          defaultLimit = defLim;
          tabLimits = parsedTabLimits;
          sortBy = (sess['sort_by'] ?? 'time').toString();
          period = (sess['period'] ?? 'all').toString();
          if (period.endsWith('y') && int.tryParse(period.substring(0, period.length - 1)) != null) {
            _yearInputCtrl.text = period.substring(0, period.length - 1);
          } else {
            _yearInputCtrl.clear();
          }
          selectedChannelId = sessChannel;
          searchQuery = (sess['q'] ?? '').toString();
          _searchCtrl.text = searchQuery;
          currentPage = (sess['page'] as int?) ?? 1;
          durationRange = RangeValues(minM, maxM);
          sidebarMode = (sess['sidebar_mode'] ?? 'full').toString();
          filterMinimized = (sess['filter_minimized'] as bool?) ?? false;
          limit = (activeLim == 25 || activeLim == 50 || activeLim == 100) ? activeLim : 25;
          refreshingYouTube = rRunning;
          refreshReadyGreen = rReady;
          refreshProgress = rProg;
          refreshNewVideosCount = rNewVids;
        });
        if (rRunning) {
          _startRefreshPolling();
        }
      }
    } catch (_) {}
    await _fetchVideos();
  }

  void _startRefreshPolling() {
    _refreshPollTimer?.cancel();
    _refreshPollTimer = Timer.periodic(const Duration(milliseconds: 600), (timer) async {
      if (!mounted || isStandaloneMode) {
        timer.cancel();
        return;
      }
      try {
        final res = await http
            .get(Uri.parse('$baseUrl/api/refresh-youtube/status'))
            .timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          final running = (data['running'] as bool?) ?? false;
          final prog = (data['progress'] as int?) ?? 0;
          final ready = (data['done_ready'] as bool?) ?? false;
          final newVids = (data['new_videos'] as int?) ?? 0;
          final err = (data['error'] ?? '').toString();

          if (!mounted) return;
          setState(() {
            refreshingYouTube = running;
            refreshProgress = prog;
            refreshReadyGreen = ready;
            refreshNewVideosCount = newVids;
          });

          if (!running) {
            timer.cancel();
            if (err.isNotEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  backgroundColor: Colors.redAccent,
                  content: Text('⚠️ Gagal Refresh YouTube: $err'),
                ),
              );
            } else if (ready) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  backgroundColor: const Color(0xFF1B5E20),
                  content: Text(
                    '🟢 Sync 100% Selesai! Tekan tombol HIJAU "Refresh YouTube (100%)" untuk menampilkan $newVids video baru.',
                  ),
                ),
              );
            }
          }
        }
      } catch (_) {}
    });
  }

  Future<void> _saveUiPreferences({int? newLimit, String? newSidebarMode, bool? newFilterMinimized}) async {
    final tabKey = selectedChannelId.isEmpty ? 'home' : selectedChannelId;
    if (newLimit != null && (newLimit == 25 || newLimit == 50 || newLimit == 100)) {
      defaultLimit = newLimit;
      tabLimits[tabKey] = newLimit;
    }
    if (!isStandaloneMode) {
      try {
        await http.post(
          Uri.parse('$baseUrl/api/ui-state'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'sort_by': sortBy,
            'period': period,
            'channel_id': selectedChannelId,
            'q': searchQuery,
            'page': currentPage,
            'min_minutes': durationRange.start.round(),
            'max_minutes': durationRange.end.round(),
            'limit': newLimit,
            'sidebar_mode': newSidebarMode ?? sidebarMode,
            'filter_minimized': newFilterMinimized ?? filterMinimized,
          }),
        );
      } catch (_) {}
    }
  }

  Future<void> _manualRefreshYouTube() async {
    // 1. Jika tombol sudah HIJAU (Sync 100% selesai), klik tombol hijau langsung menampilkan video baru ke layar!
    if (refreshReadyGreen) {
      if (!isStandaloneMode) {
        try {
          await http.post(Uri.parse('$baseUrl/api/refresh-youtube/consume'));
        } catch (_) {}
      }
      final addedCount = refreshNewVideosCount;
      setState(() {
        refreshReadyGreen = false;
        refreshProgress = 0;
        currentPage = 1;
      });
      await _fetchVideos();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1B5E20),
            content: Text(
              '✅ Video terbaru berhasil ditampilkan! ($addedCount video baru dimuat, Total: $totalVideos video)',
            ),
          ),
        );
      }
      return;
    }

    // 2. Jika sedang proses sync di background (0%..99%), biarkan user tetap menjelajah tanpa memblokir layar
    if (refreshingYouTube) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF272727),
            duration: const Duration(seconds: 2),
            content: Text(
              '⏳ Sinkronisasi berjalan di latar belakang ($refreshProgress%)... Setelah 100% (Hijau), klik lagi untuk menampilkan video baru.',
            ),
          ),
        );
      }
      return;
    }

    // 3. Tombol MERAH ditekan -> Mulai sinkronisasi di latar belakang (0% -> 100%) tanpa harus ditunggu
    setState(() {
      refreshingYouTube = true;
      refreshProgress = 2;
      refreshReadyGreen = false;
    });

    try {
      if (isStandaloneMode) {
        if (localApiKey.isEmpty) {
          throw Exception('Masukkan API Key terlebih dahulu di menu ⚙️.');
        }
        final beforeCount = _localVideos.length;
        // 1. Cek daftar Subscriptions terbaru via Channel ID user + API Key
        if (localMyChannelId.isNotEmpty && selectedChannelId.isEmpty) {
          await _standaloneSyncSubscriptionsByMyChannel();
        }
        final targetChs = _localChannels
            .where((ch) =>
                !(ch['channel_id'] ?? '').toString().startsWith('UC_demo_') &&
                (selectedChannelId.isEmpty || ch['channel_id'] == selectedChannelId))
            .toList();
        await _standaloneFastRefreshChannels(targetChs);
        if (!mounted) return;
        setState(() {
          refreshingYouTube = false;
          refreshProgress = 100;
          refreshReadyGreen = true;
          refreshNewVideosCount = (_localVideos.length - beforeCount).clamp(0, 999999);
        });
      } else {
        final res = await http.post(
          Uri.parse('$baseUrl/api/refresh-youtube'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'channel_id': selectedChannelId}),
        );
        if (res.statusCode == 200) {
          _startRefreshPolling();
        } else {
          final err = jsonDecode(res.body);
          throw Exception(err['detail'] ?? 'Gagal memulai Refresh YouTube');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          refreshingYouTube = false;
          refreshProgress = 0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text('⚠️ Gagal Refresh YouTube: ${e.toString().replaceAll("Exception: ", "")}'),
          ),
        );
      }
    }
  }

  Future<void> _refreshAll() async {
    await _fetchVideos();
  }

  Future<void> _fetchVideos() async {
    setState(() => loading = true);
    try {
      final stateRes = await http
          .get(Uri.parse('$baseUrl/api/state'))
          .timeout(const Duration(seconds: 4));
      final uri = Uri.parse('$baseUrl/api/videos').replace(
        queryParameters: {
          'sort_by': sortBy,
          'period': period,
          'channel_id': selectedChannelId,
          'q': searchQuery,
          'limit': limit.toString(),
          'page': currentPage.toString(),
          'min_minutes': durationRange.start.round().toString(),
          'max_minutes': durationRange.end.round().toString(),
        },
      );
      final vidRes = await http.get(uri).timeout(const Duration(seconds: 15));
      if (stateRes.statusCode == 200 && vidRes.statusCode == 200) {
        final sData = jsonDecode(stateRes.body);
        final vData = jsonDecode(vidRes.body);
        if (!mounted) return;
        setState(() {
          isStandaloneMode = false;
          channels = List<Map<String, dynamic>>.from(sData['channels'] ?? []);
          _sortChannelsByWatchedDesc(channels);
          hasApiKey = sData['has_api_key'] ?? false;
          apiKeyPreview = sData['api_key_preview'] ?? '';
          videos = List<Map<String, dynamic>>.from(vData['items'] ?? []);
          totalVideos = vData['total'] ?? 0;
          totalPages = vData['total_pages'] ?? 1;
          loading = false;
        });
        return;
      }
    } catch (_) {
      // Jika tidak ada backend Python (misal saat jalan mandiri sebagai APK di HP),
      // otomatis gunakan Mesin Mandiri (Standalone Mode) tanpa error!
    }
    if (!mounted) return;
    _applyLocalFilterAndPagination();
  }

  Future<void> _standaloneSyncSubscriptionsByMyChannel() async {
    if (localMyChannelId.isEmpty || localApiKey.isEmpty) return;
    try {
      final existingCids = _localChannels.map((c) => (c['channel_id'] ?? '').toString()).toSet();
      String? pageToken;
      for (var page = 0; page < 25; page++) {
        final params = <String, String>{
          'part': 'snippet',
          'channelId': localMyChannelId,
          'maxResults': '50',
          'order': 'alphabetical',
          'key': localApiKey,
        };
        if (pageToken != null && pageToken.isNotEmpty) {
          params['pageToken'] = pageToken;
        }
        final uri = Uri.https('www.googleapis.com', '/youtube/v3/subscriptions', params);
        final res = await http.get(uri).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) break;
        final data = jsonDecode(res.body);
        final items = (data['items'] as List?) ?? [];
        for (final item in items) {
          final snip = item['snippet'] ?? {};
          final cid = (snip['resourceId']?['channelId'] ?? '').toString();
          if (cid.isEmpty || existingCids.contains(cid) || _localUnsubscribedIds.contains(cid)) continue;
          final title = (snip['title'] ?? cid).toString();
          final thumb = (snip['thumbnails']?['default']?['url'] ?? '').toString();
          _localChannels.add({
            'channel_id': cid,
            'title': title,
            'handle': '',
            'thumbnail_url': thumb,
            'uploads_playlist_id': cid.startsWith('UC') ? 'UU${cid.substring(2)}' : cid,
            'source': 'subscriptions',
            'video_count': 0,
            'watched_count': 0,
          });
          existingCids.add(cid);
        }
        pageToken = data['nextPageToken']?.toString();
        if (pageToken == null || pageToken.isEmpty) break;
      }
      _sortChannelsByWatchedDesc(_localChannels);
    } catch (_) {}
  }

  Future<void> _standaloneFastRefreshChannels(List<Map<String, dynamic>> targetChs) async {
    if (targetChs.isEmpty) return;
    final existingVidIds = _localVideos.map((v) => (v['video_id'] ?? '').toString()).toSet();
    final newVidMeta = <String, Map<String, String>>{};
    final vidRegex = RegExp(r'<yt:videoId>([^<]+)</yt:videoId>');

    const batchSize = 35;
    for (var i = 0; i < targetChs.length; i += batchSize) {
      final chunk = targetChs.sublist(i, (i + batchSize > targetChs.length) ? targetChs.length : i + batchSize);
      await Future.wait(chunk.map((ch) async {
        final cid = (ch['channel_id'] ?? '').toString();
        if (!cid.startsWith('UC')) return;
        try {
          final feedUri = Uri.parse('https://www.youtube.com/feeds/videos.xml?channel_id=$cid');
          final res = await http.get(feedUri).timeout(const Duration(seconds: 5));
          if (res.statusCode == 200) {
            final matches = vidRegex.allMatches(res.body);
            for (final m in matches) {
              final vid = (m.group(1) ?? '').trim();
              if (vid.isNotEmpty && !existingVidIds.contains(vid)) {
                newVidMeta[vid] = {
                  'channel_id': cid,
                  'channel_title': (ch['title'] ?? '').toString(),
                  'channel_thumbnail': (ch['thumbnail_url'] ?? '').toString(),
                };
              }
            }
          }
        } catch (_) {}
      }));
      if (!mounted) return;
      setState(() {
        refreshProgress = ((i + chunk.length) * 90 ~/ targetChs.length).clamp(5, 92);
      });
    }

    final newIds = newVidMeta.keys.toList();
    for (var i = 0; i < newIds.length; i += 50) {
      final slice = newIds.sublist(i, (i + 50 > newIds.length) ? newIds.length : i + 50);
      try {
        final vUri = Uri.https('www.googleapis.com', '/youtube/v3/videos', {
          'part': 'snippet,statistics,contentDetails',
          'id': slice.join(','),
          'key': localApiKey,
        });
        final vRes = await http.get(vUri).timeout(const Duration(seconds: 10));
        if (vRes.statusCode == 200) {
          final vData = jsonDecode(vRes.body);
          final vItems = (vData['items'] as List?) ?? [];
          for (final v in vItems) {
            final vid = (v['id'] ?? '').toString();
            final vsnip = v['snippet'] ?? {};
            final vstats = v['statistics'] ?? {};
            final meta = newVidMeta[vid] ?? {};
            final cid = (vsnip['channelId'] ?? meta['channel_id'] ?? '').toString();
            final durStr = _parseIsoDuration((v['contentDetails']?['duration'] ?? '').toString());
            _localVideos.insert(0, {
              'video_id': vid,
              'channel_id': cid,
              'channel_title': (vsnip['channelTitle'] ?? meta['channel_title'] ?? '').toString(),
              'channel_thumbnail': (meta['channel_thumbnail'] ?? '').toString(),
              'title': (vsnip['title'] ?? 'Untitled').toString(),
              'thumbnail_url': (vsnip['thumbnails']?['high']?['url'] ??
                      vsnip['thumbnails']?['medium']?['url'] ??
                      'https://i.ytimg.com/vi/$vid/hqdefault.jpg')
                  .toString(),
              'published_at': (vsnip['publishedAt'] ?? DateTime.now().toUtc().toIso8601String()).toString(),
              'view_count': int.tryParse((vstats['viewCount'] ?? '0').toString()) ?? 0,
              'like_count': int.tryParse((vstats['likeCount'] ?? '0').toString()) ?? 0,
              'duration': durStr,
              'duration_seconds': _durationToSeconds(durStr),
              'watched_count': _getCreatorWatchedCount(cid),
              'is_demo': 0,
            });
          }
        }
      } catch (_) {}
    }
  }

  // Fungsi Mandiri (Standalone di HP) untuk langsung memanggil API YouTube tanpa Backend Python
  Future<void> _standaloneAddAndSyncChannel(String identifier) async {
    String raw = identifier.trim();
    if (raw.isEmpty) throw Exception('Masukkan @handle atau ID Channel');
    if (localApiKey.isEmpty) {
      throw Exception('Masukkan YouTube API Key dulu di menu Pengaturan API (⚙️).');
    }
    if (raw.contains('youtube.com/')) {
      if (raw.contains('/@')) {
        raw = '@${raw.split('/@')[1].split('/')[0].split('?')[0]}';
      } else if (raw.contains('/channel/')) {
        raw = raw.split('/channel/')[1].split('/')[0].split('?')[0];
      }
    }

    final queryParams = <String, String>{
      'part': 'snippet,contentDetails',
      'key': localApiKey,
    };
    if (raw.startsWith('@')) {
      queryParams['forHandle'] = raw;
    } else if (raw.startsWith('UC') && raw.length >= 20) {
      queryParams['id'] = raw;
    } else {
      queryParams['forHandle'] = '@$raw';
    }

    final chUri = Uri.https('www.googleapis.com', '/youtube/v3/channels', queryParams);
    final chRes = await http.get(chUri);
    final chData = jsonDecode(chRes.body);
    final items = (chData['items'] as List?) ?? [];
    if (items.isEmpty) {
      throw Exception('Channel "$identifier" tidak ditemukan atau API Key kurang tepat.');
    }

    final ch = items[0];
    final cid = ch['id'].toString();
    final snip = ch['snippet'] ?? {};
    final title = (snip['title'] ?? raw).toString();
    final handle = (snip['customUrl'] ?? raw).toString();
    final thumbUrl = ((snip['thumbnails']?['medium'] ?? snip['thumbnails']?['default'])?['url'] ?? '').toString();
    final uploadsPid = (ch['contentDetails']?['relatedPlaylists']?['uploads'] ??
            (cid.startsWith('UC') ? 'UU${cid.substring(2)}' : cid))
        .toString();

    _localChannels.removeWhere((c) => c['channel_id'] == cid);
    _localChannels.add({
      'channel_id': cid,
      'title': title,
      'handle': handle,
      'thumbnail_url': thumbUrl,
      'uploads_playlist_id': uploadsPid,
      'source': 'manual',
      'video_count': 0,
    });

    // Ambil 50 video terbaru dari playlist uploads (hemat kuota: 1 poin)
    final plUri = Uri.https('www.googleapis.com', '/youtube/v3/playlistItems', {
      'part': 'contentDetails',
      'playlistId': uploadsPid,
      'maxResults': '50',
      'key': localApiKey,
    });
    final plRes = await http.get(plUri);
    final plItems = (jsonDecode(plRes.body)['items'] as List?) ?? [];
    final videoIds = plItems
        .map((e) => (e['contentDetails']?['videoId'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toList();

    if (videoIds.isNotEmpty) {
      final vUri = Uri.https('www.googleapis.com', '/youtube/v3/videos', {
        'part': 'snippet,statistics,contentDetails',
        'id': videoIds.join(','),
        'key': localApiKey,
      });
      final vRes = await http.get(vUri);
      final vItems = (jsonDecode(vRes.body)['items'] as List?) ?? [];
      for (final v in vItems) {
        final vid = v['id'].toString();
        final vsnip = v['snippet'] ?? {};
        final vstats = v['statistics'] ?? {};
        _localVideos.removeWhere((old) => old['video_id'] == vid);
        _localVideos.add({
          'video_id': vid,
          'channel_id': cid,
          'channel_title': title,
          'channel_thumbnail': thumbUrl,
          'title': (vsnip['title'] ?? 'Untitled').toString(),
          'thumbnail_url': ((vsnip['thumbnails']?['high'] ?? vsnip['thumbnails']?['medium'])?['url'] ??
                  'https://i.ytimg.com/vi/$vid/hqdefault.jpg')
              .toString(),
          'published_at': (vsnip['publishedAt'] ?? DateTime.now().toUtc().toIso8601String()).toString(),
          'view_count': int.tryParse((vstats['viewCount'] ?? '0').toString()) ?? 0,
          'like_count': int.tryParse((vstats['likeCount'] ?? '0').toString()) ?? 0,
          'duration': _parseIsoDuration((v['contentDetails']?['duration'] ?? '').toString()),
          'is_demo': 0,
        });
      }
    }
  }

  String _parseIsoDuration(String iso) {
    final reg = RegExp(r'PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?');
    final m = reg.firstMatch(iso);
    if (m == null) return '';
    final h = int.tryParse(m.group(1) ?? '0') ?? 0;
    final mins = int.tryParse(m.group(2) ?? '0') ?? 0;
    final s = int.tryParse(m.group(3) ?? '0') ?? 0;
    if (h > 0) {
      return '$h:${mins.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$mins:${s.toString().padLeft(2, '0')}';
  }

  int _durationToSeconds(String dur) {
    if (dur.isEmpty) return 0;
    final parts = dur.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    if (parts.length == 2) return parts[0] * 60 + parts[1];
    return parts.isNotEmpty ? parts[0] : 0;
  }

  String _formatMinutesLabel(int mins, {bool isMax = false}) {
    if (isMax && mins >= 120) return '2 Jam+ (Tanpa Batas)';
    if (mins == 0) return '0 menit';
    if (mins >= 60) {
      final h = mins ~/ 60;
      final m = mins % 60;
      return m == 0 ? '$h jam' : '$h jam $m menit';
    }
    return '$mins menit';
  }

  String _formatCompactNumber(int num) {
    if (num >= 1000000) {
      return '${(num / 1000000).toStringAsFixed(1).replaceAll('.0', '')}M';
    }
    if (num >= 1000) {
      return '${(num / 1000).toStringAsFixed(1).replaceAll('.0', '')}K';
    }
    return num.toString();
  }

  String _formatTimeAgo(String isoDate) {
    try {
      final dt = DateTime.parse(isoDate).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inDays >= 365) {
        final years = (diff.inDays / 365).floor();
        return '$years tahun lalu';
      }
      if (diff.inDays >= 30) {
        final months = (diff.inDays / 30).floor();
        return '$months bulan lalu';
      }
      if (diff.inDays >= 1) {
        return '${diff.inDays} hari lalu';
      }
      if (diff.inHours >= 1) {
        return '${diff.inHours} jam lalu';
      }
      if (diff.inMinutes >= 1) {
        return '${diff.inMinutes} menit lalu';
      }
      return 'Baru saja';
    } catch (_) {
      return isoDate;
    }
  }

  void _sortChannelsByWatchedDesc(List<Map<String, dynamic>> list) {
    list.sort((a, b) {
      final wa = int.tryParse((a['watched_count'] ?? 0).toString()) ?? 0;
      final wb = int.tryParse((b['watched_count'] ?? 0).toString()) ?? 0;
      if (wb != wa) return wb.compareTo(wa);
      final ta = (a['title'] ?? '').toString().toLowerCase();
      final tb = (b['title'] ?? '').toString().toLowerCase();
      return ta.compareTo(tb);
    });
  }

  int _getCreatorWatchedCount(String channelId, [Map<String, dynamic>? v]) {
    for (final c in channels) {
      if ((c['channel_id'] ?? '').toString() == channelId) {
        return int.tryParse((c['watched_count'] ?? 0).toString()) ?? 0;
      }
    }
    if (v != null) {
      return int.tryParse((v['watched_count'] ?? 0).toString()) ?? 0;
    }
    return 0;
  }

  Future<void> _openYouTubeVideo(Map<String, dynamic> video) async {
    final channelId = (video['channel_id'] ?? '').toString();
    if (channelId.isNotEmpty) {
      final nextCount = _getCreatorWatchedCount(channelId, video) + 1;
      setState(() {
        for (final c in channels) {
          if ((c['channel_id'] ?? '').toString() == channelId) {
            c['watched_count'] = nextCount;
          }
        }
        for (final c in _localChannels) {
          if ((c['channel_id'] ?? '').toString() == channelId) {
            c['watched_count'] = nextCount;
          }
        }
        _sortChannelsByWatchedDesc(channels);
        _sortChannelsByWatchedDesc(_localChannels);
        for (final v in videos) {
          if ((v['channel_id'] ?? '').toString() == channelId) {
            v['watched_count'] = nextCount;
          }
        }
        for (final v in _localVideos) {
          if ((v['channel_id'] ?? '').toString() == channelId) {
            v['watched_count'] = nextCount;
          }
        }
      });
      if (!isStandaloneMode) {
        try {
          http.post(Uri.parse('$baseUrl/api/channels/${Uri.encodeComponent(channelId)}/watch'));
        } catch (_) {}
      }
    }

    String rawId = (video['video_id'] ?? '').toString();
    if (rawId.startsWith('demo_') && rawId.length > 8) {
      final parts = rawId.split('_');
      if (parts.length >= 3) {
        rawId = parts.sublist(2).join('_');
      }
    }
    final url = Uri.parse('https://www.youtube.com/watch?v=$rawId');
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  bool get _isFastUnsubscribeActive =>
      skipUnsubscribeConfirmUntil != null && DateTime.now().isBefore(skipUnsubscribeConfirmUntil!);

  Future<void> _executeUnsubscribe(String channelId, String channelTitle) async {
    _localUnsubscribedIds.add(channelId);
    // Hapus langsung dari tampilan supaya instan
    setState(() {
      channels.removeWhere((c) => c['channel_id'] == channelId);
      videos.removeWhere((v) => v['channel_id'] == channelId);
      _localChannels.removeWhere((c) => c['channel_id'] == channelId);
      _localVideos.removeWhere((v) => v['channel_id'] == channelId);
      if (selectedChannelId == channelId) {
        selectedChannelId = '';
      }
    });

    if (!isStandaloneMode) {
      try {
        await http.delete(Uri.parse('$baseUrl/api/channels/${Uri.encodeComponent(channelId)}'));
      } catch (_) {}
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFF272727),
        duration: const Duration(seconds: 2),
        content: Text(
          _isFastUnsubscribeActive
              ? '🔕 Unsubscribe "$channelTitle" berhasil (Mode Cepat 10 Menit Aktif)'
              : '🔕 Berhasil Unsubscribe "$channelTitle"',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
    _fetchVideos();
  }

  Future<void> _confirmOrUnsubscribeChannel(String channelId, String channelTitle) async {
    if (channelId.isEmpty) return;

    // Jika masih dalam masa 10 menit bebas notifikasi, langsung Unsubscribe!
    if (_isFastUnsubscribeActive) {
      await _executeUnsubscribe(channelId, channelTitle);
      return;
    }

    bool skipNext10Min = false;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          backgroundColor: const Color(0xFF212121),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Row(
            children: [
              const Icon(Icons.person_remove_alt_1, color: Color(0xFFFF0033)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Unsubscribe "$channelTitle"?',
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Apakah kamu yakin ingin menghapus / unsubscribe kreator "$channelTitle"? Semua video dari channel ini akan dihapus dari daftar tontonanmu.',
                  style: const TextStyle(fontSize: 14, color: Colors.white70),
                ),
                const SizedBox(height: 16),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setModalState(() => skipNext10Min = !skipNext10Min),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: skipNext10Min ? const Color(0xFFFF0033) : const Color(0xFF383838),
                      ),
                    ),
                    child: Row(
                      children: [
                        Checkbox(
                          value: skipNext10Min,
                          activeColor: const Color(0xFFFF0033),
                          onChanged: (val) => setModalState(() => skipNext10Min = val ?? false),
                        ),
                        const Expanded(
                          child: Text(
                            'Selama 10 menit ke depan, jangan tanya lagi (langsung Unsubscribe otomatis setiap klik)',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Batal', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.person_remove, size: 18),
              label: const Text('Ya, Unsubscribe'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF0033),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                if (skipNext10Min) {
                  setState(() {
                    skipUnsubscribeConfirmUntil = DateTime.now().add(const Duration(minutes: 10));
                  });
                }
                Navigator.pop(ctx);
                _executeUnsubscribe(channelId, channelTitle);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportExcelCsv() async {
    if (!isStandaloneMode) {
      final url = Uri.parse('$baseUrl/api/channels/export-csv');
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return;
    }
    // Jika di HP (Mode Mandiri), tampilkan & salin teks CSV siap tempel ke Excel / Google Sheets
    final buffer = StringBuffer('Channel ID,Nama Channel,Handle,Jumlah Video\n');
    for (final c in channels) {
      buffer.writeln('${c['channel_id']},"${c['title']}",${c['handle'] ?? ''},${c['video_count'] ?? 0}');
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Data CSV berhasil disalin ke Clipboard! Siap ditempel (Paste) ke Excel / Google Sheets.'),
      ),
    );
  }

  void _showAddChannelModal() {
    final handleCtrl = TextEditingController();
    final csvCtrl = TextEditingController();
    bool busy = false;
    String? modalError;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          backgroundColor: const Color(0xFF212121),
          title: const Text('Tambah Channel Follower / Import Excel CSV'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '1. Tambah 1 Channel (@handle, Link Channel, atau ID UC...):',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: handleCtrl,
                          decoration: const InputDecoration(
                            hintText: 'Contoh: @FerryIrwandi atau @RadityaDika',
                            filled: true,
                            fillColor: Color(0xFF121212),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF0033),
                          foregroundColor: Colors.white,
                        ),
                        onPressed: busy
                            ? null
                            : () async {
                                setModalState(() {
                                  busy = true;
                                  modalError = null;
                                });
                                try {
                                  if (isStandaloneMode) {
                                    await _standaloneAddAndSyncChannel(handleCtrl.text);
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    _applyLocalFilterAndPagination();
                                  } else {
                                    final res = await http.post(
                                      Uri.parse('$baseUrl/api/channels'),
                                      headers: {'Content-Type': 'application/json'},
                                      body: jsonEncode({'identifier': handleCtrl.text}),
                                    );
                                    if (res.statusCode == 200) {
                                      if (ctx.mounted) Navigator.pop(ctx);
                                      _refreshAll();
                                    } else {
                                      final err = jsonDecode(res.body);
                                      setModalState(() {
                                        modalError = err['detail'] ?? 'Gagal menambah channel';
                                        busy = false;
                                      });
                                    }
                                  }
                                } catch (e) {
                                  setModalState(() {
                                    modalError = e.toString().replaceAll('Exception: ', '');
                                    busy = false;
                                  });
                                }
                              },
                        child: const Text('Tambah'),
                      ),
                    ],
                  ),
                  const Divider(height: 28),
                  const Text(
                    '2. Atau Paste Banyak Channel dari Excel / CSV (1 baris per channel):',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Bisa paste daftar @handle atau isi file subscriptions.csv dari YouTube:',
                    style: TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: csvCtrl,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText: '@FajrulFx\n@FerryIrwandi\n@RadityaDika\natau UCxxxx,https://...,Nama Channel',
                      filled: true,
                      fillColor: Color(0xFF121212),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (modalError != null) ...[
                    const SizedBox(height: 12),
                    Text(modalError!, style: const TextStyle(color: Colors.redAccent)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Tutup'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.upload_file, size: 18),
              label: const Text('Import Daftar CSV'),
              onPressed: busy
                  ? null
                  : () async {
                      setModalState(() {
                        busy = true;
                        modalError = null;
                      });
                      if (isStandaloneMode) {
                        for (final line in csvCtrl.text.split('\n')) {
                          final trimmed = line.trim();
                          if (trimmed.isEmpty) continue;
                          final cols = trimmed.split(',');
                          if (cols[0].startsWith('UC') && cols.length >= 3) {
                            final cid = cols[0].trim();
                            final title = cols[2].trim();
                            _localChannels.removeWhere((c) => c['channel_id'] == cid);
                            _localChannels.add({
                              'channel_id': cid,
                              'title': title,
                              'handle': '',
                              'thumbnail_url': '',
                              'uploads_playlist_id': 'UU${cid.substring(2)}',
                              'source': 'csv',
                              'video_count': 0,
                            });
                          } else if (localApiKey.isNotEmpty) {
                            try {
                              await _standaloneAddAndSyncChannel(cols[0]);
                            } catch (_) {}
                          }
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                        _applyLocalFilterAndPagination();
                        return;
                      }
                      final res = await http.post(
                        Uri.parse('$baseUrl/api/channels/import-csv'),
                        headers: {'Content-Type': 'application/json'},
                        body: jsonEncode({'csv_text': csvCtrl.text}),
                      );
                      if (res.statusCode == 200) {
                        if (ctx.mounted) Navigator.pop(ctx);
                        _refreshAll();
                      } else {
                        final err = jsonDecode(res.body);
                        setModalState(() {
                          modalError = err['detail'] ?? 'Gagal import CSV';
                          busy = false;
                        });
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }

  void _showApiSettingsModal() {
    final apiKeyCtrl = TextEditingController(text: localApiKey);
    final oauthCtrl = TextEditingController(text: localOauthToken);
    final serverCtrl = TextEditingController(text: baseUrl);
    bool syncing = false;
    String? statusMsg;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          backgroundColor: const Color(0xFF212121),
          title: const Text('Pengaturan API YouTube (Gratis) & Mode Mandiri HP'),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isStandaloneMode ? const Color(0xFF1B3B2B) : const Color(0xFF1A2B3C),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isStandaloneMode ? Icons.phone_android : Icons.computer,
                          color: Colors.greenAccent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            isStandaloneMode
                                ? 'Mode Mandiri Aktif: Aplikasi jalan sendiri langsung di HP/Perangkat tanpa butuh Backend Python!'
                                : 'Mode Terhubung Backend Python ($baseUrl)',
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF181818),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '💡 Cara Dapat YouTube API Key Gratis (1 Menit, Rp 0):',
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amberAccent),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '1. Buka console.cloud.google.com -> Buat Project baru.\n'
                          '2. Buka menu "APIs & Services" -> "Library" -> Cari "YouTube Data API v3" -> Klik Enable.\n'
                          '3. Buka "Credentials" -> "Create Credentials" -> Pilih "API Key" -> Copy & Paste di bawah.',
                          style: TextStyle(fontSize: 12, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'YouTube API Key ${hasApiKey ? "(Sudah Terpasang)" : "(Belum Diisi)"}:',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: apiKeyCtrl,
                    decoration: const InputDecoration(
                      hintText: 'AIzaSy...',
                      filled: true,
                      fillColor: Color(0xFF121212),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'OAuth 2.0 Access Token (Opsional):',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: oauthCtrl,
                    decoration: const InputDecoration(
                      hintText: 'ya29.a0...',
                      filled: true,
                      fillColor: Color(0xFF121212),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Alamat Server Python (Opsional - kosongkan jika jalan mandiri di HP):',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: serverCtrl,
                    decoration: const InputDecoration(
                      hintText: 'http://127.0.0.1:8000',
                      filled: true,
                      fillColor: Color(0xFF121212),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  if (statusMsg != null) ...[
                    const SizedBox(height: 12),
                    Text(statusMsg!, style: const TextStyle(color: Colors.greenAccent)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                if (isStandaloneMode) {
                  _localChannels.removeWhere((c) => c['source'] == 'demo');
                  _localVideos.removeWhere((v) => v['is_demo'] == 1);
                  if (ctx.mounted) Navigator.pop(ctx);
                  _applyLocalFilterAndPagination();
                  return;
                }
                await http.delete(Uri.parse('$baseUrl/api/demo'));
                if (ctx.mounted) Navigator.pop(ctx);
                _refreshAll();
              },
              child: const Text('Hapus Data Demo', style: TextStyle(color: Colors.orangeAccent)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Tutup'),
            ),
            ElevatedButton(
              onPressed: syncing
                  ? null
                  : () async {
                      setState(() {
                        localApiKey = apiKeyCtrl.text.trim();
                        localOauthToken = oauthCtrl.text.trim();
                        hasApiKey = localApiKey.isNotEmpty;
                        baseUrl = serverCtrl.text.trim();
                      });
                      setModalState(() {
                        syncing = true;
                        statusMsg = 'Menyimpan & menyinkronkan video...';
                      });
                      if (!isStandaloneMode) {
                        try {
                          if (localApiKey.isNotEmpty || localOauthToken.isNotEmpty) {
                            await http.post(
                              Uri.parse('$baseUrl/api/settings'),
                              headers: {'Content-Type': 'application/json'},
                              body: jsonEncode({
                                'api_key': localApiKey,
                                'oauth_token': localOauthToken,
                              }),
                            );
                          }
                          await http.post(
                            Uri.parse('$baseUrl/api/sync'),
                            headers: {'Content-Type': 'application/json'},
                            body: jsonEncode({
                              'import_mode': localOauthToken.isNotEmpty ? 'subscriptions' : 'none',
                              'years_back': 4,
                            }),
                          );
                          setState(() {
                            refreshingYouTube = true;
                            refreshProgress = 2;
                            refreshReadyGreen = false;
                          });
                          _startRefreshPolling();
                        } catch (_) {}
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                      _refreshAll();
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF0033),
                foregroundColor: Colors.white,
              ),
              child: Text(syncing ? 'Menyinkronkan...' : 'Simpan & Sync Sekarang'),
            ),
          ],
        ),
      ),
    );
  }

  void _cycleSidebarMode() {
    final nextMode = sidebarMode == 'full'
        ? 'mini'
        : sidebarMode == 'mini'
            ? 'hidden'
            : 'full';
    setState(() => sidebarMode = nextMode);
    _saveUiPreferences(newSidebarMode: nextMode);
  }

  void _selectChannelTab(String cid) {
    final tabKey = cid.isEmpty ? 'home' : cid;
    final savedLimit = tabLimits[tabKey] ?? defaultLimit;
    final isMobileScreen = MediaQuery.of(context).size.width < 750;
    setState(() {
      selectedChannelId = cid;
      if (cid.isEmpty) {
        _searchCtrl.clear();
        searchQuery = '';
      }
      if (isMobileScreen && sidebarMode == 'full') {
        sidebarMode = 'hidden';
      }
      limit = (savedLimit == 25 || savedLimit == 50 || savedLimit == 100) ? savedLimit : 25;
      currentPage = 1;
    });
    _fetchVideos();
  }

  Widget _buildSearchInputBox({double height = 40, EdgeInsetsGeometry? margin}) {
    return Container(
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFF303030)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 14),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(
                hintText: 'Cari video dari follower/subscriptions...',
                border: InputBorder.none,
                isDense: true,
              ),
              onSubmitted: (val) {
                setState(() {
                  searchQuery = val;
                  currentPage = 1;
                });
                _fetchVideos();
              },
            ),
          ),
          if (searchQuery.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear, size: 18),
              onPressed: () {
                _searchCtrl.clear();
                setState(() {
                  searchQuery = '';
                  currentPage = 1;
                });
                _fetchVideos();
              },
            ),
          Container(
            width: 44,
            height: height,
            decoration: const BoxDecoration(
              color: Color(0xFF222222),
              borderRadius: BorderRadius.horizontal(right: Radius.circular(24)),
            ),
            child: IconButton(
              icon: const Icon(Icons.search, size: 19),
              onPressed: () {
                setState(() {
                  searchQuery = _searchCtrl.text;
                  currentPage = 1;
                });
                _fetchVideos();
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 750;
    final isCompactHeader = screenWidth < 1150;

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(isMobile ? 104 : 60),
        child: Material(
          color: const Color(0xFF0F0F0F),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: SafeArea(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Ubah Ukuran Sidebar (Penuh / Mini Ikon / Sembunyi)',
                        icon: const Icon(Icons.menu, color: Colors.white),
                        visualDensity: isMobile ? VisualDensity.compact : VisualDensity.standard,
                        onPressed: _cycleSidebarMode,
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF0033),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.play_arrow, color: Colors.white, size: 18),
                      ),
                      const SizedBox(width: 8),
                      if (!isCompactHeader)
                        const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: Text(
                            'YouTube Follower',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: -0.5),
                          ),
                        ),
                      if (!isMobile)
                        Expanded(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 480),
                            child: _buildSearchInputBox(
                              height: 40,
                              margin: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                          ),
                        )
                      else
                        const Spacer(),
                      // Tombol khusus Refresh YouTube (Merah = Belum Refresh, Lingkaran Muter + % = Loading Background, Hijau = 100% Selesai & Klik untuk Tampilkan Video Baru)
                      ElevatedButton.icon(
                        onPressed: _manualRefreshYouTube,
                        icon: refreshingYouTube
                            ? SizedBox(
                                width: 24,
                                height: 24,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: Colors.white,
                                      ),
                                    ),
                                    Text(
                                      '$refreshProgress%',
                                      style: const TextStyle(
                                        fontSize: 7.5,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : Icon(
                                refreshReadyGreen ? Icons.check_circle : Icons.refresh,
                                size: 17,
                              ),
                        label: Text(
                          refreshingYouTube
                              ? (screenWidth < 600 ? '$refreshProgress%' : 'Sync $refreshProgress%')
                              : refreshReadyGreen
                                  ? (screenWidth < 600 ? '100% Siap' : 'Refresh YouTube (100%)')
                                  : (screenWidth < 600 ? 'Refresh' : 'Refresh YouTube'),
                          style: TextStyle(fontSize: isMobile ? 12.5 : 13.5),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: refreshReadyGreen
                              ? const Color(0xFF2E7D32) // HIJAU saat 100% selesai sync
                              : const Color(0xFFFF0033), // MERAH saat belum refresh / sedang berjalan
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(horizontal: isMobile ? 10 : 12, vertical: 8),
                          visualDensity: isMobile ? VisualDensity.compact : VisualDensity.standard,
                        ),
                      ),
                      SizedBox(width: isMobile ? 2 : 6),
                      if (!isCompactHeader) ...[
                        OutlinedButton.icon(
                          onPressed: _exportExcelCsv,
                          icon: const Icon(Icons.table_view, size: 18, color: Colors.greenAccent),
                          label: const Text('Export Excel/CSV', style: TextStyle(color: Colors.white)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFF303030)),
                            backgroundColor: const Color(0xFF222222),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ] else
                        IconButton(
                          tooltip: 'Export Excel/CSV',
                          visualDensity: isMobile ? VisualDensity.compact : VisualDensity.standard,
                          onPressed: _exportExcelCsv,
                          icon: const Icon(Icons.table_view, color: Colors.greenAccent, size: 20),
                        ),
                      if (!isMobile)
                        ElevatedButton.icon(
                          onPressed: _showAddChannelModal,
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(isCompactHeader ? 'Channel' : 'Tambah Channel'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF272727),
                            foregroundColor: Colors.white,
                          ),
                        )
                      else
                        IconButton(
                          tooltip: 'Tambah Channel',
                          visualDensity: VisualDensity.compact,
                          onPressed: _showAddChannelModal,
                          icon: const Icon(Icons.person_add_alt_1, color: Colors.white, size: 20),
                        ),
                      IconButton(
                        tooltip: 'Pengaturan API & Sync',
                        visualDensity: isMobile ? VisualDensity.compact : VisualDensity.standard,
                        onPressed: _showApiSettingsModal,
                        icon: Icon(
                          Icons.settings,
                          size: isMobile ? 20 : 22,
                          color: hasApiKey ? Colors.greenAccent : Colors.amberAccent,
                        ),
                      ),
                    ],
                  ),
                  if (isMobile) ...[
                    const SizedBox(height: 4),
                    _buildSearchInputBox(height: 36),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (sidebarMode == 'mini' || (sidebarMode == 'full' && !isMobile))
                _buildSidebar(isNarrow: isMobile),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isMobile) _buildMobileQuickControlBar(),
                    _buildFilterAndSortHeader(isMobile),
                    Expanded(
                      child: loading
                          ? const Center(child: CircularProgressIndicator())
                          : LayoutBuilder(
                              builder: (ctx, constraints) =>
                                  _buildVideoGridWithPagination(constraints.maxWidth),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Di layar HP / jendela sempit, mode 'full' tampil sebagai panel overlay di atas kiri agar tidak menjepit daftar video
          if (isMobile && sidebarMode == 'full') ...[
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  setState(() => sidebarMode = 'hidden');
                  _saveUiPreferences(newSidebarMode: 'hidden');
                },
                child: Container(color: Colors.black54),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: _buildSidebar(isNarrow: false),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSidebar({bool forceFull = false, bool isNarrow = false}) {
    final isMini = !forceFull && sidebarMode == 'mini';
    if (isMini) {
      return SizedBox(
        width: isNarrow ? 62 : 72,
        child: Material(
          color: const Color(0xFF0F0F0F),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            children: [
              Tooltip(
                message: 'Lebarkan Sidebar',
                child: IconButton(
                  icon: const Icon(Icons.keyboard_double_arrow_right, color: Colors.white70),
                  onPressed: () {
                    setState(() => sidebarMode = 'full');
                    _saveUiPreferences(newSidebarMode: 'full');
                  },
                ),
              ),
              Tooltip(
                message: 'Semua Follower (${channels.length})',
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _selectChannelTab(''),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: selectedChannelId.isEmpty ? const Color(0xFF272727) : Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Column(
                      children: [
                        Icon(Icons.home_filled, color: Colors.white, size: 22),
                        SizedBox(height: 4),
                        Text('Semua', style: TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                ),
              ),
              const Divider(color: Color(0xFF272727), height: 18),
              ...channels.map((ch) {
                final cid = (ch['channel_id'] ?? '').toString();
                final title = (ch['title'] ?? '').toString();
                final watchedCount = int.tryParse((ch['watched_count'] ?? 0).toString()) ?? 0;
                final isSelected = selectedChannelId == cid;
                return Tooltip(
                  message: '$title ($watchedCount view)',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _selectChannelTab(cid),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0xFF272727) : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            CircleAvatar(
                              radius: 16,
                              backgroundColor: const Color(0xFF383838),
                              backgroundImage: (ch['thumbnail_url'] ?? '').toString().isNotEmpty
                                  ? NetworkImage(ch['thumbnail_url'])
                                  : null,
                              onBackgroundImageError: (ch['thumbnail_url'] ?? '').toString().isNotEmpty
                                  ? (_, _) {}
                                  : null,
                              child: Text(
                                title.isNotEmpty ? title[0] : '?',
                                style: const TextStyle(fontSize: 11, color: Colors.white70),
                              ),
                            ),
                            if (watchedCount > 0)
                              Positioned(
                                right: -4,
                                bottom: -4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E3A2F),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: const Color(0xFF2E7D32), width: 0.8),
                                  ),
                                  child: Text(
                                    '$watchedCount',
                                    style: const TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF81C784),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      width: isNarrow ? 190 : 240,
      child: Material(
        color: const Color(0xFF0F0F0F),
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          children: [
            Row(
              children: [
                Expanded(
                  child: _sidebarTile(
                    icon: Icons.home_filled,
                    title: 'Semua Follower (${channels.length})',
                    selected: selectedChannelId.isEmpty,
                    onTap: () => _selectChannelTab(''),
                  ),
                ),
                if (!forceFull)
                  IconButton(
                    tooltip: 'Kecilkan Sidebar (Mode Ikon)',
                    icon: const Icon(Icons.keyboard_double_arrow_left, size: 20, color: Colors.white60),
                    onPressed: () {
                      setState(() => sidebarMode = 'mini');
                      _saveUiPreferences(newSidebarMode: 'mini');
                    },
                  ),
              ],
            ),
            const Divider(color: Color(0xFF272727), height: 24),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                'Subscriptions ›',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
            ...channels.map((ch) {
              final cid = (ch['channel_id'] ?? '').toString();
              final title = (ch['title'] ?? '').toString();
              final watchedCount = int.tryParse((ch['watched_count'] ?? 0).toString()) ?? 0;
              final isSelected = selectedChannelId == cid;
              return InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => _selectChannelTab(cid),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF272727) : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: const Color(0xFF383838),
                        backgroundImage: (ch['thumbnail_url'] ?? '').toString().isNotEmpty
                            ? NetworkImage(ch['thumbnail_url'])
                            : null,
                        onBackgroundImageError: (ch['thumbnail_url'] ?? '').toString().isNotEmpty
                            ? (_, _) {}
                            : null,
                        child: Text(
                          title.isNotEmpty ? title[0] : '?',
                          style: const TextStyle(fontSize: 11, color: Colors.white70),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: watchedCount > 0 ? const Color(0xFF1E3A2F) : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '$watchedCount',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: watchedCount > 0 ? FontWeight.bold : FontWeight.normal,
                            color: watchedCount > 0 ? const Color(0xFF81C784) : Colors.white54,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
            const Divider(color: Color(0xFF272727), height: 28),
            _sidebarTile(
              icon: Icons.download_for_offline_outlined,
              title: 'Export Excel/CSV',
              selected: false,
              onTap: _exportExcelCsv,
            ),
            _sidebarTile(
              icon: Icons.sync,
              title: 'Sync & API Key',
              selected: false,
              onTap: _showApiSettingsModal,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidebarTile({
    required IconData icon,
    required String title,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF272727) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Colors.white),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileQuickControlBar() {
    String activeChannelName = 'Pilih Channel (${channels.length})';
    if (selectedChannelId.isNotEmpty) {
      for (final ch in channels) {
        if ((ch['channel_id'] ?? '').toString() == selectedChannelId) {
          activeChannelName = (ch['title'] ?? selectedChannelId).toString();
          break;
        }
      }
    }
    final isSidebarOpen = sidebarMode == 'full';

    return Container(
      color: const Color(0xFF0F0F0F),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      child: Row(
        children: [
          // Tombol Besar Kiri: Buka / Tutup Daftar Channel (Subscriptions)
          Expanded(
            child: SizedBox(
              height: 42,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isSidebarOpen
                      ? const Color(0xFFFF0033)
                      : selectedChannelId.isNotEmpty
                          ? const Color(0xFF1E3A2F)
                          : const Color(0xFF222222),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: isSidebarOpen
                          ? const Color(0xFFFF4E4E)
                          : selectedChannelId.isNotEmpty
                              ? const Color(0xFF2E7D32)
                              : const Color(0xFF3A3A3A),
                    ),
                  ),
                ),
                icon: Icon(
                  isSidebarOpen ? Icons.close : Icons.subscriptions_outlined,
                  size: 18,
                  color: isSidebarOpen ? Colors.white : Colors.redAccent,
                ),
                label: Text(
                  isSidebarOpen ? 'Tutup Channel' : activeChannelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
                onPressed: () {
                  final next = sidebarMode == 'full' ? 'hidden' : 'full';
                  setState(() => sidebarMode = next);
                  _saveUiPreferences(newSidebarMode: next);
                },
              ),
            ),
          ),
          // Tombol cepat kembali ke Semua Follower jika sedang memilih 1 channel atau mencari teks
          if (selectedChannelId.isNotEmpty || searchQuery.isNotEmpty) ...[
            const SizedBox(width: 6),
            SizedBox(
              height: 42,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xFF222222),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  side: const BorderSide(color: Color(0xFF3A3A3A)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => _selectChannelTab(''),
                child: const Icon(Icons.home_filled, size: 19, color: Colors.white),
              ),
            ),
          ],
          const SizedBox(width: 8),
          // Tombol Besar Kanan: Buka Filter / Tutup Filter (Selalu diam di tempat, mudah ditekan jempol)
          Expanded(
            child: SizedBox(
              height: 42,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: filterMinimized
                      ? const Color(0xFF222222)
                      : const Color(0xFF332610),
                  foregroundColor: Colors.amberAccent,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(
                      color: filterMinimized
                          ? const Color(0xFF3A3A3A)
                          : Colors.amberAccent,
                    ),
                  ),
                ),
                icon: Icon(
                  filterMinimized ? Icons.tune : Icons.keyboard_arrow_up_rounded,
                  size: 19,
                  color: Colors.amberAccent,
                ),
                label: Text(
                  filterMinimized ? 'Buka Filter' : 'Tutup Filter',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.amberAccent,
                  ),
                ),
                onPressed: () {
                  final next = !filterMinimized;
                  setState(() => filterMinimized = next);
                  _saveUiPreferences(newFilterMinimized: next);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterAndSortHeader(bool isMobile) {
    final periods = [
      ('all', 'Semua Waktu'),
      ('week', 'Minggu Ini'),
      ('month', 'Bulan Ini'),
      ('year', 'Tahun Ini'),
    ];
    final isCustomYear = period.endsWith('y') && int.tryParse(period.substring(0, period.length - 1)) != null;

    final sorts = [
      ('views', '🔥 View Terbanyak'),
      ('likes', '👍 Like Terbanyak'),
      ('time', '🕒 Waktu Upload'),
    ];

    if (filterMinimized) {
      final sortLabel = sorts.firstWhere((s) => s.$1 == sortBy, orElse: () => sorts.last).$2;
      final periodLabel = isCustomYear
          ? '${period.substring(0, period.length - 1)} Tahun Lalu'
          : periods.firstWhere((p) => p.$1 == period, orElse: () => periods.first).$2;
      return Container(
        color: const Color(0xFF0F0F0F),
        padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 16, vertical: isMobile ? 2 : 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$sortLabel  •  $periodLabel  •  Durasi: ${_formatMinutesLabel(durationRange.start.round())} – ${_formatMinutesLabel(durationRange.end.round(), isMax: true)}  •  $limit Video/Tab  •  Total: $totalVideos video',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ),
            if (!isMobile)
              TextButton.icon(
                icon: const Icon(Icons.expand_more, size: 18, color: Colors.amberAccent),
                label: const Text('Buka Filter', style: TextStyle(fontSize: 12.5, color: Colors.amberAccent)),
                onPressed: () {
                  setState(() => filterMinimized = false);
                  _saveUiPreferences(newFilterMinimized: false);
                },
              ),
          ],
        ),
      );
    }

    final row1Children = <Widget>[
      const Text(
        'Urutkan:',
        style: TextStyle(fontSize: 13, color: Colors.white70, fontWeight: FontWeight.w600),
      ),
      ...sorts.map((s) {
        final active = sortBy == s.$1;
        return ChoiceChip(
          label: Text(s.$2),
          selected: active,
          selectedColor: Colors.white,
          backgroundColor: const Color(0xFF272727),
          labelStyle: TextStyle(
            color: active ? Colors.black : Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
          onSelected: (_) {
            setState(() {
              sortBy = s.$1;
              currentPage = 1;
            });
            _fetchVideos();
          },
        );
      }),
      const SizedBox(width: 8),
      const Text(
        'Tampil per Tab (Permanen):',
        style: TextStyle(fontSize: 13, color: Colors.white70, fontWeight: FontWeight.w600),
      ),
      ...[25, 50, 100].map((val) {
        final active = limit == val;
        return ChoiceChip(
          label: Text('$val Video'),
          selected: active,
          selectedColor: const Color(0xFFFF0033),
          backgroundColor: const Color(0xFF272727),
          labelStyle: TextStyle(
            color: Colors.white,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            fontSize: 12.5,
          ),
          onSelected: (_) {
            setState(() {
              limit = val;
              currentPage = 1;
            });
            _saveUiPreferences(newLimit: val);
            _fetchVideos();
          },
        );
      }),
      Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Text(
          'Total: $totalVideos video',
          style: const TextStyle(fontSize: 12.5, color: Colors.white54),
        ),
      ),
      if (!isMobile)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            side: const BorderSide(color: Color(0xFF383838)),
          ),
          icon: const Icon(Icons.expand_less, size: 16, color: Colors.amberAccent),
          label: const Text('Minimal', style: TextStyle(fontSize: 12, color: Colors.amberAccent)),
          onPressed: () {
            setState(() => filterMinimized = true);
            _saveUiPreferences(newFilterMinimized: true);
          },
        ),
    ];

    final row2Children = <Widget>[
      ...periods.map((p) {
        final active = period == p.$1;
        return ChoiceChip(
          label: Text(p.$2),
          selected: active,
          selectedColor: Colors.white,
          backgroundColor: const Color(0xFF272727),
          labelStyle: TextStyle(
            color: active ? Colors.black : Colors.white,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            fontSize: 13,
          ),
          onSelected: (_) {
            _yearInputCtrl.clear();
            setState(() {
              period = p.$1;
              currentPage = 1;
            });
            _fetchVideos();
          },
        );
      }),
      // Input Angka Tahun Lalu (misal ketik 3 = 3 Tahun Lalu)
      Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isCustomYear ? const Color(0xFF3A1818) : const Color(0xFF272727),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isCustomYear ? const Color(0xFFFF0033) : const Color(0xFF444444),
            width: isCustomYear ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 44,
              child: TextField(
                controller: _yearInputCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                decoration: const InputDecoration(
                  hintText: '2, 3..',
                  hintStyle: TextStyle(fontSize: 12, color: Colors.white38),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 6),
                ),
                onChanged: (val) {
                  final trimmed = val.trim();
                  final parsed = int.tryParse(trimmed);
                  if (parsed != null && parsed >= 1) {
                    setState(() {
                      period = '${parsed}y';
                      currentPage = 1;
                    });
                    _fetchVideos();
                  } else if (trimmed.isEmpty && isCustomYear) {
                    setState(() {
                      period = 'all';
                      currentPage = 1;
                    });
                    _fetchVideos();
                  }
                },
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Tahun Lalu',
              style: TextStyle(
                fontSize: 13,
                fontWeight: isCustomYear ? FontWeight.bold : FontWeight.normal,
                color: isCustomYear ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    ];

    return Container(
      color: const Color(0xFF0F0F0F),
      padding: EdgeInsets.fromLTRB(isMobile ? 10 : 16, 4, isMobile ? 10 : 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isMobile)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < row1Children.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    row1Children[i],
                  ],
                ],
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: row1Children,
            ),
          const SizedBox(height: 6),
          if (isMobile)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < row2Children.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    row2Children[i],
                  ],
                ],
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: row2Children,
            ),
          const SizedBox(height: 6),
          // Baris 3: Garis Slider 2 Lingkaran Filter Durasi Video (0/1 Menit s/d 2 Jam, geser per 1 menit)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF181818),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2C2C2C)),
            ),
            child: Row(
              children: [
                const Icon(Icons.timer_outlined, size: 18, color: Color(0xFFFF0033)),
                const SizedBox(width: 8),
                Text(
                  isMobile
                      ? _formatMinutesLabel(durationRange.start.round())
                      : 'Durasi: Minimal ${_formatMinutesLabel(durationRange.start.round())}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFFFF0033),
                      inactiveTrackColor: const Color(0xFF383838),
                      thumbColor: Colors.white,
                      overlayColor: const Color(0x33FF0033),
                      rangeThumbShape: const RoundRangeSliderThumbShape(enabledThumbRadius: 9),
                    ),
                    child: RangeSlider(
                      values: durationRange,
                      min: 0,
                      max: 120,
                      divisions: 120,
                      labels: RangeLabels(
                        _formatMinutesLabel(durationRange.start.round()),
                        _formatMinutesLabel(durationRange.end.round(), isMax: true),
                      ),
                      onChanged: (RangeValues values) {
                        setState(() {
                          durationRange = values;
                        });
                      },
                      onChangeEnd: (_) {
                        setState(() {
                          currentPage = 1;
                        });
                        _fetchVideos();
                      },
                    ),
                  ),
                ),
                Text(
                  isMobile
                      ? (durationRange.end.round() >= 120
                          ? '2 Jam+'
                          : _formatMinutesLabel(durationRange.end.round()))
                      : 'Maksimal ${_formatMinutesLabel(durationRange.end.round(), isMax: true)}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                if (durationRange.start.round() > 0 || durationRange.end.round() < 120) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () {
                      setState(() {
                        durationRange = const RangeValues(0, 120);
                        currentPage = 1;
                      });
                      _fetchVideos();
                    },
                    child: const Text('Reset', style: TextStyle(fontSize: 12, color: Colors.amberAccent)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaginationTabsBar() {
    if (totalPages <= 1 && totalVideos <= limit) {
      return const SizedBox.shrink();
    }
    final safeCurrent = currentPage.clamp(1, totalPages);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            'Navigasi Tab:',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white70),
          ),
          // Tombol Kiri (Sebelumnya)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF272727),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onPressed: safeCurrent > 1
                ? () {
                    setState(() => currentPage = safeCurrent - 1);
                    _fetchVideos();
                  }
                : null,
            icon: const Icon(Icons.chevron_left, size: 18),
            label: const Text('Sebelumnya'),
          ),
          // Dropdown Daftar Tab Halaman
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF212121),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFF0033)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: safeCurrent,
                dropdownColor: const Color(0xFF282828),
                icon: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.arrow_drop_down, color: Colors.white),
                ),
                style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600),
                items: List.generate(totalPages, (idx) {
                  final pageNum = idx + 1;
                  final startItem = idx * limit + 1;
                  final endItem = ((idx + 1) * limit > totalVideos) ? totalVideos : (idx + 1) * limit;
                  return DropdownMenuItem<int>(
                    value: pageNum,
                    child: Text('Tab $pageNum ($startItem–$endItem)'),
                  );
                }),
                onChanged: (int? selectedPage) {
                  if (selectedPage != null && selectedPage != currentPage) {
                    setState(() => currentPage = selectedPage);
                    _fetchVideos();
                  }
                },
              ),
            ),
          ),
          // Tombol Kanan (Berikutnya)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF272727),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onPressed: safeCurrent < totalPages
                ? () {
                    setState(() => currentPage = safeCurrent + 1);
                    _fetchVideos();
                  }
                : null,
            icon: const Icon(Icons.chevron_right, size: 18),
            label: const Text('Berikutnya'),
          ),
          Text(
            'Halaman $safeCurrent dari $totalPages ($totalVideos video)',
            style: const TextStyle(fontSize: 12.5, color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoGridWithPagination(double screenWidth) {
    if (videos.isEmpty) {
      return const Center(
        child: Text(
          'Tidak ada video pada filter waktu / pencarian ini.',
          style: TextStyle(color: Colors.white60, fontSize: 15),
        ),
      );
    }

    int crossAxisCount = 3;
    if (screenWidth < 650) {
      crossAxisCount = 1;
    } else if (screenWidth < 1000) {
      crossAxisCount = 2;
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildPaginationTabsBar()),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: 16,
              mainAxisSpacing: 22,
              childAspectRatio: 1.12,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final v = videos[index];
                return _buildVideoCard(v);
              },
              childCount: videos.length,
            ),
          ),
        ),
        SliverToBoxAdapter(child: _buildPaginationTabsBar()),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }

  Widget _buildVideoCard(Map<String, dynamic> v) {
    final title = (v['title'] ?? '').toString();
    final channelId = (v['channel_id'] ?? '').toString();
    final channelTitle = (v['channel_title'] ?? '').toString();
    final thumbUrl = (v['thumbnail_url'] ?? '').toString();
    final channelThumb = (v['channel_thumbnail'] ?? '').toString();
    final views = (v['view_count'] ?? 0) as int;
    final likes = (v['like_count'] ?? 0) as int;
    final publishedAt = (v['published_at'] ?? '').toString();
    final duration = (v['duration'] ?? '').toString();
    final watchedCount = _getCreatorWatchedCount(channelId, v);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openYouTubeVideo(v),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    thumbUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      color: const Color(0xFF272727),
                      child: const Center(child: Icon(Icons.ondemand_video, size: 42, color: Colors.white38)),
                    ),
                  ),
                ),
                if (duration.isNotEmpty)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        duration,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFF383838),
                backgroundImage: channelThumb.isNotEmpty ? NetworkImage(channelThumb) : null,
                onBackgroundImageError: channelThumb.isNotEmpty ? (_, _) {} : null,
                child: Text(
                  channelTitle.isNotEmpty ? channelTitle[0] : '?',
                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            channelTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFFAAAAAA),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.check_circle, size: 13, color: Color(0xFFAAAAAA)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${_formatCompactNumber(views)} views',
                          style: const TextStyle(fontSize: 12.5, color: Color(0xFFAAAAAA)),
                        ),
                        const Text('•', style: TextStyle(fontSize: 12.5, color: Color(0xFFAAAAAA))),
                        Text(
                          _formatTimeAgo(publishedAt),
                          style: const TextStyle(fontSize: 12.5, color: Color(0xFFAAAAAA)),
                        ),
                        const Text('•', style: TextStyle(fontSize: 12.5, color: Color(0xFFAAAAAA))),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF272727),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '👍 ${_formatCompactNumber(likes)} likes',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: watchedCount > 0 ? const Color(0xFF1E3A2F) : const Color(0xFF272727),
                            borderRadius: BorderRadius.circular(4),
                            border: watchedCount > 0
                                ? Border.all(color: const Color(0xFF2E7D32), width: 0.8)
                                : null,
                          ),
                          child: Text(
                            '▶ $watchedCount view',
                            style: TextStyle(
                              fontSize: 12,
                              color: watchedCount > 0 ? const Color(0xFF81C784) : Colors.white70,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Titik 3 (⋮) di pojok kanan bawah kartu video (Unsubscribe di dalam titik 3 dengan tekan & tahan beberapa detik)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20, color: Colors.white70),
                color: const Color(0xFF282828),
                tooltip: 'Opsi Creator',
                onSelected: (value) {
                  if (value == 'filter_channel') {
                    setState(() {
                      selectedChannelId = channelId;
                      currentPage = 1;
                    });
                    _fetchVideos();
                  } else if (value == 'open_yt') {
                    _openYouTubeVideo(v);
                  }
                },
                itemBuilder: (popupCtx) => [
                  PopupMenuItem<String>(
                    enabled: false, // Agar klik biasa tidak langsung menutup menu; harus ditahan (hold) beberapa detik
                    padding: EdgeInsets.zero,
                    child: _HoldToUnsubscribeMenuItem(
                      channelTitle: channelTitle,
                      fastModeActive: skipUnsubscribeConfirmUntil != null &&
                          DateTime.now().isBefore(skipUnsubscribeConfirmUntil!),
                      onHoldCompleted: () {
                        Navigator.of(popupCtx).pop();
                        _confirmOrUnsubscribeChannel(channelId, channelTitle);
                      },
                    ),
                  ),
                  PopupMenuItem(
                    value: 'filter_channel',
                    child: Row(
                      children: [
                        const Icon(Icons.video_library_outlined, color: Colors.white70, size: 18),
                        const SizedBox(width: 10),
                        Expanded(child: Text('Lihat Semua Video $channelTitle')),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'open_yt',
                    child: Row(
                      children: [
                        Icon(Icons.open_in_new, color: Colors.white70, size: 18),
                        SizedBox(width: 10),
                        Text('Tonton di YouTube'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HoldToUnsubscribeMenuItem extends StatefulWidget {
  final String channelTitle;
  final bool fastModeActive;
  final VoidCallback onHoldCompleted;

  const _HoldToUnsubscribeMenuItem({
    required this.channelTitle,
    required this.fastModeActive,
    required this.onHoldCompleted,
  });

  @override
  State<_HoldToUnsubscribeMenuItem> createState() => _HoldToUnsubscribeMenuItemState();
}

class _HoldToUnsubscribeMenuItemState extends State<_HoldToUnsubscribeMenuItem> {
  Timer? _holdTimer;
  double _holdProgress = 0.0; // 0.0 .. 1.0 (1 detik)
  bool _holding = false;

  void _startHolding() {
    _holdTimer?.cancel();
    setState(() {
      _holding = true;
      _holdProgress = 0.05;
    });
    const stepMs = 50;
    const totalMs = 1000; // Tahan 1 detik
    _holdTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final next = _holdProgress + (stepMs / totalMs);
      if (next >= 1.0) {
        timer.cancel();
        setState(() {
          _holdProgress = 1.0;
          _holding = false;
        });
        widget.onHoldCompleted();
      } else {
        setState(() {
          _holdProgress = next;
        });
      }
    });
  }

  void _cancelHolding() {
    _holdTimer?.cancel();
    if (mounted && _holdProgress < 1.0) {
      setState(() {
        _holding = false;
        _holdProgress = 0.0;
      });
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pct = (_holdProgress * 100).round();
    return Listener(
      onPointerDown: (_) => _startHolding(),
      onPointerUp: (_) => _cancelHolding(),
      onPointerCancel: (_) => _cancelHolding(),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: _holding ? const Color(0xFF4A1818) : Colors.transparent,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _holding
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: _holdProgress,
                                strokeWidth: 2.2,
                                color: const Color(0xFFFF4E4E),
                                backgroundColor: Colors.white24,
                              ),
                              Text(
                                '$pct%',
                                style: const TextStyle(
                                  fontSize: 7.5,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        )
                      : const Icon(Icons.person_remove, color: Color(0xFFFF4E4E), size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Unsubscribe "${widget.channelTitle}"',
                      style: const TextStyle(
                        color: Color(0xFFFF6B6B),
                        fontWeight: FontWeight.w600,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                _holding
                    ? 'Tahan terus... ($pct%)'
                    : (widget.fastModeActive
                        ? '⚡ Tahan 1 detik untuk langsung Unsubscribe'
                        : '👆 Tahan 1 detik untuk Unsubscribe'),
                style: TextStyle(
                  fontSize: 11,
                  color: _holding ? Colors.amberAccent : Colors.white54,
                ),
              ),
              if (_holding) ...[
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _holdProgress,
                    minHeight: 4,
                    color: const Color(0xFFFF0033),
                    backgroundColor: Colors.white24,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
