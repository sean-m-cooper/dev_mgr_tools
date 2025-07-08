param (
    [string]$Email = "",
    [string[]]$TeamProjects = @("Proj1","Proj2"),
    [string]$PAT = "",
    [string]$CutoffData = Get-Date "2024-01-01"
)

Import-Module .\JiraConnection.psm1 -Force



# ─── Configuration ─────────────────────────────────────────────────────────────
$email = 'admin@company.com.com'

# $headers = Get-JiraAuthHeader -UserEmail $JiraUserEmail -ApiToken $JiraAPIToken
$headers = Get-JiraAuthHeader
$domain = Get-Domain
$jiraBaseUrl = "https://${domain}"

# ─── Helpers ───────────────────────────────────────────────────────────────────

function Get-BusinessDays {
    param ([datetime]$startDate, [datetime]$endDate)

    $businessDays = 0
    $current = $startDate.Date
    while ($current -le $endDate.Date) {
        if ($current.DayOfWeek -notin @('Saturday', 'Sunday')) {
            $businessDays++
        }
        $current = $current.AddDays(1)
    }
    return $businessDays
}


function Get-Project-Jira-Issues {
    param ([string]$project)

    $allIssues = @()
    $startAt = 0
    $maxResults = 100
    $total = 1  # Forces first loop

    $jql = "project=$project AND issuetype IN (Bug, Story) AND status = Closed"

    while ($startAt -lt $total) {
        $encodedJql = Encode-Url $jql
        $url = "$jiraBaseUrl/rest/api/3/search?jql=$encodedJql&startAt=$startAt&maxResults=$maxResults&expand=changelog"
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get

        $allIssues += $response.issues
        $total = $response.total
        $startAt += $maxResults
    }

    return $allIssues
}

function Get-Project-Stats {
    param (
        [array]$issues,
        [string]$project
    )

    $results = foreach ($issue in $issues) {
        $storyPoints = $issue.fields.customfield_10026 ?? $issue.fields.customfield_10016
        $qaPoints    = $issue.fields.customfield_10058

        if (-not $storyPoints -and -not $qaPoints) { continue }

        $devDate = $null
        $closedDate = $null

        foreach ($history in $issue.changelog.histories) {
            foreach ($item in $history.items) {
                if ($item.field -eq "status") {
                    $date = Get-Date $history.created
                    if (-not $devDate -and $item.toString -in @("DEV", "IN DEV")) {
                        $devDate = $date
                    } elseif (-not $closedDate -and $item.toString -eq "Closed") {
                        $closedDate = $date
                    }
                }
            }
        }

        if ($devDate -and $closedDate -and $devDate -ge $CutoffData) {
            $duration = Get-BusinessDays -startDate $devDate -endDate $closedDate
            [PSCustomObject]@{
                Project        = $project
                Key            = $issue.key
                DevStoryPoints = $storyPoints
                QAStoryPoints  = $qaPoints
                TotalPoints    = $storyPoints + $qaPoints
                DevStartDate   = $devDate
                ClosedDate     = $closedDate
                Duration       = $duration
            }
        }
    }

    Write-Host "Total issues returned: $($results.Count) for $project"
    return $results
}

function Get-DurationStatsByQuarter {
    param (
        [Parameter(Mandatory = $true)]
        [array]$WorkItems
    )

    function Add-DateFields {
        param ($item)
        $item | Add-Member -NotePropertyName Year -NotePropertyValue $item.DevStartDate.Year -PassThru |
               Add-Member -NotePropertyName Quarter -NotePropertyValue ([math]::Ceiling($item.DevStartDate.Month / 3)) -PassThru |
               Add-Member -NotePropertyName CleanPoints -NotePropertyValue ($item.TotalPoints) -PassThru
    }

    function Calculate-Stats {
        param ($groupKey, $items)

        $durations = $items | Select-Object -ExpandProperty Duration
        $avg = ($durations | Measure-Object -Average).Average
        $sumSq = ($durations | ForEach-Object { [math]::Pow($_ - $avg, 2) }) | Measure-Object -Sum
        $stdDev = if ($durations.Count -gt 0) {
            [math]::Sqrt($sumSq.Sum / $durations.Count)
        } else { 0 }

        [PSCustomObject]@{
            Project      = $groupKey[0]
            Year         = $groupKey[1]
            Quarter      = $groupKey[2]
            StoryPoints  = $groupKey[3]
            Count        = $durations.Count
            AvgDuration  = [math]::Round($avg, 2)
            StdDeviation = [math]::Round($stdDev, 2)
        }
    }

    $enhanced = $WorkItems | ForEach-Object { Add-DateFields $_ }

    $detailedStats = $enhanced | Group-Object {
        "$($_.Project)|$($_.Year)|$($_.Quarter)|$($_.CleanPoints)"
    } | ForEach-Object {
        $parts = $_.Name -split '\|'
        Calculate-Stats -groupKey $parts -items $_.Group
    }

    return $detailedStats
}

# ─── Main Execution ────────────────────────────────────────────────────────────

$allResults = @()

foreach ($project in $TeamProjects) {
    $issues = Get-Project-Jira-Issues $project
    if ($issues.Count -eq 0) {
        Write-Warning "No issues found for $project"
        continue
    }
    $allResults += Get-Project-Stats -issues $issues -project $project
}

Write-Host "Total issues processed: $($allResults.Count)"

$stats = Get-DurationStatsByQuarter -WorkItems $allResults

# $stats | Format-Table -AutoSize
$stats | Export-Csv -Path "output\team_predictability_stats.csv" -NoTypeInformation -Encoding UTF8
