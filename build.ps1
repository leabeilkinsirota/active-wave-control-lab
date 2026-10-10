# Builds the static lab website into .\site from .\_scrape\out (page content) and .\data (news).
# Usage:  powershell -ExecutionPolicy Bypass -File build.ps1
$root = $PSScriptRoot
$site = Join-Path $root 'site'
$out  = Join-Path $root '_scrape\out'
$enc  = New-Object Text.UTF8Encoding($false)

function Esc($s) { [Net.WebUtility]::HtmlEncode($s) }
function ImgFile($id) { 'images/' + ($id -replace '~mv2', '') }
# Picture tag; Wix videos appear in the scrape as their poster frame (<id>f000.jpg) and play from videos/<id>.mp4
function FigTag($id, $lnk) {
  $v = $id -replace 'f000\.jpg$', ''
  if ($v -ne $id -and (Test-Path (Join-Path $site "videos/$v.mp4"))) {
    return '<video src="videos/' + $v + '.mp4" poster="' + (ImgFile $id) + '" autoplay muted loop playsinline preload="metadata"></video>'
  }
  $tag = '<img src="' + (ImgFile $id) + '" alt="" loading="lazy">'
  if ($lnk) { $tag = '<a href="' + (Esc $lnk) + '" target="_blank" rel="noopener">' + $tag + '</a>' }
  $tag
}

# inline text: [label](url) -> <a>, everything else escaped
function Inline($s) {
  $parts = [regex]::Split($s, '(\[[^\]]*\]\([^)]*\))')
  $o = ''
  foreach ($p in $parts) {
    if ($p -match '^\[([^\]]*)\]\(([^)]*)\)$') {
      $label = $Matches[1]; $u = $Matches[2]
      if ($u -match 'wix\.com/templateslp') { $o += (Esc $label); continue }
      $ext = if ($u -match '^https?://') { ' target="_blank" rel="noopener"' } else { '' }
      $o += '<a href="' + (Esc $u) + '"' + $ext + '>' + (Esc $label) + '</a>'
    } else { $o += (Esc $p) }
  }
  $o
}

$pages = @(
  @{ file = 'index.html';       title = 'Home';        src = 'home' },
  @{ file = 'research.html';    title = 'Research';    src = 'research' },
  @{ file = 'publications.html';title = 'Publications';src = 'publications' },
  @{ file = 'team.html';        title = 'Team';        src = 'people' },
  @{ file = 'lab-life.html';    title = 'Lab life';    src = 'copy-of-people' },
  @{ file = 'contact.html';     title = 'Contact';     src = 'contact' }
)
$topics = @(
  @{ file = 'topic-1.html'; src = 'topic-1' },
  @{ file = 'topic-2.html'; src = 'copy-of-topic-1' },
  @{ file = 'topic-3.html'; src = 'copy-of-topic-2' },
  @{ file = 'topic-4.html'; src = 'copy-of-topic-3' }
)

function Read-Outline($src) {
  Get-Content (Join-Path $out "$src.txt") -Encoding UTF8 | ForEach-Object { $_ -replace '[\p{Cf}\u00a0]', '' } | Where-Object { $_ -notmatch '^id="PAGES_CONTAINER"' -and $_ -notmatch '^<footer' -and $_ -ne '​' }
}

