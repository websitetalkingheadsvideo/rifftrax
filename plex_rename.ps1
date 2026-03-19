param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [Parameter(Mandatory = $false)]
    [switch]$DoIt,
    [Parameter(Mandatory = $false)]
    [string]$LogPathOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogPath = if ($LogPathOverride) { $LogPathOverride } else { Join-Path -Path $RootPath -ChildPath 'plex_rename_log.csv' }
$TvRootPath = Join-Path -Path $RootPath -ChildPath 'Combined\TV'
$ImdbCachePath = Join-Path -Path $RootPath -ChildPath 'imdb_cache.csv'

$VideoExtensions = [string[]]@(
    '.mkv', '.mp4', '.avi', '.m4v', '.mov', '.wmv', '.webm', '.mpg', '.mpeg', '.ts', '.m2ts'
)

if (-not (Test-Path -LiteralPath $RootPath)) {
    throw [System.IO.DirectoryNotFoundException]::new("RootPath does not exist: $RootPath")
}

if ($DoIt) {
    if (Test-Path -LiteralPath $LogPath) {
        Remove-Item -LiteralPath $LogPath -Force
    }
}

if (-not $DoIt) {
    Write-Output 'Refusing to run without -DoIt'
    exit 2
}

$ImdbCacheByQuery = @{}
$ImdbCacheById = @{}

if (Test-Path -LiteralPath $ImdbCachePath) {
    $rows = Import-Csv -LiteralPath $ImdbCachePath -ErrorAction Stop
    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace($row.QueryKey)) {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($row.Title)) {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($row.Year)) {
            continue
        }
        $entry = [pscustomobject]@{
            ImdbId = [string]$row.ImdbId
            Title  = [string]$row.Title
            Year   = [int]$row.Year
        }
        $ImdbCacheByQuery[[string]$row.QueryKey] = $entry
        if (-not [string]::IsNullOrWhiteSpace([string]$row.ImdbId)) {
            $ImdbCacheById[[string]$row.ImdbId] = $entry
        }
    }
}

function Write-LogLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [Parameter(Mandatory = $true)]
        [string]$MediaType,
        [Parameter(Mandatory = $true)]
        [string]$OldPath,
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$NewPath,
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    $row = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        Action    = $Action
        MediaType = $MediaType
        OldPath   = $OldPath
        NewPath   = $NewPath
        Reason    = $Reason
    }

    if (-not (Test-Path -LiteralPath $LogPath)) {
        $row | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8
    } else {
        $row | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8 -Append
    }
}

function Convert-Word {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $v = $Value.Trim()
    $v = $v -replace '[\[\]\(\)\{\}]', ' '
    $v = $v -replace '[^0-9A-Za-z]+', ' '
    $v = $v -replace '\s{2,}', ' '
    return $v.Trim()
}

function Get-TitleTokens {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Input
    )

    if ([string]::IsNullOrWhiteSpace($Input)) {
        return [string[]]@()
    }
    $raw = $Input
    $raw = $raw -replace '\.(mkv|mp4|avi|m4v|mov|wmv|webm|mpg|mpeg|ts|m2ts)$', '' -replace '\.[sS](\d{1,2})[eE](\d{1,2})', ' '
    $raw = $raw -replace '\b(19|20)\d{2}\b', ' '

    $junk = @(
        '1080p', '2160p', '720p', '480p', 'x264', 'x265', 'hevc', 'avc', 'h264', 'h265',
        'dts', 'aac', 'ac3', 'truehd', 'dtshd', 'flac',
        'webdl', 'web-dl', 'webrip', 'web', 'hdtv', 'bluray', 'blu-ray', 'bdrip', 'brrip', 'remux', 'rip',
        'hdrip', 'dvdrip', 'xvid', 'mpeg2', 'av1',
        '5.1', '2.0', '6ch', '2ch', '6Ch', '2Ch',
        'v1', 'v2', 'v3', 'version', 'edition',
        'rifftrax', 'riff', 'riffTrax', 'plinkett', 'MrPlinkett', 'RiffTrax',
        'default', 'track1', 'track2', 'track3', 'track4',
        'plunkett', 'movie', 'audio', 'subs', 'subs1', 'subs2',
        'rarbg', 'eztv', 'yts', 'thepiratebay', 'tpb', 'group'
    )

    foreach ($j in $junk) {
        $raw = $raw -replace ('(?i)\b' + [regex]::Escape($j) + '\b'), ' '
    }

    $raw = $raw -replace '[._\-]+', ' '
    # Split simple CamelCase (AngelsRevenge -> Angels Revenge) to avoid producing one huge token.
    $raw = $raw -replace '(?<=[a-z])(?=[A-Z])', ' '
    $raw = Convert-Word -Value $raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [string[]]@()
    }

    $words = $raw.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
    $stop = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($w in @('the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'on', 'for', 'with', 'at')) {
        [void]$stop.Add($w)
    }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($w in $words) {
        if (-not $stop.Contains($w)) {
            $out.Add($w)
        }
    }
    return $out.ToArray()
}

