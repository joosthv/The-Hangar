// Aircraft page: the aeroplane in its hangar bay, with Overview, Maintenance (colour bars against the limits), Flight log,
// Technical log and Failures (rate, carburettor icing, failures armed now or within x minutes). The data comes from the
// aircraft's EFB (technical state, synced about once a minute and after every flight) and from the hangar's per-aircraft
// settings (/api/aircraft/<id>/settings).
let acId = null, acTab = "overview", acSettings = null, logFilter = "all";
const aptCache = {};

// ---------- hangar bay: back wall, roof trusses, lights, floor with bay markings, the aircraft and its reflection ----------
function bayHtml(a, big) {
    // a rendered hangar scene (the aircraft in the Jetstream hangar: build\scene.html) when the catalogue has one
    const photo = big ? a.scene : (a.sceneCard || a.scene);
    if (photo) return `<div class="bay photo${big ? " big" : ""}"><img src="${esc(photo)}" alt="${esc(a.name)} in the hangar" onerror="this.closest('.bay').classList.add('empty');this.remove()"></div>`;
    const img = a.cutout || a.image || "";
    const reg = (a.registration || (a.name || "").split(" ").slice(-1)[0] || "").toUpperCase();
    return `<div class="bay${big ? " big" : ""}${img ? "" : " empty"}">
      <svg class="truss" viewBox="0 0 1000 120" preserveAspectRatio="none" aria-hidden="true">
        <path d="M0 18 L1000 18 M0 70 L1000 70" />
        ${Array.from({ length: 21 }, (_, i) => `<path d="M${i * 50} 18 L${i * 50 + 25} 70 L${i * 50 + 50} 18" />`).join("")}
      </svg>
      <div class="lamps"><i></i><i></i><i></i></div>
      <div class="wall-mark">BAY 1${reg ? " · " + esc(reg) : ""}</div>
      <div class="floor"></div>
      ${img ? `<img class="plane" src="${esc(img)}" alt="${esc(a.name)}" onerror="this.closest('.bay').classList.add('empty');this.remove()">
      <img class="plane mirror" src="${esc(img)}" alt="" aria-hidden="true" onerror="this.remove()">` : ""}
      <div class="shadow"></div>
    </div>`;
}

// ---------- the fleet card shows a short summary; the aircraft page has the rest ----------
function techSummary(st) {
    const issues = airworthiness(st);
    const seen = st._seen ? new Date(st._seen).toLocaleString() : "";
    return `<div class="tech-head"><div><div class="eyebrow">Technical state</div>${seen ? `<div class="muted small">Synced from the EFB ${esc(seen)}</div>` : ""}</div>
        <div class="aw ${issues.length ? "bad" : "ok"}">${issues.length ? "Not airworthy: " + esc(issues.join(", ")) : "Airworthy"}</div></div>
        <div class="kv">${[["Airframe", (+st.ttaf).toFixed(1) + " h"], ["Flights", (st.flights || []).length], ["Landings", st.landings || 0], ["Next 100 h", Math.max(0, 100 - st.since100).toFixed(1) + " h"]]
            .map(r => `<div><span>${r[0]}</span><b>${esc(r[1])}</b></div>`).join("")}</div>`;
}
function airworthiness(st) {
    const issues = [];
    if (st.since100 > 100) issues.push("100 h inspection overdue");
    if (st.oil < 2.5) issues.push("oil below minimum");
    ["n", "l", "r"].forEach(k => { if (st.tyres && st.tyres[k] < 1.6) issues.push({ n: "nose", l: "left", r: "right" }[k] + " tyre soft"); });
    if (st.damage > 0.05) issues.push("engine damage");
    (st.defects || []).forEach(d => issues.push(d));
    return issues;
}

// ---------- navigation ----------
function openAircraft(id) {
    acId = id; acTab = acTab || "overview"; acSettings = null;
    document.querySelectorAll(".view").forEach(v => v.classList.toggle("hidden", v.id !== "aircraft"));
    document.querySelectorAll(".tab").forEach(x => x.classList.toggle("active", x.dataset.view === "library"));
    window.scrollTo(0, 0);
    renderAircraft();
    loadAcSettings();
}
$("#acBack").onclick = () => { acId = null; document.querySelectorAll(".view").forEach(v => v.classList.toggle("hidden", v.id !== "library")); };
document.querySelectorAll("#acTabs button").forEach(b => b.onclick = () => { acTab = b.dataset.sub; renderAircraft(); if (acTab === "fail") loadAcSettings(); });

