// Weather for the Jetstream Virtual hangars: the METAR of each hangar airfield (aviationweather.gov) and the feed of its
// cloud layers into the sim, for the hangar's weather board (the sim itself has no cloud layers for scenery to read).
//   Metar   - fetched every 5 minutes (settings: metarStations "KFHR", metarUrl with {ids}); GET /api/metar
//   SimFeed - while MSFS runs: SimConnect (native SimConnect.dll, embedded in the exe and written to DataDir\bin; a copy
//             next to the exe, the simConnectDll setting or the MSFS SDK go first / last) writes
//             L:JV_WX_VALID (1 = METAR younger than 2 h), L:JV_WX_AGE (minutes), L:JV_WX_C1..3_COVER
//             (0 none, 1 FEW, 2 SCT, 3 BKN, 4 OVC, 5 VV) and L:JV_WX_C1..3_BASE (hundreds of feet, as in the METAR)
//             every 15 s. L-vars are global, so the hangar's door object (the board) reads them.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Threading;

static class Metar
{
    static readonly object gate = new object();
    static Dictionary<string, object> latest;     // station, raw, obsTime (unix s), layers [[cover, base100]], fetched
    static DateTime fetchedAt = DateTime.MinValue;
    static string error = "";

    public static string Station { get { var s = Settings.Get("metarStations"); return s.Length > 0 ? s.Split(',')[0].Trim().ToUpperInvariant() : "KFHR"; } }
    static string Url { get { var u = Settings.Get("metarUrl"); return (u.Length > 0 ? u : "https://aviationweather.gov/api/data/metar?ids={ids}&format=json").Replace("{ids}", Station); } }

    public static int CoverCode(string c)
    {
        switch ((c ?? "").ToUpperInvariant()) { case "FEW": return 1; case "SCT": return 2; case "BKN": return 3; case "OVC": return 4; case "VV": case "OVX": return 5; default: return 0; }
    }

    // parse the aviationweather.gov JSON (an array of reports); the report of the station, or null
    public static Dictionary<string, object> Parse(string json, string station)
    {
        var arr = Hangar.Json.DeserializeObject(json) as object[];
        if (arr == null) return null;
        foreach (var o in arr)
        {
            var r = o as Dictionary<string, object>; if (r == null) continue;
            if (!string.Equals(Convert.ToString(r.ContainsKey("icaoId") ? r["icaoId"] : ""), station, StringComparison.OrdinalIgnoreCase)) continue;
            var layers = new List<object>();
            if (r.ContainsKey("clouds") && r["clouds"] is object[])
                foreach (var c in (object[])r["clouds"])
                {
                    var cd = c as Dictionary<string, object>; if (cd == null) continue;
                    int cover = CoverCode(Convert.ToString(cd.ContainsKey("cover") ? cd["cover"] : ""));
                    if (cover == 0) continue;
                    double baseFt = cd.ContainsKey("base") && cd["base"] != null ? Convert.ToDouble(cd["base"], CultureInfo.InvariantCulture) : 0;
                    layers.Add(new object[] { cover, Math.Round(baseFt / 100) });
                    if (layers.Count == 3) break;
                }
            double obs = r.ContainsKey("obsTime") && r["obsTime"] != null ? Convert.ToDouble(r["obsTime"], CultureInfo.InvariantCulture) : 0;
            return new Dictionary<string, object> { { "station", station }, { "raw", Convert.ToString(r.ContainsKey("rawOb") ? r["rawOb"] : "") }, { "obsTime", obs }, { "layers", layers.ToArray() } };
        }
        return null;
    }

