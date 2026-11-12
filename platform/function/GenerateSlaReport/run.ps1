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
# REST with the managed identity: no Az modules, no PowerShell Gallery, no ARM
# call (default inventory source), so the Function needs no internet egress.
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
#   INVENTORY_SOURCE      - 'loganalytics' (default, arg() in the workspace) or 'arm'
# =============================================================================
param($Timer)

$ErrorActionPreference = 'Stop'
$workspaceId     = $env:WORKSPACE_ID
$blobEndpoint    = $env:STORAGE_BLOB_ENDPOINT
$container       = if ($env:REPORTS_CONTAINER) { $env:REPORTS_CONTAINER } else { 'reports' }
$matrixMonths    = if ($env:MATRIX_MONTHS) { [int]$env:MATRIX_MONTHS } else { 12 }
$inventorySource = if ($env:INVENTORY_SOURCE) { $env:INVENTORY_SOURCE } else { 'loganalytics' }
if (-not $workspaceId -or -not $blobEndpoint) { throw 'WORKSPACE_ID and STORAGE_BLOB_ENDPOINT app settings are required.' }

$script:tokens = @{}

# Managed identity token; the az CLI branch exists only for local testing.
function Get-AccessToken([string]$Resource) {
    $cached = $script:tokens[$Resource]
    if ($cached -and $cached.Expires -gt [datetime]::UtcNow.AddMinutes(5)) { return $cached.Value }
    if ($env:IDENTITY_ENDPOINT) {
        $uri = '{0}?resource={1}&api-version=2019-08-01' -f $env:IDENTITY_ENDPOINT, [uri]::EscapeDataString($Resource)
        $r = Invoke-RestMethod -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }
        $token = @{ Value = $r.access_token; Expires = [datetimeoffset]::FromUnixTimeSeconds([long]$r.expires_on).UtcDateTime }
    } else {
        $token = @{ Value = (az account get-access-token --resource $Resource --query accessToken -o tsv); Expires = [datetime]::UtcNow.AddMinutes(30) }
    }
    $script:tokens[$Resource] = $token
    return $token.Value
}

# Retries throttling and transient failures; anything else fails the run.
function Invoke-Rest {
    param([string]$Method, [string]$Uri, [string]$Resource, $Body, [hashtable]$Headers = @{}, [string]$ContentType = 'application/json')
    $h = @{ Authorization = 'Bearer ' + (Get-AccessToken $Resource) } + $Headers
    for ($try = 1; ; $try++) {
        try {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $h -ContentType $ContentType -Body $Body
        } catch {
            $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($try -ge 4 -or $code -notin 0, 429, 500, 502, 503, 504) {
                throw "$Method $Uri failed (HTTP $code): $($_.ErrorDetails.Message) $($_.Exception.Message)"
            }
            Start-Sleep -Seconds (5 * $try)
        }
    }
}