function renderAircraft() {
    if (!acId) return;
    const a = items.find(x => x.id === acId); if (!a) return;
    $("#acMaker").textContent = a.manufacturer || "";
    $("#acName").textContent = a.name;
    $("#acState").innerHTML = !a.installed ? `<span class="badge none">Not installed</span>` : a.updateAvailable ? `<span class="badge upd">Update available</span>` : `<span class="badge ok">Up to date</span>`;
    const bay = $("#acBay"); if (bay.dataset.for !== a.id) { bay.innerHTML = bayHtml(a, true); bay.dataset.for = a.id; }
    document.querySelectorAll("#acTabs button").forEach(b => b.classList.toggle("active", b.dataset.sub === acTab));
    const host = $("#acBody"), st = a.state;
    host.innerHTML = "";
    if (acTab === "overview") { host.appendChild(cardEl(a, false)); if (st) host.insertAdjacentHTML("beforeend", `<div class="panel">${techSummary(st)}</div>`); return; }
    if (!st && acTab !== "fail") { host.innerHTML = `<p class="muted empty-note">No data from the aircraft yet. Fly the ${esc(a.name)} once with Jetstream Hangar running: the EFB sends its technical state, logbook and failures here.</p>`; return; }
    if (acTab === "maint") host.innerHTML = maintHtml(st);
    if (acTab === "flights") { host.innerHTML = flightsHtml(st); nameAirfields(st); }
    if (acTab === "techlog") { host.innerHTML = techLogHtml(st); host.querySelectorAll("[data-filter]").forEach(b => b.onclick = () => { logFilter = b.dataset.filter; renderAircraft(); }); }
    if (acTab === "fail") { host.innerHTML = failHtml(a, st); wireFail(a); }
}

