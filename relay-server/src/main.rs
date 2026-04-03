mod db;

use axum::{
    extract::{Path, State, WebSocketUpgrade, ws::{Message, WebSocket}},
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use dashmap::DashMap;
use db::ConversationDb;
use futures::{SinkExt, StreamExt};
use rand::Rng;
use serde::{Deserialize, Serialize};
use std::{sync::Arc, time::{Duration, Instant}};
use tokio::sync::mpsc;
use tower_http::cors::CorsLayer;

const MAX_CLIENTS_PER_ROOM: usize = 10;

#[derive(Clone)]
struct AppState {
    rooms: Arc<DashMap<String, Room>>,
    db: Arc<ConversationDb>,
}

struct Client {
    tx: mpsc::UnboundedSender<Message>,
    name: String,
    save_enabled: bool,
}

struct Room {
    created_at: Instant,
    clients: Vec<Option<Client>>,
    conversation_id: Option<i64>,
}

impl Room {
    fn new() -> Self {
        Self {
            created_at: Instant::now(),
            clients: Vec::new(),
            conversation_id: None,
        }
    }

    fn active_count(&self) -> usize {
        self.clients.iter().filter(|c| c.is_some()).count()
    }

    fn all_save_enabled(&self) -> bool {
        let active: Vec<_> = self.clients.iter().filter_map(|c| c.as_ref()).collect();
        active.len() >= 2 && active.iter().all(|c| c.save_enabled)
    }

    fn active_names(&self) -> Vec<String> {
        self.clients.iter().filter_map(|c| c.as_ref().map(|c| c.name.clone())).collect()
    }

    fn broadcast(&self, msg: &str, exclude_slot: Option<usize>) {
        for (i, client) in self.clients.iter().enumerate() {
            if Some(i) == exclude_slot { continue; }
            if let Some(c) = client {
                let _ = c.tx.send(Message::Text(msg.to_string().into()));
            }
        }
    }

    fn broadcast_all(&self, msg: &str) {
        self.broadcast(msg, None);
    }
}

#[derive(Serialize)]
struct RoomResponse {
    code: String,
    max_clients: usize,
}

#[derive(Deserialize)]
struct ControlMessage {
    #[serde(rename = "type")]
    msg_type: String,
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize, Default)]
struct RelayMessage {
    #[serde(rename = "originalText", default)]
    original_text: String,
    #[serde(rename = "sourceLanguage", default)]
    source_language: String,
    #[serde(rename = "senderName", default)]
    sender_name: String,
    #[serde(default)]
    timestamp: String,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let db_path = std::env::var("DB_PATH").unwrap_or_else(|_| "conversations.db".to_string());
    let state = AppState {
        rooms: Arc::new(DashMap::new()),
        db: Arc::new(ConversationDb::new(&db_path)),
    };

    let rooms_clone = state.rooms.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            let now = Instant::now();
            rooms_clone.retain(|_, room| {
                let has_clients = room.active_count() > 0;
                let expired = now.duration_since(room.created_at) > Duration::from_secs(300);
                has_clients || !expired
            });
        }
    });

    let app = Router::new()
        .route("/room", post(create_room))
        .route("/ws/{code}", get(ws_handler))
        .route("/conversation/{code}", get(get_conversation))
        .route("/health", get(|| async { "ok" }))
        .layer(CorsLayer::permissive())
        .with_state(state);

    let addr = std::env::var("LISTEN_ADDR").unwrap_or_else(|_| "0.0.0.0:3088".to_string());
    tracing::info!("Relay server listening on {addr}");
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn create_room(State(state): State<AppState>) -> Json<RoomResponse> {
    let mut rng = rand::thread_rng();
    let code = loop {
        let c = format!("{:06}", rng.gen_range(0..1_000_000));
        if !state.rooms.contains_key(&c) {
            break c;
        }
    };

    state.rooms.insert(code.clone(), Room::new());
    tracing::info!("Room created: {code}");
    Json(RoomResponse { code, max_clients: MAX_CLIENTS_PER_ROOM })
}

async fn ws_handler(
    ws: WebSocketUpgrade,
    Path(code): Path<String>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_ws(socket, code, state))
}

