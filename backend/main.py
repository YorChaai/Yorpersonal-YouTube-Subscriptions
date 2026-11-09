from concurrent.futures import ThreadPoolExecutor, as_completed
import csv
import io
import json
from pathlib import Path
import threading
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import db
import youtube_sync

app = FastAPI(title="Personal YouTube Subscriptions Hub")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# State sementara sesi berjalan: bertahan saat Refresh halaman (F5),
# dan otomatis kembali ke default saat aplikasi di-restart.
SESSION_UI_STATE: dict = {
    "sort_by": "time",
    "period": "all",
    "region": "all",
    "channel_id": "",
    "q": "",
    "page": 1,
    "min_minutes": 0,
    "max_minutes": 120,
    "sidebar_mode": "full",  # 'full' | 'mini' | 'hidden'
    "filter_minimized": False,
}

# Status sinkronisasi background (0%..100% + indikator Merah/Hijau)
REFRESH_STATE: dict = {
    "running": False,
    "progress": 0,          # 0 .. 100
    "done_ready": False,    # True jika sudah 100% selesai dan siap ditampilkan saat tombol Hijau diklik
    "done_channels": 0,
    "total_channels": 0,
    "new_videos": 0,
    "total_videos": 0,
    "error": "",
    "rotation_offset": 0,
}


def _get_permanent_limits() -> tuple[int, dict[str, int]]:
    default_limit_str = db.get_setting("default_limit", "25")
    try:
        default_limit = int(default_limit_str)
        if default_limit not in (25, 50, 100):
            default_limit = 25
    except ValueError:
        default_limit = 25

    raw_map = db.get_setting("tab_limits_json", "{}")
    try:
        tab_limits = json.loads(raw_map)
        if not isinstance(tab_limits, dict):
            tab_limits = {}
    except Exception:
        tab_limits = {}
    return default_limit, tab_limits


def _save_permanent_limit(tab_key: str, limit_val: int) -> None:
    if limit_val not in (25, 50, 100):
        return
    _, tab_limits = _get_permanent_limits()
    tab_limits[tab_key or "home"] = limit_val
    db.set_setting("default_limit", str(limit_val))
    db.set_setting("tab_limits_json", json.dumps(tab_limits))


@app.on_event("startup")
def on_startup() -> None:
    db.init_db()
    db.seed_demo_if_empty()


class SettingsPayload(BaseModel):
    api_key: str = ""
    oauth_token: str = ""


class AddChannelPayload(BaseModel):
    identifier: str


class ImportCsvPayload(BaseModel):
    csv_text: str


class SyncPayload(BaseModel):
    import_mode: str = "none"
    years_back: int = 4


class RefreshYouTubePayload(BaseModel):
    channel_id: str = ""


class UiStatePayload(BaseModel):
    sort_by: str | None = None
    period: str | None = None
    region: str | None = None
    channel_id: str | None = None
    q: str | None = None
    page: int | None = None
    min_minutes: int | None = None
    max_minutes: int | None = None
    limit: int | None = None
    sidebar_mode: str | None = None
    filter_minimized: bool | None = None


class WatchPayload(BaseModel):
    video_id: str = ""
    channel_id: str = ""
    device: str = "laptop"


class RegionPayload(BaseModel):
    region: str = "Nasional"


class DeviceSyncPayload(BaseModel):
    device: str = "hp"
    videos: list[dict] = []
    channels: list[dict] = []


@app.get("/api/state")
def get_state() -> dict:
    channels = db.list_channels()
    api_key = db.get_setting("api_key", "")
    oauth_token = db.get_setting("oauth_token", "")
    default_limit, tab_limits = _get_permanent_limits()
    current_tab_key = SESSION_UI_STATE.get("channel_id") or "home"
    active_limit = tab_limits.get(current_tab_key, default_limit)
    return {
        "channels": channels,
        "has_api_key": bool(api_key),
        "api_key_preview": (api_key[:6] + "..." + api_key[-4:]) if len(api_key) > 10 else ("Terpasang" if api_key else ""),
        "has_oauth_token": bool(oauth_token),
        "session_state": SESSION_UI_STATE,
        "default_limit": default_limit,
        "tab_limits": tab_limits,
        "active_limit": active_limit,
        "refresh_state": REFRESH_STATE,
    }