function Get-ImdbQueryTitleFromBaseName {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$BaseName
    )

    if ([string]::IsNullOrWhiteSpace($BaseName)) {
        return ''
    }

    $s = $BaseName

    # Strip common trailing quality/source tags used in this library.
    $s = $s -replace '(?i)(?:[_\.\-\s]+)(?:HD(?:high|med|low)|highTV|medTV|lowTV|high|med|low|tablet|mobile)\s*$', ''
    $s = $s -replace '(?i)(?:[_\.\-\s]+)(?:RiffTrax|Rifftrax)\s*$', ''

    # Normalize separators and split CamelCase.
    $s = $s -replace '[._\-]+', ' '
    $s = $s -replace '(?<=[a-z])(?=[A-Z])', ' '
    $s = $s -replace '\s{2,}', ' '

    return $s.Trim()
}

function Get-TokenMatchScore {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$QueryTokens,
        [Parameter(Mandatory = $true)]
        [string[]]$CandidateTokens
    )

    if ($null -eq $QueryTokens) { $QueryTokens = @() }
    if ($null -eq $CandidateTokens) { $CandidateTokens = @() }
    if ($QueryTokens.Length -eq 0 -or $CandidateTokens.Length -eq 0) {
        return 0
    }

    $cand = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($t in $CandidateTokens) { [void]$cand.Add($t) }

    $score = 0
    foreach ($qt in $QueryTokens) {
        if ($cand.Contains($qt)) {
            $score += 1
        }
    }
    return $score
}

function Get-NfoMovieCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NfoPath
    )

    $raw = Get-Content -LiteralPath $NfoPath -Raw -ErrorAction Stop
    $lines = $raw -split "`r?`n"

    $currentTitle = $null
    $currentYear = $null
    $currentTokens = [string[]]@()
    $candidates = New-Object System.Collections.Generic.List[object]

    $titleYearRe = [regex]'^(?<title>.+?)\s*\((?<year>19\d{2}|20\d{2})\)\s*$'
    $imdbRe = [regex]'imdb\.com/title/(tt\d{7,8})'

    foreach ($line in $lines) {
        $m1 = $titleYearRe.Match($line.Trim())
        if ($m1.Success) {
            $currentTitle = $m1.Groups['title'].Value.Trim()
            $currentYear = [int]$m1.Groups['year'].Value
            $currentTokens = Get-TitleTokens -Input $currentTitle
            continue
        }

        $m2 = $imdbRe.Match($line)
        if ($m2.Success -and $null -ne $currentTitle -and $null -ne $currentYear) {
            $tt = $m2.Groups[1].Value
            $candidates.Add([pscustomobject]@{
                ImdbId = $tt
                Title  = $currentTitle
                Year   = $currentYear
                Tokens = $currentTokens
            }) | Out-Null
            continue
        }
    }

    return $candidates.ToArray()
}

function Get-MovieFromNfo {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,
        [Parameter(Mandatory = $true)]
        [string[]]$NfoPaths
    )

    $queryTokens = Get-TitleTokens -Input $File.BaseName
    if ($null -eq $queryTokens -or $queryTokens.Length -eq 0) {
        return $null
    }

    $best = $null
    $bestScore = 0
    foreach ($nfoPath in $NfoPaths) {
        $cands = Get-NfoMovieCandidates -NfoPath $nfoPath
        foreach ($cand in $cands) {
            $score = Get-TokenMatchScore -QueryTokens $queryTokens -CandidateTokens $cand.Tokens
            if ($score -gt $bestScore) {
                $bestScore = $score
                $best = $cand
            }
        }
    }

    if ($null -eq $best) {
        return $null
    }

    if ($bestScore -lt 1) {
        return $null
    }

    return $best
}

