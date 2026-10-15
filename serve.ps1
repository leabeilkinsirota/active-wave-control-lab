# Tiny local web server for previewing .\site at http://localhost:8080/
# Each request is served on its own thread (a browser holding a video connection open must not block the pictures);
# files are sent in ranges of at most 1 MB when the browser asks for a range (videos).
param([int]$Port = 8080)
$root = Join-Path $PSScriptRoot 'site'
$l = New-Object Net.HttpListener; $l.Prefixes.Add("http://localhost:$Port/"); $l.Start()
$pool = [RunspaceFactory]::CreateRunspacePool(1, 16); $pool.Open()
$serve = {
  param($c, $root)
  $mime = @{ '.html'='text/html; charset=utf-8'; '.css'='text/css'; '.js'='application/javascript'; '.png'='image/png'; '.jpg'='image/jpeg'; '.jpeg'='image/jpeg'; '.svg'='image/svg+xml'; '.mp4'='video/mp4'; '.pdf'='application/pdf' }
  try {
    $p = [Uri]::UnescapeDataString($c.Request.Url.AbsolutePath.TrimStart('/')); if (-not $p) { $p = 'index.html' }
    $f = Join-Path $root $p
    if (Test-Path $f -PathType Leaf) {
      $e = [IO.Path]::GetExtension($f).ToLower()
      $c.Response.ContentType = $(if ($mime[$e]) { $mime[$e] } else { 'application/octet-stream' })
      $c.Response.AddHeader('Accept-Ranges', 'bytes')
      $fs = [IO.File]::OpenRead($f)
      try {
        $len = $fs.Length; $from = 0; $to = $len - 1
        $range = $c.Request.Headers['Range']
        if ($range -match '^bytes=(\d*)-(\d*)$') {
          $a = $Matches[1]; $b = $Matches[2]
          if ($a -ne '') { $from = [long]$a; if ($b -ne '') { $to = [Math]::Min([long]$b, $len - 1) } }
          elseif ($b -ne '') { $from = [Math]::Max(0, $len - [long]$b) }
          $to = [Math]::Min($to, $from + 1MB - 1)
          $c.Response.StatusCode = 206
          $c.Response.AddHeader('Content-Range', "bytes $from-$to/$len")
        }
        $n = $to - $from + 1
        $c.Response.ContentLength64 = $n
        $buf = New-Object byte[] $n
        [void]$fs.Seek($from, 'Begin'); [void]$fs.Read($buf, 0, $n)
        $c.Response.OutputStream.Write($buf, 0, $n)
      } finally { $fs.Dispose() }
    } else { $c.Response.StatusCode = 404 }
  } catch {}   # browser closed the connection early: ignore
  try { $c.Response.Close() } catch {}
}
$jobs = New-Object Collections.ArrayList
while ($l.IsListening) {
  $c = $l.GetContext()
  $ps = [PowerShell]::Create(); $ps.RunspacePool = $pool
  [void]$ps.AddScript($serve).AddArgument($c).AddArgument($root)
  [void]$jobs.Add(@{ ps = $ps; h = $ps.BeginInvoke() })
  foreach ($j in @($jobs)) { if ($j.h.IsCompleted) { $j.ps.Dispose(); $jobs.Remove($j) } }   # clean up finished requests
}
