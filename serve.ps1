# Minimal static file server using HttpListener
# Serves files from the script folder on http://127.0.0.1:8000/

$root = $PSScriptRoot
$prefix = "http://127.0.0.1:8000/"

function Get-MimeType([string]$path) {
    switch ([IO.Path]::GetExtension($path).ToLower()) {
        '.html' { 'text/html' }
        '.htm'  { 'text/html' }
        '.js'   { 'application/javascript' }
        '.css'  { 'text/css' }
        '.json' { 'application/json' }
        '.jsonl'{ 'application/json' }
        '.txt'  { 'text/plain' }
        '.png'  { 'image/png' }
        '.jpg'  { 'image/jpeg' }
        '.jpeg' { 'image/jpeg' }
        '.gif'  { 'image/gif' }
        default { 'application/octet-stream' }
    }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Error "Failed to start HTTP listener on $prefix. Try running as admin or choose another port."
    exit 1
}
Write-Output "Serving '$root' on $prefix (press Ctrl+C to stop or use monitor.bat -> Stop)."

while ($listener.IsListening) {
    try {
        $context = $listener.GetContext()
        $req = $context.Request
        $resp = $context.Response

        # map URL path to file; default to dashboard.html
        $rawPath = $req.Url.AbsolutePath.TrimStart('/')
        if ([string]::IsNullOrEmpty($rawPath)) { $rawPath = 'dashboard.html' }

        # remove leading .. or invalid segments
        $safePath = [IO.Path]::GetFullPath((Join-Path $root $rawPath))
        if (-not $safePath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            $resp.StatusCode = 403
            $buf = [Text.Encoding]::UTF8.GetBytes('Forbidden')
            $resp.OutputStream.Write($buf,0,$buf.Length)
            $resp.Close()
            continue
        }

        if (-not (Test-Path $safePath)) {
            $resp.StatusCode = 404
            $buf = [Text.Encoding]::UTF8.GetBytes('Not found')
            $resp.OutputStream.Write($buf,0,$buf.Length)
            $resp.Close()
            continue
        }

        $bytes = [IO.File]::ReadAllBytes($safePath)
        $resp.ContentType = Get-MimeType $safePath
        $resp.ContentLength64 = $bytes.Length
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
        $resp.OutputStream.Close()
    } catch [System.Net.HttpListenerException] {
        break
    } catch {
        # ignore individual request errors
    }
}

$listener.Stop()
$listener.Close()