function Get-FileSizeBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $item = Get-Item -LiteralPath $FilePath -ErrorAction Stop
    return [int64]$item.Length
}

function Get-MovieFromIMDb {
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueryTitle
    )

    # PowerShell can sometimes pass strings as character arrays or other array-like objects.
    # The previous logic joined arrays with ' ' which produced "A n g e l s ..." and broke IMDb search.
    if ($QueryTitle -is [char[]]) {
        $QueryTitle = -join $QueryTitle
    } elseif ($QueryTitle -is [System.Array]) {
        $parts = @($QueryTitle | ForEach-Object { $_.ToString() })
        $allSingleChars = $true
        foreach ($p in $parts) {
            if ($p.Length -ne 1) {
                $allSingleChars = $false
                break
            }
        }
        if ($allSingleChars) {
            $QueryTitle = ($parts -join '')
        } else {
            $QueryTitle = ($parts -join ' ')
        }
    }
    $QueryTitle = [string]$QueryTitle

    # If the query is already in the spaced-letter form (e.g. "A n g e l s ..."),
    # collapse it back to a normal string before searching IMDb.
    if ($QueryTitle -match '^(?:[A-Za-z]\s+)+[A-Za-z]$') {
        $QueryTitle = ($QueryTitle -replace '\s+', '')
    }

    $queryKey = ($QueryTitle.Trim().ToLowerInvariant())
    if ($ImdbCacheByQuery.ContainsKey($queryKey)) {
        return $ImdbCacheByQuery[$queryKey]
    }

    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123 Safari/537.36'
    $encQ = [System.Uri]::EscapeDataString($QueryTitle)
    $findUrl = "https://www.imdb.com/find/?q=$encQ&s=tt&ttype=ft"

    $headers = @{ 'User-Agent' = $ua }
    $resp = Invoke-WebRequest -Uri $findUrl -Headers $headers -Method Get -UseBasicParsing
    $html = $resp.Content

    $ttRe = [regex]'href="/title/(tt\d{7,8})/"'
    $m = $ttRe.Match($html)
    if (-not $m.Success) {
        throw "IMDb search returned no tt id for query: $QueryTitle"
    }

    $ttId = $m.Groups[1].Value
    $titleUrl = "https://www.imdb.com/title/$ttId/"
    $resp2 = Invoke-WebRequest -Uri $titleUrl -Headers $headers -Method Get -UseBasicParsing
    $html2 = $resp2.Content

    $nameRe = [regex]'\"name\"\\s*:\\s*\"(?<name>.+?)\"'
    $dateRe = [regex]'\"datePublished\"\\s*:\\s*\"(?<date>\d{4}-\d{2}-\d{2})\"'

    $mn = $nameRe.Match($html2)
    $md = $dateRe.Match($html2)
    if (-not $mn.Success -or -not $md.Success) {
        throw "Failed to extract name/datePublished from IMDb for tt: $ttId (query: $QueryTitle)"
    }

    $name = $mn.Groups['name'].Value
    $date = $md.Groups['date'].Value
    $year = [int]($date.Substring(0,4))
    $resolved = [pscustomobject]@{ ImdbId = $ttId; Title = $name; Year = $year }

    $ImdbCacheByQuery[$queryKey] = $resolved
    $ImdbCacheById[$ttId] = $resolved
    [pscustomobject]@{
        QueryKey = $queryKey
        ImdbId   = $ttId
        Title    = $name
        Year     = $year
    } | Export-Csv -LiteralPath $ImdbCachePath -NoTypeInformation -Encoding UTF8 -Append

    return $resolved
}

