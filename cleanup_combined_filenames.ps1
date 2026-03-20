param(
    [Parameter(Mandatory = $false)]
    [string]$TargetRoot = '\\amber\Rifftrax\Combined',
    [Parameter(Mandatory = $true)]
    [switch]$DoIt,
    [Parameter(Mandatory = $false)]
    [switch]$NoPrettySpaces
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $TargetRoot)) {
    throw [System.IO.DirectoryNotFoundException]::new("Folder not found: $TargetRoot")
}

if (-not $DoIt) {
    Write-Output 'Refusing to run without -DoIt'
    exit 2
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$LogPath = Join-Path -Path $scriptDir -ChildPath 'cleanup_combined_filenames.log'
$ReportPath = Join-Path -Path $scriptDir -ChildPath 'cleanup_combined_report.txt'

# Normalize every Unicode space separator to ASCII space (NBSP etc. breaks '\s+' split on some builds).
function Convert-UnicodeSpacesToAscii {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $t = $Value.Trim()
    $t = $t.Normalize([System.Text.NormalizationForm]::FormKC)
    $t = $t -replace '[\u200B-\u200D\uFEFF]', ''
    $t = $t -replace '\p{Zs}+', ' '
    $t = $t -replace '\s+', ' '
    return $t.Trim()
}

# Only real video heights (not "3720p" inside "1993720p").
function Get-ResolutionHeightAlternationPattern {
    return '(?:360|480|540|576|720|768|1080|1440|2160|4320|8640)'
}

# Some renames/tools produced "C a t s" / "R i f f t r a x" / "H E V C" - merge those runs so stripping works.
function Merge-ConsecutiveSingleCharAlnumTokens {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $normalized = Convert-UnicodeSpacesToAscii -Value $Value
    # NEVER pass StringSplitOptions as the 2nd arg to -split: it is cast to int (RemoveEmptyEntries=1)
    # and becomes "max substrings", so the whole basename stays one token and merge never runs.
    $parts = @(
        foreach ($x in ($normalized -split '\s+')) {
            if (-not [string]::IsNullOrWhiteSpace($x)) {
                $x
            }
        }
    )
    if ($parts.Count -eq 0) {
        return $normalized
    }

    $out = New-Object System.Collections.Generic.List[string]
    $acc = New-Object System.Text.StringBuilder

    foreach ($p in $parts) {
        # Use Unicode-aware letter/digit check. Explorer can show "AeonFlux" but chars may be fullwidth
        # or compatibility forms; [A-Za-z0-9] fails, every char becomes its own token, -join ' ' -> "A e o n".
        $isSingleLetterOrDigit = $false
        if ($p.Length -eq 1) {
            $ch0 = $p[0]
            $isSingleLetterOrDigit = [char]::IsLetterOrDigit($ch0)
        }
        if ($isSingleLetterOrDigit) {
            # "6c" + "h" as tokens: do not start a new acc with lone "h" - append to "\d+c" word
            if ($acc.Length -eq 0 -and $p -eq 'h' -and $out.Count -gt 0) {
                $last = $out[$out.Count - 1]
                if ($last -match '^\d+c$') {
                    $out[$out.Count - 1] = $last + 'h'
                    continue
                }
            }
            [void]$acc.Append($p[0])
        } else {
            if ($acc.Length -gt 0) {
                [void]$out.Add($acc.ToString())
                $null = $acc.Clear()
            }
            [void]$out.Add($p)
        }
    }
    if ($acc.Length -gt 0) {
        [void]$out.Add($acc.ToString())
    }

    return (($out | ForEach-Object { $_ }) -join ' ').Trim()
}

function Merge-ConsecutiveSingleCharAlnumTokensUntilStable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $prev = $null
    $cur = $Value
    $guard = 0
    while ($prev -ne $cur) {
        $prev = $cur
        $cur = Merge-ConsecutiveSingleCharAlnumTokens -Value $cur
        $guard += 1
        if ($guard -gt 20) {
            throw "Merge-ConsecutiveSingleCharAlnumTokensUntilStable: guard exceeded"
        }
    }
    return $cur
}

