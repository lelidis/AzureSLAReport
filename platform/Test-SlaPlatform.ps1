# Validation script for the SLA reporting platform.
# Compatible with PowerShell 7+. Run it from a host that can reach the private endpoints:
# checks 9 and 9b query the private Log Analytics workspace and report no data otherwise.

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

# First result row of a Log Analytics query as a hashtable (column -> value), or $null.
# Handles both output shapes of `az monitor log-analytics query`: a list of row objects
# (current log-analytics extension) and the raw API shape with a `tables` array.
function Get-LaRow {
    param([string]$WorkspaceCustomerId, [string]$Kql)
    $res = FromJson (az monitor log-analytics query -w $WorkspaceCustomerId --analytics-query $Kql -o json 2>$null)
    if ($null -eq $res) { return $null }
    if ($res -is [System.Collections.IDictionary] -and $res.ContainsKey('tables')) {
        $t = @($res['tables'])[0]
        if (-not $t -or @($t.rows).Count -eq 0) { return $null }
        $row = @{}
        for ($i = 0; $i -lt @($t.columns).Count; $i++) { $row[$t.columns[$i].name] = @($t.rows)[0][$i] }
        return $row
    }
    return @($res)[0]
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

# 3. Storage account: private, keyless, reports container present
$saList = FromJson (az storage account list -g $ResourceGroup 2>$null)
$sa = $null
if ($saList) { $sa = $saList | Where-Object { $_.kind -eq 'StorageV2' } | Select-Object -First 1 }
Add-Check '3a. Storage account' ([bool]$sa) (Pick ([bool]$sa) $sa.name 'none')

if ($sa) {
    $private = ($sa.publicNetworkAccess -eq 'Disabled') -and ($sa.allowSharedKeyAccess -eq $false)
    Add-Check '3b. Storage private + keyless' $private "publicNetworkAccess=$($sa.publicNetworkAccess); allowSharedKeyAccess=$($sa.allowSharedKeyAccess)"
    $containers = FromJson (az storage container-rm list --storage-account $sa.name -g $ResourceGroup 2>$null)
    $containerNames = @($containers | ForEach-Object { $_.name })
    Add-Check '3c. Reports container exists' ($containerNames -contains 'reports') ($containerNames -join ',')
}

# 4. Function App + identity
$fnList = FromJson (az functionapp list -g $ResourceGroup 2>$null)
$fn = $null
if ($fnList) { $fn = $fnList | Select-Object -First 1 }
Add-Check '4a. Function App' ([bool]$fn) (Pick ([bool]$fn) $fn.name 'none')

$miOk = $false
if ($fn -and $fn.identity -and $fn.identity.principalId) { $miOk = $true }
Add-Check '4b. Function App MI' $miOk (Pick $miOk $fn.identity.principalId 'no MI')

if ($fn) {
    $netOk = ($fn.publicNetworkAccess -eq 'Disabled') -and [bool]$fn.virtualNetworkSubnetId
    Add-Check '4c. Function private + VNet-integrated' $netOk "publicNetworkAccess=$($fn.publicNetworkAccess); kind=$($fn.kind)"

    # 4d. Function subnet egress is locked down: NSG attached, no default outbound access.
    # The NAT gateway is the single path to Azure Resource Manager (absent if deployed with deployNatGateway=false).
    $subId = az account show --query id -o tsv
    $snet = FromJson (az rest --method get --uri "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/virtualNetworks/vnet-sla/subnets/snet-functions?api-version=2023-11-01" 2>$null)
    if ($snet) {
        $p = $snet.properties
        $hasNsg = [bool]$p.networkSecurityGroup
        $hasNat = [bool]$p.natGateway
        $egressOk = $hasNsg -and ($p.defaultOutboundAccess -eq $false)
        Add-Check '4d. Function subnet egress locked (NSG, no default outbound)' $egressOk "nsg=$hasNsg; defaultOutboundAccess=$($p.defaultOutboundAccess); natGateway=$hasNat"
    } else {
        Add-Check '4d. Function subnet egress locked (NSG, no default outbound)' $false 'subnet snet-functions not found'
    }
}

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
    if ($r2) { $hasBlob = [bool]($r2 | Where-Object { $_.roleDefinitionName -eq 'Storage Blob Data Owner' }) }
    Add-Check '5b. MI -> Blob Data Owner' $hasBlob "$(@($r2).Count) assignment(s) on storage"
}
if ($miOk) {
    $dcrId = az resource list -g $ResourceGroup --resource-type Microsoft.Insights/dataCollectionRules --query "[0].id" -o tsv 2>$null
    if ($dcrId) {
        $r3 = FromJson (az role assignment list --assignee $fn.identity.principalId --scope $dcrId 2>$null)
        $hasDcr = $false
        if ($r3) { $hasDcr = [bool]($r3 | Where-Object { $_.roleDefinitionName -eq 'Monitoring Metrics Publisher' }) }
        Add-Check '5c. MI -> Monitoring Metrics Publisher on DCR' $hasDcr "$(@($r3).Count) assignment(s) on $(($dcrId -split '/')[-1])"
    } else {
        Add-Check '5c. MI -> Monitoring Metrics Publisher on DCR' $false 'data collection rule not found'
    }
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
    $deployed = ($funcs -contains 'GenerateSlaReport') -and ($funcs -contains 'RefreshInventory')
    Add-Check '6. Function code deployed (GenerateSlaReport + RefreshInventory)' $deployed ($funcs -join ',')
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
    $row = Get-LaRow $customerId $q
    if ($row -and $null -ne $row['Events']) {
        $events = [int]$row['Events']
        $rcount = [int]$row['Resources']
        Add-Check '9. ResourceHealth in last 7d' ($events -gt 0) "Events=$events; Resources=$rcount"
    } else {
        Add-Check '9. ResourceHealth in last 7d' $false 'No data (allow ~15 min after enabling the diag setting) or workspace not reachable from this network'
    }

    # 9b. Inventory snapshot written by RefreshInventory (workbook reads SlaInventory_CL; arg() is not usable on Private Link)
    $q2 = 'SlaInventory_CL | summarize Resources=count(), Snapshot=max(TimeGenerated)'
    $row2 = Get-LaRow $customerId $q2
    if ($row2 -and $null -ne $row2['Resources'] -and [int]$row2['Resources'] -gt 0) {
        Add-Check '9b. Inventory snapshot in SlaInventory_CL' $true "Resources=$($row2['Resources']); Snapshot=$($row2['Snapshot'])"
    } else {
        Add-Check '9b. Inventory snapshot in SlaInventory_CL' $false 'Empty (run RefreshInventory, README step 4, and wait a few minutes) or workspace not reachable from this network'
    }
}

# 10. Private endpoints (storage blob/queue/table, function sites, AMPLS) approved
$pes = @(FromJson (az network private-endpoint list -g $ResourceGroup 2>$null))
$approved = @($pes | Where-Object { $_.privateLinkServiceConnections[0].privateLinkServiceConnectionState.status -eq 'Approved' }).Count
Add-Check '10. Private endpoints approved' ($pes.Count -ge 5 -and $approved -eq $pes.Count) "$approved of $($pes.Count) approved (expected 5)"

$results | Format-Table -AutoSize
$failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($failCount -gt 0) {
    Write-Host "`n$failCount check(s) FAILED. Address those before relying on the report." -ForegroundColor Yellow
} else {
    Write-Host "`nAll checks passed." -ForegroundColor Green
}
