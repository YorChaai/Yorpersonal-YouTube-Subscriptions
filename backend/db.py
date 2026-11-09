import json
import math
import re
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

DB_PATH = Path(__file__).parent / "youtube_personal.db"

ID_KEYWORDS = {
    "indonesia", "nusantara", "sejarah", "sarjana", "bicara", "cerita", "horor", "tongkrongan",
    "berkelas", "revolusi", "santai", "kepo", "terang", "menit", "hukum", "politik", "opini",
    "kompas", "detik", "tribun", "liputan", "tempo", "kumparan", "merdeka", "suara", "tvone",
    "inews", "trans7", "antv", "sctv", "mnc", "rcti", "netmediatama", "narasi", "mojok",
    "asumsi", "tirto", "katadata", "idntimes", "fajrul", "ferry", "raditya", "radit", "malaka",
    "irwandi", "dea", "leonardo", "eno", "raymond", "sumargo", "curhat", "timothy", "ronald",
    "corbuzier", "yahya", "milyhya", "hapsah", "tretan", "choki", "pandji", "standup",
    "ngobrol", "bocah", "kabar", "warta", "sinema", "jawa", "sunda", "bali", "jakarta",
    "bandung", "jogja", "surabaya", "indo", "indonesian", "film", "misteri", "hiburan",
    "belajar", "resep", "kuliner", "makan", "masak", "dapur", "anak", "islam", "dakwah",
    "ustadz", "kajian", "gus", "habib", "santri", "pesantren", "berita", "fakta",
    "gadgetin", "jagat", "sobat", "ruang", "bumi", "kreatif", "karya",
}