# When filenames have zero spaces (user collapsed them), token-splitting cannot see 1080p/Rifftrax/etc.
# Peel known release/encode tails from the RIGHT on the compact string (case-insensitive).
function Invoke-StripGluedReleaseTailOnce {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $patterns = [string[]]@(
        '(?i)(?:h\.?26[45]|x26[45]|h26[45])$',
        '(?i)(?:hevc|avc|av1)$',
        '(?i)(?:aac|ac3|dts|truehd|flac|eac3)$',
        '(?i)v\d+$',
        '(?i)\d+ch$',
        '(?i)rifftrax$',
        ('(?i)' + (Get-ResolutionHeightAlternationPattern) + 'p$'),
        '(?i)(?:webrip|webdl|bluray|bdrip|brrip|remux|hdtv|dvdrip)$',
        '(?i)dualaudio$'
    )

    foreach ($p in $patterns) {
        $next = $Value -replace $p, ''
        if ($next -ne $Value) {
            return $next
        }
    }

    return $Value
}

function Invoke-StripGluedReleaseTailUntilStable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $prev = $null
    $cur = $Value
    $guard = 0
    while ($prev -ne $cur) {
        $prev = $cur
        $cur = Invoke-StripGluedReleaseTailOnce -Value $cur
        $guard += 1
        if ($guard -gt 200) {
            throw "Invoke-StripGluedReleaseTailUntilStable: guard exceeded"
        }
    }
    return $cur
}

# "Cats2019" / "Beowulf2007" -> space before trailing year (Plex-friendly), without eating titles like "300".
function Add-SpaceBeforeTrailingMovieYear {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    $m = [regex]::Match($Value, '^(?i)(.+)((?:19|20)\d{2})$')
    if (-not $m.Success) {
        return $Value
    }

    $prefix = [string]$m.Groups[1].Value
    $yearText = [string]$m.Groups[2].Value
    if ($prefix.Length -lt 1) {
        return $Value
    }

    $yearNum = 0
    $parsed = [int]::TryParse($yearText, [ref]$yearNum)
    if (-not $parsed) {
        return $Value
    }

    if ($yearNum -lt 1900 -or $yearNum -gt 2035) {
        return $Value
    }

    return ($prefix + ' ' + $yearText)
}

# Regex often misses glued or oddly spaced release tails; this peels tokens from the RIGHT.
function Invoke-StripReleaseTailByTokens {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $patternWeb = '^(webdl|webrip|bluray|bdrip|brrip|remux|hdtv|dvdrip)$'
    $patternAudio = '^(aac|ac3|dts|truehd|flac|eac3)$'
    $resH = Get-ResolutionHeightAlternationPattern
    $patternResP = '^' + $resH + 'p$'

    $normalized = Convert-UnicodeSpacesToAscii -Value $Value
    $normalized = $normalized -replace '_+', ' '
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($p in ($normalized -split '\s+')) {
        if ([string]::IsNullOrWhiteSpace($p)) {
            continue
        }
        [void]$list.Add($p)
    }

    $pass = $true
    while ($pass -and $list.Count -gt 0) {
        $pass = $false
        $last = $list[$list.Count - 1]
        $L = $last.ToLowerInvariant()

        if ($L -match '^v\d+$') {
            $list.RemoveAt($list.Count - 1)
            $pass = $true
            continue
        }
        if ($L -match '^(hevc|avc|av1)$') {
            $list.RemoveAt($list.Count - 1)
            $pass = $true
            continue
        }
        if ($L -match '^x26[45]$' -or $L -match '^h26[45]$') {
            $list.RemoveAt($list.Count - 1)
            $pass = $true
            continue
        }
        if ($L -match '^\d+ch$') {
            $list.RemoveAt($list.Count - 1)
            $pass = $true
            continue
        }
        if ($list.Count -ge 2) {
            $prev = $list[$list.Count - 2]
            $pLow = $prev.ToLowerInvariant()
            if ($L -eq 'h' -and $prev -match '^\d+c$') {
                $list.RemoveAt($list.Count - 1)
                $list.RemoveAt($list.Count - 1)
                $pass = $true
                continue
            }
            if ($L -eq 'ch' -and $prev -match '^\d+$') {
                $list.RemoveAt($list.Count - 1)
                $list.RemoveAt($list.Count - 1)
                $pass = $true
                continue
            }
            if ($L -eq 'c' -and $pLow -eq 'av') {
                $list.RemoveAt($list.Count - 1)
                $list.RemoveAt($list.Count - 1)
                $pass = $true
                continue
            }
            if ($L -eq 'p' -and $prev -match ('^' + $resH + '$')) {
                $list.RemoveAt($list.Count - 1)
                $list.RemoveAt($list.Count - 1)
                $pass = $true
                continue
            }
        }
        if ($L -match $patternResP) {
            $list.RemoveAt($list.Count - 1)
            $pass = $true
            continue
        }
        if ($L -eq 'rifftrax') {
            $list.RemoveAt($list.Count - 1)
            $pass = $true
            continue
        }
        if ($L -match $patternWeb) {
            $list.RemoveAt($list.Count - 1)
            $pass = $true
            continue
        }
        if ($L -match $patternAudio) {
            $list.RemoveAt($list.Count - 1)
            $pass = $true
            continue
        }
    }

    return (($list | ForEach-Object { $_ }) -join ' ').Trim()
}

