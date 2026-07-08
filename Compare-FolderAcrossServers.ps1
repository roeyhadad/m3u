#Requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── פונקציות עזר ──────────────────────────────────────────────────────────────

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    if ($Bytes -lt 1GB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N2} GB' -f ($Bytes / 1GB)
}

function ConvertTo-HtmlText {
    param([string]$s)
    $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
}

# בניית טבלת קבצים — עם נתיב מלא וכפתור Show Diff
$script:diffCounter = 0
function Build-FileTable {
    param(
        $Files,
        [string]$Label,
        [string]$RowClass,
        [string]$BadgeClass,
        [string]$ServerUncRoot,
        [string]$SourceUncRoot,
        [bool]$ShowDiff = $false
    )
    if (-not $Files -or @($Files).Count -eq 0) { return '' }
    $Files = @($Files)

    $rows = [System.Text.StringBuilder]::new()

    foreach ($file in $Files) {
        $script:diffCounter++
        $did     = "df$($script:diffCounter)"
        $rel     = ConvertTo-HtmlText $file.RelativePath
        $dt      = ConvertTo-HtmlText $file.DateTime
        $sz      = ConvertTo-HtmlText $file.SizeFormatted
        $fullSrv = ConvertTo-HtmlText "$ServerUncRoot\$($file.RelativePath)"
        $fullSrc = ConvertTo-HtmlText "$SourceUncRoot\$($file.RelativePath)"

        if ($ShowDiff) {
            $srcUrl  = "file:///$($SourceUncRoot -replace '\\','/')/$(($file.RelativePath -replace '\\','/'))"
            $tgtUrl  = "file:///$($ServerUncRoot -replace '\\','/')/$(($file.RelativePath -replace '\\','/'))"
            $actCell = "<a class='open-btn' href='$srcUrl' target='_blank' title='Open source file'>Src</a> " +
                       "<a class='open-btn btn-tgt' href='$tgtUrl' target='_blank' title='Open target file'>Tgt</a> " +
                       "<button class='diff-btn' onclick=""toggleDiff('$did')"">Show Diff</button>"
        } else {
            $fileUrl = "file:///$($ServerUncRoot -replace '\\','/')/$(($file.RelativePath -replace '\\','/'))"
            $actCell = "<a class='open-btn' href='$fileUrl' target='_blank' title='Open file'>Open</a>"
        }

        [void]$rows.Append("<tr class='$RowClass'>")
        [void]$rows.Append("<td><div class='rel'>$rel</div><div class='full-path src-path'>$fullSrc</div><div class='full-path tgt-path'>$fullSrv</div></td>")
        [void]$rows.Append("<td>$dt</td><td class='sz'>$sz</td><td class='act'>$actCell</td></tr>")

        if ($ShowDiff) {
            # DiffHtml חושב ישירות ב-Runspace ושמור על אובייקט הקובץ
            $diffContent = if ($file.DiffHtml) { $file.DiffHtml } else { "<em class='diff-ok'>&#10003; Content identical.</em>" }
            [void]$rows.Append("<tr class='diff-row' id='$did' style='display:none'><td colspan='4' class='diff-cell'>$diffContent</td></tr>")
        }
    }

    return @"
        <div class="cat-block">
          <div class="cat-header $BadgeClass">$Label <span class="cnt">$($Files.Count)</span></div>
          <table class="file-table">
            <thead><tr><th>Path</th><th>Date Modified</th><th>Size</th><th></th></tr></thead>
            <tbody>$($rows.ToString())</tbody>
          </table>
        </div>
"@
}