@app.post("/api/ui-state")
def update_ui_state(payload: UiStatePayload) -> dict:
    if payload.sort_by is not None:
        SESSION_UI_STATE["sort_by"] = payload.sort_by
    if payload.period is not None:
        SESSION_UI_STATE["period"] = payload.period
    if payload.region is not None:
        SESSION_UI_STATE["region"] = payload.region
    if payload.channel_id is not None:
        SESSION_UI_STATE["channel_id"] = payload.channel_id
    if payload.q is not None:
        SESSION_UI_STATE["q"] = payload.q
    if payload.page is not None:
        SESSION_UI_STATE["page"] = max(1, payload.page)
    if payload.min_minutes is not None:
        SESSION_UI_STATE["min_minutes"] = payload.min_minutes
    if payload.max_minutes is not None:
        SESSION_UI_STATE["max_minutes"] = payload.max_minutes
    if payload.sidebar_mode is not None:
        SESSION_UI_STATE["sidebar_mode"] = payload.sidebar_mode
    if payload.filter_minimized is not None:
        SESSION_UI_STATE["filter_minimized"] = payload.filter_minimized
    if payload.limit is not None and payload.limit in (25, 50, 100):
        tab_key = SESSION_UI_STATE.get("channel_id") or "home"
        _save_permanent_limit(tab_key, payload.limit)

    default_limit, tab_limits = _get_permanent_limits()
    current_tab_key = SESSION_UI_STATE.get("channel_id") or "home"
    return {
        "status": "ok",
        "session_state": SESSION_UI_STATE,
        "default_limit": default_limit,
        "tab_limits": tab_limits,
        "active_limit": tab_limits.get(current_tab_key, default_limit),
    }


@app.get("/api/videos")
def get_videos(
    sort_by: str = "time",
    period: str = "all",
    region: str = "all",
    channel_id: str = "",
    q: str = "",
    limit: int = 25,
    page: int = 1,
    min_minutes: int = 0,
    max_minutes: int = 120,
) -> dict:
    # Simpan kondisi terakhir ke SESSION_UI_STATE agar saat Refresh halaman (F5) tidak hilang
    SESSION_UI_STATE["sort_by"] = sort_by
    SESSION_UI_STATE["period"] = period
    SESSION_UI_STATE["region"] = region
    SESSION_UI_STATE["channel_id"] = channel_id
    SESSION_UI_STATE["q"] = q
    SESSION_UI_STATE["page"] = max(1, page)
    SESSION_UI_STATE["min_minutes"] = min_minutes
    SESSION_UI_STATE["max_minutes"] = max_minutes
    if limit in (25, 50, 100):
        _save_permanent_limit(channel_id or "home", limit)

    res = db.query_videos(
        sort_by=sort_by,
        period=period,
        region=region,
        channel_id=channel_id,
        q=q,
        limit=limit,
        page=page,
        min_minutes=min_minutes,
        max_minutes=max_minutes,
    )
    # Jika user mengetik pencarian (misal 'saat stop') untuk video lama yang belum ada di cache lokal,
    # cari di YouTube khusus dari daftar 927 channel yang di-subscribe user
    if q.strip() and res["total"] < 3 and page == 1:
        api_key = db.get_setting("api_key", "")
        oauth_token = db.get_setting("oauth_token", "")
        if api_key or oauth_token:
            youtube_sync.search_and_cache_subscribed_videos(
                q=q,
                channel_id=channel_id,
                api_key=api_key,
                oauth_token=oauth_token,
            )
            res = db.query_videos(
                sort_by=sort_by,
                period=period,
                region=region,
                channel_id=channel_id,
                q=q,
                limit=limit,
                page=page,
                min_minutes=min_minutes,
                max_minutes=max_minutes,
            )
            # Jika masih 0 karena user tidak sengaja sedang mengklik 1 channel tertentu di sidebar (misal 2Nine Fit),
            # otomatis cari di seluruh 927 channel Subscriptions agar video yang dicari tetap ketemu!
            if res["total"] == 0 and channel_id:
                youtube_sync.search_and_cache_subscribed_videos(
                    q=q,
                    channel_id="",
                    api_key=api_key,
                    oauth_token=oauth_token,
                )
                res = db.query_videos(
                    sort_by=sort_by,
                    period=period,
                    region=region,
                    channel_id="",
                    q=q,
                    limit=limit,
                    page=page,
                    min_minutes=min_minutes,
                    max_minutes=max_minutes,
                )

    # Jika user klik salah satu dari 930 channel di sidebar yang videonya belum pernah ditarik sama sekali (0 video), tarik 1x
    if channel_id and res["total"] == 0 and period == "all" and not q and page == 1 and min_minutes == 0 and max_minutes >= 120:
        api_key = db.get_setting("api_key", "")
        oauth_token = db.get_setting("oauth_token", "")
        if api_key or oauth_token:
            chs = [c for c in db.list_channels() if c["channel_id"] == channel_id]
            if chs and chs[0].get("synced_video_count", 0) == 0:
                try:
                    youtube_sync.sync_channel_videos(chs[0], api_key=api_key, oauth_token=oauth_token, max_videos=150)
                    res = db.query_videos(
                        sort_by=sort_by,
                        period=period,
                        region=region,
                        channel_id=channel_id,
                        q=q,
                        limit=limit,
                        page=page,
                        min_minutes=min_minutes,
                        max_minutes=max_minutes,
                    )
                except Exception:
                    pass
    return res