# Generic outline -> HTML (headings by font size, images grouped into rows)
function Convert-Outline($lines, $skipFirstTitle) {
  $html = New-Object Text.StringBuilder
  $imgs = New-Object Collections.ArrayList
  $flush = {
    if ($imgs.Count -gt 0) { [void]$html.AppendLine('<div class="figs">' + ($imgs -join '') + '</div>'); $imgs.Clear() }
  }
  $first = $true
  foreach ($l in $lines) {
    $size = 16
    if ($l -match '^\{S:(\d+)\}(.*)$') { $size = [int]$Matches[1]; $l = $Matches[2] }
    $l = $l.Trim()
    if (-not $l) { continue }
    if ($l -match '^\[?\[IMG:([^|\]]+)\|[^\]]*\]\]?(\(([^)]*)\))?$') {
      [void]$imgs.Add((FigTag $Matches[1] $Matches[3])); continue
    }
    & $flush
    if (($l -in @('Positions', 'Sayan')) -or ($l.Length -le 2) -or (($l -match '^[\w.%()-]+$') -and ($l -match '[_0-9]') -and ($l -notmatch '\s'))) { continue }
    if ($l -match '^\[(.{130,}?)\]\(([^)]*)\)$') { $body_ = $Matches[1] -replace '\s*Read more\.?\s*$', ''; $l = $body_ + ' [Read more]('+ $Matches[2] + ')' }
    $plain = [regex]::Replace($l, '\[([^\]]*)\]\([^)]*\)', '$1')
    if ($plain.Length -gt 130 -or $size -lt 20) { [void]$html.AppendLine('<p>' + (Inline $l) + '</p>'); continue }
    if ($size -ge 40) { if ($first -and $skipFirstTitle) { $first = $false; continue }; [void]$html.AppendLine('<h2>' + (Inline $l) + '</h2>') }
    elseif ($size -ge 30) { [void]$html.AppendLine('<h3>' + (Inline $l) + '</h3>') }
    elseif ($size -ge 24) { [void]$html.AppendLine('<h4>' + (Inline $l) + '</h4>') }
    else { [void]$html.AppendLine('<p class="cap">' + (Inline $l) + '</p>') }
    $first = $false
  }
  & $flush
  $html.ToString()
}

# Aspect ratio of a downloaded image (for the collage layout)
Add-Type -AssemblyName System.Drawing
$script:arCache = @{}
function ImgAR($id) {
  $f = Join-Path $site (ImgFile $id)
  if (-not $script:arCache.ContainsKey($f)) {
    $ar = 1.5
    if (Test-Path $f) { try { $im = [Drawing.Image]::FromFile($f); $ar = [Math]::Round($im.Width / $im.Height, 3); $im.Dispose() } catch {} }
    $script:arCache[$f] = $ar
  }
  $script:arCache[$f]
}

# Picture rows for one project. All sizes are fractions of the picture column width W:
# every picture in a row has the same height and a full row spans W exactly; a shorter last row
# keeps the height of the row above (centred). The row split is chosen so that row heights stay
# close to 0.42 W (smaller rows cost more than larger ones; with several rows none is taller than 0.55 W) and the pictures are not much taller than the text.
function Layout-Figs($figs, $textH, $split) {
  $n = $figs.Count; if ($n -eq 0) { return '' }
  $g = 0.016; $h0 = 0.42
  $best = $null; $bestCost = [double]::MaxValue
  for ($mask = 0; $mask -lt [Math]::Pow(2, $n - 1); $mask++) {
    $rows = @(); $cur = @()
    for ($k = 0; $k -lt $n; $k++) { $cur += $k; if ($k -lt $n - 1 -and ($mask -band (1 -shl $k))) { $rows += , $cur; $cur = @() } }
    $rows += , $cur
    if (@($rows | Where-Object { $_.Count -gt 3 }).Count) { continue }
    if ($split -and ((@($rows | ForEach-Object { $_.Count }) -join ',') -ne ($split -join ','))) { continue }   # fixed row split for this project
    $hs = @(); $cost = 0; $prevH = 0; $prevN = 0
    for ($r = 0; $r -lt $rows.Count; $r++) {
      $sum = 0; foreach ($k in $rows[$r]) { $sum += $figs[$k].ar }
      $rh = (1 - $g * ($rows[$r].Count - 1)) / $sum
      if ($r -gt 0 -and $r -eq $rows.Count - 1 -and $rows[$r].Count -lt $prevN -and $rh -gt $prevH) { $rh = $prevH }
      $cost += $(if ($rh -lt $h0) { 1 } else { 0.3 }) * [Math]::Pow([Math]::Log($rh / $h0), 2)   # small pictures are worse than large ones
      if ($rows.Count -gt 1) { $rh = [Math]::Min($rh, 0.55) }   # display cap: with several rows, no row dominates (a lone picture still fills the column)
      $hs += $rh; $prevH = $rh; $prevN = $rows[$r].Count
    }
    $tot = ($hs | Measure-Object -Sum).Sum + $g * ($rows.Count - 1)
    if ($tot -gt 1.3 * $textH) { $cost += [Math]::Pow([Math]::Log($tot / (1.3 * $textH)), 2) }   # text wraps below, so mild
    if ($cost -lt $bestCost) { $bestCost = $cost; $best = @{ rows = $rows; hs = $hs } }
  }
  # rows of several pictures share one height (the smallest), so no group of pictures looks oversized next to another
  $multi = @(0..($best.rows.Count - 1) | Where-Object { $best.rows[$_].Count -gt 1 })
  if ($multi.Count -gt 1) {
    $hmin = ($multi | ForEach-Object { $best.hs[$_] } | Measure-Object -Minimum).Minimum
    foreach ($r in $multi) { $best.hs[$r] = $hmin }
  }
  $html = ''
  for ($r = 0; $r -lt $best.rows.Count; $r++) {
    $html += '<div class="frow" style="--h:' + [Math]::Round($best.hs[$r], 4) + '">'
    foreach ($k in $best.rows[$r]) { $html += ($figs[$k].tag -replace '^<(figure|a|img|video)', ('<$1 style="--ar:' + [Math]::Round($figs[$k].ar * $figs[$k].s, 3) + '"')) }
    $html += '</div>'
  }
  $html
}

