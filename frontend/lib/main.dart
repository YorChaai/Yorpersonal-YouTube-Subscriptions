import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
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
  String baseUrl = Uri.base.port == 8000
      ? Uri.base.origin
      : 'http://127.0.0.1:8000';
  String sidebarMode =
      'full'; // 'full' (240px) | 'mini' (72px ikon saja) | 'hidden' (0px)
  bool filterMinimized =
      false; // Opsi meminimalkan bar urutan/filter agar area video lebih luas
  bool loading = false;
  bool refreshingYouTube = false;
  int refreshProgress = 0; // 0..100 persen
  bool refreshReadyGreen =
      false; // True jika 100% selesai sync dan tombol berubah HIJAU siap diklik
  int refreshNewVideosCount = 0;
  Timer? _refreshPollTimer;
  bool syncingUsb = false;
  int usbSyncProgress = 0; // 0..100 persen
  bool usbSyncReadyGreen = false;
  Timer? _usbSyncResetTimer;
  bool isStandaloneMode =
      false; // Otomatis aktif di HP jika tanpa backend Python
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // Filter & Pagination State
  String sortBy = 'time'; // 'views' | 'likes' | 'time'
  String period =
      'all'; // 'all' | 'week' | 'month' | 'year' | '2y' | '3y' | '4y'
  String selectedRegion = 'all'; // 'all' | 'Nasional' | 'Internasional'
  String selectedChannelId = '';
  String searchQuery = '';
  bool get _isHpDevice =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  String get _deviceType => _isHpDevice ? 'hp' : 'laptop';
  int limit = 25; // 25 | 50 | 100
  int defaultLimit = 25;
  Map<String, int> tabLimits =
      {}; // Penyimpanan permanen jumlah video per tab/channel
  int currentPage = 1;
  int totalVideos = 0;
  int totalPages = 1;
  RangeValues durationRange = const RangeValues(
    0,
    120,
  ); // 0 menit s/d 120 menit (2 jam)
  Thumb? _activeDurationThumb;
  DateTime?
  skipUnsubscribeConfirmUntil; // Mode 10 menit langsung Unsubscribe tanpa konfirmasi

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
    _usbSyncResetTimer?.cancel();
    _searchCtrl.dispose();
    _yearInputCtrl.dispose();
    super.dispose();
  }

  void _initLocalSeedData() {
    if (_localChannels.isNotEmpty) return;
    final now = DateTime.now().toUtc();
    final demoChannels = [
      (
        'UC_demo_fajrul',
        'Fajrul Fx',
        '@FajrulFx',
        'https://i.ytimg.com/vi/M7lc1UVf-VE/hqdefault.jpg',
      ),
      (
        'UC_demo_anim',
        'Animated History',
        '@AnimatedHistory',
        'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg',
      ),
      (
        'UC_demo_malaka',
        'MALAKA',
        '@malaka_project',
        'https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg',
      ),
      (
        'UC_demo_radit',
        'Raditya Dika',
        '@RadityaDika',
        'https://i.ytimg.com/vi/9bZkp7q19f0/hqdefault.jpg',
      ),
      (
        'UC_demo_justin',
        'Justin Sung',
        '@JustinSung',
        'https://i.ytimg.com/vi/kJQP7kiw5Fk/hqdefault.jpg',
      ),
      (
        'UC_demo_ferry',
        'Ferry Irwandi',
        '@FerryIrwandi',
        'https://i.ytimg.com/vi/RgKAFK5djSk/hqdefault.jpg',
      ),
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
      'dQw4w9WgXcQ',
      'M7lc1UVf-VE',
      'jNQXAC9IVRw',
      '9bZkp7q19f0',
      'kJQP7kiw5Fk',
      'RgKAFK5djSk',
      'OPf0YbXqDm0',
      'fJ9rUzIMcZQ',
      'CevxZvSJLk8',
      'JGwWNGJdvx8',
      'YQHsXMglC9A',
      'hT_nvWreIhg',
    ];

    final samples = [
      // Minggu ini (1 - 6 hari lalu)
      (
        'UC_demo_ferry',
        'Ferry Irwandi',
        'Kenapa Bank Terbesar di Paraguay Bisa Kolaps? - Kasus Ueno',
        1,
        512000,
        41200,
        '18:13',
      ),
      (
        'UC_demo_fajrul',
        'Fajrul Fx',
        'Apa yang Terjadi pada Tubuh Saat Makan Sekali Sehari (Jam demi Jam)',
        2,
        440000,
        32900,
        '10:18',
      ),
      (
        'UC_demo_malaka',
        'MALAKA',
        'Cara Berpikir Kritis di Era Banjir Informasi (Minggu Ini)',
        3,
        690000,
        58100,
        '24:14',
      ),
      (
        'UC_demo_radit',
        'Raditya Dika',
        'Stand Up Comedy Spesial Minggu Ini: Cerita Finansial',
        4,
        920000,
        74500,
        '31:45',
      ),
      (
        'UC_demo_justin',
        'Justin Sung',
        'How to Study 3x Faster Without Memorizing (This Week)',
        5,
        310000,
        27400,
        '16:20',
      ),
      (
        'UC_demo_anim',
        'Animated History',
        'Sejarah Runtuhnya Kekaisaran Romawi dalam 15 Menit',
        6,
        780000,
        63000,
        '15:08',
      ),
      // Bulan ini (9 - 27 hari lalu)
      (
        'UC_demo_ferry',
        'Ferry Irwandi',
        'Bedah Logika & Stoikisme Untuk Anak Muda (Bulan Ini)',
        9,
        830000,
        69300,
        '28:40',
      ),
      (
        'UC_demo_malaka',
        'MALAKA',
        'Pendidikan & Masa Depan Kerja di Indonesia',
        12,
        1120000,
        94000,
        '42:10',
      ),
      (
        'UC_demo_radit',
        'Raditya Dika',
        'Podcast Cerita Horor Kantor Baru (Bulan Ini)',
        15,
        1450000,
        112000,
        '54:20',
      ),
      (
        'UC_demo_fajrul',
        'Fajrul Fx',
        'Eksperimen Sains: Tidur 4 Jam vs 8 Jam Selama Sebulan',
        19,
        610000,
        48700,
        '14:55',
      ),
      (
        'UC_demo_justin',
        'Justin Sung',
        'Mind Mapping Technique for Deep Understanding',
        23,
        495000,
        39100,
        '21:12',
      ),
      (
        'UC_demo_anim',
        'Animated History',
        'Perang Dunia II dari Sudut Pandang Ekonomi',
        27,
        950000,
        81200,
        '19:33',
      ),
      // Tahun ini (65 - 310 hari lalu)
      (
        'UC_demo_radit',
        'Raditya Dika',
        'Tur Rumah Baru & Studio Podcast (Tahun Ini)',
        65,
        2850000,
        198000,
        '38:15',
      ),
      (
        'UC_demo_ferry',
        'Ferry Irwandi',
        'Investigasi Fenomena Judi Online & Psikologi Bandar',
        110,
        3600000,
        285000,
        '35:48',
      ),
      (
        'UC_demo_malaka',
        'MALAKA',
        'Monolog: Kenapa Kita Sering Merasa Tertinggal?',
        160,
        1940000,
        164000,
        '29:10',
      ),
      (
        'UC_demo_fajrul',
        'Fajrul Fx',
        'Fisika Kuantum Dijelaskan dengan Bahasa Tongkrongan',
        210,
        1150000,
        97500,
        '17:42',
      ),
      (
        'UC_demo_justin',
        'Justin Sung',
        'Complete Guide to Self-Regulated Learning (This Year)',
        260,
        870000,
        71000,
        '26:05',
      ),
      (
        'UC_demo_anim',
        'Animated History',
        'Kebangkitan dan Keruntuhan Majapahit (Animasi Lengkap)',
        310,
        2210000,
        175000,
        '33:20',
      ),
      // 2 Tahun Lalu (420 - 690 hari lalu)
      (
        'UC_demo_ferry',
        'Ferry Irwandi',
        'Revolusi Industri Kreatif & Konten (2 Tahun Lalu)',
        420,
        1420000,
        108000,
        '22:18',
      ),
      (
        'UC_demo_radit',
        'Raditya Dika',
        'Belajar Investasi dari Nol untuk Pemula (2 Tahun Lalu)',
        480,
        3100000,
        240000,
        '41:00',
      ),
      (
        'UC_demo_malaka',
        'MALAKA',
        'Episode Perdana: Membangun Manusia Merdeka (2 Tahun Lalu)',
        530,
        2540000,
        215000,
        '47:30',
      ),
      (
        'UC_demo_fajrul',
        'Fajrul Fx',
        'Sejarah Penemuan Listrik & Konflik Tesla vs Edison',
        590,
        980000,
        82400,
        '16:11',
      ),
      (
        'UC_demo_justin',
        'Justin Sung',
        'Why Re-reading Notes Does Not Work (2 Years Ago)',
        640,
        1320000,
        104000,
        '15:45',
      ),
      (
        'UC_demo_anim',
        'Animated History',
        'Peta Perdagangan Jalur Sutra Kuno (2 Tahun Lalu)',
        690,
        1650000,
        129000,
        '20:04',
      ),
      // 3 Tahun Lalu (790 - 1060 hari lalu)
      (
        'UC_demo_radit',
        'Raditya Dika',
        'Cerita Masa Kuliah di Luar Negeri (3 Tahun Lalu)',
        790,
        4200000,
        310000,
        '27:50',
      ),
      (
        'UC_demo_ferry',
        'Ferry Irwandi',
        'Mindset Keuangan di Usia 20-an (3 Tahun Lalu)',
        850,
        1780000,
        142000,
        '19:25',
      ),
      (
        'UC_demo_fajrul',
        'Fajrul Fx',
        'Bagaimana Cara Kerja Mesin Waktu Menurut Teori Relativitas?',
        910,
        1540000,
        126000,
        '14:30',
      ),
      (
        'UC_demo_justin',
        'Justin Sung',
        'Top 1% Student Study Routine (3 Years Ago)',
        960,
        2450000,
        195000,
        '18:55',
      ),
      (
        'UC_demo_anim',
        'Animated History',
        'Sejarah Nusantara Sebelum Era Kolonial (3 Tahun Lalu)',
        1020,
        2890000,
        224000,
        '25:40',
      ),
      (
        'UC_demo_malaka',
        'MALAKA',
        'Diskusi Filsafat Klasik untuk Kehidupan Modern (3 Tahun Lalu)',
        1060,
        1190000,
        96000,
        '36:12',
      ),
      // 4 Tahun Lalu (1150 - 1430 hari lalu)
      (
        'UC_demo_radit',
        'Raditya Dika',
        'Bongkar Rahasia Menulis Buku & Skenario Film (4 Tahun Lalu)',
        1150,
        3850000,
        290000,
        '34:10',
      ),
      (
        'UC_demo_fajrul',
        'Fajrul Fx',
        'Video Sains Pertama: Kenapa Langit Berwarna Biru? (4 Tahun Lalu)',
        1220,
        890000,
        73000,
        '11:20',
      ),
      (
        'UC_demo_justin',
        'Justin Sung',
        'How I Transitioned from Medical School to Teaching (4 Years Ago)',
        1290,
        1620000,
        134000,
        '22:00',
      ),
      (
        'UC_demo_anim',
        'Animated History',
        'Asal Usul Peradaban Mesopotamia (4 Tahun Lalu)',
        1350,
        3120000,
        248000,
        '21:45',
      ),
      (
        'UC_demo_ferry',
        'Ferry Irwandi',
        'Belajar Videografi & Storytelling Sinematik (4 Tahun Lalu)',
        1400,
        1250000,
        99500,
        '16:50',
      ),
      (
        'UC_demo_malaka',
        'MALAKA',
        'Arsip Pemikiran: Membaca Ulang Sejarah Bangsa (4 Tahun Lalu)',
        1430,
        1410000,
        115000,
        '39:05',
      ),
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
            ..addAll(
              bundledChs.map((e) => Map<String, dynamic>.from(e as Map)),
            );
          _sortChannelsByWatchedDesc(_localChannels);
        }
        if (bundledVids.isNotEmpty) {
          _localVideos
            ..clear()
            ..addAll(
              bundledVids.map((e) => Map<String, dynamic>.from(e as Map)),
            );
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
      // The bundled file is only a seed. A standalone phone must restore its
      // own database after the seed has been loaded, otherwise every launch
      // discards videos fetched by Refresh.
      if (_isHpDevice) {
        final db = await _openStandaloneDatabase();
        final savedChannels = await db.query('channels', orderBy: 'rowid');
        final savedVideos = await db.query('videos', orderBy: 'rowid');
        if (savedChannels.isNotEmpty || savedVideos.isNotEmpty) {
          _localChannels
            ..clear()
            ..addAll(
              savedChannels.map(
                (e) => jsonDecode(e['data']! as String) as Map<String, dynamic>,
              ),
            );
          _localVideos
            ..clear()
            ..addAll(
              savedVideos.map(
                (e) => jsonDecode(e['data']! as String) as Map<String, dynamic>,
              ),
            );
        }
      }
    } catch (_) {}
  }

  Future<Database> _openStandaloneDatabase() => openDatabase(
    'standalone_cache.db',
    version: 1,
    onCreate: (db, version) async {
      await db.execute(
        'CREATE TABLE channels (id TEXT PRIMARY KEY, data TEXT NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE videos (id TEXT PRIMARY KEY, data TEXT NOT NULL)',
      );
    },
  );

  Future<void> _saveStandaloneData() async {
    if (!_isHpDevice) return;
    try {
      final db = await _openStandaloneDatabase();
      await db.transaction((txn) async {
        await txn.delete('channels');
        await txn.delete('videos');
        final channelBatch = txn.batch();
        for (final channel in _localChannels) {
          channelBatch.insert('channels', {
            'id': (channel['channel_id'] ?? '').toString(),
            'data': jsonEncode(channel),
          });
        }
        await channelBatch.commit(noResult: true);
        final videoBatch = txn.batch();
        for (final video in _localVideos) {
          videoBatch.insert('videos', {
            'id': (video['video_id'] ?? '').toString(),
            'data': jsonEncode(video),
          });
        }
        await videoBatch.commit(noResult: true);
      });
    } catch (_) {
      // Keep the current session usable if device storage is temporarily unavailable.
    }
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
    } else if (period.endsWith('y') &&
        int.tryParse(period.substring(0, period.length - 1)) != null) {
      final yrs = int.parse(period.substring(0, period.length - 1));
      if (yrs >= 1) {
        startIso = now.subtract(Duration(days: 365 * yrs)).toIso8601String();
        if (yrs > 1) {
          endIso = now
              .subtract(Duration(days: 365 * (yrs - 1)))
              .toIso8601String();
        }
      }
    }

    final qLower = searchQuery.trim().toLowerCase();
    final minSec = durationRange.start.round() * 60;
    final maxSec = durationRange.end.round() * 60;
    final filtered = _localVideos.where((v) {
      if (selectedChannelId.isNotEmpty &&
          v['channel_id'] != selectedChannelId) {
        return false;
      }
      if (selectedRegion != 'all') {
        final reg = (v['region'] ?? 'Belum diketahui').toString();
        if (reg != selectedRegion) return false;
      }
      if (minSec > 0 || durationRange.end.round() < 120) {
        final durSec =
            (v['duration_seconds'] as int?) ??
            _durationToSeconds((v['duration'] ?? '').toString());
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
        final va =
            ((a['view_count'] ?? 0) as int) + ((a['views_total'] ?? 0) as int);
        final vb =
            ((b['view_count'] ?? 0) as int) + ((b['views_total'] ?? 0) as int);
        return vb.compareTo(va);
      } else if (sortBy == 'likes') {
        return ((b['like_count'] ?? 0) as int).compareTo(
          (a['like_count'] ?? 0) as int,
        );
      }
      return (b['published_at'] ?? '').toString().compareTo(
        (a['published_at'] ?? '').toString(),
      );
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
        final activeLim =
            parsedTabLimits[sessChannel.isEmpty ? 'home' : sessChannel] ??
            defLim;
        final minM = ((sess['min_minutes'] ?? 0) as num).toDouble().clamp(
          0.0,
          120.0,
        );
        final maxM = ((sess['max_minutes'] ?? 120) as num).toDouble().clamp(
          minM,
          120.0,
        );
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
          selectedRegion = (sess['region'] ?? 'all').toString();
          if (period.endsWith('y') &&
              int.tryParse(period.substring(0, period.length - 1)) != null) {
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
          limit = (activeLim == 25 || activeLim == 50 || activeLim == 100)
              ? activeLim
              : 25;
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
    _refreshPollTimer = Timer.periodic(const Duration(milliseconds: 600), (
      timer,
    ) async {
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

  Future<void> _saveUiPreferences({
    int? newLimit,
    String? newSidebarMode,
    bool? newFilterMinimized,
  }) async {
    final tabKey = selectedChannelId.isEmpty ? 'home' : selectedChannelId;
    if (newLimit != null &&
        (newLimit == 25 || newLimit == 50 || newLimit == 100)) {
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
            'region': selectedRegion,
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

    // Jika backend laptop tidak terjangkau (mis. HP tanpa USB/backend mati), otomatis pakai Mode Mandiri
    if (!isStandaloneMode) {
      try {
        await http
            .get(Uri.parse('$baseUrl/api/state'))
            .timeout(const Duration(milliseconds: 1500));
      } catch (_) {
        isStandaloneMode = true;
      }
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
            .where(
              (ch) =>
                  !(ch['channel_id'] ?? '').toString().startsWith('UC_demo_') &&
                  (selectedChannelId.isEmpty ||
                      ch['channel_id'] == selectedChannelId),
            )
            .toList();
        await _standaloneRefreshChannelRegions(targetChs);
        await _standaloneFastRefreshChannels(targetChs);
        await _saveStandaloneData();
        if (!mounted) return;
        setState(() {
          refreshingYouTube = false;
          refreshProgress = 100;
          refreshReadyGreen = true;
          refreshNewVideosCount = (_localVideos.length - beforeCount).clamp(
            0,
            999999,
          );
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
            content: Text(
              '⚠️ Gagal Refresh YouTube: ${e.toString().replaceAll("Exception: ", "")}',
            ),
          ),
        );
      }
    }
  }

  Future<void> _refreshAll() async {
    await _fetchVideos();
  }

  Future<void> _fetchVideos({bool silent = false}) async {
    if (!silent) setState(() => loading = true);
    try {
      final stateRes = await http
          .get(Uri.parse('$baseUrl/api/state'))
          .timeout(const Duration(seconds: 4));
      final uri = Uri.parse('$baseUrl/api/videos').replace(
        queryParameters: {
          'sort_by': sortBy,
          'period': period,
          'region': selectedRegion,
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
        final fetchedChannels = List<Map<String, dynamic>>.from(
          sData['channels'] ?? [],
        );
        final fetchedVideos = List<Map<String, dynamic>>.from(
          vData['items'] ?? [],
        );
        for (final fetched in fetchedChannels) {
          for (final saved in _localChannels) {
            if ((saved['channel_id'] ?? '').toString() ==
                (fetched['channel_id'] ?? '').toString()) {
              _mergeUsageCounts(fetched, saved, isChannel: true);
              break;
            }
          }
        }
        for (final fetched in fetchedVideos) {
          for (final saved in _localVideos) {
            if ((saved['video_id'] ?? '').toString() ==
                (fetched['video_id'] ?? '').toString()) {
              _mergeUsageCounts(fetched, saved);
              break;
            }
          }
        }
        setState(() {
          isStandaloneMode = false;
          channels = fetchedChannels;
          _sortChannelsByWatchedDesc(channels);
          hasApiKey = sData['has_api_key'] ?? false;
          apiKeyPreview = sData['api_key_preview'] ?? '';
          videos = fetchedVideos;
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
      final existingCids = _localChannels
          .map((c) => (c['channel_id'] ?? '').toString())
          .toSet();
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
        final uri = Uri.https(
          'www.googleapis.com',
          '/youtube/v3/subscriptions',
          params,
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) break;
        final data = jsonDecode(res.body);
        final items = (data['items'] as List?) ?? [];
        for (final item in items) {
          final snip = item['snippet'] ?? {};
          final cid = (snip['resourceId']?['channelId'] ?? '').toString();
          if (cid.isEmpty ||
              existingCids.contains(cid) ||
              _localUnsubscribedIds.contains(cid))
            continue;
          final title = (snip['title'] ?? cid).toString();
          final thumb = (snip['thumbnails']?['default']?['url'] ?? '')
              .toString();
          _localChannels.add({
            'channel_id': cid,
            'title': title,
            'handle': '',
            'thumbnail_url': thumb,
            'uploads_playlist_id': cid.startsWith('UC')
                ? 'UU${cid.substring(2)}'
                : cid,
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

  Future<void> _standaloneFastRefreshChannels(
    List<Map<String, dynamic>> targetChs,
  ) async {
    if (targetChs.isEmpty) return;
    final existingVidIds = _localVideos
        .map((v) => (v['video_id'] ?? '').toString())
        .toSet();
    final newVidMeta = <String, Map<String, String>>{};
    final vidRegex = RegExp(r'<yt:videoId>([^<]+)</yt:videoId>');

    const batchSize = 35;
    for (var i = 0; i < targetChs.length; i += batchSize) {
      final chunk = targetChs.sublist(
        i,
        (i + batchSize > targetChs.length) ? targetChs.length : i + batchSize,
      );
      await Future.wait(
        chunk.map((ch) async {
          final cid = (ch['channel_id'] ?? '').toString();
          if (!cid.startsWith('UC')) return;
          try {
            final feedUri = Uri.parse(
              'https://www.youtube.com/feeds/videos.xml?channel_id=$cid',
            );
            final res = await http
                .get(feedUri)
                .timeout(const Duration(seconds: 5));
            if (res.statusCode == 200) {
              final matches = vidRegex.allMatches(res.body);
              for (final m in matches) {
                final vid = (m.group(1) ?? '').trim();
                if (vid.isNotEmpty && !existingVidIds.contains(vid)) {
                  newVidMeta[vid] = {
                    'channel_id': cid,
                    'channel_title': (ch['title'] ?? '').toString(),
                    'channel_thumbnail': (ch['thumbnail_url'] ?? '').toString(),
                    'region': (ch['region'] ?? 'Belum diketahui').toString(),
                  };
                }
              }
            }
          } catch (_) {}
        }),
      );
      if (!mounted) return;
      setState(() {
        refreshProgress = ((i + chunk.length) * 90 ~/ targetChs.length).clamp(
          5,
          92,
        );
      });
    }

    final newIds = newVidMeta.keys.toList();
    for (var i = 0; i < newIds.length; i += 50) {
      final slice = newIds.sublist(
        i,
        (i + 50 > newIds.length) ? newIds.length : i + 50,
      );
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
            final cid = (vsnip['channelId'] ?? meta['channel_id'] ?? '')
                .toString();
            final durStr = _parseIsoDuration(
              (v['contentDetails']?['duration'] ?? '').toString(),
            );
            _localVideos.insert(0, {
              'video_id': vid,
              'channel_id': cid,
              'channel_title':
                  (vsnip['channelTitle'] ?? meta['channel_title'] ?? '')
                      .toString(),
              'channel_thumbnail': (meta['channel_thumbnail'] ?? '').toString(),
              'title': (vsnip['title'] ?? 'Untitled').toString(),
              'thumbnail_url':
                  (vsnip['thumbnails']?['high']?['url'] ??
                          vsnip['thumbnails']?['medium']?['url'] ??
                          'https://i.ytimg.com/vi/$vid/hqdefault.jpg')
                      .toString(),
              'published_at':
                  (vsnip['publishedAt'] ??
                          DateTime.now().toUtc().toIso8601String())
                      .toString(),
              'view_count':
                  int.tryParse((vstats['viewCount'] ?? '0').toString()) ?? 0,
              'like_count':
                  int.tryParse((vstats['likeCount'] ?? '0').toString()) ?? 0,
              'duration': durStr,
              'duration_seconds': _durationToSeconds(durStr),
              'watched_count': _getCreatorWatchedCount(cid),
              'region': (meta['region'] ?? 'Belum diketahui').toString(),
              'is_demo': 0,
            });
          }
        }
      } catch (_) {}
    }
  }

  String _classifyLocalRegion(
    String title,
    String handle,
    String country,
    String language,
  ) {
    final countryCode = country.trim().toUpperCase();
    final lang = language.trim().toLowerCase();
    if (countryCode == 'ID') return 'Nasional';
    if (countryCode.isNotEmpty) return 'Internasional';
    if (lang == 'id' || lang.startsWith('id-')) return 'Nasional';
    final text = '$title $handle'.toLowerCase();
    const indonesiaSignals = [
      'indonesia',
      'indonesian',
      'nusantara',
      'jakarta',
      'bandung',
      'surabaya',
      'jogja',
      'yogyakarta',
      'bahasa indonesia',
      'wib',
      'kompas',
      'detik',
      'tribun',
      'liputan',
      'tempo',
      'kumparan',
      'tvone',
      'trans7',
      'mnc',
      'jawa',
      'sunda',
      'fajrul',
      'ferry irwandi',
      'raditya dika',
      'malaka',
      'gadgetin',
    ];
    if (indonesiaSignals.any(text.contains)) return 'Nasional';
    return 'Belum diketahui';
  }

  Future<void> _standaloneRefreshChannelRegions(
    List<Map<String, dynamic>> targetChannels,
  ) async {
    for (var start = 0; start < targetChannels.length; start += 50) {
      final batch = targetChannels.skip(start).take(50).toList();
      final ids = batch
          .map((c) => (c['channel_id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();
      if (ids.isEmpty) continue;
      try {
        final uri = Uri.https('www.googleapis.com', '/youtube/v3/channels', {
          'part': 'snippet',
          'id': ids.join(','),
          'key': localApiKey,
        });
        final response = await http
            .get(uri)
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) continue;
        final items = (jsonDecode(response.body)['items'] as List?) ?? [];
        for (final item in items) {
          final snippet = item['snippet'] ?? {};
          final channelId = (item['id'] ?? '').toString();
          final region = _classifyLocalRegion(
            (snippet['title'] ?? '').toString(),
            (snippet['customUrl'] ?? '').toString(),
            (snippet['country'] ?? '').toString(),
            (snippet['defaultLanguage'] ?? '').toString(),
          );
          for (final channel in _localChannels) {
            if (channel['channel_id'] == channelId) channel['region'] = region;
          }
          for (final video in _localVideos) {
            if (video['channel_id'] == channelId) video['region'] = region;
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
      throw Exception(
        'Masukkan YouTube API Key dulu di menu Pengaturan API (⚙️).',
      );
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

    final chUri = Uri.https(
      'www.googleapis.com',
      '/youtube/v3/channels',
      queryParams,
    );
    final chRes = await http.get(chUri);
    final chData = jsonDecode(chRes.body);
    final items = (chData['items'] as List?) ?? [];
    if (items.isEmpty) {
      throw Exception(
        'Channel "$identifier" tidak ditemukan atau API Key kurang tepat.',
      );
    }

    final ch = items[0];
    final cid = ch['id'].toString();
    final snip = ch['snippet'] ?? {};
    final title = (snip['title'] ?? raw).toString();
    final handle = (snip['customUrl'] ?? raw).toString();
    final region = _classifyLocalRegion(
      title,
      handle,
      (snip['country'] ?? '').toString(),
      (snip['defaultLanguage'] ?? '').toString(),
    );
    final thumbUrl =
        ((snip['thumbnails']?['medium'] ??
                    snip['thumbnails']?['default'])?['url'] ??
                '')
            .toString();
    final uploadsPid =
        (ch['contentDetails']?['relatedPlaylists']?['uploads'] ??
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
      'region': region,
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
          'thumbnail_url':
              ((vsnip['thumbnails']?['high'] ??
                          vsnip['thumbnails']?['medium'])?['url'] ??
                      'https://i.ytimg.com/vi/$vid/hqdefault.jpg')
                  .toString(),
          'published_at':
              (vsnip['publishedAt'] ?? DateTime.now().toUtc().toIso8601String())
                  .toString(),
          'view_count':
              int.tryParse((vstats['viewCount'] ?? '0').toString()) ?? 0,
          'like_count':
              int.tryParse((vstats['likeCount'] ?? '0').toString()) ?? 0,
          'duration': _parseIsoDuration(
            (v['contentDetails']?['duration'] ?? '').toString(),
          ),
          'region': region,
          'is_demo': 0,
        });
      }
    }
    await _saveStandaloneData();
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

  Thumb? _durationThumbSelector(
    TextDirection textDirection,
    RangeValues values,
    double tapValue,
    Size thumbSize,
    Size trackSize,
    double dx,
  ) {
    final hitRadius = (thumbSize.width > 48 ? thumbSize.width : 48) / 2;
    final nearStart =
        (tapValue - values.start).abs() * trackSize.width <= hitRadius;
    final nearEnd =
        (tapValue - values.end).abs() * trackSize.width <= hitRadius;

    if (nearStart && nearEnd) {
      if (dx == 0) return null;
      final towardStart = textDirection == TextDirection.ltr ? dx < 0 : dx > 0;
      return towardStart ? Thumb.start : Thumb.end;
    }
    if (nearStart) return Thumb.start;
    if (nearEnd) return Thumb.end;

    // Track taps between the thumbs select the upper bound. Taps before the
    // lower bound can still adjust the lower thumb.
    return tapValue < values.start ? Thumb.start : Thumb.end;
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

  void _mergeUsageCounts(
    Map<String, dynamic> current,
    Map<String, dynamic> saved, {
    bool isChannel = false,
  }) {
    final currentHp = int.tryParse((current['views_hp'] ?? 0).toString()) ?? 0;
    final savedHp = int.tryParse((saved['views_hp'] ?? 0).toString()) ?? 0;
    final currentLaptop =
        int.tryParse((current['views_laptop'] ?? 0).toString()) ?? 0;
    final savedLaptop =
        int.tryParse((saved['views_laptop'] ?? 0).toString()) ?? 0;
    final hp = currentHp > savedHp ? currentHp : savedHp;
    final laptop = currentLaptop > savedLaptop ? currentLaptop : savedLaptop;
    current['views_hp'] = hp;
    current['views_laptop'] = laptop;
    current['views_total'] = hp + laptop;
    if (isChannel) current['watched_count'] = hp + laptop;
    saved['views_hp'] = hp;
    saved['views_laptop'] = laptop;
    saved['views_total'] = hp + laptop;
    if (isChannel) saved['watched_count'] = hp + laptop;
    if (!isChannel) {
      final currentWatched =
          int.tryParse((current['watched_count'] ?? 0).toString()) ?? 0;
      final savedWatched =
          int.tryParse((saved['watched_count'] ?? 0).toString()) ?? 0;
      final watched = currentWatched > savedWatched
          ? currentWatched
          : savedWatched;
      current['watched_count'] = watched;
      saved['watched_count'] = watched;
    }
  }

  Future<void> _saveWatchCountsLocally(String channelId, String videoId) async {
    if (!_isHpDevice) return;
    try {
      final db = await _openStandaloneDatabase();
      Map<String, dynamic>? channel;
      for (final item in _localChannels) {
        if ((item['channel_id'] ?? '').toString() == channelId) {
          channel = item;
          break;
        }
      }
      if (channel == null) {
        for (final item in channels) {
          if ((item['channel_id'] ?? '').toString() == channelId) {
            channel = Map<String, dynamic>.from(item);
            _localChannels.add(channel);
            break;
          }
        }
      }
      if (channel != null) {
        await db.insert('channels', {
          'id': channelId,
          'data': jsonEncode(channel),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      Map<String, dynamic>? video;
      for (final item in _localVideos) {
        if ((item['video_id'] ?? '').toString() == videoId) {
          video = item;
          break;
        }
      }
      if (video == null) {
        for (final item in videos) {
          if ((item['video_id'] ?? '').toString() == videoId) {
            video = Map<String, dynamic>.from(item);
            _localVideos.add(video);
            break;
          }
        }
      }
      if (video != null) {
        await db.insert('videos', {
          'id': videoId,
          'data': jsonEncode(video),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    } catch (_) {}
  }

  Future<void> _openYouTubeVideo(Map<String, dynamic> video) async {
    final channelId = (video['channel_id'] ?? '').toString();
    final videoId = (video['video_id'] ?? '').toString();
    final isHp = _isHpDevice;
    final nowIso = DateTime.now().toUtc().toIso8601String();

    setState(() {
      void updateChannelViews(Map<String, dynamic> c) {
        final hp = int.tryParse((c['views_hp'] ?? 0).toString()) ?? 0;
        final lap = int.tryParse((c['views_laptop'] ?? 0).toString()) ?? 0;
        final newHp = isHp ? hp + 1 : hp;
        final newLap = isHp ? lap : lap + 1;
        c['views_hp'] = newHp;
        c['views_laptop'] = newLap;
        c['views_total'] = newHp + newLap;
        c['watched_count'] = newHp + newLap;
        c['updated_at'] = nowIso;
      }

      void updateVideoViews(Map<String, dynamic> v) {
        final hp = int.tryParse((v['views_hp'] ?? 0).toString()) ?? 0;
        final lap = int.tryParse((v['views_laptop'] ?? 0).toString()) ?? 0;
        final newHp = isHp ? hp + 1 : hp;
        final newLap = isHp ? lap : lap + 1;
        v['views_hp'] = newHp;
        v['views_laptop'] = newLap;
        v['views_total'] = newHp + newLap;
        v['updated_at'] = nowIso;
      }

      if (channelId.isNotEmpty) {
        for (final c in channels) {
          if ((c['channel_id'] ?? '').toString() == channelId) {
            updateChannelViews(c);
          }
        }
        for (final c in _localChannels) {
          if ((c['channel_id'] ?? '').toString() == channelId) {
            updateChannelViews(c);
          }
        }
        _sortChannelsByWatchedDesc(channels);
        _sortChannelsByWatchedDesc(_localChannels);
      }

      if (videoId.isNotEmpty) {
        for (final v in videos) {
          if ((v['video_id'] ?? '').toString() == videoId) {
            updateVideoViews(v);
          }
        }
        for (final v in _localVideos) {
          if ((v['video_id'] ?? '').toString() == videoId) {
            updateVideoViews(v);
          }
        }
      }

      if (channelId.isNotEmpty) {
        for (final displayed in channels) {
          if ((displayed['channel_id'] ?? '').toString() != channelId) continue;
          for (final saved in _localChannels) {
            if ((saved['channel_id'] ?? '').toString() == channelId) {
              _mergeUsageCounts(saved, displayed, isChannel: true);
              break;
            }
          }
        }
      }
      if (videoId.isNotEmpty) {
        for (final displayed in videos) {
          if ((displayed['video_id'] ?? '').toString() != videoId) continue;
          for (final saved in _localVideos) {
            if ((saved['video_id'] ?? '').toString() == videoId) {
              _mergeUsageCounts(saved, displayed);
              break;
            }
          }
        }
      }
    });

    await _saveWatchCountsLocally(channelId, videoId);

    if (!isStandaloneMode && videoId.isNotEmpty) {
      try {
        await http
            .post(
              Uri.parse(
                '$baseUrl/api/videos/${Uri.encodeComponent(videoId)}/watch',
              ),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'device': _deviceType,
                'channel_id': channelId,
                'video_id': videoId,
              }),
            )
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
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
      skipUnsubscribeConfirmUntil != null &&
      DateTime.now().isBefore(skipUnsubscribeConfirmUntil!);

  Future<void> _executeUnsubscribe(
    String channelId,
    String channelTitle,
  ) async {
    _localUnsubscribedIds.add(channelId);
    final nowIso = DateTime.now().toUtc().toIso8601String();
    // Update status menjadi 'unfollowed' dengan timestamp terbaru untuk rekonsiliasi sync
    setState(() {
      for (final c in _localChannels) {
        if ((c['channel_id'] ?? '').toString() == channelId) {
          c['status'] = 'unfollowed';
          c['updated_at'] = nowIso;
        }
      }
      channels.removeWhere((c) => c['channel_id'] == channelId);
      videos.removeWhere((v) => v['channel_id'] == channelId);
      _localVideos.removeWhere((v) => v['channel_id'] == channelId);
      if (selectedChannelId == channelId) {
        selectedChannelId = '';
      }
    });

    if (!isStandaloneMode) {
      try {
        await http.post(
          Uri.parse(
            '$baseUrl/api/channels/${Uri.encodeComponent(channelId)}/unfollow',
          ),
        );
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

  Future<void> _confirmOrUnsubscribeChannel(
    String channelId,
    String channelTitle,
  ) async {
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          title: Row(
            children: [
              const Icon(Icons.person_remove_alt_1, color: Color(0xFFFF0033)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Unsubscribe "$channelTitle"?',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
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
                  onTap: () =>
                      setModalState(() => skipNext10Min = !skipNext10Min),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: skipNext10Min
                            ? const Color(0xFFFF0033)
                            : const Color(0xFF383838),
                      ),
                    ),
                    child: Row(
                      children: [
                        Checkbox(
                          value: skipNext10Min,
                          activeColor: const Color(0xFFFF0033),
                          onChanged: (val) =>
                              setModalState(() => skipNext10Min = val ?? false),
                        ),
                        const Expanded(
                          child: Text(
                            'Selama 10 menit ke depan, jangan tanya lagi (langsung Unsubscribe otomatis setiap klik)',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
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
              child: const Text(
                'Batal',
                style: TextStyle(color: Colors.white70),
              ),
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
                    skipUnsubscribeConfirmUntil = DateTime.now().add(
                      const Duration(minutes: 10),
                    );
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

  Future<void> _showUsbSyncDialog() async {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Row(
            children: [
              Icon(Icons.usb, color: Colors.cyanAccent),
              SizedBox(width: 8),
              Text(
                'Sync USB (HP ⇄ Laptop)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF282828),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      _isHpDevice
                          ? Icons.phone_android
                          : Icons.laptop_chromebook,
                      color: Colors.amberAccent,
                      size: 26,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Perangkat ini: ${_isHpDevice ? "📱 HP Android" : "💻 Laptop / Desktop"}\n• Tulis: views_${_isHpDevice ? "hp" : "laptop"}\n• Terima: views_${_isHpDevice ? "laptop" : "hp"}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Hubungkan kabel USB dari HP ke Laptop, lalu klik tombol di bawah:',
                style: TextStyle(fontSize: 12.5, color: Colors.white70),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00838F),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  icon: const Icon(Icons.bolt, color: Colors.yellowAccent),
                  label: const Text(
                    '⚡ Sync Langsung Kabel USB',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _performDirectUsbSync();
                  },
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      icon: const Icon(
                        Icons.download,
                        size: 16,
                        color: Colors.greenAccent,
                      ),
                      label: const Text(
                        'Export JSON',
                        style: TextStyle(fontSize: 12, color: Colors.white),
                      ),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _exportSyncJson();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      icon: const Icon(
                        Icons.upload,
                        size: 16,
                        color: Colors.orangeAccent,
                      ),
                      label: const Text(
                        'Import JSON',
                        style: TextStyle(fontSize: 12, color: Colors.white),
                      ),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _importSyncJson();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Tutup',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _performDirectUsbSync() async {
    if (syncingUsb) return;
    setState(() {
      syncingUsb = true;
      usbSyncProgress = 15;
      usbSyncReadyGreen = false;
    });

    try {
      await Future.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;
      setState(() => usbSyncProgress = 30);

      final payload = {
        'device': _deviceType,
        'videos': [
          for (final v in (_localVideos.isNotEmpty ? _localVideos : videos))
            if ((int.tryParse((v['views_hp'] ?? 0).toString()) ?? 0) > 0 ||
                (int.tryParse((v['views_laptop'] ?? 0).toString()) ?? 0) > 0)
              {
                'video_id': v['video_id'],
                'views_hp': v['views_hp'] ?? 0,
                'views_laptop': v['views_laptop'] ?? 0,
                'updated_at':
                    v['updated_at'] ?? DateTime.now().toUtc().toIso8601String(),
              },
        ],
        'channels': [
          for (final c
              in (_localChannels.isNotEmpty ? _localChannels : channels))
            {
              'channel_id': c['channel_id'],
              'title': c['title'],
              'handle': c['handle'] ?? '',
              'views_hp': c['views_hp'] ?? 0,
              'views_laptop': c['views_laptop'] ?? 0,
              'status': c['status'] ?? 'subscribed',
              'region': c['region'] ?? 'Belum diketahui',
              'updated_at':
                  c['updated_at'] ?? DateTime.now().toUtc().toIso8601String(),
            },
        ],
      };

      if (!mounted) return;
      setState(() => usbSyncProgress = 50);

      http.Response? syncResp;
      final candidates = <String>{
        baseUrl,
        'http://127.0.0.1:8000',
        'http://10.0.2.2:8000',
        'http://172.18.164.232:8000',
        'http://192.168.68.54:8000',
      };
      for (final cand in candidates) {
        try {
          final r = await http
              .post(
                Uri.parse('$cand/api/sync/exchange'),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode(payload),
              )
              .timeout(const Duration(seconds: 5));
          if (r.statusCode == 200) {
            baseUrl = cand;
            syncResp = r;
            break;
          }
        } catch (_) {}
      }

      if (syncResp != null && syncResp.statusCode == 200) {
        if (!mounted) return;
        setState(() => usbSyncProgress = 75);

        final data = jsonDecode(syncResp.body);
        final remoteVids = (data['videos'] as List?) ?? [];
        final remoteChs = (data['channels'] as List?) ?? [];

        final remoteVidMap = {
          for (final v in remoteVids) (v['video_id'] ?? '').toString(): v,
        };
        for (final v in _localVideos) {
          final vid = (v['video_id'] ?? '').toString();
          if (remoteVidMap.containsKey(vid)) {
            final rv = remoteVidMap[vid];
            final rHp = int.tryParse((rv['views_hp'] ?? 0).toString()) ?? 0;
            final rLap =
                int.tryParse((rv['views_laptop'] ?? 0).toString()) ?? 0;
            final curHp = int.tryParse((v['views_hp'] ?? 0).toString()) ?? 0;
            final curLap =
                int.tryParse((v['views_laptop'] ?? 0).toString()) ?? 0;
            final nextHp = curHp > rHp ? curHp : rHp;
            final nextLap = curLap > rLap ? curLap : rLap;
            v['views_hp'] = nextHp;
            v['views_laptop'] = nextLap;
            v['views_total'] = nextHp + nextLap;
            if (rv['region'] != null && rv['region'].toString().isNotEmpty) {
              v['region'] = rv['region'].toString();
            }
          }
        }

        for (final rc in remoteChs) {
          final cid = (rc['channel_id'] ?? '').toString();
          if (cid.isEmpty) continue;
          Map<String, dynamic>? cached;
          for (final c in _localChannels) {
            if ((c['channel_id'] ?? '').toString() == cid) {
              cached = c;
              break;
            }
          }
          final rcHp = int.tryParse((rc['views_hp'] ?? 0).toString()) ?? 0;
          final rcLap = int.tryParse((rc['views_laptop'] ?? 0).toString()) ?? 0;
          if (cached == null) {
            // Keep the laptop's creator list available on the phone after
            // disconnecting, instead of losing creators absent from the seed.
            if ((rc['status'] ?? 'subscribed') != 'unfollowed') {
              final added = Map<String, dynamic>.from(rc);
              added['views_total'] = rcHp + rcLap;
              added['watched_count'] = rcHp + rcLap;
              _localChannels.add(added);
            }
            continue;
          }
          final curHp = int.tryParse((cached['views_hp'] ?? 0).toString()) ?? 0;
          final curLap =
              int.tryParse((cached['views_laptop'] ?? 0).toString()) ?? 0;
          final nextHp = curHp > rcHp ? curHp : rcHp;
          final nextLap = curLap > rcLap ? curLap : rcLap;
          cached['views_hp'] = nextHp;
          cached['views_laptop'] = nextLap;
          cached['views_total'] = nextHp + nextLap;
          cached['watched_count'] = nextHp + nextLap;
          if (rc['status'] != null) cached['status'] = rc['status'];
          if (rc['region'] != null) cached['region'] = rc['region'];
          if (rc['updated_at'] != null) cached['updated_at'] = rc['updated_at'];
          if (rc['title'] != null) cached['title'] = rc['title'];
          if (rc['thumbnail_url'] != null) {
            cached['thumbnail_url'] = rc['thumbnail_url'];
          }
        }

        _sortChannelsByWatchedDesc(_localChannels);
        _sortChannelsByWatchedDesc(channels);

        if (!mounted) return;
        setState(() => usbSyncProgress = 90);

        await _fetchVideos(silent: true);
        // USB sync updates the in-memory cache. Persist it before reporting
        // success, otherwise the next cold start restores stale creator counts.
        await _saveStandaloneData();

        if (!mounted) return;
        setState(() {
          usbSyncProgress = 100;
          syncingUsb = false;
          usbSyncReadyGreen = true;
        });

        _usbSyncResetTimer?.cancel();
        _usbSyncResetTimer = Timer(const Duration(seconds: 4), () {
          if (mounted) setState(() => usbSyncReadyGreen = false);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1B5E20),
            content: Text(
              '⚡ Sync USB 100% Selesai! Data HP & Laptop terhubung (${remoteVids.length} video, ${remoteChs.length} channel).',
            ),
          ),
        );
      } else {
        throw Exception(
          'Tidak dapat terhubung ke Laptop via kabel USB. Pastikan backend di laptop menyala.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        syncingUsb = false;
        usbSyncProgress = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            '⚠️ Gagal Sync USB: ${e.toString().replaceAll("Exception: ", "")}',
          ),
        ),
      );
    }
  }

  Future<void> _exportSyncJson() async {
    final payload = {
      'device': _deviceType,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'videos': [
        for (final v in (_localVideos.isNotEmpty ? _localVideos : videos))
          if ((int.tryParse((v['views_hp'] ?? 0).toString()) ?? 0) > 0 ||
              (int.tryParse((v['views_laptop'] ?? 0).toString()) ?? 0) > 0)
            {
              'video_id': v['video_id'],
              'views_hp': v['views_hp'] ?? 0,
              'views_laptop': v['views_laptop'] ?? 0,
              'region': v['region'] ?? 'Belum diketahui',
              'updated_at':
                  v['updated_at'] ?? DateTime.now().toUtc().toIso8601String(),
            },
      ],
      'channels': [
        for (final c in (_localChannels.isNotEmpty ? _localChannels : channels))
          {
            'channel_id': c['channel_id'],
            'title': c['title'],
            'handle': c['handle'] ?? '',
            'views_hp': c['views_hp'] ?? 0,
            'views_laptop': c['views_laptop'] ?? 0,
            'status': c['status'] ?? 'subscribed',
            'region': c['region'] ?? 'Belum diketahui',
            'updated_at':
                c['updated_at'] ?? DateTime.now().toUtc().toIso8601String(),
          },
      ],
    };
    final jsonStr = jsonEncode(payload);
    await Clipboard.setData(ClipboardData(text: jsonStr));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF1B5E20),
          content: Text(
            '📋 Paket data sync (.json) berhasil disalin ke Clipboard!',
          ),
        ),
      );
    }
  }

  Future<void> _importSyncJson() async {
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text(
            'Import Paket Data Sync',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Tempelkan isi JSON data sync dari perangkat lain:',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: ctrl,
                maxLines: 6,
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: Colors.white,
                ),
                decoration: const InputDecoration(
                  hintText:
                      '{"device": "...", "videos": [...], "channels": [...]}',
                  hintStyle: TextStyle(color: Colors.white24, fontSize: 11),
                  filled: true,
                  fillColor: Color(0xFF282828),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text(
                'Batal',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF0033),
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _applySyncDataString(ctrl.text);
              },
              child: const Text('Terapkan Sync'),
            ),
          ],
        );
      },
    );
  }

  void _applySyncDataString(String rawJson) {
    try {
      final data = jsonDecode(rawJson.trim());
      final remoteVids = (data['videos'] as List?) ?? [];
      final remoteChs = (data['channels'] as List?) ?? [];
      final remoteVidMap = {
        for (final v in remoteVids) (v['video_id'] ?? '').toString(): v,
      };
      final remoteChMap = {
        for (final c in remoteChs) (c['channel_id'] ?? '').toString(): c,
      };

      setState(() {
        for (final v in _localVideos) {
          final vid = (v['video_id'] ?? '').toString();
          if (remoteVidMap.containsKey(vid)) {
            final rv = remoteVidMap[vid];
            final rHp = int.tryParse((rv['views_hp'] ?? 0).toString()) ?? 0;
            final rLap =
                int.tryParse((rv['views_laptop'] ?? 0).toString()) ?? 0;
            final curHp = int.tryParse((v['views_hp'] ?? 0).toString()) ?? 0;
            final curLap =
                int.tryParse((v['views_laptop'] ?? 0).toString()) ?? 0;
            final nextHp = curHp > rHp ? curHp : rHp;
            final nextLap = curLap > rLap ? curLap : rLap;
            v['views_hp'] = nextHp;
            v['views_laptop'] = nextLap;
            v['views_total'] = nextHp + nextLap;
            if (rv['region'] != null && rv['region'].toString().isNotEmpty) {
              v['region'] = rv['region'].toString();
            }
          }
        }
        for (final c in _localChannels) {
          final cid = (c['channel_id'] ?? '').toString();
          if (remoteChMap.containsKey(cid)) {
            final rc = remoteChMap[cid];
            final rHp = int.tryParse((rc['views_hp'] ?? 0).toString()) ?? 0;
            final rLap =
                int.tryParse((rc['views_laptop'] ?? 0).toString()) ?? 0;
            final curHp = int.tryParse((c['views_hp'] ?? 0).toString()) ?? 0;
            final curLap =
                int.tryParse((c['views_laptop'] ?? 0).toString()) ?? 0;
            final nextHp = curHp > rHp ? curHp : rHp;
            final nextLap = curLap > rLap ? curLap : rLap;
            c['views_hp'] = nextHp;
            c['views_laptop'] = nextLap;
            c['views_total'] = nextHp + nextLap;
            c['watched_count'] = nextHp + nextLap;
            if (rc['status'] != null) c['status'] = rc['status'];
            if (rc['region'] != null) c['region'] = rc['region'];
          }
        }
        _sortChannelsByWatchedDesc(_localChannels);
        _sortChannelsByWatchedDesc(channels);
      });

      _applyLocalFilterAndPagination();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1B5E20),
          content: Text(
            '✅ Import sync berhasil! (${remoteVids.length} video, ${remoteChs.length} channel)',
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('⚠️ Format JSON tidak valid: $e'),
        ),
      );
    }
  }

  Future<void> _exportExcelCsv() async {
    if (!isStandaloneMode) {
      final url = Uri.parse('$baseUrl/api/channels/export-csv');
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return;
    }
    // Jika di HP (Mode Mandiri), tampilkan & salin teks CSV siap tempel ke Excel / Google Sheets
    final buffer = StringBuffer(
      'Channel ID,Nama Channel,Handle,Jumlah Video\n',
    );
    for (final c in channels) {
      buffer.writeln(
        '${c['channel_id']},"${c['title']}",${c['handle'] ?? ''},${c['video_count'] ?? 0}',
      );
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Data CSV berhasil disalin ke Clipboard! Siap ditempel (Paste) ke Excel / Google Sheets.',
        ),
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
                                    await _standaloneAddAndSyncChannel(
                                      handleCtrl.text,
                                    );
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    _applyLocalFilterAndPagination();
                                  } else {
                                    final res = await http.post(
                                      Uri.parse('$baseUrl/api/channels'),
                                      headers: {
                                        'Content-Type': 'application/json',
                                      },
                                      body: jsonEncode({
                                        'identifier': handleCtrl.text,
                                      }),
                                    );
                                    if (res.statusCode == 200) {
                                      if (ctx.mounted) Navigator.pop(ctx);
                                      _refreshAll();
                                    } else {
                                      final err = jsonDecode(res.body);
                                      setModalState(() {
                                        modalError =
                                            err['detail'] ??
                                            'Gagal menambah channel';
                                        busy = false;
                                      });
                                    }
                                  }
                                } catch (e) {
                                  setModalState(() {
                                    modalError = e.toString().replaceAll(
                                      'Exception: ',
                                      '',
                                    );
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
                      hintText:
                          '@FajrulFx\n@FerryIrwandi\n@RadityaDika\natau UCxxxx,https://...,Nama Channel',
                      filled: true,
                      fillColor: Color(0xFF121212),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (modalError != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      modalError!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
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
                            _localChannels.removeWhere(
                              (c) => c['channel_id'] == cid,
                            );
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
          title: const Text(
            'Pengaturan API YouTube (Gratis) & Mode Mandiri HP',
          ),
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
                      color: isStandaloneMode
                          ? const Color(0xFF1B3B2B)
                          : const Color(0xFF1A2B3C),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isStandaloneMode
                              ? Icons.phone_android
                              : Icons.computer,
                          color: Colors.greenAccent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            isStandaloneMode
                                ? 'Mode Mandiri Aktif: Aplikasi jalan sendiri langsung di HP/Perangkat tanpa butuh Backend Python!'
                                : 'Mode Terhubung Backend Python ($baseUrl)',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
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
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.amberAccent,
                          ),
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
                    Text(
                      statusMsg!,
                      style: const TextStyle(color: Colors.greenAccent),
                    ),
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
              child: const Text(
                'Hapus Data Demo',
                style: TextStyle(color: Colors.orangeAccent),
              ),
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
                          if (localApiKey.isNotEmpty ||
                              localOauthToken.isNotEmpty) {
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
                              'import_mode': localOauthToken.isNotEmpty
                                  ? 'subscriptions'
                                  : 'none',
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
              child: Text(
                syncing ? 'Menyinkronkan...' : 'Simpan & Sync Sekarang',
              ),
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
      limit = (savedLimit == 25 || savedLimit == 50 || savedLimit == 100)
          ? savedLimit
          : 25;
      currentPage = 1;
    });
    if (isMobileScreen && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    _fetchVideos();
  }

  Widget _buildSearchInputBox({
    double height = 40,
    EdgeInsetsGeometry? margin,
  }) {
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

  Widget _buildUsbSyncButton({required bool isMobile}) {
    if (syncingUsb) {
      return Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF004D40),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.cyanAccent, width: 1.2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: usbSyncProgress > 0
                        ? (usbSyncProgress / 100.0)
                        : null,
                    strokeWidth: 2.2,
                    color: Colors.cyanAccent,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$usbSyncProgress%',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.cyanAccent,
              ),
            ),
          ],
        ),
      );
    }

    if (usbSyncReadyGreen) {
      return ElevatedButton.icon(
        onPressed: _performDirectUsbSync,
        icon: const Icon(Icons.check_circle, size: 15, color: Colors.white),
        label: Text(
          isMobile ? '100%' : '100% Sync',
          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF2E7D32),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 34),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }

    return OutlinedButton.icon(
      onPressed: _performDirectUsbSync,
      icon: const Icon(Icons.usb, size: 16, color: Colors.cyanAccent),
      label: Text(
        isMobile
            ? 'Sync USB'
            : (_isHpDevice ? 'Sync Laptop (USB)' : 'Sync HP (USB)'),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Color(0xFF00695C)),
        backgroundColor: const Color(0xFF1B2A30),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _buildRefreshYouTubeButton(bool isMobile) {
    return ElevatedButton.icon(
      onPressed: _manualRefreshYouTube,
      icon: refreshingYouTube
          ? SizedBox(
              width: 18,
              height: 18,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(
                    value: refreshProgress > 0
                        ? (refreshProgress / 100.0)
                        : null,
                    strokeWidth: 2.2,
                    color: Colors.white,
                  ),
                ],
              ),
            )
          : Icon(
              refreshReadyGreen ? Icons.check_circle : Icons.refresh,
              size: 16,
            ),
      label: Text(
        refreshingYouTube
            ? '$refreshProgress%'
            : (refreshReadyGreen
                  ? (isMobile ? 'Siap' : '100% Siap')
                  : (isMobile ? 'Refresh' : 'Refresh YouTube')),
        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: refreshReadyGreen
            ? const Color(0xFF2E7D32)
            : const Color(0xFFFF0033),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 750;
    final isCompactHeader = screenWidth < 1150;

    return Scaffold(
      key: _scaffoldKey,
      drawer: isMobile
          ? Drawer(
              backgroundColor: const Color(0xFF0F0F0F),
              child: SafeArea(
                child: _buildSidebar(forceFull: true, isNarrow: false),
              ),
            )
          : null,
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
                        tooltip: isMobile
                            ? 'Daftar Channel (Subscriptions)'
                            : 'Ubah Ukuran Sidebar (Penuh / Mini Ikon / Sembunyi)',
                        icon: const Icon(Icons.menu, color: Colors.white),
                        visualDensity: isMobile
                            ? VisualDensity.compact
                            : VisualDensity.standard,
                        onPressed: () {
                          if (isMobile) {
                            _scaffoldKey.currentState?.openDrawer();
                          } else {
                            _cycleSidebarMode();
                          }
                        },
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF0033),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(
                          Icons.play_arrow,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (!isCompactHeader)
                        const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: Text(
                            'YouTube Follower',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              letterSpacing: -0.5,
                            ),
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

                      // 1. Tombol Sync USB (Dengan animasi lingkaran 1-100% dan TIDAK membekukan layar)
                      _buildUsbSyncButton(isMobile: isMobile),
                      const SizedBox(width: 4),

                      // 2. Tombol Refresh YouTube
                      _buildRefreshYouTubeButton(isMobile),

                      if (!isMobile) ...[
                        const SizedBox(width: 6),
                        if (!isCompactHeader) ...[
                          OutlinedButton.icon(
                            onPressed: _exportExcelCsv,
                            icon: const Icon(
                              Icons.table_view,
                              size: 18,
                              color: Colors.greenAccent,
                            ),
                            label: const Text(
                              'Export Excel/CSV',
                              style: TextStyle(color: Colors.white),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFF303030)),
                              backgroundColor: const Color(0xFF222222),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ] else ...[
                          IconButton(
                            tooltip: 'Export Excel/CSV',
                            onPressed: _exportExcelCsv,
                            icon: const Icon(
                              Icons.table_view,
                              color: Colors.greenAccent,
                              size: 20,
                            ),
                          ),
                        ],
                        ElevatedButton.icon(
                          onPressed: _showAddChannelModal,
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(
                            isCompactHeader ? 'Channel' : 'Tambah Channel',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF272727),
                            foregroundColor: Colors.white,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Pengaturan API & Sync',
                          onPressed: _showApiSettingsModal,
                          icon: Icon(
                            Icons.settings,
                            size: 22,
                            color: hasApiKey
                                ? Colors.greenAccent
                                : Colors.amberAccent,
                          ),
                        ),
                      ] else ...[
                        // Pada HP: Menu Popup 3 Titik (Menghilangkan Right Overflow 49px sama sekali!)
                        PopupMenuButton<String>(
                          icon: const Icon(
                            Icons.more_vert,
                            color: Colors.white,
                            size: 22,
                          ),
                          tooltip: 'Menu Lainnya',
                          color: const Color(0xFF212121),
                          onSelected: (val) {
                            if (val == 'add') _showAddChannelModal();
                            if (val == 'csv') _exportExcelCsv();
                            if (val == 'export_sync') _exportSyncJson();
                            if (val == 'import_sync') _importSyncJson();
                            if (val == 'settings') _showApiSettingsModal();
                          },
                          itemBuilder: (ctx) => [
                            const PopupMenuItem(
                              value: 'add',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.person_add_alt_1,
                                    size: 18,
                                    color: Colors.white,
                                  ),
                                  SizedBox(width: 10),
                                  Text(
                                    'Tambah Channel',
                                    style: TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'csv',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.table_view,
                                    size: 18,
                                    color: Colors.greenAccent,
                                  ),
                                  SizedBox(width: 10),
                                  Text(
                                    'Export Excel / CSV',
                                    style: TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'export_sync',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.upload,
                                    size: 18,
                                    color: Colors.cyanAccent,
                                  ),
                                  SizedBox(width: 10),
                                  Text(
                                    'Salin JSON Sync',
                                    style: TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'import_sync',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.download,
                                    size: 18,
                                    color: Colors.cyanAccent,
                                  ),
                                  SizedBox(width: 10),
                                  Text(
                                    'Tempel JSON Sync',
                                    style: TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'settings',
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.settings,
                                    size: 18,
                                    color: Colors.amberAccent,
                                  ),
                                  SizedBox(width: 10),
                                  Text(
                                    'Pengaturan API & IP',
                                    style: TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
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
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMobile && sidebarMode != 'hidden')
            _buildSidebar(isNarrow: sidebarMode == 'mini'),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isMobile) ...[_buildMobileQuickControlBar()],
                if (!isMobile) _buildFilterAndSortHeader(false),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : LayoutBuilder(
                          builder: (ctx, constraints) =>
                              _buildVideoGridWithPagination(
                                constraints.maxWidth,
                              ),
                        ),
                ),
              ],
            ),
          ),
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
                  icon: const Icon(
                    Icons.keyboard_double_arrow_right,
                    color: Colors.white70,
                  ),
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
                      color: selectedChannelId.isEmpty
                          ? const Color(0xFF272727)
                          : Colors.transparent,
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
              ...channels
                  .where((ch) {
                    if (selectedRegion != 'all') {
                      return (ch['region'] ?? 'Belum diketahui').toString() ==
                          selectedRegion;
                    }
                    return true;
                  })
                  .map((ch) {
                    final cid = (ch['channel_id'] ?? '').toString();
                    final title = (ch['title'] ?? '').toString();
                    final reg = (ch['region'] ?? 'Belum diketahui').toString();
                    final cHp =
                        int.tryParse((ch['views_hp'] ?? 0).toString()) ?? 0;
                    final cLap =
                        int.tryParse((ch['views_laptop'] ?? 0).toString()) ?? 0;
                    final watchedCount =
                        int.tryParse(
                          (ch['views_total'] ?? ch['watched_count'] ?? 0)
                              .toString(),
                        ) ??
                        (cHp + cLap);
                    final isSelected = selectedChannelId == cid;
                    return Tooltip(
                      message:
                          '$title\nTotal: $watchedCount view (📱 HP: $cHp | 💻 Laptop: $cLap)\nWilayah: $reg',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _selectChannelTab(cid),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFF272727)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Center(
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                CircleAvatar(
                                  radius: 16,
                                  backgroundColor: const Color(0xFF383838),
                                  backgroundImage:
                                      (ch['thumbnail_url'] ?? '')
                                          .toString()
                                          .isNotEmpty
                                      ? NetworkImage(ch['thumbnail_url'])
                                      : null,
                                  onBackgroundImageError:
                                      (ch['thumbnail_url'] ?? '')
                                          .toString()
                                          .isNotEmpty
                                      ? (_, _) {}
                                      : null,
                                  child: Text(
                                    title.isNotEmpty ? title[0] : '?',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ),
                                if (watchedCount > 0)
                                  Positioned(
                                    right: -4,
                                    bottom: -4,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF1E3A2F),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: const Color(0xFF2E7D32),
                                          width: 0.8,
                                        ),
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

    final sidebarContent = Material(
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
              if (forceFull)
                IconButton(
                  tooltip: 'Tutup',
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.of(context).pop(),
                )
              else
                IconButton(
                  tooltip: 'Kecilkan Sidebar (Mode Ikon)',
                  icon: const Icon(
                    Icons.keyboard_double_arrow_left,
                    size: 20,
                    color: Colors.white60,
                  ),
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
          ...channels
              .where((ch) {
                if (selectedRegion != 'all') {
                  return (ch['region'] ?? 'Belum diketahui').toString() ==
                      selectedRegion;
                }
                return true;
              })
              .map((ch) {
                final cid = (ch['channel_id'] ?? '').toString();
                final title = (ch['title'] ?? '').toString();
                final reg = (ch['region'] ?? 'Belum diketahui').toString();
                final cHp = int.tryParse((ch['views_hp'] ?? 0).toString()) ?? 0;
                final cLap =
                    int.tryParse((ch['views_laptop'] ?? 0).toString()) ?? 0;
                final watchedCount =
                    int.tryParse(
                      (ch['views_total'] ?? ch['watched_count'] ?? 0)
                          .toString(),
                    ) ??
                    (cHp + cLap);
                final isSelected = selectedChannelId == cid;
                return Tooltip(
                  message:
                      '$title\nTotal: $watchedCount view (📱 HP: $cHp | 💻 Laptop: $cLap)\nWilayah: $reg',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _selectChannelTab(cid),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF272727)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 14,
                            backgroundColor: const Color(0xFF383838),
                            backgroundImage:
                                (ch['thumbnail_url'] ?? '')
                                    .toString()
                                    .isNotEmpty
                                ? NetworkImage(ch['thumbnail_url'])
                                : null,
                            onBackgroundImageError:
                                (ch['thumbnail_url'] ?? '')
                                    .toString()
                                    .isNotEmpty
                                ? (_, _) {}
                                : null,
                            child: Text(
                              title.isNotEmpty ? title[0] : '?',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: isSelected
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  reg == 'Nasional' ? '🇮🇩' : '🌍',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: watchedCount > 0
                                  ? const Color(0xFF1E3A2F)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '$watchedCount',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: watchedCount > 0
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: watchedCount > 0
                                    ? const Color(0xFF81C784)
                                    : Colors.white54,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
          const Divider(color: Color(0xFF272727), height: 28),
          _sidebarTile(
            icon: Icons.usb,
            title: 'Sync USB (HP ⇄ Laptop)',
            selected: false,
            onTap: _showUsbSyncDialog,
          ),
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
    );
    if (forceFull) {
      return sidebarContent;
    }
    return SizedBox(width: isNarrow ? 190 : 240, child: sidebarContent);
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

  void _showMobileFilterBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final periods = [
              ('all', 'Semua Waktu'),
              ('week', 'Minggu Ini'),
              ('month', 'Bulan Ini'),
              ('year', 'Tahun Ini'),
            ];
            final sorts = [
              ('views', '🔥 View Terbanyak'),
              ('likes', '👍 Like Terbanyak'),
              ('time', '🕒 Waktu Upload'),
            ];
            final isCustomYear =
                period.endsWith('y') &&
                int.tryParse(period.substring(0, period.length - 1)) != null;

            Widget regionChoice(String value, String label) {
              final active = selectedRegion == value;
              return ChoiceChip(
                label: SizedBox(
                  width: double.infinity,
                  child: Text(label, textAlign: TextAlign.center),
                ),
                selected: active,
                selectedColor: value == 'Nasional'
                    ? const Color(0xFFD32F2F)
                    : (value == 'Internasional'
                          ? const Color(0xFF1976D2)
                          : (value == 'Belum diketahui'
                                ? const Color(0xFF616161)
                                : Colors.white)),
                backgroundColor: const Color(0xFF2C2C2C),
                labelStyle: TextStyle(
                  color: active && value == 'all' ? Colors.black : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12.5,
                ),
                onSelected: (_) {
                  setState(() {
                    selectedRegion = value;
                    currentPage = 1;
                  });
                  setModalState(() {});
                  _saveUiPreferences();
                  _fetchVideos();
                },
              );
            }

            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Filter & Urutan Video',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const Divider(color: Color(0xFF333333)),
                    const SizedBox(height: 6),
                    const Text(
                      'Urutkan:',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: sorts.map((s) {
                        final active = sortBy == s.$1;
                        return ChoiceChip(
                          label: Text(s.$2),
                          selected: active,
                          selectedColor: Colors.white,
                          backgroundColor: const Color(0xFF2C2C2C),
                          labelStyle: TextStyle(
                            color: active ? Colors.black : Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12.5,
                          ),
                          onSelected: (_) {
                            setState(() {
                              sortBy = s.$1;
                              currentPage = 1;
                            });
                            setModalState(() {});
                            _saveUiPreferences();
                            _fetchVideos();
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Wilayah Konten:',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: regionChoice('Nasional', 'Nasional'),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: regionChoice(
                                'Internasional',
                                'Internasional',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(child: regionChoice('all', 'Semua')),
                            const SizedBox(width: 8),
                            Expanded(
                              child: regionChoice(
                                'Belum diketahui',
                                'Belum diketahui',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Periode Upload:',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: periods.map((p) {
                        final active = period == p.$1;
                        return ChoiceChip(
                          label: Text(p.$2),
                          selected: active,
                          selectedColor: Colors.white,
                          backgroundColor: const Color(0xFF2C2C2C),
                          labelStyle: TextStyle(
                            color: active ? Colors.black : Colors.white,
                            fontWeight: active
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontSize: 12.5,
                          ),
                          onSelected: (_) {
                            _yearInputCtrl.clear();
                            setState(() {
                              period = p.$1;
                              currentPage = 1;
                            });
                            setModalState(() {});
                            _fetchVideos();
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Tampil per Tab (Permanen):',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [25, 50, 100].map((val) {
                        final active = limit == val;
                        return ChoiceChip(
                          label: Text('$val Video'),
                          selected: active,
                          selectedColor: const Color(0xFFFF0033),
                          backgroundColor: const Color(0xFF2C2C2C),
                          labelStyle: TextStyle(
                            color: Colors.white,
                            fontWeight: active
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontSize: 12.5,
                          ),
                          onSelected: (_) {
                            setState(() {
                              limit = val;
                              currentPage = 1;
                            });
                            setModalState(() {});
                            _saveUiPreferences(newLimit: val);
                            _fetchVideos();
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Filter Durasi Video:',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${_formatMinutesLabel(durationRange.start.round())} – ${_formatMinutesLabel(durationRange.end.round(), isMax: true)}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Colors.amberAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: LayoutBuilder(
                        builder: (sliderContext, constraints) {
                          const trackInset = 16.0;
                          final trackWidth =
                              (constraints.maxWidth - trackInset * 2)
                                  .clamp(1.0, double.infinity)
                                  .toDouble();

                          void finishDurationDrag() {
                            if (_activeDurationThumb == null) return;
                            _activeDurationThumb = null;
                            setState(() => currentPage = 1);
                            _saveUiPreferences();
                            _fetchVideos();
                          }

                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragStart: (details) {
                              final x = details.localPosition.dx;
                              final startX =
                                  trackInset +
                                  durationRange.start / 120 * trackWidth;
                              final endX =
                                  trackInset +
                                  durationRange.end / 120 * trackWidth;
                              final startDistance = (x - startX).abs();
                              final endDistance = (x - endX).abs();
                              // Make the touch target much larger than the
                              // visible thumb, which is difficult to grab on
                              // a phone. Track presses still do not move it.
                              const thumbHitRadius = 36.0;

                              if (startDistance <= thumbHitRadius ||
                                  endDistance <= thumbHitRadius) {
                                setModalState(
                                  () => _activeDurationThumb =
                                      startDistance <= endDistance
                                      ? Thumb.start
                                      : Thumb.end,
                                );
                              } else {
                                setModalState(
                                  () => _activeDurationThumb = null,
                                );
                              }
                            },
                            onHorizontalDragUpdate: (details) {
                              final deltaMinutes =
                                  (details.primaryDelta ?? 0) /
                                  trackWidth *
                                  120;
                              final thumb = _activeDurationThumb;
                              if (thumb == Thumb.start) {
                                final start =
                                    (durationRange.start + deltaMinutes)
                                        .clamp(0.0, durationRange.end)
                                        .toDouble();
                                setModalState(() {
                                  durationRange = RangeValues(
                                    start,
                                    durationRange.end,
                                  );
                                });
                              } else if (thumb == Thumb.end) {
                                final end = (durationRange.end + deltaMinutes)
                                    .clamp(durationRange.start, 120.0)
                                    .toDouble();
                                setModalState(() {
                                  durationRange = RangeValues(
                                    durationRange.start,
                                    end,
                                  );
                                });
                              }
                            },
                            onHorizontalDragEnd: (_) => finishDurationDrag(),
                            onHorizontalDragCancel: finishDurationDrag,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                IgnorePointer(
                                  child: RangeSlider(
                                    values: durationRange,
                                    min: 0,
                                    max: 120,
                                    divisions: 120,
                                    activeColor: const Color(0xFFFF0033),
                                    inactiveColor: const Color(0xFF444444),
                                    onChanged: (_) {},
                                  ),
                                ),
                                for (final thumb in [Thumb.start, Thumb.end])
                                  Positioned(
                                    left:
                                        trackInset +
                                        (thumb == Thumb.start
                                                ? durationRange.start
                                                : durationRange.end) /
                                            120 *
                                            trackWidth -
                                        11,
                                    child: IgnorePointer(
                                      child: AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 120,
                                        ),
                                        width: 22,
                                        height: 22,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: const Color(0xFFFF0033),
                                          border: Border.all(
                                            color: Colors.white,
                                            width: _activeDurationThumb == thumb
                                                ? 2.5
                                                : 1.5,
                                          ),
                                          boxShadow: [
                                            if (_activeDurationThumb == thumb)
                                              BoxShadow(
                                                color: const Color(
                                                  0xFFFF0033,
                                                ).withValues(alpha: 0.55),
                                                blurRadius: 14,
                                                spreadRadius: 4,
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF0033),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(
                          'Terapkan (Total $totalVideos Video)',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMobileQuickControlBar() {
    return Container(
      color: const Color(0xFF0F0F0F),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      child: Row(
        children: [
          // Tombol Besar Kanan: Buka Filter Bottom Sheet
          Expanded(
            child: SizedBox(
              height: 40,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF222222),
                  foregroundColor: Colors.amberAccent,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: const BorderSide(color: Color(0xFF3A3A3A)),
                  ),
                ),
                icon: const Icon(
                  Icons.tune,
                  size: 18,
                  color: Colors.amberAccent,
                ),
                label: const Text(
                  'Filter & Urutkan',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: Colors.amberAccent,
                  ),
                ),
                onPressed: _showMobileFilterBottomSheet,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileActiveFilterBar() {
    return Container(
      color: const Color(0xFF0F0F0F),
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            // CHIP WILAYAH: [🌐 Semua] [🇮🇩 Nasional] [🌍 Internasional] LANGSUNG DI LAYAR!
            ...[
              ('all', '🌐 Semua'),
              ('Nasional', '🇮🇩 Nasional'),
              ('Internasional', '🌍 Internasional'),
              ('Belum diketahui', 'Belum diketahui'),
            ].map((reg) {
              final active = selectedRegion == reg.$1;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(reg.$2),
                  selected: active,
                  selectedColor: reg.$1 == 'Nasional'
                      ? const Color(0xFFD32F2F)
                      : (reg.$1 == 'Internasional'
                            ? const Color(0xFF1976D2)
                            : (reg.$1 == 'Belum diketahui'
                                  ? const Color(0xFF616161)
                                  : Colors.white)),
                  backgroundColor: const Color(0xFF222222),
                  labelStyle: TextStyle(
                    color: active
                        ? (reg.$1 == 'all' ? Colors.black : Colors.white)
                        : Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 11.5,
                  ),
                  onSelected: (_) {
                    setState(() {
                      selectedRegion = reg.$1;
                      currentPage = 1;
                    });
                    _saveUiPreferences();
                    _fetchVideos();
                  },
                ),
              );
            }),
            const SizedBox(width: 4),
            // Tombol Urutan aktif
            ActionChip(
              backgroundColor: const Color(0xFF222222),
              side: const BorderSide(color: Color(0xFF383838)),
              label: Text(
                sortBy == 'views'
                    ? '🔥 View'
                    : (sortBy == 'likes' ? '👍 Like' : '🕒 Waktu'),
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              onPressed: _showMobileFilterBottomSheet,
            ),
            const SizedBox(width: 6),
            ActionChip(
              backgroundColor: const Color(0xFF222222),
              side: const BorderSide(color: Color(0xFF383838)),
              label: Text(
                '$limit Video',
                style: const TextStyle(fontSize: 11.5, color: Colors.white70),
              ),
              onPressed: _showMobileFilterBottomSheet,
            ),
            const SizedBox(width: 8),
            Text(
              'Total: $totalVideos',
              style: const TextStyle(fontSize: 11, color: Colors.white38),
            ),
          ],
        ),
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
    final isCustomYear =
        period.endsWith('y') &&
        int.tryParse(period.substring(0, period.length - 1)) != null;

    final sorts = [
      ('views', '🔥 View Terbanyak'),
      ('likes', '👍 Like Terbanyak'),
      ('time', '🕒 Waktu Upload'),
    ];

    if (filterMinimized) {
      final sortLabel = sorts
          .firstWhere((s) => s.$1 == sortBy, orElse: () => sorts.last)
          .$2;
      final periodLabel = isCustomYear
          ? '${period.substring(0, period.length - 1)} Tahun Lalu'
          : periods
                .firstWhere((p) => p.$1 == period, orElse: () => periods.first)
                .$2;
      final regionLabel = selectedRegion == 'Nasional'
          ? '🇮🇩 Nasional'
          : (selectedRegion == 'Internasional'
                ? '🌍 Internasional'
                : '🌐 Semua Wilayah');
      return Container(
        color: const Color(0xFF0F0F0F),
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 12 : 16,
          vertical: isMobile ? 2 : 4,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$sortLabel  •  $regionLabel  •  $periodLabel  •  Durasi: ${_formatMinutesLabel(durationRange.start.round())} – ${_formatMinutesLabel(durationRange.end.round(), isMax: true)}  •  $limit Video/Tab  •  Total: $totalVideos video',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ),
            if (!isMobile)
              TextButton.icon(
                icon: const Icon(
                  Icons.expand_more,
                  size: 18,
                  color: Colors.amberAccent,
                ),
                label: const Text(
                  'Buka Filter',
                  style: TextStyle(fontSize: 12.5, color: Colors.amberAccent),
                ),
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
        style: TextStyle(
          fontSize: 13,
          color: Colors.white70,
          fontWeight: FontWeight.w600,
        ),
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
            _saveUiPreferences();
            _fetchVideos();
          },
        );
      }),
      const SizedBox(width: 8),
      const Text(
        'Wilayah:',
        style: TextStyle(
          fontSize: 13,
          color: Colors.white70,
          fontWeight: FontWeight.w600,
        ),
      ),
      ...[
        ('all', '🌐 Semua'),
        ('Nasional', '🇮🇩 Nasional'),
        ('Internasional', '🌍 Internasional'),
        ('Belum diketahui', 'Belum diketahui'),
      ].map((reg) {
        final active = selectedRegion == reg.$1;
        return ChoiceChip(
          label: Text(reg.$2),
          selected: active,
          selectedColor: reg.$1 == 'Nasional'
              ? const Color(0xFFD32F2F)
              : (reg.$1 == 'Internasional'
                    ? const Color(0xFF1976D2)
                    : (reg.$1 == 'Belum diketahui'
                          ? const Color(0xFF616161)
                          : Colors.white)),
          backgroundColor: const Color(0xFF272727),
          labelStyle: TextStyle(
            color: active
                ? (reg.$1 == 'all' ? Colors.black : Colors.white)
                : Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
          onSelected: (_) {
            setState(() {
              selectedRegion = reg.$1;
              currentPage = 1;
            });
            _saveUiPreferences();
            _fetchVideos();
          },
        );
      }),
      const SizedBox(width: 8),
      const Text(
        'Tampil per Tab (Permanen):',
        style: TextStyle(
          fontSize: 13,
          color: Colors.white70,
          fontWeight: FontWeight.w600,
        ),
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
          icon: const Icon(
            Icons.expand_less,
            size: 16,
            color: Colors.amberAccent,
          ),
          label: const Text(
            'Minimal',
            style: TextStyle(fontSize: 12, color: Colors.amberAccent),
          ),
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
          color: isCustomYear
              ? const Color(0xFF3A1818)
              : const Color(0xFF272727),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isCustomYear
                ? const Color(0xFFFF0033)
                : const Color(0xFF444444),
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
      padding: EdgeInsets.fromLTRB(
        isMobile ? 10 : 16,
        4,
        isMobile ? 10 : 16,
        8,
      ),
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
                const Icon(
                  Icons.timer_outlined,
                  size: 18,
                  color: Color(0xFFFF0033),
                ),
                const SizedBox(width: 8),
                Text(
                  isMobile
                      ? _formatMinutesLabel(durationRange.start.round())
                      : 'Durasi: Minimal ${_formatMinutesLabel(durationRange.start.round())}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFFFF0033),
                      inactiveTrackColor: const Color(0xFF383838),
                      thumbColor: Colors.white,
                      overlayColor: const Color(0x33FF0033),
                      thumbSelector: _durationThumbSelector,
                      rangeThumbShape: const RoundRangeSliderThumbShape(
                        enabledThumbRadius: 9,
                      ),
                    ),
                    child: RangeSlider(
                      values: durationRange,
                      min: 0,
                      max: 120,
                      divisions: 120,
                      labels: RangeLabels(
                        _formatMinutesLabel(durationRange.start.round()),
                        _formatMinutesLabel(
                          durationRange.end.round(),
                          isMax: true,
                        ),
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
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                if (durationRange.start.round() > 0 ||
                    durationRange.end.round() < 120) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
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
                    child: const Text(
                      'Reset',
                      style: TextStyle(fontSize: 12, color: Colors.amberAccent),
                    ),
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
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: Colors.white70,
            ),
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
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
                items: List.generate(totalPages, (idx) {
                  final pageNum = idx + 1;
                  final startItem = idx * limit + 1;
                  final endItem = ((idx + 1) * limit > totalVideos)
                      ? totalVideos
                      : (idx + 1) * limit;
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
            delegate: SliverChildBuilderDelegate((context, index) {
              final v = videos[index];
              return _buildVideoCard(v);
            }, childCount: videos.length),
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
    final vHp = int.tryParse((v['views_hp'] ?? 0).toString()) ?? 0;
    final vLap = int.tryParse((v['views_laptop'] ?? 0).toString()) ?? 0;
    final vTot =
        int.tryParse((v['views_total'] ?? 0).toString()) ?? (vHp + vLap);
    final creatorWatched = _getCreatorWatchedCount(channelId, v);
    final watchedCount = vTot > 0 ? vTot : creatorWatched;
    final videoRegion = (v['region'] ?? 'Belum diketahui').toString();

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
                      child: const Center(
                        child: Icon(
                          Icons.ondemand_video,
                          size: 42,
                          color: Colors.white38,
                        ),
                      ),
                    ),
                  ),
                ),
                if (duration.isNotEmpty)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
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
                backgroundImage: channelThumb.isNotEmpty
                    ? NetworkImage(channelThumb)
                    : null,
                onBackgroundImageError: channelThumb.isNotEmpty
                    ? (_, _) {}
                    : null,
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
                            '$channelTitle ${videoRegion == "Nasional" ? "🇮🇩" : (videoRegion == "Internasional" ? "🌍" : "❔")}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFFAAAAAA),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.check_circle,
                          size: 13,
                          color: Color(0xFFAAAAAA),
                        ),
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
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFFAAAAAA),
                          ),
                        ),
                        const Text(
                          '•',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFFAAAAAA),
                          ),
                        ),
                        Text(
                          _formatTimeAgo(publishedAt),
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFFAAAAAA),
                          ),
                        ),
                        const Text(
                          '•',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFFAAAAAA),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1.5,
                          ),
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
                        Tooltip(
                          message:
                              'Total: $watchedCount view\n📱 HP: $vHp view | 💻 Laptop: $vLap view\nWilayah: $videoRegion',
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: watchedCount > 0
                                  ? const Color(0xFF1E3A2F)
                                  : const Color(0xFF272727),
                              borderRadius: BorderRadius.circular(4),
                              border: watchedCount > 0
                                  ? Border.all(
                                      color: const Color(0xFF2E7D32),
                                      width: 0.8,
                                    )
                                  : null,
                            ),
                            child: Text(
                              '▶ $watchedCount view',
                              style: TextStyle(
                                fontSize: 12,
                                color: watchedCount > 0
                                    ? const Color(0xFF81C784)
                                    : Colors.white70,
                                fontWeight: FontWeight.w600,
                              ),
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
                icon: const Icon(
                  Icons.more_vert,
                  size: 20,
                  color: Colors.white70,
                ),
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
                    enabled:
                        false, // Agar klik biasa tidak langsung menutup menu; harus ditahan (hold) beberapa detik
                    padding: EdgeInsets.zero,
                    child: _HoldToUnsubscribeMenuItem(
                      channelTitle: channelTitle,
                      fastModeActive:
                          skipUnsubscribeConfirmUntil != null &&
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
                        const Icon(
                          Icons.video_library_outlined,
                          color: Colors.white70,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text('Lihat Semua Video $channelTitle'),
                        ),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'open_yt',
                    child: Row(
                      children: [
                        Icon(
                          Icons.open_in_new,
                          color: Colors.white70,
                          size: 18,
                        ),
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
  State<_HoldToUnsubscribeMenuItem> createState() =>
      _HoldToUnsubscribeMenuItemState();
}

class _HoldToUnsubscribeMenuItemState
    extends State<_HoldToUnsubscribeMenuItem> {
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
                      : const Icon(
                          Icons.person_remove,
                          color: Color(0xFFFF4E4E),
                          size: 18,
                        ),
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
