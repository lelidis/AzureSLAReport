# =============================================================================
# GenerateSlaReport - Timer-triggered Function
#
# Runs on the 1st of each month at 06:00 UTC. Queries the central Log Analytics
# workspace for ResourceHealth events of the previous month, builds:
#   - Per-resource availability (CSV + HTML)
#   - Region x Month (12-month) availability matrix (CSV + HTML)
# Uploads HTML/CSV to the Storage account's `$web` static website container.
#
# App settings consumed (set in main.bicep):
#   WORKSPACE_ID      - Log Analytics customerId (GUID)
#   STORAGE_ACCOUNT   - Storage account name
#   STATIC_CONTAINER  - usually `$web`
#   MATRIX_MONTHS     - default 12
# =============================================================================
param($Timer)

$ErrorActionPreference = 'Stop'
$workspaceId    = $env:WORKSPACE_ID
$storageAccount = $env:STORAGE_ACCOUNT
$container      = if ($env:STATIC_CONTAINER) { $env:STATIC_CONTAINER } else { '$web' }
$matrixMonths   = if ($env:MATRIX_MONTHS) { [int]$env:MATRIX_MONTHS } else { 12 }

$now    = [datetime]::UtcNow
$report = $now.AddMonths(-1).ToString('yyyy-MM')
$reportStart = [datetime]::ParseExact("$report-01", 'yyyy-MM-dd', $null)
$reportEnd   = $reportStart.AddMonths(1)
$matrixStart = $reportStart.AddMonths(-($matrixMonths - 1))
$matrixEndEx = $reportEnd

Write-Host "Reporting month: $report"

# -----------------------------------------------------------------------------
# 1. Inventory from Azure Resource Graph (real region + full 100% backfill base)
# -----------------------------------------------------------------------------
$computeTypes = "'microsoft.compute/virtualmachines','microsoft.compute/virtualmachinescalesets'"
$invQuery = "resources | where type in~ ($computeTypes) | project ResourceId = tolower(id), Region = tostring(location)"
$inventory = [System.Collections.Generic.List[object]]::new()
$skipToken = $null
do {
    if ($skipToken) { $page = Search-AzGraph -Query $invQuery -First 1000 -SkipToken $skipToken }
    else            { $page = Search-AzGraph -Query $invQuery -First 1000 }
    foreach ($r in $page) { $inventory.Add($r) }
    $skipToken = $page.SkipToken
} while ($skipToken)
Write-Host "Inventory compute resources: $($inventory.Count)"

# -----------------------------------------------------------------------------
# 2. Downtime seconds per resource per month from Log Analytics
# -----------------------------------------------------------------------------
$kqlDown = @"
let MatrixStart = datetime('$($matrixStart.ToString('o'))');
let MatrixEndExclusive = datetime('$($matrixEndEx.ToString('o'))');
let n = $matrixMonths;
let evtraw = AzureActivity
| where TimeGenerated between (MatrixStart .. MatrixEndExclusive)
| where CategoryValue == 'ResourceHealth'
| extend ResourceId = tolower(coalesce(_ResourceId, ResourceId))
| where ResourceId has '/providers/microsoft.compute/virtualmachines/' or ResourceId has '/providers/microsoft.compute/virtualmachinescalesets/'
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

$downRaw = (Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $kqlDown).Results
$downMap = @{}
foreach ($d in $downRaw) { $downMap["$($d.ResourceId)|$($d.Month)"] = [double]$d.DownSec }

# -----------------------------------------------------------------------------
# 3. Per-resource table (reporting month) with 100% backfill from inventory
# -----------------------------------------------------------------------------
$monthSecOf = { param($mo) $s = [datetime]::ParseExact("$mo-01", 'yyyy-MM-dd', $null); ($s.AddMonths(1) - $s).TotalSeconds }
$reportSec  = & $monthSecOf $report

$perRes = foreach ($inv in $inventory) {
    $down = [double]0
    $k = "$($inv.ResourceId)|$report"
    if ($downMap.ContainsKey($k)) { $down = [math]::Min($downMap[$k], $reportSec) }
    [pscustomobject]@{
        ResourceId         = $inv.ResourceId
        Region             = $inv.Region
        AvailabilityPct    = [math]::Round((($reportSec - $down) / $reportSec) * 100, 4)
        UnavailableMinutes = [math]::Round($down / 60.0, 2)
    }
}

