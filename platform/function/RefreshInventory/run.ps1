# =============================================================================
# RefreshInventory - Timer-triggered Function
#
# Runs daily at 02:30 UTC. Reads the resource inventory from Azure Resource
# Graph and writes it as a snapshot to the SlaInventory_CL table of the private
# Log Analytics workspace through the Logs Ingestion API (private endpoint).
#
# Why: the workbook cannot call arg('') inside Log Analytics when the workspace
# is reached over Azure Monitor Private Link ("The Azure Data Explorer (ADX)
# pattern cannot be used with Private Link"). It joins this table instead, so
# every workbook query stays inside the private workspace.
#
# Snapshot semantics: every row of one run carries the same TimeGenerated; the
# workbook uses the rows of the newest snapshot.
#
# App settings consumed (set in main.bicep):
#   DCE_LOGS_INGESTION_ENDPOINT - logs ingestion endpoint of the data collection endpoint
#   DCR_IMMUTABLE_ID            - immutable id of the data collection rule
#   INVENTORY_STREAM            - stream name (default Custom-SlaInventory_CL)
# Needs Reader on every reported subscription (Azure Resource Graph) and
# Monitoring Metrics Publisher on the data collection rule.
# =============================================================================
param($Timer)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../Shared/SlaCommon.ps1"

$endpoint = $env:DCE_LOGS_INGESTION_ENDPOINT
$ruleId   = $env:DCR_IMMUTABLE_ID
$stream   = if ($env:INVENTORY_STREAM) { $env:INVENTORY_STREAM } else { 'Custom-SlaInventory_CL' }
if (-not $endpoint -or -not $ruleId) { throw 'DCE_LOGS_INGESTION_ENDPOINT and DCR_IMMUTABLE_ID app settings are required.' }

try {
    $inventory = @(Get-ArgInventory)
} catch {
    throw "Inventory through Azure Resource Graph failed: $($_.Exception.Message). The Function identity needs Reader on the subscriptions and outbound HTTPS to management.azure.com (NAT gateway / firewall egress, see README)."
}
Write-Host "Inventory resources read from Azure Resource Graph: $($inventory.Count)"
if ($inventory.Count -eq 0) {
    Write-Warning 'No resources found: grant the Function identity Reader on the subscriptions to report. Nothing was ingested.'
    return
}

$snapshot = [datetime]::UtcNow.ToString('o')
$uri = '{0}/dataCollectionRules/{1}/streams/{2}?api-version=2023-01-01' -f $endpoint.TrimEnd('/'), $ruleId, $stream
# The Logs Ingestion API accepts at most 1 MB per call; 1,000 rows stay far below it even with long resource IDs.
$chunkSize = 1000
for ($i = 0; $i -lt $inventory.Count; $i += $chunkSize) {
    $last = [math]::Min($i + $chunkSize, $inventory.Count) - 1
    $rows = foreach ($r in $inventory[$i..$last]) {
        [ordered]@{ TimeGenerated = $snapshot; ResourceId = $r.ResourceId; RType = $r.RType; Region = $r.Region; ArgType = $r.ArgType }
    }
    $json = ConvertTo-Json -InputObject @($rows) -Compress -Depth 4
    Invoke-Rest -Method Post -Uri $uri -Resource 'https://monitor.azure.com/' -Body $json | Out-Null
}
Write-Host "Inventory snapshot $snapshot ingested: $($inventory.Count) resources into $stream."
