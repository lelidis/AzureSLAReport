# Validation script for the SLA reporting platform.
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-sla-monitoring',
    [string]$WorkspaceName = 'law-sla-prod'
)

$ErrorActionPreference = 'Continue'
$results = New-Object System.Collections.Generic.List[object]

function Add-Check {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    $status = 'FAIL'
    if ($Ok) { $status = 'PASS' }
    $results.Add([pscustomobject]@{ Check = $Name; Status = $status; Detail = $Detail })
}

function FromJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try   { return ($Text | ConvertFrom-Json -AsHashtable) }
    catch { return $null }
}

function Pick {
    param($Cond, $A, $B = '')
    if ($Cond) { return $A } else { return $B }
}

Write-Host "Subscription: $(az account show --query name -o tsv)" -ForegroundColor Cyan

# 1. Resource group
$rg = FromJson (az group show -n $ResourceGroup 2>$null)
Add-Check '1. Resource group exists' ([bool]$rg) $ResourceGroup

# 2. Log Analytics workspace + retention
$ws = FromJson (az monitor log-analytics workspace show -g $ResourceGroup -n $WorkspaceName 2>$null)
$wsOk = [bool]$ws
Add-Check '2. Log Analytics workspace' $wsOk (Pick $wsOk "$WorkspaceName / retention=$($ws.retentionInDays)d" 'not found')
$workspaceId = $null; $customerId = $null
if ($wsOk) { $workspaceId = $ws.id; $customerId = $ws.customerId }

# 3. Storage account + static website
$saList = FromJson (az storage account list -g $ResourceGroup 2>$null)
$sa = $null
if ($saList) { $sa = $saList | Where-Object { $_.kind -eq 'StorageV2' } | Select-Object -First 1 }
Add-Check '3a. Storage account' ([bool]$sa) (Pick ([bool]$sa) $sa.name 'none')

if ($sa) {
    $sw = FromJson (az storage blob service-properties show --account-name $sa.name --auth-mode login --query staticWebsite 2>$null)
    $swOk = $false
    if ($sw -and $sw.enabled) { $swOk = $true }
    Add-Check '3b. Static website enabled' $swOk (Pick ([bool]$sw) "indexDocument=$($sw.indexDocument)" 'disabled')
}

# 4. Function App + identity
$fnList = FromJson (az functionapp list -g $ResourceGroup 2>$null)
$fn = $null
if ($fnList) { $fn = $fnList | Select-Object -First 1 }
Add-Check '4a. Function App' ([bool]$fn) (Pick ([bool]$fn) $fn.name 'none')

$miOk = $false
if ($fn -and $fn.identity -and $fn.identity.principalId) { $miOk = $true }
Add-Check '4b. Function App MI' $miOk (Pick $miOk $fn.identity.principalId 'no MI')

# 5. RBAC for the Function MI
if ($miOk -and $wsOk) {
    $r1 = FromJson (az role assignment list --assignee $fn.identity.principalId --scope $ws.id 2>$null)
    $hasLA = $false
    if ($r1) { $hasLA = [bool]($r1 | Where-Object { $_.roleDefinitionName -eq 'Log Analytics Reader' }) }
    Add-Check '5a. MI -> Log Analytics Reader' $hasLA "$(@($r1).Count) assignment(s) on workspace"
}
if ($miOk -and $sa) {
    $r2 = FromJson (az role assignment list --assignee $fn.identity.principalId --scope $sa.id 2>$null)
    $hasBlob = $false
    if ($r2) { $hasBlob = [bool]($r2 | Where-Object { $_.roleDefinitionName -eq 'Storage Blob Data Contributor' }) }
    Add-Check '5b. MI -> Blob Data Contributor' $hasBlob "$(@($r2).Count) assignment(s) on storage"
}

# 6. Function code is deployed
if ($fn) {
    $subId = az account show --query id -o tsv
    $funcsRaw = az rest --method get `
        --uri "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$($fn.name)/functions?api-version=2023-12-01" `
        --query "value[].name" -o tsv 2>$null
    $funcs = @()
    if ($funcsRaw) {
        $funcs = ($funcsRaw -split "`r?`n") | Where-Object { $_ } | ForEach-Object { ($_ -split '/')[-1] }
    }
    $deployed = $funcs -contains 'GenerateSlaReport'
    Add-Check '6. Function code deployed (GenerateSlaReport)' $deployed ($funcs -join ',')
}

# 7. Workbook
$wb = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/workbooks --query "[0].name" -o tsv 2>$null
Add-Check '7. Workbook resource' ([bool]$wb) (Pick ([bool]$wb) $wb 'not found')

# 8. Subscription -> ResourceHealth -> workspace
$dsRoot = FromJson (az monitor diagnostic-settings subscription list 2>$null)
$has = $false
$totalDs = 0
if ($dsRoot -and $dsRoot.value) {
    $totalDs = @($dsRoot.value).Count
    foreach ($d in $dsRoot.value) {
        if ($workspaceId -and $d.workspaceId -eq $workspaceId) {
            foreach ($l in $d.logs) {
                if ($l.category -eq 'ResourceHealth' -and $l.enabled) { $has = $true }
            }
        }
    }
}
Add-Check '8. Sub diag setting -> ResourceHealth' $has "$totalDs total subscription diagnostic setting(s)"

# 9. Data flowing
if ($customerId) {
    $q = @"
AzureActivity
| where TimeGenerated > ago(7d)
| where CategoryValue == 'ResourceHealth'
| summarize Events=count(), Resources=dcount(ResourceId)
"@
    $row = FromJson (az monitor log-analytics query -w $customerId --analytics-query $q --query "tables[0].rows[0]" 2>$null)
    if ($row -and @($row).Count -ge 2) {
        $events = [int]$row[0]
        $rcount = [int]$row[1]
        Add-Check '9. ResourceHealth in last 7d' ([int]$events -gt 0) "Events=$events; Resources=$rcount"
    } else {
        Add-Check '9. ResourceHealth in last 7d' $false 'No data yet (allow ~15 min after enabling diag setting)'
    }
}

# 10. Static site reachable
if ($sa) {
    $primaryEp = $null
    if ($sa.primaryEndpoints) { $primaryEp = $sa.primaryEndpoints.web }
    if ($primaryEp) {
        $code = 0
        try {
            $resp = Invoke-WebRequest -Uri $primaryEp -Method Head -TimeoutSec 10 -ErrorAction SilentlyContinue
            if ($resp) { $code = [int]$resp.StatusCode }
        } catch { $code = 0 }
        if ($code -eq 0) {
            try {
                $curlCode = & curl.exe -s -o NUL -w "%{http_code}" $primaryEp
                if ($curlCode -match '^\d+$') { $code = [int]$curlCode }
            } catch { }
        }
        $reachable = $code -in 200,403,404
        Add-Check '10. Static website endpoint reachable' $reachable "$primaryEp (HTTP $code)"
    }
}

$results | Format-Table -AutoSize
$failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($failCount -gt 0) {
    Write-Host "`n$failCount check(s) FAILED. Address those before relying on the report." -ForegroundColor Yellow
} else {
    Write-Host "`nAll checks passed." -ForegroundColor Green
}
