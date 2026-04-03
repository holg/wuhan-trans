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

#[derive(Clone)]
struct AppState {
    rooms: Arc<DashMap<String, Room>>,
    db: Arc<ConversationDb>,
}

struct Room {
    created_at: Instant,
    clients: [Option<mpsc::UnboundedSender<Message>>; 2],
    client_names: [Option<String>; 2],
    save_flags: [bool; 2],
    conversation_id: Option<i64>,
}

#[derive(Serialize)]
struct RoomResponse {
    code: String,
}

#[derive(Deserialize)]
struct ControlMessage {
    #[serde(rename = "type")]
    msg_type: String,
    #[serde(default)]
    peer: Option<String>,
}

#[derive(Deserialize, Default)]
struct PeerMessage {
    #[serde(rename = "originalText", default)]
    original_text: String,
    #[serde(rename = "translatedText", default)]
    translated_text: String,
    #[serde(rename = "sourceLanguage", default)]
    source_language: String,
    #[serde(rename = "targetLanguage", default)]
    target_language: String,
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

    // Background room cleanup
    let rooms_clone = state.rooms.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(60)).await;
            let now = Instant::now();
            rooms_clone.retain(|_, room| {
                let has_clients = room.clients.iter().any(|c| c.is_some());
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

    let addr = std::env::var("LISTEN_ADDR").unwrap_or_else(|_| "0.0.0.0:3000".to_string());
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

    state.rooms.insert(
        code.clone(),
        Room {
            created_at: Instant::now(),
            clients: [None, None],
            client_names: [None, None],
            save_flags: [false, false],
            conversation_id: None,
        },
    );

    tracing::info!("Room created: {code}");
    Json(RoomResponse { code })
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

    // Find a slot in the room
    let slot = {
        let mut room = match state.rooms.get_mut(&code) {
            Some(r) => r,
            None => {
                let _ = ws_tx
                    .send(Message::Text(
                        serde_json::json!({"type":"error","message":"room not found"}).to_string().into(),
                    ))
                    .await;
                return;
            }
        };

        if room.clients[0].is_none() {
            room.clients[0] = Some(tx.clone());
            0
        } else if room.clients[1].is_none() {
            room.clients[1] = Some(tx.clone());
            1
        } else {
            drop(room);
            let _ = ws_tx
                .send(Message::Text(
                    serde_json::json!({"type":"error","message":"room full"}).to_string().into(),
                ))
                .await;
            return;
        }
    };

    let other = 1 - slot;
    tracing::info!("Client {slot} joined room {code}");

    // Notify both if paired
    if let Some(room) = state.rooms.get(&code) {
        if room.clients[0].is_some() && room.clients[1].is_some() {
            let name_a = room.client_names[0].clone().unwrap_or_else(|| "Device A".into());
            let name_b = room.client_names[1].clone().unwrap_or_else(|| "Device B".into());
            if let Some(ref c) = room.clients[0] {
                let _ = c.send(Message::Text(
                    serde_json::json!({"type":"paired","peer": name_b}).to_string().into(),
                ));
            }
            if let Some(ref c) = room.clients[1] {
                let _ = c.send(Message::Text(
                    serde_json::json!({"type":"paired","peer": name_a}).to_string().into(),
                ));
            }
        }
    }

    // Forward messages from channel to WebSocket
    let code_clone = code.clone();
    let send_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if ws_tx.send(msg).await.is_err() {
                break;
            }
        }
        tracing::info!("Send task ended for room {code_clone} slot {slot}");
    });

    // Read messages from WebSocket
    let state_clone = state.clone();
    let code_clone2 = code.clone();
    let recv_task = tokio::spawn(async move {
        while let Some(Ok(msg)) = ws_rx.next().await {
            match msg {
                Message::Text(text) => {
                    let text_str: &str = &text;

                    // Check if it's a control message
                    if let Ok(ctrl) = serde_json::from_str::<ControlMessage>(text_str) {
                        match ctrl.msg_type.as_str() {
                            "enable_save" => {
                                if let Some(mut room) = state_clone.rooms.get_mut(&code_clone2) {
                                    room.save_flags[slot] = true;
                                    if room.save_flags[0] && room.save_flags[1] {
                                        if room.conversation_id.is_none() {
                                            room.conversation_id =
                                                Some(state_clone.db.create_conversation(&code_clone2));
                                        }
                                        // Notify both
                                        for c in room.clients.iter().flatten() {
                                            let _ = c.send(Message::Text(
                                                serde_json::json!({"type":"save_status","active":true})
                                                    .to_string().into(),
                                            ));
                                        }
                                    }
                                }
                                continue;
                            }
                            "disable_save" => {
                                if let Some(mut room) = state_clone.rooms.get_mut(&code_clone2) {
                                    room.save_flags[slot] = false;
                                    for c in room.clients.iter().flatten() {
                                        let _ = c.send(Message::Text(
                                            serde_json::json!({"type":"save_status","active":false})
                                                .to_string().into(),
                                        ));
                                    }
                                }
                                continue;
                            }
                            _ => {} // Not a recognized control message, relay it
                        }
                    }

                    // Save to DB if both opted in
                    if let Some(room) = state_clone.rooms.get(&code_clone2) {
                        if room.save_flags[0] && room.save_flags[1] {
                            if let Some(conv_id) = room.conversation_id {
                                if let Ok(pm) = serde_json::from_str::<PeerMessage>(text_str) {
                                    let sender = if slot == 0 { "A" } else { "B" };
                                    state_clone.db.save_message(
                                        conv_id,
                                        &pm.original_text,
                                        &pm.translated_text,
                                        &pm.source_language,
                                        &pm.target_language,
                                        &pm.timestamp,
                                        sender,
                                    );
                                }
                            }
                        }

                        // Relay to other client
                        if let Some(ref c) = room.clients[other] {
                            let _ = c.send(Message::Text(text));
                        }
                    }
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
        tracing::info!("Recv task ended for room {code_clone2} slot {slot}");
    });

    // Wait for either task to finish
    tokio::select! {
        _ = send_task => {},
        _ = recv_task => {},
    }

    // Cleanup
    if let Some(mut room) = state.rooms.get_mut(&code) {
        room.clients[slot] = None;
        room.client_names[slot] = None;
        room.save_flags[slot] = false;

        // Notify other client
        if let Some(ref c) = room.clients[other] {
            let _ = c.send(Message::Text(
                serde_json::json!({"type":"peer_left"}).to_string().into(),
            ));
        }
    }
    tracing::info!("Client {slot} left room {code}");
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
