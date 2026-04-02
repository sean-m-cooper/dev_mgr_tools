# =============================================
# Jira PAT Diagnostics Script
# =============================================

param (
    [string]$JiraDomain = "company.atlassian.net",
    [string]$JiraUserEmail = "admin@company.com",
    [string]$JiraAPIToken = "JiraPATC"
)

# 1️⃣ Generate Basic Auth Header
$pair = "${JiraUserEmail}:${JiraAPIToken}"
$token = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair))
Write-Host "Auth Pair (before encode): ${JiraUserEmail}:${JiraAPIToken}"
Write-Host "Base64: $token"

$headers = @{
    Authorization = "Basic $token"
    "Content-Type" = "application/json"
}

Write-Host "========================================="
Write-Host "🔑 Checking PAT Identity (/myself)"
Write-Host "========================================="

try {
    $myself = Invoke-RestMethod -Uri "https://$JiraDomain/rest/api/2/myself" `
        -Headers $headers -Method Get

    $myself | ConvertTo-Json -Depth 5
    Write-Host "`n✅ Authenticated as: $($myself.displayName) <$($myself.emailAddress)>"
    Write-Host "   AccountId: $($myself.accountId)"
} catch {
    Write-Host "`n❌ Failed to get /myself:`n$($_.Exception.Message)"
    exit 1
}

# 2️⃣ Test /rest/api/3/project/search
Write-Host "`n========================================="
Write-Host "🔍 Checking Projects (/rest/api/3/project/search)"
Write-Host "========================================="

try {
    $projects3 = Invoke-RestMethod -Uri "https://$JiraDomain/rest/api/3/project/search" `
        -Headers $headers -Method Get

    $projects3 | ConvertTo-Json -Depth 5
    Write-Host "`n🔢 Total projects found: $($projects3.total)"
} catch {
    Write-Host "`n❌ Failed to get /rest/api/3/project/search:`n$($_.Exception.Message)"
}

# 3️⃣ Test /rest/api/2/project
Write-Host "`n========================================="
Write-Host "🕵️ Checking Projects (/rest/api/2/project)"
Write-Host "========================================="

try {
    $projects2 = Invoke-RestMethod -Uri "https://$JiraDomain/rest/api/2/project" `
        -Headers $headers -Method Get

    $projects2 | ConvertTo-Json -Depth 5
    Write-Host "`n🔢 Total projects found: $($projects2.Count)"
} catch {
    Write-Host "`n❌ Failed to get /rest/api/2/project:`n$($_.Exception.Message)"
}

Write-Host "`n✅ Diagnostics complete. Compare the results above!"
Write-Host "👉 If /api/2 works but /api/3 does not, it's likely a scope or permission mapping issue."
Write-Host "👉 If both show zero, check your user's Browse Projects permission & product access!"