# 'Prefer: wait' lifts the default 3-minute server-side query timeout.
function Invoke-LaQuery([string]$Kql) {
    $body = @{ query = $Kql } | ConvertTo-Json -Compress
    $r = Invoke-Rest -Method Post -Uri "https://api.loganalytics.azure.com/v1/workspaces/$workspaceId/query" `
        -Resource 'https://api.loganalytics.io' -Body $body -Headers @{ Prefer = 'wait=600' }
    if ($r.error) { throw "Log Analytics query error: $($r.error.message)" }
    $cols = @($r.tables[0].columns | ForEach-Object { $_.name })
    foreach ($row in $r.tables[0].rows) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $row[$i] }
        [pscustomobject]$o
    }
}

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
# 0. Service catalog (identical to inject-queries.ps1 / the workbook)
#    RType, name, token (ResourceHealth path), arg (ARG type), sla, basis
# -----------------------------------------------------------------------------
$services = @(
  @{ RType='VM';              name='Virtual Machines';            token='/providers/microsoft.compute/virtualmachines/';                 arg='microsoft.compute/virtualmachines';                 sla='99.9% / 99.95% / 99.99%'; basis='Single VM Premium SSD / Av Set / Av Zones' },
  @{ RType='VMSS';            name='VM Scale Sets';               token='/providers/microsoft.compute/virtualmachinescalesets/';         arg='microsoft.compute/virtualmachinescalesets';         sla='99.95% / 99.99%';         basis='Av Set or multi-zone' },
  @{ RType='AppService';      name='App Service';                 token='/providers/microsoft.web/sites/';                               arg='microsoft.web/sites';                               sla='99.95%';                  basis='Standard or higher tier' },
  @{ RType='StaticWebApp';    name='Static Web Apps';             token='/providers/microsoft.web/staticsites/';                         arg='microsoft.web/staticsites';                         sla='99.95%';                  basis='Standard' },
  @{ RType='AKS';             name='AKS';                         token='/providers/microsoft.containerservice/managedclusters/';        arg='microsoft.containerservice/managedclusters';        sla='99.95%';                  basis='Uptime SLA enabled' },
  @{ RType='ContainerApp';    name='Container Apps';              token='/providers/microsoft.app/containerapps/';                       arg='microsoft.app/containerapps';                       sla='99.95%';                  basis='Standard' },
  @{ RType='ACI';             name='Container Instances';         token='/providers/microsoft.containerinstance/containergroups/';       arg='microsoft.containerinstance/containergroups';       sla='99.9%';                   basis='Standard' },
  @{ RType='ServiceFabric';   name='Service Fabric';              token='/providers/microsoft.servicefabric/clusters/';                  arg='microsoft.servicefabric/clusters';                  sla='99.95%';                  basis='Silver/Gold durability' },
  @{ RType='Batch';           name='Batch';                       token='/providers/microsoft.batch/batchaccounts/';                     arg='microsoft.batch/batchaccounts';                     sla='99.9%';                   basis='Standard' },
  @{ RType='SQL';             name='SQL Database';                token='/providers/microsoft.sql/servers/';                             arg='microsoft.sql/servers';                             sla='99.99%';                  basis='Business Critical / GP HA' },
  @{ RType='SQLMI';           name='SQL Managed Instance';        token='/providers/microsoft.sql/managedinstances/';                    arg='microsoft.sql/managedinstances';                    sla='99.99%';                  basis='Business Critical' },
  @{ RType='Cosmos';          name='Cosmos DB';                   token='/providers/microsoft.documentdb/databaseaccounts/';             arg='microsoft.documentdb/databaseaccounts';             sla='99.99% / 99.999%';        basis='Single / multi-region writes' },
  @{ RType='Postgres';        name='PostgreSQL Flexible';         token='/providers/microsoft.dbforpostgresql/flexibleservers/';         arg='microsoft.dbforpostgresql/flexibleservers';         sla='99.99%';                  basis='HA enabled' },
  @{ RType='MySQL';           name='MySQL Flexible';              token='/providers/microsoft.dbformysql/flexibleservers/';              arg='microsoft.dbformysql/flexibleservers';              sla='99.99%';                  basis='HA enabled' },
  @{ RType='MariaDB';         name='MariaDB';                     token='/providers/microsoft.dbformariadb/servers/';                    arg='microsoft.dbformariadb/servers';                    sla='99.99%';                  basis='Standard' },
  @{ RType='Synapse';         name='Synapse Analytics';           token='/providers/microsoft.synapse/workspaces/';                      arg='microsoft.synapse/workspaces';                      sla='99.9%';                   basis='Standard' },
  @{ RType='DataExplorer';    name='Data Explorer';               token='/providers/microsoft.kusto/clusters/';                          arg='microsoft.kusto/clusters';                          sla='99.9%';                   basis='Standard' },
  @{ RType='DataFactory';     name='Data Factory';                token='/providers/microsoft.datafactory/factories/';                   arg='microsoft.datafactory/factories';                   sla='99.9%';                   basis='Standard' },
  @{ RType='Databricks';      name='Databricks';                  token='/providers/microsoft.databricks/workspaces/';                   arg='microsoft.databricks/workspaces';                   sla='99.95%';                  basis='Premium' },
  @{ RType='Storage';         name='Storage Account';             token='/providers/microsoft.storage/storageaccounts/';                 arg='microsoft.storage/storageaccounts';                 sla='99.9% / 99.99%';          basis='LRS write / GRS read' },
  @{ RType='KeyVault';        name='Key Vault';                   token='/providers/microsoft.keyvault/vaults/';                         arg='microsoft.keyvault/vaults';                         sla='99.99%';                  basis='Standard' },
  @{ RType='Redis';           name='Cache for Redis';             token='/providers/microsoft.cache/redis/';                             arg='microsoft.cache/redis';                             sla='99.9%';                   basis='Standard / Premium' },
  @{ RType='ServiceBus';      name='Service Bus';                 token='/providers/microsoft.servicebus/namespaces/';                   arg='microsoft.servicebus/namespaces';                   sla='99.9% / 99.95%';          basis='Std / Premium' },
  @{ RType='EventHub';        name='Event Hubs';                  token='/providers/microsoft.eventhub/namespaces/';                     arg='microsoft.eventhub/namespaces';                     sla='99.95%';                  basis='Standard' },
  @{ RType='EventGridTopic';  name='Event Grid Topic';            token='/providers/microsoft.eventgrid/topics/';                        arg='microsoft.eventgrid/topics';                        sla='99.99%';                  basis='Standard' },
  @{ RType='EventGridDomain'; name='Event Grid Domain';           token='/providers/microsoft.eventgrid/domains/';                       arg='microsoft.eventgrid/domains';                       sla='99.99%';                  basis='Standard' },
  @{ RType='APIManagement';   name='API Management';              token='/providers/microsoft.apimanagement/service/';                   arg='microsoft.apimanagement/service';                   sla='99.95% / 99.99%';         basis='Std / Premium multi-region' },
  @{ RType='LogicApps';       name='Logic Apps (Consumption)';    token='/providers/microsoft.logic/workflows/';                         arg='microsoft.logic/workflows';                         sla='99.9%';                   basis='Standard' },
  @{ RType='NotificationHub'; name='Notification Hubs';           token='/providers/microsoft.notificationhubs/namespaces/';             arg='microsoft.notificationhubs/namespaces';             sla='99.9%';                   basis='Standard' },
  @{ RType='Relay';           name='Relay';                       token='/providers/microsoft.relay/namespaces/';                        arg='microsoft.relay/namespaces';                        sla='99.9%';                   basis='Standard' },
  @{ RType='SignalR';         name='SignalR';                     token='/providers/microsoft.signalrservice/signalr/';                  arg='microsoft.signalrservice/signalr';                  sla='99.9%';                   basis='Standard' },
  @{ RType='WebPubSub';       name='Web PubSub';                  token='/providers/microsoft.signalrservice/webpubsub/';                arg='microsoft.signalrservice/webpubsub';                sla='99.9%';                   basis='Standard' },
  @{ RType='Cognitive';       name='Cognitive Services / OpenAI'; token='/providers/microsoft.cognitiveservices/accounts/';              arg='microsoft.cognitiveservices/accounts';              sla='99.9%';                   basis='Standard' },
  @{ RType='AISearch';        name='AI Search';                   token='/providers/microsoft.search/searchservices/';                   arg='microsoft.search/searchservices';                   sla='99.9%';                   basis='Standard 2+ replicas' },
  @{ RType='AppGw';           name='Application Gateway';         token='/providers/microsoft.network/applicationgateways/';             arg='microsoft.network/applicationgateways';             sla='99.95%';                  basis='Standard_v2' },
  @{ RType='LoadBalancer';    name='Load Balancer';               token='/providers/microsoft.network/loadbalancers/';                   arg='microsoft.network/loadbalancers';                   sla='99.99%';                  basis='Standard SKU' },
  @{ RType='PublicIP';        name='Public IP';                   token='/providers/microsoft.network/publicipaddresses/';               arg='microsoft.network/publicipaddresses';               sla='99.99%';                  basis='Standard SKU' },
  @{ RType='NatGateway';      name='NAT Gateway';                 token='/providers/microsoft.network/natgateways/';                     arg='microsoft.network/natgateways';                     sla='99.99%';                  basis='Standard' },
  @{ RType='Firewall';        name='Firewall';                    token='/providers/microsoft.network/azurefirewalls/';                  arg='microsoft.network/azurefirewalls';                  sla='99.95% / 99.99%';         basis='Std / AZ' },
  @{ RType='Bastion';         name='Bastion';                     token='/providers/microsoft.network/bastionhosts/';                    arg='microsoft.network/bastionhosts';                    sla='99.95%';                  basis='Standard' },
  @{ RType='PrivateEndpoint'; name='Private Endpoint';            token='/providers/microsoft.network/privateendpoints/';                arg='microsoft.network/privateendpoints';                sla='99.9%';                   basis='Standard' },
  @{ RType='DnsZone';         name='DNS Zone';                    token='/providers/microsoft.network/dnszones/';                        arg='microsoft.network/dnszones';                        sla='100%';                    basis='Public DNS' },
  @{ RType='PrivateDnsZone';  name='Private DNS Zone';            token='/providers/microsoft.network/privatednszones/';                 arg='microsoft.network/privatednszones';                 sla='100%';                    basis='Private DNS' },
  @{ RType='VNetGateway';     name='VPN / ER Gateway';            token='/providers/microsoft.network/virtualnetworkgateways/';          arg='microsoft.network/virtualnetworkgateways';          sla='99.95%';                  basis='VpnGw / ErGw' },
  @{ RType='ExpressRoute';    name='ExpressRoute Circuit';        token='/providers/microsoft.network/expressroutecircuits/';            arg='microsoft.network/expressroutecircuits';            sla='99.95%';                  basis='Standard' },
  @{ RType='FrontDoor';       name='Front Door (Classic)';        token='/providers/microsoft.network/frontdoors/';                      arg='microsoft.network/frontdoors';                      sla='99.99%';                  basis='Classic' },
  @{ RType='CDN';             name='CDN / Front Door Std/Premium';token='/providers/microsoft.cdn/profiles/';                            arg='microsoft.cdn/profiles';                            sla='99.99%';                  basis='Std / Premium' },
  @{ RType='TrafficManager';  name='Traffic Manager';             token='/providers/microsoft.network/trafficmanagerprofiles/';          arg='microsoft.network/trafficmanagerprofiles';          sla='99.99%';                  basis='Standard' },
  @{ RType='ManagedIdentity'; name='Managed Identity';            token='/providers/microsoft.managedidentity/userassignedidentities/';  arg='microsoft.managedidentity/userassignedidentities';  sla='99.9%';                   basis='Standard' }
)

# Lookup maps derived from the catalog
$argToRType = @{}
$expected   = @{}
foreach ($s in $services) {
    $argToRType[$s.arg] = $s.RType
    $expected[$s.RType] = @{ sla = $s.sla; basis = $s.basis }
}
$argList    = ($services | ForEach-Object { "'" + $_.arg + "'" }) -join ','
$tokenArray = '[' + (($services | ForEach-Object { "'" + $_.token + "'" }) -join ',') + ']'

# -----------------------------------------------------------------------------
# 1. Inventory from Azure Resource Graph (real region + RType, 100% backfill base)
#    loganalytics: arg('') runs inside the private workspace, no ARM call.
#    arm:          ARG REST on management.azure.com (needs ARM reachability).
# -----------------------------------------------------------------------------
$invFilter = "tolower(type) in ($argList)"
$invProject = 'project ResourceId = tolower(id), Region = tostring(location), ArgType = tolower(type)'
$inventory = [System.Collections.Generic.List[object]]::new()

function Add-InventoryRow($ResourceId, $Region, $ArgType) {
    $rt = $argToRType[$ArgType]
    $inventory.Add([pscustomobject]@{ ResourceId = $ResourceId; Region = $Region; RType = if ($rt) { $rt } else { 'Other' } })
}

if ($inventorySource -eq 'arm') {
    $skipToken = $null
    do {
        $options = @{ '$top' = 1000 }
        if ($skipToken) { $options['$skipToken'] = $skipToken }
        $body = @{ query = "resources | where $invFilter | $invProject"; options = $options } | ConvertTo-Json -Compress
        $page = Invoke-Rest -Method Post -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' `
            -Resource 'https://management.azure.com/' -Body $body
        foreach ($r in $page.data) { Add-InventoryRow $r.ResourceId $r.Region $r.ArgType }
        $skipToken = $page.'$skipToken'
    } while ($skipToken)
    $expectedCount = $inventory.Count
} else {
    try {
        # arg('') returns at most 1000 rows, so page with a keyset cursor (strcmp: KQL has no string '>').
        $cursor = ''
        for ($page = 0; $page -lt 500; $page++) {
            $escaped = $cursor.Replace('\', '\\').Replace("'", "\'")
            $rows = @(Invoke-LaQuery "arg('').resources | where $invFilter | $invProject | where strcmp(ResourceId, '$escaped') > 0 | order by ResourceId asc | take 1000")
            foreach ($r in $rows) { Add-InventoryRow $r.ResourceId $r.Region $r.ArgType }
            if ($rows.Count -lt 1000) { break }
            $cursor = $rows[-1].ResourceId
        }
        $expectedCount = [int]@(Invoke-LaQuery "arg('').resources | where $invFilter | summarize n = count()")[0].n
    } catch {
        throw "Inventory through arg() failed: $($_.Exception.Message). Check the Function identity has Reader on the subscriptions; if arg() is blocked for this private workspace, set INVENTORY_SOURCE=arm (needs ARM reachability)."
    }
}
$inventoryNote = ''
if ($inventory.Count -eq 0) {
    $inventoryNote = 'No resources found: grant the Function identity Reader on the subscriptions to report.'
} elseif ($inventory.Count -ne $expectedCount) {
    $inventoryNote = "Inventory incomplete: $($inventory.Count) of $expectedCount resources listed."
}
if ($inventoryNote) { Write-Warning $inventoryNote }
Write-Host "Inventory resources (all selected types): $($inventory.Count) via $inventorySource"

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
