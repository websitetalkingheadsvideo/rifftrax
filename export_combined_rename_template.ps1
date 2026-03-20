# Writes combined_rename_map.csv: RFC 4180 CSV, columns OldRel,NewRel (relative to Combined).
# NewRel empty = no rename for that row (rename_from_map.ps1 still checks OldRel exists on disk).

param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [Parameter(Mandatory = $true)]
    [string]$OutMapPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Rfc4180CsvField {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $s = $Value.Replace('"', '""')
    return '"' + $s + '"'
}

if (-not (Test-Path -LiteralPath $RootPath)) {
    throw [System.IO.DirectoryNotFoundException]::new("RootPath not found: $RootPath")
}

$videoExt = [string[]]@('.mkv', '.mp4', '.avi', '.m4v', '.mov', '.wmv', '.webm', '.mpg', '.mpeg', '.ts', '.m2ts')
$rootFull = (Get-Item -LiteralPath $RootPath).FullName

function Get-RelativePathFromRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$FullPath
    )

    $rf = [System.IO.Path]::GetFullPath($Root)
    $ff = [System.IO.Path]::GetFullPath($FullPath)
    if (-not $ff.StartsWith($rf, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "File not under root: $FullPath"
    }

    return $ff.Substring($rf.Length).TrimStart('\')
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('OldRel,NewRel')

$files = Get-ChildItem -LiteralPath $RootPath -Recurse -File | Where-Object { $videoExt -contains $_.Extension.ToLowerInvariant() } | Sort-Object FullName
foreach ($f in $files) {
    $rel = Get-RelativePathFromRoot -Root $rootFull -FullPath $f.FullName
    $o = ConvertTo-Rfc4180CsvField -Value $rel
    $n = ConvertTo-Rfc4180CsvField -Value ''
    [void]$sb.AppendLine($o + ',' + $n)
}

$dir = Split-Path -Parent $OutMapPath
if (-not (Test-Path -LiteralPath $dir)) {
    throw "Output folder not found: $dir"
}

[System.IO.File]::WriteAllText($OutMapPath, $sb.ToString(), $utf8NoBom)
Write-Output ("Wrote " + $files.Count + " rows to: " + $OutMapPath)