# Research page: one block per project, pictures floated right with the text wrapping around them
# Pictures left out of the Research page
$skipImgs = @('c1fe2f_affb91702dd140d6b065eaaa55480178')   # gravitational lensing: funnel potential
# Pictures shown smaller than their row height (unit-cell sketches etc.); the row is laid out at full size, then shrinks and is centred
$imgScale = @{ 'c1fe2f_0f7ba6f18c864b8883195429b988346d' = 0.63; 'c1fe2f_77610aaac52f40499d1f95780868e4ad' = 0.85   # Haldane unit cell, 3 controlled cells
              'c1fe2f_cbb4c1fbb74d41ea8eb433c65b4ee650' = 1.15 }   # quiet channel system sketch
# Fixed row split for a project (key = its first picture): number of pictures per row
$rowSplit = @{ 'c1fe2f_cbb4c1fbb74d41ea8eb433c65b4ee650' = @(1, 3) }   # quiet channel: system on top, 3 snapshots below
# Pictures moved to the end of their project (own row below the others)
$moveLast = @('c1fe2f_d3b19acc8c4c433b916e56274a27ab48')   # topological lattice animation
# Project titles missing on the Wix page: title inserted before the paragraph starting with the key
$addTitles = @{ 'We realized active autonomous guiding of topological sound beams' = 'Real-time steering of curved sound beams in a feedback-based topological acoustic metamaterial' }
function Convert-Projects($lines) {
  $o = New-Object Text.StringBuilder
  $title = $null; $txt = ''; $figs = New-Object Collections.ArrayList; $caps = New-Object Collections.ArrayList
  $emit = {
    if ($title) {
      # captions belong to the pictures in order; shown under each picture
      for ($k = 0; $k -lt [Math]::Min($caps.Count, $figs.Count); $k++) { $figs[$k].tag = '<figure>' + $figs[$k].tag + '<figcaption>' + $caps[$k] + '</figcaption></figure>' }
      if ($caps.Count) { Write-Host ("  captions in '{0}': {1}" -f $title.Substring(0, [Math]::Min(30, $title.Length)), ($caps -join ' | ')) }
      # rough text height in units of the picture column width (text beside the pictures: ~62 chars per 24px line)
      $plainTxt = [regex]::Replace($txt, '<[^>]+>', '')
      $npar = ([regex]::Matches($txt, '<p>')).Count
      $textH = (($plainTxt.Length / 62) * 24 + $npar * 10) / 455
      $figs = @($figs | Where-Object { $_.id -notin $moveLast }) + @($figs | Where-Object { $_.id -in $moveLast })
      [void]$o.AppendLine('<section class="proj"><h3>' + $title + '</h3><div class="pfig">' + (Layout-Figs $figs $textH $(if ($figs.Count) { $rowSplit[$figs[0].id] })) + '</div><div class="ptxt">' + $txt + '</div></section>')
    }
  }
  foreach ($l in $lines) {
    $size = 16
    if ($l -match '^\{S:(\d+)\}(.*)$') { $size = [int]$Matches[1]; $l = $Matches[2] }
    $l = $l.Trim()
    if (-not $l) { continue }
    if ($l -match '^\[?\[IMG:([^|\]]+)\|[^\]]*\]\]?(\(([^)]*)\))?$') {
      $id = $Matches[1]; $lnk = $Matches[3]
      $key = $id -replace '(~mv2.*|f000\.jpg)$', ''
      if ($key -in $skipImgs) { continue }
      $ar = ImgAR $id
      $s = if ($imgScale.ContainsKey($key)) { $imgScale[$key] } else { 1 }
      $tag = FigTag $id $lnk
      [void]$figs.Add(@{ tag = $tag; ar = $ar; s = $s; id = $key }); continue
    }
    foreach ($k in $addTitles.Keys) { if ($l.StartsWith($k)) { & $emit; $title = Esc $addTitles[$k]; $txt = ''; $figs = New-Object Collections.ArrayList } }
    if (($l -in @('Positions', 'Sayan')) -or ($l.Length -le 2) -or (($l -match '^[\w.%()-]+$') -and ($l -match '[_0-9]') -and ($l -notmatch '\s'))) { continue }
    if ($l -match '^\[(.{130,}?)\]\(([^)]*)\)$') { $bt = $Matches[1] -replace '\s*Read more\.?\s*$', ''; $l = $bt + ' [Read more](' + $Matches[2] + ')' }
    $plain = [regex]::Replace($l, '\[([^\]]*)\]\([^)]*\)', '$1')
    if ($size -ge 30 -and $plain.Length -le 130) { & $emit; $title = Inline $l; $txt = ''; $figs = New-Object Collections.ArrayList; $caps = New-Object Collections.ArrayList; continue }
    # short lines inside a project are picture captions (e.g. "M<0, K=0."), not text
    if ($plain.Length -le 60 -and $title) { [void]$caps.Add((Inline ($l -replace '\.$', ''))); continue }
    # Wix split some paragraphs mid-sentence around the pictures: a piece starting in lowercase continues the previous one
    if ($l -cmatch '^[a-z]' -and $txt.EndsWith('</p>')) { $txt = $txt.Substring(0, $txt.Length - 4) + ' ' + (Inline $l) + '</p>' }
    else { $txt += '<p>' + (Inline $l) + '</p>' }
  }
  & $emit
  $o.ToString()
}
# ---------- shared chrome ----------
$menu = @(
  @{ f = 'index.html'; t = 'Home' }, @{ f = 'research.html'; t = 'Research' }, @{ f = 'publications.html'; t = 'Publications' },
  @{ f = 'team.html'; t = 'Team' }, @{ f = 'lab-life.html'; t = 'Lab life' }, @{ f = 'contact.html'; t = 'Contact' }
)
$topicTitles = @()
foreach ($t in $topics) {
  $first = (Read-Outline $t.src | Select-Object -First 1) -replace '^\{S:\d+\}', ''
  $topicTitles += @{ f = $t.file; t = $first }
}
function Chrome-Top($active, $pageTitle) {
  $nav = ''
  foreach ($m in $menu) {
    $cls = if ($m.f -eq $active) { ' class="on"' } else { '' }
    if ($m.t -eq 'Research') {
      $sub = ($topicTitles | ForEach-Object { '<a href="' + $_.f + '">' + (Esc $_.t) + '</a>' }) -join ''
      $nav += '<div class="dd"><a' + $cls + ' href="' + $m.f + '">' + $m.t + '</a><div class="ddm">' + $sub + '</div></div>'
    } else { $nav += '<a' + $cls + ' href="' + $m.f + '">' + $m.t + '</a>' }
  }
  @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(Esc $pageTitle) | Active Wave Control Lab</title>
<meta name="description" content="Active Wave Control Lab, School of Mechanical Engineering, Tel Aviv University: active control of wave propagation in metamaterials and open acoustic environments.">
<link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=Open+Sans:wght@300;400;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="style.css"></head><body>
<header class="banner"><h1>Active Wave Control Lab</h1></header>
<nav class="menu">$nav</nav>
<main>
"@
}
$footer = @"
</main>
<footer>
<hr>
<div class="inst"><img src="images/c1fe2f_1fbeb8481adb4920a88a78e52d2930b6.png" alt="Tel Aviv University"><p>School of Mechanical Engineering<br>The Iby and Aladar Fleischman Faculty of Engineering<br>Tel Aviv University</p></div>
<div class="funders">
<a href="https://isf.org.il/#/" target="_blank" rel="noopener"><img src="images/c1fe2f_80198b619a104773a049620936e7af68.jpg" alt="Israel Science Foundation"></a>
<a href="https://www.pazyfoundation.org.il/" target="_blank" rel="noopener"><img src="images/c1fe2f_e8bc55baf8c24b1fa501f40504e478f6.jpg" alt="Pazy Foundation"></a>
<a href="https://innovationisrael.org.il/en/" target="_blank" rel="noopener"><img src="images/c1fe2f_66663232a26245138f2722d760e0542e.png" alt="Israel Innovation Authority"></a>
</div></footer></body></html>
"@

