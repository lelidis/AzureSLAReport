# Quick Setup — enable ResourceHealth ingestion per subscription
# Run this for every subscription you want covered. Idempotent.

param(
    [Parameter(Mandatory)] [string]$WorkspaceResourceId,   # full /subscriptions/.../workspaces/...
    [string[]]$SubscriptionIds                             # omit to do all accessible subs
)

if (-not $SubscriptionIds) {
    $SubscriptionIds = (az account list --query "[?state=='Enabled'].id" -o tsv) -split "`r?`n"
}

foreach ($sub in $SubscriptionIds) {
    Write-Host "==> $sub"
    az account set --subscription $sub | Out-Null

    az monitor diagnostic-settings subscription create `
        --name 'sla-resourcehealth-to-law' `
        --location global `
        --workspace $WorkspaceResourceId `
        --logs '[{\"category\":\"ResourceHealth\",\"enabled\":true},{\"category\":\"Administrative\",\"enabled\":false}]' `
        2>$null | Out-Null

    # If it already existed, update instead
    if ($LASTEXITCODE -ne 0) {
        az monitor diagnostic-settings subscription update `
            --name 'sla-resourcehealth-to-law' `
            --workspace $WorkspaceResourceId `
            --logs '[{\"category\":\"ResourceHealth\",\"enabled\":true}]' | Out-Null
    }
}

Write-Host "Done. Allow ~15 min for ResourceHealthEvent rows to appear in Log Analytics." -ForegroundColor Green