def _run_background_refresh(channel_id: str, api_key: str, oauth_token: str) -> None:
    try:
        before_total = db.query_videos(limit=25, page=1)["total"]
        # 1. Tarik daftar channel Subscriptions terbaru secara PERMANEN via Channel ID user + API Key (aktif selamanya!)
        my_cid = db.get_setting("my_channel_id", "")
        if my_cid and api_key and not channel_id:
            try:
                youtube_sync.sync_public_subscriptions_by_channel(my_cid, api_key=api_key)
            except Exception:
                pass
        elif oauth_token and not channel_id:
            try:
                youtube_sync.import_oauth_subscriptions(oauth_token, mode="subscriptions")
            except Exception:
                pass
        all_chs = [c for c in db.list_channels() if not c["channel_id"].startswith("UC_demo_")]

        if channel_id:
            target_chs = [c for c in all_chs if c["channel_id"] == channel_id]
            REFRESH_STATE["total_channels"] = len(target_chs)
            REFRESH_STATE["done_channels"] = 0
            REFRESH_STATE["progress"] = 10
            for idx, ch in enumerate(target_chs):
                youtube_sync.sync_channel_videos(ch, api_key=api_key, oauth_token=oauth_token, max_videos=250)
                REFRESH_STATE["done_channels"] = idx + 1
                REFRESH_STATE["progress"] = min(99, int((idx + 1) * 100 / max(1, len(target_chs))))
        else:
            # Cek 100% SELURUH channel (semua 927+ channel tanpa terkecuali, termasuk yang jarang upload 1 bulan/tahun sekali!)
            REFRESH_STATE["total_channels"] = len(all_chs)
            REFRESH_STATE["done_channels"] = 0
            REFRESH_STATE["progress"] = 5

            def _on_prog(done: int, total: int) -> None:
                REFRESH_STATE["done_channels"] = done
                REFRESH_STATE["progress"] = min(99, max(5, int(done * 95 / max(1, total))))

            youtube_sync.refresh_all_channels_comprehensive(
                all_chs,
                api_key=api_key,
                oauth_token=oauth_token,
                on_progress=_on_prog,
            )

        after_total = db.query_videos(limit=25, page=1)["total"]
        REFRESH_STATE["new_videos"] = max(0, after_total - before_total)
        REFRESH_STATE["total_videos"] = after_total
        REFRESH_STATE["progress"] = 100
        REFRESH_STATE["done_ready"] = True
        REFRESH_STATE["running"] = False
    except Exception as e:
        REFRESH_STATE["error"] = str(e)
        REFRESH_STATE["running"] = False
        REFRESH_STATE["done_ready"] = False


