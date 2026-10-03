#!/data/data/com.termux/files/usr/bin/bash
# video_bot - installer SATU FILE untuk Termux (bot.py sudah ada di dalam skrip ini)
# Pasang / update:
#   curl -fsSL https://raw.githubusercontent.com/vicoadiwibowo/bot_video/main/install.sh | bash
# Aman dijalankan berulang. File .env tidak pernah ditimpa.

INSTALL_DIR="${INSTALL_DIR:-$HOME/bot_video}"
PIP_PKGS=("python-telegram-bot>=21.0" "aiohttp>=3.9")

export DEBIAN_FRONTEND=noninteractive
export AIOHTTP_NO_EXTENSIONS=1 FROZENLIST_NO_EXTENSIONS=1 \
       MULTIDICT_NO_EXTENSIONS=1 YARL_NO_EXTENSIONS=1

say()  { printf '\n\033[1;32m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$1"; }
die()  { printf '\n\033[1;31m[GAGAL] %s\033[0m\n' "$1"; exit 1; }

retry() {  # retry <jumlah> perintah...
    local n=$1; shift
    local i
    for ((i=1; i<=n; i++)); do
        "$@" && return 0
        warn "Percobaan $i/$n gagal: $*"
        sleep 3
    done
    return 1
}

ask() {  # ask "pertanyaan" "default"
    local ans=""
    if [ -r /dev/tty ]; then
        read -r -p "$1 " ans </dev/tty || true
    fi
    ans="$(echo "${ans:-$2}" | tr -d '[:space:]')"
    echo "$ans"
}

ask_required() {
    local v=""
    while [ -z "$v" ]; do
        v="$(ask "$1" "")"
        [ -z "$v" ] && warn "Tidak boleh kosong."
    done
    echo "$v"
}

main() {
# ---------- 1. Paket Termux ----------
say "Update paket Termux"
retry 3 pkg update -y -o Dpkg::Options::="--force-confold" </dev/null || warn "pkg update gagal, lanjut dengan data lama"
retry 3 pkg install -y -o Dpkg::Options::="--force-confold" \
    python ffmpeg clang libffi openssl </dev/null \
    || die "Gagal memasang paket Termux. Cek koneksi lalu jalankan ulang."

# ---------- 2. Storage ----------
say "Izin storage (klik Allow jika muncul)"
if [ ! -d "$HOME/storage/downloads" ]; then
    termux-setup-storage >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        [ -d "$HOME/storage/downloads" ] && break
        sleep 1
    done
fi
if [ -d "$HOME/storage/downloads" ]; then
    DL_DIR='~/storage/downloads/video_bot'
else
    warn "Izin storage belum diberikan, hasil download disimpan di ~/video_bot_downloads"
    DL_DIR="$HOME/video_bot_downloads"
fi

# ---------- 3. Tulis bot.py ----------
say "Menulis bot.py"
mkdir -p "$INSTALL_DIR" || die "Tidak bisa membuat folder $INSTALL_DIR"
cd "$INSTALL_DIR" || die "Folder $INSTALL_DIR tidak ditemukan."
cat > bot.py <<'PYEOF'
#!/usr/bin/env python3
"""
video_bot v4 — Telegram bot: link video -> download -> upload ke channel.
Support: direct file (multipart), HLS (segmen paralel, disimpan ke disk),
DASH (ffmpeg), dan pencarian URL video di halaman HTML/JSON.
"""
import asyncio
import html as htmllib
import ipaddress
import json
import logging
import os
import queue as thread_queue
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import urlparse, unquote, urljoin

import aiohttp
try:
    from curl_cffi import requests as cffi_requests
    HAS_CFFI = True
except ImportError:
    cffi_requests = None
    HAS_CFFI = False
from telegram import Update
from telegram.ext import (
    Application, CommandHandler, ContextTypes, MessageHandler, filters,
)

logging.basicConfig(format="%(asctime)s %(levelname)s %(name)s: %(message)s", level=logging.INFO)
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("video_bot")


# ====== ENV ======
def load_env(path):
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
load_env(os.path.join(BASE_DIR, ".env"))

BOT_TOKEN = os.environ.get("BOT_TOKEN", "")
CHANNEL_ID = os.environ.get("CHANNEL_ID", "").strip()
# Kosong = pakai API resmi Telegram (limit upload 50MB).
# Isi http://127.0.0.1:8081 jika menjalankan Local Bot API server (limit 2GB).
API_HOST = os.environ.get("API_HOST", "").strip().rstrip("/")
ALLOWED_USERS = {int(x) for x in os.environ.get("ALLOWED_USERS", "").replace(" ", "").split(",") if x}
ALLOW_PRIVATE_HOSTS = os.environ.get("ALLOW_PRIVATE_HOSTS", "0") == "1"

DOWNLOAD_DIR = os.path.expanduser(os.environ.get("DOWNLOAD_DIR", "~/storage/downloads/video_bot"))
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

# ====== TUNING ======
_default_max = "2000" if API_HOST else "49"
MAX_SIZE_MB = int(os.environ.get("MAX_SIZE_MB", _default_max))
MAX_BYTES = MAX_SIZE_MB * 1024 * 1024
NUM_PARTS = int(os.environ.get("NUM_PARTS", "16"))
NUM_SEG_PARTS = int(os.environ.get("NUM_SEG_PARTS", "16"))
MIN_PART_BYTES = 4 * 1024 * 1024
MULTIPART_MIN_SIZE = 8 * 1024 * 1024
CHUNK_SIZE = 512 * 1024
PROGRESS_INTERVAL = 2.5
PART_RETRIES = 4
SEG_RETRIES = 5
MAX_DEPTH = 4
MAX_CANDIDATES = 3
MAX_TEXT_BYTES = 3 * 1024 * 1024
HLS_TIMEOUT = 7200
MAX_JOBS = int(os.environ.get("MAX_JOBS", "1"))

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 "
                  "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36",
    "Accept": "*/*",
    "Accept-Language": "en-US,en;q=0.9",
    "Accept-Encoding": "identity",
    "Sec-Fetch-Dest": "empty",
    "Sec-Fetch-Mode": "cors",
    "Sec-Fetch-Site": "same-origin",
    "Sec-Ch-Ua": '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
    "Sec-Ch-Ua-Mobile": "?1",
    "Sec-Ch-Ua-Platform": '"Android"',
}
VIDEO_EXTS = (".mp4", ".mkv", ".webm", ".mov", ".avi", ".flv", ".m4v", ".ts")
SKIP_EXTS = (".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".css", ".js", ".ico", ".woff", ".woff2")
URL_KEYS = ("file", "src", "source", "url", "video_url", "stream", "hls", "playlist")

SURRIT_HOSTS = ("surrit.com",)
MIRROR_REFERER = "https://missav.ws/"
JOB_SEM = None


class DownloadError(Exception): pass
class TooBig(DownloadError): pass
class RangeNotSupported(DownloadError): pass


# ====== UTIL ======
def human_size(b):
    for u in ["B", "KB", "MB", "GB"]:
        if b < 1024:
            return f"{b:.1f}{u}"
        b /= 1024
    return f"{b:.1f}TB"


def human_speed(bps): return f"{human_size(bps)}/s"


def human_eta(sec):
    if sec <= 0 or sec > 86400:
        return "--:--"
    m, s = divmod(int(sec), 60)
    h, m = divmod(m, 60)
    if h: return f"{h}j {m}m"
    if m: return f"{m}m {s}s"
    return f"{s}s"


async def safe_edit(msg, text):
    try:
        await msg.edit_text(text[:4000])
    except Exception:
        pass


def is_textual(ct):
    return ct.startswith("text/") or "html" in ct or "json" in ct or "xml" in ct or "javascript" in ct


def guess_ext(ct, url):
    ct = ct.lower()
    if "mp4" in ct: return ".mp4"
    if "webm" in ct: return ".webm"
    if "matroska" in ct: return ".mkv"
    if "quicktime" in ct: return ".mov"
    if "mp2t" in ct or "mpegurl" in ct: return ".ts"
    p = urlparse(url).path.lower()
    for e in VIDEO_EXTS:
        if p.endswith(e):
            return e
    return ".mp4"


def is_surrit_host(url):
    try:
        h = urlparse(url).hostname or ""
        return any(h == s or h.endswith("." + s) for s in SURRIT_HOSTS)
    except Exception:
        return False


def resolve_referer(url, referer=None):
    if is_surrit_host(url):
        return referer or MIRROR_REFERER
    return referer


def build_headers(url, referer=None):
    h = dict(HEADERS)
    if is_surrit_host(url):
        ref = referer or MIRROR_REFERER
        h["Referer"] = ref
        rp = urlparse(ref)
        h["Origin"] = f"{rp.scheme}://{rp.netloc}"
        h["Sec-Fetch-Site"] = "cross-site"
        return h
    p = urlparse(url)
    origin = f"{p.scheme}://{p.netloc}"
    h["Origin"] = origin
    if referer:
        h["Referer"] = referer
        rp = urlparse(referer)
        if rp.netloc != p.netloc:
            h["Sec-Fetch-Site"] = "cross-site"
    else:
        h["Referer"] = origin + "/"
    return h


def make_filename(url, disp, ext):
    name = ""
    m = re.search(r"filename\*?=(?:UTF-8'')?\"?([^\";]+)\"?", disp or "", re.I)
    if m: name = unquote(m.group(1))
    if not name: name = unquote(os.path.basename(urlparse(url).path))
    name = re.sub(r"[^\w.\-()\[\] ]+", "_", name).strip(" ._")
    stem, e = os.path.splitext(name)
    if not stem: stem = f"video_{int(time.time())}"
    return stem[:80] + (e if e.lower() in VIDEO_EXTS else ext)


def is_safe_url(url):
    try:
        host = urlparse(url).hostname
        if not host:
            return False
        for info in socket.getaddrinfo(host, None):
            ip = ipaddress.ip_address(info[4][0])
            if (ip.is_private or ip.is_loopback or ip.is_link_local
                    or ip.is_reserved or ip.is_multicast or ip.is_unspecified):
                return False
        return True
    except Exception:
        return False


def _prep_cffi_headers(url, headers, referer, range_hdr):
    h = dict(headers or {})
    h.setdefault("Accept", "*/*")
    h.setdefault("Accept-Language", "en-US,en;q=0.9")
    h.setdefault("Accept-Encoding", "identity")
    ref = resolve_referer(url, referer)
    if ref:
        h["Referer"] = ref
        p = urlparse(ref)
        h["Origin"] = f"{p.scheme}://{p.netloc}"
    if is_surrit_host(url):
        h["Sec-Fetch-Site"] = "cross-site"
    if range_hdr:
        h["Range"] = range_hdr
    return h


def _cffi_get_sync(url, headers=None, referer=None, timeout=120, range_hdr=None):
    if not HAS_CFFI:
        raise DownloadError("curl_cffi belum terinstall (pip install curl_cffi)")
    h = _prep_cffi_headers(url, headers, referer, range_hdr)
    r = cffi_requests.get(url, headers=h, impersonate="chrome120",
                          timeout=timeout, allow_redirects=True)
    return r.status_code, dict(r.headers), r.content


def _cffi_session_get(sess, url, headers=None, referer=None, timeout=120):
    h = _prep_cffi_headers(url, headers, referer, None)
    r = sess.get(url, headers=h, timeout=timeout, allow_redirects=True)
    return r.status_code, dict(r.headers), r.content


async def fetch_bytes(url, referer=None, headers=None, timeout=120, range_hdr=None):
    if is_surrit_host(url):
        return await asyncio.to_thread(_cffi_get_sync, url, headers, referer, timeout, range_hdr)
    h = dict(headers or HEADERS)
    if referer:
        h["Referer"] = referer
        p = urlparse(referer)
        h.setdefault("Origin", f"{p.scheme}://{p.netloc}")
    if range_hdr:
        h["Range"] = range_hdr
    to = aiohttp.ClientTimeout(total=timeout, sock_connect=20, sock_read=timeout)
    async with aiohttp.ClientSession(timeout=to, headers=h) as s:
        async with s.get(url, allow_redirects=True) as r:
            content = await r.read()
            return r.status, dict(r.headers), content


def dedupe(seq):
    seen, out = set(), []
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


# ====== PROGRESS ======
class Progress:
    def __init__(self, msg, total, label="Downloading"):
        self.msg, self.total, self.label = msg, total, label
        self.speed = 0.0
        self._lb = 0
        self._lt = time.monotonic()
        self._le = 0.0
        self._ltext = ""

    async def update(self, done, force=False):
        now = time.monotonic()
        if not force and (now - self._le) < PROGRESS_INTERVAL:
            return
        dt = now - self._lt
        if dt > 0:
            inst = (done - self._lb) / dt
            self.speed = inst if self.speed == 0 else 0.7 * self.speed + 0.3 * inst
        self._lb, self._lt, self._le = done, now, now
        if self.total:
            pct = min(done * 100 / self.total, 100)
            filled = int(12 * pct / 100)
            bar = "#" * filled + "-" * (12 - filled)
            eta = (self.total - done) / self.speed if self.speed > 0 else 0
            text = (f"{self.label} [{bar}] {pct:.1f}%\n"
                    f"{human_size(done)} / {human_size(self.total)}\n"
                    f"Speed: {human_speed(self.speed)}  ETA: {human_eta(eta)}")
        else:
            text = f"{self.label}... {human_size(done)}\nSpeed: {human_speed(self.speed)}"
        if text != self._ltext:
            self._ltext = text
            await safe_edit(self.msg, text)


class SegProgress:
    def __init__(self, msg, total_parts, label="Download HLS"):
        self.msg = msg
        self.total_parts = total_parts
        self.label = label
        self.done_parts = 0
        self.done_bytes = 0
        self.speed = 0.0
        self._lb = 0
        self._lt = time.monotonic()
        self._le = 0.0
        self._ltext = ""
        self._lock = threading.Lock()

    def add_part(self, nbytes):
        with self._lock:
            self.done_parts += 1
            self.done_bytes += nbytes

    async def update(self, force=False):
        now = time.monotonic()
        if not force and (now - self._le) < PROGRESS_INTERVAL:
            return
        dt = now - self._lt
        if dt > 0:
            inst = (self.done_bytes - self._lb) / dt
            self.speed = inst if self.speed == 0 else 0.7 * self.speed + 0.3 * inst
        self._lb, self._lt, self._le = self.done_bytes, now, now
        pct = self.done_parts * 100 / self.total_parts if self.total_parts else 0
        filled = int(12 * pct / 100)
        bar = "#" * filled + "-" * (12 - filled)
        eta = 0
        if self.speed > 0 and self.done_parts > 0:
            remain = self.total_parts - self.done_parts
            eta = remain * (self.done_bytes / self.done_parts) / self.speed
        text = (f"{self.label} [{bar}] {pct:.1f}%\n"
                f"Part {self.done_parts} / {self.total_parts}  ({human_size(self.done_bytes)})\n"
                f"Speed: {human_speed(self.speed)}  ETA: {human_eta(eta)}")
        if text != self._ltext:
            self._ltext = text
            await safe_edit(self.msg, text)


async def reporter(progress, counter):
    try:
        while True:
            await asyncio.sleep(0.5)
            await progress.update(counter["done"])
    except asyncio.CancelledError:
        pass


async def seg_reporter(progress):
    try:
        while True:
            await asyncio.sleep(0.5)
            await progress.update()
    except asyncio.CancelledError:
        pass


# ====== PROBE ======
async def probe(url, referer=None):
    """GET sekali per variasi referer; pakai yang pertama tidak 401/403."""
    timeout = aiohttp.ClientTimeout(total=90, sock_connect=15, sock_read=20)
    info = {"status": 0, "ct": "", "url": url, "size": 0, "ranges": True,
            "body": b"", "disp": "", "error": "", "referer": referer}
    p = urlparse(url)
    origin = f"{p.scheme}://{p.netloc}/"
    variants = dedupe([referer, origin, None])
    for i, ref_try in enumerate(variants):
        is_last = i == len(variants) - 1
        try:
            async with aiohttp.ClientSession(timeout=timeout, headers=build_headers(url, ref_try)) as s:
                async with s.get(url, allow_redirects=True) as r:
                    if r.status in (401, 403) and not is_last:
                        continue
                    info["status"] = r.status
                    info["referer"] = ref_try
                    info["ct"] = r.headers.get("Content-Type", "").split(";")[0].strip().lower()
                    info["url"] = str(r.url)
                    info["disp"] = r.headers.get("Content-Disposition", "")
                    try: info["size"] = int(r.headers.get("Content-Length") or 0)
                    except ValueError: info["size"] = 0
                    info["ranges"] = r.headers.get("Accept-Ranges", "").lower() == "bytes"
                    if r.status < 400 and is_textual(info["ct"]):
                        buf = bytearray()
                        async for chunk in r.content.iter_chunked(65536):
                            buf += chunk
                            if len(buf) >= MAX_TEXT_BYTES:
                                break
                        info["body"] = bytes(buf)
                    return info
        except Exception as e:
            info["status"] = 0
            info["error"] = str(e)[:150]
    return info


# ====== EKSTRAKSI URL DARI HTML/JSON ======
VIDEO_TAG_RE = re.compile(r"<(?:video|source)[^>]+?src\s*=\s*[\"']([^\"']+)[\"']", re.I)
MEDIA_URL_RE = re.compile(
    r"[\"'(=]\s*([^\s\"'<>()]+?\.(?:m3u8|mpd|mp4|webm|mkv|mov)(?:\?[^\s\"'<>()]*)?)"
    r"(?=[\"'\s)<>;,]|$)", re.I)
JSON_KEY_RE = re.compile(
    r"[\"'](?:file|src|source|url|video_url|stream|hls|playlist)[\"']\s*[:=]\s*[\"']([^\"']+)[\"']", re.I)
IFRAME_RE = re.compile(r"<iframe[^>]+?src\s*=\s*[\"']([^\"']+)[\"']", re.I)
MEDIA_EXT_RE = re.compile(r"\.(?:m3u8|mpd|mp4|webm|mkv|mov|ts)(?:[?#]|$)", re.I)


def _clean_candidate(base, raw):
    raw = raw.strip()
    if not raw or raw.startswith(("javascript:", "data:", "blob:", "#")):
        return None
    full = urljoin(base, raw)
    p = urlparse(full)
    if p.scheme not in ("http", "https") or not p.netloc:
        return None
    return full


def extract_from_html(body, base_url):
    text = body.decode("utf-8", errors="ignore")
    text = text.replace("\\/", "/").replace("\\u002F", "/").replace("\\u0026", "&")
    text = htmllib.unescape(text)
    direct, keyed, frames = [], [], []
    for m in VIDEO_TAG_RE.finditer(text): direct.append(m.group(1))
    for m in MEDIA_URL_RE.finditer(text): direct.append(m.group(1))
    for m in JSON_KEY_RE.finditer(text):
        v = m.group(1)
        if v.lower().split("?")[0].endswith(SKIP_EXTS):
            continue
        if v.startswith(("http://", "https://", "//", "/")):
            keyed.append(v)
    for m in IFRAME_RE.finditer(text): frames.append(m.group(1))
    out = []
    for raw in direct + keyed + frames:
        c = _clean_candidate(base_url, raw)
        if c: out.append(c)
    return dedupe(out)


def extract_from_json(data, base_url):
    try:
        obj = json.loads(data.decode("utf-8", errors="ignore"))
    except ValueError:
        return []
    media, other = [], []

    def walk(o, key=""):
        if isinstance(o, dict):
            for k, v in o.items(): walk(v, str(k).lower())
        elif isinstance(o, list):
            for v in o: walk(v, key)
        elif isinstance(o, str):
            v = o.strip()
            if not v or " " in v or len(v) > 2000: return
            if not v.startswith(("http://", "https://", "//", "/")): return
            c = _clean_candidate(base_url, v)
            if not c: return
            if MEDIA_EXT_RE.search(v): media.append(c)
            elif key in URL_KEYS and not v.lower().split("?")[0].endswith(SKIP_EXTS):
                other.append(c)

    walk(obj)
    return dedupe(media + other)


# ====== HLS / M3U8 ======
def parse_m3u8(text, base_url):
    lines = [l.strip() for l in text.splitlines() if l.strip()]
    segs, variants = [], []
    is_master = False
    for i, line in enumerate(lines):
        if line.startswith("#EXT-X-STREAM-INF"):
            is_master = True
            if i + 1 < len(lines) and not lines[i + 1].startswith("#"):
                variants.append(_clean_candidate(base_url, lines[i + 1]))
        elif line.startswith("#EXTINF"):
            if i + 1 < len(lines) and not lines[i + 1].startswith("#"):
                segs.append(_clean_candidate(base_url, lines[i + 1]))
    if is_master and variants:
        return "master", [v for v in variants if v]
    return "media", [s for s in segs if s]


def pick_best_variant(variants):
    def score(u):
        nums = re.findall(r"\d+", u)
        return max([int(n) for n in nums if 100 <= int(n) <= 4320], default=0)
    return max(variants, key=score)


async def _fetch_m3u8_text(url, referer=None):
    ref = resolve_referer(url, referer)
    status, _, body = await fetch_bytes(url, referer=ref, timeout=60)
    if status != 200:
        raise DownloadError(f"m3u8 HTTP {status}")
    return body.decode("utf-8", errors="ignore")


def _seg_path(seg_dir, idx):
    return os.path.join(seg_dir, f"{idx:06d}.seg")


def _seg_worker_cffi(q, seg_dir, progress, headers, referer, stop):
    sess = cffi_requests.Session(impersonate="chrome120")
    try:
        while not stop.is_set():
            try:
                idx, seg_url = q.get_nowait()
            except thread_queue.Empty:
                return
            for attempt in range(SEG_RETRIES):
                try:
                    status, _, data = _cffi_session_get(sess, seg_url, headers, referer, timeout=120)
                    if status != 200:
                        raise DownloadError(f"seg {idx} HTTP {status}")
                    if not data:
                        raise DownloadError(f"seg {idx} kosong")
                    with open(_seg_path(seg_dir, idx), "wb") as f:
                        f.write(data)
                    progress.add_part(len(data))
                    break
                except Exception as e:
                    if attempt == SEG_RETRIES - 1:
                        stop.set()
                        raise DownloadError(f"seg {idx}: {e}")
                    time.sleep(0.5 * (attempt + 1))
    finally:
        try: sess.close()
        except Exception: pass


async def download_hls_manual(m3u8_url, dest_ts, status_msg, referer=None, depth=0):
    if depth > 6:
        raise DownloadError("terlalu banyak level m3u8 (nested master)")

    text = await _fetch_m3u8_text(m3u8_url, referer=referer)
    typ, urls = parse_m3u8(text, m3u8_url)
    if typ == "master" and urls:
        best = pick_best_variant(urls)
        await safe_edit(status_msg, "Master m3u8 -> varian terbaik dipilih")
        return await download_hls_manual(best, dest_ts, status_msg,
                                         referer=referer or m3u8_url, depth=depth + 1)
    if not urls:
        raise DownloadError("m3u8 tidak berisi segmen")
    if re.search(r"#EXT-X-KEY:[^\n]*METHOD=(?!NONE)", text):
        raise DownloadError("HLS terenkripsi (pakai ffmpeg)")

    total_segs = len(urls)
    log.info("HLS: %d segmen", total_segs)
    progress = SegProgress(status_msg, total_segs)
    await progress.update(force=True)

    seg_dir = dest_ts + "_segs"
    shutil.rmtree(seg_dir, ignore_errors=True)
    os.makedirs(seg_dir)

    use_cffi = is_surrit_host(m3u8_url) or is_surrit_host(urls[0])
    seg_referer = resolve_referer(m3u8_url, referer) or m3u8_url
    hdrs = build_headers(m3u8_url, seg_referer)
    n_workers = max(1, min(NUM_SEG_PARTS, total_segs))
    rep = asyncio.create_task(seg_reporter(progress))

    try:
        if use_cffi:
            if not HAS_CFFI:
                raise DownloadError("host ini butuh curl_cffi (pip install curl_cffi)")
            q = thread_queue.Queue()
            for i, u in enumerate(urls): q.put((i, u))
            stop = threading.Event()
            workers = [asyncio.create_task(asyncio.to_thread(
                _seg_worker_cffi, q, seg_dir, progress, hdrs, seg_referer, stop))
                for _ in range(n_workers)]
            await asyncio.gather(*workers)
        else:
            q = asyncio.Queue()
            for i, u in enumerate(urls): q.put_nowait((i, u))
            timeout = aiohttp.ClientTimeout(total=None, sock_connect=20, sock_read=60)
            connector = aiohttp.TCPConnector(limit=n_workers + 4)
            async with aiohttp.ClientSession(timeout=timeout, headers=hdrs, connector=connector) as sess:
                async def worker():
                    while True:
                        try: idx, seg_url = q.get_nowait()
                        except asyncio.QueueEmpty: return
                        for attempt in range(SEG_RETRIES):
                            try:
                                async with sess.get(seg_url, allow_redirects=True) as r:
                                    if r.status != 200:
                                        raise DownloadError(f"seg {idx} HTTP {r.status}")
                                    data = await r.read()
                                if not data:
                                    raise DownloadError(f"seg {idx} kosong")
                                with open(_seg_path(seg_dir, idx), "wb") as f:
                                    f.write(data)
                                progress.add_part(len(data))
                                break
                            except Exception as e:
                                if attempt == SEG_RETRIES - 1:
                                    raise DownloadError(f"seg {idx}: {e}")
                                await asyncio.sleep(0.5 * (attempt + 1))
                tasks = [asyncio.create_task(worker()) for _ in range(n_workers)]
                try:
                    await asyncio.gather(*tasks)
                except Exception:
                    for t in tasks: t.cancel()
                    await asyncio.gather(*tasks, return_exceptions=True)
                    raise
        await progress.update(force=True)
    except Exception:
        shutil.rmtree(seg_dir, ignore_errors=True)
        raise
    finally:
        rep.cancel()
        await asyncio.gather(rep, return_exceptions=True)

    await safe_edit(status_msg, f"Menggabungkan {total_segs} segmen...")
    try:
        with open(dest_ts, "wb") as out:
            for i in range(total_segs):
                p = _seg_path(seg_dir, i)
                if not os.path.exists(p):
                    raise DownloadError("ada segmen yang tidak terunduh")
                with open(p, "rb") as f:
                    shutil.copyfileobj(f, out, 1024 * 1024)
                os.remove(p)
    finally:
        shutil.rmtree(seg_dir, ignore_errors=True)
    return dest_ts


# ====== DOWNLOAD FILE UTUH ======
async def download_part(session, url, start, end, fd, counter, idx):
    pos = start
    attempt = 0
    while pos <= end:
        before = pos
        try:
            async with session.get(url, headers={"Range": f"bytes={pos}-{end}"}) as r:
                if r.status != 206:
                    raise RangeNotSupported(f"part {idx}: HTTP {r.status}")
                async for chunk in r.content.iter_chunked(CHUNK_SIZE):
                    remain = end - pos + 1
                    if len(chunk) > remain:
                        chunk = chunk[:remain]
                    os.pwrite(fd, chunk, pos)
                    pos += len(chunk)
                    counter["done"] += len(chunk)
                    if pos > end:
                        break
            if pos <= end:
                raise aiohttp.ClientPayloadError("koneksi putus")
        except RangeNotSupported:
            raise
        except (aiohttp.ClientError, asyncio.TimeoutError) as e:
            if pos > before: attempt = 0
            attempt += 1
            if attempt > PART_RETRIES:
                raise DownloadError(f"part {idx} gagal: {e}")
            await asyncio.sleep(min(2 * attempt, 10))


async def download_multipart(url, dest, total, status_msg, headers):
    num_parts = max(1, min(NUM_PARTS, total // MIN_PART_BYTES))
    part = total // num_parts
    ranges = [(i * part, (i + 1) * part - 1 if i < num_parts - 1 else total - 1) for i in range(num_parts)]
    counter = {"done": 0}
    progress = Progress(status_msg, total)
    await progress.update(0, force=True)
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    tasks, rep = [], None
    try:
        os.ftruncate(fd, total)
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=20, sock_read=120)
        connector = aiohttp.TCPConnector(limit=num_parts + 2)
        async with aiohttp.ClientSession(timeout=timeout, headers=headers, connector=connector) as session:
            tasks = [asyncio.create_task(download_part(session, url, s, e, fd, counter, i))
                     for i, (s, e) in enumerate(ranges)]
            rep = asyncio.create_task(reporter(progress, counter))
            await asyncio.gather(*tasks)
        if counter["done"] != total:
            raise DownloadError(f"ukuran tidak cocok ({counter['done']} / {total})")
        await progress.update(total, force=True)
    finally:
        if rep: rep.cancel()
        for t in tasks:
            if not t.done(): t.cancel()
        await asyncio.gather(*tasks, *([rep] if rep else []), return_exceptions=True)
        os.close(fd)


async def download_single(url, dest, total, status_msg, headers):
    counter = {"done": 0}
    progress = Progress(status_msg, total)
    rep = None
    try:
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=20, sock_read=120)
        async with aiohttp.ClientSession(timeout=timeout, headers=headers) as s:
            async with s.get(url, allow_redirects=True) as r:
                if r.status != 200:
                    raise DownloadError(f"HTTP {r.status}")
                if not total:
                    try: total = int(r.headers.get("Content-Length") or 0)
                    except ValueError: total = 0
                    progress.total = total
                if total > MAX_BYTES:
                    raise TooBig(f"file {human_size(total)} > {MAX_SIZE_MB}MB")
                await progress.update(0, force=True)
                rep = asyncio.create_task(reporter(progress, counter))
                with open(dest, "wb") as f:
                    async for chunk in r.content.iter_chunked(CHUNK_SIZE):
                        f.write(chunk)
                        counter["done"] += len(chunk)
                        if counter["done"] > MAX_BYTES:
                            raise TooBig(f"melebihi {MAX_SIZE_MB}MB")
        if total and counter["done"] < total:
            raise DownloadError(f"terpotong ({counter['done']}/{total})")
        await progress.update(counter["done"], force=True)
    finally:
        if rep:
            rep.cancel()
            await asyncio.gather(rep, return_exceptions=True)


async def smart_download(url, dest, status_msg, size, ranges_ok, headers, job_dir):
    if size > MAX_BYTES:
        raise TooBig(f"file {human_size(size)} > {MAX_SIZE_MB}MB")
    if size:
        free = shutil.disk_usage(job_dir).free
        if free < size * 1.05:
            raise DownloadError(f"disk kurang (butuh {human_size(size)}, sisa {human_size(free)})")
    if ranges_ok and size >= MULTIPART_MIN_SIZE:
        try:
            await safe_edit(status_msg, f"Download paralel ({human_size(size)})...")
            await download_multipart(url, dest, size, status_msg, headers)
            return
        except TooBig:
            raise
        except (DownloadError, aiohttp.ClientError, asyncio.TimeoutError) as e:
            log.warning("multipart gagal: %s", e)
            await safe_edit(status_msg, "Multipart gagal, coba single...")
            if os.path.exists(dest): os.remove(dest)
    last = None
    for _ in range(2):
        try:
            await download_single(url, dest, size, status_msg, headers)
            return
        except TooBig:
            raise
        except (DownloadError, aiohttp.ClientError, asyncio.TimeoutError) as e:
            last = e
            if os.path.exists(dest): os.remove(dest)
            await asyncio.sleep(2)
    raise DownloadError(f"download gagal: {last}")


# ====== FFMPEG HELPERS ======
def download_hls_ffmpeg(url, dest, referer=None):
    hdr = f"User-Agent: {HEADERS['User-Agent']}\r\nAccept: */*\r\nAccept-Language: en-US,en;q=0.9\r\n"
    ref = resolve_referer(url, referer)
    if not ref:
        pp = urlparse(url)
        ref = f"{pp.scheme}://{pp.netloc}/"
    pp = urlparse(ref)
    hdr += f"Referer: {ref}\r\nOrigin: {pp.scheme}://{pp.netloc}\r\n"
    base = ["ffmpeg", "-y", "-nostdin", "-loglevel", "error",
            "-protocol_whitelist", "http,https,tcp,tls,crypto",
            "-headers", hdr, "-i", url, "-c", "copy", "-fs", str(MAX_BYTES)]
    last_err = ""
    for bsf in (["-bsf:a", "aac_adtstoasc"], []):
        try:
            r = subprocess.run(base + bsf + [dest], capture_output=True, text=True, timeout=HLS_TIMEOUT)
        except FileNotFoundError:
            raise DownloadError("ffmpeg belum terpasang")
        except subprocess.TimeoutExpired:
            raise DownloadError("HLS timeout")
        if r.returncode == 0 and os.path.exists(dest) and os.path.getsize(dest) > 0:
            return
        last_err = (r.stderr or "")[-200:]
    raise DownloadError(f"ffmpeg gagal: {last_err.strip()}")


def concat_ts_to_mp4(src_ts, dst_mp4):
    try:
        r = subprocess.run(
            ["ffmpeg", "-y", "-nostdin", "-loglevel", "error",
             "-i", src_ts, "-c", "copy", "-bsf:a", "aac_adtstoasc",
             "-movflags", "+faststart", dst_mp4],
            capture_output=True, timeout=HLS_TIMEOUT)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0 and os.path.exists(dst_mp4) and os.path.getsize(dst_mp4) > 0


def probe_video(path):
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=width,height,duration:format=duration",
             "-of", "json", path],
            capture_output=True, text=True, timeout=60)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {}
    try:
        d = json.loads(r.stdout or "{}")
    except ValueError:
        return {}
    streams = d.get("streams") or []
    if r.returncode != 0 or not streams:
        return None
    st = streams[0]
    try: dur = float(st.get("duration") or (d.get("format") or {}).get("duration") or 0)
    except ValueError: dur = 0
    return {"width": int(st.get("width") or 0), "height": int(st.get("height") or 0), "duration": int(dur)}


