[CmdletBinding()]
param(
    [string]$DiagnosticSettingName = 'sla-resourcehealth-to-law',
    [switch]$AllSubscriptions
)

$ErrorActionPreference = 'Stop'

function Update-SubscriptionDiagnosticSetting {
    param(
        [string]$SubscriptionId,
        [string]$SettingName
    )

    az account set --subscription $SubscriptionId | Out-Null

    $settingsJson = az monitor diagnostic-settings subscription list -o json
    if (-not $settingsJson) {
        throw "Unable to list subscription diagnostic settings for subscription $SubscriptionId."
    }

    $settings = $settingsJson | ConvertFrom-Json
    $current = $null
    if ($settings.value) {
        $current = $settings.value | Where-Object { $_.name -eq $SettingName } | Select-Object -First 1
    }

    if (-not $current) {
        throw "Diagnostic setting '$SettingName' not found on subscription $SubscriptionId."
    }

    $workspaceId = $current.workspaceId

    $body = @{
        properties = @{
            workspaceId = $workspaceId
            logs = @(
                @{ category = 'ResourceHealth'; enabled = $true }
                @{ category = 'Administrative'; enabled = $true }
                @{ category = 'Security'; enabled = $false }
                @{ category = 'ServiceHealth'; enabled = $false }
                @{ category = 'Alert'; enabled = $false }
                @{ category = 'Recommendation'; enabled = $false }
                @{ category = 'Policy'; enabled = $false }
                @{ category = 'Autoscale'; enabled = $false }
            )
        }
    } | ConvertTo-Json -Depth 8 -Compress

    $tmpBody = Join-Path $env:TEMP ("diag-setting-update-{0}.json" -f $SubscriptionId)
    $body | Set-Content -Path $tmpBody -Encoding UTF8

    az rest --method put `
        --uri "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/diagnosticSettings/$SettingName?api-version=2021-05-01-preview" `
        --headers "Content-Type=application/json" `
        --body "@$tmpBody" -o none

    [pscustomobject]@{
        SubscriptionId = $SubscriptionId
        WorkspaceId = $workspaceId
        Updated = $true
    }
}

$currentSub = az account show --query id -o tsv
if (-not $currentSub) {
    throw 'No active Azure subscription in az CLI context.'
}

$targetSubscriptions = @($currentSub)
if ($AllSubscriptions) {
    $targetSubscriptions = @(az account list --query "[?state=='Enabled'].id" -o tsv | Where-Object { $_ })
}

$results = foreach ($subscriptionId in $targetSubscriptions) {
    try {
        Update-SubscriptionDiagnosticSetting -SubscriptionId $subscriptionId -SettingName $DiagnosticSettingName
    } catch {
        [pscustomobject]@{
            SubscriptionId = $subscriptionId
            WorkspaceId = $null
            Updated = $false
            Error = $_.Exception.Message
        }
    }
}

$results | Format-Table -AutoSize

$failed = @($results | Where-Object { -not $_.Updated }).Count
if ($failed -gt 0) {
    Write-Host "`n$failed subscription(s) failed to update." -ForegroundColor Yellow
} else {
    Write-Host "`nAdministrative and ResourceHealth are now enabled on $($results.Count) subscription(s)." -ForegroundColor Green
}
