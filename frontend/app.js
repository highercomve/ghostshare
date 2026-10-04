const $ = id => document.getElementById(id);
let files = [], model = null, sending = false, polling = false;
const terminal = new Set(["Finished", "Rejected", "Cancelled", "Disconnected"]);
const states = { Initial:"Connecting", ReceivedConnectionRequest:"Connecting", SentIntroduction:"Waiting for receiver",
  WaitingForUserConsent:"Waiting for approval", ReceivingFiles:"Receiving", SendingFiles:"Sending", Finished:"Complete",
  Rejected:"Declined", Cancelled:"Cancelled", Disconnected:"Disconnected" };
function bytes(value) {
  if (value < 1024) return value + " B";
  const units = ["KB", "MB", "GB", "TB"];
  let i = -1;
  do { value /= 1024; i++; } while (value >= 1024 && i < units.length - 1);
  return value.toFixed(value < 10 ? 1 : 0) + " " + units[i];
}
function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function clear(node) { node.innerHTML = ""; }
function error(message) { $("error").textContent = String(message); $("error").hidden = false; }
async function call(command, args) {
  if (!window.oriel) throw new Error("Open GhostFile as a desktop app to share files.");
  const response = await window.oriel.invoke(command, args || null);
  if (typeof response !== "string") return response;
  const result = JSON.parse(response);
  if (!result.ok) throw new Error(result.error);
  return result.data;
}
function button(text, className, action) {
  const node = element("button", className, text);
  node.addEventListener("click", action);
  return node;
}
function render_files() {
  clear($("file-list"));
  $("file-empty").hidden = files.length > 0;
  $("clear").hidden = files.length === 0;
  $("choose").textContent = files.length ? "Add another file ＋" : "Choose files ＋";
  for (const file of files) {
    const row = element("div", "file-row");
    const detail = element("div", "file-detail");
    detail.appendChild(element("div", "file-name", file.name));
    detail.appendChild(element("div", "small", bytes(file.size)));
    row.appendChild(detail);
    const remove = button("Remove", "text-button", () => { files = files.filter(f => f.path !== file.path); render_files(); render_peers(); });
    remove.disabled = sending;
    row.appendChild(remove);
    $("file-list").appendChild(row);
  }
  $("manual-send").disabled = !files.length || sending || !$("address").value.trim();
}
function render_peers() {
  const peers = model ? model.peers : [];
  clear($("peers"));
  $("peer-empty").hidden = peers.length > 0;
  $("peer-count").textContent = String(peers.length);
  for (const peer of peers) {
    const row = element("div", "peer-row");
    row.appendChild(element("div", "device-icon", peer.rtype === "Phone" ? "▯" : "▱"));
    const detail = element("div", "peer-detail");
    detail.appendChild(element("div", "peer-name", peer.name || "Nearby device"));
    detail.appendChild(element("div", "small", (peer.rtype || "Device") + " · " + peer.id));
    row.appendChild(detail);
    const sendButton = button("Send ↗", "", () => send(peer.id, peer.name || "Nearby device"));
    sendButton.disabled = !files.length || sending;
    row.appendChild(sendButton);
    $("peers").appendChild(row);
  }
}
async function send(address, name) {
  if (!files.length || sending) return;
  sending = true; $("choose").disabled = true; $("clear").disabled = true;
  render_files(); render_peers();
  try {
    await call("send_files", { address, name, paths:files.map(f => f.path) });
    files = []; $("error").hidden = true;
  } catch (err) { error(err.message || err); }
  finally { sending = false; $("choose").disabled = false; $("clear").disabled = false; render_files(); render_peers(); await poll(); }
}
async function decision(id, accept, controls, chooseFolder = false) {
  for (const node of controls) node.disabled = true;
  try {
    let directory = null;
    if (chooseFolder) { directory = await call("select_folder"); if (!directory) return; }
    await call("decide", { id, accept, directory }); await poll();
  }
  catch (err) { error(err.message || err); }
  finally { for (const node of controls) node.disabled = false; }
}
function render_transfers() {
  clear($("requests")); clear($("transfers"));
  const transfers = (model.transfers || []).slice().reverse();
  if (!transfers.length) $("transfers").appendChild(element("p", "activity-empty", "Your files’ next adventure starts here."));
  for (const transfer of transfers) {
    const meta = transfer.meta || {};
    const incoming = transfer.rtype === "Inbound";
    const peer = meta.source ? meta.source.name : "Nearby device";
    const names = (meta.files || []).map(name => name.split(/[\\/]/).pop()).join(", ") || meta.text_description || "Preparing transfer";
    if (incoming && transfer.state === "WaitingForUserConsent") {
      const request = element("div", "request");
      request.appendChild(element("h3", "", peer + " wants to share"));
      request.appendChild(element("div", "", names + " · " + bytes(meta.total_bytes || 0)));
      request.appendChild(element("p", "small", "Confirm that this code matches the other device before accepting."));
      request.appendChild(element("div", "pin", meta.pin_code || "—"));
      const actions = element("div", "request-actions");
      const controls = [];
      request.appendChild(element("div", "small", "Default folder · " + model.download_dir));
      controls.push(button("Accept to default", "primary", () => decision(transfer.id, true, controls)));
      controls.push(button("Choose folder…", "secondary", () => decision(transfer.id, true, controls, true)));
      controls.push(button("Decline", "secondary", () => decision(transfer.id, false, controls)));
      for (const control of controls) actions.appendChild(control);
      request.appendChild(actions); $("requests").appendChild(request);
    }
    const row = element("div", "transfer-row");
    const detail = element("div", "transfer-detail");
    detail.appendChild(element("div", "transfer-name", names));
    detail.appendChild(element("div", "small", (incoming ? "From " + peer : "Sending") + " · " + bytes(meta.total_bytes || 0)));
    if (!terminal.has(transfer.state)) {
      const progress = element("div", "progress");
      const fill = element("div", "progress-fill");
      fill.style.width = Math.min(100, meta.total_bytes ? (meta.ack_bytes || 0) / meta.total_bytes * 100 : 0) + "%";
      progress.appendChild(fill); detail.appendChild(progress);
    }
    if (transfer.state === "Finished" && (incoming ? meta.saved_files : meta.files)) {
      const actions = element("div", "file-actions");
      const paths = (incoming ? meta.saved_files : meta.files) || [];
      paths.forEach((path, index) => actions.appendChild(button(paths.length === 1 ? "Open file" : "Open " + path.split(/[\\/]/).pop(), "secondary", async () => {
        try { await call("open_transfer", {id:transfer.id, index, folder:false}); } catch (err) { error(err.message || err); }
      })));
      if (paths.length) actions.appendChild(button("Open folder", "text-button", async () => {
        try { await call("open_transfer", {id:transfer.id, index:0, folder:true}); } catch (err) { error(err.message || err); }
      }));
      detail.appendChild(actions);
      if (incoming && meta.destination) detail.appendChild(element("div", "small", "Saved in " + meta.destination));
    }
    row.appendChild(detail);
    const status = element("div", "transfer-status");
    status.appendChild(element("div", "", states[transfer.state] || "Connecting securely"));
    if (meta.pin_code && !incoming && !terminal.has(transfer.state)) status.appendChild(element("div", "small", "Code " + meta.pin_code));
    if (!terminal.has(transfer.state)) status.appendChild(button("Cancel", "text-button", async () => {
      try { await call("cancel", { id:transfer.id }); await poll(); } catch(err) { error(err.message || err); }
    }));
    row.appendChild(status); $("transfers").appendChild(row);
  }
}
let previous_peers = "", previous_transfers = "";
async function poll() {
  if (polling) return;
  polling = true;
  try {
    model = await call("snapshot");
    $("visibility").textContent = model.visible ? "● Visible to nearby devices" : "○ Hidden from nearby devices";
    $("visibility").className = "presence" + (model.visible ? "" : " off");
    $("identity").textContent = "This computer · " + model.name;
    $("downloads").textContent = "Save to " + model.download_dir;
    if (model.error) error(model.error);
    const peers = JSON.stringify(model.peers), transfers = JSON.stringify(model.transfers);
    if (peers !== previous_peers) { previous_peers = peers; render_peers(); }
    if (transfers !== previous_transfers) { previous_transfers = transfers; render_transfers(); }
  } catch (err) { error(err.message || err); $("visibility").textContent = "Quick Share unavailable"; }
  finally { polling = false; }
}
async function choose_files() {
  $("choose").disabled = true;
  try {
    const file = await call("select_file");
    if (file && !files.some(f => f.path === file.path)) files.push(file);
    render_files(); render_peers();
  } catch (err) { error(err.message || err); }
  finally { $("choose").disabled = false; }
}
$("choose").addEventListener("click", choose_files);
$("clear").addEventListener("click", () => { files = []; render_files(); render_peers(); });
$("address").addEventListener("input", () => { $("manual-send").disabled = !files.length || sending || !$("address").value.trim(); });
$("manual-send").addEventListener("click", () => send($("address").value.trim(), "Nearby device"));
$("visibility").addEventListener("click", async () => {
  if (!model) return;
  $("visibility").disabled = true;
  try { await call("visibility", { visible:!model.visible }); await poll(); }
  catch (err) { error(err.message || err); }
  finally { $("visibility").disabled = false; }
});
render_files(); poll(); setInterval(poll, 800);

