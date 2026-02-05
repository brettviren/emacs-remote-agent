use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use base64::Engine;

// --- Constants ---
const PROTOCOL_VERSION: u32 = 2;
const MAX_CHUNK_SIZE: usize = 1024 * 1024;
const AGENT_TIMEOUT: u64 = 300;
const TMP_DIR: &str = "remote-agent-tmp";

// --- Traits ---
trait AsyncMessageIO {
    async fn read_message(&mut self) -> Result<Vec<u8>>;
    async fn write_message(&mut self, data: &[u8]) -> Result<()>;
}

impl AsyncMessageIO for tokio::io::Stdin {
    async fn read_message(&mut self) -> Result<Vec<u8>> {
        let mut len_buf = [0u8; 4];
        self.read_exact(&mut len_buf).await?;
        let len = u32::from_be_bytes(len_buf) as usize;
        if len > 100 * 1024 * 1024 { return Err(anyhow::anyhow!("Message too large")); }
        let mut buf = vec![0u8; len];
        self.read_exact(&mut buf).await?;
        Ok(buf)
    }
    async fn write_message(&mut self, _d: &[u8]) -> Result<()> { Err(anyhow::anyhow!("Stdin read-only")) }
}

impl AsyncMessageIO for tokio::io::Stdout {
    async fn read_message(&mut self) -> Result<Vec<u8>> { Err(anyhow::anyhow!("Stdout write-only")) }
    async fn write_message(&mut self, data: &[u8]) -> Result<()> {
        let len = (data.len() as u32).to_be_bytes();
        self.write_all(&len).await?;
        self.write_all(data).await?;
        self.flush().await?;
        Ok(())
    }
}

// --- Types ---
#[derive(Deserialize)]
struct RpcRequest { id: u64, method: String, #[serde(default)] params: serde_json::Value }

#[derive(Serialize)]
struct RpcResponse {
    id: u64,
    #[serde(skip_serializing_if="Option::is_none")] result: Option<serde_json::Value>,
    #[serde(skip_serializing_if="Option::is_none")] error: Option<RpcError>
}

#[derive(Serialize)]
struct RpcError {
    code: i32,
    message: String,
    #[serde(skip_serializing_if="Option::is_none")]
    data: Option<serde_json::Value>
}

#[derive(Serialize)]
struct FileStat { #[serde(rename="type")] file_type: &'static str, size: u64, mode: u32, atime: f64, mtime: f64, ctime: f64, symlink_target: Option<String> }

#[tokio::main]
async fn main() -> Result<()> {
    // Setup signals
    setup_signal_handlers().await?;

    let mut stdin = tokio::io::stdin();
    let mut stdout = tokio::io::stdout();

    // Handshake
    let mut handshake = serde_json::json!({
        "protocol_version": PROTOCOL_VERSION,
        "agent_version": env!("CARGO_PKG_VERSION"),
        "pid": std::process::id(),
        "hostname": hostname::get().ok().and_then(|s| s.into_string().ok()).unwrap_or_else(|| "unknown".into())
    });
    if let Ok(token) = std::env::var("RA_AGENT_TOKEN") { handshake["auth_token"] = token.into(); }
    stdout.write_message(&serde_json::to_vec(&handshake)?).await?;

    // Activity Timer
    let last_activity = Arc::new(Mutex::new(Instant::now()));
    let checker = last_activity.clone();

    // Idle-checker
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(30)).await;
            if Instant::now().duration_since(*checker.lock().unwrap()) > Duration::from_secs(AGENT_TIMEOUT) {
                std::process::exit(0);
            }
        }
    });

    // Startup GC
    let _ = cleanup_garbage().await;

    // Main Loop
    loop {
        match stdin.read_message().await {
            Ok(bytes) => {
                *last_activity.lock().unwrap() = Instant::now();
                let act = last_activity.clone();
                if let Err(e) = handle_message(&mut stdout, &bytes, act).await {
                    eprintln!("[AGENT] Error: {}", e);
                }
            }
            Err(_) => break,
        }
    }
    Ok(())
}