function Get-MovieFromIMDbId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImdbId
    )

    if ($ImdbCacheById.ContainsKey($ImdbId)) {
        return $ImdbCacheById[$ImdbId]
    }

    $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123 Safari/537.36'
    $titleUrl = "https://www.imdb.com/title/$ImdbId/"

    $headers = @{ 'User-Agent' = $ua }
    $resp2 = Invoke-WebRequest -Uri $titleUrl -Headers $headers -Method Get -UseBasicParsing
    $html2 = $resp2.Content

    $nameRe = [regex]'\"name\"\\s*:\\s*\"(?<name>.+?)\"'
    $dateRe = [regex]'\"datePublished\"\\s*:\\s*\"(?<date>\d{4}-\d{2}-\d{2})\"'

    $mn = $nameRe.Match($html2)
    $md = $dateRe.Match($html2)
    if (-not $mn.Success -or -not $md.Success) {
        throw "Failed to extract title/year from IMDb for tt: $ImdbId"
    }

    $name = $mn.Groups['name'].Value
    $date = $md.Groups['date'].Value
    $year = [int]($date.Substring(0,4))
    $resolved = [pscustomobject]@{ ImdbId = $ImdbId; Title = $name; Year = $year }

    $idQueryKey = ([string]$name).Trim().ToLowerInvariant()
    $ImdbCacheById[$ImdbId] = $resolved
    if (-not [string]::IsNullOrWhiteSpace($idQueryKey)) {
        $ImdbCacheByQuery[$idQueryKey] = $resolved
    }
    [pscustomobject]@{
        QueryKey = $idQueryKey
        ImdbId   = $ImdbId
        Title    = $name
        Year     = $year
    } | Export-Csv -LiteralPath $ImdbCachePath -NoTypeInformation -Encoding UTF8 -Append

    return $resolved
}

function Get-MovieTargetPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Folder,
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [int]$Year,
        [Parameter(Mandatory = $true)]
        [string]$ExtensionWithDot
    )

    function Get-FilenameSafe {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Value
        )

        $invalid = [System.IO.Path]::GetInvalidFileNameChars()
        $s = $Value
        foreach ($ch in $invalid) {
            $s = $s -replace [regex]::Escape([string]$ch), ' '
        }
        $s = $s -replace '\s{2,}', ' '
        return $s.Trim()
    }

    $safeTitle = Get-FilenameSafe -Value $Title.Trim()
    $newName = "$safeTitle ($Year)$ExtensionWithDot"
    return (Join-Path -Path $Folder -ChildPath $newName)
}

function Get-TvTargetPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShowName,
        [Parameter(Mandatory = $true)]
        [int]$Season,
        [Parameter(Mandatory = $true)]
        [int]$Episode,
        [Parameter(Mandatory = $true)]
        [string]$ExtensionWithDot,
        [Parameter(Mandatory = $true)]
        [string]$TvRoot
    )

    function Get-FilenameSafe {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Value
        )

        $invalid = [System.IO.Path]::GetInvalidFileNameChars()
        $s = $Value
        foreach ($ch in $invalid) {
            $s = $s -replace [regex]::Escape([string]$ch), ' '
        }
        $s = $s -replace '\s{2,}', ' '
        return $s.Trim()
    }

    $safeShowName = Get-FilenameSafe -Value $ShowName
    $safeExt = $ExtensionWithDot

    $seasonDir = Join-Path -Path $TvRoot -ChildPath $safeShowName
    $seasonDir = Join-Path -Path $seasonDir -ChildPath ("Season {0:D2}" -f $Season)
    $fileName = ("{0} - S{1:D2}E{2:D2}{3}" -f $safeShowName, $Season, $Episode, $safeExt)
    return (Join-Path -Path $seasonDir -ChildPath $fileName)
}

function Get-TvSeasonEpisodeFromFilename {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $re1 = [regex]'[sS](?<s>\d{1,2})[eE](?<e>\d{1,2})'
    $m1 = $re1.Match($Name)
    if ($m1.Success) {
        return [pscustomobject]@{ Season = [int]$m1.Groups['s'].Value; Episode = [int]$m1.Groups['e'].Value }
    }

    $re2 = [regex]'(?<s>\d{1,2})x(?<e>\d{1,2})'
    $m2 = $re2.Match($Name)
    if ($m2.Success) {
        return [pscustomobject]@{ Season = [int]$m2.Groups['s'].Value; Episode = [int]$m2.Groups['e'].Value }
    }

    return $null
}