# -----------------------------------------------------------------------------
# 4. Region x Month matrix with 100% backfill (weighted by inventory)
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
# 5. Render HTML
# -----------------------------------------------------------------------------
$style = '<style>body{font-family:Segoe UI,Arial;margin:24px}table{border-collapse:collapse;width:100%;font-size:13px;margin:8px 0}th,td{border:1px solid #ddd;padding:6px 8px}th{background:#0a3a6b;color:#fff;text-align:center}.matrix td{text-align:center}.matrix td.region{text-align:left;font-weight:600;background:#fafafa}.matrix td.warn{background:#fff4ce}.matrix td.bad{background:#fde7e9}</style>'

$mHead = '<tr><th>Region</th>' + (($monthsList | ForEach-Object { "<th>$([datetime]::ParseExact("$_-01",'yyyy-MM-dd',$null).ToString('MMM-yy'))<br/>COMPUTE</th>" }) -join '') + '</tr>'
$mBody = ($matrix | ForEach-Object {
    $r = $_; $cells = foreach ($mo in $monthsList) {
        $v = $r.$mo
        if ($null -eq $v) { "<td>n/a</td>" }
        else {
            $cls = if ($v -lt 99.9) { 'bad' } elseif ($v -lt 99.95) { 'warn' } else { '' }
            "<td class='$cls'>$([string]::Format('{0:F4}%', $v))</td>"
        }
    }
    "<tr><td class='region'>$($r.Region)</td>$(-join $cells)</tr>"
}) -join "`n"

$rRows = ($perRes | Sort-Object AvailabilityPct | ForEach-Object {
    "<tr><td>$($_.ResourceId)</td><td>$($_.Region)</td><td>$($_.AvailabilityPct)%</td><td>$($_.UnavailableMinutes)</td></tr>"
}) -join "`n"

$html = @"
<!doctype html><html><head><meta charset='utf-8'><title>Compute SLA $report</title>$style</head><body>
<h1>Azure Compute Availability SLA</h1>
<div>Reporting month: <b>$report</b> &nbsp;|&nbsp; Generated: $($now.ToString('u'))</div>
<h2>Cumulative Compute Uptime per Region per Month (last $matrixMonths months)</h2>
<table class='matrix'><thead>$mHead</thead><tbody>$mBody</tbody></table>
<h2>Resources ($report)</h2>
<table><thead><tr><th>ResourceId</th><th>Region</th><th>Availability</th><th>Unavailable (min)</th></tr></thead><tbody>$rRows</tbody></table>
</body></html>
"@

# -----------------------------------------------------------------------------
# 6. Upload to $web
# -----------------------------------------------------------------------------
$tmp = $env:TEMP
$htmlFile  = Join-Path $tmp "AzComputeSla_$report.html"
$csvFile   = Join-Path $tmp "AzComputeSla_$report.csv"
$matrixCsv = Join-Path $tmp "AzComputeSla_RegionMatrix_$report.csv"
$indexFile = Join-Path $tmp 'index.html'

$html       | Out-File $htmlFile  -Encoding UTF8
$perRes     | Export-Csv $csvFile   -NoTypeInformation -Encoding UTF8
$matrix     | Export-Csv $matrixCsv -NoTypeInformation -Encoding UTF8
$html       | Out-File $indexFile -Encoding UTF8

$ctx = New-AzStorageContext -StorageAccountName $storageAccount -UseConnectedAccount
foreach ($f in @($htmlFile, $csvFile, $matrixCsv, $indexFile)) {
    $ct = if ($f.EndsWith('.html')) { 'text/html' } else { 'text/csv' }
    Set-AzStorageBlobContent -Context $ctx -Container $container -File $f -Blob (Split-Path $f -Leaf) `
        -Properties @{ContentType=$ct} -Force | Out-Null
}

Write-Host "Report published to https://$storageAccount.z6.web.core.windows.net/"