@app.post("/api/refresh-youtube")
def refresh_youtube(payload: RefreshYouTubePayload) -> dict:
    """Mulai sinkronisasi YouTube di background (0%..100%) tanpa menghentikan aktivitas user."""
    api_key = db.get_setting("api_key", "")
    oauth_token = db.get_setting("oauth_token", "")
    if not api_key and not oauth_token:
        raise HTTPException(status_code=400, detail="API Key belum terpasang.")

    if REFRESH_STATE["running"]:
        return {"status": "running", **REFRESH_STATE}

    REFRESH_STATE["running"] = True
    REFRESH_STATE["progress"] = 2
    REFRESH_STATE["done_ready"] = False
    REFRESH_STATE["done_channels"] = 0
    REFRESH_STATE["total_channels"] = 0
    REFRESH_STATE["new_videos"] = 0
    REFRESH_STATE["error"] = ""

    t = threading.Thread(
        target=_run_background_refresh,
        args=(payload.channel_id, api_key, oauth_token),
        daemon=True,
    )
    t.start()
    return {"status": "started", **REFRESH_STATE}


@app.get("/api/refresh-youtube/status")
def refresh_youtube_status() -> dict:
    return REFRESH_STATE


@app.post("/api/refresh-youtube/consume")
def refresh_youtube_consume() -> dict:
    """Dipanggil ketika tombol Refresh warna HIJAU (100%) ditekan untuk menampilkan video baru."""
    summary = dict(REFRESH_STATE)
    REFRESH_STATE["done_ready"] = False
    REFRESH_STATE["progress"] = 0
    return {"status": "ok", **summary}


@app.post("/api/settings")
def save_settings(payload: SettingsPayload) -> dict:
    if payload.api_key and payload.api_key.strip():
        db.set_setting("api_key", payload.api_key.strip())
    if payload.oauth_token and payload.oauth_token.strip():
        db.set_setting("oauth_token", payload.oauth_token.strip())
    return {"status": "ok", **get_state()}


@app.get("/api/channels")
def get_channels_list(region: str = "all") -> dict:
    channels = db.list_channels(region=region)
    return {"status": "ok", "channels": channels, "region": region}


@app.post("/api/channels")
def add_channel(payload: AddChannelPayload) -> dict:
    api_key = db.get_setting("api_key", "")
    oauth_token = db.get_setting("oauth_token", "")
    try:
        ch = youtube_sync.resolve_and_add_channel(payload.identifier, api_key=api_key, oauth_token=oauth_token)
        synced = youtube_sync.sync_channel_videos(ch, api_key=api_key, oauth_token=oauth_token)
        return {"status": "ok", "channel": ch, "videos_synced": synced}
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/api/videos/{video_id}/watch")
def watch_video(video_id: str, payload: WatchPayload | None = None) -> dict:
    dev = payload.device if payload and payload.device else "laptop"
    cid = payload.channel_id if payload else ""
    res = db.record_watch(channel_id=cid, video_id=video_id, device=dev)
    return {"status": "ok", **res}


@app.post("/api/channels/{channel_id}/watch")
def watch_channel(channel_id: str, payload: WatchPayload | None = None) -> dict:
    dev = payload.device if payload and payload.device else "laptop"
    vid = payload.video_id if payload else ""
    res = db.record_watch(channel_id=channel_id, video_id=vid, device=dev)
    return {"status": "ok", **res}


@app.post("/api/channels/{channel_id}/region")
def update_channel_region(channel_id: str, payload: RegionPayload) -> dict:
    reg = db.set_channel_region(channel_id, payload.region)
    return {"status": "ok", "channel_id": channel_id, "region": reg}


@app.post("/api/channels/{channel_id}/subscribe")
def subscribe_channel_endpoint(channel_id: str) -> dict:
    db.subscribe_channel(channel_id)
    return {"status": "ok", "channel_id": channel_id, "status": "subscribed"}


@app.post("/api/channels/{channel_id}/unfollow")
def unfollow_channel_endpoint(channel_id: str) -> dict:
    db.delete_channel(channel_id)
    if SESSION_UI_STATE.get("channel_id") == channel_id:
        SESSION_UI_STATE["channel_id"] = ""
    return {"status": "ok", "channel_id": channel_id, "status": "unfollowed"}


@app.delete("/api/channels/{channel_id}")
def remove_channel(channel_id: str) -> dict:
    db.delete_channel(channel_id)
    if SESSION_UI_STATE.get("channel_id") == channel_id:
        SESSION_UI_STATE["channel_id"] = ""
    return {"status": "ok"}


