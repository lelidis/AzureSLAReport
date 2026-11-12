# =============================================================================
# GenerateSlaReport - Timer-triggered Function
#
# Runs on the 1st of each month at 06:00 UTC. Produces the same data as the
# Azure Availability SLA workbook (platform/inject-queries.ps1), aligned 100%:
#   - Full 49-service catalog (ARG inventory + RType / ExpectedSLA / SlaBasis)
#   - Per-resource availability for the previous month
#     (ResourceId, RType, Region, ActualSLA, ExpectedSLA, SlaBasis,
#      UnavailableMinutes, PlatformEvents)
#   - Region x Month (12-month) availability matrix, 100% backfilled
# Renders HTML/CSV and writes them to a PRIVATE blob container. Everything is
# REST with the managed identity (Shared/SlaCommon.ps1): no Az modules, no
# PowerShell Gallery. Log Analytics and Blob are reached over private endpoints;
# the inventory (Azure Resource Graph) is the only call that leaves the VNet,
# towards management.azure.com through the NSG-restricted NAT gateway.
#
# Query semantics mirror the workbook exactly:
#   - AzureActivity / CategoryValue == 'ResourceHealth'
#   - exclude userinitiated reason/cause and deallocate/power-off ops
#   - downtime = segmented seconds where currentHealthStatus != 'Available'
#   - inventory + 100% backfill of healthy resources from Azure Resource Graph
#
# App settings consumed (set in main.bicep):
#   WORKSPACE_ID          - Log Analytics customerId (GUID)
#   STORAGE_BLOB_ENDPOINT - Blob endpoint of the storage account
#   REPORTS_CONTAINER     - private blob container for reports (default 'reports')
#   MATRIX_MONTHS         - default 12
# =============================================================================
param($Timer)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../Shared/SlaCommon.ps1"

$blobEndpoint = $env:STORAGE_BLOB_ENDPOINT
$container    = if ($env:REPORTS_CONTAINER) { $env:REPORTS_CONTAINER } else { 'reports' }
$matrixMonths = if ($env:MATRIX_MONTHS) { [int]$env:MATRIX_MONTHS } else { 12 }
if (-not $env:WORKSPACE_ID -or -not $blobEndpoint) { throw 'WORKSPACE_ID and STORAGE_BLOB_ENDPOINT app settings are required.' }

