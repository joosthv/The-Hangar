// Jetstream Hangar UI: talks to the local server (same origin) at /api/*.
const $ = (s, el) => (el || document).querySelector(s);
const api = (path, opts) => fetch("/api/" + path, opts).then(r => r.json().then(j => ({ ok: r.ok, status: r.status, j })));
const post = (path, body) => api(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
let job = { state: "idle" }, polling = null, items = [];

document.querySelectorAll(".tab").forEach(t => t.onclick = () => {
    document.querySelectorAll(".tab").forEach(x => x.classList.toggle("active", x === t));
    document.querySelectorAll(".view").forEach(v => v.classList.toggle("hidden", v.id !== t.dataset.view));
    if (t.dataset.view === "settings") loadSettings();
    if (t.dataset.view === "scenery" && !scan) loadScan(false);
});

function notice(text, err) {
    const n = $("#notice");
    n.textContent = text || ""; n.classList.toggle("hidden", !text); n.classList.toggle("err", !!err);
}

async function loadStatus() {
    let j;
    try { j = (await api("status")).j; } catch (e) { $("#chips").innerHTML = `<span class="chip warn">Hangar not answering - restarting?</span>`; return; }
    $("#ver").textContent = "v" + j.version;
    const chips = [];
    chips.push(j.communityOk ? ["ok", "Community folder"] : ["bad", "Community folder not found"]);
    chips.push(j.simRunning ? ["warn", "MSFS running"] : ["ok", "MSFS closed"]);
    chips.push(j.navigraph ? ["ok", "EFB backend ready"] : ["warn", "Navigraph unavailable"]);
    if (j.waiting && j.waiting.length) chips.push(["warn", "Waiting for MSFS to close: " + j.waiting.join(", ")]);
    else if (j.autoUpdate) chips.push(["ok", "Auto-update on"]);
    const su = j.selfUpdate || {};
    if (su.state === "current") chips.push(["ok", "Hangar up to date"]);
    else if (su.state === "available") chips.push(["warn link", "Hangar " + su.latest + " available - update", "selfupdate"]);
    else if (su.state === "updating") chips.push(["warn", "Updating hangar to " + su.latest + " - restarting"]);
    else if (su.state === "error") chips.push(["bad", su.message]);
    else chips.push(["", "Hangar " + j.version]);
    $(".brand").title = "Version " + j.version + (su.checked ? " - checked " + su.checked : "");
    $("#chips").innerHTML = chips.map(c => `<span class="chip ${c[0]}"${c[2] ? ` data-act="${c[2]}"` : ""}>${esc(c[1])}</span>`).join("");
    const act = document.querySelector("[data-act=selfupdate]");
    if (act) act.onclick = async () => { await post("self-update"); notice("Updating Jetstream Hangar - it restarts in a few seconds."); setTimeout(loadStatus, 4000); };
    if (!j.catalogUrl) notice("No catalogue URL set - using the local catalog.json. Set the GitHub catalogue under Settings.");
    return j;
}

async function loadLibrary(refresh) {
    $("#refresh").disabled = true;
    try {
        const { ok, j } = await api("catalog" + (refresh ? "?refresh=1" : ""));
        if (!ok) { notice("Could not load the catalogue: " + (j.error || "error"), true); return; }
        items = j; render();
        if (!j.length) notice("The catalogue lists no aircraft yet.");
        else { const s = (await api("status")).j; notice(s.githubNotice || ""); }
    } catch (e) { notice("Could not reach the hangar service: " + e, true); }
    finally { $("#refresh").disabled = false; }
}

function techHtml(st) {
    if (!st) return "";
    const lvl = (v, c, w, rev) => rev ? (v <= w ? "b" : v <= c ? "w" : "") : (v >= w ? "b" : v >= c ? "w" : "");
    const due = (h, lim) => { const r = lim - h; return [r > 0 ? r.toFixed(1) + " h left" : "overdue " + (-r).toFixed(1) + " h", r <= 0 ? "b" : r <= 10 ? "w" : ""]; };
    const issues = [];
    if (st.since100 > 100) issues.push("100 h inspection overdue");
    if (st.oil < 2.5) issues.push("oil below minimum");
    ["n", "l", "r"].forEach(k => { if (st.tyres && st.tyres[k] < 1.6) issues.push({ n: "nose", l: "left", r: "right" }[k] + " tyre soft"); });
    if (st.damage > 0.05) issues.push("engine damage");
    (st.defects || []).forEach(d => issues.push(d));
    const rows = [
        ["Airframe time", (+st.ttaf).toFixed(1) + " h", ""],
        ["100 h inspection", ...due(st.since100, 100)],
        ["Oil change", ...due(st.sinceOil, st.avgas > 0.5 ? 50 : 100)],
        ["Spark plugs", ...due(st.sincePlugs, 100)],
        ["Oil quantity", (+st.oil).toFixed(2) + " l", lvl(st.oil, 2.6, 2.0, true)],
        ["Coolant", (+st.coolant).toFixed(2) + " l", lvl(st.coolant, 1.85, 1.6, true)],
        ["Tyres N / L / R", st.tyres ? [st.tyres.n, st.tyres.l, st.tyres.r].map(x => (+x).toFixed(1)).join(" / ") + " bar" : "-", st.tyres && Math.min(st.tyres.n, st.tyres.l, st.tyres.r) < 1.6 ? "b" : ""],
        ["Brake pads L / R", st.pads ? (+st.pads.l).toFixed(1) + " / " + (+st.pads.r).toFixed(1) + " mm" : "-", st.pads && Math.min(st.pads.l, st.pads.r) < 2 ? "b" : ""],
        ["Battery", Math.round(st.battery) + " %", lvl(st.battery, 60, 25, true)],
    ];
    const seen = st._seen ? new Date(st._seen).toLocaleString() : "";
    return `<div class="tech-head"><div><div class="eyebrow">Technical state</div>${seen ? `<div class="muted small">Synced from the EFB ${esc(seen)}</div>` : ""}</div>
        <div class="aw ${issues.length ? "bad" : "ok"}">${issues.length ? "Not airworthy: " + esc(issues.join(", ")) : "Airworthy"}</div></div>
        <div class="grid">${rows.map(r => `<div><span>${esc(r[0])}</span><span class="${r[2]}">${esc(r[1])}</span></div>`).join("")}</div>
        <div class="log">${(st.log || []).slice(0, 12).map(e => esc(e.t + "  " + e.h + " h  " + e.text)).join("<br>")}</div>`;
}

// release notes are a CHANGELOG.md section: "### Heading", "- item" (continued on indented lines), **bold**
function notesHtml(md) {
    const inline = s => esc(s).replace(/\*\*(.+?)\*\*/g, "<b>$1</b>").replace(/`([^`]+)`/g, "<code>$1</code>");
    let html = "", list = null;
    const flush = () => { if (list) { html += "<ul>" + list.map(li => `<li>${inline(li)}</li>`).join("") + "</ul>"; list = null; } };
    for (const raw of String(md).replace(/\r/g, "").split("\n")) {
        const line = raw.trimEnd();
        if (!line.trim()) { flush(); continue; }
        let m;
        if ((m = line.match(/^#{2,4}\s+(.*)/))) { flush(); html += `<h4>${inline(m[1])}</h4>`; }
        else if ((m = line.match(/^\s*[-*]\s+(.*)/))) { (list = list || []).push(m[1]); }
        else if (list && /^\s+/.test(raw)) { list[list.length - 1] += " " + line.trim(); }
        else { flush(); html += `<p>${inline(line)}</p>`; }
    }
    flush();
    return html;
}

function render() {
    const host = $("#cards"); host.innerHTML = "";
    for (const a of items) {
        const el = $("#cardTpl").content.firstElementChild.cloneNode(true);
        el.dataset.id = a.id;
        // the whole picture is shown (contain), never cropped
        const th = $(".thumb", el), img = $("img", th);
        if (a.image) { img.src = a.image; img.alt = a.name; img.onerror = () => { img.remove(); th.classList.add("empty"); }; }
        else { img.remove(); th.classList.add("empty"); }
        $("h2", el).textContent = a.name;
        $(".maker", el).textContent = a.manufacturer || "";
        $(".desc", el).textContent = a.description || "";
        $(".state", el).innerHTML = !a.installed ? `<span class="badge none">Not installed</span>` : a.updateAvailable ? `<span class="badge upd">Update available</span>` : a.latestVersion ? `<span class="badge ok">Up to date</span>` : "";
        const cell = (k, v) => `<div><div class="k">${k}</div><div class="v">${esc(v)}</div></div>`;
        $(".versions", el).innerHTML = cell("Installed", a.installedVersion || "-") + cell("Latest", a.latestVersion || "-") +
            cell("Download", a.release && a.release.size ? (a.release.size / 1048576).toFixed(0) + " MB" : "-") +
            (a.releaseError ? `<div class="err">${esc(a.releaseError)}</div>` : "");
        const b = $(".buttons", el), busy = job.state === "running";
        const btn = (label, cls, fn, dis) => { const x = document.createElement("button"); x.textContent = label; if (cls) x.className = cls; x.disabled = !!dis || busy; x.onclick = fn; b.appendChild(x); };
        if (a.release) {
            if (!a.installed) btn("Install " + a.latestVersion, "", () => install(a));
            else if (a.updateAvailable) btn("Update to " + a.latestVersion, "", () => install(a));
            else btn("Reinstall", "secondary", () => install(a));
        }
        if (a.installed) btn("Uninstall", "danger", () => uninstall(a));
        if (a.release && a.release.notes) { $(".notes", el).classList.remove("hidden"); $(".notes .md", el).innerHTML = notesHtml(a.release.notes); }
        if (a.state) { const t = $(".tech", el); t.classList.remove("hidden"); t.innerHTML = techHtml(a.state); }
        if (job.id === a.id && job.state !== "idle") showJob(el);
        host.appendChild(el);
    }
}

function showJob(el) {
    const p = $(".progress", el);
    p.classList.remove("hidden");
    $(".bar", p).style.width = (job.state === "done" ? 100 : job.percent || 0) + "%";
    $(".bar", p).style.background = job.state === "error" ? "var(--bad)" : job.state === "done" ? "var(--ok)" : "";
    $(".ptext", p).textContent = job.message || "";
}

async function install(a) {
    notice("");
    const { ok, j } = await post("install", { id: a.id });
    if (!ok) { notice(j.error || "Could not start the installation", true); return; }
    job = { id: a.id, state: "running", percent: 0, message: "Starting" }; render();
    clearInterval(polling);
    polling = setInterval(async () => {
        job = (await api("job")).j;
        const el = document.querySelector(`.card[data-id="${a.id}"]`); if (el) showJob(el);
        if (job.state !== "running") { clearInterval(polling); if (job.state === "error") notice(job.message, true); await loadLibrary(false); }
    }, 500);
}

async function uninstall(a) {
    if (!confirm("Remove " + a.name + " from the Community folder?")) return;
    const { ok, j } = await post("uninstall", { id: a.id });
    if (!ok) notice(j.error, true); else notice("");
    loadLibrary(false);
}

async function loadSettings() {
    const { j } = await api("settings"), f = $("#settingsForm");
    f.catalogUrl.value = j.catalogUrl || "";
    f.communityOverride.value = j.communityOverride || "";
    f.communityOverride.placeholder = j.communityDetected || "not detected - enter the path";
    $("#detected").textContent = "Detected: " + (j.communityDetected || "none") + ". Leave empty to use the detected folder.";
    f.githubToken.value = j.githubToken || "";
    f.checkHours.value = String(j.checkHours || 6);
    f.prerelease.checked = String(j.prerelease) === "true";
    f.autoUpdate.checked = String(j.autoUpdate) !== "false";
    f.selfUpdate.checked = String(j.selfUpdate) !== "false";
    f.autostart.checked = !!j.autostart;
}
$("#settingsForm").onsubmit = async (e) => {
    e.preventDefault();
    const f = e.target;
    await post("settings", { catalogUrl: f.catalogUrl.value.trim(), communityOverride: f.communityOverride.value.trim(), githubToken: f.githubToken.value, checkHours: +f.checkHours.value, prerelease: f.prerelease.checked, autoUpdate: f.autoUpdate.checked, selfUpdate: f.selfUpdate.checked, autostart: f.autostart.checked });
    $("#saved").textContent = "Saved."; setTimeout(() => $("#saved").textContent = "", 2500);
    loadStatus(); loadLibrary(true);
};
$("#openCommunity").onclick = () => post("open-community");
// "Check for updates": the hangar itself first (it may restart), then the aircraft
$("#refresh").onclick = async () => {
    $("#refresh").disabled = true;
    await post("check-updates");
    setTimeout(async () => { await loadStatus(); await loadLibrary(true); }, 2500);
};
// ---------------- Community folder overview (scenery and every other package) ----------------
let scan = null;
const typeNames = { AIRPORT: "Airports", SCENERY: "Other scenery", NAVDATA: "Nav data (AIRAC)", AIRCRAFT: "Aircraft", LIVERY: "Liveries", MISC: "Misc / libraries", INSTRUMENTS: "Instruments", CORE: "Core", UNKNOWN: "Unknown / broken" };
const typeOrder = ["AIRPORT", "SCENERY", "AIRCRAFT", "LIVERY", "MISC", "INSTRUMENTS", "CORE", "NAVDATA", "UNKNOWN"];
async function loadScan(refresh) {
    $("#scanCount").textContent = "Scanning...";
    try { scan = (await api("community" + (refresh ? "?refresh=1" : ""))).j; } catch (e) { $("#scanCount").textContent = "Scan failed: " + e; return; }
    const sel = $("#scanType"), cur = sel.value || "AIRPORT";
    const rank = t => typeOrder.indexOf(t) < 0 ? 50 : typeOrder.indexOf(t);
    const types = Object.keys(scan.counts || {}).sort((a, b) => rank(a) - rank(b) || a.localeCompare(b));
    const total = (scan.packages || []).length;
    sel.innerHTML = `<option value="ALL">All packages (${total})</option>` + types.map(t => `<option value="${esc(t)}">${esc(typeNames[t] || t)} (${scan.counts[t]})</option>`).join("");
    sel.value = types.indexOf(cur) >= 0 || cur === "ALL" ? cur : (types.indexOf("AIRPORT") >= 0 ? "AIRPORT" : "ALL");
    renderScan();
    loadAirportNames();
}
// airport names next to the ICAO codes (package titles are often only a code or a copyright line)
let aptNames = {}, aptTimer = null;
async function loadAirportNames() {
    const icaos = [...new Set((scan.packages || []).flatMap(p => p.airports || []))].filter(i => !aptNames[i]);
    if (!icaos.length) return;
    try {
        const { j } = await api("airports?icao=" + encodeURIComponent(icaos.join(",")));
        clearTimeout(aptTimer);
        if (j.status === "ready") { Object.keys(j.airports).forEach(k => aptNames[k] = j.airports[k].name); renderScan(); }
        else if (j.status === "loading" || j.status === "not loaded") aptTimer = setTimeout(loadAirportNames, 2000);
    } catch (e) { }
}
function scanRows() {
    const q = $("#scanSearch").value.trim().toLowerCase(), type = $("#scanType").value;
    return (scan.packages || []).filter(p => (type === "ALL" || p.type === type) &&
        (!q || [p.title, p.creator, p.folder].concat(p.airports || []).some(v => String(v || "").toLowerCase().indexOf(q) >= 0)));
}
// ---- world map of the airports in the Community folder (Leaflet, OpenStreetMap tiles; positions from the hangar) ----
let map = null, mapLayer = null, mapTimer = null, showMap = false;
async function renderMap(rows) {
    const note = $("#mapNote");
    if (typeof L === "undefined") { note.textContent = "The map needs an internet connection (map library could not be loaded)."; return; }
    if (!map) {
        map = L.map("map", { worldCopyJump: true, minZoom: 2 }).setView([30, 0], 2);
        // OpenStreetMap tiles (no key), darkened with a CSS filter to match the page (.darktiles in style.css)
        L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png",
            { maxZoom: 18, className: "darktiles", attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors' }).addTo(map);
        mapLayer = L.layerGroup().addTo(map);
    }
    setTimeout(() => map.invalidateSize(), 0);
    const icaos = [...new Set(rows.flatMap(p => p.airports || []))];
    if (!icaos.length) { mapLayer.clearLayers(); note.textContent = "No airports in this selection."; return; }
    const { j } = await api("airports?icao=" + encodeURIComponent(icaos.join(",")));
    clearTimeout(mapTimer);
    if (j.status !== "ready") {
        note.textContent = j.status === "loading" ? "Loading the airport list (first time: about 12 MB)..." : "Airport positions unavailable: " + j.status;
        if (j.status === "loading" || j.status === "not loaded") mapTimer = setTimeout(() => showMap && renderMap(scanRows()), 2000);
        return;
    }
    mapLayer.clearLayers();
    const pts = [], missing = [];
    for (const p of rows) for (const icao of p.airports || []) {
        const a = j.airports[icao]; if (!a) { missing.push(icao); continue; }
        pts.push([a.lat, a.lon]);
        L.circleMarker([a.lat, a.lon], { radius: 6, weight: 1.5, color: p.airportsGuessed ? "#e2a74f" : "#8fb4d6", fillColor: p.airportsGuessed ? "#e2a74f" : "#8fb4d6", fillOpacity: .35, dashArray: p.airportsGuessed ? "3 3" : null })
            .bindTooltip(icao, { permanent: pts.length <= 40, direction: "top", offset: [0, -6], className: "icaotip" })
            .bindPopup(`<b>${esc(icao)}</b> ${esc(a.name)}<br>${esc(p.title)}${p.creator ? "<br><span class='muted'>" + esc(p.creator) + "</span>" : ""}${p.airportsGuessed ? "<br><i>ICAO guessed from the folder name</i>" : ""}`)
            .addTo(mapLayer);
    }
    if (pts.length) map.fitBounds(pts, { padding: [40, 40], maxZoom: 7 });
    note.textContent = pts.length + " airports on the map" + (missing.length ? " - no position for " + missing.join(", ") : "") + ". Dashed: ICAO guessed from the folder name.";
}
function setMapMode(on) {
    showMap = on;
    $("#showMap").classList.toggle("active", on); $("#showList").classList.toggle("active", !on);
    $("#mapWrap").classList.toggle("hidden", !on);
    renderScan();
}
$("#showList").onclick = () => setMapMode(false);
$("#showMap").onclick = () => setMapMode(true);
function renderScan() {
    if (!scan) return;
    const rows = scanRows();
    if (showMap) renderMap(rows);
    $("#scanCount").textContent = rows.length + " shown - " + (scan.community || "no Community folder") + " - scanned " + scan.scanned;
    $("#scanList").innerHTML = rows.map(p => `<div class="pkg">
        <div class="t">${esc(p.title)}</div>
        <div class="side"><button class="secondary" data-open="${esc(p.folder)}">Open folder</button></div>
        <div class="meta">
          ${(p.airports || []).slice(0, 12).map(i => `<span class="icao${p.airportsGuessed ? " guess" : ""}" title="${p.airportsGuessed ? "guessed from the folder name" : "from ContentHistory.json"}">${esc(i)}</span>${(p.airports || []).length <= 3 && aptNames[i] ? `<span class="aname">${esc(aptNames[i])}</span>` : ""}`).join("")}
          ${(p.airports || []).length > 12 ? `<span class="tag" title="${esc(p.airports.slice(12).join(", "))}">+${p.airports.length - 12} more airports</span>` : ""}
          ${p.creator ? `<span>${esc(p.creator)}</span>` : ""}
          ${p.version ? `<span>v${esc(p.version)}</span>` : ""}
          ${p.sizeMB ? `<span>${p.sizeMB >= 1024 ? (p.sizeMB / 1024).toFixed(1) + " GB" : Math.round(p.sizeMB) + " MB"}</span>` : ""}
          <span class="tag">${esc(typeNames[p.type] || p.type)}</span>
          ${p.linked ? `<span class="tag" title="folder is a link to another location">linked</span>` : ""}
          ${p.problem ? `<span class="tag warn">${esc(p.problem)}</span>` : ""}
          <span class="muted">${esc(p.folder)}</span>
        </div></div>`).join("") || `<p class="muted">Nothing matches.</p>`;
    document.querySelectorAll("[data-open]").forEach(b => b.onclick = () => post("open-package", { folder: b.dataset.open }));
}
$("#scanSearch").oninput = renderScan;
$("#scanType").onchange = renderScan;
$("#scanRefresh").onclick = () => loadScan(true);
// ---------------- Navigraph account (held by the hangar) ----------------
// While a sign-in is waiting, the page asks for the session every 2 s; that is the hangar's sign that someone is
// watching. Leaving or hiding the page stops it, and the hangar ends the sign-in after about 20 s (device-flow rule).
let ngTimer = null, ngLastCode = "";
async function ngRefresh() {
    let s;
    try { s = (await api("navigraph/session")).j; } catch (e) { return; }
    const st = $("#ngState"), waiting = s.state === "waiting" || s.state === "starting";
    st.textContent = !s.configured ? "Not available in this build" : s.state === "in" ? "Signed in" + (s.user ? " as " + s.user : "") :
        waiting ? "Waiting for your approval" : s.state === "error" ? s.message : "Not signed in" + (s.message ? " - " + s.message : "");
    st.style.color = s.state === "in" ? "var(--ok)" : s.state === "error" ? "var(--bad)" : "";
    $("#ngLogin").classList.toggle("hidden", s.state === "in" || waiting || !s.configured);
    $("#ngLogout").classList.toggle("hidden", s.state !== "in");
    $("#ngCancel").classList.toggle("hidden", !waiting);
    $("#ngCode").classList.toggle("hidden", !(s.state === "waiting" && s.code));
    if (s.state === "waiting" && s.code) {
        const c = s.code;
        if (c.verification_uri_complete !== ngLastCode) {
            ngLastCode = c.verification_uri_complete;
            const cv = $("#ngQr"), g = cv.getContext("2d");
            QR.draw(g, c.verification_uri_complete, 0, 0, cv.width);
        }
        $("#ngLink").textContent = c.verification_uri.replace(/^https?:\/\//, "");
        $("#ngLink").href = c.verification_uri_complete;
        $("#ngUserCode").textContent = c.user_code;
        $("#ngExpires").textContent = "Code valid for " + Math.floor(c.expires_in / 60) + ":" + String(c.expires_in % 60).padStart(2, "0");
    }
    clearTimeout(ngTimer);
    if (waiting && document.visibilityState === "visible") ngTimer = setTimeout(ngRefresh, 2000);
}
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") ngRefresh(); });
$("#ngLogin").onclick = async () => { ngLastCode = ""; const { ok, j } = await post("navigraph/login"); if (!ok) notice("Navigraph: " + (j.error || "sign-in could not start"), true); ngRefresh(); };
$("#ngCancel").onclick = async () => { await post("navigraph/cancel"); ngRefresh(); };
$("#ngLogout").onclick = async () => { if (confirm("Sign out of Navigraph? The EFBs lose access to charts until you sign in again.")) { await post("navigraph/logout"); ngRefresh(); } };

(async () => {
    await loadStatus();
    job = (await api("job")).j;
    await loadLibrary(false);
    ngRefresh();
    setInterval(loadStatus, 10000);
})();
