// Jetstream Hangar toolbar panel (MSFS 2024, every aircraft).
//   - Jetstream Virtual hangars: distance from the aircraft, door position, OPEN / CLOSE. The door motor is in the
//     hangar scenery: the panel only sets L:JV_HANGAR_DOOR_TARGET (0 / 100) and shows L:JV_HANGAR_DOOR (0..100), so
//     the door keeps moving when the panel is closed, and the AT-3 EFB and this panel always agree.
//   - Hangar lights: L:JV_HANGAR_LIGHTS 0 = AUTO (on at dawn, dusk and night), 1 = ON, 2 = OFF; the hangar switches them.
//   - Jetstream Hangar desktop app: connected or not (http://localhost:48330/api/ping).
// Runs in Coherent GT: no ?? / ?. / async-await. JHPanel holds the logic (tested in toolbar\tests\panel_tests.html with
// a stand-in SimVar); IngamePanelJetstreamHangar only wires it to the toolbar window.

var JH_HANGARS = [
    { id: "KFHR", name: "JV Hangar KFHR", place: "Friday Harbor, San Juan Island", lat: 48.52766565, lon: -123.02752819 }
];
var JH_APP = "http://localhost:48330";

var JHPanel = {
    // great-circle distance in metres
    dist: function (lat1, lon1, lat2, lon2) {
        var r = Math.PI / 180, a = Math.sin((lat2 - lat1) * r / 2), b = Math.sin((lon2 - lon1) * r / 2);
        var h = a * a + Math.cos(lat1 * r) * Math.cos(lat2 * r) * b * b;
        return 2 * 6371000 * Math.asin(Math.min(1, Math.sqrt(h)));
    },
    distText: function (m) {
        if (m < 1000) return Math.round(m) + " m";
        var nm = m / 1852;
        return nm < 10 ? nm.toFixed(1) + " nm" : Math.round(nm) + " nm";
    },
    lvar: function (n) { var v = SimVar.GetSimVarValue("L:" + n, "number"); return typeof v === "number" && isFinite(v) ? v : 0; },
    doorPos: function () { return Math.max(0, Math.min(100, this.lvar("JV_HANGAR_DOOR"))); },
    doorTarget: function () { return this.lvar("JV_HANGAR_DOOR_TARGET") > 50 ? 100 : 0; },
    setTarget: function (t) { SimVar.SetSimVarValue("L:JV_HANGAR_DOOR_TARGET", "number", t > 50 ? 100 : 0); },
    lightsMode: function () { var m = Math.round(this.lvar("JV_HANGAR_LIGHTS")); return m === 1 || m === 2 ? m : 0; },
    setLights: function (m) { SimVar.SetSimVarValue("L:JV_HANGAR_LIGHTS", "number", m === 1 || m === 2 ? m : 0); },
    doorState: function () {
        var p = this.doorPos(), t = this.doorTarget();
        if (Math.abs(p - t) <= 0.5) return p >= 50 ? "Open" : "Closed";
        return (t > p ? "Opening " : "Closing ") + Math.round(p) + " %";
    },
    // hangars sorted by distance from the aircraft
    hangars: function () {
        var lat = SimVar.GetSimVarValue("PLANE LATITUDE", "degrees"), lon = SimVar.GetSimVarValue("PLANE LONGITUDE", "degrees");
        var list = JH_HANGARS.map(function (h) { return { h: h, d: JHPanel.dist(lat, lon, h.lat, h.lon) }; });
        list.sort(function (a, b) { return a.d - b.d; });
        return list;
    },
    esc: function (s) { return String(s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" }[c]; }); },
    render: function (root, app) {
        var self = this, rows = this.hangars(), p = this.doorPos(), state = this.doorState(), moving = state.indexOf("ing ") > 0;
        var html = "<div class='jh-app " + (app.ok ? "ok" : "off") + "'><span class='dot'></span>" +
            (app.ok ? "Jetstream Hangar " + this.esc(app.version) + " connected" : "Jetstream Hangar app not running") + "</div>";
        rows.forEach(function (r) {
            html += "<section class='jh-hangar'><div class='jh-head'><div><b>" + self.esc(r.h.name) + "</b><span>" + self.esc(r.h.place) + "</span></div>" +
                "<em>" + self.distText(r.d) + "</em></div>" +
                "<div class='jh-door'><div class='jh-label'>Hangar door</div><div class='jh-state" + (moving ? " moving" : "") + "'>" + state + "</div></div>" +
                "<div class='jh-bar'><i style='width:" + p.toFixed(1) + "%'></i></div>" +
                "<div class='jh-buttons'><button data-t='100'" + (self.doorTarget() === 100 ? " class='on'" : "") + ">OPEN</button>" +
                "<button data-t='0'" + (self.doorTarget() === 0 ? " class='on'" : "") + ">CLOSE</button></div>" +
                "<div class='jh-door'><div class='jh-label'>Hangar lights</div></div><div class='jh-buttons jh-lights'>" +
                ["AUTO", "ON", "OFF"].map(function (t, m) { return "<button data-l='" + m + "'" + (self.lightsMode() === m ? " class='on'" : "") + ">" + t + "</button>"; }).join("") +
                "</div></section>";
        });
        html += "<p class='jh-note'>The door runs on its own motor (25 s). AUTO: lights on at dawn, dusk and night. The AT-3 EFB shows the same door and lights.</p>";
        root.innerHTML = html;
        var bs = root.querySelectorAll("button");
        for (var i = 0; i < bs.length; i++) bs[i].addEventListener("click", function (e) {
            var b = e.currentTarget;
            if (b.hasAttribute("data-l")) self.setLights(Number(b.getAttribute("data-l"))); else self.setTarget(Number(b.getAttribute("data-t")));
            self.render(root, app);
        });
    },
    // desktop app status, at most every 5 s
    pingApp: function (app, done) {
        if (Date.now() - app.checked < 5000) { if (done) done(); return; }
        app.checked = Date.now();
        try {
            fetch(JH_APP + "/api/ping").then(function (r) { return r.ok ? r.json() : null; }).then(function (j) {
                app.ok = !!j; app.version = j && j.version ? j.version : ""; if (done) done();
            }).catch(function () { app.ok = false; if (done) done(); });
        } catch (e) { app.ok = false; if (done) done(); }
    }
};

if (typeof TemplateElement !== "undefined") {
    class IngamePanelJetstreamHangar extends TemplateElement {
        constructor() { super(...arguments); this.timer = null; this.app = { ok: false, version: "", checked: 0 }; }
        connectedCallback() {
            super.connectedCallback();
            this.ui = this.querySelector("ingame-ui");
            this.root = this.querySelector("#jh-root");
            if (this.ui) {
                this.ui.addEventListener("panelActive", () => this.start());
                this.ui.addEventListener("panelInactive", () => this.stop());
            }
            this.start();
        }
        start() {
            if (this.timer) return;
            const tick = () => { JHPanel.pingApp(this.app); try { JHPanel.render(this.root, this.app); } catch (e) { this.root.textContent = "Jetstream Hangar: " + e; } };
            tick();
            this.timer = setInterval(tick, 250);
        }
        stop() { if (this.timer) { clearInterval(this.timer); this.timer = null; } }
    }
    window.customElements.define("ingamepanel-jetstream-hangar", IngamePanelJetstreamHangar);
    if (typeof checkAutoload === "function") checkAutoload();
}
