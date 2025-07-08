<#
.SYNOPSIS
    Dev Activity Report for specified repositories, with PR completions filtered by closedDate.

.PARAMETER Organization
    Azure DevOps organization name.

.PARAMETER Project
    Project name.

.PARAMETER PAT
    Personal Access Token.

.PARAMETER RepositoryNames
    Array of repository names to include.

.PARAMETER FromDate
    Start date (yyyy-MM-dd).

.PARAMETER ToDate
    End date (yyyy-MM-dd).

.EXAMPLE
    .\DevActivityReport.ps1 -Organization "myOrg" -Project "myProject" -PAT "YOUR_PAT" `
      -RepositoryNames "Repo1","Repo2" -FromDate "2025-07-01" -ToDate "2025-07-05"
#>

param (
    [string]$Organization = "",
    [string]$Project = "",
    [string]$PAT = "",
    [string[]]$RepositoryNames = @("Proj1","Proj2"),
    [string]$FromDate = "2025-01-01",
    [string]$ToDate = "2025-06-30"
)

Write-Host "Dev Activity Report"
Write-Host "Organization: $Organization"
Write-Host "Project: $Project"
Write-Host "Repositories: $($RepositoryNames -join ', ')"
Write-Host "FromDate: $FromDate"
Write-Host "ToDate: $ToDate"

$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":" + $PAT))
$headers = @{ Authorization = "Basic $base64AuthInfo" }

$reposUri = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories?api-version=7.0"
$reposResponse = Invoke-RestMethod -Uri $reposUri -Headers $headers -Method Get
$selectedRepos = $reposResponse.value | Where-Object { $RepositoryNames -contains $_.name }

if ($selectedRepos.Count -eq 0) {
    Write-Host "❌ No matching repositories found."
    exit 1
}

$commitCounts = @{}
$prsCreated = @{}
$prsCompleted = @{}
$prComments = @{}
$prApprovals = @{}
$authorNames = @{}

foreach ($repo in $selectedRepos) {
    $repoId = $repo.id
    $repoName = $repo.name

    Write-Host "\nProcessing repository: $repoName"

    # === Commits Across All Branches ===
    $uniqueCommits = @{}
    $branchesUri = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$repoId/refs?filter=heads/&api-version=7.0"
    $branchesResponse = Invoke-RestMethod -Uri $branchesUri -Headers $headers -Method Get
    $branches = $branchesResponse.value

    foreach ($branch in $branches) {
        $branchName = $branch.name -replace "refs/heads/", ""
        $commitUri = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$repoId/commits" +
            "?searchCriteria.itemVersion.version=$branchName" +
            "&searchCriteria.itemVersion.versionType=branch" +
            "&searchCriteria.fromDate=$FromDate" +
            "&searchCriteria.toDate=$ToDate" +
            "&api-version=7.0"

        $commitResponse = Invoke-RestMethod -Uri $commitUri -Headers $headers -Method Get

        foreach ($commit in $commitResponse.value) {
            $commitId = $commit.commitId
            if (-not $uniqueCommits.ContainsKey($commitId)) {
                $uniqueCommits[$commitId] = @{ Email = $commit.author.email; Name = $commit.author.name }
            }
        }
    }

    foreach ($commit in $uniqueCommits.GetEnumerator()) {
        $email = $commit.Value.Email
        $name = $commit.Value.Name
        if ($commitCounts.ContainsKey($email)) { $commitCounts[$email]++ } else { $commitCounts[$email] = 1 }
        $authorNames[$email] = $name
    }

    # === Pull Requests ===
    $prUri = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$repoId/pullrequests?searchCriteria.status=all&api-version=7.0"
    $prResponse = Invoke-RestMethod -Uri $prUri -Headers $headers -Method Get
    $allPRs = $prResponse.value

    $prsCreatedInRange = $allPRs | Where-Object { $_.creationDate -ge $FromDate -and $_.creationDate -le $ToDate }
    $prsCompletedInRange = $allPRs | Where-Object { $_.status -eq "completed" -and $_.closedDate -ge $FromDate -and $_.closedDate -le $ToDate }

    foreach ($pr in $prsCreatedInRange) {
        $login = $pr.createdBy.uniqueName
        $name = $pr.createdBy.displayName
        if ($prsCreated.ContainsKey($login)) { $prsCreated[$login]++ } else { $prsCreated[$login] = 1 }
        $authorNames[$login] = $name
    }

    foreach ($pr in $prsCompletedInRange) {
        $login = $pr.createdBy.uniqueName
        $name = $pr.createdBy.displayName
        if ($prsCompleted.ContainsKey($login)) { $prsCompleted[$login]++ } else { $prsCompleted[$login] = 1 }
        $authorNames[$login] = $name
    }

    $prsToCheck = $prsCreatedInRange + $prsCompletedInRange | Select-Object -Unique

    foreach ($pr in $prsToCheck) {
        $threadsUri = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$repoId/pullRequests/$($pr.pullRequestId)/threads?api-version=7.0"
        $threadsResponse = Invoke-RestMethod -Uri $threadsUri -Headers $headers -Method Get

        foreach ($thread in $threadsResponse.value) {
            foreach ($comment in $thread.comments) {
                $login = $comment.author.uniqueName
                $name = $comment.author.displayName
                if ($prComments.ContainsKey($login)) { $prComments[$login]++ } else { $prComments[$login] = 1 }
                $authorNames[$login] = $name
            }
        }

        $reviewersUri = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$repoId/pullRequests/$($pr.pullRequestId)/reviewers?api-version=7.0"
        $reviewersResponse = Invoke-RestMethod -Uri $reviewersUri -Headers $headers -Method Get

        foreach ($reviewer in $reviewersResponse.value) {
            if ($reviewer.vote -ge 5) {
                $login = $reviewer.uniqueName
                $name = $reviewer.displayName
                if ($prApprovals.ContainsKey($login)) { $prApprovals[$login]++ } else { $prApprovals[$login] = 1 }
                $authorNames[$login] = $name
            }
        }
    }
}

# === Combine and Consolidate by DisplayName ===
$allAuthors = $commitCounts.Keys + $prsCreated.Keys + $prsCompleted.Keys + $prComments.Keys + $prApprovals.Keys | Sort-Object -Unique
$displayNameMap = @{}
foreach ($uniqueName in $allAuthors) {
    $name = $authorNames[$uniqueName]
    if ($displayNameMap.ContainsKey($name)) {
        $displayNameMap[$name] += $uniqueName
    } else {
        $displayNameMap[$name] = @($uniqueName)
    }
}

$finalReport = @()
foreach ($displayName in $displayNameMap.Keys) {
    $totalCommits = 0
    $totalPRsCreated = 0
    $totalPRsCompleted = 0
    $totalPRComments = 0
    $totalPRApprovals = 0

    foreach ($uniqueName in $displayNameMap[$displayName]) {
        $totalCommits += $commitCounts[$uniqueName] | ForEach-Object { if ($_ -eq $null) {0} else {$_} }
        $totalPRsCreated += $prsCreated[$uniqueName] | ForEach-Object { if ($_ -eq $null) {0} else {$_} }
        $totalPRsCompleted += $prsCompleted[$uniqueName] | ForEach-Object { if ($_ -eq $null) {0} else {$_} }
        $totalPRComments += $prComments[$uniqueName] | ForEach-Object { if ($_ -eq $null) {0} else {$_} }
        $totalPRApprovals += $prApprovals[$uniqueName] | ForEach-Object { if ($_ -eq $null) {0} else {$_} }
    }

    $finalReport += [PSCustomObject]@{
        DisplayName  = $displayName
        UniqueNames  = ($displayNameMap[$displayName] -join "; ")
        Commits      = $totalCommits
        PRsCreated   = $totalPRsCreated
        PRsCompleted = $totalPRsCompleted
        PRComments   = $totalPRComments
        PRApprovals  = $totalPRApprovals
    }
}

$finalReport | Export-Csv -Path "output\DevActivityReport_SelectedRepos.csv" -NoTypeInformation

Write-Host "\n✅ DevActivityReport_SelectedRepos.csv created! Consolidated by display name, all branches included."