def make_thumb(path, out, duration):
    ss = "1" if duration > 3 else "0"
    try:
        r = subprocess.run(
            ["ffmpeg", "-y", "-nostdin", "-loglevel", "error", "-ss", ss, "-i", path,
             "-frames:v", "1", "-vf", "scale=320:-2", "-q:v", "5", out],
            capture_output=True, timeout=60)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if r.returncode == 0 and os.path.exists(out) and 0 < os.path.getsize(out) < 500 * 1024:
        return out
    return None


def remux_to_mp4(src, dst):
    try:
        r = subprocess.run(
            ["ffmpeg", "-y", "-nostdin", "-loglevel", "error", "-i", src,
             "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
             "-movflags", "+faststart", dst],
            capture_output=True, timeout=HLS_TIMEOUT)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0 and os.path.exists(dst) and os.path.getsize(dst) > 0


# ====== PIPELINE ======
async def process_url(url, status_msg, job_dir, depth=0, referer=None):
    if depth > MAX_DEPTH:
        raise DownloadError("terlalu dalam menelusuri halaman")
    await safe_edit(status_msg, "Menganalisis URL...")
    if not ALLOW_PRIVATE_HOSTS and not await asyncio.to_thread(is_safe_url, url):
        raise DownloadError("URL ke alamat lokal/privat diblokir")

    info = await probe(url, referer)
    if info["status"] == 0:
        raise DownloadError(f"tidak bisa akses URL ({info['error'] or 'timeout/DNS'})")
    if info["status"] >= 400:
        raise DownloadError(f"server balas HTTP {info['status']}")

    final, ct = info["url"], info["ct"]
    if final != url and not ALLOW_PRIVATE_HOSTS and not await asyncio.to_thread(is_safe_url, final):
        raise DownloadError("redirect ke alamat lokal/privat diblokir")

    eff_ref = info["referer"] if info["referer"] is not None else referer
    headers = build_headers(final, eff_ref)
    path_l = urlparse(final).path.lower()

    if "mpegurl" in ct or path_l.endswith(".m3u8"):
        dest_ts = os.path.join(job_dir, "hls.ts")
        await safe_edit(status_msg, "HLS terdeteksi — download paralel segmen...")
        try:
            await download_hls_manual(final, dest_ts, status_msg, referer=eff_ref)
            mp4 = os.path.join(job_dir, "hls.mp4")
            await safe_edit(status_msg, "Konversi TS -> MP4...")
            if await asyncio.to_thread(concat_ts_to_mp4, dest_ts, mp4):
                os.remove(dest_ts)
                return mp4, make_filename(final, "", ".mp4")
            return dest_ts, make_filename(final, "", ".ts")
        except DownloadError as e:
            log.warning("manual HLS gagal (%s), fallback ffmpeg", e)
            await safe_edit(status_msg, "Download manual gagal — fallback ke ffmpeg...")
            dest = os.path.join(job_dir, "src.mp4")
            await asyncio.to_thread(download_hls_ffmpeg, final, dest, eff_ref)
            return dest, make_filename(final, "", ".mp4")

    if path_l.endswith(".mpd") or "dash+xml" in ct:
        dest = os.path.join(job_dir, "dash.mp4")
        await safe_edit(status_msg, "DASH stream — via ffmpeg...")
        await asyncio.to_thread(download_hls_ffmpeg, final, dest, eff_ref)
        return dest, make_filename(final, "", ".mp4")

    if is_textual(ct):
        await safe_edit(status_msg, "Mencari URL video di halaman...")
        body = info["body"]
        cands = extract_from_json(body, final) if "json" in ct else extract_from_html(body, final)
        cands = [c for c in cands if c not in (url, final)]
        if not cands:
            raise DownloadError("tidak menemukan URL video di halaman")
        last = None
        for c in cands[:MAX_CANDIDATES]:
            try:
                return await process_url(c, status_msg, job_dir, depth + 1, referer=final)
            except TooBig:
                raise
            except DownloadError as e:
                last = e
        raise DownloadError(f"semua kandidat gagal (terakhir: {last})")

    looks_video = (
        ct.startswith("video/")
        or ct in ("application/octet-stream", "binary/octet-stream",
                  "application/mp4", "application/x-matroska", "video/mp2t")
        or path_l.endswith(VIDEO_EXTS)
    )
    if not looks_video:
        raise DownloadError(f"tipe konten tidak didukung: {ct or 'tidak diketahui'}")

    ext = guess_ext(ct, final)
    dest = os.path.join(job_dir, f"src{ext}")
    if is_surrit_host(final):
        await download_single(final, dest, info["size"], status_msg, headers)
    else:
        await smart_download(final, dest, status_msg, info["size"], info["ranges"], headers, job_dir)
    return dest, make_filename(final, info["disp"], ext)


