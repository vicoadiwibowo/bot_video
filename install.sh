#!/data/data/com.termux/files/usr/bin/bash
# video_bot installer untuk Termux
# Pakai:  curl -fsSL https://raw.githubusercontent.com/vicoadiwibowo/bot_video/main/install.sh | bash
# Jalankan lagi kapan saja untuk update (file .env tidak ditimpa).

set -e

REPO_URL="${REPO_URL:-https://github.com/vicoadiwibowo/bot_video.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/bot_video}"

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$1"; }
ask() {  # ask "pertanyaan" "default" -> echo jawaban
    local ans
    if [ -r /dev/tty ]; then
        read -r -p "$1 " ans </dev/tty || true
    fi
    echo "${ans:-$2}"
}

say "Update paket Termux"
pkg update -y
pkg install -y python ffmpeg git clang libffi openssl

say "Izin storage (klik Allow jika muncul)"
[ -d "$HOME/storage" ] || termux-setup-storage || true
sleep 2

say "Ambil source dari GitHub"
if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --ff-only
else
    git clone "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

say "Install library Python"
export AIOHTTP_NO_EXTENSIONS=1 FROZENLIST_NO_EXTENSIONS=1 \
       MULTIDICT_NO_EXTENSIONS=1 YARL_NO_EXTENSIONS=1
pip install -r requirements.txt
pip install curl_cffi || echo "(curl_cffi gagal dipasang - hanya perlu untuk host surrit, boleh diabaikan)"

if [ ! -f .env ]; then
    say "Konfigurasi bot"
    BOT_TOKEN=$(ask "BOT_TOKEN (dari @BotFather):" "")
    CHANNEL_ID=$(ask "CHANNEL_ID (contoh -1001234567890):" "")
    ALLOWED_USERS=$(ask "ALLOWED_USERS (ID Telegram kamu, pisah koma):" "")
    LOCAL=$(ask "Pakai Local Bot API server (upload sampai 2GB)? [y/N]:" "n")
    API_HOST=""
    case "$LOCAL" in
        y|Y) API_HOST=$(ask "API_HOST [http://127.0.0.1:8081]:" "http://127.0.0.1:8081") ;;
    esac
    cat > .env <<EOF
BOT_TOKEN=$BOT_TOKEN
CHANNEL_ID=$CHANNEL_ID
ALLOWED_USERS=$ALLOWED_USERS
API_HOST=$API_HOST
EOF
    chmod 600 .env
else
    say ".env sudah ada - tidak ditimpa"
fi

cat > start.sh <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
cd "$(dirname "$0")"
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