#!/bin/bash
# Deploy vtranslate-relay to server
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/deploy-config.toml"

# Simple TOML reader
read_config() {
    local key="$1" default="$2"
    [[ ! -f "$CONFIG_FILE" ]] && echo "$default" && return
    local val
    val=$(grep -E "^${key} *=" "$CONFIG_FILE" | head -1 | sed 's/[^=]*= *"*//' | sed 's/"*$//')
    echo "${val:-$default}"
}

SSH_HOST=$(read_config "ssh_host" "")
SERVER_NAME=$(read_config "server_name" "")
APP_NAME=$(read_config "app_name" "vtranslate-relay")
REMOTE_BASE=$(read_config "remote_base" "")
TARGET_TRIPLE=$(read_config "target_triple" "x86_64-unknown-linux-gnu")
LISTEN_ADDR=$(read_config "listen_addr" "127.0.0.1:3000")
DB_PATH=$(read_config "db_path" "./data/conversations.db")
RUST_LOG=$(read_config "rust_log" "info")

[[ -z "$SSH_HOST" || -z "$REMOTE_BASE" ]] && echo "Error: ssh_host and remote_base required in $CONFIG_FILE" && exit 1

LOCAL_BINARY="$PROJECT_DIR/relay-server/target/$TARGET_TRIPLE/release/$APP_NAME"

cd "$PROJECT_DIR"

ssh_cmd() { ssh "$SSH_HOST" "$@"; }

usage() {
    cat <<EOF
Usage: $0 <command>

Commands:
    build       Cross-compile relay server for Linux
    deploy      Build + upload + restart
    upload      Upload binary to server
    setup       First-time: create dirs, systemd service, nginx config
    gen-nginx   Generate nginx config
    install-nginx  Upload and activate nginx config
    restart     Restart service
    logs        Follow service logs
    status      Show service status

Server: $SSH_HOST:$REMOTE_BASE
EOF
    exit 1
}

cmd_build() {
    echo "=== Building $APP_NAME for $TARGET_TRIPLE ==="
    "$SCRIPT_DIR/cross_build_on_mac.sh" "$TARGET_TRIPLE"
}

cmd_upload() {
    echo "=== Uploading to $SSH_HOST ==="
    ssh_cmd "mkdir -p $REMOTE_BASE/data"

    if [[ -f "$LOCAL_BINARY" ]]; then
        rsync -avz --progress "$LOCAL_BINARY" "$SSH_HOST:$REMOTE_BASE/"
        ssh_cmd "chmod +x $REMOTE_BASE/$APP_NAME"
        echo "✓ Binary uploaded"
    else
        echo "✗ Binary not found: $LOCAL_BINARY"
        echo "  Run: $0 build"
        exit 1
    fi

    # Create .env if not exists
    if ! ssh_cmd "test -f $REMOTE_BASE/.env"; then
        ssh_cmd "cat > $REMOTE_BASE/.env" <<ENV
LISTEN_ADDR=$LISTEN_ADDR
DB_PATH=$DB_PATH
RUST_LOG=$RUST_LOG
ENV
        echo "✓ Created .env"
    fi
}

cmd_setup() {
    echo "=== First-time setup on $SSH_HOST ==="

    ssh_cmd "sudo mkdir -p $REMOTE_BASE/data"

    # Systemd service
    cat <<EOF | ssh_cmd "sudo tee /etc/systemd/system/$APP_NAME.service > /dev/null"
[Unit]
Description=VoiceTranslate WebSocket Relay
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=$REMOTE_BASE
ExecStart=$REMOTE_BASE/$APP_NAME
Restart=always
RestartSec=5
EnvironmentFile=$REMOTE_BASE/.env

[Install]
WantedBy=multi-user.target
EOF

    ssh_cmd "sudo bash -s" <<REMOTE
chown -R www-data:www-data $REMOTE_BASE
systemctl daemon-reload
systemctl enable $APP_NAME
REMOTE

    echo "✓ Setup complete. Run: $0 deploy"
}

cmd_gen_nginx() {
    local CONF="$SCRIPT_DIR/generated-nginx-${SERVER_NAME}.conf"
    local PORT="${LISTEN_ADDR##*:}"

    cat > "$CONF" <<NGINX
# vtranslate-relay nginx config
# Install: $0 install-nginx
# Then: sudo certbot --nginx -d $SERVER_NAME

server {
    listen 80;
    server_name $SERVER_NAME;

    # WebSocket relay
    location /ws/ {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    # REST API
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    access_log /var/log/nginx/$SERVER_NAME.access.log;
    error_log  /var/log/nginx/$SERVER_NAME.error.log;
}
NGINX

    echo "✓ Generated: $CONF"
}

cmd_install_nginx() {
    local CONF="$SCRIPT_DIR/generated-nginx-${SERVER_NAME}.conf"
    [[ ! -f "$CONF" ]] && cmd_gen_nginx

    scp "$CONF" "$SSH_HOST:/tmp/$SERVER_NAME"
    ssh_cmd "sudo cp /tmp/$SERVER_NAME /etc/nginx/sites-available/$SERVER_NAME && \
             sudo ln -sf /etc/nginx/sites-available/$SERVER_NAME /etc/nginx/sites-enabled/$SERVER_NAME && \
             sudo nginx -t && sudo systemctl reload nginx"
    echo "✓ Nginx installed. For SSL: sudo certbot --nginx -d $SERVER_NAME"
}

cmd_restart() {
    ssh_cmd "sudo systemctl restart $APP_NAME && sleep 1 && sudo systemctl status $APP_NAME --no-pager"
}

cmd_deploy() {
    cmd_build
    cmd_upload
    cmd_restart
    echo ""
    echo "=== Deployed to $SSH_HOST ==="
    echo "WebSocket: wss://$SERVER_NAME/ws/{code}"
    echo "Create room: https://$SERVER_NAME/room"
}

cmd_logs() {
    ssh_cmd "sudo journalctl -u $APP_NAME -f"
}

cmd_status() {
    ssh_cmd "sudo systemctl status $APP_NAME --no-pager"
    echo ""
    ssh_cmd "sudo journalctl -u $APP_NAME -n 20 --no-pager"
}

case "${1:-}" in
    build)          cmd_build ;;
    deploy)         cmd_deploy ;;
    upload)         cmd_upload ;;
    setup)          cmd_setup ;;
    gen-nginx)      cmd_gen_nginx ;;
    install-nginx)  cmd_install_nginx ;;
    restart)        cmd_restart ;;
    logs)           cmd_logs ;;
    status)         cmd_status ;;
    *)              usage ;;
esac