function Get-CleanBaseName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseName,
        [Parameter(Mandatory = $true)]
        [bool]$SuppressPrettySeparators
    )

    # Do NOT run global "[._-]+ -> space" before stripping the tail: a single _ or . between
    # letters (M_o_v_i_e) becomes "space between every letter" and breaks the name.
    $s = Convert-UnicodeSpacesToAscii -Value $BaseName.Trim()
    if ($SuppressPrettySeparators) {
        # Drop separators without inserting spaces (keeps glued names glued).
        $s = $s -replace '_+', ''
        $s = $s -replace '\.+', ''
        $s = $s -replace '\-+', ''
    }
    else {
        # Underscore/dot runs usually separate tags; spaces let the token peeler work.
        $s = $s -replace '_+', ' '
        $s = $s -replace '\.+', ' '
        $s = $s -replace '\-+', ' '
    }
    $s = $s -replace '\s+', ' '
    $s = $s.Trim()

    $s = Merge-ConsecutiveSingleCharAlnumTokensUntilStable -Value $s

    # Collapsed filenames: "Cats20191080pRifftrax6chx265HEVC" (no spaces) - peel tails, then year.
    if ($s -notmatch '\s') {
        $s = Invoke-StripGluedReleaseTailUntilStable -Value $s
        if (-not $SuppressPrettySeparators) {
            $s = Add-SpaceBeforeTrailingMovieYear -Value $s
        }
    }

    # Phase 1: strip release/encode junk from the RIGHT only. Treat space, dot, underscore as
    # separators so "1981_1080_p_Rifftrax_6_ch_2_ch_v_2" is handled like spaced forms.
    $rh = Get-ResolutionHeightAlternationPattern
    $tailPatterns = @(
        # Exact layout from Combined folder, e.g. "2022 1080p Rifftrax 6ch x265 HEVC" (1080p often has no space)
        ('(?i)\s+(?:(?:' + $rh + ')\s*p|(?:' + $rh + ')p)\s+rifftrax\s+\d+ch\s+x26[45]\s+(?:hevc|h\.?264|h\.?265|avc|av\s*c)\s*$'),
        ('(?i)\s+(?:(?:' + $rh + ')\s*p|(?:' + $rh + ')p)\s+rifftrax\s+\d+\s*ch\s+x26[45]\s+(?:hevc|h\.?264|h\.?265|avc|av\s*c)\s*$'),
        '(?i)[\s._-]+v\s*\d+\s*$',
        '(?i)[\s._-]+\d+\s*ch\s*$',
        '(?i)[\s._-]+\d+\s*c\s*h\s*$',
        '(?i)[\s._-]+\d+c\s+h\s*$',
        '(?i)[\s._-]+\d+ch\s*$',
        '(?i)[\s._-]+rifftrax\s*$',
        ('(?i)[\s._-]+(?:' + $rh + ')\s*p\s*$'),
        ('(?i)[\s._-]+(?:' + $rh + ')p\s*$'),
        # Do NOT strip trailing (19|20)xx here - that removes real movie years like "Cats 2019".
        '(?i)[\s._-]+(?:x264|x265|h264|h265|hevc|h\.?264|h\.?265|avc|av\s*c|av1|aac|ac3|dts|truehd|flac|webrip|webdl|web\s*dl|bluray|brrip|bdrip|hdtv)\s*$'
    )

    $pass = $true
    while ($pass) {
        $pass = $false
        foreach ($p in $tailPatterns) {
            $next = $s -replace $p, ''
            if ($next -ne $s) {
                $s = $next
                $pass = $true
            }
        }
    }

    if (-not $SuppressPrettySeparators) {
        # Phase 2: CamelCase word boundaries (TitleCase words only).
        $s = $s -replace '(?<=[a-z])(?=[A-Z])', ' '

        # Phase 3: multi-character delimiter runs -> space.
        $s = $s -replace '[._\-]{2,}', ' '

        # Phase 4: single ._- only BETWEEN two "word" chunks (2+ alnum), not between single letters.
        $guard = 0
        while ($s -match '([0-9A-Za-z]{2,})[._\-]([0-9A-Za-z]{2,})') {
            $s = $s -replace '([0-9A-Za-z]{2,})[._\-]([0-9A-Za-z]{2,})', '$1 $2'
            $guard += 1
            if ($guard -gt 200) {
                throw "Get-CleanBaseName: delimiter loop exceeded guard for input: $BaseName"
            }
        }
    }

    $s = $s -replace '\s{2,}', ' '
    $s = $s.Trim()

    # Second pass: token peel (handles "AV C", "6 ch", "1080 p", 1080p, underscores, etc.)
    $prevTokenPass = $null
    while ($prevTokenPass -ne $s) {
        $prevTokenPass = $s
        $s = Invoke-StripReleaseTailByTokens -Value $s
    }

    return $s
}