# ── ScriptBlock לכל Runspace ──────────────────────────────────────────────────
$compareScript = {
    param([string]$Target, [string]$SrcPath, [string]$FolderPart)

    $destPath = "\\$Target\$FolderPart"

    # ── פונקציות פנימיות (חייבות להיות בתוך ה-ScriptBlock) ──────────────────

    function _Fmt([long]$b) {
        if ($b -lt 1KB) { return "$b B" }
        if ($b -lt 1MB) { return '{0:N1} KB' -f ($b/1KB) }
        if ($b -lt 1GB) { return '{0:N1} MB' -f ($b/1MB) }
        return '{0:N2} GB' -f ($b/1GB)
    }

    function _HtmlEnc([string]$s) {
        $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
    }

    # קריאת קובץ עם זיהוי BOM — מחזיר טקסט מנורמל (CRLF → LF)
    function _ReadNorm([string]$path) {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $skip  = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $enc = [System.Text.Encoding]::UTF8; $skip = 3
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $enc = [System.Text.Encoding]::Unicode; $skip = 2
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $enc = [System.Text.Encoding]::BigEndianUnicode; $skip = 2
        } else {
            $enc = New-Object System.Text.UTF8Encoding($false, $false); $skip = 0
        }
        if ($skip -gt 0) {
            $trimmed = New-Object byte[] ($bytes.Length - $skip)
            [System.Array]::Copy($bytes, $skip, $trimmed, 0, $trimmed.Length)
            $bytes = $trimmed
        }
        return ($enc.GetString($bytes)) -replace "`r`n","`n" -replace "`r","`n"
    }

    # LCS diff — מקבל טקסט מנורמל (כבר נקרא), מחזיר HTML מוכן
    function _DiffHtml([string]$srcText, [string]$dstText, [string]$srcLabel, [string]$dstLabel) {
        $MAX_LINES = 1000
        $CONTEXT   = 3

        $srcLines = @($srcText -split "`n")
        $dstLines = @($dstText -split "`n")

        if ($srcLines.Count -gt $MAX_LINES -or $dstLines.Count -gt $MAX_LINES) {
            return "<em class='diff-err'>Too many lines (&gt;$MAX_LINES) for inline diff. ($($srcLines.Count) / $($dstLines.Count))</em>"
        }

        $m = $srcLines.Count; $n = $dstLines.Count

        # גזירת prefix/suffix משותף
        $pre = 0
        while ($pre -lt $m -and $pre -lt $n -and ([string]::CompareOrdinal($srcLines[$pre], $dstLines[$pre]) -eq 0)) { $pre++ }
        $suf = 0
        while ($suf -lt ($m-$pre) -and $suf -lt ($n-$pre) -and
               ([string]::CompareOrdinal($srcLines[$m-1-$suf], $dstLines[$n-1-$suf]) -eq 0)) { $suf++ }

        $srcMidEnd = $m - 1 - $suf; $dstMidEnd = $n - 1 - $suf
        $srcMid = if ($pre -le $srcMidEnd) { @($srcLines[$pre..$srcMidEnd]) } else { @() }
        $dstMid = if ($pre -le $dstMidEnd) { @($dstLines[$pre..$dstMidEnd]) } else { @() }
        $mm = $srcMid.Count; $nn = $dstMid.Count

        if ($mm -eq 0 -and $nn -eq 0) {
            return "<em class='diff-ok'>&#10003; Content identical.</em>"
        }

        # LCS DP — jagged array (PS5.1 safe)
        $dp = New-Object 'object[]' ($mm+1)
        for ($k = 0; $k -le $mm; $k++) { $dp[$k] = New-Object 'int[]' ($nn+1) }
        for ($i = $mm-1; $i -ge 0; $i--) {
            for ($j = $nn-1; $j -ge 0; $j--) {
                if ([string]::CompareOrdinal($srcMid[$i], $dstMid[$j]) -eq 0) {
                    $dp[$i][$j] = 1 + $dp[$i+1][$j+1]
                } else {
                    $lv = $dp[$i+1][$j]; $rv = $dp[$i][$j+1]
                    $dp[$i][$j] = if ($lv -ge $rv) { $lv } else { $rv }
                }
            }
        }

        # בניית ops
        $ops = [System.Collections.Generic.List[PSCustomObject]]::new()
        for ($k = 0; $k -lt $pre; $k++) { $ops.Add([PSCustomObject]@{Op='eq';Text=$srcLines[$k]}) }
        $i = 0; $j = 0
        while ($i -lt $mm -or $j -lt $nn) {
            if ($i -lt $mm -and $j -lt $nn -and ([string]::CompareOrdinal($srcMid[$i], $dstMid[$j]) -eq 0)) {
                $ops.Add([PSCustomObject]@{Op='eq';  Text=$srcMid[$i]}); $i++; $j++
            } elseif ($j -lt $nn -and ($i -ge $mm -or $dp[$i][$j+1] -gt $dp[$i+1][$j])) {
                $ops.Add([PSCustomObject]@{Op='add'; Text=$dstMid[$j]}); $j++
            } else {
                $ops.Add([PSCustomObject]@{Op='del'; Text=$srcMid[$i]}); $i++
            }
        }
        for ($k = $suf-1; $k -ge 0; $k--) { $ops.Add([PSCustomObject]@{Op='eq';Text=$srcLines[$m-1-$k]}) }

        # סינון — רק שורות עם שינוי
        $changed = @($ops | Where-Object { $_.Op -ne 'eq' })
        if ($changed.Count -eq 0) {
            # לא אמור לקרות עם השוואה Ordinal — אבל אם קרה, אל תשקר שהקבצים זהים
            $firstDiff = -1
            $minLen = [Math]::Min($srcText.Length, $dstText.Length)
            for ($q = 0; $q -lt $minLen; $q++) { if ($srcText[$q] -ne $dstText[$q]) { $firstDiff = $q; break } }
            if ($firstDiff -lt 0 -and $srcText.Length -ne $dstText.Length) { $firstDiff = $minLen }
            $sc = if ($firstDiff -ge 0 -and $firstDiff -lt $srcText.Length) { 'U+{0:X4}' -f [int]$srcText[$firstDiff] } else { 'EOF' }
            $dc = if ($firstDiff -ge 0 -and $firstDiff -lt $dstText.Length) { 'U+{0:X4}' -f [int]$dstText[$firstDiff] } else { 'EOF' }
            return "<em class='diff-err'>Files differ only in invisible/control characters (e.g. NUL, zero-width). First difference at char index $firstDiff : source=$sc, target=$dc. Lengths: $($srcText.Length) / $($dstText.Length) chars.</em>"
        }

        # סימון שורות להצגה (שינוי ± Context)
        $total = $ops.Count
        $show  = New-Object bool[] $total
        for ($k = 0; $k -lt $total; $k++) {
            if ($ops[$k].Op -ne 'eq') {
                $lo = [Math]::Max(0, $k-$CONTEXT); $hi = [Math]::Min($total-1, $k+$CONTEXT)
                for ($l = $lo; $l -le $hi; $l++) { $show[$l] = $true }
            }
        }

        $sb = [System.Text.StringBuilder]::new()
        $sn = 1; $dn = 1; $prevOmit = $false
        for ($k = 0; $k -lt $total; $k++) {
            $op = $ops[$k]
            if (-not $show[$k]) {
                if (-not $prevOmit) { [void]$sb.Append("<tr class='diff-skip'><td colspan='4'>&hellip;</td></tr>") }
                $prevOmit = $true
                if ($op.Op -eq 'eq') { $sn++; $dn++ } elseif ($op.Op -eq 'del') { $sn++ } else { $dn++ }
                continue
            }
            $prevOmit = $false
            $txt = _HtmlEnc $op.Text
            switch ($op.Op) {
                'eq'  { [void]$sb.Append("<tr class='deq'><td class='ln'>$sn</td><td class='ln'>$dn</td><td class='dm'>&nbsp;</td><td class='dc'>$txt</td></tr>"); $sn++; $dn++ }
                'del' { [void]$sb.Append("<tr class='ddel'><td class='ln'>$sn</td><td class='ln'>&nbsp;</td><td class='dm'>-</td><td class='dc'>$txt</td></tr>"); $sn++ }
                'add' { [void]$sb.Append("<tr class='dadd'><td class='ln'>&nbsp;</td><td class='ln'>$dn</td><td class='dm'>+</td><td class='dc'>$txt</td></tr>"); $dn++ }
            }
        }

        $sl = _HtmlEnc $srcLabel; $dl = _HtmlEnc $dstLabel
        return @"
<div class='diff-legend'><span class='dl-src'>- Source: $sl</span><span class='dl-dst'>+ Target: $dl</span></div>
<table class='diff-table'><thead><tr><th>Src#</th><th>Tgt#</th><th></th><th>Content</th></tr></thead>
<tbody>$($sb.ToString())</tbody></table>
"@
    }

    # ── תוצאה ──────────────────────────────────────────────────────────────────

    $result = [PSCustomObject]@{
        Server         = $Target
        OnlyInSource   = [System.Collections.Generic.List[PSCustomObject]]::new()
        OnlyInDest     = [System.Collections.Generic.List[PSCustomObject]]::new()
        ContentDiffers = [System.Collections.Generic.List[PSCustomObject]]::new()
        Identical      = 0
        TotalDiff      = 0
        Error          = $null
    }

    try {
        $rawOutput = & robocopy $SrcPath $destPath /L /E /MIR /BYTES /TS /FP /NJH /NJS /NDL /R:0 /W:0 2>&1
        $exitCode  = $LASTEXITCODE

        if ($exitCode -ge 8) {
            $errLine = $rawOutput |
                Where-Object { "$_" -match 'ERROR|FATAL|Access is denied|cannot find the (path|file)' } |
                Select-Object -First 1
            $result.Error = "Robocopy exit $exitCode$(if ($errLine) { ': ' + $errLine })"
        }
        else {
            $dateChanged = [System.Collections.Generic.List[PSCustomObject]]::new()

            foreach ($line in $rawOutput) {
                $lineStr = "$line"
                if ([string]::IsNullOrWhiteSpace($lineStr)) { continue }
                if ($lineStr -notmatch '(\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2})') { continue }
                $dt       = $Matches[1]; $dtIdx = $lineStr.IndexOf($dt)
                $fullPath = $lineStr.Substring($dtIdx + $dt.Length).Trim()
                if (-not $fullPath.StartsWith('\\')) { continue }
                $beforeDt = $lineStr.Substring(0, $dtIdx)
                if ($beforeDt -notmatch '(\d+)\s*$') { continue }
                $size    = [long]$Matches[1]
                $sizeIdx = $beforeDt.LastIndexOf($Matches[1])
                $tag     = $beforeDt.Substring(0, $sizeIdx).Trim()
                $relPath = ($fullPath -replace [regex]::Escape($SrcPath),'' -replace [regex]::Escape($destPath),'').TrimStart('\')

                $fileObj = [PSCustomObject]@{
                    RelativePath  = $relPath
                    DateTime      = $dt
                    Size          = $size
                    SizeFormatted = _Fmt $size
                    DiffHtml      = ''
                }

                if     ($tag -match '\*EXTRA') { $result.OnlyInDest.Add($fileObj) }
                elseif ($tag -match 'Newer')   { $dateChanged.Add($fileObj) }
                elseif ($tag -match 'Older')   { $dateChanged.Add($fileObj) }
                elseif ($tag -match 'Same')    { $result.Identical++ }
                else                           { $result.OnlyInSource.Add($fileObj) }
            }

            # hash raw bytes → אם זהים, הכל זהה (תאריך בלבד שונה)
            # אם hash שונה → קרא טקסט מנורמל: אם זהה → BOM/CRLF בלבד (Identical)
            # רק אם גם הטקסט המנורמל שונה → ContentDiffers + DiffHtml
            $md5 = [System.Security.Cryptography.MD5]::Create()
            foreach ($f in $dateChanged) {
                $sf = "$SrcPath\$($f.RelativePath)"
                $df = "$destPath\$($f.RelativePath)"
                try {
                    $sbytes = [System.IO.File]::ReadAllBytes($sf)
                    $dbytes = [System.IO.File]::ReadAllBytes($df)

                    if ($sbytes.Length -gt 2MB -or $dbytes.Length -gt 2MB) {
                        # קובץ גדול — hash בלבד, ללא diff
                        $sh = [BitConverter]::ToString($md5.ComputeHash($sbytes)) -replace '-',''
                        $dh = [BitConverter]::ToString($md5.ComputeHash($dbytes)) -replace '-',''
                        if ($sh -eq $dh) { $result.Identical++ }
                        else {
                            $f.DiffHtml = "<em class='diff-err'>File too large (&gt;2MB) for inline diff.</em>"
                            $result.ContentDiffers.Add($f)
                        }
                        continue
                    }

                    $sh = [BitConverter]::ToString($md5.ComputeHash($sbytes)) -replace '-',''
                    $dh = [BitConverter]::ToString($md5.ComputeHash($dbytes)) -replace '-',''

                    if ($sh -eq $dh) {
                        # bytes זהים לחלוטין — תאריך שונה בלבד
                        $result.Identical++
                        continue
                    }

                    # bytes שונים — בדיקת טקסט מנורמל (BOM / CRLF)
                    $enc = New-Object System.Text.UTF8Encoding($false, $false)
                    function _Decode([byte[]]$b) {
                        $skip = 0
                        if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
                            $e = [System.Text.Encoding]::UTF8; $skip = 3
                        } elseif ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) {
                            $e = [System.Text.Encoding]::Unicode; $skip = 2
                        } elseif ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) {
                            $e = [System.Text.Encoding]::BigEndianUnicode; $skip = 2
                        } else {
                            $e = New-Object System.Text.UTF8Encoding($false, $false); $skip = 0
                        }
                        if ($skip -gt 0) {
                            $t = New-Object byte[] ($b.Length - $skip)
                            [System.Array]::Copy($b, $skip, $t, 0, $t.Length)
                            $b = $t
                        }
                        return ($e.GetString($b)) -replace "`r`n","`n" -replace "`r","`n"
                    }

                    $srcText = _Decode $sbytes
                    $dstText = _Decode $dbytes

                    if ([string]::CompareOrdinal($srcText, $dstText) -eq 0) {
                        # תוכן זהה — רק BOM/CRLF שונה
                        $result.Identical++
                        continue
                    }

                    # תוכן שונה — חישוב diff
                    $f.DiffHtml = _DiffHtml $srcText $dstText $sf $df
                    $result.ContentDiffers.Add($f)

                } catch {
                    $f.DiffHtml = "<em class='diff-err'>Read error: $(_HtmlEnc $_.Exception.Message)</em>"
                    $result.ContentDiffers.Add($f)
                }
            }
            $md5.Dispose()

            $result.TotalDiff = $result.OnlyInSource.Count + $result.OnlyInDest.Count + $result.ContentDiffers.Count
        }
    }
    catch { $result.Error = $_.Exception.Message }

    return $result
}