    public static void FetchIfDue(bool force)
    {
        lock (gate) if (!force && DateTime.UtcNow - fetchedAt < TimeSpan.FromSeconds(Settings.GetInt("metarSeconds", 300))) return;
        try
        {
            string json;
            using (var wc = new WebClient()) { wc.Headers["User-Agent"] = Hangar.AppName + " " + Hangar.AppVersion; wc.Encoding = System.Text.Encoding.UTF8; json = wc.DownloadString(Url); }
            var m = Parse(json, Station);
            lock (gate) { latest = m; fetchedAt = DateTime.UtcNow; error = m == null ? "No METAR for " + Station : ""; }
        }
        catch (Exception e) { lock (gate) { fetchedAt = DateTime.UtcNow; error = "METAR: " + e.Message; } Hangar.Log("metar: " + e.Message); }
    }

    public static double AgeMinutes(Dictionary<string, object> m)
    {
        double obs = m == null ? 0 : Convert.ToDouble(m["obsTime"], CultureInfo.InvariantCulture);
        return obs <= 0 ? 9999 : Math.Max(0, (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(obs)).TotalMinutes);
    }

    // the values written to the sim, in L-var order: valid, age, (cover, base) x 3
    public static double[] SimValues()
    {
        Dictionary<string, object> m; lock (gate) m = latest;
        var v = new double[8];
        double age = AgeMinutes(m);
        v[0] = m != null && age < 120 ? 1 : 0; v[1] = Math.Min(999, Math.Round(age));
        if (m != null) { var ls = (object[])m["layers"]; for (int i = 0; i < ls.Length && i < 3; i++) { var l = (object[])ls[i]; v[2 + 2 * i] = Convert.ToDouble(l[0]); v[3 + 2 * i] = Convert.ToDouble(l[1]); } }
        return v;
    }

    public static Dictionary<string, object> Status()
    {
        lock (gate)
        {
            var d = new Dictionary<string, object> { { "station", Station }, { "error", error }, { "simFeed", SimFeed.State }, { "simConnectDll", SimFeed.DllPath } };
            if (latest != null) { d["raw"] = latest["raw"]; d["layers"] = latest["layers"]; d["ageMinutes"] = Math.Round(AgeMinutes(latest)); }
            d["simValues"] = SimValues();
            return d;
        }
    }
}

static class SimFeed
{
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr LoadLibrary(string path);
    [DllImport("SimConnect.dll")] static extern int SimConnect_Open(out IntPtr h, string name, IntPtr hWnd, uint userEvent, IntPtr hEvent, uint configIndex);
    [DllImport("SimConnect.dll")] static extern int SimConnect_Close(IntPtr h);
    [DllImport("SimConnect.dll")] static extern int SimConnect_AddToDataDefinition(IntPtr h, uint defineId, string datum, string units, int datumType, float epsilon, uint datumId);
    [DllImport("SimConnect.dll")] static extern int SimConnect_SetDataOnSimObject(IntPtr h, uint defineId, uint objectId, uint flags, uint arrayCount, uint unitSize, IntPtr data);
    [DllImport("SimConnect.dll")] static extern int SimConnect_GetNextDispatch(IntPtr h, out IntPtr data, out uint size);

    static readonly string[] Vars = { "L:JV_WX_VALID", "L:JV_WX_AGE", "L:JV_WX_C1_COVER", "L:JV_WX_C1_BASE", "L:JV_WX_C2_COVER", "L:JV_WX_C2_BASE", "L:JV_WX_C3_COVER", "L:JV_WX_C3_BASE" };
    const int Float64 = 4; const uint DefWx = 1, UserObject = 0, Unused = 0xFFFFFFFF;
    public static string State = "starting";
    static IntPtr handle = IntPtr.Zero;
    static bool dllLoaded;

    public static string DllPath = "";

    // the copy embedded by build.ps1 (resource native.SimConnect.dll), written to DataDir\bin when missing or different
    public static string ExtractDll()
    {
        using (var s = System.Reflection.Assembly.GetExecutingAssembly().GetManifestResourceStream("native.SimConnect.dll"))
        {
            if (s == null) return null;
            var ms = new MemoryStream(); s.CopyTo(ms); var data = ms.ToArray();
            var dir = Path.Combine(Hangar.DataDir, "bin"); var f = Path.Combine(dir, "SimConnect.dll");
            if (File.Exists(f) && File.ReadAllBytes(f).SequenceEqual(data)) return f;
            if (dllLoaded) return f;   // loaded from there already: replaced at the next start
            Directory.CreateDirectory(dir); File.WriteAllBytes(f, data);
            return f;
        }
    }