async fn handle_ws(socket: WebSocket, code: String, state: AppState) {
    let (mut ws_tx, mut ws_rx) = socket.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    // Find or create a slot
    let slot = {
        let mut room = match state.rooms.get_mut(&code) {
            Some(r) => r,
            None => {
                let _ = ws_tx.send(Message::Text(
                    serde_json::json!({"type":"error","message":"room not found"}).to_string().into(),
                )).await;
                return;
            }
        };

        if room.active_count() >= MAX_CLIENTS_PER_ROOM {
            drop(room);
            let _ = ws_tx.send(Message::Text(
                serde_json::json!({"type":"error","message":"room full"}).to_string().into(),
            )).await;
            return;
        }

        // Find first empty slot or append
        let slot = room.clients.iter().position(|c| c.is_none());
        let slot = match slot {
            Some(i) => {
                room.clients[i] = Some(Client {
                    tx: tx.clone(),
                    name: format!("User {}", i + 1),
                    save_enabled: false,
                });
                i
            }
            None => {
                let i = room.clients.len();
                room.clients.push(Some(Client {
                    tx: tx.clone(),
                    name: format!("User {}", i + 1),
                    save_enabled: false,
                }));
                i
            }
        };

        slot
    };

    tracing::info!("Client {slot} joined room {code} ({} total)", {
        state.rooms.get(&code).map(|r| r.active_count()).unwrap_or(0)
    });

    // Notify everyone about the roster
    send_roster(&state, &code);

    // Forward messages from channel to WebSocket
    let code_clone = code.clone();
    let send_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if ws_tx.send(msg).await.is_err() { break; }
        }
        tracing::debug!("Send task ended for room {code_clone} slot {slot}");
    });

    // Read messages from WebSocket
    let state_clone = state.clone();
    let code_clone2 = code.clone();
    let recv_task = tokio::spawn(async move {
        while let Some(Ok(msg)) = ws_rx.next().await {
            match msg {
                Message::Text(text) => {
                    let text_str: &str = &text;

                    // Control messages
                    if let Ok(ctrl) = serde_json::from_str::<ControlMessage>(text_str) {
                        match ctrl.msg_type.as_str() {
                            "set_name" => {
                                if let Some(name) = ctrl.name {
                                    if let Some(mut room) = state_clone.rooms.get_mut(&code_clone2) {
                                        if let Some(ref mut c) = room.clients.get_mut(slot).and_then(|c| c.as_mut()) {
                                            c.name = name;
                                        }
                                    }
                                    send_roster(&state_clone, &code_clone2);
                                }
                                continue;
                            }
                            "enable_save" => {
                                if let Some(mut room) = state_clone.rooms.get_mut(&code_clone2) {
                                    if let Some(ref mut c) = room.clients.get_mut(slot).and_then(|c| c.as_mut()) {
                                        c.save_enabled = true;
                                    }
                                    if room.all_save_enabled() {
                                        if room.conversation_id.is_none() {
                                            room.conversation_id = Some(state_clone.db.create_conversation(&code_clone2));
                                        }
                                        room.broadcast_all(&serde_json::json!({"type":"save_status","active":true}).to_string());
                                    }
                                }
                                continue;
                            }
                            "disable_save" => {
                                if let Some(mut room) = state_clone.rooms.get_mut(&code_clone2) {
                                    if let Some(ref mut c) = room.clients.get_mut(slot).and_then(|c| c.as_mut()) {
                                        c.save_enabled = false;
                                    }
                                    room.broadcast_all(&serde_json::json!({"type":"save_status","active":false}).to_string());
                                }
                                continue;
                            }
                            _ => {}
                        }
                    }

                    // Data message — broadcast to all others
                    if let Some(room) = state_clone.rooms.get(&code_clone2) {
                        // Save if enabled
                        let save_active = room.all_save_enabled();
                        tracing::debug!("Data msg from slot {slot}, save_active={save_active}, conv_id={:?}", room.conversation_id);
                        if save_active {
                            if let Some(conv_id) = room.conversation_id {
                                match serde_json::from_str::<RelayMessage>(text_str) {
                                    Ok(ref pm) => {
                                        tracing::info!("Saving message: original='{}', sender='{}'", &pm.original_text.chars().take(50).collect::<String>(), &pm.sender_name);
                                    }
                                    Err(e) => {
                                        tracing::warn!("Failed to parse RelayMessage: {e}");
                                    }
                                }
                                if let Ok(pm) = serde_json::from_str::<RelayMessage>(text_str) {
                                    state_clone.db.save_message(
                                        conv_id,
                                        &pm.original_text,
                                        "",  // no pre-translation in multi-user mode
                                        &pm.source_language,
                                        "",
                                        &pm.timestamp,
                                        &pm.sender_name,
                                    );
                                }
                            }
                        }

                        // Broadcast to all except sender
                        room.broadcast(text_str, Some(slot));
                    }
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
        tracing::debug!("Recv task ended for room {code_clone2} slot {slot}");
    });

    tokio::select! {
        _ = send_task => {},
        _ = recv_task => {},
    }

    // Cleanup
    if let Some(mut room) = state.rooms.get_mut(&code) {
        if slot < room.clients.len() {
            room.clients[slot] = None;
        }
    }

    tracing::info!("Client {slot} left room {code}");
    send_roster(&state, &code);
}

fn send_roster(state: &AppState, code: &str) {
    if let Some(room) = state.rooms.get(code) {
        let names = room.active_names();
        let count = names.len();
        let roster = serde_json::json!({
            "type": "roster",
            "participants": names,
            "count": count,
        });
        room.broadcast_all(&roster.to_string());
    }
}

async fn get_conversation(
    Path(code): Path<String>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    match state.db.get_conversation(&code) {
        Some(conv) => Json(conv).into_response(),
        None => (axum::http::StatusCode::NOT_FOUND, "Not found").into_response(),
    }
}
