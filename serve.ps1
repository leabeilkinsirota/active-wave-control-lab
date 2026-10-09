# Tiny local web server for previewing .\site at http://localhost:8080/
param([int]$Port = 8080)
$root = Join-Path $PSScriptRoot 'site'
$l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$Port/"); $l.Start()
$mime = @{ '.html'='text/html; charset=utf-8'; '.css'='text/css'; '.js'='application/javascript'; '.png'='image/png'; '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'; '.svg'='image/svg+xml' }
while ($l.IsListening) {
  $c = $l.GetContext(); $p = [Uri]::UnescapeDataString($c.Request.Url.AbsolutePath.TrimStart('/')); if (-not $p) { $p = 'index.html' }
  $f = Join-Path $root $p
  if (Test-Path $f -PathType Leaf) { $b = [IO.File]::ReadAllBytes($f); $e = [IO.Path]::GetExtension($f).ToLower(); $c.Response.ContentType = $(if ($mime[$e]) { $mime[$e] } else { 'application/octet-stream' }); $c.Response.OutputStream.Write($b, 0, $b.Length) } else { $c.Response.StatusCode = 404 }
  $c.Response.Close()
}
