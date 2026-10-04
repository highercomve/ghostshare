//! C ABI between Oriel/Zig and the Quick Share protocol engine.
use rqs_lib::{
    channel::{ChannelAction, ChannelDirection, ChannelMessage, TransferType},
    EndpointInfo, OutboundPayload, SendInfo, State, Visibility, RQS,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    ffi::{CStr, CString},
    os::raw::c_char,
    path::PathBuf,
    sync::{mpsc as sync_channel, Mutex, OnceLock},
    thread,
    time::Duration,
};
use tokio::sync::{broadcast, mpsc};

type EventCallback = unsafe extern "C" fn(*const c_char);
static EVENT_CALLBACK: Mutex<Option<EventCallback>> = Mutex::new(None);
#[no_mangle]
pub extern "C" fn ghostfile_set_event_callback(callback: Option<EventCallback>) {
    if let Ok(mut current) = EVENT_CALLBACK.lock() { *current = callback; }
}
fn notify_transfer(event: &ChannelMessage) {
    if event.rtype != Some(TransferType::Inbound) { return; }
    let kind = match event.state {
        Some(State::WaitingForUserConsent) => "request",
        Some(State::Finished) => "finished",
        Some(State::Rejected | State::Cancelled | State::Disconnected) => "dismiss",
        _ => return,
    };
    let name = event.meta.as_ref().and_then(|m| m.source.as_ref()).map(|s| s.name.as_str()).unwrap_or("Nearby device");
    let value = CString::new(json!({"id":event.id,"kind":kind,"name":name}).to_string()).unwrap();
    if let Ok(callback) = EVENT_CALLBACK.lock() {
        if let Some(callback) = *callback { unsafe { callback(value.as_ptr()); } }
    }
}
static ENGINE: OnceLock<Mutex<Option<Engine>>> = OnceLock::new();
struct Engine {
    tx: mpsc::Sender<Envelope>,
    thread: thread::JoinHandle<()>,
}
struct Envelope {
    request: Request,
    reply: sync_channel::Sender<Result<Value, String>>,
}
#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum Request {
    Snapshot,
    Visibility {
        visible: bool,
    },
    Send {
        address: String,
        name: String,
        paths: Vec<String>,
    },
    Decide {
        id: String,
        accept: bool,
        directory: Option<String>,
    },
    Cancel {
        id: String,
    },
    ResolvePath { id: String, index: usize, folder: bool },
    Stop,
}
struct Model {
    name: String,
    download_dir: PathBuf,
    visible: bool,
    peers: BTreeMap<String, EndpointInfo>,
    transfers: Vec<ChannelMessage>,
    error: Option<String>,
}
impl Model {
    fn snapshot(&self) -> Value {
        json!({"name":self.name, "download_dir":self.download_dir, "visible":self.visible,
            "peers":self.peers.values().collect::<Vec<_>>(), "transfers":self.transfers,
            "error":self.error, "protocol":"Quick Share"})
    }
    fn transfer_event(&mut self, mut event: ChannelMessage) {
        if event.direction != ChannelDirection::LibToFront {
            return;
        }
        let old_state = self.transfers.iter().find(|t| t.id == event.id).and_then(|t| t.state.clone());
        if old_state != event.state { notify_transfer(&event); }
        if let Some(index) = self.transfers.iter().position(|t| t.id == event.id) {
            if event.meta.is_none() {
                event.meta = self.transfers[index].meta.clone();
            }
            if event.rtype.is_none() {
                event.rtype = self.transfers[index].rtype.clone();
            }
            self.transfers[index] = event;
        } else {
            if self.transfers.len() >= 64 {
                if let Some(index) = self
                    .transfers
                    .iter()
                    .position(|t| terminal(t.state.as_ref()))
                {
                    self.transfers.remove(index);
                } else {
                    self.error = Some("Too many active transfers".into());
                    return;
                }
            }
            self.transfers.push(event);
        }
    }
}
fn terminal(state: Option<&State>) -> bool {
    matches!(
        state,
        Some(State::Finished | State::Rejected | State::Cancelled | State::Disconnected)
    )
}
fn validate_paths(paths: &[String]) -> Result<Vec<String>, String> {
    if paths.is_empty() || paths.len() > 1024 {
        return Err("Choose between 1 and 1024 files".into());
    }
    paths
        .iter()
        .map(|p| {
            let path = std::fs::canonicalize(p).map_err(|e| e.to_string())?;
            let info = std::fs::metadata(&path).map_err(|e| e.to_string())?;
            if !info.is_file() {
                return Err("Only regular files can be sent".into());
            }
            if info.len() > (1 << 40) {
                return Err("File exceeds the 1 TB limit".into());
            }
            path.to_str()
                .map(str::to_owned)
                .ok_or_else(|| "Filename is not UTF-8".into())
        })
        .collect()
}
fn control_message(id: String, action: ChannelAction) -> ChannelMessage {
    ChannelMessage {
        id,
        direction: ChannelDirection::FrontToLib,
        action: Some(action),
        ..Default::default()
    }
}
async fn handle(
    request: Request,
    model: &mut Model,
    rqs: &mut RQS,
    sender: &mpsc::Sender<SendInfo>,
) -> Result<Value, String> {
    match request {
        Request::Snapshot => return Ok(model.snapshot()),
        Request::Visibility { visible } => {
            rqs.change_visibility(if visible {
                Visibility::Visible
            } else {
                Visibility::Invisible
            });
            model.visible = visible;
        }
        Request::Send {
            address,
            name,
            paths,
        } => {
            let address: std::net::SocketAddr = address
                .parse()
                .map_err(|_| "Use an IP address and port".to_string())?;
            if address.port() == 0 || address.ip().is_unspecified() || address.ip().is_multicast() {
                return Err("Invalid destination".into());
            }
            let paths = validate_paths(&paths)?;
            let id = format!(
                "{}-{}",
                address,
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            );
            sender
                .try_send(SendInfo {
                    id,
                    name,
                    addr: address.to_string(),
                    ob: OutboundPayload::Files(paths),
                })
                .map_err(|e| e.to_string())?;
        }
        Request::Decide { id, accept, directory } => {
            let transfer = model
                .transfers
                .iter()
                .find(|t| t.id == id)
                .ok_or("Request expired")?;
            if transfer.rtype != Some(TransferType::Inbound)
                || transfer.state != Some(State::WaitingForUserConsent)
            {
                return Err("Request is no longer waiting for approval".into());
            }
            let directory = if accept {
                directory.map(|dir| -> Result<String, String> {
                    let path = std::fs::canonicalize(dir).map_err(|e| e.to_string())?;
                    if !path.is_dir() { return Err("Save location must be a directory".into()); }
                    Ok(path.to_string_lossy().into_owned())
                }).transpose()?
            } else { None };
            let mut message = control_message(id, if accept { ChannelAction::AcceptTransfer } else { ChannelAction::RejectTransfer });
            message.save_directory = directory;
            rqs.message_sender.send(message).map_err(|e| e.to_string())?;
        }
        Request::ResolvePath { id, index, folder } => {
            let transfer = model.transfers.iter().find(|t| t.id == id).ok_or("Transfer not found")?;
            if transfer.state != Some(State::Finished) { return Err("Transfer has not completed".into()); }
            let meta = transfer.meta.as_ref().ok_or("File metadata unavailable")?;
            let paths = if transfer.rtype == Some(TransferType::Inbound) { &meta.saved_files } else { &meta.files };
            let path = PathBuf::from(paths.as_ref().and_then(|p| p.get(index)).ok_or("File not found")?);
            let path = if folder { path.parent().ok_or("Folder unavailable")?.to_path_buf() } else { path };
            return Ok(json!(std::fs::canonicalize(path).map_err(|e| e.to_string())?));
        }
        Request::Cancel { id } => {
            let transfer = model
                .transfers
                .iter()
                .find(|t| t.id == id)
                .ok_or("Transfer not found")?;
            if terminal(transfer.state.as_ref()) {
                return Err("Transfer already ended".into());
            }
            rqs.message_sender
                .send(control_message(id, ChannelAction::CancelTransfer))
                .map_err(|e| e.to_string())?;
        }
        Request::Stop => unreachable!(),
    }
    Ok(json!(true))
}
async fn run(
    mut requests: mpsc::Receiver<Envelope>,
    ready: sync_channel::Sender<Result<(), String>>,
    directory: PathBuf,
) {
    let mut model = Model {
        name: hostname::get()
            .unwrap_or_default()
            .to_string_lossy()
            .into_owned(),
        download_dir: directory.clone(),
        visible: true,
        peers: BTreeMap::new(),
        transfers: vec![],
        error: None,
    };
    let port = std::env::var("GHOSTFILE_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .map(u32::from);
    let mut rqs = RQS::new(Visibility::Visible, port, Some(directory));
    let mut transfers = rqs.message_sender.subscribe();
    let (peers_tx, mut peers) = broadcast::channel(64);
    let sender = match rqs.run().await {
        Ok((sender, _)) => sender,
        Err(e) => {
            let _ = ready.send(Err(e.to_string()));
            return;
        }
    };
    if let Err(e) = rqs.discovery(peers_tx) {
        let _ = ready.send(Err(e.to_string()));
        let _ = tokio::time::timeout(Duration::from_secs(3), rqs.stop()).await;
        return;
    }
    let _ = ready.send(Ok(()));
    loop {
        tokio::select! {
            envelope = requests.recv() => {
                let Some(envelope) = envelope else { break; };
                if matches!(envelope.request, Request::Stop) {
                    let _ = envelope.reply.send(Ok(json!(true)));
                    break;
                }
                let result = handle(envelope.request, &mut model, &mut rqs, &sender).await;
                let _ = envelope.reply.send(result);
            }
            event = peers.recv() => match event {
                Ok(peer) if peer.present == Some(true) => {
                    if model.peers.len() < 128 || model.peers.contains_key(&peer.id) {
                        model.peers.insert(peer.id.clone(), peer);
                    }
                }
                Ok(peer) => { model.peers.remove(&peer.id); }
                Err(broadcast::error::RecvError::Lagged(_)) => { model.error = Some("Discovery updates were delayed".into()); }
                Err(broadcast::error::RecvError::Closed) => break,
            },
            event = transfers.recv() => match event {
                Ok(event) => model.transfer_event(event),
                Err(broadcast::error::RecvError::Lagged(_)) => { model.error = Some("Transfer updates were delayed".into()); }
                Err(broadcast::error::RecvError::Closed) => break,
            },
        }
    }
    let _ = tokio::time::timeout(Duration::from_secs(3), rqs.stop()).await;
}
fn encode(result: Result<Value, String>) -> *mut c_char {
    let value = match result {
        Ok(data) => json!({"ok":true,"data":data}),
        Err(error) => json!({"ok":false,"error":error}),
    };
    CString::new(value.to_string())
        .expect("JSON has no literal NUL")
        .into_raw()
}
fn guarded(f: impl FnOnce() -> Result<Value, String>) -> *mut c_char {
    encode(
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(f))
            .unwrap_or_else(|_| Err("Quick Share engine panicked".into())),
    )
}
/// Input must be a valid NUL-terminated UTF-8 string owned by the caller.
#[no_mangle]
pub unsafe extern "C" fn ghostfile_start(directory: *const c_char) -> *mut c_char {
    guarded(|| {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(
                tracing_subscriber::EnvFilter::try_from_default_env()
                    .unwrap_or_else(|_| "warn".into()),
            )
            .with_writer(std::io::stderr)
            .try_init();
        if directory.is_null() {
            return Err("Missing downloads directory".into());
        }
        let text = CStr::from_ptr(directory)
            .to_str()
            .map_err(|e| e.to_string())?;
        let directory = if text.is_empty() {
            let dirs = directories::UserDirs::new().ok_or("Could not locate home directory")?;
            dirs.download_dir()
                .unwrap_or(dirs.home_dir())
                .join("GhostFile")
        } else {
            PathBuf::from(text)
        };
        std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        let directory = std::fs::canonicalize(directory).map_err(|e| e.to_string())?;
        let mut engine = ENGINE
            .get_or_init(|| Mutex::new(None))
            .lock()
            .map_err(|e| e.to_string())?;
        if engine.is_some() {
            return Err("Engine already running".into());
        }
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        let (tx, rx) = mpsc::channel(32);
        let (ready_tx, ready_rx) = sync_channel::channel();
        let thread = thread::Builder::new()
            .name("ghostfile-quickshare".into())
            .spawn(move || {
                runtime.block_on(run(rx, ready_tx, directory));
                runtime.shutdown_timeout(Duration::from_secs(1));
            })
            .map_err(|e| e.to_string())?;
        match ready_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(())) => {
                *engine = Some(Engine { tx, thread });
                Ok(json!(true))
            }
            Ok(Err(e)) => {
                drop(tx);
                let _ = thread.join();
                Err(e)
            }
            Err(e) => {
                drop(tx);
                let _ = thread.join();
                Err(e.to_string())
            }
        }
    })
}
#[no_mangle]
pub unsafe extern "C" fn ghostfile_request(request: *const c_char) -> *mut c_char {
    guarded(|| {
        if request.is_null() {
            return Err("Missing request".into());
        }
        let request: Request = serde_json::from_slice(CStr::from_ptr(request).to_bytes())
            .map_err(|e| e.to_string())?;
        if matches!(request, Request::Stop) {
            return Err("Use ghostfile_stop".into());
        }
        let engine = ENGINE
            .get_or_init(|| Mutex::new(None))
            .lock()
            .map_err(|e| e.to_string())?;
        let engine = engine.as_ref().ok_or("Quick Share engine is not running")?;
        let (tx, rx) = sync_channel::channel();
        engine
            .tx
            .try_send(Envelope { request, reply: tx })
            .map_err(|e| e.to_string())?;
        rx.recv_timeout(Duration::from_secs(5))
            .map_err(|e| e.to_string())?
    })
}
#[no_mangle]
pub extern "C" fn ghostfile_stop() {
    let Some(lock) = ENGINE.get() else {
        return;
    };
    let Ok(mut guard) = lock.lock() else {
        return;
    };
    if let Some(engine) = guard.take() {
        let (tx, _) = sync_channel::channel();
        let _ = engine.tx.try_send(Envelope {
            request: Request::Stop,
            reply: tx,
        });
        drop(engine.tx);
        let _ = engine.thread.join();
    }
}
/// Free exactly once a non-null pointer returned by start/request.
#[no_mangle]
pub unsafe extern "C" fn ghostfile_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(CString::from_raw(pointer));
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_non_files_and_empty_batches() {
        assert!(validate_paths(&[]).is_err());
        assert!(validate_paths(&["/a/nonexistent/ghostfile".into()]).is_err());
        assert!(validate_paths(&[std::env::temp_dir().to_string_lossy().into_owned()]).is_err());
    }
    #[test]
    fn preserves_pin_and_metadata_when_state_only_event_arrives() {
        let mut model = Model {
            name: "test".into(),
            download_dir: PathBuf::new(),
            visible: true,
            peers: BTreeMap::new(),
            transfers: vec![],
            error: None,
        };
        let mut event: ChannelMessage = serde_json::from_value(json!({"id":"1", "direction":"LibToFront",
            "rtype":"Inbound", "state":"WaitingForUserConsent", "meta":{"id":"1", "pin_code":"1234", "total_bytes":5,"ack_bytes":0}})).unwrap();
        model.transfer_event(event.clone());
        event.state = Some(State::Finished);
        event.meta = None;
        event.rtype = None;
        model.transfer_event(event);
        assert_eq!(
            model.transfers[0]
                .meta
                .as_ref()
                .unwrap()
                .pin_code
                .as_deref(),
            Some("1234")
        );
        assert_eq!(model.transfers[0].rtype, Some(TransferType::Inbound));
    }
}