# ── הרצת ההשוואה המקבילה ─────────────────────────────────────────────────────
function Invoke-Comparison {
    param([string]$SourceServer, [string[]]$TargetServers, [string]$FolderPath, [int]$ThrottleLimit = 16)

    $FolderPath = $FolderPath.Trim('\').Trim('/')
    $sourcePath = "\\$SourceServer\$FolderPath"

    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
        1, $ThrottleLimit,
        [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault(),
        $Host
    )
    $pool.Open()

    $jobs = foreach ($target in $TargetServers) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($compareScript)
        [void]$ps.AddParameter('Target',     $target)
        [void]$ps.AddParameter('SrcPath',    $sourcePath)
        [void]$ps.AddParameter('FolderPart', $FolderPath)
        [PSCustomObject]@{ Server = $target; PowerShell = $ps; Handle = $ps.BeginInvoke() }
    }

    $rawResults = foreach ($job in $jobs) {
        $job.PowerShell.EndInvoke($job.Handle)
        $job.PowerShell.Dispose()
    }

    $pool.Close()
    $pool.Dispose()

    $allResults = [ordered]@{}
    foreach ($srv in $TargetServers) {
        $match = @($rawResults) | Where-Object { $_.Server -eq $srv } | Select-Object -First 1
        if ($match) { $allResults[$srv] = $match }
    }

    return $allResults
}