    // SimConnect.dll: next to the hangar, the setting, the embedded copy, else the MSFS 2024 SDK (developer machines)
    static string FindDll()
    {
        var cands = new List<string> { Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "SimConnect.dll"), Settings.Get("simConnectDll") };
        try { cands.Add(ExtractDll()); } catch (Exception e) { Hangar.Log("simfeed: extracting SimConnect.dll: " + e.Message); }
        var sdk = Environment.GetEnvironmentVariable("MSFS2024_SDK"); if (!string.IsNullOrEmpty(sdk)) cands.Add(Path.Combine(sdk, "SimConnect SDK", "lib", "SimConnect.dll"));
        cands.Add(@"C:\MSFS 2024 SDK\SimConnect SDK\lib\SimConnect.dll");
        return cands.FirstOrDefault(p => !string.IsNullOrEmpty(p) && File.Exists(p));
    }

    static void Disconnect() { if (handle != IntPtr.Zero) { try { SimConnect_Close(handle); } catch { } handle = IntPtr.Zero; } }

    public static void Loop()
    {
        Thread.Sleep(Settings.GetInt("startDelayMs", 3000));
        DllPath = FindDll() ?? "";
        while (true)
        {
            try { Tick(); } catch (Exception e) { State = "error: " + e.Message; Disconnect(); Hangar.Log("simfeed: " + e.Message); }
            Thread.Sleep(Settings.GetInt("simFeedSeconds", 15) * 1000);
        }
    }

    static void Tick()
    {
        if (Settings.Get("simFeed") == "off") { Disconnect(); State = "off (setting)"; return; }
        if (!Community.SimRunning()) { Disconnect(); State = "waiting for MSFS"; return; }
        Metar.FetchIfDue(false);
        if (!dllLoaded)
        {
            var dll = FindDll(); DllPath = dll ?? "";
            if (dll == null) { State = "SimConnect.dll not found"; return; }
            if (LoadLibrary(dll) == IntPtr.Zero) { State = "SimConnect.dll could not be loaded (" + Marshal.GetLastWin32Error() + ")"; return; }
            dllLoaded = true;
        }
        if (handle == IntPtr.Zero)
        {
            IntPtr h;
            int hr = SimConnect_Open(out h, Hangar.AppName, IntPtr.Zero, 0, IntPtr.Zero, 0);
            if (hr != 0 || h == IntPtr.Zero) { State = "MSFS not ready for SimConnect yet"; return; }
            handle = h;
            foreach (var v in Vars) SimConnect_AddToDataDefinition(handle, DefWx, v, "number", Float64, 0, Unused);
            Hangar.Log("simfeed: connected to MSFS");
        }
        IntPtr p; uint n; int guard = 0;
        while (guard++ < 100 && SimConnect_GetNextDispatch(handle, out p, out n) == 0) { }   // drain (exceptions, quit)
        var vals = Metar.SimValues();
        IntPtr buf = Marshal.AllocHGlobal(8 * vals.Length);
        try
        {
            Marshal.Copy(vals, 0, buf, vals.Length);
            int hr = SimConnect_SetDataOnSimObject(handle, DefWx, UserObject, 0, 0, (uint)(8 * vals.Length), buf);
            if (hr != 0) { State = "SimConnect write failed (0x" + hr.ToString("X8") + "), reconnecting"; Disconnect(); return; }
        }
        finally { Marshal.FreeHGlobal(buf); }
        State = vals[0] > 0 ? "feeding the " + Metar.Station + " METAR to the sim (" + vals[1] + " min old)" : "connected; no current METAR for " + Metar.Station;
    }
}