async fn handle_message(stdout: &mut tokio::io::Stdout, bytes: &[u8], act: Arc<Mutex<Instant>>) -> Result<()> {
    let req: RpcRequest = serde_json::from_slice(bytes).context("Bad JSON")?;
    let res = match process_command(&req.method, req.params, act).await {
        Ok(r) => RpcResponse { id: req.id, result: Some(r), error: None },
        // 🛠️ FIX 1: Added `data: None` to satisfy struct definition
        Err(e) => RpcResponse {
            id: req.id,
            result: None,
            error: Some(RpcError { code: -32000, message: e.to_string(), data: None })
        },
    };
    stdout.write_message(&serde_json::to_vec(&res)?).await?;
    Ok(())
}

async fn process_command(method: &str, params: serde_json::Value, act: Arc<Mutex<Instant>>) -> Result<serde_json::Value> {
    match method {
        "ping" => Ok(serde_json::json!({"pong": true})),

        "stat" => {
            let path = get_path(&params)?;
            let meta = fs::symlink_metadata(&path)?;
            let ft = meta.file_type();
            let mut stat = FileStat {
                file_type: if ft.is_dir() { "directory" } else if ft.is_symlink() { "symlink" } else { "file" },
                size: if ft.is_file() { meta.len() } else { 0 },
                mode: meta.mode(),
                atime: meta.atime() as f64,
                mtime: meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs_f64()).unwrap_or(0.0),
                ctime: meta.ctime() as f64,
                symlink_target: None,
            };
            if ft.is_symlink() { stat.symlink_target = fs::read_link(&path).ok().map(|p| p.to_string_lossy().into()); }
            Ok(serde_json::to_value(stat)?)
        },

        "read_chunk" => {
            *act.lock().unwrap() = Instant::now();
            let path = get_path(&params)?;
            let offset = params["offset"].as_u64().unwrap_or(0);
            let len = params["length"].as_u64().unwrap_or(MAX_CHUNK_SIZE as u64).min(MAX_CHUNK_SIZE as u64);

            let mut file = fs::File::open(&path)?;
            use std::io::{Seek, Read};
            file.seek(std::io::SeekFrom::Start(offset))?;
            let mut buf = vec![0u8; len as usize];
            let n = file.read(&mut buf)?;
            buf.truncate(n);
            use base64::{engine::general_purpose::STANDARD, Engine as _};
            Ok(serde_json::json!({ "data": STANDARD.encode(&buf), "bytes_read": n }))
        },

        "write_chunk" => {
            *act.lock().unwrap() = Instant::now();
            let path = get_path(&params)?;
            let offset = params["offset"].as_u64().unwrap_or(0);
            let data = base64::engine::general_purpose::STANDARD.decode(params["data"].as_str().context("No data")?)?;

            let cache_dir = dirs::cache_dir().unwrap_or_else(|| PathBuf::from("/tmp")).join(TMP_DIR);
            fs::create_dir_all(&cache_dir).ok();

            let safe_name = path.file_name().unwrap_or_default().to_string_lossy();
            let temp_name = format!(".{}.ra_partial", safe_name);
            let temp_path = cache_dir.join(temp_name);

            let write_res = (|| -> Result<usize> {
                let mut opts = fs::OpenOptions::new();
                opts.write(true).create(true);
                if offset == 0 { opts.truncate(true); }

                let mut file = opts.open(&temp_path)?;
                use std::io::{Seek, Write};
                file.seek(std::io::SeekFrom::Start(offset))?;
                file.write_all(&data)?;
                file.sync_all()?;
                Ok(data.len())
            })();

            match write_res {
                Ok(n) => {
                    if params["final"].as_bool().unwrap_or(false) {
                        fs::rename(&temp_path, &path)?;
                    }
                    Ok(serde_json::json!({ "bytes_written": n }))
                },
                Err(e) => {
                    let _ = fs::remove_file(&temp_path);
                    // 🛠️ FIX 2: Return `e` directly instead of wrapping it
                    Err(e)
                }
            }
        },

        "list_dir" => {
            let path = get_path(&params)?;
            let entries: Vec<serde_json::Value> = fs::read_dir(&path)?
                .filter_map(|e| e.ok())
                .map(|e| {
                    let m = e.metadata().ok();
                    let t = if let Some(ref m) = m { if m.is_dir() { "directory" } else if m.file_type().is_symlink() { "symlink" } else { "file" } } else { "unknown" };
                    serde_json::json!({ "name": e.file_name().to_string_lossy(), "type": t })
                }).collect();
            Ok(serde_json::json!(entries))
        },

        "mkdir" => {
            let path = get_path(&params)?;
            if params["recursive"].as_bool().unwrap_or(false) { fs::create_dir_all(&path)?; } else { fs::create_dir(&path)?; }
            Ok(serde_json::json!(true))
        },
        "delete" => {
            let path = get_path(&params)?;
            if fs::metadata(&path)?.is_dir() { fs::remove_dir_all(&path)?; } else { fs::remove_file(&path)?; }
            Ok(serde_json::json!(true))
        },
        "rename" => {
            let src = get_path(&params)?;
            let dst = Path::new(params["new_path"].as_str().context("No new_path")?);
            fs::rename(src, dst)?;
            Ok(serde_json::json!(true))
        },
        "hpc_info" => {
            let mut info = serde_json::Map::new();
            if std::env::var("SLURM_JOB_ID").is_ok() {
                info.insert("scheduler".into(), "slurm".into());
                if let Ok(n) = std::env::var("SLURMD_NODENAME") { info.insert("node".into(), n.into()); }
            } else if std::env::var("PBS_JOBID").is_ok() {
                info.insert("scheduler".into(), "pbs".into());
            } else {
                info.insert("scheduler".into(), "none".into());
            }
            if let Ok(cwd) = std::env::current_dir() {
                if cwd.starts_with("/gpfs") { info.insert("filesystem".into(), "gpfs".into()); }
                else if cwd.starts_with("/scratch") { info.insert("filesystem".into(), "lustre".into()); }
            }
            Ok(serde_json::Value::Object(info))
        },
        _ => Err(anyhow::anyhow!("Unknown method")),
    }
}