function Publish-Blob([string]$Name, [string]$Content, [string]$ContentType) {
    $uri = '{0}/{1}/{2}' -f $blobEndpoint.TrimEnd('/'), $container, $Name
    $headers = @{ 'x-ms-version' = '2023-11-03'; 'x-ms-blob-type' = 'BlockBlob'; 'x-ms-blob-content-type' = $ContentType }
    Invoke-Rest -Method Put -Uri $uri -Resource 'https://storage.azure.com/' -ContentType $ContentType -Headers $headers `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($Content)) | Out-Null
}

function ConvertTo-HtmlText($Value) { [System.Net.WebUtility]::HtmlEncode([string]$Value) }

$now    = [datetime]::UtcNow
$report = $now.AddMonths(-1).ToString('yyyy-MM')
$reportStart = [datetime]::ParseExact("$report-01", 'yyyy-MM-dd', $null)
$reportEnd   = $reportStart.AddMonths(1)
$matrixStart = $reportStart.AddMonths(-($matrixMonths - 1))
$matrixEndEx = $reportEnd

Write-Host "Reporting month: $report"

# -----------------------------------------------------------------------------
# 0. Service catalog (Shared/SlaCommon.ps1; identical to inject-queries.ps1 / the workbook)
# -----------------------------------------------------------------------------
$services = $script:ServiceCatalog
$expected = @{}
foreach ($s in $services) { $expected[$s.RType] = @{ sla = $s.sla; basis = $s.basis } }
$tokenArray = '[' + (($services | ForEach-Object { "'" + $_.token + "'" }) -join ',') + ']'

# -----------------------------------------------------------------------------
# 1. Inventory from Azure Resource Graph (real region + RType, 100% backfill base)
# -----------------------------------------------------------------------------
try {
    $inventory = @(Get-ArgInventory)
} catch {
    throw "Inventory through Azure Resource Graph failed: $($_.Exception.Message). The Function identity needs Reader on the subscriptions and outbound HTTPS to management.azure.com (NAT gateway / firewall egress, see README)."
}
$inventoryNote = ''
if ($inventory.Count -eq 0) {
    $inventoryNote = 'No resources found: grant the Function identity Reader on the subscriptions to report.'
    Write-Warning $inventoryNote
}
Write-Host "Inventory resources (all selected types): $($inventory.Count) via Azure Resource Graph"

# -----------------------------------------------------------------------------
# 2. Downtime seconds per resource per month from Log Analytics
#    (segmented availability, same filters as the workbook)
# -----------------------------------------------------------------------------
$kqlDown = @"
let MatrixStart = datetime('$($matrixStart.ToString('o'))');
let MatrixEndExclusive = datetime('$($matrixEndEx.ToString('o'))');
let n = $matrixMonths;
let SelectedTokens = dynamic($tokenArray);
let evtraw = AzureActivity
| where TimeGenerated between (MatrixStart .. MatrixEndExclusive)
| where CategoryValue == 'ResourceHealth'
| extend ResourceId = tolower(coalesce(_ResourceId, ResourceId))
| where ResourceId has_any (SelectedTokens)
| extend Props = tostring(Properties), OpName = tolower(tostring(OperationNameValue))
| extend ReasonType = tolower(tostring(extractjson('`$.reasonType', Props))), Cause = tolower(tostring(extractjson('`$.cause', Props)))
| where ReasonType != 'userinitiated' and Cause != 'userinitiated'
| where not(OpName has 'deallocate' or OpName has 'power off' or OpName has 'poweroff')
| extend AvailState = tostring(extractjson('`$.currentHealthStatus', Props)), OccuredTime = coalesce(todatetime(extractjson('`$.eventTimestamp', Props)), todatetime(extractjson('`$.occuredTime', Props)), TimeGenerated)
| project ResourceId, OccuredTime, AvailState
| order by ResourceId asc, OccuredTime asc;
evtraw
| extend NextTime = coalesce(next(OccuredTime), MatrixEndExclusive)
| mv-expand m = range(0, n - 1) to typeof(int)
| extend WindowStart = startofmonth(datetime_add('month', m, MatrixStart)), WindowEnd = startofmonth(datetime_add('month', m + 1, MatrixStart))
| extend SegStart = iff(OccuredTime < WindowStart, WindowStart, OccuredTime), SegEnd = iff(NextTime > WindowEnd, WindowEnd, NextTime)
| where SegEnd > SegStart
| extend IsDown = AvailState != 'Available', Month = format_datetime(WindowStart, 'yyyy-MM')
| summarize DownSec = sumif(datetime_diff('second', SegEnd, SegStart), IsDown) by ResourceId, Month
"@

$downRaw = @(Invoke-LaQuery $kqlDown)
$downMap = @{}
foreach ($d in $downRaw) { $downMap["$($d.ResourceId)|$($d.Month)"] = [double]$d.DownSec }

# -----------------------------------------------------------------------------
# 3. Platform event counts per resource per month (ResourceHealth events)
# -----------------------------------------------------------------------------
$kqlEvents = @"
let MatrixStart = datetime('$($matrixStart.ToString('o'))');
let MatrixEndExclusive = datetime('$($matrixEndEx.ToString('o'))');
let SelectedTokens = dynamic($tokenArray);
AzureActivity
| where TimeGenerated between (MatrixStart .. MatrixEndExclusive)
| where CategoryValue == 'ResourceHealth'
| extend ResourceId = tolower(coalesce(_ResourceId, ResourceId))
| where ResourceId has_any (SelectedTokens)
| extend Props = tostring(Properties), OpName = tolower(tostring(OperationNameValue))
| extend ReasonType = tolower(tostring(extractjson('`$.reasonType', Props))), Cause = tolower(tostring(extractjson('`$.cause', Props)))
| where ReasonType != 'userinitiated' and Cause != 'userinitiated'
| where not(OpName has 'deallocate' or OpName has 'power off' or OpName has 'poweroff')
| extend OccuredTime = coalesce(todatetime(extractjson('`$.eventTimestamp', Props)), todatetime(extractjson('`$.occuredTime', Props)), TimeGenerated)
| extend Month = format_datetime(startofmonth(OccuredTime), 'yyyy-MM')
| summarize PlatformEvents = count() by ResourceId, Month
"@

$evtRaw = @(Invoke-LaQuery $kqlEvents)
$evtMap = @{}
foreach ($e in $evtRaw) { $evtMap["$($e.ResourceId)|$($e.Month)"] = [int]$e.PlatformEvents }

# -----------------------------------------------------------------------------
# 4. Per-resource table (reporting month) with 100% backfill from inventory
#    Columns match the workbook: RType, ExpectedSLA, SlaBasis, PlatformEvents
# -----------------------------------------------------------------------------
$monthSecOf = { param($mo) $s = [datetime]::ParseExact("$mo-01", 'yyyy-MM-dd', $null); ($s.AddMonths(1) - $s).TotalSeconds }
$reportSec  = & $monthSecOf $report

$perRes = foreach ($inv in $inventory) {
    $down = [double]0
    $k = "$($inv.ResourceId)|$report"
    if ($downMap.ContainsKey($k)) { $down = [math]::Min($downMap[$k], $reportSec) }
    $events = if ($evtMap.ContainsKey($k)) { $evtMap[$k] } else { 0 }
    $exp = $expected[$inv.RType]
    $slaVal = [math]::Round((($reportSec - $down) / $reportSec) * 100, 4)
    [pscustomobject]@{
        ResourceId         = $inv.ResourceId
        RType              = $inv.RType
        Region             = $inv.Region
        ActualSLA          = "$slaVal%"
        ExpectedSLA        = if ($exp) { $exp.sla } else { 'Unknown' }
        SlaBasis           = if ($exp) { $exp.basis } else { 'Not mapped' }
        UnavailableMinutes = [math]::Round($down / 60.0, 2)
        PlatformEvents     = $events
        _SlaValue          = $slaVal
    }
}

# -----------------------------------------------------------------------------
# 5. Region x Month matrix with 100% backfill (weighted by inventory)
# -----------------------------------------------------------------------------
$monthsList = 0..($matrixMonths - 1) | ForEach-Object { $matrixStart.AddMonths($_).ToString('yyyy-MM') }
$regions    = $inventory | Select-Object -ExpandProperty Region -Unique | Sort-Object
$matrix = foreach ($rg in $regions) {
    $resInRegion = @($inventory | Where-Object { $_.Region -eq $rg })
    $row = [ordered]@{ Region = $rg }
    foreach ($mo in $monthsList) {
        $monthSec = & $monthSecOf $mo
        $totalSec = $resInRegion.Count * $monthSec
        $downSum  = [double]0
        foreach ($r in $resInRegion) {
            $k = "$($r.ResourceId)|$mo"
            if ($downMap.ContainsKey($k)) { $downSum += [math]::Min($downMap[$k], $monthSec) }
        }
        $row[$mo] = if ($totalSec -gt 0) { [math]::Round((($totalSec - $downSum) / $totalSec) * 100, 4) } else { $null }
    }
    [pscustomobject]$row
}

# -----------------------------------------------------------------------------
# 6. Render HTML
# -----------------------------------------------------------------------------
$style = '<style>body{font-family:Segoe UI,Arial;margin:24px}table{border-collapse:collapse;width:100%;font-size:13px;margin:8px 0}th,td{border:1px solid #ddd;padding:6px 8px}th{background:#0a3a6b;color:#fff;text-align:center}.matrix td{text-align:center}.matrix td.region{text-align:left;font-weight:600;background:#fafafa}.matrix td.warn{background:#fff4ce}.matrix td.bad{background:#fde7e9}</style>'

$mHead = '<tr><th>Region</th>' + (($monthsList | ForEach-Object { "<th>$([datetime]::ParseExact("$_-01",'yyyy-MM-dd',$null).ToString('MMM-yy'))</th>" }) -join '') + '</tr>'
$mBody = ($matrix | ForEach-Object {
    $r = $_; $cells = foreach ($mo in $monthsList) {
        $v = $r.$mo
        if ($null -eq $v) { "<td>n/a</td>" }
        else {
            $cls = if ($v -lt 99.9) { 'bad' } elseif ($v -lt 99.95) { 'warn' } else { '' }
            "<td class='$cls'>$([string]::Format('{0:F4}%', $v))</td>"
        }
    }
    "<tr><td class='region'>$(ConvertTo-HtmlText $r.Region)</td>$(-join $cells)</tr>"
}) -join "`n"

$rRows = ($perRes | Sort-Object _SlaValue, @{Expression='UnavailableMinutes';Descending=$true} | ForEach-Object {
    $cells = $_.ResourceId, $_.RType, $_.Region, $_.ActualSLA, $_.ExpectedSLA, $_.SlaBasis, $_.UnavailableMinutes, $_.PlatformEvents | ForEach-Object { "<td>$(ConvertTo-HtmlText $_)</td>" }
    "<tr>$(-join $cells)</tr>"
}) -join "`n"

$noticeHtml = if ($inventoryNote) { "<p style='background:#fff4ce;padding:8px'><b>Note:</b> $(ConvertTo-HtmlText $inventoryNote)</p>" } else { '' }

$html = @"
<!doctype html><html><head><meta charset='utf-8'><title>Azure Availability SLA $report</title>$style</head><body>
<h1>Azure Availability SLA</h1>
<div>Reporting month: <b>$report</b> &nbsp;|&nbsp; Generated: $($now.ToString('u')) &nbsp;|&nbsp; Resources: $($inventory.Count)</div>
$noticeHtml
<h2>Cumulative Uptime per Region per Month (last $matrixMonths months)</h2>
<table class='matrix'><thead>$mHead</thead><tbody>$mBody</tbody></table>
<h2>Per-resource platform SLA ($report)</h2>
<table><thead><tr><th>ResourceId</th><th>RType</th><th>Region</th><th>ActualSLA</th><th>ExpectedSLA</th><th>SlaBasis</th><th>Unavailable (min)</th><th>PlatformEvents</th></tr></thead><tbody>$rRows</tbody></table>
</body></html>
"@

# -----------------------------------------------------------------------------
# 7. Upload to the PRIVATE reports container (Entra/RBAC)
# -----------------------------------------------------------------------------
$perResCsv = (@($perRes | Select-Object ResourceId, RType, Region, ActualSLA, ExpectedSLA, SlaBasis, UnavailableMinutes, PlatformEvents) | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
$matrixCsv = (@($matrix) | ConvertTo-Csv -NoTypeInformation) -join "`r`n"

Publish-Blob "AzSla_$report.html" $html 'text/html'
Publish-Blob "AzSla_$report.csv" $perResCsv 'text/csv'
Publish-Blob "AzSla_RegionMatrix_$report.csv" $matrixCsv 'text/csv'
Publish-Blob 'index.html' $html 'text/html'

Write-Host "Report published to private container '$container' (index.html). Read it via the Azure Portal Storage browser or Storage Explorer with Storage Blob Data Reader."
