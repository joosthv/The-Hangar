param([int]$Port = 8766, [string]$Root = (Join-Path $PSScriptRoot "mock"))
# Mock GitHub for the hangar tests: serves files under $Root, answers the release-asset API (/api/assetapi/<name>) with a
# redirect to the file host (/dl/<name>) like GitHub does, and logs whether each request carried a token.
$l = New-Object System.Net.HttpListener
$l.Prefixes.Add("http://localhost:$Port/")
$l.Start()
while ($l.IsListening) {
    $ctx = $l.GetContext()
    $p = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath.TrimStart('/'))
    $auth = if ($ctx.Request.Headers['Authorization']) { 'auth' } else { 'noauth' }
    Add-Content (Join-Path $Root 'requests.log') "$p $auth"
    if ($p -like 'api/assetapi/*') {
        $ctx.Response.StatusCode = 302
        $ctx.Response.RedirectLocation = "http://localhost:$Port/dl/" + $p.Substring(13)
        $ctx.Response.Close()
        continue
    }
    $f = Join-Path $Root $p
    if (Test-Path $f -PathType Leaf) { $b = [IO.File]::ReadAllBytes($f); $ctx.Response.OutputStream.Write($b, 0, $b.Length) } else { $ctx.Response.StatusCode = 404 }
    $ctx.Response.Close()
}
