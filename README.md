# video_bot

Bot Telegram: kirim link video → bot download → upload ke channel.
Support direct file (multipart), HLS/m3u8 (segmen paralel), DASH (ffmpeg), dan halaman web yang berisi video.

## Install di Termux (satu perintah)

Ganti `USERNAME` dengan username GitHub kamu:

```bash
curl -fsSL https://raw.githubusercontent.com/USERNAME/video_bot/main/install.sh | REPO_URL=https://github.com/USERNAME/video_bot.git bash
```

Installer akan memasang paket, mengambil source, dan menanyakan BOT_TOKEN, CHANNEL_ID, dan ALLOWED_USERS.

## Jalankan

```bash
cd ~/video_bot && ./start.sh
```

## Update

Jalankan ulang perintah install di atas. File `.env` tidak ditimpa.

## Konfigurasi (.env)

Lihat `.env.example`. Tanpa `API_HOST`, bot memakai API resmi Telegram (upload maks ~50MB).
Untuk 2GB, jalankan Local Bot API server dan isi `API_HOST=http://127.0.0.1:8081`.

## Perintah bot

- `/id` — lihat ID Telegram kamu (untuk ALLOWED_USERS)
- Kirim link apa saja untuk memulai download
