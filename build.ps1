# Builds the static lab website into .\site from .\_scrape\out (page content) and .\data (news).
# Usage:  powershell -ExecutionPolicy Bypass -File build.ps1
$root = $PSScriptRoot
$site = Join-Path $root 'site'
$out  = Join-Path $root '_scrape\out'
$enc  = New-Object Text.UTF8Encoding($false)
$cssVer = (Get-FileHash (Join-Path $site 'style.css') -Algorithm MD5).Hash.Substring(0, 8)   # stylesheet version: browsers reload it after every change

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

# Publication entry "[Authors (year). Title. Journal, vol...](url)": one link, only the journal (or proceedings) name in bold
function Pub-Item($s) {
  if ($s -notmatch '^\[(.*)\]\(([^)]*)\)$') { return (Inline $s) }
  $label = $Matches[1]; $u = $Matches[2]
  if ($label -match '^(?<pre>.*?\(\d{4}[^)]*\)\.\s+.*?\.\s+In\s+)(?<j>.+?)(?<post>\s+\((?:Vol\.|pp\.).*)$' -or
      $label -match '^(?<pre>.*?\(\d{4}[^)]*\)\.\s+.*?\.\s+)(?<j>[^,]+?)(?<post>,\s*\d.*)$') {
    $html = (Esc $Matches['pre']) + '<b>' + (Esc $Matches['j']) + '</b>' + (Esc $Matches['post'])
  } else { Write-Host "  publication without journal: $label"; $html = Esc $label }
  '<a href="' + (Esc $u) + '" target="_blank" rel="noopener">' + $html + '</a>'
}

