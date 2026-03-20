# Workflow: (1) RUN_EXPORT_RENAME_TEMPLATE.bat -> combined_rename_map.csv (OldRel,NewRel)
# (2) Edit CSV (Excel, ReNamer export, Cursor). Empty NewRel = no rename; OldRel must still exist on disk.
# (3) RUN_RENAME_FROM_MAP_DRYRUN.bat  (4) RUN_RENAME_FROM_MAP_APPLY.bat
# ColumnSeparator: Csv | Pipe | Tab

param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [Parameter(Mandatory = $true)]
    [string]$MapPath,
    [Parameter(Mandatory = $true)]
    [ValidateSet('DryRun', 'Apply')]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [ValidateSet('Csv', 'Pipe', 'Tab')]
    [string]$ColumnSeparator
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-RelSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $t = $Value.Trim()
    $t = $t -replace '/', '\'
    $t = $t.TrimStart('\')
    return $t
}

function Get-RelativePathFromRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$FullPath
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $fileFull = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $fileFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "File is not under root: $FullPath (root: $rootFull)"
    }

    $rel = $fileFull.Substring($rootFull.Length)
    $rel = $rel.TrimStart('\')
    return $rel
}

if (-not (Test-Path -LiteralPath $RootPath)) {
    throw [System.IO.DirectoryNotFoundException]::new("RootPath not found: $RootPath")
}

if (-not (Test-Path -LiteralPath $MapPath)) {
    throw [System.IO.FileNotFoundException]::new("Map file not found: $MapPath")
}

$rootItem = Get-Item -LiteralPath $RootPath
$allFiles = Get-ChildItem -LiteralPath $RootPath -Recurse -File

$nameToPaths = @{}
foreach ($f in $allFiles) {
    $n = $f.Name
    if (-not $nameToPaths.ContainsKey($n)) {
        $nameToPaths[$n] = New-Object System.Collections.Generic.List[string]
    }
    [void]$nameToPaths[$n].Add($f.FullName)
}

$relToFull = @{}
foreach ($f in $allFiles) {
    $rel = Get-RelativePathFromRoot -Root $rootItem.FullName -FullPath $f.FullName
    $key = Normalize-RelSegment -Value $rel
    if ($relToFull.ContainsKey($key)) {
        throw "Internal: duplicate relative key: $key"
    }
    $relToFull[$key] = $f.FullName
}

function Resolve-MapOldToFullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OldColumn
    )

    $oldNorm = Normalize-RelSegment -Value $OldColumn
    if ($oldNorm -match '\\') {
        if (-not $relToFull.ContainsKey($oldNorm)) {
            throw "Map references unknown path under root: $oldNorm"
        }
        return $relToFull[$oldNorm]
    }

    if (-not $nameToPaths.ContainsKey($oldNorm)) {
        throw "Map references unknown file name under root: $oldNorm"
    }
    $cands = $nameToPaths[$oldNorm]
    if ($cands.Count -gt 1) {
        $listed = ($cands | ForEach-Object { Get-RelativePathFromRoot -Root $rootItem.FullName -FullPath $_ }) -join '; '
        throw "File name is not unique under root (use RelPath with backslash): $oldNorm - matches: $listed"
    }
    return $cands[0]
}

function Read-MapCsvCell {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Record,
        [Parameter(Mandatory = $true)]
        [string[]]$HeaderNamesInOrder
    )

    foreach ($h in $HeaderNamesInOrder) {
        foreach ($prop in $Record.PSObject.Properties) {
            if ($prop.Name.Equals($h, [System.StringComparison]::OrdinalIgnoreCase)) {
                $v = $prop.Value
                if ($null -eq $v) {
                    return ''
                }
                return [string]$v
            }
        }
    }

    return $null
}

function Split-MapLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Pipe', 'Tab')]
        [string]$SeparatorKind
    )

    $sep = if ($SeparatorKind -eq 'Pipe') { '|' } else { "`t" }
    $idx = $Line.IndexOf($sep)
    if ($idx -lt 0) {
        throw "Map line must contain separator '$sep' exactly once (old then new): $Line"
    }
    $idx2 = $Line.IndexOf($sep, $idx + $sep.Length)
    if ($idx2 -ge 0) {
        throw "Map line contains more than one column separator - fix the line: $Line"
    }

    $oldCol = $Line.Substring(0, $idx).Trim()
    $newCol = $Line.Substring($idx + $sep.Length).Trim()
    if ([string]::IsNullOrWhiteSpace($oldCol)) {
        throw "Map line has empty left column (current name): $Line"
    }
    return [pscustomobject]@{
        Old = $oldCol
        New = if ([string]::IsNullOrWhiteSpace($newCol)) { '' } else { $newCol }
    }
}

$rows = New-Object System.Collections.Generic.List[object]
$skippedEmptyRight = 0
$emptyRightResolvedRel = New-Object System.Collections.Generic.List[string]