$videoExt = [string[]]@('.mkv', '.mp4', '.avi', '.m4v', '.mov', '.wmv', '.webm', '.mpg', '.mpeg', '.ts', '.m2ts')
$files = Get-ChildItem -LiteralPath $TargetRoot -Recurse -File | Where-Object { $videoExt -contains $_.Extension.ToLowerInvariant() }

$renamed = 0
$skipped = 0
$skippedEmpty = 0
$skippedUnchanged = 0
$conflicts = 0
$locked = 0
$failed = 0
$logLines = New-Object System.Collections.Generic.List[string]
$reportLines = New-Object System.Collections.Generic.List[string]

$scriptSelf = $MyInvocation.MyCommand.Path
$scriptItem = Get-Item -LiteralPath $scriptSelf
$runStamp = ('Script="{0}" ScriptLastWriteUtc={1:o} TargetRoot="{2}" NoPrettySpaces={3}' -f $scriptSelf, $scriptItem.LastWriteTimeUtc, $TargetRoot, $NoPrettySpaces.IsPresent)
Write-Output $runStamp
[void]$logLines.Add($runStamp)
[void]$logLines.Add('')

[void]$reportLines.Add('Cleanup report (open with Notepad). RENAME = would change filename; SAME = already matches computed name.')
[void]$reportLines.Add($runStamp)
[void]$reportLines.Add('')