def classify_region(title: str, handle: str = "", country: str = "", default_lang: str = "") -> str:
    cntry = (country or "").strip().upper()
    lang = (default_lang or "").strip().lower()
    if cntry == "ID" or lang.startswith("id"):
        return "Nasional"
    text = f"{title or ''} {handle or ''}".lower()
    words = re.findall(r"[a-zA-Z0-9]+", text)
    if any(w in ID_KEYWORDS for w in words):
        return "Nasional"
    h_low = (handle or "").lower()
    if h_low.endswith("id") or "_id" in h_low or ".id" in h_low or "indonesia" in text:
        return "Nasional"
    if cntry and cntry != "ID":
        return "Internasional"
    return "Internasional"


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
        for alter_sql in (
            "ALTER TABLE channels ADD COLUMN yt_video_count INTEGER DEFAULT 0",
            "ALTER TABLE channels ADD COLUMN subscriber_count INTEGER DEFAULT 0",
            "ALTER TABLE channels ADD COLUMN watched_count INTEGER DEFAULT 0",
            "ALTER TABLE channels ADD COLUMN region TEXT DEFAULT 'Nasional'",
            "ALTER TABLE channels ADD COLUMN status TEXT DEFAULT 'subscribed'",
            "ALTER TABLE channels ADD COLUMN views_hp INTEGER DEFAULT 0",
            "ALTER TABLE channels ADD COLUMN views_laptop INTEGER DEFAULT 0",
            "ALTER TABLE channels ADD COLUMN views_total INTEGER GENERATED ALWAYS AS (COALESCE(views_hp, 0) + COALESCE(views_laptop, 0)) VIRTUAL",
            "ALTER TABLE channels ADD COLUMN updated_at TEXT DEFAULT ''",
            "ALTER TABLE videos ADD COLUMN duration_seconds INTEGER DEFAULT 0",
            "ALTER TABLE videos ADD COLUMN region TEXT DEFAULT 'Nasional'",
            "ALTER TABLE videos ADD COLUMN views_hp INTEGER DEFAULT 0",
            "ALTER TABLE videos ADD COLUMN views_laptop INTEGER DEFAULT 0",
            "ALTER TABLE videos ADD COLUMN views_total INTEGER GENERATED ALWAYS AS (COALESCE(views_hp, 0) + COALESCE(views_laptop, 0)) VIRTUAL",
            "ALTER TABLE videos ADD COLUMN updated_at TEXT DEFAULT ''",
        ):
            try:
                conn.execute(alter_sql)
            except sqlite3.OperationalError:
                pass

        conn.execute("CREATE INDEX IF NOT EXISTS idx_videos_duration ON videos(duration_seconds)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_videos_region ON videos(region)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_channels_region ON channels(region)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_channels_status ON channels(status)")

        now_iso = datetime.now(timezone.utc).isoformat()
        conn.execute("UPDATE channels SET updated_at = ? WHERE updated_at IS NULL OR updated_at = ''", (now_iso,))
        conn.execute("UPDATE videos SET updated_at = ? WHERE updated_at IS NULL OR updated_at = ''", (now_iso,))
        conn.execute("UPDATE channels SET status = 'subscribed' WHERE status IS NULL OR status = ''")
        conn.execute("UPDATE channels SET views_laptop = watched_count WHERE watched_count > 0 AND views_laptop = 0 AND views_hp = 0")

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
    region: str = "",
    country: str = "",
    status: str = "subscribed",
    force_subscribe: bool = False,
) -> None:
    if not uploads_playlist_id and channel_id.startswith("UC"):
        uploads_playlist_id = "UU" + channel_id[2:]
    elif not uploads_playlist_id:
        uploads_playlist_id = channel_id
    if not region:
        region = classify_region(title, handle, country=country)
    now_iso = datetime.now(timezone.utc).isoformat()
    with get_conn() as conn:
        if force_subscribe:
            conn.execute(
                """
                INSERT INTO channels(channel_id, title, handle, thumbnail_url, uploads_playlist_id, source, added_at, region, status, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'subscribed', ?)
                ON CONFLICT(channel_id) DO UPDATE SET
                    title=excluded.title,
                    handle=CASE WHEN excluded.handle != '' THEN excluded.handle ELSE channels.handle END,
                    thumbnail_url=CASE WHEN excluded.thumbnail_url != '' THEN excluded.thumbnail_url ELSE channels.thumbnail_url END,
                    uploads_playlist_id=excluded.uploads_playlist_id,
                    region=CASE WHEN excluded.region != '' THEN excluded.region ELSE channels.region END,
                    status='subscribed',
                    updated_at=excluded.updated_at
                """,
                (channel_id, title, handle, thumbnail_url, uploads_playlist_id, source, now_iso, region, now_iso),
            )
        else:
            conn.execute(
                """
                INSERT INTO channels(channel_id, title, handle, thumbnail_url, uploads_playlist_id, source, added_at, region, status, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(channel_id) DO UPDATE SET
                    title=excluded.title,
                    handle=CASE WHEN excluded.handle != '' THEN excluded.handle ELSE channels.handle END,
                    thumbnail_url=CASE WHEN excluded.thumbnail_url != '' THEN excluded.thumbnail_url ELSE channels.thumbnail_url END,
                    uploads_playlist_id=excluded.uploads_playlist_id,
                    region=CASE WHEN channels.region IS NULL OR channels.region = '' THEN excluded.region ELSE channels.region END
                """,
                (channel_id, title, handle, thumbnail_url, uploads_playlist_id, source, now_iso, region, status, now_iso),
            )


def delete_channel(channel_id: str) -> None:
    now_iso = datetime.now(timezone.utc).isoformat()
    raw = get_setting("unsubscribed_map_json", "{}")
    try:
        unsub_map = json.loads(raw)
        if not isinstance(unsub_map, dict):
            unsub_map = {}
    except Exception:
        unsub_map = {}
    unsub_map[channel_id] = now_iso
    set_setting("unsubscribed_map_json", json.dumps(unsub_map))
    with get_conn() as conn:
        conn.execute("DELETE FROM videos WHERE channel_id = ?", (channel_id,))
        row = conn.execute("SELECT channel_id FROM channels WHERE channel_id = ?", (channel_id,)).fetchone()
        if row:
            conn.execute(
                "UPDATE channels SET status = 'unfollowed', updated_at = ? WHERE channel_id = ?",
                (now_iso, channel_id),
            )
        else:
            conn.execute(
                """
                INSERT INTO channels(channel_id, title, uploads_playlist_id, source, added_at, status, updated_at)
                VALUES (?, ?, ?, 'unfollowed', ?, 'unfollowed', ?)
                """,
                (channel_id, channel_id, channel_id, now_iso, now_iso),
            )