# ---------- news ----------
$news = Get-Content (Join-Path $root 'data\news.json') -Raw -Encoding UTF8 | ConvertFrom-Json | Sort-Object sort -Descending | Select-Object -First 10
$newsHtml = '<ul class="news">'
$i = 0
foreach ($n in $news) {
  $i++
  $txt = if ($n.link) { '<a href="' + (Esc $n.link) + '" target="_blank" rel="noopener">' + (Esc $n.text) + '</a>' } else { Esc $n.text }
  $hide = if ($i -gt 4) { ' class="more" hidden' } else { '' }
  $newsHtml += "<li$hide><span class=""d"">$(Esc $n.date)</span><span>$txt</span></li>"
}
$newsHtml += '</ul>'
if (@($news).Count -gt 4) { $newsHtml += '<p class="morebtn"><button type="button" id="showmore">Show more news</button></p>' }
$newsJs = '<script>var b=document.getElementById("showmore");if(b){var open=false;b.addEventListener("click",function(){open=!open;document.querySelectorAll("li.more").forEach(function(e){e.hidden=!open});b.textContent=open?"Show less news":"Show more news";});}</script>'

# ---------- write pages ----------
New-Item -ItemType Directory -Force $site | Out-Null
function Write-Page($file, $active, $title, $body, $extra = '') {
  [IO.File]::WriteAllText((Join-Path $site $file), (Chrome-Top $active $title) + $body + $footer.Replace('</body>', $extra + '</body>'), $enc)
}