async def upload_to_channel(bot, path, meta, thumb, as_video):
    common = dict(
        chat_id=CHANNEL_ID,
        read_timeout=1800, write_timeout=1800,
        connect_timeout=30, pool_timeout=30,
    )
    real = Path(os.path.realpath(path))
    if as_video:
        extra = {}
        for k in ("width", "height", "duration"):
            if meta.get(k): extra[k] = meta[k]
        if thumb: extra["thumbnail"] = Path(os.path.realpath(thumb))
        await bot.send_video(video=real, supports_streaming=True, **extra, **common)
    else:
        await bot.send_document(document=real, **common)


async def run_job(url, status_msg, bot):
    job_dir = os.path.join(DOWNLOAD_DIR, uuid.uuid4().hex[:12])
    os.makedirs(job_dir, exist_ok=True)
    try:
        path, filename = await process_url(url, status_msg, job_dir)
        size = os.path.getsize(path)
        if size > MAX_BYTES:
            raise TooBig(f"file {human_size(size)} > {MAX_SIZE_MB}MB")

        await safe_edit(status_msg, "Memeriksa file video...")
        meta = await asyncio.to_thread(probe_video, path)
        if meta is None:
            raise DownloadError("hasil download bukan video valid")

        send_path, as_video = path, True
        if not path.lower().endswith(".mp4"):
            await safe_edit(status_msg, "Konversi ke MP4 (tanpa re-encode)...")
            out = os.path.join(job_dir, "out.mp4")
            if await asyncio.to_thread(remux_to_mp4, path, out):
                send_path = out
                filename = os.path.splitext(filename)[0] + ".mp4"
            else:
                as_video = False

        send_size = os.path.getsize(send_path)
        if send_size > MAX_BYTES:
            raise TooBig(f"file {human_size(send_size)} > {MAX_SIZE_MB}MB")

        thumb = None
        if as_video:
            thumb = await asyncio.to_thread(make_thumb, send_path,
                                            os.path.join(job_dir, "thumb.jpg"),
                                            (meta or {}).get("duration", 0))

        size_mb = send_size / 1024 / 1024
        await safe_edit(status_msg, f"Upload ke channel ({size_mb:.1f} MB)...")
        await upload_to_channel(bot, send_path, meta or {}, thumb, as_video)
        await safe_edit(status_msg, f"Selesai! {filename} ({size_mb:.1f} MB)")
    except DownloadError as e:
        await safe_edit(status_msg, f"Gagal: {e}")
    except Exception as e:
        log.exception("job error")
        await safe_edit(status_msg, f"Error: {str(e)[:300]}")
    finally:
        shutil.rmtree(job_dir, ignore_errors=True)


