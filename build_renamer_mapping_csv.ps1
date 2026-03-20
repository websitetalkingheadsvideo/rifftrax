# Builds a CSV for ReNamer Mapping: col1 = basename only (matches drag-dropped Name), no header row.
# Run from repo root: pwsh -File build_renamer_mapping_csv.ps1

$inPath = Join-Path $PSScriptRoot 'combined_rename_map.csv'
$outPath = Join-Path $PSScriptRoot 'combined_rename_map_renamer_mapping.csv'

if (-not (Test-Path -LiteralPath $inPath)) {
    throw "Missing input: $inPath"
}

$rows = Import-Csv -LiteralPath $inPath
$out = New-Object System.Collections.Generic.List[string]

foreach ($r in $rows) {
    $old = $r.OldRel
    $new = $r.NewRel
    if ([string]::IsNullOrWhiteSpace($old)) { continue }
    if ([string]::IsNullOrWhiteSpace($new)) { continue }

    $base = ($old -replace '^.*[/\\]', '').Trim()
    $newT = $new.Trim()

    function Escape-CsvField([string]$s) {
        if ($s -match '[,"]') {
            return '"' + ($s -replace '"', '""') + '"'
        }
        return $s
    }

    $out.Add((Escape-CsvField $base) + ',' + (Escape-CsvField $newT))
}

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($outPath, $out, $utf8NoBom)
Write-Host "Wrote $($out.Count) rows to $outPath"
