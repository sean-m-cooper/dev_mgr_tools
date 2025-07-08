
param (
    [string[]]$IssueTypes = @("Bug", "Story", "Spike", "Sub-Task"),

    [string[]]$AssigneeEmails = @(
        "dev1@company.com",
        "dev2@company.com"
    ),

    [string]$FromDate = "2025/01/01"
)

# 1️⃣ Dot-source the shared logic
Import-Module .\JiraConnection.psm1 -Force


# 2️⃣ Get header & resolve emails
$headers = Get-JiraAuthHeader

$AccountIds = Resolve-JiraEmailsToAccountIds -Headers $Headers -Emails $AssigneeEmails

# Trim & remove empty entries
$AccountIds = $AccountIds | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
$IssueTypes = $IssueTypes | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

if ($AccountIds.Count -eq 0) {
    Write-Error "❌ No AccountIds found. Exiting."
    exit 1
}

if ($IssueTypes.Count -eq 0) {
    Write-Error "❌ No IssueTypes specified. Exiting."
    exit 1
}

$assigneeClause = "assignee in (" + ( ($AccountIds | ForEach-Object { "'$_'" }) -join ", " ) + ")"
$issueTypeClause = "type in (" + (($IssueTypes | ForEach-Object { "'$_'" }) -join ", ") + ")"

$JqlLines = @(
    $assigneeClause,
    "AND $issueTypeClause",
    "AND status = Closed",
    "AND statusCategoryChangedDate >= '$FromDate'",
    "ORDER BY type, statusCategoryChangedDate ASC"
)
$Jql = $JqlLines -join "`n"

# Write-Host "✅ Final JQL:`n$Jql"

# === Fields ===
$fields = @(
    "issuetype",
    "key",
    "id",
    "summary",
    "assignee",
    "customfield_10016",
    "components",
    "statuscategorychangedate",
    "labels"
)


# 5️⃣ Query Jira
$Issues = Invoke-JiraSearch -Headers $Headers -Jql $Jql -Fields $Fields

# 6️⃣ Transform to report
$Results = $Issues | ForEach-Object {
    $dt = if ($_.fields.statuscategorychangedate) {
        [DateTime]::Parse($_.fields.statuscategorychangedate).ToString("yyyy-MM-dd HH:mm")
    } else { "\" }

    [PSCustomObject]@{
        "Issue Type" = $_.fields.issuetype.name
        "Issue Key" = $_.key
        "Issue id" = $_.id
        "Summary" = $_.fields.summary
        "Assignee" = $_.fields.assignee.displayName
        "Assignee Id" = $_.fields.assignee.accountId
        "Story Points" = $_.fields.customfield_10016
        "Components" = ($_.fields.components | ForEach-Object { $_.name }) -join ",\"
        "Status Category Changed\" = $dt
        "Labels\" = ($_.fields.labels -join ",\")
    }}

$results | Export-Csv -Path "output\JiraDeveloperProductivityStats.csv" -NoTypeInformation

Write-Host "`n✅ JiraDeveloperProductivityStats.csv created for users: $($AssigneeEmails -join ', ') and issue types: $($IssueTypes -join ', ')!"