// ---------- maintenance: every value on a bar with its limits ----------
// zones: [from, to, "ok" | "warn" | "bad"]; marks: [value, label]
function gaugeBar(name, value, min, max, zones, marks, text, sub) {
    const pct = v => Math.max(0, Math.min(100, (v - min) / (max - min) * 100));
    const zone = zones.find(z => value >= z[0] && value < z[1]) || zones[value < zones[0][0] ? 0 : zones.length - 1];
    return `<div class="gbar ${zone[2]}">
      <div class="gtop"><span class="gname">${esc(name)}</span><span class="gval">${esc(text)}</span></div>
      <div class="gtrack">${zones.map(z => `<i class="z ${z[2]}" style="left:${pct(z[0])}%;width:${pct(z[1]) - pct(z[0])}%"></i>`).join("")}
        ${(marks || []).map(m => `<i class="m" style="left:${pct(m[0])}%"><b>${esc(m[1])}</b></i>`).join("")}
        <i class="needle" style="left:${pct(value)}%"></i></div>
      ${sub ? `<div class="gsub">${esc(sub)}</div>` : ""}
    </div>`;
}
function dueBar(name, since, limit) {
    const left = limit - since;
    return gaugeBar(name, since, 0, limit * 1.15, [[0, limit - 10, "ok"], [limit - 10, limit, "warn"], [limit, limit * 1.15, "bad"]], [[limit, limit + " h"]],
        since.toFixed(1) + " of " + limit + " h", left > 0 ? left.toFixed(1) + " h until due" : "OVERDUE by " + (-left).toFixed(1) + " h");
}
function maintHtml(st) {
    const oilLim = st.avgas > 0.5 ? 50 : 100, t = st.tyres || {}, p = st.pads || {};
    const tyre = (k, n) => gaugeBar("Tyre " + n, t[k], 0, 3.2, [[0, 1.6, "bad"], [1.6, 2.2, "warn"], [2.2, 2.8, "ok"], [2.8, 3.2, "warn"]], [[2.5, "2.5"]], (+t[k]).toFixed(2) + " bar", (st.leak && st.leak[k] > 0 ? "leaking - " : "") + "nominal 2.5 bar, soft below 1.6");
    const issues = airworthiness(st);
    return `<div class="aw-row"><div class="aw ${issues.length ? "bad" : "ok"}">${issues.length ? "Not airworthy" : "Airworthy"}</div>${issues.length ? `<span>${esc(issues.join(" · "))}</span>` : `<span class="muted">No open defects, all inspections within limits.</span>`}</div>
    <div class="gcols">
      <section class="panel"><h3 class="eyebrow">Inspections and intervals</h3>
        ${dueBar("100 h / annual inspection", st.since100, 100)}
        ${dueBar("Oil and filter change", st.sinceOil, oilLim)}
        ${dueBar("Spark plugs", st.sincePlugs, 100)}
        ${dueBar("Carburettor synchronisation", st.sinceCarb, 100)}
        ${dueBar("Air filter", st.sinceFilter, 100)}
        ${gaugeBar("Engine time since new", st.tsn, 0, 2100, [[0, 1900, "ok"], [1900, 2000, "warn"], [2000, 2100, "bad"]], [[2000, "TBO"]], (+st.tsn).toFixed(1) + " h", "Rotax 912 S TBO 2000 h")}
      </section>
      <section class="panel"><h3 class="eyebrow">Fluids and electrics</h3>
        ${gaugeBar("Engine oil", st.oil, 1.5, 4.0, [[1.5, 2.0, "bad"], [2.0, 2.5, "warn"], [2.5, 3.5, "ok"], [3.5, 4.0, "warn"]], [[2.5, "MIN"], [3.5, "MAX"]], (+st.oil).toFixed(2) + " l",
            (st.oil < 2.5 ? "BELOW MIN: add " + (3.0 - st.oil).toFixed(2) + " l (to 3.0 l)" : st.oil > 3.5 ? "above MAX: do not add oil" : (st.oil - 2.5).toFixed(2) + " l above MIN, " + (3.5 - st.oil).toFixed(2) + " l below MAX") + " · POH 2.5 - 3.5 l")}
        ${gaugeBar("Coolant", st.coolant, 1.0, 2.3, [[1.0, 1.6, "bad"], [1.6, 1.85, "warn"], [1.85, 2.3, "ok"]], [[2.0, "2.0"]], (+st.coolant).toFixed(2) + " l", "system 2.0 l")}
        ${gaugeBar("Battery condition", st.battery, 0, 100, [[0, 25, "bad"], [25, 60, "warn"], [60, 100.01, "ok"]], [[25, "no start"]], Math.round(st.battery) + " %", "12 V 18 Ah")}
        ${gaugeBar("Engine condition", (st.damage || 0) * 100, 0, 120, [[0, 5, "ok"], [5, 100, "warn"], [100, 120, "bad"]], [[100, "seized"]], st.damage > 0.05 ? "damaged " + Math.round(st.damage * 100) + " %" : "serviceable", "")}
      </section>
      <section class="panel"><h3 class="eyebrow">Wheels and brakes</h3>
        ${tyre("n", "nose")}${tyre("l", "left main")}${tyre("r", "right main")}
        ${gaugeBar("Brake pads left", p.l, 0, 6.5, [[0, 2, "bad"], [2, 3, "warn"], [3, 6.5, "ok"]], [[2, "MIN"]], (+p.l).toFixed(1) + " mm", "")}
        ${gaugeBar("Brake pads right", p.r, 0, 6.5, [[0, 2, "bad"], [2, 3, "warn"], [3, 6.5, "ok"]], [[2, "MIN"]], (+p.r).toFixed(1) + " mm", "")}
      </section>
      <section class="panel"><h3 class="eyebrow">Totals</h3>
        <div class="kv big">${[["Airframe total time", (+st.ttaf).toFixed(1) + " h"], ["Engine since new", (+st.tsn).toFixed(1) + " h"], ["Flights logged", (st.flights || []).length], ["Landings", st.landings || 0],
            ["Open defects", (st.defects || []).length || "none"]].map(r => `<div><span>${r[0]}</span><b>${esc(r[1])}</b></div>`).join("")}</div>
        ${(st.defects || []).length ? `<ul class="defects">${st.defects.map(d => `<li>${esc(d)}</li>`).join("")}</ul>` : ""}
        <p class="muted small">Maintenance is carried out in the cockpit: EFB, TECH, MAINT (on the ground, engine stopped).</p>
      </section>
    </div>`;
}

