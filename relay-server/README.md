# vtranslate-relay

Lightweight WebSocket relay server for VoiceTranslator internet pairing. Written in Rust.

## What it does

- Creates rooms with 6-digit codes
- Relays text messages between up to 10 connected clients
- Optional conversation persistence to SQLite (opt-in by all participants)
- Broadcasts participant roster on join/leave

The server is a dumb pipe — it never translates. Each client app translates locally.

## API

### REST

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/room` | Create room → `{"code":"482719","max_clients":10}` |
| `GET` | `/health` | Health check → `ok` |
| `GET` | `/conversation/{code}` | Retrieve saved conversation (if save was enabled) |

### WebSocket

Connect: `wss://voice.rlxapi.eu/ws/{room_code}`

**Control messages (client → server):**
```json
{"type":"set_name","name":"Holger's iPhone"}
{"type":"enable_save"}
{"type":"disable_save"}
```

**Control messages (server → client):**
```json
{"type":"roster","participants":["Holger's iPhone","Wife's iPhone"],"count":2}
{"type":"save_status","active":true}
{"type":"error","message":"room not found"}
```

**Data messages (client → server → all other clients):**
Any JSON that isn't a control message is relayed verbatim to all other clients in the room.

## Build & Run

```bash
# Local development
cargo run

# With custom port
LISTEN_ADDR=127.0.0.1:3088 cargo run

# With SQLite persistence
DB_PATH=./data/conversations.db cargo run
```

## Deploy

```bash
# From project root
./scripts/deploy_to_server.sh setup        # First time: dirs, systemd, .env
./scripts/deploy_to_server.sh install-nginx # nginx config
./scripts/deploy_to_server.sh deploy       # Build + upload + restart

# Other commands
./scripts/deploy_to_server.sh status       # Check service
./scripts/deploy_to_server.sh logs         # Follow logs
./scripts/deploy_to_server.sh restart      # Restart service
```

Configuration: `scripts/deploy-config.toml`

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LISTEN_ADDR` | `0.0.0.0:3088` | Bind address |
| `DB_PATH` | `conversations.db` | SQLite database path |
| `RUST_LOG` | `info` | Log level |

## Room Lifecycle

- Room created with `POST /room` → 6-digit code
- Clients connect via WebSocket at `/ws/{code}`
- Max 10 clients per room
- Room expires after 5 minutes if empty
- Room destroyed when all clients disconnect
- Background cleanup every 60 seconds

## Multi-user Translation Flow

```
User A (German)  ──► relay ──► User B (Chinese): translates DE→ZH locally
                         └──► User C (French): translates DE→FR locally
                         └──► User D (English): translates DE→EN locally
```

Each device independently translates into its user's preferred language. The relay only sees the original text.
