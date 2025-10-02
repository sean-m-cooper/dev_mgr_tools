<#
.SYNOPSIS
    Dev Activity Report for specified repositories, with PR completions filtered by closedDate.

.PARAMETER Organization
    Azure DevOps organization name.

.PARAMETER Project
    Project name.

.PARAMETER PAT
    Personal Access Token (required).

.PARAMETER RepositoryNames
    Array of repository names to include.

.PARAMETER FromDate
    Start date (yyyy-MM-dd).

.PARAMETER ToDate
    End date (yyyy-MM-dd).

.PARAMETER OutputPath
    Destination CSV path (defaults to current folder).

.PARAMETER MaxRetries
    Maximum number of retry attempts for transient REST errors.

.PARAMETER RetryDelaySeconds
    Initial delay (seconds) between retries; delay grows linearly per attempt.

.EXAMPLE
    .\DevActivityReport.ps1 -Organization "myOrg" -Project "myProject" -PAT "YOUR_PAT" `
      -RepositoryNames "Repo1","Repo2" -FromDate "2025-07-01" -ToDate "2025-07-05"
#>

[CmdletBinding()]
param (
    [string]$Organization    = "",
    [string]$Project         = "",
    [Parameter(Mandatory = $true)]
    [string]$PAT,
    [string[]]$RepositoryNames = @(
        ""
    ),
    [DateTime]$FromDate      = [DateTime]::Parse("2025-01-01"),
    [DateTime]$ToDate        = [DateTime]::Parse("2025-012-30"),
    [string]$OutputPath      = (Join-Path (Get-Location) "DevActivityReport_SelectedRepos.csv"),
    [int]$MaxRetries         = 4,
    [int]$RetryDelaySeconds  = 3
)

# --- Validation & Setup ------------------------------------------------------
if ($ToDate -lt $FromDate) {
    throw "ToDate must be greater than or equal to FromDate."
}
if ([string]::IsNullOrWhiteSpace($PAT)) {
    throw "A Personal Access Token (PAT) is required."
}

$distinctRepoNames = $RepositoryNames |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique

if (-not $distinctRepoNames) {
    throw "RepositoryNames must include at least one valid repository."
}

[System.Net.ServicePointManager]::SecurityProtocol =
    [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

$fromDateUtc = $FromDate.ToUniversalTime()
$toDateUtc   = $ToDate.ToUniversalTime()
$fromDateIso = $fromDateUtc.ToString("o")
$toDateIso   = $toDateUtc.ToString("o")

$apiVersion  = "7.1"
$base64Auth  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":" + $PAT))
$headers     = @{ Authorization = "Basic $base64Auth" }

Write-Host "Dev Activity Report"
Write-Host "Organization     : $Organization"
Write-Host "Project          : $Project"
Write-Host "Repositories     : $($distinctRepoNames -join ', ')"
Write-Host "FromDate (UTC)   : $($fromDateUtc.ToString('u'))"
Write-Host "ToDate   (UTC)   : $($toDateUtc.ToString('u'))"
Write-Host ""

# --- Helper Functions --------------------------------------------------------
function Resolve-Identity {
    param($Source)

    $key = $Source.uniqueName
    if ([string]::IsNullOrWhiteSpace($key)) { $key = $Source.email }
    if ([string]::IsNullOrWhiteSpace($key)) { $key = $Source.id }
    if ([string]::IsNullOrWhiteSpace($key)) { $key = $Source.name }

    $displayName = $Source.displayName
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $Source.name }

    $email = $Source.email
    if ([string]::IsNullOrWhiteSpace($email) -and $Source.uniqueName -match '@') {
        $email = $Source.uniqueName
    }

    return [PSCustomObject]@{
        Key         = $key
        DisplayName = $displayName
        Email       = $email
    }
}

function Increment-Metric {
    param(
        [Hashtable]$Table,
        [string]$Key,
        [int]$Amount = 1
    )
    if ([string]::IsNullOrWhiteSpace($Key)) { return }
    if ($Table.ContainsKey($Key)) {
        $Table[$Key] += $Amount
    } else {
        $Table[$Key] = $Amount
    }
}

function Update-DisplayName {
    param(
        [Hashtable]$Map,
        [string]$Key,
        [string]$DisplayName
    )
    if ([string]::IsNullOrWhiteSpace($Key) -or [string]::IsNullOrWhiteSpace($DisplayName)) { return }
    $Map[$Key] = $DisplayName
}

function Get-HeaderValues {
    param($Headers, [string]$Name)

    if ($null -eq $Headers) { return @() }

    if ($Headers -is [System.Net.Http.Headers.HttpResponseHeaders]) {
        if ($Headers.Contains($Name)) { return @($Headers.GetValues($Name)) }
    }
    elseif ($Headers.PSObject.Properties.Name -contains $Name) {
        return @($Headers.$Name)
    }
    elseif ($Headers -is [hashtable] -and $Headers.ContainsKey($Name)) {
        return @($Headers[$Name])
    }

    return @()
}

function Get-NextSkip {
    param(
        $Headers,
        [int]$PageSize,
        [int]$CurrentSkip,
        [int]$ReturnedCount
    )

    foreach ($token in Get-HeaderValues -Headers $Headers -Name 'x-ms-continuationtoken') {
        if ([string]::IsNullOrWhiteSpace($token)) { continue }
        if ($token -match 'skip=(?<skip>\d+)')   { return [int]$matches['skip'] }
        if ($token -match '^\d+$')               { return [int]$token }
    }

    foreach ($linkValue in Get-HeaderValues -Headers $Headers -Name 'Link') {
        if ($linkValue -match '<(?<url>[^>]+)>;\s*rel="?next"?') {
            $url = $matches['url']
            if ($url -match 'searchCriteria\.\$skip=(?<skip>\d+)') { return [int]$matches['skip'] }
            if ($url -match '\$skip=(?<skip>\d+)')                 { return [int]$matches['skip'] }
        }
    }

    if ($ReturnedCount -eq $PageSize) {
        return $CurrentSkip + $PageSize
    }

    return $null
}

function Parse-AdoDate {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return [DateTime]::Parse($Value, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

function Invoke-AdoRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [ValidateSet("Get","Post","Put","Patch","Delete")][string]$Method = "Get",
        $Body = $null,
        [int]$MaxRetries = 3,
        [int]$RetryDelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $responseHeaders = $null
            $invokeParams = @{
                Uri                     = $Uri
                Headers                 = $Headers
                Method                  = $Method
                ResponseHeadersVariable = 'responseHeaders'
            }
            if ($Body) { $invokeParams.Body = $Body }

            $result = Invoke-RestMethod @invokeParams
            return [PSCustomObject]@{
                Result  = $result
                Headers = $responseHeaders
            }
        }
        catch [System.Net.WebException], [System.IO.IOException] {
            $message = $_.Exception.Message
            Write-Warning ("Attempt {0}/{1} failed for {2}. Error: {3}" -f $attempt, $MaxRetries, $Uri, $message)

            if ($_.Exception.InnerException) {
                Write-Verbose ("  Inner exception: {0}" -f $_.Exception.InnerException.Message)
            }

            if ($attempt -eq $MaxRetries) {
                throw
            }

            $delay = $RetryDelaySeconds * $attempt
            Start-Sleep -Seconds $delay
        }
        catch {
            Write-Error ("Non-recoverable error calling {0}: {1}" -f $Uri, $_.Exception.Message)
            throw
        }
    }
}

# --- Metric Stores -----------------------------------------------------------
$commitCounts       = @{}
$prsCreatedCounts   = @{}
$prsCompletedCounts = @{}
$prCommentCounts    = @{}
$prApprovalCounts   = @{}
$authorDisplayNames = @{}

function Get-MetricValue {
    param([Hashtable]$Table, [string]$Key)
    if ($Table.ContainsKey($Key)) { return [int]$Table[$Key] }
    return 0
}

# --- Repository Discovery ----------------------------------------------------
$reposUri = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories?api-version=$apiVersion"
try {
    $reposResponse = Invoke-AdoRequest -Uri $reposUri -Headers $headers -MaxRetries $MaxRetries -RetryDelaySeconds $RetryDelaySeconds
    $selectedRepos = $reposResponse.Result.value | Where-Object { $distinctRepoNames -contains $_.name }
}
catch {
    Write-Error "Failed to enumerate repositories. $_"
    exit 1
}

if (-not $selectedRepos) {
    Write-Host "❌ No matching repositories found."
    exit 1
}

# --- Repository Loop ---------------------------------------------------------
foreach ($repo in $selectedRepos) {
    $repoId   = $repo.id
    $repoName = $repo.name

    Write-Host ""
    Write-Host "Processing repository: $repoName"

    try {
        # --- Commits Across All Branches ---
        $commitIds       = [System.Collections.Generic.HashSet[string]]::new()
        $commitBaseUri   = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$repoId/commits"
        $commitPageSize  = 200
        $commitSkip      = 0

        do {
            $commitQuery = @(
                "searchCriteria.`$top=$commitPageSize"
                "searchCriteria.`$skip=$commitSkip"
                "searchCriteria.fromDate=$fromDateIso"
                "searchCriteria.toDate=$toDateIso"
                "api-version=$apiVersion"
            ) -join '&'

            $commitUri = "${commitBaseUri}?$commitQuery"

            $commitCall = Invoke-AdoRequest -Uri $commitUri -Headers $headers -MaxRetries $MaxRetries -RetryDelaySeconds $RetryDelaySeconds
            $commitResponse = $commitCall.Result
            $commitHeaders  = $commitCall.Headers

            $pageCount = $commitResponse.value.Count
            Write-Host "  Commits retrieved this page: $pageCount"

            foreach ($commit in $commitResponse.value) {
                if ([string]::IsNullOrWhiteSpace($commit.commitId)) { continue }
                if (-not $commitIds.Add($commit.commitId)) { continue }

                $authorInfo = Resolve-Identity $commit.author
                Increment-Metric -Table $commitCounts -Key $authorInfo.Key
                Update-DisplayName -Map $authorDisplayNames -Key $authorInfo.Key -DisplayName $authorInfo.DisplayName
            }

            $commitSkip = Get-NextSkip -Headers $commitHeaders -PageSize $commitPageSize -CurrentSkip $commitSkip -ReturnedCount $pageCount
        }
        while ($commitSkip -ne $null)

        Write-Host "  Total unique commits collected: $($commitIds.Count)"

        # --- Pull Requests ---
        $prBaseUri   = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$repoId/pullrequests"
        $prPageSize  = 100
        $prSkip      = 0
        $allPullRequests = New-Object System.Collections.Generic.List[object]

        do {
            $prQuery = @(
                "`$top=$prPageSize"
                "`$skip=$prSkip"
                "searchCriteria.status=all"
                "api-version=$apiVersion"
            ) -join '&'

            $prUri = "${prBaseUri}?$prQuery"

            $prCall = Invoke-AdoRequest -Uri $prUri -Headers $headers -MaxRetries $MaxRetries -RetryDelaySeconds $RetryDelaySeconds
            $prResponse = $prCall.Result
            $prHeaders  = $prCall.Headers

            $allPullRequests.AddRange($prResponse.value)
            $prSkip = Get-NextSkip -Headers $prHeaders -PageSize $prPageSize -CurrentSkip $prSkip -ReturnedCount $prResponse.value.Count
        }
        while ($prSkip -ne $null)

        Write-Host "  Pull requests retrieved: $($allPullRequests.Count)"

        $prsCreatedInRange   = @()
        $prsCompletedInRange = @()

        foreach ($pr in $allPullRequests) {
            $creationDate = Parse-AdoDate $pr.creationDate
            if ($creationDate -and $creationDate -ge $fromDateUtc -and $creationDate -le $toDateUtc) {
                $prsCreatedInRange += $pr
                $creator = Resolve-Identity $pr.createdBy
                Increment-Metric -Table $prsCreatedCounts -Key $creator.Key
                Update-DisplayName -Map $authorDisplayNames -Key $creator.Key -DisplayName $creator.DisplayName
            }

            if ($pr.status -eq "completed") {
                $closedDate = Parse-AdoDate $pr.closedDate
                if ($closedDate -and $closedDate -ge $fromDateUtc -and $closedDate -le $toDateUtc) {
                    $prsCompletedInRange += $pr
                    $creator = Resolve-Identity $pr.createdBy
                    Increment-Metric -Table $prsCompletedCounts -Key $creator.Key
                    Update-DisplayName -Map $authorDisplayNames -Key $creator.Key -DisplayName $creator.DisplayName
                }
            }
        }

        $prsToInspect = @{}
        foreach ($pr in $prsCreatedInRange + $prsCompletedInRange) {
            $prsToInspect[$pr.pullRequestId] = $pr
        }

        Write-Host ("  PRs in range - Created: {0}, Completed: {1}, Unique for comments/approvals: {2}" -f `
            $prsCreatedInRange.Count, $prsCompletedInRange.Count, $prsToInspect.Count)

        foreach ($prId in $prsToInspect.Keys) {
            Write-Host "    Inspecting PR ID: $prId"

            $prThreadsUri = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$repoId/pullRequests/$prId/threads?api-version=$apiVersion"
            $threadsCall = Invoke-AdoRequest -Uri $prThreadsUri -Headers $headers -MaxRetries $MaxRetries -RetryDelaySeconds $RetryDelaySeconds
            $threadsResponse = $threadsCall.Result

            foreach ($thread in $threadsResponse.value) {
                foreach ($comment in $thread.comments) {
                    $commentAuthor = Resolve-Identity $comment.author
                    Increment-Metric -Table $prCommentCounts -Key $commentAuthor.Key
                    Update-DisplayName -Map $authorDisplayNames -Key $commentAuthor.Key -DisplayName $commentAuthor.DisplayName
                }
            }

            $reviewersUri = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$repoId/pullRequests/$prId/reviewers?api-version=$apiVersion"
            $reviewersCall = Invoke-AdoRequest -Uri $reviewersUri -Headers $headers -MaxRetries $MaxRetries -RetryDelaySeconds $RetryDelaySeconds
            $reviewersResponse = $reviewersCall.Result

            foreach ($reviewer in $reviewersResponse.value) {
                if ($reviewer.vote -ge 5) {
                    $reviewerIdentity = Resolve-Identity $reviewer
                    Increment-Metric -Table $prApprovalCounts -Key $reviewerIdentity.Key
                    Update-DisplayName -Map $authorDisplayNames -Key $reviewerIdentity.Key -DisplayName $reviewerIdentity.DisplayName
                }
            }
        }
    }
    catch {
        Write-Error ("Failed while processing repository '{0}'. {1}" -f $repoName, $_.Exception.Message)
        continue
    }
}

# --- Consolidation by Display Name -------------------------------------------
$allUniqueKeys = @(
    $commitCounts.Keys
    $prsCreatedCounts.Keys
    $prsCompletedCounts.Keys
    $prCommentCounts.Keys
    $prApprovalCounts.Keys
) | Where-Object { $_ } | Sort-Object -Unique

if (-not $allUniqueKeys) {
    Write-Host "`n⚠️ No activity found for the specified parameters."
    exit 0
}