# Only treat real sharing violations as "locked". Phrases like "cannot access the file" appear for
# permissions, path length, SMB, invalid names, etc. - not exclusive to locks.
function Test-IsSharingViolation {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    $ex = $Exception
    while ($null -ne $ex) {
        $msg = $ex.Message
        if ($msg -match '(?i)being used by another process') {
            return $true
        }
        if ($msg -match '(?i)sharing violation') {
            return $true
        }
        if ($ex -is [System.IO.IOException]) {
            $hr = $ex.HResult
            # 0x80070020 ERROR_SHARING_VIOLATION
            if ($hr -eq -2147024864) {
                return $true
            }
            if (($hr -band 0xFFFF) -eq 32) {
                return $true
            }
        }
        $ex = $ex.InnerException
    }
    return $false
}

function Invoke-RenameWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,
        [Parameter(Mandatory = $true)]
        [string]$NewName,
        [Parameter(Mandatory = $true)]
        [int]$MaxAttempts,
        [Parameter(Mandatory = $true)]
        [int]$DelayMs
    )

    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt += 1
        try {
            Rename-Item -LiteralPath $LiteralPath -NewName $NewName -ErrorAction Stop
            return
        } catch {
            if ($attempt -ge $MaxAttempts -or -not (Test-IsSharingViolation -Exception $_.Exception)) {
                throw
            }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

foreach ($file in $files) {
    $cleanBase = Get-CleanBaseName -BaseName $file.BaseName -SuppressPrettySeparators $NoPrettySpaces.IsPresent
    $wouldChange = -not [string]::Equals(($cleanBase + $file.Extension), $file.Name, [System.StringComparison]::Ordinal)
    $ob = $file.BaseName -replace "`t", ' '
    $cb = $cleanBase -replace "`t", ' '
    if ($wouldChange) {
        [void]$reportLines.Add("[RENAME] $ob")
        [void]$reportLines.Add("      -> $cb")
        [void]$reportLines.Add('')
    } else {
        [void]$reportLines.Add("[SAME]   $ob")
        [void]$reportLines.Add('')
    }

    if ([string]::IsNullOrWhiteSpace($cleanBase)) {
        $skipped += 1
        $skippedEmpty += 1
        continue
    }

    $newName = $cleanBase + $file.Extension
    if ([string]::Equals($newName, $file.Name, [System.StringComparison]::Ordinal)) {
        $skipped += 1
        $skippedUnchanged += 1
        continue
    }

    $destPath = Join-Path -Path $file.DirectoryName -ChildPath $newName
    if (Test-Path -LiteralPath $destPath) {
        $conflicts += 1
        $line = "CONFLICT`t$($file.FullName)`t$destPath"
        Write-Output $line
        [void]$logLines.Add($line)
        continue
    }

    try {
        Invoke-RenameWithRetry -LiteralPath $file.FullName -NewName $newName -MaxAttempts 12 -DelayMs 400
        $renamed += 1
        $line = "RENAMED`t$($file.Name)`t$newName"
        Write-Output $line
        [void]$logLines.Add($line)
    } catch {
        if (Test-IsSharingViolation -Exception $_.Exception) {
            $locked += 1
            $line = "LOCKED`t$($file.FullName)`t$newName`t$($_.Exception.Message)"
            Write-Output $line
            [void]$logLines.Add($line)
            continue
        }
        $failed += 1
        $reason = $_.Exception.Message -replace "`r|`n", ' '
        $line = "FAIL`t$($file.FullName)`t$newName`t$reason"
        Write-Output $line
        [void]$logLines.Add($line)
        continue
    }
}

$summary = "Done. Renamed=$renamed Skipped=$skipped (empty=$skippedEmpty already_ok=$skippedUnchanged) Conflicts=$conflicts Locked=$locked Failed=$failed TargetRoot=$TargetRoot"
Write-Output $summary
[void]$logLines.Add($summary)

$logLines | Set-Content -LiteralPath $LogPath -Encoding UTF8
$reportLines | Set-Content -LiteralPath $ReportPath -Encoding UTF8

Write-Output ("Report (Notepad): " + $ReportPath)
Write-Output ("Video files scanned: " + ($files | Measure-Object).Count)

# Always exit 0 if we got this far - use summary + log for FAIL/LOCKED counts (avoids "ERROR" in CMD when the issue isn't a simple lock).
exit 0