function Get-TvShowNameFromPath {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $p = $File.Directory
    if ($null -eq $p) {
        return $null
    }

    function IsSeasonFolder([string]$folderName) {
        return ($folderName -match '^\s*Season\s*\d{1,2}\s*$')
    }

    $parentName = $p.Name
    if (IsSeasonFolder -folderName $parentName) {
        $gp = $p.Parent
        if ($null -eq $gp) {
            return $null
        }
        $parentName = $gp.Name
    }

    $show = $parentName -replace '[._\-]+',' ' -replace '\s{2,}',' '
    $show = $show.Trim()
    if ([string]::IsNullOrWhiteSpace($show)) {
        return $null
    }
    return $show
}

$AllVideos = Get-ChildItem -Path $RootPath -Recurse -File -Force | Where-Object {
    $VideoExtensions -contains $_.Extension.ToLowerInvariant()
}

Write-Output ("Found {0} video files" -f ($AllVideos | Measure-Object).Count)

$Plans = New-Object System.Collections.Generic.List[object]

foreach ($f in $AllVideos) {
    $ext = $f.Extension
    $inTv = $false
    if (Test-Path -LiteralPath $TvRootPath) {
        if ($f.FullName.StartsWith($TvRootPath.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            $inTv = $true
        }
    }

    $tvParse = Get-TvSeasonEpisodeFromFilename -Name $f.Name
    $isTv = $inTv -or ($null -ne $tvParse)

    if ($isTv) {
        if ($null -eq $tvParse) {
            Write-LogLine -Action 'skip' -MediaType 'tv' -OldPath $f.FullName -NewPath '' -Reason 'TV file in TV folder but no S/E match in filename'
            continue
        }

        $showName = Get-TvShowNameFromPath -File $f
        if ($null -eq $showName) {
            Write-LogLine -Action 'skip' -MediaType 'tv' -OldPath $f.FullName -NewPath '' -Reason 'TV show name could not be derived from folder'
            continue
        }

        $dest = Get-TvTargetPath -ShowName $showName -Season ([int]$tvParse.Season) -Episode ([int]$tvParse.Episode) -ExtensionWithDot $ext -TvRoot $TvRootPath

        $Plans.Add([pscustomobject]@{
            SourcePath = $f.FullName
            DestPath   = $dest
            MediaType   = 'tv'
            ShowName    = $showName
            Season      = [int]$tvParse.Season
            Episode     = [int]$tvParse.Episode
        }) | Out-Null
        continue
    }

    $nfos = @()
    $nfoCandidates = Get-ChildItem -LiteralPath $f.Directory.FullName -Filter '*.nfo' -File -ErrorAction SilentlyContinue
    if ($null -ne $nfoCandidates) {
        foreach ($nf in $nfoCandidates) { $nfos += $nf.FullName }
    }

    $resolved = $null
    if ($null -ne $nfos -and $nfos.Length -gt 0) {
        $resolved = Get-MovieFromNfo -File $f -NfoPaths $nfos
    }

    if ($null -ne $resolved) {
        $resolvedImdb = $null
        try {
            $resolvedImdb = Get-MovieFromIMDbId -ImdbId $resolved.ImdbId
        } catch {
            Write-LogLine -Action 'skip' -MediaType 'movie' -OldPath $f.FullName -NewPath '' -Reason ("IMDb by id failed: " + $_.Exception.Message)
            continue
        }

        $title = [string]$resolvedImdb.Title
        $year = [int]$resolvedImdb.Year
        $dest = Get-MovieTargetPath -Folder $f.Directory.FullName -Title $title -Year $year -ExtensionWithDot $ext
        $Plans.Add([pscustomobject]@{
            SourcePath = $f.FullName
            DestPath   = $dest
            MediaType  = 'movie'
            Title      = $title
            Year       = $year
        }) | Out-Null
        continue
    }

    if ([string]::IsNullOrWhiteSpace($f.BaseName)) {
        Write-LogLine -Action 'skip' -MediaType 'movie' -OldPath $f.FullName -NewPath '' -Reason 'Movie filename has no name (empty base name)'
        continue
    }
    $queryTitle = [string](Get-ImdbQueryTitleFromBaseName -BaseName $f.BaseName)
    if ([string]::IsNullOrWhiteSpace($queryTitle)) {
        Write-LogLine -Action 'skip' -MediaType 'movie' -OldPath $f.FullName -NewPath '' -Reason ("Movie title could not be derived. BaseName='" + $f.BaseName + "'")
        continue
    }

    $resolvedImdb = $null
    try {
        $resolvedImdb = Get-MovieFromIMDb -QueryTitle $queryTitle
    } catch {
        Write-LogLine -Action 'skip' -MediaType 'movie' -OldPath $f.FullName -NewPath '' -Reason ("IMDb lookup failed: " + $_.Exception.Message)
        continue
    }

    if ($null -eq $resolvedImdb) {
        Write-LogLine -Action 'skip' -MediaType 'movie' -OldPath $f.FullName -NewPath '' -Reason 'IMDb lookup returned null'
        continue
    }

    $title = [string]$resolvedImdb.Title
    $year = [int]$resolvedImdb.Year
    $dest = Get-MovieTargetPath -Folder $f.Directory.FullName -Title $title -Year $year -ExtensionWithDot $ext

    $Plans.Add([pscustomobject]@{
        SourcePath = $f.FullName
        DestPath   = $dest
        MediaType  = 'movie'
        Title      = $title
        Year       = $year
    }) | Out-Null
}

function Select-WinnerByLargestFile {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Candidates
    )

    $best = $null
    $bestSize = [int64]-1
    foreach ($c in $Candidates) {
        $size = Get-FileSizeBytes -FilePath $c.Path
        if ($size -gt $bestSize) {
            $bestSize = $size
            $best = $c
        }
    }
    return [pscustomobject]@{ Winner = $best; SizeBytes = $bestSize }
}

