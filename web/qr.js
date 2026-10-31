// QR code encoder (byte mode, ECC L, versions 1-10), shared with the AT-3 EFB (AT3EfbNav.js).
const QR = (() => {
    const ECC = [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18], BLK = [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4];
    const rawModules = (v) => { let r = (16 * v + 128) * v + 64; if (v >= 2) { const n = Math.floor(v / 7) + 2; r -= (25 * n - 10) * n - 55; if (v >= 7) r -= 36; } return r; };
    const dataCw = (v) => Math.floor(rawModules(v) / 8) - ECC[v] * BLK[v];
    const mul = (x, y) => { let z = 0; for (let i = 7; i >= 0; i--) { z = (z << 1) ^ ((z >>> 7) * 0x11D); z ^= ((y >>> i) & 1) * x; } return z; };
    const divisor = (deg) => { const r = []; for (let i = 0; i < deg - 1; i++) r.push(0); r.push(1); let root = 1; for (let i = 0; i < deg; i++) { for (let j = 0; j < r.length; j++) { r[j] = mul(r[j], root); if (j + 1 < r.length) r[j] ^= r[j + 1]; } root = mul(root, 2); } return r; };
    const remainder = (data, div) => { const r = div.map(() => 0); for (const b of data) { const f = b ^ r.shift(); r.push(0); div.forEach((c, i) => r[i] ^= mul(c, f)); } return r; };
    function encode(text) {
        const bytes = unescape(encodeURIComponent(text)).split("").map(c => c.charCodeAt(0));
        let v = 1;
        for (; v <= 10; v++) if (4 + (v < 10 ? 8 : 16) + bytes.length * 8 <= dataCw(v) * 8) break;
        if (v > 10) return null;
        const bb = [], app = (val, len) => { for (let i = len - 1; i >= 0; i--) bb.push((val >>> i) & 1); };
        app(4, 4); app(bytes.length, v < 10 ? 8 : 16); bytes.forEach(b => app(b, 8));
        const cap = dataCw(v) * 8;
        app(0, Math.min(4, cap - bb.length)); app(0, (8 - bb.length % 8) % 8);
        for (let pad = 0xEC; bb.length < cap; pad ^= 0xEC ^ 0x11) app(pad, 8);
        const data = []; for (let i = 0; i < bb.length; i += 8) { let x = 0; for (let j = 0; j < 8; j++) x = (x << 1) | bb[i + j]; data.push(x); }
        const nb = BLK[v], el = ECC[v], raw = Math.floor(rawModules(v) / 8), nShort = nb - raw % nb, shortLen = Math.floor(raw / nb);
        const blocks = [], dv = divisor(el);
        for (let i = 0, k = 0; i < nb; i++) { const d = data.slice(k, k + shortLen - el + (i < nShort ? 0 : 1)); k += d.length; const e = remainder(d, dv); if (i < nShort) d.push(0); blocks.push(d.concat(e)); }
        const all = []; for (let i = 0; i < blocks[0].length; i++) blocks.forEach((b, j) => { if (i !== shortLen - el || j >= nShort) all.push(b[i]); });
        const size = v * 4 + 17, mod = [], fn = [];
        for (let i = 0; i < size; i++) { mod.push(new Array(size).fill(false)); fn.push(new Array(size).fill(false)); }
        const set = (x, y, d) => { mod[y][x] = d; fn[y][x] = true; };
        for (let i = 0; i < size; i++) { set(6, i, i % 2 === 0); set(i, 6, i % 2 === 0); }
        const finder = (x, y) => { for (let dy = -4; dy <= 4; dy++) for (let dx = -4; dx <= 4; dx++) { const d = Math.max(Math.abs(dx), Math.abs(dy)), xx = x + dx, yy = y + dy; if (xx >= 0 && xx < size && yy >= 0 && yy < size) set(xx, yy, d !== 2 && d !== 4); } };
        finder(3, 3); finder(size - 4, 3); finder(3, size - 4);
        if (v > 1) {
            const n = Math.floor(v / 7) + 2, step = Math.ceil((v * 4 + 4) / (n * 2 - 2)) * 2, pos = [6];
            for (let p = size - 7; pos.length < n; p -= step) pos.splice(1, 0, p);
            pos.forEach((a, i) => pos.forEach((b, j) => { if (!(i === 0 && j === 0 || i === 0 && j === n - 1 || i === n - 1 && j === 0)) for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(a + dx, b + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1); }));
        }
        const format = () => {
            const d = 1 << 3 | 0; let rem = d; for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
            const bits = (d << 10 | rem) ^ 0x5412, g = (i) => ((bits >>> i) & 1) !== 0;
            for (let i = 0; i <= 5; i++) set(8, i, g(i));
            set(8, 7, g(6)); set(8, 8, g(7)); set(7, 8, g(8));
            for (let i = 9; i < 15; i++) set(14 - i, 8, g(i));
            for (let i = 0; i < 8; i++) set(size - 1 - i, 8, g(i));
            for (let i = 8; i < 15; i++) set(8, size - 15 + i, g(i));
            set(8, size - 8, true);
        };
        format();
        if (v >= 7) { let rem = v; for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1F25); const bits = v << 12 | rem; for (let i = 0; i < 18; i++) { const b = ((bits >>> i) & 1) !== 0, a = size - 11 + i % 3, c = Math.floor(i / 3); set(a, c, b); set(c, a, b); } }
        let i = 0;
        for (let right = size - 1; right >= 1; right -= 2) {
            if (right === 6) right = 5;
            for (let vert = 0; vert < size; vert++) for (let j = 0; j < 2; j++) {
                const x = right - j, up = ((right + 1) & 2) === 0, y = up ? size - 1 - vert : vert;
                if (!fn[y][x] && i < all.length * 8) { mod[y][x] = ((all[i >>> 3] >>> (7 - (i & 7))) & 1) !== 0; i++; }
            }
        }
        for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) if (!fn[y][x] && (x + y) % 2 === 0) mod[y][x] = !mod[y][x];
        format();
        return mod;
    }
    // draws the code with a 4-module quiet zone inside a white square of side 'px'
    function draw(g, text, x, y, px) {
        const m = encode(text);
        g.fillStyle = "#fff"; g.fillRect(x, y, px, px);
        if (!m) return false;
        const n = m.length + 8, s = px / n;
        g.fillStyle = "#000";
        for (let r = 0; r < m.length; r++) for (let c = 0; c < m.length; c++) if (m[r][c]) g.fillRect(x + (c + 4) * s, y + (r + 4) * s, Math.ceil(s), Math.ceil(s));
        return true;
    }
    return { encode, draw };
})();
