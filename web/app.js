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
});

function notice(text, err) {
    const n = $("#notice");
    n.textContent = text || ""; n.classList.toggle("hidden", !text); n.classList.toggle("err", !!err);
}

async function loadStatus() {
    const { j } = await api("status");
    const chips = [];
    chips.push(j.communityOk ? ["ok", "Community folder found"] : ["bad", "Community folder not found"]);
    chips.push(j.simRunning ? ["warn", "MSFS running"] : ["ok", "MSFS closed"]);
    chips.push(j.navigraph ? ["ok", "EFB backend ready"] : ["warn", "Navigraph not configured"]);
    if (j.waiting && j.waiting.length) chips.push(["warn", "Update waiting for MSFS to close: " + j.waiting.join(", ")]);
    else if (j.autoUpdate) chips.push(["ok", "Auto-update on"]);
    if (j.selfUpdate && j.selfUpdate.state === "error") chips.push(["bad", j.selfUpdate.message]);
    $(".brand").title = "Version " + j.version;
    $("#chips").innerHTML = chips.map(c => `<span class="chip ${c[0]}">${esc(c[1])}</span>`).join("");
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
    return `<h3>Technical state ${seen ? `<span class="muted" style="text-transform:none;font-weight:400">- synced ${esc(seen)}</span>` : ""}</h3>
        <div class="aw ${issues.length ? "bad" : "ok"}">${issues.length ? "NOT AIRWORTHY: " + esc(issues.join(", ")) : "AIRWORTHY"}</div>
        <div class="grid">${rows.map(r => `<div><span>${esc(r[0])}</span><span class="${r[2]}">${esc(r[1])}</span></div>`).join("")}</div>
        <div class="log">${(st.log || []).slice(0, 12).map(e => esc(e.t + "  " + e.h + " h  " + e.text)).join("<br>")}</div>`;
}

function render() {
    const host = $("#cards"); host.innerHTML = "";
    for (const a of items) {
        const el = $("#cardTpl").content.firstElementChild.cloneNode(true);
        el.dataset.id = a.id;
        const th = $(".thumb", el);
        if (a.image) th.style.backgroundImage = `url("${a.image}")`; else th.textContent = "✈";
        $("h2", el).textContent = a.name;
        $(".maker", el).textContent = a.manufacturer || "";
        $(".desc", el).textContent = a.description || "";
        const badge = !a.installed ? `<span class="badge none">not installed</span>` : a.updateAvailable ? `<span class="badge upd">update available</span>` : a.latestVersion ? `<span class="badge ok">up to date</span>` : "";
        $(".versions", el).innerHTML = `${badge}<span>Installed <b>${esc(a.installedVersion || "-")}</b></span><span>Latest <b>${esc(a.latestVersion || "-")}</b></span>` +
            (a.release && a.release.size ? `<span>${(a.release.size / 1048576).toFixed(0)} MB</span>` : "") + (a.releaseError ? `<span style="color:var(--warn)">${esc(a.releaseError)}</span>` : "");
        const b = $(".buttons", el), busy = job.state === "running";
        const btn = (label, cls, fn, dis) => { const x = document.createElement("button"); x.textContent = label; if (cls) x.className = cls; x.disabled = !!dis || busy; x.onclick = fn; b.appendChild(x); };
        if (a.release) {
            if (!a.installed) btn("Install " + a.latestVersion, "", () => install(a));
            else if (a.updateAvailable) btn("Update to " + a.latestVersion, "", () => install(a));
            else btn("Reinstall", "secondary", () => install(a));
        }
        if (a.installed) btn("Uninstall", "danger", () => uninstall(a));
        if (a.release && a.release.notes) { $(".notes", el).classList.remove("hidden"); $(".notes pre", el).textContent = a.release.notes; }
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
$("#openCommunity").onclick = () => api("open-community");
$("#refresh").onclick = () => loadLibrary(true);

(async () => {
    await loadStatus();
    job = (await api("job")).j;
    await loadLibrary(false);
    setInterval(loadStatus, 10000);
})();
