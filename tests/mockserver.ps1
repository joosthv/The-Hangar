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
    # scripted Navigraph identity server: device code, one pending poll, then tokens; refresh rotates RT-n -> RT-(n+1);
    # a file "invalidgrant" in the mock root makes refreshes fail; request bodies are logged for the checks
    if ($p -like 'identity/connect/*') {
        $body = (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd()
        Add-Content (Join-Path $Root 'identity.log') "$p | $body"
        $status = 200; $json = '{}'
        if ($p -eq 'identity/connect/deviceauthorization') { $json = '{"device_code":"DEV1","user_code":"MOCKCODE","verification_uri":"https://navigraph.com/code","verification_uri_complete":"https://navigraph.com/code?user_code=MOCKCODE","expires_in":600,"interval":1}' }
        elseif ($p -eq 'identity/connect/userinfo') { $json = '{"preferred_username":"mockpilot"}' }
        elseif ($body -match 'grant_type=refresh_token') {
            if (Test-Path (Join-Path $Root 'invalidgrant')) { $status = 400; $json = '{"error":"invalid_grant"}' }
            else { $n = [int]([regex]::Match($body, 'refresh_token=RT-(\d+)').Groups[1].Value); $json = '{"access_token":"AT-' + ($n + 1) + '","refresh_token":"RT-' + ($n + 1) + '","expires_in":3600}' }
        }
        else {
            $cf = Join-Path $Root 'tokencount'; $k = 1; if (Test-Path $cf) { $k = [int](Get-Content $cf) + 1 }; Set-Content $cf $k
            if ($k -eq 1 -or (Test-Path (Join-Path $Root 'pending'))) { $status = 400; $json = '{"error":"authorization_pending"}' } else { $json = '{"access_token":"AT-1","refresh_token":"RT-1","expires_in":3600}' }
        }
        $b = [Text.Encoding]::UTF8.GetBytes($json); $ctx.Response.StatusCode = $status; $ctx.Response.ContentType = 'application/json'
        $ctx.Response.OutputStream.Write($b, 0, $b.Length); $ctx.Response.Close()
        continue
    }
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