$pages = @(
  @{ file = 'index.html';       title = 'Home';        src = 'home' },
  @{ file = 'research.html';    title = 'Research';    src = 'research' },
  @{ file = 'publications.html';title = 'Publications';src = 'publications' },
  @{ file = 'team.html';        title = 'Team';        src = 'people' },
  @{ file = 'lab-life.html';    title = 'Lab life';    src = 'copy-of-people' },
  @{ file = 'contact.html';     title = 'Contact';     src = 'contact' }
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
function Layout-Figs($figs, $textH, $split, $opt = @{}) {
  $n = $figs.Count; if ($n -eq 0) { return '' }
  $g = 0.016; $h0 = 0.42; $maxPer = 3; $hcap = 99   # Lab life passes smaller rows, more per row and a height cap
  $hmin = 0; $mcap = 0.55; $wmin = 0   # mcap: row height limit when there are several rows; wmin: narrowest photo
  if ($opt.h0) { $h0 = $opt.h0 }; if ($opt.maxPer) { $maxPer = $opt.maxPer }; if ($opt.hcap) { $hcap = $opt.hcap }; if ($opt.hmin) { $hmin = $opt.hmin }; if ($opt.mcap) { $mcap = $opt.mcap }; if ($opt.wmin) { $wmin = $opt.wmin }
  $best = $null; $bestCost = [double]::MaxValue
  for ($mask = 0; $mask -lt [Math]::Pow(2, $n - 1); $mask++) {
    $rows = @(); $cur = @()
    for ($k = 0; $k -lt $n; $k++) { $cur += $k; if ($k -lt $n - 1 -and ($mask -band (1 -shl $k))) { $rows += , $cur; $cur = @() } }
    $rows += , $cur
    if (@($rows | Where-Object { $_.Count -gt $maxPer }).Count) { continue }
    if ($split -and ((@($rows | ForEach-Object { $_.Count }) -join ',') -ne ($split -join ','))) { continue }   # fixed row split for this project
    $hs = @(); $cost = 0; $prevH = 0; $prevN = 0
    for ($r = 0; $r -lt $rows.Count; $r++) {
      $sum = 0; foreach ($k in $rows[$r]) { $sum += $figs[$k].ar }
      $rh = (1 - $g * ($rows[$r].Count - 1)) / $sum
      if (-not $split -and $r -gt 0 -and $r -eq $rows.Count - 1 -and $rows[$r].Count -lt $prevN -and $rh -gt $prevH) { $rh = $prevH }   # rows set by hand are left as given
      $cost += $(if ($rh -lt $h0) { 1 } else { 0.3 }) * [Math]::Pow([Math]::Log($rh / $h0), 2)   # small pictures are worse than large ones
      if ($rh -lt $hmin) { $cost += 10 * [Math]::Pow([Math]::Log($rh / $hmin), 2) }   # optional floor on row height
      if ($wmin) { foreach ($k in $rows[$r]) { $pw = $figs[$k].ar * [Math]::Min($rh, $mcap); if ($pw -lt $wmin) { $cost += 40 * [Math]::Pow([Math]::Log($pw / $wmin), 2) } } }   # optional floor on photo width
      if ($rows.Count -gt 1) { $rh = [Math]::Min($rh, $mcap) }; $rh = [Math]::Min($rh, $hcap)   # display cap: with several rows, no row dominates (a lone picture still fills the column)
      $hs += $rh; $prevH = $rh; $prevN = $rows[$r].Count
    }
    $tot = ($hs | Measure-Object -Sum).Sum + $g * ($rows.Count - 1)
    if ($tot -gt 1.3 * $textH) { $cost += [Math]::Pow([Math]::Log($tot / (1.3 * $textH)), 2) }   # text wraps below, so mild
    if ($cost -lt $bestCost) { $bestCost = $cost; $best = @{ rows = $rows; hs = $hs } }
  }
  # rows of several pictures share one height (the smallest), so no group of pictures looks oversized next to another
  $multi = @(0..($best.rows.Count - 1) | Where-Object { $best.rows[$_].Count -gt 1 })
  if ($multi.Count -gt 1 -and -not $opt.noEqual) {
    $hmin = ($multi | ForEach-Object { $best.hs[$_] } | Measure-Object -Minimum).Minimum
    foreach ($r in $multi) { $best.hs[$r] = $hmin }
  }
  $html = ''
  for ($r = 0; $r -lt $best.rows.Count; $r++) {
    $html += '<div class="frow" style="--h:' + [Math]::Round($best.hs[$r], 4) + '">'
    foreach ($k in $best.rows[$r]) { $html += ($figs[$k].tag -replace '^<(figure|a|img|video)', ('<$1 style="--ar:' + [Math]::Round($figs[$k].ar * $figs[$k].s, 3) + ';--r:' + $figs[$k].ar + '"')) }
    $html += '</div>'
  }
  $html
}

# Research page: one block per project, pictures floated right with the text wrapping around them
# Pictures left out of the Research page
$skipImgs = @('c1fe2f_affb91702dd140d6b065eaaa55480178')   # gravitational lensing: funnel potential
# Pictures shown smaller than their row height (unit-cell sketches etc.); the row is laid out at full size, then shrinks and is centred
$imgScale = @{ 'c1fe2f_0f7ba6f18c864b8883195429b988346d' = 0.63; 'c1fe2f_77610aaac52f40499d1f95780868e4ad' = 0.85   # Haldane unit cell, 3 controlled cells
              'c1fe2f_cbb4c1fbb74d41ea8eb433c65b4ee650' = 1.15   # quiet channel system sketch
              'c1fe2f_dff405ae5f1143858148b331df0b491e' = 0.8; 'c1fe2f_9aa51e66bc7d4934bea437dbc2cf242a' = 0.8; 'c1fe2f_8374e7cf995e470d9eca5cd6da6f516d' = 0.8   # quiet channel snapshots
              'c1fe2f_96a0a614fbb44338a2a4729af3fbfaff' = 0.8   # temporal negative refraction
              'c1fe2f_760c171f40c44ed0bca72aecd2d2e459' = 0.8   # wave acceleration and non-Hermitian jump
              'c1fe2f_1d9fde2056a04133bba2beae7422ad7a' = 0.8   # Lab life: Fun Times group selfie
              'c1fe2f_77f2568a29d24293b3ebcceab43e4c4a' = 0.8; 'c1fe2f_2018e1edeb474978bd2f4758fbe22417' = 0.8   # temporal cloaking figures
              'c1fe2f_9a3030b94e044f5a9311eb478cb3f958' = 0.75; 'c1fe2f_0b1bbbe1d3f1416fa916a15e8ad1dff0' = 0.75   # Lab life: Team day
              'c1fe2f_dde1fc8287ed4d81980503af470d887c' = 0.75; 'c1fe2f_cb1637009ff14849a35a048470d6364b' = 0.75; 'c1fe2f_fe9bdb6b68104b549fe79211da75ae48' = 0.75   # Lab life: Sodom cave
              'c1fe2f_34fcb9c11d0c4e63b975339c45b3a837' = 0.8   # harnessing nonlinearity
              'c1fe2f_09ecb430a9e045bdbc92bd943f25c0ad' = 0.8; 'c1fe2f_afff75f980c0419cbd492035db2c3f09' = 0.8; 'c1fe2f_16907c31fc41423fb82cf56f350bca64' = 0.8; 'c1fe2f_2dc04382aca74ea1910241691cdfdb24' = 0.8   # controlled wave acceleration: gamma panels
              'c1fe2f_720f9d42937146d4b853ea93e9587a09' = 0.93; 'c1fe2f_279b2987753c49cea3eacb46b4d0a033' = 1.08   # Lab life Siena: Colosseum smaller, restaurant bigger
              'c1fe2f_e4c0fb65dfc64000a7777483dc8cbd9c' = 0.8; 'c1fe2f_9522254608714fbcab2ee1230266b2ed' = 0.8; 'c1fe2f_7b5946e9c1a84a37b49208d4c9048806' = 0.8   # reconfigurable metamaterials videos
              'c1fe2f_7a6c9c38dd0646baa75666a175bfb216' = 0.8; 'c1fe2f_9729ad1c463e49a2809164e156faf488' = 0.8; 'c1fe2f_23857bc08e3a4b8ea54d55a3eb6ab771' = 0.8 }   # absorbers plots
# Fixed row split for a project (key = its first picture): number of pictures per row
$rowSplit = @{ 'c1fe2f_cbb4c1fbb74d41ea8eb433c65b4ee650' = @(1, 3) }   # quiet channel: system on top, 3 snapshots below
# Pictures moved to the end of their project (own row below the others)
$moveLast = @('c1fe2f_d3b19acc8c4c433b916e56274a27ab48')   # topological lattice animation
# Project titles missing on the Wix page: title inserted before the paragraph starting with the key
$addTitles = @{ 'We realized active autonomous guiding of topological sound beams' = 'Real-time steering of curved sound beams in a feedback-based topological acoustic metamaterial' }
# Project titles as in the papers (from Crossref); {PT} = calligraphic PT
$paperTitles = @{
  'Wave Acceleration and NH Jump in Nonreciprocal Lattices' = 'Solution of wave acceleration and non-Hermitian jump in nonreciprocal lattices'
  'Fast wave transport in two-dimensional PT-symmetric lattices' = 'Fast wave transport in two-dimensional {PT}-symmetric lattices'
  'Harnessing Nonlinearity to Tame Wave Dynamics in Nonreciprocal Active Systems' = 'Harnessing nonlinearity to tame wave dynamics in nonreciprocal active systems'
  'Controlled wave acceleration in non-Hermitian lattices' = 'Controlled wave acceleration in {PT}-symmetric and inhomogeneous non-Hermitian lattices'
  'Emerging exceptional point with breakdown of the skin effect in non-Hermitian quantum systems' = 'Emerging exceptional point with breakdown of the skin effect in non-Hermitian systems'
  'Real-time-controlled artificial quiet channel for acoustic cloaking' = 'Real-time-controlled artificial quiet channel for acoustic cloaking under varying detection conditions'
  'Acoustic analogue of quantum tunneling' = 'Klein-Like Tunneling of Sound via Negative Index Metamaterials'
  'Feedback-based topological mechanical metamaterials' = 'Non-Newtonian Topological Mechanical Metamaterials Using Feedback Control'
  'Feedback-based reconfigurable elastic metamaterials' = 'Tunable and reconfigurable mechanical transmission-line metamaterials via direct active feedback control'
  'Active boundary and interior wave absorbers' = 'Active boundary and interior absorbers for one-dimensional wave propagation: Application to transmission-line metamaterials'
}
function Paper-Title($t) { (Esc $t).Replace('{PT}', '&#x1D4AB;&#x1D4AF;') }
# Journal and year of each project's paper, keyed by a piece of its "Read more" link
$venues = [ordered]@{
  'gsp7-v4v1' = 'Physical Review Applied, 2026'; 's44455-025-00012-7' = 'npj Metamaterials, 2026'
  'zs92-qr17' = 'Physical Review Applied, 2025'; 'zkxs-24kn' = 'Physical Review Applied, 2025'
  'PhysRevB.111.174304' = 'Physical Review B, 2025'; 'PhysRevB.111.L100301' = 'Physical Review B, 2025'
  'PhysRevResearch.5.033104' = 'Physical Review Research, 2023'; 'PhysRevB.108.085104' = 'Physical Review B, 2023'
  'apl/article/123' = 'Applied Physics Letters, 2023'; 'S0888327023004090' = 'Mechanical Systems and Signal Processing, 2023'
  'ome-13-5-1401' = 'Optical Materials Express, 2023'; 'PhysRevApplied.18.014057' = 'Physical Review Applied, 2022'
  'PhysRevLett.125.256802' = 'Physical Review Letters, 2020'; 'S0888327020308657' = 'Mechanical Systems and Signal Processing, 2021'
  'S0888327019300019' = 'Mechanical Systems and Signal Processing, 2019'; 'S0005109820300534' = 'Automatica, 2020'
}
# "Read more" at the end of the text -> its own line: "<i>Journal</i>, year - Read more"
function Venue-Line($txt) {
  $m = [regex]::Match($txt, '\s*<a href="([^"]+)"[^>]*>Read more\.?</a>\.?')
  if (-not $m.Success) { return $txt }
  $url = $m.Groups[1].Value
  $txt = $txt.Remove($m.Index, $m.Length) -replace '<p></p>', ''
  $v = ''; foreach ($k in $venues.Keys) { if ($url.Contains($k)) { $v = $venues[$k]; break } }
  if ($v -match '^(.*), (\d{4})$') { $v = '<i>' + (Esc $Matches[1]) + '</i>, ' + $Matches[2] + ' &ndash; ' } else { Write-Host "  no journal for $url" }
  $txt + '<p class="pref">' + $v + '<a href="' + $url + '" target="_blank" rel="noopener">Read more</a></p>'
}
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
      $txt = Venue-Line $txt
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
    if ($size -ge 30 -and $plain.Length -le 130) { & $emit; $title = if ($paperTitles.ContainsKey($plain)) { Paper-Title $paperTitles[$plain] } else { Inline $l }; $txt = ''; $figs = New-Object Collections.ArrayList; $caps = New-Object Collections.ArrayList; continue }
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
function Chrome-Top($active, $pageTitle) {
  $nav = ''
  foreach ($m in $menu) {
    $cls = if ($m.f -eq $active) { ' class="on"' } else { '' }
    $nav += '<a' + $cls + ' href="' + $m.f + '">' + $m.t + '</a>'
  }
  @"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(Esc $pageTitle) | Active Wave Control Lab</title>
<meta name="description" content="Active Wave Control Lab, School of Mechanical Engineering, Tel Aviv University: active control of wave propagation in metamaterials and open acoustic environments.">
<link rel="preconnect" href="https://fonts.googleapis.com"><link href="https://fonts.googleapis.com/css2?family=Open+Sans:wght@300;400;600&display=swap" rel="stylesheet">
<link rel="stylesheet" href="style.css?v=$cssVer"></head><body>
<header class="banner"><h1>Active Wave Control Lab</h1></header>
<nav class="menu">$nav</nav>
<main>
"@
}
$footer = @"
</main>
<footer>
<hr>
<div class="inst"><a href="https://en-engineering.tau.ac.il/School-of-Mechanical-Engineering/" target="_blank" rel="noopener" title="School of Mechanical Engineering, Tel Aviv University"><img src="images/c1fe2f_1fbeb8481adb4920a88a78e52d2930b6.png" alt="Tel Aviv University"><p>School of Mechanical Engineering<br>The Iby and Aladar Fleischman Faculty of Engineering<br>Tel Aviv University</p></a></div>
<div class="funders">
<a href="https://isf.org.il/#/" target="_blank" rel="noopener"><img src="images/c1fe2f_80198b619a104773a049620936e7af68.jpg" alt="Israel Science Foundation"></a>
<a href="https://www.pazyfoundation.org.il/" target="_blank" rel="noopener"><img src="images/c1fe2f_e8bc55baf8c24b1fa501f40504e478f6.jpg" alt="Pazy Foundation"></a>
<a href="https://innovationisrael.org.il/en/" target="_blank" rel="noopener"><img src="images/c1fe2f_66663232a26245138f2722d760e0542e.png" alt="Israel Innovation Authority"></a>
</div></footer>
<script>if(location.hash==='#toggle-stats'){try{var k='umami.disabled';if(localStorage.getItem(k)){localStorage.removeItem(k);alert('Visit statistics: this browser is counted again.')}else{localStorage.setItem(k,'1');alert('Visit statistics: visits from this browser are no longer counted.')}}catch(e){}}</script>
<script defer src="https://cloud.umami.is/script.js" data-website-id="5366c617-d664-4bd8-91f8-ba28ba505198"></script>
</body></html>
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
# Link clean-up on every page: old Wix URLs -> new pages, ADS abstracts -> official APS meeting pages,
# preprint -> published article, personal session tokens removed
function Fix-Links($html) {
  $html = [regex]::Replace($html, 'href="https?://(www\.)?active-wave-control-lab\.com/?([\w-]*)"( target="_blank" rel="noopener")?', {
    param($m) $p = $m.Groups[2].Value; if (-not $p) { $p = 'index' }; 'href="' + $p + '.html"' })
  $html = [regex]::Replace($html, 'https://ui\.adsabs\.harvard\.edu/abs/(\d\d)(\d\d)APS\.\.MAR([A-Z])(\d\d)(\d{3})\w/abstract', {
    param($m) 'https://meetings.aps.org/Meeting/MAR' + $m.Groups[2].Value + '/Session/' + $m.Groups[3].Value + $m.Groups[4].Value + '.' + [int]$m.Groups[5].Value })
  $html = $html.Replace('https://arxiv.org/abs/2512.12726', 'https://www.nature.com/articles/s44455-025-00012-7')
  [regex]::Replace($html, '\?casa_token=[^"&]*(&amp;)?', { param($m) if ($m.Groups[1].Success) { '?' } else { '' } })
}
function Write-Page($file, $active, $title, $body, $extra = '') {
  [IO.File]::WriteAllText((Join-Path $site $file), (Fix-Links ((Chrome-Top $active $title) + $body + $footer.Replace('</body>', $extra + '</body>'))), $enc)
}

# Home
$h = Read-Outline 'home'
$intro = ($h | Where-Object { $_ -like 'We are interested*' } | Select-Object -First 1) -replace 'Read More\.$', '[Read More.](research.html)'
$homeHtml = '<section class="intro"><p>' + (Inline $intro) + '</p><a href="research.html"><img class="hero" src="images/c1fe2f_29825e2f1e2f4abc966e0eb971645ed7.png" alt="Active control of wave propagation: acoustic illusion and mimicking quantum wave phenomena"></a></section>'
$homeHtml += '<section class="band join"><h2>JOIN US!</h2><p><a class="btn" href="contact.html">Find out about available positions in our lab</a></p></section>'
$homeHtml += '<section class="band"><h2>Latest News</h2>' + $newsHtml + '</section>'
Write-Page 'index.html' 'index.html' 'Home' $homeHtml $newsJs

# Generic pages
foreach ($p in $pages | Where-Object { $_.src -in 'research', 'publications', 'contact' }) {
  $lines = Read-Outline $p.src
  if ($p.src -eq 'publications') {
    # data/publications.txt: one [citation](link) per line; entries after "## Earlier publications" sit behind a button
    $pl = Get-Content (Join-Path $root 'data\publications.txt') -Encoding UTF8 | Where-Object { $_.Trim() -and $_ -notmatch '^#\s' }
    $cut = [Array]::FindIndex([string[]]$pl, [Predicate[string]]{ param($x) $x -match '^##\s' })
    $recent = if ($cut -ge 0) { $pl[0..($cut - 1)] } else { $pl }
    $earlier = if ($cut -ge 0 -and $cut -lt $pl.Count - 1) { $pl[($cut + 1)..($pl.Count - 1)] } else { @() }
    $body = '<ul class="pubs">' + (($recent | ForEach-Object { '<li>' + (Pub-Item $_.Trim()) + '</li>' }) -join '') + '</ul>'
    if ($earlier.Count) {
      $body += '<p class="morebtn"><button type="button" id="earlierbtn">Show earlier publications</button></p>'
      $body += '<div id="earlier" hidden><ul class="pubs">' + (($earlier | ForEach-Object { '<li>' + (Pub-Item $_.Trim()) + '</li>' }) -join '') + '</ul></div>'
    }
  } elseif ($p.src -eq 'research') { $body = Convert-Projects $lines }
  else { $body = Convert-Outline $lines $false }
  # no page titles: the highlighted menu item shows where you are
  if ($p.src -eq 'contact') {
    # lines starting with "- " become a bulleted list
    $body = [regex]::Replace($body, '(?:<p>-\s*(.*?)</p>\s*)+', { param($m) '<ul class="dash">' + ((($m.Value | Select-String '<p>-\s*(.*?)</p>' -AllMatches).Matches | ForEach-Object { '<li>' + $_.Groups[1].Value + '</li>' }) -join '') + '</ul>' })
    $body = '<div class="contact">' + $body + '</div>'
  }
  $extra = if ($p.src -eq 'publications') { '<script>var e=document.getElementById("earlierbtn");if(e){e.addEventListener("click",function(){var d=document.getElementById("earlier");d.hidden=!d.hidden;e.textContent=d.hidden?"Show earlier publications":"Hide earlier publications";});}</script>' } else { '' }
  Write-Page $p.file $p.file $p.title $body $extra
}

# Team: sections, with photo cards
$lines = Read-Outline 'people'
$body = ''
$card = $null; $inPI = $false; $inAlumni = $false
$flushCard = { if ($script:card) { $script:body += '<div class="card">' + $script:card + '</div></div>'; $script:card = $null } }
foreach ($l in $lines) {
  $size = 16; if ($l -match '^\{S:(\d+)\}(.*)$') { $size = [int]$Matches[1]; $l = $Matches[2] }
  $l = $l.Trim(); if (-not $l -or $l -eq 'Sayan') { continue }
  if ($l -match '^(Principal Investigator|Research Scientists|Postdoctoral Fellows|Students|Alumni)') { & $flushCard; $body += '<h3>' + (Inline $l) + '</h3>'; $inPI = $l -like 'Principal Investigator*'; $inAlumni = $l -like 'Alumni*'
    # alumni come from data/alumni.txt (one per line)
    if ($inAlumni) { $body += ((Get-Content (Join-Path $root 'data\alumni.txt') -Encoding UTF8 | Where-Object { $_.Trim() -and $_ -notmatch '^#' } | ForEach-Object { '<p class="alumni">' + (Inline $_.Trim()) + '</p>' }) -join '') }
    continue }
  # PI card: photo from the old page, text from data/team-pi.html (name, contact line, short CV)
  if ($inAlumni) { continue }
  if ($inPI) {
    if ($l -match '^\[IMG:([^|\]]+)\|') { $body += '<div class="card pi"><img class="ph" src="' + (ImgFile $Matches[1]) + '" alt="Lea Beilkin-Sirota"><div class="txt">' + (Get-Content (Join-Path $root 'data\team-pi.html') -Raw -Encoding UTF8) + '</div></div>' }
    continue
  }
  if ($l -match '^\[IMG:([^|\]]+)\|') { & $flushCard; $card = '<img class="ph" src="' + (ImgFile $Matches[1]) + '" alt=""><div class="txt">'; continue }
  if ($card) {
    if ($l -notmatch '^\[' -and $card -notmatch '<h4>') { $card += '<h4>' + (Inline $l) + '</h4>' } else { $card += '<p>' + (Inline $l) + '</p>' }
  } else { $body += '<p class="alumni">' + (Inline $l) + '</p>' }
}
& $flushCard
$body = $body.Replace('</div></div>', '</div></div>')
Write-Page 'team.html' 'team.html' 'Team' $body

# Lab life: zig-zag timeline of events from data/lab-life.txt (newest first)
$evs = New-Object Collections.ArrayList; $ev = $null
foreach ($dl in (Get-Content (Join-Path $root 'data\lab-life.txt') -Encoding UTF8)) {
  $dl = $dl.Trim(); if (-not $dl -or ($dl -match '^#(\s|$)')) { continue }
  if ($dl -match '^##\s+(.*?)(\s+\|\s+(\S+))?$') { $ev = @{ title = $Matches[1]; link = $Matches[3]; logos = @(); figs = New-Object Collections.ArrayList; text = ''; split = $null }; [void]$evs.Add($ev); continue }
  if ($dl -match '^(photo|logo)\s+(\S+)(\s+\|\s+(\S+))?$') {
    $kind = $Matches[1]; $file = $Matches[2]; $lnk = $Matches[4]
    if ($kind -eq 'logo') {
      $t = '<img src="' + (ImgFile $file) + '" alt="" loading="lazy">'
      if ($lnk) { $t = '<a href="' + (Esc $lnk) + '" target="_blank" rel="noopener">' + $t + '</a>' }
      $ev.logos += $t
    } else { $k0 = $file -replace '\.\w+$', ''; [void]$ev.figs.Add(@{ tag = (FigTag $file $lnk); ar = [Math]::Max((ImgAR $file), 0.75); s = $(if ($imgScale.ContainsKey($k0)) { $imgScale[$k0] } else { 1 }); id = $file }) }   # very tall phone photos are trimmed to 3:4
    continue
  }
  if ($dl -match '^rows\s+([\d\s]+)$') { $ev.split = @($Matches[1].Trim() -split '\s+' | ForEach-Object { [int]$_ }); continue }
  if ($dl -match '^text\s+(.*)$') { $ev.text += '<p>' + (Inline $Matches[1]) + '</p>' }
}
$tl = '<div class="tl">'
foreach ($ev in $evs) {
  $name = $ev.title; $date = ''
  if ($name -match '^(.*?)\s+-\s+([^-]+)$') { $name = $Matches[1]; $date = $Matches[2] }
  $h = Esc $name; if ($ev.link) { $h = '<a href="' + (Esc $ev.link) + '" target="_blank" rel="noopener">' + $h + '</a>' }
  $tl += '<article class="ev">' + $(if ($date) { '<p class="date">' + (Esc $date) + '</p>' }) + '<h3>' + $h + '</h3>'
  $logos = if ($ev.logos.Count) { '<div class="logos">' + ($ev.logos -join '') + '</div>' } else { '' }
  if ($ev.figs.Count -eq 1 -and $logos) {
    # one photo and logos: side by side
    $tl += '<div class="side"><div class="efig">' + (Layout-Figs $ev.figs 10 $null @{ hcap = 9 }) + '</div>' + $logos + '</div>'
  } else {
    $tl += $logos
    # a lone photo gets more room than photos in a collage
    $hc = if ($ev.figs.Count -eq 1) { 0.6 } else { 0.55 }
    if ($ev.split) { $hc = 0.75 }   # rows set by hand: allow bigger photos
    if ($ev.figs.Count) { $tl += '<div class="efig">' + (Layout-Figs $ev.figs 10 $ev.split @{ h0 = 0.42; hmin = 0.37; maxPer = 4; hcap = $hc; mcap = $(if ($ev.split) { 0.75 } else { 0.55 }); wmin = 0.33; noEqual = $true }) + '</div>' }
  }
  $tl += $ev.text + '</article>'
}
$tl += '</div>'
# Desktop: pack the cards on both sides of the line, each one a bit lower than the previous (keeps the order in time)
$tlJs = @'
<script>
(function () {
  var tl = document.querySelector('.tl'); if (!tl) return;
  var evs = [].slice.call(tl.querySelectorAll('.ev'));
  function place() {
    var wide = window.innerWidth > 760;
    tl.classList.toggle('packed', wide);
    if (!wide) { evs.forEach(function (e) { e.style.top = ''; e.classList.remove('l', 'r'); }); tl.style.height = ''; return; }
    var bottom = { l: 0, r: 0 }, prevTop = -1e9, prevSide = 'r';
    evs.forEach(function (e) {
      var side = bottom.l < bottom.r ? 'l' : bottom.r < bottom.l ? 'r' : (prevSide === 'l' ? 'r' : 'l');
      var top = Math.max(bottom[side], prevTop + 60);
      e.classList.remove('l', 'r'); e.classList.add(side); e.style.top = top + 'px';
      bottom[side] = top + e.offsetHeight + 26; prevTop = top; prevSide = side;
    });
    tl.style.height = Math.max(bottom.l, bottom.r) + 'px';
  }
  place(); window.addEventListener('resize', place); window.addEventListener('load', place);
  [].forEach.call(tl.querySelectorAll('img'), function (i) { i.addEventListener('load', place); });
})();
</script>
'@
Write-Page 'lab-life.html' 'lab-life.html' 'Lab life' $tl $tlJs

"Built {0} pages into {1}" -f $pages.Count, $site

# Redirect stubs so old Wix URLs keep working (the old topic pages now lead to Research)
$redirects = @{ 'people.html' = 'team.html'; 'copy-of-people.html' = 'lab-life.html'; 'topic-1.html' = 'research.html'; 'copy-of-topic-1.html' = 'research.html'; 'copy-of-topic-2.html' = 'research.html'; 'copy-of-topic-3.html' = 'research.html' }
foreach ($k in $redirects.Keys) {
  $to = $redirects[$k]
  [IO.File]::WriteAllText((Join-Path $site $k), "<!doctype html><meta charset=""utf-8""><title>Redirecting</title><link rel=""canonical"" href=""$to""><meta http-equiv=""refresh"" content=""0; url=$to""><p>Moved to <a href=""$to"">$to</a>.</p>", $enc)
}