// ---------- flight logbook ----------
const hm = iso => { const d = new Date(iso); return isNaN(d) ? "-" : String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0"); };
const hhmm = h => { const m = Math.round((+h || 0) * 60); return Math.floor(m / 60) + ":" + String(m % 60).padStart(2, "0"); };
function flightsHtml(st) {
    const f = st.flights || [];
    if (!f.length) return `<p class="muted empty-note">No flights logged yet. A flight is logged from engine start to engine stop when the aircraft has been airborne.</p>`;
    const sum = (k) => f.reduce((s, x) => s + (+x[k] || 0), 0);
    const apt = (pt) => { const c = pt ? aptCache[pt.join(",")] : null; return c === undefined ? `<span class="muted">...</span>` : c ? `<span class="icao" title="${esc(c.name)}">${esc(c.code)}</span>` : `<span class="muted" title="${pt.join(", ")}">field</span>`; };
    return `<div class="kv big totals">${[["Flights", f.length], ["Block time", hhmm(sum("block"))], ["Air time", hhmm(sum("air"))], ["Landings", sum("landings")]].map(r => `<div><span>${r[0]}</span><b>${r[1]}</b></div>`).join("")}</div>
    <div class="table-wrap"><table class="log-table">
      <thead><tr><th>Date</th><th>From</th><th>To</th><th>Off</th><th>On</th><th class="r">Block</th><th class="r">Air</th><th class="r">Ldg</th><th class="r">Max alt</th></tr></thead>
      <tbody>${f.map(x => `<tr><td>${esc(x.date)}</td><td>${apt(x.dep)}</td><td>${apt(x.arr)}</td><td>${hm(x.off)}</td><td>${hm(x.on)}</td>
        <td class="r">${hhmm(x.block)}</td><td class="r">${hhmm(x.air)}</td><td class="r">${x.landings}</td><td class="r">${(x.maxAlt || 0).toLocaleString()} ft</td></tr>`).join("")}</tbody>
    </table></div>`;
}
async function nameAirfields(st) {
    const pts = []; (st.flights || []).forEach(x => [x.dep, x.arr].forEach(p => { if (p && aptCache[p.join(",")] === undefined && pts.indexOf(p.join(",")) < 0) pts.push(p.join(",")); }));
    if (!pts.length) return;
    try {
        const { j } = await api("airports/nearest?pts=" + encodeURIComponent(pts.join(";")));
        if (j.status !== "ready") { setTimeout(() => acTab === "flights" && nameAirfields(st), 2000); return; }
        pts.forEach((p, i) => aptCache[p] = j.airports[i] || null);
        if (acTab === "flights") renderAircraft();
    } catch (e) { }
}

// ---------- technical log ----------
function techLogHtml(st) {
    const kinds = [["all", "All"], ["maint", "Maintenance"], ["defect", "Defects"], ["exceed", "Exceedances"], ["info", "Landings and notes"]];
    const rows = (st.log || []).filter(e => logFilter === "all" || (e.kind || "info") === logFilter);
    return `<div class="filters"><div class="seg">${kinds.map(k => `<button type="button" data-filter="${k[0]}" class="${logFilter === k[0] ? "active" : ""}">${k[1]}</button>`).join("")}</div>
      <span class="muted small">${(st.log || []).length} entries, newest first (the aircraft keeps the last 80)</span></div>
    ${rows.length ? `<div class="table-wrap"><table class="log-table"><thead><tr><th>Date</th><th class="r">Airframe h</th><th>Kind</th><th>Entry</th></tr></thead>
      <tbody>${rows.map(e => `<tr><td>${esc(e.t)}</td><td class="r">${esc(e.h)}</td><td><span class="tag ${e.kind === "defect" || e.kind === "exceed" ? "warn" : ""}">${esc({ maint: "maintenance", defect: "defect", exceed: "exceedance", info: "note" }[e.kind || "info"] || e.kind)}</span></td><td>${esc(e.text)}</td></tr>`).join("")}</tbody></table></div>`
        : `<p class="muted empty-note">Nothing in this category.</p>`}`;
}

// ---------- failures ----------
async function loadAcSettings() {
    if (!acId) return;
    try { const { ok, j } = await api("aircraft/" + acId + "/settings"); if (ok) { acSettings = j; if (acTab === "fail") renderAircraft(); } } catch (e) { }
}
const RATES = [["off", "Off", "No random failures"], ["realistic", "Realistic", "Real-world rates: very rare"], ["increased", "Increased", "10 x: now and then"], ["training", "Training", "60 x: expect one every few hours"]];
function failHtml(a, st) {
    const s = acSettings || { failureRate: "realistic", carbIce: true, commands: [] };
    const defs = a.failures || [], name = id => (defs.find(d => d.id === id) || { name: id }).name;
    const groups = [...new Set(defs.map(d => d.group))];
    const fail = st && st.fail ? st.fail : { active: {} };
    const active = Object.keys(fail.active || {});
    const armed = (s.commands || []).filter(c => c.id);
    return `<div class="gcols">
      <section class="panel"><h3 class="eyebrow">Random failures</h3>
        <div class="rates">${RATES.map(r => `<label class="rate ${s.failureRate === r[0] ? "on" : ""}"><input type="radio" name="rate" value="${r[0]}" ${s.failureRate === r[0] ? "checked" : ""}><b>${r[1]}</b><span>${r[2]}</span></label>`).join("")}</div>
        <p class="muted small">Overdue maintenance makes failures more likely. Failures only happen with the engine running.</p>
        <label class="check"><input type="checkbox" id="carbIce" ${s.carbIce ? "checked" : ""}> Carburettor icing <small>from temperature, humidity and power; carb heat clears it</small></label>
        <p class="muted small">Airframe and pitot icing are simulated by MSFS itself (pitot heat works).</p>
      </section>
      <section class="panel"><h3 class="eyebrow">Arm a failure</h3>
        ${defs.length ? `<label>Failure<select id="armId">${groups.map(g => `<optgroup label="${esc(g)}">${defs.filter(d => d.group === g).map(d => `<option value="${esc(d.id)}">${esc(d.name)}</option>`).join("")}</optgroup>`).join("")}</select></label>
        <div class="when"><label class="check"><input type="radio" name="when" value="now" checked> Now</label>
          <label class="check"><input type="radio" name="when" value="within"> Within <input id="armMin" type="number" min="1" max="600" value="15" class="num"> minutes <small>at a random moment</small></label></div>
        <div class="actions"><button id="armBtn" type="button">Arm failure</button><span id="armMsg" class="small muted"></span></div>
        <p class="muted small">The cockpit shows nothing: you find the failure by its symptoms.</p>` : `<p class="muted">This aircraft has no failure list in the catalogue.</p>`}
      </section>
      <section class="panel"><h3 class="eyebrow">Armed, not yet taken by the aircraft</h3>
        ${armed.length ? `<ul class="flist">${armed.map(c => `<li><span>${esc(name(c.id))}</span><span class="muted small">${c.window ? "within " + c.window + " min" : "now"}</span><button class="secondary small-btn" data-disarm="${esc(c.cid)}">Disarm</button></li>`).join("")}</ul>` : `<p class="muted small">Nothing armed. The aircraft picks armed failures up within 10 s while it is running in the sim.</p>`}
      </section>
      <section class="panel"><h3 class="eyebrow">Active in the aircraft</h3>
        ${st ? (active.length ? `<ul class="flist">${active.map(id => `<li><span>${esc(name(id))}</span><span class="muted small">${fail.active[id].source === "hangar" ? "armed here" : "random"}</span></li>`).join("")}</ul>` : `<p class="muted small">No active failures.</p>`) : `<p class="muted small">No data from the aircraft yet.</p>`}
        ${st && fail.ice ? `<p class="small">Carburettor ice: ${Math.round(fail.ice * 100)} %</p>` : ""}
        <div class="actions"><button id="repairBtn" class="secondary" type="button">Workshop repair</button><span id="repairMsg" class="small muted"></span></div>
        <p class="muted small">Repairs everything the next time the aircraft is on the ground with the engine stopped (or use EFB, TECH, MAINT, Troubleshoot and repair).</p>
      </section>
    </div>`;
}
function wireFail(a) {
    const host = $("#acBody");
    host.querySelectorAll('input[name="rate"]').forEach(r => r.onchange = async () => { const { ok, j } = await post("aircraft/" + a.id + "/settings", { failureRate: r.value }); if (ok) acSettings = j; renderAircraft(); });
    const ci = $("#carbIce"); if (ci) ci.onchange = async () => { const { ok, j } = await post("aircraft/" + a.id + "/settings", { carbIce: ci.checked }); if (ok) acSettings = j; };
    const ab = $("#armBtn");
    if (ab) ab.onclick = async () => {
        const within = host.querySelector('input[name="when"]:checked').value === "within";
        const { ok, j } = await post("aircraft/" + a.id + "/failures", { id: $("#armId").value, minutes: within ? +$("#armMin").value : 0 });
        if (ok) { acSettings = j; renderAircraft(); $("#armMsg") && ($("#armMsg").textContent = "Armed."); } else $("#armMsg").textContent = j.error || "Could not arm";
    };
    host.querySelectorAll("[data-disarm]").forEach(b => b.onclick = async () => { const { ok, j } = await post("aircraft/" + a.id + "/disarm", { cid: b.dataset.disarm }); if (ok) acSettings = j; renderAircraft(); });
    const rb = $("#repairBtn"); if (rb) rb.onclick = async () => { const { ok, j } = await post("aircraft/" + a.id + "/repair"); if (ok) { acSettings = j; $("#repairMsg").textContent = "Booked: done at the next stop on the ground."; } };
}
// keep the open page fresh while the aircraft flies (state sync, armed failures being taken)
// (not on Failures: a refresh would wipe a half-filled form - it reloads when the tab is opened)
setInterval(() => { if (acId && document.visibilityState === "visible" && ["maint", "flights", "techlog"].indexOf(acTab) >= 0) loadLibrary(false); }, 15000);