# ── בניית דוח HTML ────────────────────────────────────────────────────────────
function Build-HtmlReport {
    param(
        $AllResults,
        [string]$SourceServer,
        [string[]]$TargetServers,
        [string]$SourcePath,
        [datetime]$StartTime,
        [int]$Duration
    )

    $script:diffCounter = 0

    $summaryRows = $AllResults.Keys | ForEach-Object {
        $srv = $_; $r = $AllResults[$srv]; $sh = ConvertTo-HtmlText $srv
        if ($r.Error) {
            "<tr class='err-row'><td><a href='#s_$sh'>$sh</a></td><td colspan='5' class='err-cell'>$(ConvertTo-HtmlText $r.Error)</td></tr>"
        } else {
            $totalDiff = $r.TotalDiff
            $sc = if ($totalDiff -eq 0) { 'ok' } else { 'diff' }
            $st = if ($totalDiff -eq 0) { '&#10003; Identical' } else { '&#10007; Differences found' }
            "<tr><td><a href='#s_$sh'>$sh</a></td><td class='status-$sc'>$st</td><td class='n'>$(@($r.OnlyInSource).Count)</td><td class='n'>$(@($r.OnlyInDest).Count)</td><td class='n'>$(@($r.ContentDiffers).Count)</td><td class='n'>$([int]$r.Identical)</td></tr>"
        }
    }

    $detailSections = $AllResults.Keys | ForEach-Object {
        $srv = $_; $r = $AllResults[$srv]; $sh = ConvertTo-HtmlText $srv

        $totalDiff  = if ($r.Error) { 1 } else { $r.TotalDiff }
        $hClass     = if ($r.Error) { 'hdr-err' } elseif ($totalDiff -eq 0) { 'hdr-ok' } else { 'hdr-diff' }
        $badge      = if ($r.Error) { 'ERROR' } elseif ($totalDiff -eq 0) { 'Identical' } else { "$totalDiff differences" }
        $openAttr   = if ($totalDiff -gt 0 -or $r.Error) { ' open' } else { '' }

        $srvUncRoot = "\\$srv\$($SourcePath -replace [regex]::Escape("\\$SourceServer\"),'')"

        $body = if ($r.Error) {
            "<p class='err-msg'>$(ConvertTo-HtmlText $r.Error)</p>"
        } elseif ($totalDiff -eq 0) {
            "<p class='ok-msg'>&#10003; All files match the source server.</p>"
        } else {
            (Build-FileTable -Files $r.OnlyInSource -Label "Only in Source ($SourceServer)" -RowClass 'rs' -BadgeClass 'badge-src' -ServerUncRoot $SourcePath  -SourceUncRoot $SourcePath -ShowDiff $false) +
            (Build-FileTable -Files $r.OnlyInDest   -Label "Only in Target ($srv)"          -RowClass 'rt' -BadgeClass 'badge-tgt' -ServerUncRoot $srvUncRoot   -SourceUncRoot $SourcePath -ShowDiff $false) +
            (Build-FileTable -Files $r.ContentDiffers -Label "Content Differs"              -RowClass 'rn' -BadgeClass 'badge-new' -ServerUncRoot $srvUncRoot   -SourceUncRoot $SourcePath -ShowDiff $true)
        }

        @"
    <section id="s_$sh">
      <details$openAttr>
        <summary class="$hClass"><span class="sname">$sh</span><span class="badge">$badge</span></summary>
        <div class="det-body">$body</div>
      </details>
    </section>
"@
    }

    $srcHtml    = ConvertTo-HtmlText $SourcePath
    $reportDate = $StartTime.ToString('yyyy-MM-dd HH:mm:ss')

    return @"
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Folder Compare -- $srcHtml</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Tahoma,Verdana,sans-serif;font-size:13.5px;background:#f0f2f5;color:#222;padding:28px 32px}
a{color:#3f51b5;text-decoration:none}a:hover{text-decoration:underline}
.page-title{font-size:22px;font-weight:700;color:#1a237e;margin-bottom:6px}
.meta{color:#555;font-size:12.5px;margin-bottom:28px;display:flex;flex-wrap:wrap;gap:18px}
.meta b{color:#333}
h2{font-size:16px;font-weight:700;color:#283593;border-bottom:2px solid #3f51b5;padding-bottom:5px;margin:28px 0 14px}
.sum-wrap{overflow-x:auto}
table.sum{width:100%;border-collapse:collapse;background:#fff;box-shadow:0 1px 5px rgba(0,0,0,.12);border-radius:7px;overflow:hidden}
table.sum th{background:#3f51b5;color:#fff;padding:10px 14px;text-align:left;font-size:12.5px;font-weight:600;white-space:nowrap}
table.sum td{padding:9px 14px;border-bottom:1px solid #eee}
table.sum tr:last-child td{border-bottom:none}
table.sum tr:hover td{background:#f5f7ff}
.n{text-align:center;font-variant-numeric:tabular-nums}
.status-ok{color:#2e7d32;font-weight:600}.status-diff{color:#c62828;font-weight:600}
.err-row td{background:#ffebee}.err-cell{color:#c62828;font-size:12px}
.legend{display:flex;flex-wrap:wrap;gap:14px;margin-bottom:16px;font-size:12px}
.leg{display:flex;align-items:center;gap:5px}
.leg-dot{width:11px;height:11px;border-radius:2px;border:1px solid rgba(0,0,0,.15)}
section{margin-bottom:10px}
details{background:#fff;border-radius:7px;box-shadow:0 1px 4px rgba(0,0,0,.1);overflow:hidden}
details>summary{display:flex;align-items:center;justify-content:space-between;padding:12px 16px;cursor:pointer;user-select:none;list-style:none}
details>summary::-webkit-details-marker{display:none}
details>summary::after{content:'\25B6';font-size:10px;color:#777;transition:transform .18s;margin-left:8px}
details[open]>summary::after{transform:rotate(90deg)}
.sname{font-size:14px;font-weight:700}
.badge{font-size:12px;padding:2px 11px;border-radius:12px;background:rgba(0,0,0,.08)}
.hdr-ok{background:#e8f5e9}.hdr-diff{background:#fff8e1}.hdr-err{background:#ffebee}
.det-body{padding:14px 18px 18px}
.ok-msg{color:#2e7d32;padding:6px 0}.err-msg{color:#c62828;padding:6px 0}
.cat-block{margin-bottom:16px}.cat-block:last-child{margin-bottom:0}
.cat-header{font-size:12px;font-weight:700;padding:5px 10px;border-radius:4px 4px 0 0;text-transform:uppercase;letter-spacing:.4px}
.cnt{font-weight:400;margin-left:6px;opacity:.8}
.badge-src{background:#fff3e0;color:#e65100}.badge-tgt{background:#fce4ec;color:#880e4f}
.badge-new{background:#e8f5e9;color:#1b5e20}.badge-old{background:#f3e5f5;color:#4a148c}
table.file-table{width:100%;border-collapse:collapse;font-size:12px;border:1px solid rgba(0,0,0,.08);border-top:none;border-radius:0 0 4px 4px;overflow:hidden}
table.file-table th{background:#607d8b;color:#fff;padding:5px 10px;text-align:left;font-weight:600}
table.file-table td{padding:5px 10px;border-bottom:1px solid #f0f0f0;vertical-align:top}
table.file-table tr:last-child td{border-bottom:none}
.rel{font-weight:500;word-break:break-all}
.full-path{font-size:10.5px;margin-top:2px;word-break:break-all}
.src-path{color:#1565c0}.tgt-path{color:#6a1b9a}
.sz{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.act{white-space:nowrap;text-align:right;width:1px}
.rs td{background:#fff8f0}.rt td{background:#fff0f4}.rn td{background:#f0fff4}.ro td{background:#f8f0ff}
table.file-table tr:hover td{filter:brightness(0.97)}
.open-btn{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600;background:#3f51b5;color:#fff;text-decoration:none;margin:1px 1px 3px 0}
.open-btn:hover{background:#283593;color:#fff;text-decoration:none}
.btn-tgt{background:#7b1fa2}.btn-tgt:hover{background:#4a148c}
.diff-btn{display:inline-block;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600;background:#00796b;color:#fff;border:none;cursor:pointer;margin:1px 0 3px 0}
.diff-btn:hover{background:#004d40}
.diff-row td{padding:0}
.diff-cell{padding:0!important}
.diff-legend{display:flex;gap:16px;padding:6px 10px;background:#f5f5f5;font-size:11px;border-bottom:1px solid #ddd}
.dl-src{color:#c62828;font-family:monospace}.dl-dst{color:#2e7d32;font-family:monospace}
table.diff-table{width:100%;border-collapse:collapse;font-family:Consolas,'Courier New',monospace;font-size:12px}
table.diff-table th{background:#455a64;color:#fff;padding:3px 8px;text-align:left;font-weight:600;font-size:11px}
.ln{width:40px;text-align:right;color:#90a4ae;padding:1px 6px;user-select:none;white-space:nowrap;background:rgba(0,0,0,.03)}
.dm{width:18px;text-align:center;font-weight:700;padding:1px 4px}
.dc{padding:1px 8px;white-space:pre-wrap;word-break:break-all}
.deq td{background:#fff}.deq .dm{color:#aaa}
.ddel td{background:#ffebee}.ddel .dm{color:#c62828}
.dadd td{background:#e8f5e9}.dadd .dm{color:#2e7d32}
.diff-skip td{background:#f5f5f5;color:#9e9e9e;text-align:center;font-style:italic;padding:3px;font-size:11px}
.diff-ok{color:#2e7d32;font-style:italic;padding:8px 12px;display:block}
.diff-err{color:#c62828;font-style:italic;padding:8px 12px;display:block}
</style>
<script>
function toggleDiff(id) {
  var row = document.getElementById(id);
  var btn = row.previousElementSibling.querySelector('.diff-btn');
  if (!row || !btn) return;
  if (row.style.display === 'none') {
    row.style.display = '';
    btn.textContent = 'Hide Diff';
    btn.style.background = '#bf360c';
  } else {
    row.style.display = 'none';
    btn.textContent = 'Show Diff';
    btn.style.background = '';
  }
}
</script>
</head><body>
<p class="page-title">Folder Comparison Report</p>
<div class="meta">
  <span><b>Source:</b> $srcHtml</span>
  <span><b>Targets:</b> $(ConvertTo-HtmlText ($TargetServers -join ', '))</span>
  <span><b>Generated:</b> $reportDate</span>
  <span><b>Duration:</b> ${Duration}s</span>
</div>
<h2>Summary</h2>
<div class="sum-wrap"><table class="sum">
  <thead><tr><th>Server</th><th>Status</th><th title="In source, missing from target">Only in Source</th><th title="In target, not in source">Only in Target</th><th title="Same name, different content">Content Differs</th><th>Identical</th></tr></thead>
  <tbody>$($summaryRows -join "`n")</tbody>
</table></div>
<h2>Details</h2>
<div class="legend">
  <div class="leg"><div class="leg-dot" style="background:#fff8f0;border-color:#ffb74d"></div> Only in source</div>
  <div class="leg"><div class="leg-dot" style="background:#fff0f4;border-color:#f48fb1"></div> Only in target</div>
  <div class="leg"><div class="leg-dot" style="background:#f0fff4;border-color:#a5d6a7"></div> Content differs</div>
</div>
$($detailSections -join "`n")
</body></html>
"@
}

# ══════════════════════════════════════════════════════════════════════════════
# GUI
# ══════════════════════════════════════════════════════════════════════════════

# ── שמירה וטעינה של הגדרות ───────────────────────────────────────────────────
$script:configPath = Join-Path (Split-Path $MyInvocation.MyCommand.Path) 'FolderCompare.config.json'

function Save-Config {
    param($Source, $Targets, $Folder, $Output)
    $cfg = @{
        SourceServer  = $Source
        TargetServers = $Targets
        FolderPath    = $Folder
        OutputHtml    = $Output
    }
    $cfg | ConvertTo-Json | Out-File -FilePath $script:configPath -Encoding UTF8 -Force
}

function Load-Config {
    if (-not (Test-Path $script:configPath)) { return $null }
    try   { return Get-Content $script:configPath -Raw | ConvertFrom-Json }
    catch { return $null }
}

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'Folder Comparison Tool'
$form.Size            = New-Object System.Drawing.Size(620, 510)
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false
$form.BackColor       = [System.Drawing.Color]::FromArgb(240, 242, 245)
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text      = 'Folder Comparison Tool'
$lblTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(26, 35, 126)
$lblTitle.Location  = New-Object System.Drawing.Point(20, 15)
$lblTitle.Size      = New-Object System.Drawing.Size(560, 30)
$form.Controls.Add($lblTitle)

$sep = New-Object System.Windows.Forms.Panel
$sep.Location  = New-Object System.Drawing.Point(20, 52)
$sep.Size      = New-Object System.Drawing.Size(560, 2)
$sep.BackColor = [System.Drawing.Color]::FromArgb(63, 81, 181)
$form.Controls.Add($sep)

function Add-Row {
    param($Parent, [string]$LabelText, [string]$Default, [int]$Top)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $LabelText; $lbl.Location = New-Object System.Drawing.Point(20, $Top)
    $lbl.Size = New-Object System.Drawing.Size(150, 20)
    $lbl.ForeColor = [System.Drawing.Color]::FromArgb(40,53,147)
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $Parent.Controls.Add($lbl)
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Text = $Default; $txt.Location = New-Object System.Drawing.Point(175, ($Top-2))
    $txt.Size = New-Object System.Drawing.Size(405, 22); $txt.BackColor = [System.Drawing.Color]::White
    $Parent.Controls.Add($txt)
    return $txt
}

$txtSource  = Add-Row $form 'Source Server:'  '172.29.0.30'                                      75
$txtTargets = Add-Row $form 'Target Servers:' '172.29.0.31, 172.29.0.36'                         115
$txtFolder  = Add-Row $form 'Folder Path:'    'd$\Ness\staticcontent\digitalPrivateReact'         155

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text      = 'Target Servers: comma-separated   |   Folder Path: relative to server root'
$lblHint.Location  = New-Object System.Drawing.Point(20, 185)
$lblHint.Size      = New-Object System.Drawing.Size(560, 18)
$lblHint.ForeColor = [System.Drawing.Color]::Gray
$lblHint.Font      = New-Object System.Drawing.Font('Segoe UI', 8)
$form.Controls.Add($lblHint)

$lblOut = New-Object System.Windows.Forms.Label
$lblOut.Text = 'Output HTML:'; $lblOut.Location = New-Object System.Drawing.Point(20, 215)
$lblOut.Size = New-Object System.Drawing.Size(150, 20)
$lblOut.ForeColor = [System.Drawing.Color]::FromArgb(40,53,147)
$lblOut.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblOut)

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Text = "$env:USERPROFILE\Desktop\FolderCompare.html"
$txtOutput.Location = New-Object System.Drawing.Point(175, 213)
$txtOutput.Size = New-Object System.Drawing.Size(325, 22)
$txtOutput.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($txtOutput)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '...'; $btnBrowse.Location = New-Object System.Drawing.Point(505, 212)
$btnBrowse.Size = New-Object System.Drawing.Size(75, 24)
$btnBrowse.BackColor = [System.Drawing.Color]::FromArgb(63,81,181)
$btnBrowse.ForeColor = [System.Drawing.Color]::White
$btnBrowse.FlatStyle = 'Flat'
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'HTML files (*.html)|*.html'; $dlg.FileName = 'FolderCompare.html'
    if ($dlg.ShowDialog() -eq 'OK') { $txtOutput.Text = $dlg.FileName }
})
$form.Controls.Add($btnBrowse)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = 'Log:'; $lblLog.Location = New-Object System.Drawing.Point(20, 250)
$lblLog.Size = New-Object System.Drawing.Size(60, 18)
$lblLog.ForeColor = [System.Drawing.Color]::FromArgb(40,53,147)
$lblLog.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Location = New-Object System.Drawing.Point(20, 272)
$txtLog.Size = New-Object System.Drawing.Size(560, 140)
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(200,200,200)
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($txtLog)

function Write-Log {
    param([string]$Msg, [System.Drawing.Color]$Color = [System.Drawing.Color]::FromArgb(200,200,200))
    $txtLog.SelectionStart = $txtLog.TextLength; $txtLog.SelectionLength = 0
    $txtLog.SelectionColor = $Color
    $txtLog.AppendText("$Msg`n")
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = 'Run Comparison'; $btnRun.Location = New-Object System.Drawing.Point(20, 428)
$btnRun.Size = New-Object System.Drawing.Size(160, 36)
$btnRun.BackColor = [System.Drawing.Color]::FromArgb(63,81,181)
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = 'Flat'
$btnRun.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnRun)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Clear Log'; $btnClear.Location = New-Object System.Drawing.Point(190, 428)
$btnClear.Size = New-Object System.Drawing.Size(100, 36)
$btnClear.BackColor = [System.Drawing.Color]::FromArgb(96,125,139)
$btnClear.ForeColor = [System.Drawing.Color]::White
$btnClear.FlatStyle = 'Flat'
$btnClear.Add_Click({ $txtLog.Clear() })
$form.Controls.Add($btnClear)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save Settings'; $btnSave.Location = New-Object System.Drawing.Point(298, 428)
$btnSave.Size = New-Object System.Drawing.Size(110, 36)
$btnSave.BackColor = [System.Drawing.Color]::FromArgb(46,125,50)
$btnSave.ForeColor = [System.Drawing.Color]::White
$btnSave.FlatStyle = 'Flat'
$btnSave.Add_Click({
    Save-Config -Source  $txtSource.Text.Trim() `
                -Targets $txtTargets.Text.Trim() `
                -Folder  $txtFolder.Text.Trim() `
                -Output  $txtOutput.Text.Trim()
    Write-Log "Settings saved to: $script:configPath" ([System.Drawing.Color]::FromArgb(102,187,106))
})
$form.Controls.Add($btnSave)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = 'Close'; $btnClose.Location = New-Object System.Drawing.Point(500, 428)
$btnClose.Size = New-Object System.Drawing.Size(100, 36)
$btnClose.BackColor = [System.Drawing.Color]::FromArgb(183,28,28)
$btnClose.ForeColor = [System.Drawing.Color]::White
$btnClose.FlatStyle = 'Flat'
$btnClose.Add_Click({ $form.Close() })
$form.Controls.Add($btnClose)

# ── טעינת הגדרות שמורות בפתיחה ───────────────────────────────────────────────
$savedCfg = Load-Config
if ($savedCfg) {
    if ($savedCfg.SourceServer)  { $txtSource.Text  = $savedCfg.SourceServer }
    if ($savedCfg.TargetServers) { $txtTargets.Text = $savedCfg.TargetServers }
    if ($savedCfg.FolderPath)    { $txtFolder.Text  = $savedCfg.FolderPath }
    if ($savedCfg.OutputHtml)    { $txtOutput.Text  = $savedCfg.OutputHtml }
}

# ── לוגיקת כפתור Run ──────────────────────────────────────────────────────────
$btnRun.Add_Click({
    $sourceServer  = $txtSource.Text.Trim()
    $targetServers = $txtTargets.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $folderPath    = $txtFolder.Text.Trim()
    $outputHtml    = $txtOutput.Text.Trim()

    if (-not $sourceServer)         { [System.Windows.Forms.MessageBox]::Show('Please enter a Source Server.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning); return }
    if ($targetServers.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Please enter at least one Target Server.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning); return }
    if (-not $folderPath)           { [System.Windows.Forms.MessageBox]::Show('Please enter a Folder Path.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning); return }
    if (-not $outputHtml)           { [System.Windows.Forms.MessageBox]::Show('Please enter an Output HTML path.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning); return }

    $btnRun.Enabled = $false
    $txtLog.Clear()

    $cleanFolder = $folderPath.Trim('\').Trim('/')
    $sourcePath  = "\\$sourceServer\$cleanFolder"
    $startTime   = Get-Date

    Write-Log "Source : $sourcePath"                          ([System.Drawing.Color]::FromArgb(144,202,249))
    Write-Log "Targets: $($targetServers -join ', ')"         ([System.Drawing.Color]::FromArgb(144,202,249))
    Write-Log "Step 1/2 - Running Robocopy comparisons + diffs..." ([System.Drawing.Color]::FromArgb(180,180,180))

    try {
        $allResults = Invoke-Comparison -SourceServer $sourceServer -TargetServers $targetServers -FolderPath $folderPath

        foreach ($srv in $allResults.Keys) {
            $r = $allResults[$srv]
            if ($r.Error) {
                Write-Log "  $srv  ERROR"    ([System.Drawing.Color]::FromArgb(239,83,80))
                Write-Log "    $($r.Error)" ([System.Drawing.Color]::FromArgb(239,83,80))
            } else {
                $col = if ($r.TotalDiff -eq 0) { [System.Drawing.Color]::FromArgb(102,187,106) } else { [System.Drawing.Color]::FromArgb(255,213,79) }
                Write-Log "  $srv  $($r.TotalDiff) diff(s)" $col
                if (@($r.OnlyInSource).Count -gt 0) { Write-Log "    Only in source   : $(@($r.OnlyInSource).Count)"   ([System.Drawing.Color]::FromArgb(255,183,77)) }
                if (@($r.OnlyInDest).Count   -gt 0) { Write-Log "    Only in target   : $(@($r.OnlyInDest).Count)"     ([System.Drawing.Color]::FromArgb(239,83,80))  }
                if (@($r.ContentDiffers).Count -gt 0) { Write-Log "  Content differs  : $(@($r.ContentDiffers).Count)" ([System.Drawing.Color]::FromArgb(255,213,79)) }
            }
        }

        Write-Log "Step 2/2 - Building HTML report..." ([System.Drawing.Color]::FromArgb(180,180,180))
        $duration = [int]((Get-Date) - $startTime).TotalSeconds
        $html     = Build-HtmlReport -AllResults $allResults -SourceServer $sourceServer -TargetServers $targetServers -SourcePath $sourcePath -StartTime $startTime -Duration $duration

        $outputDir = Split-Path $outputHtml -Parent
        if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

        $html | Out-File -FilePath $outputHtml -Encoding UTF8 -Force

        Write-Log ""
        Write-Log "Done! Report saved: $outputHtml" ([System.Drawing.Color]::FromArgb(102,187,106))
        Write-Log "Duration: ${duration}s"          ([System.Drawing.Color]::FromArgb(180,180,180))

        Start-Process explorer.exe $outputHtml
    }
    catch {
        Write-Log "ERROR: $_" ([System.Drawing.Color]::FromArgb(239,83,80))
    }
    finally {
        $btnRun.Enabled = $true
    }
})

[void]$form.ShowDialog()