if ($ColumnSeparator -eq 'Csv') {
    $sr = New-Object System.IO.StreamReader -ArgumentList @($MapPath, [System.Text.Encoding]::UTF8, $true)
    try {
        $csvText = $sr.ReadToEnd()
    }
    finally {
        $sr.Close()
    }
    $csvData = @($csvText | ConvertFrom-Csv)
    if ($csvData.Count -eq 0) {
        throw "CSV map is empty or unreadable: $MapPath"
    }
    $rowIx = 0
    foreach ($record in $csvData) {
        $rowIx += 1
        $lineNum = $rowIx + 1
        $oldCol = Read-MapCsvCell -Record $record -HeaderNamesInOrder @('OldRel', 'From', 'Source')
        $newCol = Read-MapCsvCell -Record $record -HeaderNamesInOrder @('NewRel', 'To', 'Target')
        if ($null -eq $oldCol) {
            throw ("CSV map row {0} (file line {1}): missing OldRel column (or alias From, Source). Headers must include OldRel." -f $rowIx, $lineNum)
        }
        if ($null -eq $newCol) {
            throw ("CSV map row {0} (file line {1}): missing NewRel column (or alias To, Target). Headers must include NewRel." -f $rowIx, $lineNum)
        }
        $oldCol = $oldCol.Trim()
        $newCol = $newCol.Trim()
        if ([string]::IsNullOrWhiteSpace($oldCol)) {
            throw ("CSV map row {0} (file line {1}): OldRel is empty." -f $rowIx, $lineNum)
        }
        try {
            if ([string]::IsNullOrWhiteSpace($newCol)) {
                try {
                    $resolvedFull = Resolve-MapOldToFullPath -OldColumn $oldCol
                    $relOk = Get-RelativePathFromRoot -Root $rootItem.FullName -FullPath $resolvedFull
                    [void]$emptyRightResolvedRel.Add($relOk)
                    $skippedEmptyRight += 1
                }
                catch {
                    throw ("CSV row {0} (file line {1}): NewRel empty - OldRel must match a file under root. Resolve failed: {2}`n  OldRel was: {3}" -f $rowIx, $lineNum, $_.Exception.Message, $oldCol)
                }
                continue
            }
            [void]$rows.Add([pscustomobject]@{ Old = $oldCol; New = $newCol })
        }
        catch {
            throw "Map parse error at CSV row ${rowIx} (file line ${lineNum}): $($_.Exception.Message)"
        }
    }
}
else {
    $rawLines = Get-Content -LiteralPath $MapPath -Encoding UTF8
    $lineNum = 0
    foreach ($line in $rawLines) {
        $lineNum += 1
        $trim = $line.Trim()
        if ($trim.Length -eq 0) {
            continue
        }
        if ($trim.StartsWith('#')) {
            continue
        }
        try {
            $parsed = Split-MapLine -Line $line -SeparatorKind $ColumnSeparator
            if ([string]::IsNullOrWhiteSpace($parsed.New)) {
                try {
                    $resolvedFull = Resolve-MapOldToFullPath -OldColumn $parsed.Old
                    $relOk = Get-RelativePathFromRoot -Root $rootItem.FullName -FullPath $resolvedFull
                    [void]$emptyRightResolvedRel.Add($relOk)
                    $skippedEmptyRight += 1
                }
                catch {
                    throw ("Map line {0}: nothing after '{1}' - still must point at a real file under root. Resolve failed: {2}`n  Left column was: {3}" -f $lineNum, $(if ($ColumnSeparator -eq 'Pipe') { '|' } else { 'TAB' }), $_.Exception.Message, $parsed.Old)
                }
                continue
            }
            [void]$rows.Add($parsed)
        }
        catch {
            throw "Map parse error at line ${lineNum}: $($_.Exception.Message)"
        }
    }
}

$mapItem = Get-Item -LiteralPath $MapPath
$logPath = Join-Path -Path $mapItem.DirectoryName -ChildPath 'rename_from_map.log'
$log = New-Object System.Collections.Generic.List[string]
$rootResolved = [System.IO.Path]::GetFullPath($rootItem.FullName)
[void]$log.Add(("Mode={0} ColumnSeparator={1} RootPath={2} MapPath={3} RenamesPlanned={4} EmptyRightLines={5} EmptyRightVerifiedOk={6} FilesOnDiskUnderRoot={7}" -f $Mode, $ColumnSeparator, $rootResolved, $MapPath, $rows.Count, $skippedEmptyRight, $emptyRightResolvedRel.Count, $allFiles.Count))
[void]$log.Add('')
if ($skippedEmptyRight -gt 0) {
    [void]$log.Add('--- Left column OK, right empty (no rename) ---')
    foreach ($rel in $emptyRightResolvedRel) {
        [void]$log.Add(('EMPTY_RIGHT_OK`t{0}' -f $rel))
    }
    [void]$log.Add('')
}