def subscribe_channel(channel_id: str) -> None:
    now_iso = datetime.now(timezone.utc).isoformat()
    raw = get_setting("unsubscribed_map_json", "{}")
    try:
        unsub_map = json.loads(raw)
        if isinstance(unsub_map, dict) and channel_id in unsub_map:
            del unsub_map[channel_id]
            set_setting("unsubscribed_map_json", json.dumps(unsub_map))
    except Exception:
        pass
    with get_conn() as conn:
        conn.execute(
            "UPDATE channels SET status = 'subscribed', updated_at = ? WHERE channel_id = ?",
            (now_iso, channel_id),
        )


def set_channel_region(channel_id: str, region: str) -> str:
    reg = "Nasional" if region == "Nasional" else "Internasional"
    now_iso = datetime.now(timezone.utc).isoformat()
    with get_conn() as conn:
        conn.execute(
            "UPDATE channels SET region = ?, updated_at = ? WHERE channel_id = ?",
            (reg, now_iso, channel_id),
        )
        conn.execute(
            "UPDATE videos SET region = ?, updated_at = ? WHERE channel_id = ?",
            (reg, now_iso, channel_id),
        )
    return reg


def clear_demo_data() -> None:
    with get_conn() as conn:
        conn.execute("DELETE FROM videos WHERE is_demo = 1")
        conn.execute("DELETE FROM channels WHERE source = 'demo'")


def upsert_videos(videos: list[dict]) -> int:
    if not videos:
        return 0
    now_iso = datetime.now(timezone.utc).isoformat()
    with get_conn() as conn:
        ch_rows = conn.execute("SELECT channel_id, region, status FROM channels").fetchall()
        ch_region_map = {r["channel_id"]: (r["region"] or "Nasional") for r in ch_rows}
        unfollowed_set = {r["channel_id"] for r in ch_rows if r["status"] == "unfollowed"}

        filtered_videos = []
        for v in videos:
            cid = v.get("channel_id", "")
            # Filter Masuk (Ingress Gate): buang video dari channel yang berstatus unfollowed
            if cid in unfollowed_set:
                continue
            if "duration_seconds" not in v:
                v["duration_seconds"] = duration_to_seconds(v.get("duration", ""))
            if not v.get("region"):
                v["region"] = ch_region_map.get(cid) or classify_region(v.get("channel_title", ""))
            if not v.get("updated_at"):
                v["updated_at"] = now_iso
            filtered_videos.append(v)

        if not filtered_videos:
            return 0

        # Menjaga Kolom View: views_hp dan views_laptop lokal TIDAK ditimpa saat refresh Google API
        conn.executemany(
            """
            INSERT INTO videos(
                video_id, channel_id, channel_title, channel_thumbnail,
                title, thumbnail_url, published_at, view_count, like_count,
                duration, duration_seconds, is_demo, region, updated_at
            ) VALUES (
                :video_id, :channel_id, :channel_title, :channel_thumbnail,
                :title, :thumbnail_url, :published_at, :view_count, :like_count,
                :duration, :duration_seconds, :is_demo, :region, :updated_at
            )
            ON CONFLICT(video_id) DO UPDATE SET
                title=excluded.title,
                thumbnail_url=excluded.thumbnail_url,
                view_count=excluded.view_count,
                like_count=excluded.like_count,
                duration=excluded.duration,
                duration_seconds=excluded.duration_seconds,
                channel_title=excluded.channel_title,
                channel_thumbnail=excluded.channel_thumbnail,
                region=excluded.region
            """,
            filtered_videos,
        )
    return len(filtered_videos)


