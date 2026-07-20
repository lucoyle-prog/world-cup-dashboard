# Updates World Cup Performance Team dashboard data from ESPN (no API key required).
# Schedule daily via Task Scheduler, or run manually before sharing the dashboard.
param(
    [switch]$SkipRosterFetch
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = $PSScriptRoot
$csvPath = Join-Path (Split-Path $root -Parent) 'FIFA Draw(Draw Results).csv'
$dataJsPath = Join-Path $root 'world-cup-data.js'
$dataJsonPath = Join-Path $root 'world-cup-dashboard-data.json'
$historyPath = Join-Path $root 'world-cup-status-history.json'
$profilesPath = Join-Path $root 'country-profiles.json'

$countryAliases = @{
    'Congo DR' = @('Congo DR', 'DR Congo', 'Democratic Republic of Congo')
    "Cote d'Ivoire" = @('Ivory Coast', "Cote d'Ivoire", "Côte d'Ivoire")
    'Korea Republic' = @('South Korea', 'Korea Republic', 'Korea')
    'Cape Verde Islands' = @('Cape Verde', 'Cabo Verde')
    'Turkey' = @('Turkiye', 'Türkiye', 'Turkey')
    'Czech Republic' = @('Czechia', 'Czech Republic')
    'Curacao' = @('Curacao', 'Curaçao')
    'Bosnia and Herzegovina' = @('Bosnia-Herzegovina', 'Bosnia and Herzegovina')
    'United States' = @('United States', 'USA')
    'Scotland' = @('Scotland')
}

function Normalize-Name([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $n = $Name.Trim().ToLowerInvariant()
    $n = $n -replace '[\u2019''`]', "'"
    $n = $n -replace '[^a-z0-9\s-]', ''
    $n = $n -replace '\s+', ' '
    return $n.Trim()
}

function Normalize-PlayerName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $formD = $Name.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $formD.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    $n = $sb.ToString().ToLowerInvariant()
    $n = $n -replace '[^a-z0-9\s-]', ''
    $n = $n -replace '\s+', ' '
    return $n.Trim()
}

function Get-StatValue($Entry, [string]$StatName) {
    $stat = $Entry.stats | Where-Object { $_.name -eq $StatName } | Select-Object -First 1
    if ($null -eq $stat) { return 0 }
    return [int][Math]::Floor([double]$stat.value)
}

function Resolve-CountryStatus($Entry, [string]$GroupName, [string]$Phase) {
    $note = ''
    if ($Entry.note -and $Entry.note.description) { $note = $Entry.note.description }
    $gp = Get-StatValue $Entry 'gamesPlayed'
    $pts = Get-StatValue $Entry 'points'
    $rank = Get-StatValue $Entry 'rank'
    $advanced = Get-StatValue $Entry 'advanced'
    $groupMatches = 3

    if ($advanced -gt 0) {
        return @{ status = 'IN'; detail = 'Advanced - still in the World Cup'; note = $note; groupRank = $rank; points = $pts; played = $gp }
    }

    # ESPN projects "Eliminated" before teams have played - ignore until group stage is done
    # or elimination is otherwise confirmed (all 3 group matches complete).
    $groupStageComplete = $gp -ge $groupMatches
    $eliminationConfirmed = $false
    if ($groupStageComplete) {
        if ($note -match 'Eliminated') { $eliminationConfirmed = $true }
        if ($rank -ge 4) { $eliminationConfirmed = $true }
    }

    if ($eliminationConfirmed) {
        return @{ status = 'OUT'; detail = 'Eliminated from World Cup'; note = $note; groupRank = $rank; points = $pts; played = $gp }
    }

    if ($gp -lt $groupMatches) {
        $progress = if ($gp -eq 0) { "In World Cup - $GroupName" } else { "In World Cup - $GroupName (group stage in progress)" }
        return @{ status = 'IN'; detail = $progress; note = $note; groupRank = $rank; points = $pts; played = $gp }
    }

    # Third-place teams with advanced=0 missed the Best 8 cut once group stage is complete.
    if ($groupStageComplete -and $rank -eq 3 -and $advanced -eq 0) {
        return @{ status = 'OUT'; detail = 'Eliminated - did not qualify among best third-place teams'; note = $note; groupRank = $rank; points = $pts; played = $gp }
    }

    if ($note -match 'Advance|Best 8') {
        $race = if ($note -match 'Best 8') { ' - awaiting best third-place result' } else { '' }
        return @{ status = 'IN'; detail = "Still in World Cup$race"; note = $note; groupRank = $rank; points = $pts; played = $gp }
    }

    return @{ status = 'IN'; detail = "Still in World Cup - $GroupName"; note = $note; groupRank = $rank; points = $pts; played = $gp }
}

function Get-KnockoutRoundLabel([string]$Slug) {
    $labels = @{
        'round-of-32' = 'Round of 32'
        'round-of-16' = 'Round of 16'
        'quarter-final' = 'Quarter-final'
        'quarterfinals' = 'Quarter-final'
        'semi-final' = 'Semi-final'
        'semifinals' = 'Semi-final'
        'third-place' = 'Third-place play-off'
        'third-place-playoff' = 'Third-place play-off'
        '3rd-place-match' = 'Third-place play-off'
        'final' = 'Final'
    }
    if ($labels.ContainsKey($Slug)) { return $labels[$Slug] }
    if ([string]::IsNullOrWhiteSpace($Slug)) { return 'Knockout stage' }
    return ($Slug -replace '-', ' ')
}

function Get-CompetitorScore($Competitor) {
    if ($null -eq $Competitor) { return $null }
    $score = $Competitor.score
    if ($null -eq $score) { return $null }
    if ($score -is [string] -and $score -match '^\d+$') { return [int]$score }
    if ($score.PSObject.Properties.Name -contains 'displayValue' -and $score.displayValue -match '^\d+$') {
        return [int]$score.displayValue
    }
    if ($score.PSObject.Properties.Name -contains 'value') {
        return [int][Math]::Floor([double]$score.value)
    }
    return $null
}

function Get-CompetitorWinner($Competitor) {
    if ($null -eq $Competitor) { return $null }
    if ($Competitor.PSObject.Properties.Name -contains 'winner') { return [bool]$Competitor.winner }
    return $null
}

function Get-KnockoutLosersFromCompetition($Comp, [string]$RoundLabel) {
    $losers = @{}
    if ($Comp.status.type.state -ne 'post') { return $losers }

    $winners = @($Comp.competitors | Where-Object { Get-CompetitorWinner $_ -eq $true })
    if ($winners.Count -eq 0) {
        $scored = @($Comp.competitors | Where-Object { $null -ne (Get-CompetitorScore $_) })
        if ($scored.Count -lt 2) { return $losers }
        $maxScore = ($scored | ForEach-Object { Get-CompetitorScore $_ } | Measure-Object -Maximum).Maximum
        $winners = @($scored | Where-Object { (Get-CompetitorScore $_) -eq $maxScore })
        if ($winners.Count -ne 1) { return $losers }
    }

    $winnerName = $winners[0].team.displayName
    foreach ($competitor in $Comp.competitors) {
        if (Get-CompetitorWinner $competitor -eq $true) { continue }
        if ($competitor.team.displayName -eq $winnerName) { continue }
        $teamName = $competitor.team.displayName
        $losers[$teamName] = "Eliminated in $RoundLabel (lost to $winnerName)"
    }
    return $losers
}

function Get-KnockoutEliminations {
    $eliminated = @{}
    $knockoutStart = Get-Date '2026-06-28'
    $knockoutEnd = Get-Date '2026-07-19'
    $today = Get-Date
    if ($today -lt $knockoutEnd) { $knockoutEnd = $today }

    for ($day = $knockoutStart; $day -le $knockoutEnd; $day = $day.AddDays(1)) {
        $dateStr = $day.ToString('yyyyMMdd')
        try {
            $scoreboard = Invoke-RestMethod -Uri "https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world/scoreboard?dates=$dateStr&limit=100" -Method Get
            foreach ($event in $scoreboard.events) {
                $slug = $event.season.slug
                if ([string]::IsNullOrWhiteSpace($slug) -or $slug -eq 'group-stage') { continue }
                $comp = $event.competitions | Select-Object -First 1
                if (-not $comp) { continue }
                $roundLabel = Get-KnockoutRoundLabel $slug
                foreach ($entry in (Get-KnockoutLosersFromCompetition $comp $roundLabel).GetEnumerator()) {
                    $eliminated[$entry.Key] = $entry.Value
                }
            }
        }
        catch {
            Write-Warning "Could not load knockout scoreboard for ${dateStr}: $($_.Exception.Message)"
        }
    }
    return $eliminated
}

function Get-KnockoutEliminationsFromSchedules($TeamIds, $AllPicks) {
    $eliminated = @{}
    $knockoutCutoff = Get-Date '2026-06-28'

    foreach ($pick in $AllPicks) {
        $espnName = $null
        $teamId = $null
        foreach ($name in $TeamIds.Keys) {
            if (Test-CountryMatch $pick $name) {
                $espnName = $name
                $teamId = $TeamIds[$name]
                break
            }
        }
        if (-not $teamId) { continue }

        try {
            $schedule = Invoke-RestMethod -Uri "https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world/teams/$teamId/schedule" -Method Get
            Start-Sleep -Milliseconds 80
        }
        catch {
            Write-Warning "Could not load schedule for $espnName ($teamId): $($_.Exception.Message)"
            continue
        }

        foreach ($event in ($schedule.events | Sort-Object date)) {
            $eventDate = [datetime]$event.date
            if ($eventDate -lt $knockoutCutoff) { continue }
            $comp = $event.competitions | Select-Object -First 1
            if (-not $comp) { continue }
            if ($comp.status.type.state -ne 'post') { continue }

            $slug = $event.season.slug
            if ($slug -eq 'group-stage') { continue }

            $me = $comp.competitors | Where-Object { Test-CountryMatch $pick $_.team.displayName } | Select-Object -First 1
            if (-not $me) { continue }
            if (Get-CompetitorWinner $me -eq $true) { continue }

            $roundLabel = Get-KnockoutRoundLabel $slug
            $opp = ($comp.competitors | Where-Object { -not (Test-CountryMatch $pick $_.team.displayName) } | Select-Object -First 1).team.displayName
            if ([string]::IsNullOrWhiteSpace($opp)) { $opp = 'opponent' }
            $eliminated[$espnName] = "Eliminated in $roundLabel (lost to $opp)"
        }
    }
    return $eliminated
}

function Merge-KnockoutEliminations($Primary, $Secondary) {
    $merged = @{}
    foreach ($key in $Primary.Keys) { $merged[$key] = $Primary[$key] }
    foreach ($key in $Secondary.Keys) { $merged[$key] = $Secondary[$key] }
    return $merged
}

function Get-MatchScoreLine($Comp) {
    $scores = @($Comp.competitors | ForEach-Object { Get-CompetitorScore $_ } | Where-Object { $null -ne $_ })
    if ($scores.Count -lt 2) { return '' }
    return ($scores -join '-')
}

function Get-TournamentFinishMap {
    $finishes = @{}
    $knockoutStart = Get-Date '2026-06-28'
    $knockoutEnd = Get-Date '2026-07-19'
    $today = Get-Date
    if ($today -lt $knockoutEnd) { $knockoutEnd = $today }

    for ($day = $knockoutStart; $day -le $knockoutEnd; $day = $day.AddDays(1)) {
        $dateStr = $day.ToString('yyyyMMdd')
        try {
            $scoreboard = Invoke-RestMethod -Uri "https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world/scoreboard?dates=$dateStr&limit=100" -Method Get
            foreach ($event in $scoreboard.events) {
                $slug = $event.season.slug
                if ([string]::IsNullOrWhiteSpace($slug) -or $slug -eq 'group-stage') { continue }
                $comp = $event.competitions | Select-Object -First 1
                if (-not $comp -or $comp.status.type.state -ne 'post') { continue }

                $winners = @($comp.competitors | Where-Object { Get-CompetitorWinner $_ -eq $true })
                if ($winners.Count -eq 0) {
                    $scored = @($comp.competitors | Where-Object { $null -ne (Get-CompetitorScore $_) })
                    if ($scored.Count -lt 2) { continue }
                    $maxScore = ($scored | ForEach-Object { Get-CompetitorScore $_ } | Measure-Object -Maximum).Maximum
                    $winners = @($scored | Where-Object { (Get-CompetitorScore $_) -eq $maxScore })
                    if ($winners.Count -ne 1) { continue }
                }
                $winnerName = $winners[0].team.displayName
                $scoreLine = Get-MatchScoreLine $comp

                foreach ($competitor in $comp.competitors) {
                    if (Get-CompetitorWinner $competitor -eq $true) { continue }
                    $teamName = $competitor.team.displayName
                    $oppScore = Get-CompetitorScore $competitor
                    $winScore = Get-CompetitorScore $winners[0]

                    if ($slug -eq 'final') {
                        $finishes[$winnerName] = @{
                            score = 100
                            status = 'IN'
                            label = 'World Cup Champion'
                            detail = "World Cup Champion - beat $teamName $winScore-$oppScore in the Final"
                        }
                        $finishes[$teamName] = @{
                            score = 90
                            status = 'OUT'
                            label = 'Runners-up'
                            detail = "Runners-up - lost to $winnerName $oppScore-$winScore in the Final"
                        }
                        continue
                    }
                    if ($slug -match '3rd-place') {
                        $finishes[$winnerName] = @{
                            score = 85
                            status = 'OUT'
                            label = '3rd place'
                            detail = "Finished 3rd - beat $teamName $winScore-$oppScore in the third-place match"
                        }
                        $finishes[$teamName] = @{
                            score = 82
                            status = 'OUT'
                            label = '4th place'
                            detail = "Finished 4th - lost the third-place match to $winnerName $oppScore-$winScore"
                        }
                        continue
                    }

                    $roundLabel = Get-KnockoutRoundLabel $slug
                    $score = switch -Regex ($slug) {
                        'semi' { 70 }
                        'quarter' { 50 }
                        'round-of-16' { 30 }
                        'round-of-32' { 20 }
                        default { 15 }
                    }
                    if (-not $finishes.ContainsKey($teamName) -or $finishes[$teamName].score -lt $score) {
                        $detailSuffix = if ($scoreLine) { " ($scoreLine)" } else { '' }
                        $finishes[$teamName] = @{
                            score = $score
                            status = 'OUT'
                            label = $roundLabel
                            detail = "Eliminated in $roundLabel (lost to $winnerName)$detailSuffix"
                        }
                    }
                }
            }
        }
        catch {
            Write-Warning "Could not load finish map for ${dateStr}: $($_.Exception.Message)"
        }
    }
    return $finishes
}

function Apply-TournamentFinishes($FinishMap, $CountryLookup, $AllPicks, $Groups) {
    foreach ($espnName in $FinishMap.Keys) {
        $finish = $FinishMap[$espnName]
        $keys = New-Object System.Collections.Generic.HashSet[string]
        [void]$keys.Add($espnName)
        foreach ($pick in $AllPicks) {
            if (Test-CountryMatch $pick $espnName) { [void]$keys.Add($pick) }
        }
        foreach ($key in $keys) {
            if (-not $CountryLookup.ContainsKey($key)) { continue }
            $CountryLookup[$key]['status'] = $finish.status
            $CountryLookup[$key]['detail'] = $finish.detail
            $CountryLookup[$key]['finishLabel'] = $finish.label
            $CountryLookup[$key]['finishScore'] = $finish.score
        }
    }
    foreach ($group in $Groups) {
        foreach ($team in $group.teams) {
            if ($FinishMap.ContainsKey($team.name)) {
                $finish = $FinishMap[$team.name]
                $team.status = $finish.status
                $team.detail = $finish.detail
            }
        }
    }
}

function Get-CountryField($Country, [string]$Name) {
    if ($null -eq $Country) { return $null }
    if ($Country -is [hashtable]) { return $Country[$Name] }
    return $Country.$Name
}

function Get-MemberBestFinish($MemberCountries) {
    $bestScore = 0
    $bestCountry = $null
    $bestLabel = ''
    foreach ($c in $MemberCountries) {
        $finishScore = Get-CountryField $c 'finishScore'
        $status = Get-CountryField $c 'status'
        $score = if ($finishScore) { [int]$finishScore } elseif ($status -eq 'IN') { 100 } else { 5 }
        $label = Get-CountryField $c 'finishLabel'
        if (-not $label) {
            if ($status -eq 'IN') { $label = 'World Cup Champion' }
            else { $label = Get-CountryField $c 'detail' }
        }
        $pickName = Get-CountryField $c 'pickName'
        if ($score -gt $bestScore) {
            $bestScore = $score
            $bestCountry = $pickName
            $bestLabel = $label
        }
    }
    return @{ score = $bestScore; country = $bestCountry; label = $bestLabel }
}

function Build-Podium($Members, $Countries, $FinishMap) {
    $championEntry = $FinishMap.GetEnumerator() | Where-Object { $_.Value.score -eq 100 } | Select-Object -First 1
    if (-not $championEntry) { return $null }

    $poolMembers = @($Members | Where-Object { $_.name -notmatch 'Not Picked' })
    $stats = @()
    foreach ($m in $poolMembers) {
        $groupPts = 0
        foreach ($c in $m.countries) {
            $pts = Get-CountryField $c 'points'
            if ($pts) { $groupPts += [int]$pts }
        }
        $best = Get-MemberBestFinish $m.countries
        $stats += [PSCustomObject]@{
            name = $m.name
            bestScore = $best.score
            bestCountry = $best.country
            bestLabel = $best.label
            groupPoints = $groupPts
            inCount = $m.inCount
            countries = @($m.countries | ForEach-Object {
                @{
                    pickName = Get-CountryField $_ 'pickName'
                    displayName = Get-CountryField $_ 'displayName'
                    logo = Get-CountryField $_ 'logo'
                    abbreviation = Get-CountryField $_ 'abbreviation'
                    status = Get-CountryField $_ 'status'
                }
            })
        }
    }

    $survivalRanked = @($stats | Sort-Object -Property @{ Expression = 'bestScore'; Descending = $true }, @{ Expression = 'groupPoints'; Descending = $true }, @{ Expression = 'name'; Descending = $false })
    $first = $survivalRanked[0]
    $second = if ($survivalRanked.Count -gt 1) { $survivalRanked[1] } else { $null }
    $third = if ($survivalRanked.Count -gt 2) { $survivalRanked[2] } else { $null }
    $topNames = @($first.name)
    if ($second) { $topNames += $second.name }
    if ($third) { $topNames += $third.name }

    $fourth = @($stats | Sort-Object -Property @{ Expression = 'groupPoints'; Descending = $true }, @{ Expression = 'bestScore'; Descending = $true }, @{ Expression = 'name'; Descending = $false } | Where-Object { $topNames -notcontains $_.name } | Select-Object -First 1)[0]
    if (-not $fourth) {
        $fourth = @($stats | Sort-Object -Property @{ Expression = 'groupPoints'; Descending = $true } | Select-Object -Skip 3 -First 1)[0]
    }

    $championCountry = $Countries | Where-Object {
        $fs = Get-CountryField $_ 'finishScore'
        $st = Get-CountryField $_ 'status'
        $pn = Get-CountryField $_ 'pickName'
        ($fs -eq 100) -or ($st -eq 'IN' -and $pn -eq 'Spain')
    } | Select-Object -First 1
    if (-not $championCountry) {
        $championCountry = $Countries | Where-Object { Test-CountryMatch 'Spain' (Get-CountryField $_ 'displayName') } | Select-Object -First 1
    }
    $winnerMember = $poolMembers | Where-Object {
        @($_.countries | Where-Object {
            $pn = Get-CountryField $_ 'pickName'
            $dn = Get-CountryField $_ 'displayName'
            ($pn -eq 'Spain') -or (Test-CountryMatch 'Spain' $dn)
        }).Count -gt 0
    } | Select-Object -First 1

    function Format-Place($Place, $Stat, $Title, $Subtitle, $Metric) {
        if (-not $Stat) { return $null }
        return @{
            place = $Place
            title = $Title
            subtitle = $Subtitle
            memberName = $Stat.name
            metric = $Metric
            bestCountry = $Stat.bestCountry
            bestLabel = $Stat.bestLabel
            groupPoints = $Stat.groupPoints
            countries = $Stat.countries
        }
    }

    $places = @(
        (Format-Place 1 $first '1st Place' 'World Cup Champion pick' "$($first.bestCountry) - $($first.bestLabel)")
        (Format-Place 2 $second '2nd Place' 'Best knockout run' "$($second.bestCountry) - $($second.bestLabel)")
        (Format-Place 3 $third '3rd Place' 'Next best knockout run' "$($third.bestCountry) - $($third.bestLabel)")
        (Format-Place 4 $fourth '4th Place' 'Most group stage points' "$($fourth.groupPoints) pts across 3 picks")
    ) | Where-Object { $_ }

    return @{
        complete = $true
        championTeam = if ($championCountry) { Get-CountryField $championCountry 'displayName' } else { $championEntry.Key }
        championPick = if ($championCountry) { Get-CountryField $championCountry 'pickName' } else { 'Spain' }
        championLogo = if ($championCountry) { Get-CountryField $championCountry 'logo' } else { $null }
        winnerMember = if ($winnerMember) { $winnerMember.name } else { $first.name }
        places = $places
    }
}

function Apply-KnockoutEliminations($KnockoutMap, $CountryLookup, $AllPicks, $Groups) {
    foreach ($espnName in $KnockoutMap.Keys) {
        $detail = $KnockoutMap[$espnName]
        $keys = New-Object System.Collections.Generic.HashSet[string]
        [void]$keys.Add($espnName)
        foreach ($pick in $AllPicks) {
            if (Test-CountryMatch $pick $espnName) { [void]$keys.Add($pick) }
        }
        foreach ($key in $keys) {
            if (-not $CountryLookup.ContainsKey($key)) { continue }
            $CountryLookup[$key]['status'] = 'OUT'
            $CountryLookup[$key]['detail'] = $detail
        }
    }
    foreach ($group in $Groups) {
        foreach ($team in $group.teams) {
            if ($KnockoutMap.ContainsKey($team.name)) {
                $team.status = 'OUT'
                $team.detail = $KnockoutMap[$team.name]
            }
        }
    }
}

function Test-CountryMatch([string]$PickName, [string]$EspnName) {
    $pickNorm = Normalize-Name $PickName
    $espnNorm = Normalize-Name $EspnName
    if ($pickNorm -eq $espnNorm) { return $true }
    if ($pickNorm -match 'ivoire' -and $espnNorm -match 'ivory') { return $true }
    if ($countryAliases.ContainsKey($PickName)) {
        foreach ($alias in $countryAliases[$PickName]) {
            if ((Normalize-Name $alias) -eq $espnNorm) { return $true }
        }
    }
    foreach ($key in $countryAliases.Keys) {
        if ((Normalize-Name $key) -eq $pickNorm) {
            foreach ($alias in $countryAliases[$key]) {
                if ((Normalize-Name $alias) -eq $espnNorm) { return $true }
            }
        }
    }
    return $false
}

function Read-TeamPicks([string]$Path) {
    $rows = Import-Csv -Path $Path
    $members = @()
    foreach ($row in $rows) {
        $name = $row.Name.Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($name -eq 'Not Picked') {
            $raw = ($row.'Country 1' -split "`r?`n" | ForEach-Object { $_.Trim() }) | Where-Object { $_ }
            $members += [PSCustomObject]@{
                name = 'Not Picked (Pool)'
                countries = @($raw)
                note = if ($row.'Country 2') { ($row.'Country 2').Trim() } else { '' }
            }
            continue
        }
        $countries = @($row.'Country 1', $row.'Country 2', $row.'Country 3') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if ($countries.Count -eq 0) { continue }
        $members += [PSCustomObject]@{ name = $name; countries = $countries; note = '' }
    }
    return $members
}

function Get-PlayerHeadshot($Athlete) {
    if ($Athlete.headshot -and $Athlete.headshot.href) { return $Athlete.headshot.href }
    if ($Athlete.id) { return "https://a.espncdn.com/i/headshots/soccer/players/full/$($Athlete.id).png" }
    return $null
}

function Find-AthleteByName($Athletes, [string]$TargetName) {
    if ([string]::IsNullOrWhiteSpace($TargetName)) { return $null }
    $targetNorm = Normalize-PlayerName $TargetName
    $targetParts = $targetNorm -split '\s+'
    $targetLast = $targetParts[-1]

    foreach ($athlete in $Athletes) {
        $nameNorm = Normalize-PlayerName $athlete.displayName
        if ($nameNorm -eq $targetNorm) { return $athlete }
    }
    foreach ($athlete in $Athletes) {
        $nameNorm = Normalize-PlayerName $athlete.displayName
        $parts = $nameNorm -split '\s+'
        if ($parts[-1] -eq $targetLast) { return $athlete }
        if ($parts[-1].StartsWith($targetLast) -or $targetLast.StartsWith($parts[-1])) { return $athlete }
    }
    foreach ($athlete in $Athletes) {
        $nameNorm = Normalize-PlayerName $athlete.displayName
        if ($nameNorm -like "*$targetLast*") { return $athlete }
    }
    return $null
}

function Select-FallbackStar($Athletes) {
    if (-not $Athletes) { return $null }
    $outfield = @($Athletes) | Where-Object { $_.position -and $_.position.abbreviation -ne 'G' }
    $profiled = $outfield | Where-Object { $_.profiled -eq $true } | Select-Object -First 1
    if ($profiled) { return $profiled }
    $withPhoto = $outfield | Where-Object { Get-PlayerHeadshot $_ } | Select-Object -First 1
    if ($withPhoto) { return $withPhoto }
    return ($outfield | Select-Object -First 1)
}

function Get-CountryProfile([string]$PickName, $ProfilesConfig) {
    if ($ProfilesConfig.profiles.PSObject.Properties.Name -contains $PickName) {
        return $ProfilesConfig.profiles.$PickName
    }
    foreach ($prop in $ProfilesConfig.profiles.PSObject.Properties) {
        if ((Normalize-Name $prop.Name) -eq (Normalize-Name $PickName)) { return $prop.Value }
    }
    return $null
}

function Build-StarPlayerInfo([string]$PickName, [string]$EspnTeamId, $ProfilesConfig, $RosterCache) {
    $profile = Get-CountryProfile $PickName $ProfilesConfig
    $fifaSlug = if ($profile) { $profile.fifaSlug } else {
        ($PickName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    }
    $fifaUrl = "$($ProfilesConfig.fifaBaseUrl)/$fifaSlug"
    $starName = if ($profile) { $profile.starPlayer } else { '' }

    $athlete = $null
    if ($EspnTeamId -and -not $SkipRosterFetch) {
        if (-not $RosterCache.ContainsKey($EspnTeamId)) {
            try {
                $RosterCache[$EspnTeamId] = (Invoke-RestMethod -Uri "https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world/teams/$EspnTeamId/roster").athletes
                Start-Sleep -Milliseconds 120
            }
            catch {
                $RosterCache[$EspnTeamId] = @()
            }
        }
        $athletes = $RosterCache[$EspnTeamId]
        if ($starName) {
            $athlete = Find-AthleteByName $athletes $starName
        }
        else {
            $athlete = Select-FallbackStar $athletes
            if ($athlete) { $starName = $athlete.displayName }
        }
    }

    if (-not $starName) { $starName = 'Squad star TBD' }

    return @{
        name = $starName
        position = if ($athlete -and $athlete.position) { $athlete.position.displayName } else { '' }
        headshot = if ($athlete) { Get-PlayerHeadshot $athlete } else { $null }
        espnUrl = if ($athlete) {
            ($athlete.links | Where-Object { $_.rel -contains 'overview' -and $_.rel -contains 'desktop' } | Select-Object -First 1).href
        } else { $null }
        fifaUrl = $fifaUrl
    }
}

Write-Host 'Reading team picks from CSV...'
$teamPicks = Read-TeamPicks $csvPath
$allPicks = $teamPicks | ForEach-Object { $_.countries } | Select-Object -Unique
$profilesConfig = Get-Content $profilesPath -Raw | ConvertFrom-Json
$espnTeamIds = @{}
$rosterCache = @{}

Write-Host 'Fetching live World Cup standings from ESPN...'
$standings = Invoke-RestMethod -Uri 'https://site.api.espn.com/apis/v2/sports/soccer/fifa.world/standings' -Method Get

$countryLookup = @{}
$groups = @()
$totalMatchesPlayed = 0

foreach ($group in $standings.children) {
    $groupName = $group.name
    $entries = @()
    $groupEntries = @()
    if ($group.standings -and $group.standings.entries) {
        $groupEntries = @($group.standings.entries)
    }
    foreach ($entry in $groupEntries) {
        if (-not $entry -or -not $entry.team) { continue }
        $resolved = Resolve-CountryStatus $entry $groupName 'tournament'
        $gp = $resolved.played
        $totalMatchesPlayed += $gp
        $teamInfo = @{
            name = $entry.team.displayName
            espnTeamId = $entry.team.id
            abbreviation = $entry.team.abbreviation
            logo = ($entry.team.logos | Select-Object -First 1).href
            group = $groupName
            status = $resolved.status
            detail = $resolved.detail
            note = $resolved.note
            rank = $resolved.groupRank
            points = $resolved.points
            played = $resolved.played
            record = ($entry.stats | Where-Object { $_.type -eq 'total' } | Select-Object -First 1).displayValue
        }
        $espnTeamIds[$entry.team.displayName] = $entry.team.id
        $entries += $teamInfo
        $countryLookup[$entry.team.displayName] = $teamInfo
        foreach ($pick in $allPicks) {
            if (Test-CountryMatch $pick $entry.team.displayName) {
                $countryLookup[$pick] = $teamInfo
            }
        }
    }
    $groups += @{ name = $groupName; teams = $entries }
}

Write-Host 'Checking knockout round results...'
$knockoutEliminated = Get-KnockoutEliminations
$scheduleEliminated = Get-KnockoutEliminationsFromSchedules $espnTeamIds $allPicks
$knockoutEliminated = Merge-KnockoutEliminations $knockoutEliminated $scheduleEliminated
if ($knockoutEliminated.Count -gt 0) {
    Write-Host "Knockout eliminations detected: $($knockoutEliminated.Count)"
    Apply-KnockoutEliminations $knockoutEliminated $countryLookup $allPicks $groups
}

Write-Host 'Resolving tournament finishes...'
$finishMap = Get-TournamentFinishMap
$tournamentComplete = @($finishMap.Values | Where-Object { $_.score -eq 100 }).Count -gt 0
if ($finishMap.Count -gt 0) {
    Apply-TournamentFinishes $finishMap $countryLookup $allPicks $groups
    if ($tournamentComplete) {
        Write-Host "Tournament complete - champion detected."
    }
}

$unmatched = @()
Write-Host 'Enriching countries with star players and FIFA links...'
$countries = @()
foreach ($pick in $allPicks) {
    if ($countryLookup.ContainsKey($pick)) {
        $info = $countryLookup[$pick]
        $espnId = $info.espnTeamId
        if (-not $espnId -and $espnTeamIds.ContainsKey($info.name)) { $espnId = $espnTeamIds[$info.name] }
        $star = Build-StarPlayerInfo $pick $espnId $profilesConfig $rosterCache
        $countries += @{
            pickName = $pick
            displayName = $info.name
            abbreviation = $info.abbreviation
            logo = $info.logo
            group = $info.group
            status = $info.status
            detail = $info.detail
            note = $info.note
            rank = $info.rank
            points = $info.points
            played = $info.played
            record = $info.record
            finishScore = if ($info.finishScore) { $info.finishScore } else { 0 }
            finishLabel = if ($info.finishLabel) { $info.finishLabel } else { '' }
            starPlayer = $star
            fifaUrl = $star.fifaUrl
        }
    }
    else {
        $unmatched += $pick
        $star = Build-StarPlayerInfo $pick $null $profilesConfig $rosterCache
        $countries += @{
            pickName = $pick
            displayName = $pick
            abbreviation = ($pick.Substring(0, [Math]::Min(3, $pick.Length)).ToUpper())
            logo = $null
            group = '-'
            status = 'PENDING'
            detail = 'Not found in World Cup draw - may have missed qualification'
            note = ''
            rank = 0
            points = 0
            played = 0
            record = '-'
            starPlayer = $star
            fifaUrl = $star.fifaUrl
        }
    }
}

Write-Host 'Fetching today''s matches...'
$todayMatches = @()
try {
    $today = Get-Date -Format 'yyyyMMdd'
    $scoreboard = Invoke-RestMethod -Uri "https://site.api.espn.com/apis/site/v2/sports/soccer/fifa.world/scoreboard?dates=$today" -Method Get
    foreach ($event in $scoreboard.events) {
        $comp = $event.competitions | Select-Object -First 1
        if (-not $comp) { continue }
        $homeTeam = $comp.competitors | Where-Object { $_.homeAway -eq 'home' } | Select-Object -First 1
        $awayTeam = $comp.competitors | Where-Object { $_.homeAway -eq 'away' } | Select-Object -First 1
        if (-not $homeTeam -or -not $awayTeam) { continue }
        $tracked = @($homeTeam.team.displayName, $awayTeam.team.displayName) | Where-Object {
            $n = $_
            $allPicks | Where-Object { Test-CountryMatch $_ $n }
        }
        if ($tracked.Count -eq 0) { continue }
        $todayMatches += @{
            name = $event.name
            status = $comp.status.type.description
            state = $comp.status.type.state
            home = @{ name = $homeTeam.team.displayName; score = $homeTeam.score; logo = ($homeTeam.team.logos | Select-Object -First 1).href }
            away = @{ name = $awayTeam.team.displayName; score = $awayTeam.score; logo = ($awayTeam.team.logos | Select-Object -First 1).href }
            tracked = @($tracked)
        }
    }
}
catch {
    Write-Warning "Could not load scoreboard: $($_.Exception.Message)"
}

$previousStatuses = @{}
if (Test-Path $historyPath) {
    try {
        $hist = Get-Content $historyPath -Raw | ConvertFrom-Json
        foreach ($c in $hist.countries) { $previousStatuses[$c.pickName] = $c.status }
    }
    catch { Write-Warning 'Could not read status history.' }
}

$statusChanges = @()
foreach ($c in $countries) {
    $prev = $previousStatuses[$c.pickName]
    if ($prev -and $prev -ne $c.status) {
        $statusChanges += @{
            country = $c.pickName
            from = $prev
            to = $c.status
            detail = $c.detail
        }
    }
}

$membersOut = @()
foreach ($member in $teamPicks) {
    $memberCountries = @()
    foreach ($pick in $member.countries) {
        $match = $countries | Where-Object { $_.pickName -eq $pick } | Select-Object -First 1
        if ($match) { $memberCountries += $match }
    }
    $inCount = @($memberCountries | Where-Object { $_.status -eq 'IN' }).Count
    $outCount = @($memberCountries | Where-Object { $_.status -eq 'OUT' }).Count
    $membersOut += @{
        name = $member.name
        note = $member.note
        countries = $memberCountries
        inCount = $inCount
        outCount = $outCount
    }
}

$podium = $null
if ($tournamentComplete) {
    $podium = Build-Podium $membersOut $countries $finishMap
}

$summary = @{
    total = $countries.Count
    inCount = @($countries | Where-Object { $_.status -eq 'IN' }).Count
    outCount = @($countries | Where-Object { $_.status -eq 'OUT' }).Count
    pendingCount = @($countries | Where-Object { $_.status -eq 'PENDING' }).Count
    members = $teamPicks.Count
    matchesPlayedInTournament = [int]($totalMatchesPlayed / 2)
}

$payload = @{
    lastUpdated = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    lastUpdatedDisplay = (Get-Date).ToString('dddd, MMMM d, yyyy h:mm tt')
    tournament = '2026 FIFA World Cup'
    tournamentDates = 'June 11 - July 19, 2026'
    phase = if ($tournamentComplete) {
        "Tournament complete - $($podium.championTeam) are World Cup champions!"
    } elseif ($totalMatchesPlayed -gt 0) {
        'Tournament in progress'
    } else {
        'Group stage - opening day'
    }
    tournamentComplete = [bool]$tournamentComplete
    summary = $summary
    podium = $podium
    statusChanges = $statusChanges
    members = $membersOut
    countries = $countries
    groups = $groups
    todayMatches = $todayMatches
    unmatchedPicks = $unmatched
}

$json = $payload | ConvertTo-Json -Depth 8
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($dataJsonPath, $json, $utf8NoBom)
[System.IO.File]::WriteAllText($dataJsPath, "window.WC_DASHBOARD_DATA = $json;", $utf8NoBom)
$historyPayload = @{
    countries = @($countries | ForEach-Object { @{ pickName = $_.pickName; status = $_.status } })
}
[System.IO.File]::WriteAllText($historyPath, ($historyPayload | ConvertTo-Json -Depth 4), $utf8NoBom)

Write-Host "Updated $($countries.Count) countries - IN: $($summary.inCount), OUT: $($summary.outCount), PENDING: $($summary.pendingCount)"
if ($statusChanges.Count -gt 0) {
    Write-Host "Status changes since last run:"
    $statusChanges | ForEach-Object { Write-Host "  $($_.country): $($_.from) -> $($_.to)" }
}
if ($unmatched.Count -gt 0) {
    Write-Warning "Unmatched picks: $($unmatched -join ', ')"
}
Write-Host "Data written to:`n  $dataJsPath`n  $dataJsonPath"