# Home
$h = Read-Outline 'home'
$intro = ($h | Where-Object { $_ -like 'We are interested*' } | Select-Object -First 1) -replace 'Read More\.$', '[Read More.](research.html)'
$homeHtml = '<section class="intro"><p>' + (Inline $intro) + '</p><img class="hero" src="images/c1fe2f_29825e2f1e2f4abc966e0eb971645ed7.png" alt="Active control of wave propagation: acoustic illusion and mimicking quantum wave phenomena"></section>'
$homeHtml += '<section class="band join"><h2>JOIN US!</h2><p><a class="btn" href="contact.html">Find out about available positions in our lab</a></p></section>'
$homeHtml += '<section class="band"><h2>Latest News</h2>' + $newsHtml + '</section>'
Write-Page 'index.html' 'index.html' 'Home' $homeHtml $newsJs

# Generic pages
foreach ($p in $pages | Where-Object { $_.src -in 'research', 'publications', 'contact' }) {
  $lines = Read-Outline $p.src
  if ($p.src -eq 'publications') {
    $body = '<h2>Publications</h2><ol class="pubs">' + (($lines | ForEach-Object { $_ -replace '^\{S:\d+\}','' } | Where-Object { $_ -match '^\[' } | ForEach-Object { '<li>' + (Inline $_) + '</li>' }) -join '') + '</ol>'
  } elseif ($p.src -eq 'research') { $body = Convert-Projects $lines }
  else { $body = Convert-Outline $lines $false }
  if ($p.src -eq 'research') { $body = '<h2>Research</h2>' + $body }
  if ($p.src -eq 'contact') { $body = '<h2>Contact</h2>' + $body }
  Write-Page $p.file $p.file $p.title $body
}