def record_watch(channel_id: str, video_id: str = "", device: str = "laptop") -> dict:
    dev = "hp" if str(device).lower() == "hp" else "laptop"
    col = "views_hp" if dev == "hp" else "views_laptop"
    now_iso = datetime.now(timezone.utc).isoformat()
    with get_conn() as conn:
        if video_id:
            conn.execute(
                f"UPDATE videos SET {col} = COALESCE({col}, 0) + 1, updated_at = ? WHERE video_id = ?",
                (now_iso, video_id),
            )
            if not channel_id:
                v_row = conn.execute("SELECT channel_id FROM videos WHERE video_id = ?", (video_id,)).fetchone()
                if v_row:
                    channel_id = v_row["channel_id"]

        if channel_id:
            conn.execute(
                f"""
                UPDATE channels
                SET {col} = COALESCE({col}, 0) + 1,
                    watched_count = COALESCE(views_hp, 0) + COALESCE(views_laptop, 0) + 1,
                    updated_at = ?
                WHERE channel_id = ?
                """,
                (now_iso, channel_id),
            )

        c_info = {"views_hp": 0, "views_laptop": 0, "views_total": 0, "watched_count": 0}
        if channel_id:
            crow = conn.execute(
                "SELECT COALESCE(views_hp, 0) AS views_hp, COALESCE(views_laptop, 0) AS views_laptop, COALESCE(views_total, 0) AS views_total FROM channels WHERE channel_id = ?",
                (channel_id,),
            ).fetchone()
            if crow:
                c_info = {
                    "views_hp": int(crow["views_hp"]),
                    "views_laptop": int(crow["views_laptop"]),
                    "views_total": int(crow["views_total"]),
                    "watched_count": int(crow["views_total"]),
                }

        v_info = {"views_hp": 0, "views_laptop": 0, "views_total": 0}
        if video_id:
            vrow = conn.execute(
                "SELECT COALESCE(views_hp, 0) AS views_hp, COALESCE(views_laptop, 0) AS views_laptop, COALESCE(views_total, 0) AS views_total FROM videos WHERE video_id = ?",
                (video_id,),
            ).fetchone()
            if vrow:
                v_info = {
                    "views_hp": int(vrow["views_hp"]),
                    "views_laptop": int(vrow["views_laptop"]),
                    "views_total": int(vrow["views_total"]),
                }

        return {
            "channel_id": channel_id,
            "video_id": video_id,
            "device": dev,
            **c_info,
            "video_views_hp": v_info["views_hp"],
            "video_views_laptop": v_info["views_laptop"],
            "video_views_total": v_info["views_total"],
        }


def increment_channel_watched(channel_id: str, device: str = "laptop", video_id: str = "") -> int:
    res = record_watch(channel_id=channel_id, video_id=video_id, device=device)
    return int(res.get("views_total", 0))