function set_theme(dark) { document.documentElement.setAttribute("data-theme", dark ? "dark" : "light"); }
if (window.oriel) {
  call("system_info").then(info => typeof info.dark === "boolean" && set_theme(info.dark)).catch(err => error(err.message || err));
  window.oriel.listen("system_theme", info => typeof info.dark === "boolean" && set_theme(info.dark));
  window.oriel.listen("tray_send", () => choose_files());
  window.oriel.listen("tray_visibility", () => poll());
  window.oriel.listen("review_request", () => poll());
}
$("quit").addEventListener("click", () => call("quit"));

let update_busy = false, update_android = false, update_version = "";
async function check_updates() {
  if (update_busy) return;
  update_busy = true; $("update-check").disabled = true;
  $("update-status").textContent = "Checking for updates…";
  try {
    const info = await call("update_info"); update_android = info.android; update_version = info.version;
    const update = await call("updater_check");
    $("update-status").textContent = update.available ? "GhostFile " + update.version + " is available" : "GhostFile " + update_version + " · Up to date";
    $("update-install").hidden = !update.available;
    $("update-install").textContent = update_android ? "Download APK" : "Install update";
  } catch (err) { $("update-status").textContent = "Updates unavailable · Try again later"; }
  finally { update_busy = false; $("update-check").disabled = false; }
}
function active_transfers() { return model && (model.transfers || []).some(t => !terminal.has(t.state)); }
$("update-check").addEventListener("click", check_updates);
$("update-install").addEventListener("click", async () => {
  if (update_busy) return;
  if (update_android) { await window.oriel.openExternal("https://github.com/highercomve/ghostfile/releases/latest"); return; }
  if (active_transfers()) { $("update-status").textContent = "Finish or cancel your transfers before updating"; return; }
  update_busy = true; $("update-install").disabled = true; $("update-check").disabled = true;
  try {
    $("update-status").textContent = "Downloading and verifying update…";
    await call("updater_install");
    $("update-status").textContent = "Update installed · Restart when your transfers are finished";
    $("update-install").hidden = true; $("update-restart").hidden = false;
    $("update-check").hidden = true;
  } catch (err) { $("update-status").textContent = "Update failed: " + (err.message || err); }
  finally { update_busy = false; $("update-install").disabled = false; $("update-check").disabled = false; }
});
$("update-restart").addEventListener("click", async () => {
  if (active_transfers()) { $("update-status").textContent = "Finish or cancel your transfers before restarting"; return; }
  try { await call("updater_restart"); } catch (err) { $("update-status").textContent = String(err.message || err); }
});
if (window.oriel) {
  window.oriel.listen("tray_update", check_updates);
  window.oriel.listen("updater://progress", progress => {
    $("update-status").textContent = "Downloading update · " + (progress.total ? Math.round(progress.downloaded / progress.total * 100) + "%" : bytes(progress.downloaded));
  });
  setTimeout(check_updates, 1500);
  setInterval(() => { if ($("update-restart").hidden) check_updates(); }, 6 * 60 * 60 * 1000);
}
