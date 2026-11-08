import math
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

DB_PATH = Path(__file__).parent / "youtube_personal.db"


def get_conn() -> sqlite3.Connection:
    # ponytail: sqlite connection per request with WAL, sufficient for personal single-user app
    conn = sqlite3.connect(DB_PATH, timeout=30.0)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def duration_to_seconds(dur_str: str) -> int:
    if not dur_str:
        return 0
    parts = [int(p) for p in dur_str.split(":") if p.isdigit()]
    if len(parts) == 3:
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    if len(parts) == 2:
        return parts[0] * 60 + parts[1]
    if len(parts) == 1:
        return parts[0]
    return 0


def init_db() -> None:
    with get_conn() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS channels (
                channel_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                handle TEXT DEFAULT '',
                thumbnail_url TEXT DEFAULT '',
                uploads_playlist_id TEXT NOT NULL,
                source TEXT DEFAULT 'manual',
                added_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS videos (
                video_id TEXT PRIMARY KEY,
                channel_id TEXT NOT NULL,
                channel_title TEXT NOT NULL,
                channel_thumbnail TEXT DEFAULT '',
                title TEXT NOT NULL,
                thumbnail_url TEXT NOT NULL,
                published_at TEXT NOT NULL,
                view_count INTEGER DEFAULT 0,
                like_count INTEGER DEFAULT 0,
                duration TEXT DEFAULT '',
                duration_seconds INTEGER DEFAULT 0,
                is_demo INTEGER DEFAULT 0,
                FOREIGN KEY (channel_id) REFERENCES channels(channel_id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_videos_published ON videos(published_at DESC);
            CREATE INDEX IF NOT EXISTS idx_videos_views ON videos(view_count DESC);
            CREATE INDEX IF NOT EXISTS idx_videos_likes ON videos(like_count DESC);
            CREATE INDEX IF NOT EXISTS idx_videos_channel ON videos(channel_id);
            """
        )
        # Tambahkan kolom yt_video_count, subscriber_count, & watched_count jika belum ada
        cols = [r["name"] for r in conn.execute("PRAGMA table_info(channels)").fetchall()]
        if "yt_video_count" not in cols:
            conn.execute("ALTER TABLE channels ADD COLUMN yt_video_count INTEGER DEFAULT 0")
        if "subscriber_count" not in cols:
            conn.execute("ALTER TABLE channels ADD COLUMN subscriber_count INTEGER DEFAULT 0")
        if "watched_count" not in cols:
            conn.execute("ALTER TABLE channels ADD COLUMN watched_count INTEGER DEFAULT 0")

        v_cols = [r["name"] for r in conn.execute("PRAGMA table_info(videos)").fetchall()]
        if "duration_seconds" not in v_cols:
            conn.execute("ALTER TABLE videos ADD COLUMN duration_seconds INTEGER DEFAULT 0")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_videos_duration ON videos(duration_seconds)")
        # Backfill duration_seconds untuk semua video yang sudah ada di database
        rows = conn.execute("SELECT video_id, duration FROM videos WHERE duration_seconds = 0 AND duration != ''").fetchall()
        if rows:
            conn.executemany(
                "UPDATE videos SET duration_seconds = ? WHERE video_id = ?",
                [(duration_to_seconds(r["duration"]), r["video_id"]) for r in rows],
            )


def get_setting(key: str, default: str = "") -> str:
    with get_conn() as conn:
        row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else default


def set_setting(key: str, value: str) -> None:
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value.strip()),
        )


def upsert_channel(
    channel_id: str,
    title: str,
    handle: str = "",
    thumbnail_url: str = "",
    uploads_playlist_id: str = "",
    source: str = "manual",
) -> None:
    if not uploads_playlist_id and channel_id.startswith("UC"):
        uploads_playlist_id = "UU" + channel_id[2:]
    elif not uploads_playlist_id:
        uploads_playlist_id = channel_id
    now_iso = datetime.now(timezone.utc).isoformat()
    with get_conn() as conn:
        conn.execute(
            """
            INSERT INTO channels(channel_id, title, handle, thumbnail_url, uploads_playlist_id, source, added_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(channel_id) DO UPDATE SET
                title=excluded.title,
                handle=CASE WHEN excluded.handle != '' THEN excluded.handle ELSE channels.handle END,
                thumbnail_url=CASE WHEN excluded.thumbnail_url != '' THEN excluded.thumbnail_url ELSE channels.thumbnail_url END,
                uploads_playlist_id=excluded.uploads_playlist_id
            """,
            (channel_id, title, handle, thumbnail_url, uploads_playlist_id, source, now_iso),
        )


def delete_channel(channel_id: str) -> None:
    import json
    raw = get_setting("unsubscribed_map_json", "{}")
    try:
        unsub_map = json.loads(raw)
        if not isinstance(unsub_map, dict):
            unsub_map = {}
    except Exception:
        unsub_map = {}
    unsub_map[channel_id] = datetime.now(timezone.utc).isoformat()
    set_setting("unsubscribed_map_json", json.dumps(unsub_map))
    with get_conn() as conn:
        conn.execute("DELETE FROM videos WHERE channel_id = ?", (channel_id,))
        conn.execute("DELETE FROM channels WHERE channel_id = ?", (channel_id,))


def clear_demo_data() -> None:
    with get_conn() as conn:
        conn.execute("DELETE FROM videos WHERE is_demo = 1")
        conn.execute("DELETE FROM channels WHERE source = 'demo'")


def upsert_videos(videos: list[dict]) -> int:
    if not videos:
        return 0
    for v in videos:
        if "duration_seconds" not in v:
            v["duration_seconds"] = duration_to_seconds(v.get("duration", ""))
    with get_conn() as conn:
        conn.executemany(
            """
            INSERT INTO videos(
                video_id, channel_id, channel_title, channel_thumbnail,
                title, thumbnail_url, published_at, view_count, like_count, duration, duration_seconds, is_demo
            ) VALUES (
                :video_id, :channel_id, :channel_title, :channel_thumbnail,
                :title, :thumbnail_url, :published_at, :view_count, :like_count, :duration, :duration_seconds, :is_demo
            )
            ON CONFLICT(video_id) DO UPDATE SET
                title=excluded.title,
                thumbnail_url=excluded.thumbnail_url,
                view_count=excluded.view_count,
                like_count=excluded.like_count,
                duration=excluded.duration,
                duration_seconds=excluded.duration_seconds,
                channel_title=excluded.channel_title,
                channel_thumbnail=excluded.channel_thumbnail
            """,
            videos,
        )
    return len(videos)


def increment_channel_watched(channel_id: str) -> int:
    with get_conn() as conn:
        conn.execute(
            "UPDATE channels SET watched_count = COALESCE(watched_count, 0) + 1 WHERE channel_id = ?",
            (channel_id,),
        )
        row = conn.execute(
            "SELECT COALESCE(watched_count, 0) AS watched_count FROM channels WHERE channel_id = ?",
            (channel_id,),
        ).fetchone()
        return int(row["watched_count"]) if row else 0


def list_channels() -> list[dict]:
    with get_conn() as conn:
        rows = conn.execute(
            """
            SELECT c.*,
                   COALESCE(c.watched_count, 0) AS watched_count,
                   COUNT(v.video_id) AS synced_video_count,
                   CASE WHEN c.yt_video_count > COUNT(v.video_id) THEN c.yt_video_count ELSE COUNT(v.video_id) END AS video_count
            FROM channels c
            LEFT JOIN videos v ON v.channel_id = c.channel_id
            GROUP BY c.channel_id
            ORDER BY c.title ASC
            """
        ).fetchall()
        return [dict(r) for r in rows]


def list_channels_for_refresh(rotating_offset: int = 0) -> list[dict]:
    """Urutkan channel untuk Refresh YouTube: prioritaskan yang belum pernah sync + channel paling aktif upload terbaru + rotasi."""
    with get_conn() as conn:
        rows = conn.execute(
            """
            SELECT c.*,
                   COUNT(v.video_id) AS synced_video_count,
                   MAX(v.published_at) AS latest_upload
            FROM channels c
            LEFT JOIN videos v ON v.channel_id = c.channel_id
            WHERE c.channel_id NOT LIKE 'UC_demo_%'
            GROUP BY c.channel_id
            ORDER BY CASE WHEN COUNT(v.video_id) = 0 THEN 0 ELSE 1 END ASC,
                     MAX(v.published_at) DESC,
                     c.title ASC
            """
        ).fetchall()
        all_chs = [dict(r) for r in rows]
        unsynced = [c for c in all_chs if c.get("synced_video_count", 0) == 0][:40]
        synced = [c for c in all_chs if c.get("synced_video_count", 0) > 0]
        # Ambil 40 channel paling aktif (yang baru saja upload) + 30 channel bergilir
        top_active = synced[:40]
        rest = synced[40:]
        if rest:
            start = rotating_offset % len(rest)
            rotated = (rest[start:] + rest[:start])[:30]
        else:
            rotated = []
        return unsynced + top_active + rotated


def period_bounds(period: str, now: datetime | None = None) -> tuple[str | None, str | None]:
    now = now or datetime.now(timezone.utc)
    if period == "week":
        return (now - timedelta(days=7)).isoformat(), None
    if period == "month":
        return (now - timedelta(days=30)).isoformat(), None
    if period == "year":
        return (now - timedelta(days=365)).isoformat(), None
    if period.endswith("y") and period[:-1].isdigit():
        years = int(period[:-1])
        if years >= 1:
            start_dt = (now - timedelta(days=365 * years)).isoformat()
            end_dt = (now - timedelta(days=365 * (years - 1))).isoformat() if years > 1 else None
            return start_dt, end_dt
    return None, None


def query_videos(
    sort_by: str = "time",
    period: str = "all",
    channel_id: str = "",
    q: str = "",
    limit: int = 25,
    page: int = 1,
    min_minutes: int = 0,
    max_minutes: int = 120,
    now: datetime | None = None,
) -> dict:
    limit = limit if limit in (25, 50, 100) else 25
    page = max(1, page)
    offset = (page - 1) * limit

    order_map = {
        "views": "view_count DESC, published_at DESC",
        "likes": "like_count DESC, view_count DESC",
        "time": "published_at DESC",
    }
    order_sql = order_map.get(sort_by, "published_at DESC")
    start_iso, end_iso = period_bounds(period, now=now)

    clauses = ["1=1"]
    params: list = []

    if start_iso:
        clauses.append("published_at >= ?")
        params.append(start_iso)
    if end_iso:
        clauses.append("published_at < ?")
        params.append(end_iso)
    if channel_id:
        clauses.append("channel_id = ?")
        params.append(channel_id)
    if min_minutes > 0:
        clauses.append("duration_seconds >= ?")
        params.append(min_minutes * 60)
    if max_minutes < 120:
        clauses.append("duration_seconds <= ?")
        params.append(max_minutes * 60)
    if q.strip():
        clauses.append("(title LIKE ? OR channel_title LIKE ?)")
        like_q = f"%{q.strip()}%"
        params.extend([like_q, like_q])

    where_sql = " AND ".join(clauses)
    with get_conn() as conn:
        total = conn.execute(f"SELECT COUNT(*) FROM videos WHERE {where_sql}", params).fetchone()[0]
        rows = conn.execute(
            f"SELECT videos.*, COALESCE((SELECT watched_count FROM channels c WHERE c.channel_id = videos.channel_id), 0) AS watched_count FROM videos WHERE {where_sql} ORDER BY {order_sql} LIMIT ? OFFSET ?",
            [*params, limit, offset],
        ).fetchall()

    total_pages = max(1, math.ceil(total / limit))
    return {
        "items": [dict(r) for r in rows],
        "total": total,
        "page": page,
        "limit": limit,
        "total_pages": total_pages,
    }


def seed_demo_if_empty() -> None:
    with get_conn() as conn:
        count = conn.execute("SELECT COUNT(*) FROM channels").fetchone()[0]
        if count > 0:
            return

    now = datetime.now(timezone.utc)
    # Channel sesuai referensi gambar screenshot user
    demo_channels = [
        ("UC_demo_fajrul", "Fajrul Fx", "@FajrulFx", "https://i.ytimg.com/vi/M7lc1UVf-VE/hqdefault.jpg"),
        ("UC_demo_anim", "Animated History", "@AnimatedHistory", "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"),
        ("UC_demo_malaka", "MALAKA", "@malaka_project", "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg"),
        ("UC_demo_radit", "Raditya Dika", "@RadityaDika", "https://i.ytimg.com/vi/9bZkp7q19f0/hqdefault.jpg"),
        ("UC_demo_justin", "Justin Sung", "@JustinSung", "https://i.ytimg.com/vi/kJQP7kiw5Fk/hqdefault.jpg"),
        ("UC_demo_ferry", "Ferry Irwandi", "@FerryIrwandi", "https://i.ytimg.com/vi/RgKAFK5djSk/hqdefault.jpg"),
    ]
    for cid, title, handle, thumb in demo_channels:
        upsert_channel(cid, title, handle, thumb, "UU" + cid[2:], source="demo")

    # Thumbnails valid YouTube agar tampil menarik di grid 3 kolom
    yt_thumbs = [
        "dQw4w9WgXcQ", "M7lc1UVf-VE", "jNQXAC9IVRw", "9bZkp7q19f0",
        "kJQP7kiw5Fk", "RgKAFK5djSk", "OPf0YbXqDm0", "fJ9rUzIMcZQ",
        "CevxZvSJLk8", "JGwWNGJdvx8", "YQHsXMglC9A", "hT_nvWreIhg",
    ]

    base_samples = [
        # Minggu ini (0 - 6 hari lalu)
        ("UC_demo_ferry", "Ferry Irwandi", "Kenapa Bank Terbesar di Paraguay Bisa Kolaps? - Kasus Ueno", 1, 512_000, 41_200, "18:13"),
        ("UC_demo_fajrul", "Fajrul Fx", "Apa yang Terjadi pada Tubuh Saat Makan Sekali Sehari (Jam demi Jam)", 2, 440_000, 32_900, "10:18"),
        ("UC_demo_malaka", "MALAKA", "Cara Berpikir Kritis di Era Banjir Informasi (Minggu Ini)", 3, 690_000, 58_100, "24:14"),
        ("UC_demo_radit", "Raditya Dika", "Stand Up Comedy Spesial Minggu Ini: Cerita Finansial", 4, 920_000, 74_500, "31:45"),
        ("UC_demo_justin", "Justin Sung", "How to Study 3x Faster Without Memorizing (This Week)", 5, 310_000, 27_400, "16:20"),
        ("UC_demo_anim", "Animated History", "Sejarah Runtuhnya Kekaisaran Romawi dalam 15 Menit", 6, 780_000, 63_000, "15:08"),
        # Bulan ini (8 - 29 hari lalu)
        ("UC_demo_ferry", "Ferry Irwandi", "Bedah Logika & Stoikisme Untuk Anak Muda (Bulan Ini)", 9, 830_000, 69_300, "28:40"),
        ("UC_demo_malaka", "MALAKA", "Pendidikan & Masa Depan Kerja di Indonesia", 12, 1_120_000, 94_000, "42:10"),
        ("UC_demo_radit", "Raditya Dika", "Podcast Cerita Horor Kantor Baru (Bulan Ini)", 15, 1_450_000, 112_000, "54:20"),
        ("UC_demo_fajrul", "Fajrul Fx", "Eksperimen Sains: Tidur 4 Jam vs 8 Jam Selama Sebulan", 19, 610_000, 48_700, "14:55"),
        ("UC_demo_justin", "Justin Sung", "Mind Mapping Technique for Deep Understanding", 23, 495_000, 39_100, "21:12"),
        ("UC_demo_anim", "Animated History", "Perang Dunia II dari Sudut Pandang Ekonomi", 27, 950_000, 81_200, "19:33"),
        # Tahun ini (45 - 340 hari lalu)
        ("UC_demo_radit", "Raditya Dika", "Tur Rumah Baru & Studio Podcast (Tahun Ini)", 65, 2_850_000, 198_000, "38:15"),
        ("UC_demo_ferry", "Ferry Irwandi", "Investigasi Fenomena Judi Online & Psikologi Bandar", 110, 3_600_000, 285_000, "35:48"),
        ("UC_demo_malaka", "MALAKA", "Monolog: Kenapa Kita Sering Merasa Tertinggal?", 160, 1_940_000, 164_000, "29:10"),
        ("UC_demo_fajrul", "Fajrul Fx", "Fisika Kuantum Dijelaskan dengan Bahasa Tongkrongan", 210, 1_150_000, 97_500, "17:42"),
        ("UC_demo_justin", "Justin Sung", "Complete Guide to Self-Regulated Learning (This Year)", 260, 870_000, 71_000, "26:05"),
        ("UC_demo_anim", "Animated History", "Kebangkitan dan Keruntuhan Majapahit (Animasi Lengkap)", 310, 2_210_000, 175_000, "33:20"),
        # 2 Tahun Lalu (400 - 700 hari lalu)
        ("UC_demo_ferry", "Ferry Irwandi", "Revolusi Industri Kreatif & Konten (2 Tahun Lalu)", 420, 1_420_000, 108_000, "22:18"),
        ("UC_demo_radit", "Raditya Dika", "Belajar Investasi dari Nol untuk Pemula (2 Tahun Lalu)", 480, 3_100_000, 240_000, "41:00"),
        ("UC_demo_malaka", "MALAKA", "Episode Perdana: Membangun Manusia Merdeka (2 Tahun Lalu)", 530, 2_540_000, 215_000, "47:30"),
        ("UC_demo_fajrul", "Fajrul Fx", "Sejarah Penemuan Listrik & Konflik Tesla vs Edison", 590, 980_000, 82_400, "16:11"),
        ("UC_demo_justin", "Justin Sung", "Why Re-reading Notes Does Not Work (2 Years Ago)", 640, 1_320_000, 104_000, "15:45"),
        ("UC_demo_anim", "Animated History", "Peta Perdagangan Jalur Sutra Kuno (2 Tahun Lalu)", 690, 1_650_000, 129_000, "20:04"),
        # 3 Tahun Lalu (760 - 1050 hari lalu)
        ("UC_demo_radit", "Raditya Dika", "Cerita Masa Kuliah di Luar Negeri (3 Tahun Lalu)", 790, 4_200_000, 310_000, "27:50"),
        ("UC_demo_ferry", "Ferry Irwandi", "Mindset Keuangan di Usia 20-an (3 Tahun Lalu)", 850, 1_780_000, 142_000, "19:25"),
        ("UC_demo_fajrul", "Fajrul Fx", "Bagaimana Cara Kerja Mesin Waktu Menurut Teori Relativitas?", 910, 1_540_000, 126_000, "14:30"),
        ("UC_demo_justin", "Justin Sung", "Top 1% Student Study Routine (3 Years Ago)", 960, 2_450_000, 195_000, "18:55"),
        ("UC_demo_anim", "Animated History", "Sejarah Nusantara Sebelum Era Kolonial (3 Tahun Lalu)", 1020, 2_890_000, 224_000, "25:40"),
        ("UC_demo_malaka", "MALAKA", "Diskusi Filsafat klasik untuk Kehidupan Modern (3 Tahun Lalu)", 1060, 1_190_000, 96_000, "36:12"),
        # 4 Tahun Lalu (1120 - 1420 hari lalu)
        ("UC_demo_radit", "Raditya Dika", "Bongkar Rahasia Menulis Buku & Skenario Film (4 Tahun Lalu)", 1150, 3_850_000, 290_000, "34:10"),
        ("UC_demo_fajrul", "Fajrul Fx", "Video Sains Pertama: Kenapa Langit Berwarna Biru? (4 Tahun Lalu)", 1220, 890_000, 73_000, "11:20"),
        ("UC_demo_justin", "Justin Sung", "How I Transitioned from Medical School to Teaching (4 Years Ago)", 1290, 1_620_000, 134_000, "22:00"),
        ("UC_demo_anim", "Animated History", "Asal Usul Peradaban Mesopotamia (4 Tahun Lalu)", 1350, 3_120_000, 248_000, "21:45"),
        ("UC_demo_ferry", "Ferry Irwandi", "Belajar Videografi & Storytelling Sinematik (4 Tahun Lalu)", 1400, 1_250_000, 99_500, "16:50"),
        ("UC_demo_malaka", "MALAKA", "Arsip Pemikiran: Membaca Ulang Sejarah Bangsa (4 Tahun Lalu)", 1430, 1_410_000, 115_000, "39:05"),
    ]

    video_rows = []
    for idx, (cid, ctitle, vtitle, days_ago, views, likes, dur) in enumerate(base_samples):
        yt_id = yt_thumbs[idx % len(yt_thumbs)]
        vid = f"demo_{idx + 1:02d}_{yt_id}"
        pub = (now - timedelta(days=days_ago)).isoformat()
        video_rows.append(
            {
                "video_id": vid,
                "channel_id": cid,
                "channel_title": ctitle,
                "channel_thumbnail": f"https://i.ytimg.com/vi/{yt_id}/default.jpg",
                "title": vtitle,
                "thumbnail_url": f"https://i.ytimg.com/vi/{yt_id}/hqdefault.jpg",
                "published_at": pub,
                "view_count": views,
                "like_count": likes,
                "duration": dur,
                "is_demo": 1,
            }
        )
    upsert_videos(video_rows)


if __name__ == "__main__":
    init_db()
    seed_demo_if_empty()
    p1 = query_videos(sort_by="views", period="all", limit=25, page=1)
    assert p1["total"] >= 36, f"Expected >= 36 demo videos, got {p1['total']}"
    assert len(p1["items"]) == 25, "Limit 25 should return 25 items on page 1"
    assert p1["total_pages"] >= 2, "Should have at least 2 pages for 36 items with limit 25"
    p2 = query_videos(sort_by="views", period="all", limit=25, page=2)
    assert len(p2["items"]) >= 11, "Page 2 should have remaining items"
    assert p1["items"][0]["view_count"] >= p1["items"][-1]["view_count"], "Views sort check"
    likes_res = query_videos(sort_by="likes", period="all", limit=50, page=1)
    assert likes_res["items"][0]["like_count"] >= likes_res["items"][-1]["like_count"], "Likes sort check"
    for period_key in ("week", "month", "year", "2y", "3y", "4y"):
        r = query_videos(sort_by="time", period=period_key, limit=25, page=1)
        assert r["total"] >= 5, f"Period {period_key} should have videos"
    print("db.py self-check passed!")