fn get_path(p: &serde_json::Value) -> Result<PathBuf> {
    let s = p["path"].as_str().context("No path")?;
    let path = Path::new(s);
    if path.starts_with("/dev") || path.starts_with("/proc") || path.starts_with("/sys") { return Err(anyhow::anyhow!("Denied")); }
    if path.exists() && !path.is_symlink() { Ok(path.canonicalize().unwrap_or(path.to_path_buf())) } else { Ok(path.to_path_buf()) }
}

async fn setup_signal_handlers() -> Result<()> {
    use tokio::signal::unix::{signal, SignalKind};
    let mut term = signal(SignalKind::terminate())?;
    let mut hup = signal(SignalKind::hangup())?;
    let mut int = signal(SignalKind::interrupt())?;

    tokio::spawn(async move {
        tokio::select! {
            _ = term.recv() => {},
            _ = hup.recv() => {},
            _ = int.recv() => {},
        }
        std::process::exit(0);
    });
    Ok(())
}

async fn cleanup_garbage() -> Result<()> {
    use dirs::cache_dir;
    let cache_dir = cache_dir().unwrap_or_else(|| PathBuf::from("/tmp")).join(TMP_DIR);
    if let Ok(entries) = fs::read_dir(&cache_dir) {
        for e in entries.flatten() {
            let p = e.path();
            if p.extension().map_or(false, |x| x == "ra_partial") {
                if let Ok(m) = fs::metadata(&p) {
                    if let Ok(t) = m.modified() {
                        if SystemTime::now().duration_since(t).unwrap_or_default() > Duration::from_secs(3600) {
                            let _ = fs::remove_file(p);
                        }
                    }
                }
            }
        }
    }
    Ok(())
}