# Team: sections, with photo cards
$lines = Read-Outline 'people'
$body = '<h2>Team</h2>'
$card = $null
$flushCard = { if ($script:card) { $script:body += '<div class="card">' + $script:card + '</div></div>'; $script:card = $null } }
foreach ($l in $lines) {
  $size = 16; if ($l -match '^\{S:(\d+)\}(.*)$') { $size = [int]$Matches[1]; $l = $Matches[2] }
  $l = $l.Trim(); if (-not $l -or $l -eq 'Sayan') { continue }
  if ($l -match '^\[IMG:([^|\]]+)\|') { & $flushCard; $card = '<img class="ph" src="' + (ImgFile $Matches[1]) + '" alt=""><div class="txt">'; $cardOpen = $true; continue }
  if ($l -match '^(Principal Investigator|Research Scientists|Postdoctoral Fellows|Students|Alumni)') { & $flushCard; $body += '<h3>' + (Inline $l) + '</h3>'; continue }
  if ($card) {
    if ($l -notmatch '^\[' -and $card -notmatch '<h4>') { $card += '<h4>' + (Inline $l) + '</h4>' } else { $card += '<p>' + (Inline $l) + '</p>' }
  } else { $body += '<p class="alumni">' + (Inline $l) + '</p>' }
}
& $flushCard
$body = $body.Replace('</div></div>', '</div></div>')
Write-Page 'team.html' 'team.html' 'Team' $body

# Lab life
Write-Page 'lab-life.html' 'lab-life.html' 'Lab life' ('<h2>Lab life</h2>' + (Convert-Outline (Read-Outline 'copy-of-people') $false))

# Topics
foreach ($t in $topics) {
  $lines = @(Read-Outline $t.src)
  $title = ($lines[0] -replace '^\{S:\d+\}', '')
  $b = '<p class="crumb"><a href="research.html">&larr; Research</a></p>' + (Convert-Outline $lines $false)
  Write-Page $t.file 'research.html' $title $b
}
"Built {0} pages into {1}" -f ($pages.Count + $topics.Count), $site

# Redirect stubs so old Wix URLs keep working
$redirects = @{ 'people.html' = 'team.html'; 'copy-of-people.html' = 'lab-life.html'; 'copy-of-topic-1.html' = 'topic-2.html'; 'copy-of-topic-2.html' = 'topic-3.html'; 'copy-of-topic-3.html' = 'topic-4.html' }
foreach ($k in $redirects.Keys) {
  $to = $redirects[$k]
  [IO.File]::WriteAllText((Join-Path $site $k), "<!doctype html><meta charset=""utf-8""><title>Redirecting</title><link rel=""canonical"" href=""$to""><meta http-equiv=""refresh"" content=""0; url=$to""><p>Moved to <a href=""$to"">$to</a>.</p>", $enc)
}
