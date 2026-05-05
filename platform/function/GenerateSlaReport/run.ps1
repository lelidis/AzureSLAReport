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
$wStart = [datetime]::ParseExact("$report-01", 'yyyy-MM-dd', $null)
$wEnd   = $wStart.AddMonths(1)

Write-Host "Reporting month: $report"

# -----------------------------------------------------------------------------
# 1. Query Log Analytics
# -----------------------------------------------------------------------------
$kqlPerResource = @"
let _start = datetime('$($wStart.ToString('o'))');
let _end   = datetime('$($wEnd.ToString('o'))');
let _wsec  = toreal(datetime_diff('second', _end, _start));
AzureActivity
| where TimeGenerated between (_start .. _end + 1h)
| where CategoryValue == 'ResourceHealth'
| where tolower(ResourceId) has '/providers/microsoft.compute/virtualmachines/'
    or tolower(ResourceId) has '/providers/microsoft.compute/virtualmachinescalesets/'
| extend p = todynamic(Properties)
| where tostring(p['reasonType']) != 'UserInitiated'
| extend ResourceId  = tolower(ResourceId),
            AvailState  = tostring(p['currentHealthStatus']),
            OccuredTime = coalesce(todatetime(p['eventTimestamp']), todatetime(p['occuredTime']), TimeGenerated),
            Region      = coalesce(tostring(p['resourceLocation']), tostring(p['location']), tostring(ResourceGroup), 'unknown')
| order by ResourceId asc, OccuredTime asc
| extend NextTimeRaw = next(OccuredTime)
| extend NextTime = coalesce(NextTimeRaw, _end)
| extend SegStart = iff(OccuredTime < _start, _start, OccuredTime),
         SegEnd   = iff(NextTime  > _end,   _end,   NextTime)
| where SegEnd > SegStart
| extend SegSec = datetime_diff('second', SegEnd, SegStart), IsDown = AvailState != 'Available'
| summarize DownSec = sumif(SegSec, IsDown), Region = any(Region) by ResourceId
| extend AvailabilityPct = round(((_wsec - DownSec) / _wsec) * 100, 4),
         UnavailableMinutes = round(DownSec / 60.0, 2)
| project ResourceId, Region, AvailabilityPct, UnavailableMinutes
"@

$kqlMatrix = @"
let n = $matrixMonths;
let MatrixEnd   = startofmonth(datetime('$($now.ToString('o'))')) + 1d;
let MatrixStart = startofmonth(datetime_add('month', -(n-1), MatrixEnd));
AzureActivity
| where TimeGenerated between (MatrixStart .. MatrixEnd)
| where CategoryValue == 'ResourceHealth'
| where tolower(ResourceId) has '/providers/microsoft.compute/virtualmachines/'
    or tolower(ResourceId) has '/providers/microsoft.compute/virtualmachinescalesets/'
| extend p = todynamic(Properties)
| where tostring(p['reasonType']) != 'UserInitiated'
| extend ResourceId  = tolower(ResourceId),
            AvailState  = tostring(p['currentHealthStatus']),
            OccuredTime = coalesce(todatetime(p['eventTimestamp']), todatetime(p['occuredTime']), TimeGenerated),
            Region      = coalesce(tostring(p['resourceLocation']), tostring(p['location']), tostring(ResourceGroup), 'unknown')
| order by ResourceId asc, OccuredTime asc
| extend NextTimeRaw = next(OccuredTime)
| extend NextTime = coalesce(NextTimeRaw, MatrixEnd)
| mv-expand m = range(0, n-1) to typeof(int)
| extend WStart = startofmonth(datetime_add('month', m - (n-1), MatrixEnd)),
         WEnd   = startofmonth(datetime_add('month', m - (n-2), MatrixEnd))
| extend SegStart = iff(OccuredTime < WStart, WStart, OccuredTime),
         SegEnd   = iff(NextTime  > WEnd,   WEnd,   NextTime)
| where SegEnd > SegStart and SegStart >= WStart
| extend SegSec = datetime_diff('second', SegEnd, SegStart), IsDown = AvailState != 'Available',
         WSec   = datetime_diff('second', WEnd, WStart),
         Month  = format_datetime(WStart, 'yyyy-MM')
| summarize DownSec = sumif(SegSec, IsDown), WindowSec = max(WSec) by Region, Month
| extend AvailabilityPct = round(((WindowSec - DownSec) / WindowSec) * 100, 4)
| project Region, Month, AvailabilityPct
"@

$perRes = (Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $kqlPerResource).Results
$matRaw = (Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $kqlMatrix).Results

# -----------------------------------------------------------------------------
# 2. Build pivot for matrix (Region x Month)
# -----------------------------------------------------------------------------
$months = ($matRaw | Select-Object -ExpandProperty Month -Unique | Sort-Object)
$matrix = $matRaw | Group-Object Region | ForEach-Object {
    $row = [ordered]@{ Region = $_.Name }
    foreach ($mo in $months) {
        $cell = $_.Group | Where-Object { $_.Month -eq $mo } | Select-Object -First 1
        $row[$mo] = if ($cell) { [double]$cell.AvailabilityPct } else { $null }
    }
    [pscustomobject]$row
}

# -----------------------------------------------------------------------------
# 3. Render HTML
# -----------------------------------------------------------------------------
$style = '<style>body{font-family:Segoe UI,Arial;margin:24px}table{border-collapse:collapse;width:100%;font-size:13px;margin:8px 0}th,td{border:1px solid #ddd;padding:6px 8px}th{background:#0a3a6b;color:#fff;text-align:center}.matrix td{text-align:center}.matrix td.region{text-align:left;font-weight:600;background:#fafafa}.matrix td.warn{background:#fff4ce}.matrix td.bad{background:#fde7e9}</style>'

$mHead = '<tr><th>Region</th>' + (($months | ForEach-Object { "<th>$([datetime]::ParseExact("$_-01",'yyyy-MM-dd',$null).ToString('MMM-yy'))<br/>COMPUTE</th>" }) -join '') + '</tr>'
$mBody = ($matrix | ForEach-Object {
    $r = $_; $cells = foreach ($mo in $months) {
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
# 4. Upload to $web
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