# ====== HANDLER ======
URL_RE = re.compile(r"https?://[^\s<>\"']+", re.I)


async def cmd_id(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user and update.message:
        await update.message.reply_text(f"ID kamu: {update.effective_user.id}")


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.message:
        await update.message.reply_text(
            "Kirim link video (direct / m3u8 / halaman web), bot akan download "
            f"dan upload ke channel.\nBatas ukuran: {MAX_SIZE_MB}MB.\n/id = lihat ID kamu.")


async def handle_link(update: Update, context: ContextTypes.DEFAULT_TYPE):
    msg, user = update.message, update.effective_user
    if not msg or not msg.text or not user:
        return
    if user.id not in ALLOWED_USERS:
        await msg.reply_text("Akses ditolak. Kirim /id lalu minta admin menambahkan ID kamu.")
        return
    m = URL_RE.search(msg.text)
    if not m:
        await msg.reply_text("Kirim link valid (http/https).")
        return
    url = m.group(0).rstrip(").,;")
    status_msg = await msg.reply_text("Memproses...")
    waiting = JOB_SEM.locked()
    if waiting:
        await safe_edit(status_msg, "Antri — menunggu job sebelumnya selesai...")
    async with JOB_SEM:
        if waiting:
            await safe_edit(status_msg, "Memproses...")
        await run_job(url, status_msg, context.bot)


async def on_error(update, context: ContextTypes.DEFAULT_TYPE):
    log.error("Unhandled error", exc_info=context.error)


async def post_init(app: Application):
    global JOB_SEM
    JOB_SEM = asyncio.Semaphore(MAX_JOBS)


def cleanup_stale_jobs():
    """Hapus sisa folder job dari sesi sebelumnya (mis. bot crash)."""
    try:
        for name in os.listdir(DOWNLOAD_DIR):
            p = os.path.join(DOWNLOAD_DIR, name)
            if os.path.isdir(p) and re.fullmatch(r"[0-9a-f]{12}", name):
                shutil.rmtree(p, ignore_errors=True)
    except OSError:
        pass


def main():
    if not BOT_TOKEN:
        sys.exit("BOT_TOKEN belum diset (isi file .env).")
    if not CHANNEL_ID:
        sys.exit("CHANNEL_ID belum diset (isi file .env).")
    if not ALLOWED_USERS:
        print("PERINGATAN: ALLOWED_USERS kosong — semua link ditolak.")
    cleanup_stale_jobs()

    builder = (
        Application.builder()
        .token(BOT_TOKEN)
        .concurrent_updates(True)
        .connect_timeout(30.0)
        .read_timeout(1800.0)
        .write_timeout(1800.0)
        .pool_timeout(30.0)
        .get_updates_connect_timeout(30.0)
        .get_updates_read_timeout(45.0)
        .get_updates_write_timeout(30.0)
        .get_updates_pool_timeout(30.0)
        .post_init(post_init)
    )
    if API_HOST:
        builder = (builder.base_url(f"{API_HOST}/bot")
                   .base_file_url(f"{API_HOST}/file/bot")
                   .local_mode(True))
    application = builder.build()

    application.add_handler(CommandHandler("start", cmd_start))
    application.add_handler(CommandHandler("id", cmd_id))
    application.add_handler(
        MessageHandler(filters.TEXT & ~filters.COMMAND & filters.UpdateType.MESSAGE, handle_link))
    application.add_error_handler(on_error)

    mode = f"Local API {API_HOST}" if API_HOST else "API resmi Telegram (limit ~50MB)"
    print(f"Bot v4 jalan — {mode} — {NUM_PARTS} paralel (file), {NUM_SEG_PARTS} paralel (HLS).")
    application.run_polling(poll_interval=2.0, timeout=30, drop_pending_updates=True)


if __name__ == "__main__":
    main()
PYEOF
python -m py_compile bot.py || die "bot.py hasil tulis tidak valid (download skrip kemungkinan terpotong). Jalankan ulang."

# ---------- 4. Library Python ----------
say "Install library Python"
retry 3 pip install --no-cache-dir "${PIP_PKGS[@]}" </dev/null \
    || die "Gagal memasang library Python. Cek koneksi/ruang penyimpanan lalu jalankan ulang."
if ! pip install --no-cache-dir curl_cffi </dev/null >/dev/null 2>&1; then
    warn "curl_cffi gagal dipasang (hanya perlu untuk host surrit, aman diabaikan)"
fi
python -c "import telegram, aiohttp" 2>/dev/null \
    || die "Library terpasang tapi gagal di-import. Jalankan: python -c 'import telegram, aiohttp'"

# ---------- 5. Konfigurasi ----------
if [ -f .env ] && grep -q '^BOT_TOKEN=.\+' .env && grep -q '^CHANNEL_ID=.\+' .env; then
    say ".env sudah lengkap - tidak ditimpa"
else
    say "Konfigurasi bot"
    BOT_TOKEN="$(ask_required 'BOT_TOKEN (dari @BotFather):')"
    CHANNEL_ID="$(ask_required 'CHANNEL_ID (contoh -1001234567890):')"
    ALLOWED_USERS="$(ask_required 'ALLOWED_USERS (ID Telegram kamu, pisah koma):')"
    LOCAL="$(ask 'Pakai Local Bot API server (upload sampai 2GB)? [y/N]:' 'n')"
    API_HOST=""
    case "$LOCAL" in
        y|Y) API_HOST="$(ask 'API_HOST [http://127.0.0.1:8081]:' 'http://127.0.0.1:8081')" ;;
    esac
    cat > .env <<EOF
BOT_TOKEN=$BOT_TOKEN
CHANNEL_ID=$CHANNEL_ID
ALLOWED_USERS=$ALLOWED_USERS
API_HOST=$API_HOST
DOWNLOAD_DIR=$DL_DIR
EOF
    chmod 600 .env
fi

# ---------- 6. Script start ----------
cat > start.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd "$(dirname "$0")" || exit 1
if ! grep -q '^BOT_TOKEN=.\+' .env 2>/dev/null || ! grep -q '^CHANNEL_ID=.\+' .env 2>/dev/null; then
    echo "File .env belum lengkap. Edit dulu: nano .env"
    exit 1
fi
termux-wake-lock 2>/dev/null || true
while true; do
    python bot.py
    echo "Bot berhenti, restart 5 detik... (Ctrl+C untuk keluar)"
    sleep 5
done
EOF
chmod +x start.sh

say "Selesai!"
echo "Jalankan bot:     cd $INSTALL_DIR && ./start.sh"
echo "Edit konfigurasi: nano $INSTALL_DIR/.env"
echo "Update bot:       jalankan ulang perintah curl install"
}

main "$@"
exit $?