def list_channels(region: str = "all", include_unfollowed: bool = False) -> list[dict]:
    clauses = ["1=1"]
    params: list = []
    if not include_unfollowed:
        clauses.append("COALESCE(c.status, 'subscribed') != 'unfollowed'")
    if region in ("Nasional", "Internasional"):
        clauses.append("COALESCE(c.region, 'Nasional') = ?")
        params.append(region)
    where_sql = " AND ".join(clauses)
    with get_conn() as conn:
        rows = conn.execute(
            f"""
            SELECT c.*,
                   COALESCE(c.views_hp, 0) AS views_hp,
                   COALESCE(c.views_laptop, 0) AS views_laptop,
                   COALESCE(c.views_total, c.watched_count, 0) AS views_total,
                   COALESCE(c.views_total, c.watched_count, 0) AS watched_count,
                   COALESCE(c.region, 'Nasional') AS region,
                   COALESCE(c.status, 'subscribed') AS status,
                   COUNT(v.video_id) AS synced_video_count,
                   CASE WHEN c.yt_video_count > COUNT(v.video_id) THEN c.yt_video_count ELSE COUNT(v.video_id) END AS video_count
            FROM channels c
            LEFT JOIN videos v ON v.channel_id = c.channel_id
            WHERE {where_sql}
            GROUP BY c.channel_id
            ORDER BY COALESCE(c.views_total, c.watched_count, 0) DESC, c.title COLLATE NOCASE ASC
            """,
            params,
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
              AND COALESCE(c.status, 'subscribed') != 'unfollowed'
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
    region: str = "all",
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
        "views": "videos.view_count DESC, videos.views_total DESC, videos.published_at DESC",
        "local_views": "videos.views_total DESC, videos.view_count DESC, videos.published_at DESC",
        "likes": "videos.like_count DESC, videos.view_count DESC",
        "time": "videos.published_at DESC",
    }
    order_sql = order_map.get(sort_by, "videos.published_at DESC")
    start_iso, end_iso = period_bounds(period, now=now)

    clauses = [
        "videos.channel_id NOT IN (SELECT channel_id FROM channels WHERE status = 'unfollowed')"
    ]
    params: list = []

    if start_iso:
        clauses.append("videos.published_at >= ?")
        params.append(start_iso)
    if end_iso:
        clauses.append("videos.published_at < ?")
        params.append(end_iso)
    if channel_id:
        clauses.append("videos.channel_id = ?")
        params.append(channel_id)
    if region in ("Nasional", "Internasional"):
        clauses.append("COALESCE(videos.region, 'Nasional') = ?")
        params.append(region)
    if min_minutes > 0:
        clauses.append("videos.duration_seconds >= ?")
        params.append(min_minutes * 60)
    if max_minutes < 120:
        clauses.append("videos.duration_seconds <= ?")
        params.append(max_minutes * 60)
    if q.strip():
        clauses.append("(videos.title LIKE ? OR videos.channel_title LIKE ?)")
        like_q = f"%{q.strip()}%"
        params.extend([like_q, like_q])

    where_sql = " AND ".join(clauses)
    with get_conn() as conn:
        total = conn.execute(f"SELECT COUNT(*) FROM videos WHERE {where_sql}", params).fetchone()[0]
        rows = conn.execute(
            f"""
            SELECT videos.*,
                   COALESCE(videos.views_hp, 0) AS views_hp,
                   COALESCE(videos.views_laptop, 0) AS views_laptop,
                   COALESCE(videos.views_total, 0) AS views_total,
                   COALESCE(videos.region, 'Nasional') AS region,
                   COALESCE((SELECT c.views_hp FROM channels c WHERE c.channel_id = videos.channel_id), 0) AS channel_views_hp,
                   COALESCE((SELECT c.views_laptop FROM channels c WHERE c.channel_id = videos.channel_id), 0) AS channel_views_laptop,
                   COALESCE((SELECT c.views_total FROM channels c WHERE c.channel_id = videos.channel_id), 0) AS watched_count
            FROM videos
            WHERE {where_sql}
            ORDER BY {order_sql}
            LIMIT ? OFFSET ?
            """,
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


def sync_device_data(payload: dict) -> dict:
    """
    Sinkronisasi 2 arah antara HP dan Laptop (via Kabel USB / JSON Bundle):
    - HP menulis views_hp, Laptop menulis views_laptop (tanpa double counting).
    - Rekonsiliasi status unfollowed vs subscribed menggunakan timestamp updated_at terbaru.
    """
    now_iso = datetime.now(timezone.utc).isoformat()
    incoming_device = str(payload.get("device", "hp")).lower()
    incoming_videos = payload.get("videos", []) or []
    incoming_channels = payload.get("channels", []) or []

    updated_videos_count = 0
    updated_channels_count = 0

    with get_conn() as conn:
        # 1. Rekonsiliasi Tabel Videos (views_hp & views_laptop)
        for v in incoming_videos:
            vid = str(v.get("video_id", "")).strip()
            if not vid:
                continue
            v_hp = int(v.get("views_hp", 0) or 0)
            v_laptop = int(v.get("views_laptop", 0) or 0)
            v_upd = str(v.get("updated_at", "") or now_iso)
            if incoming_device == "hp":
                cur = conn.execute(
                    "UPDATE videos SET views_hp = MAX(COALESCE(views_hp, 0), ?), updated_at = ? WHERE video_id = ?",
                    (v_hp, v_upd, vid),
                )
            elif incoming_device == "laptop":
                cur = conn.execute(
                    "UPDATE videos SET views_laptop = MAX(COALESCE(views_laptop, 0), ?), updated_at = ? WHERE video_id = ?",
                    (v_laptop, v_upd, vid),
                )
            else:
                cur = conn.execute(
                    """
                    UPDATE videos
                    SET views_hp = MAX(COALESCE(views_hp, 0), ?),
                        views_laptop = MAX(COALESCE(views_laptop, 0), ?),
                        updated_at = ?
                    WHERE video_id = ?
                    """,
                    (v_hp, v_laptop, v_upd, vid),
                )
            if cur.rowcount > 0:
                updated_videos_count += 1

        # 2. Rekonsiliasi Tabel Channels / Creators (views_hp, views_laptop, status unfollowed/subscribed via updated_at)
        local_ch_rows = conn.execute(
            "SELECT channel_id, status, region, COALESCE(views_hp, 0) AS views_hp, COALESCE(views_laptop, 0) AS views_laptop, COALESCE(updated_at, '') AS updated_at FROM channels"
        ).fetchall()
        local_ch_map = {r["channel_id"]: dict(r) for r in local_ch_rows}

        for c in incoming_channels:
            cid = str(c.get("channel_id") or c.get("creator_id") or "").strip()
            if not cid:
                continue
            c_title = str(c.get("title") or c.get("channel_name") or cid).strip()
            c_hp = int(c.get("views_hp", 0) or 0)
            c_laptop = int(c.get("views_laptop", 0) or 0)
            c_status = str(c.get("status", "subscribed") or "subscribed")
            c_region = str(c.get("region", "") or "")
            c_upd = str(c.get("updated_at", "") or "")

            existing = local_ch_map.get(cid)
            if existing:
                new_hp = max(int(existing["views_hp"]), c_hp) if incoming_device in ("hp", "bundle") else int(existing["views_hp"])
                new_laptop = max(int(existing["views_laptop"]), c_laptop) if incoming_device in ("laptop", "bundle") else int(existing["views_laptop"])
                new_status = existing["status"] or "subscribed"
                new_upd = existing["updated_at"] or ""
                new_region = existing["region"] or "Nasional"

                # Gunakan timestamp updated_at terbaru untuk rekonsiliasi status unfollowed vs subscribed
                if c_upd and (not new_upd or c_upd >= new_upd):
                    if c_status in ("subscribed", "unfollowed"):
                        new_status = c_status
                    new_upd = c_upd
                    if c_region in ("Nasional", "Internasional"):
                        new_region = c_region

                conn.execute(
                    """
                    UPDATE channels
                    SET views_hp = ?,
                        views_laptop = ?,
                        watched_count = ? + ?,
                        status = ?,
                        region = ?,
                        updated_at = ?
                    WHERE channel_id = ?
                    """,
                    (new_hp, new_laptop, new_hp, new_laptop, new_status, new_region, new_upd or now_iso, cid),
                )
                if new_status == "unfollowed":
                    conn.execute("DELETE FROM videos WHERE channel_id = ?", (cid,))
                updated_channels_count += 1
            else:
                # Creator baru dari perangkat lain: tambahkan jika tidak unfollowed (atau simpan tombstone jika unfollowed)
                uploads_pid = "UU" + cid[2:] if cid.startswith("UC") else cid
                reg = c_region if c_region in ("Nasional", "Internasional") else classify_region(c_title)
                conn.execute(
                    """
                    INSERT INTO channels(
                        channel_id, title, handle, thumbnail_url, uploads_playlist_id,
                        source, added_at, region, status, views_hp, views_laptop, watched_count, updated_at
                    ) VALUES (?, ?, ?, ?, ?, 'sync', ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        cid,
                        c_title,
                        str(c.get("handle", "")),
                        str(c.get("thumbnail_url", "")),
                        uploads_pid,
                        now_iso,
                        reg,
                        c_status if c_status in ("subscribed", "unfollowed") else "subscribed",
                        c_hp,
                        c_laptop,
                        c_hp + c_laptop,
                        c_upd or now_iso,
                    ),
                )
                updated_channels_count += 1

        # 3. Kembalikan paket balasan berisi data terbaru dari Laptop ke HP
        out_videos = [
            dict(r)
            for r in conn.execute(
                """
                SELECT video_id, channel_id, region,
                       COALESCE(views_hp, 0) AS views_hp,
                       COALESCE(views_laptop, 0) AS views_laptop,
                       COALESCE(views_total, 0) AS views_total,
                       COALESCE(updated_at, '') AS updated_at
                FROM videos
                WHERE COALESCE(views_hp, 0) > 0 OR COALESCE(views_laptop, 0) > 0
                """
            ).fetchall()
        ]
        out_channels = [
            dict(r)
            for r in conn.execute(
                """
                SELECT channel_id, title, handle, thumbnail_url, uploads_playlist_id,
                       COALESCE(region, 'Nasional') AS region,
                       COALESCE(status, 'subscribed') AS status,
                       COALESCE(views_hp, 0) AS views_hp,
                       COALESCE(views_laptop, 0) AS views_laptop,
                       COALESCE(views_total, 0) AS views_total,
                       COALESCE(updated_at, '') AS updated_at
                FROM channels
                """
            ).fetchall()
        ]

    return {
        "status": "ok",
        "device": "laptop",
        "synced_at": now_iso,
        "updated_videos_count": updated_videos_count,
        "updated_channels_count": updated_channels_count,
        "videos": out_videos,
        "channels": out_channels,
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
