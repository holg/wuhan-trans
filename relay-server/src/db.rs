use rusqlite::{Connection, params};
use std::sync::Mutex;

pub struct ConversationDb {
    conn: Mutex<Connection>,
}

impl ConversationDb {
    pub fn new(path: &str) -> Self {
        let conn = Connection::open(path).expect("Failed to open SQLite database");
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS conversations (
                id INTEGER PRIMARY KEY,
                room_code TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY,
                conversation_id INTEGER REFERENCES conversations(id),
                original_text TEXT NOT NULL,
                translated_text TEXT NOT NULL,
                source_language TEXT NOT NULL,
                target_language TEXT NOT NULL,
                timestamp TEXT NOT NULL,
                sender TEXT
            );",
        )
        .expect("Failed to create tables");
        Self { conn: Mutex::new(conn) }
    }

    pub fn create_conversation(&self, room_code: &str) -> i64 {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO conversations (room_code) VALUES (?1)",
            params![room_code],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    pub fn save_message(
        &self,
        conversation_id: i64,
        original_text: &str,
        translated_text: &str,
        source_language: &str,
        target_language: &str,
        timestamp: &str,
        sender: &str,
    ) {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO messages (conversation_id, original_text, translated_text, source_language, target_language, timestamp, sender)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![conversation_id, original_text, translated_text, source_language, target_language, timestamp, sender],
        )
        .ok();
    }

    pub fn get_conversation(&self, room_code: &str) -> Option<serde_json::Value> {
        let conn = self.conn.lock().unwrap();
        let conv_id: Option<i64> = conn
            .query_row(
                "SELECT id FROM conversations WHERE room_code = ?1 ORDER BY id DESC LIMIT 1",
                params![room_code],
                |row| row.get(0),
            )
            .ok();

        let conv_id = conv_id?;
        let mut stmt = conn
            .prepare("SELECT original_text, translated_text, source_language, target_language, timestamp, sender FROM messages WHERE conversation_id = ?1 ORDER BY id")
            .ok()?;

        let messages: Vec<serde_json::Value> = stmt
            .query_map(params![conv_id], |row| {
                Ok(serde_json::json!({
                    "originalText": row.get::<_, String>(0)?,
                    "translatedText": row.get::<_, String>(1)?,
                    "sourceLanguage": row.get::<_, String>(2)?,
                    "targetLanguage": row.get::<_, String>(3)?,
                    "timestamp": row.get::<_, String>(4)?,
                    "sender": row.get::<_, String>(5)?,
                }))
            })
            .ok()?
            .filter_map(|r| r.ok())
            .collect();

        Some(serde_json::json!({
            "roomCode": room_code,
            "messages": messages,
        }))
    }
}