$Groups = $Plans | Group-Object -Property DestPath

$Winners = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

foreach ($g in $Groups) {
    $dest = [string]$g.Name
    $groupPlans = @($g.Group)

    $candidates = New-Object System.Collections.Generic.List[object]

    if (Test-Path -LiteralPath $dest) {
        $existing = Get-Item -LiteralPath $dest -ErrorAction Stop
        $candidates.Add([pscustomobject]@{ Path = $existing.FullName; Plan = $null }) | Out-Null
    }

    foreach ($p in $groupPlans) {
        if ($p.SourcePath -ne $dest) {
            $candidates.Add([pscustomobject]@{ Path = $p.SourcePath; Plan = $p }) | Out-Null
        }
    }

    if ($candidates.Count -le 1) {
        foreach ($p in $groupPlans) {
            if ($p.SourcePath -ne $dest) { [void]$Winners.Add($p.SourcePath) }
        }
        continue
    }

    $sel = Select-WinnerByLargestFile -Candidates $candidates.ToArray()
    $winner = $sel.Winner

    foreach ($p in $groupPlans) {
        if ($p.SourcePath -eq $winner.Path) {
            [void]$Winners.Add($p.SourcePath)
        } else {
            Write-LogLine -Action 'skip' -MediaType $p.MediaType -OldPath $p.SourcePath -NewPath $p.DestPath -Reason 'Destination conflict: loser kept unchanged (smaller file size)'
        }
    }
}

foreach ($p in $Plans) {
    if (-not $Winners.Contains($p.SourcePath)) {
        continue
    }

    if ($p.SourcePath -ieq $p.DestPath) {
        Write-LogLine -Action 'skip' -MediaType $p.MediaType -OldPath $p.SourcePath -NewPath $p.DestPath -Reason 'Already at target name'
        continue
    }

    if (Test-Path -LiteralPath $p.DestPath) {
        Write-LogLine -Action 'skip' -MediaType $p.MediaType -OldPath $p.SourcePath -NewPath $p.DestPath -Reason 'Destination already exists; skipping to avoid overwrite'
        continue
    }

    $destParent = Split-Path -Path $p.DestPath -Parent
    if (-not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }

    $action = if ($p.MediaType -eq 'tv') { 'move' } else { 'rename' }
    Move-Item -LiteralPath $p.SourcePath -Destination $p.DestPath
    Write-LogLine -Action $action -MediaType $p.MediaType -OldPath $p.SourcePath -NewPath $p.DestPath -Reason 'Applied Plex naming cleanup'
}

Write-Output 'Done. See plex_rename_log.csv for results.'