$planned = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
    $srcFull = Resolve-MapOldToFullPath -OldColumn $r.Old
    $srcDir = [System.IO.Path]::GetDirectoryName($srcFull)
    $newNorm = Normalize-RelSegment -Value $r.New

    if ($newNorm -match '\\') {
        $destRel = $newNorm
    }
    else {
        $srcRel = Get-RelativePathFromRoot -Root $rootItem.FullName -FullPath $srcFull
        $srcRelNorm = Normalize-RelSegment -Value $srcRel
        $parentRel = ''
        $idx = $srcRelNorm.LastIndexOf('\')
        if ($idx -ge 0) {
            $parentRel = $srcRelNorm.Substring(0, $idx)
        }
        if ($parentRel.Length -gt 0) {
            $destRel = $parentRel + '\' + $newNorm
        }
        else {
            $destRel = $newNorm
        }
    }

    $destFull = Join-Path -Path $rootItem.FullName -ChildPath $destRel
    $destFull = [System.IO.Path]::GetFullPath($destFull)

    if (-not $destFull.StartsWith([System.IO.Path]::GetFullPath($rootItem.FullName), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing destination outside root: $destFull"
    }

    $destDir = Split-Path -Parent $destFull
    if (-not (Test-Path -LiteralPath $destDir)) {
        throw "Destination folder does not exist (create it first): $destDir"
    }

    [void]$planned.Add([pscustomobject]@{
            SrcFull = $srcFull
            DestFull = $destFull
            OldMap = $r.Old
            NewMap = $r.New
        })
}

# Detect duplicate sources or destinations in map
$srcSeen = @{}
$destSeen = @{}
foreach ($p in $planned) {
    $sk = $p.SrcFull.ToLowerInvariant()
    if ($srcSeen.ContainsKey($sk)) {
        throw "Map lists two rows for the same source file: $($p.SrcFull)"
    }
    $srcSeen[$sk] = $true

    $dk = $p.DestFull.ToLowerInvariant()
    if ($destSeen.ContainsKey($dk)) {
        throw "Map lists two rows targeting the same destination: $($p.DestFull)"
    }
    $destSeen[$dk] = $true
}

$apply = ($Mode -eq 'Apply')
$countWouldRename = 0
$countSkipSame = 0
foreach ($p in $planned) {
    $destName = Split-Path -Leaf $p.DestFull
    if ($p.SrcFull -eq $p.DestFull) {
        $countSkipSame += 1
        [void]$log.Add(("SKIP_SAME`t{0}" -f $p.SrcFull))
        continue
    }

    if (Test-Path -LiteralPath $p.DestFull) {
        throw "Destination already exists (refusing overwrite): $($p.DestFull)"
    }

    $countWouldRename += 1
    $relFrom = Get-RelativePathFromRoot -Root $rootItem.FullName -FullPath $p.SrcFull
    $relTo = Get-RelativePathFromRoot -Root $rootItem.FullName -FullPath $p.DestFull
    $line = ("PLAN`t{0}`t->`t{1}" -f $p.SrcFull, $p.DestFull)
    $lineShort = ("{0}  ->  {1}" -f $relFrom, $relTo)
    Write-Output $lineShort
    [void]$log.Add($line)

    if ($apply) {
        $srcDir = [System.IO.Path]::GetDirectoryName($p.SrcFull)
        $destDir = Split-Path -Parent $p.DestFull
        $srcDirNorm = [System.IO.Path]::GetFullPath($srcDir)
        $destDirNorm = [System.IO.Path]::GetFullPath($destDir)
        if ($srcDirNorm.Equals($destDirNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
            Rename-Item -LiteralPath $p.SrcFull -NewName $destName -ErrorAction Stop
        }
        else {
            Move-Item -LiteralPath $p.SrcFull -Destination $p.DestFull -ErrorAction Stop
        }
        [void]$log.Add(("RENAMED`t{0}`t->`t{1}" -f $p.SrcFull, $p.DestFull))
    }
}

[void]$log.Add('')
[void]$log.Add(("Summary: WouldRename={0} SkipSamePath={1} EmptyRightNoRename={2}" -f $countWouldRename, $countSkipSame, $skippedEmptyRight))
[void]$log.Add('Done.')
$log | Set-Content -LiteralPath $logPath -Encoding UTF8

Write-Output ''
Write-Output '=== rename_from_map (read this block) ==='
Write-Output ("Root: {0}" -f $rootResolved)
Write-Output ("Files on disk under root: {0}" -f $allFiles.Count)
Write-Output ("Map rows with a NEW name (rename planned): {0}" -f $rows.Count)
if ($skippedEmptyRight -gt 0) {
    Write-Output ("Lines with empty right (no rename): {0} - each left column matched exactly one file under root." -f $skippedEmptyRight)
}
Write-Output ("Would rename / move: {0}" -f $countWouldRename)
Write-Output ("Skip (already correct path): {0}" -f $countSkipSame)
if ($countWouldRename -eq 0) {
    Write-Output ''
    $hint = if ($ColumnSeparator -eq 'Csv') { 'Fill NewRel for rows you want renamed.' } else { 'Add text after the separator on lines where you want a new name.' }
    Write-Output ('Nothing to do for renames: {0}' -f $hint)
}
Write-Output ("Full log: {0}" -f $logPath)
if (-not $apply) {
    Write-Output 'DryRun: no files were renamed. If counts look right, run Mode Apply.'
}