@app.post("/api/sync/exchange")
def sync_exchange_device(payload: DeviceSyncPayload) -> dict:
    """Sinkronisasi langsung HP ⇄ Laptop via Kabel USB / Jaringan Lokal."""
    return db.sync_device_data(payload.dict())


@app.get("/api/sync/export-bundle")
def export_sync_bundle_endpoint() -> Response:
    bundle = db.sync_device_data({"device": "bundle", "videos": [], "channels": []})
    bundle_json = json.dumps(bundle, indent=2, ensure_ascii=False)
    return Response(
        content=bundle_json,
        media_type="application/json; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="youtube_sync_bundle.json"'},
    )


@app.post("/api/sync/import-bundle")
def import_sync_bundle_endpoint(payload: DeviceSyncPayload) -> dict:
    return db.sync_device_data(payload.dict())


@app.delete("/api/demo")
def remove_demo() -> dict:
    db.clear_demo_data()
    return {"status": "ok"}


@app.post("/api/demo")
def restore_demo() -> dict:
    db.clear_demo_data()
    db.seed_demo_if_empty()
    return {"status": "ok"}


@app.post("/api/sync")
def sync_all(payload: SyncPayload) -> dict:
    api_key = db.get_setting("api_key", "")
    oauth_token = db.get_setting("oauth_token", "")
    imported_channels = 0

    try:
        if payload.import_mode in ("subscriptions", "subscribers") and oauth_token:
            imported_channels = youtube_sync.import_oauth_subscriptions(oauth_token, mode=payload.import_mode)

        if not REFRESH_STATE["running"]:
            REFRESH_STATE["running"] = True
            REFRESH_STATE["progress"] = 2
            REFRESH_STATE["done_ready"] = False
            REFRESH_STATE["done_channels"] = 0
            REFRESH_STATE["total_channels"] = 0
            REFRESH_STATE["new_videos"] = 0
            REFRESH_STATE["error"] = ""
            t = threading.Thread(
                target=_run_background_refresh,
                args=("", api_key, oauth_token),
                daemon=True,
            )
            t.start()

        return {
            "status": "started",
            "imported_channels": imported_channels,
            "synced_videos": 0,
            **REFRESH_STATE,
        }
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@app.get("/api/channels/export-csv")
def export_channels_csv() -> Response:
    channels = db.list_channels()
    buf = io.StringIO()
    buf.write("\ufeff")
    writer = csv.writer(buf)
    writer.writerow(["Channel ID", "Nama Channel", "Handle", "URL Channel", "Total Video di YouTube", "Jumlah Subscriber", "Sumber"])
    for c in channels:
        cid = c["channel_id"]
        handle = c.get("handle", "")
        url = f"https://www.youtube.com/{handle}" if handle else f"https://www.youtube.com/channel/{cid}"
        writer.writerow([
            cid,
            c["title"],
            handle,
            url,
            c.get("video_count", 0),
            c.get("subscriber_count", 0),
            c.get("source", ""),
        ])

    return Response(
        content=buf.getvalue(),
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="daftar_channel_youtube.csv"'},
    )


@app.post("/api/channels/import-csv")
def import_channels_csv(payload: ImportCsvPayload) -> dict:
    api_key = db.get_setting("api_key", "")
    oauth_token = db.get_setting("oauth_token", "")
    text = payload.csv_text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="Teks CSV / daftar channel kosong.")

    reader = csv.reader(io.StringIO(text))
    added = 0
    for row in reader:
        if not row:
            continue
        first = row[0].strip()
        if first.lower() in ("channel id", "channel_id", "id", "nama channel"):
            continue
        if first.startswith("UC") and len(row) >= 3:
            cid = first
            title = row[2].strip() or cid
            db.upsert_channel(
                channel_id=cid,
                title=title,
                uploads_playlist_id="UU" + cid[2:],
                source="csv",
            )
            added += 1
        elif api_key or oauth_token:
            try:
                youtube_sync.resolve_and_add_channel(first, api_key=api_key, oauth_token=oauth_token)
                added += 1
            except ValueError:
                pass
    return {"status": "ok", "added": added}


WEB_BUILD_DIR = Path(__file__).parent.parent / "frontend" / "build" / "web"
if WEB_BUILD_DIR.exists():
    app.mount("/", StaticFiles(directory=str(WEB_BUILD_DIR), html=True), name="web")