$displayGroups = @{}
foreach ($key in $allUniqueKeys) {
    $displayName = $authorDisplayNames[$key]
    if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = $key }

    if ($displayGroups.ContainsKey($displayName)) {
        $displayGroups[$displayName] += $key
    } else {
        $displayGroups[$displayName] = @($key)
    }
}

$finalReport = foreach ($displayName in ($displayGroups.Keys | Sort-Object)) {
    $keysForDisplayName = $displayGroups[$displayName]

    $commits      = 0
    $prsCreated   = 0
    $prsCompleted = 0
    $prComments   = 0
    $prApprovals  = 0

    foreach ($key in $keysForDisplayName) {
        $commits      += Get-MetricValue -Table $commitCounts       -Key $key
        $prsCreated   += Get-MetricValue -Table $prsCreatedCounts   -Key $key
        $prsCompleted += Get-MetricValue -Table $prsCompletedCounts -Key $key
        $prComments   += Get-MetricValue -Table $prCommentCounts    -Key $key
        $prApprovals  += Get-MetricValue -Table $prApprovalCounts   -Key $key
    }

    [PSCustomObject]@{
        DisplayName  = $displayName
        UniqueNames  = ($keysForDisplayName -join "; ")
        Commits      = $commits
        PRsCreated   = $prsCreated
        PRsCompleted = $prsCompleted
        PRComments   = $prComments
        PRApprovals  = $prApprovals
    }
}

$finalReport | Sort-Object DisplayName | Export-Csv -Path $OutputPath -NoTypeInformation

Write-Host "`n✅ $OutputPath created. Consolidated by display name across all repositories."
