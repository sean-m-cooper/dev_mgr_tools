function Get-JiraAuthHeader {
    param (
        [string]$UserEmail='admin@company.com',
        [string]$ApiToken='JiraPAT'
    )

    return @{
    Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${UserEmail}:${apiToken}"))
    Accept = "application/json"
    }
}

function Get-Domain{
    return 'company.atlassian.net'
}

function Resolve-JiraEmailsToAccountIds {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Headers,
        [Parameter(Mandatory)]
        [string[]]$Emails
    )

    $accountIds = @()
    $domain = Get-Domain

    foreach ($email in $Emails) {
        $uri = "https://$domain/rest/api/3/user/search?query=$email"

        try {
            $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop
 Write-Host "Response:`n$($response | ConvertTo-Json -Depth 10)"
            if ($response.Count -gt 0) {
                foreach ($user in $response) {
                    $accountIds += $user.accountId
                    Write-Host "✅ Resolved: $email → AccountId: $($user.accountId) ($($user.displayName))"
                }
            }
            else {
                Write-Warning "⚠️ No match found for email: $email. Please check spelling or permissions."
            }

        } catch {
            Write-Error "❌ Error resolving email '$email': $($_.Exception.Message)"
        }
    }

    if ($accountIds.Count -eq 0) {
        Write-Warning "⚠️ Warning: No valid accountIds were resolved. Double-check your email list!"
    }

    return $accountIds
}


function Invoke-JiraSearch {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$Jql,
        [Parameter(Mandatory)][string[]]$Fields,
        [int]$MaxResults = 100
    )

    $body = @{
        jql = $Jql
        maxResults = $MaxResults
        fields = $Fields
    } | ConvertTo-Json -Depth 5

    # 🟢 Jira Cloud requires application/json for POST
    if (-not $Headers.ContainsKey("Content-Type")) {
        $Headers["Content-Type"] = "application/json"
    }
    $domain = Get-Domain
    $url = "https://$domain/rest/api/3/search"

    Write-Host "`n📡 Querying Jira: $url"
    Write-Host "JQL:`n$Jql`n"

    $response = Invoke-RestMethod -Uri $url -Method Post -Headers $Headers -Body $body

    return $response.issues
}

function Encode-Url {
    param([string]$StringToEncode)
    return [uri]::EscapeDataString($StringToEncode)
}


Export-ModuleMember -Function Get-JiraAuthHeader, Resolve-JiraEmailsToAccountIds, Invoke-JiraSearch, Encode-Url, Get-Domain