$ErrorActionPreference = 'Stop'

# Service catalog: code, RType, DisplayName, RH path token, ARG type, ExpectedSLA, SlaBasis
$services = @(
  @{ code='vm';              RType='VM';              name='Virtual Machines';              token='/providers/microsoft.compute/virtualmachines/';                       arg='microsoft.compute/virtualmachines';                       sla='99.9% / 99.95% / 99.99%';     basis='Single VM Premium SSD / Av Set / Av Zones' },
  @{ code='vmss';            RType='VMSS';            name='VM Scale Sets';                  token='/providers/microsoft.compute/virtualmachinescalesets/';               arg='microsoft.compute/virtualmachinescalesets';               sla='99.95% / 99.99%';             basis='Av Set or multi-zone' },
  @{ code='appservice';      RType='AppService';      name='App Service';                    token='/providers/microsoft.web/sites/';                                     arg='microsoft.web/sites';                                     sla='99.95%';                      basis='Standard or higher tier' },
  @{ code='swa';             RType='StaticWebApp';    name='Static Web Apps';                token='/providers/microsoft.web/staticsites/';                               arg='microsoft.web/staticsites';                               sla='99.95%';                      basis='Standard' },
  @{ code='aks';             RType='AKS';             name='AKS';                            token='/providers/microsoft.containerservice/managedclusters/';              arg='microsoft.containerservice/managedclusters';              sla='99.95%';                      basis='Uptime SLA enabled' },
  @{ code='containerapp';    RType='ContainerApp';    name='Container Apps';                 token='/providers/microsoft.app/containerapps/';                             arg='microsoft.app/containerapps';                             sla='99.95%';                      basis='Standard' },
  @{ code='aci';             RType='ACI';             name='Container Instances';            token='/providers/microsoft.containerinstance/containergroups/';             arg='microsoft.containerinstance/containergroups';             sla='99.9%';                       basis='Standard' },
  @{ code='servicefabric';   RType='ServiceFabric';   name='Service Fabric';                 token='/providers/microsoft.servicefabric/clusters/';                        arg='microsoft.servicefabric/clusters';                        sla='99.95%';                      basis='Silver/Gold durability' },
  @{ code='batch';           RType='Batch';           name='Batch';                          token='/providers/microsoft.batch/batchaccounts/';                           arg='microsoft.batch/batchaccounts';                           sla='99.9%';                       basis='Standard' },
  @{ code='sql';             RType='SQL';             name='SQL Database';                   token='/providers/microsoft.sql/servers/';                                   arg='microsoft.sql/servers';                                   sla='99.99%';                      basis='Business Critical / GP HA' },
  @{ code='sqlmi';           RType='SQLMI';           name='SQL Managed Instance';           token='/providers/microsoft.sql/managedinstances/';                          arg='microsoft.sql/managedinstances';                          sla='99.99%';                      basis='Business Critical' },
  @{ code='cosmos';          RType='Cosmos';          name='Cosmos DB';                      token='/providers/microsoft.documentdb/databaseaccounts/';                   arg='microsoft.documentdb/databaseaccounts';                   sla='99.99% / 99.999%';            basis='Single / multi-region writes' },
  @{ code='postgres';        RType='Postgres';        name='PostgreSQL Flexible';            token='/providers/microsoft.dbforpostgresql/flexibleservers/';               arg='microsoft.dbforpostgresql/flexibleservers';               sla='99.99%';                      basis='HA enabled' },
  @{ code='mysql';           RType='MySQL';           name='MySQL Flexible';                 token='/providers/microsoft.dbformysql/flexibleservers/';                    arg='microsoft.dbformysql/flexibleservers';                    sla='99.99%';                      basis='HA enabled' },
  @{ code='mariadb';         RType='MariaDB';         name='MariaDB';                        token='/providers/microsoft.dbformariadb/servers/';                          arg='microsoft.dbformariadb/servers';                          sla='99.99%';                      basis='Standard' },
  @{ code='synapse';         RType='Synapse';         name='Synapse Analytics';              token='/providers/microsoft.synapse/workspaces/';                            arg='microsoft.synapse/workspaces';                            sla='99.9%';                       basis='Standard' },
  @{ code='kusto';           RType='DataExplorer';    name='Data Explorer';                  token='/providers/microsoft.kusto/clusters/';                                arg='microsoft.kusto/clusters';                                sla='99.9%';                       basis='Standard' },
  @{ code='adf';             RType='DataFactory';     name='Data Factory';                   token='/providers/microsoft.datafactory/factories/';                         arg='microsoft.datafactory/factories';                         sla='99.9%';                       basis='Standard' },
  @{ code='databricks';      RType='Databricks';      name='Databricks';                     token='/providers/microsoft.databricks/workspaces/';                         arg='microsoft.databricks/workspaces';                         sla='99.95%';                      basis='Premium' },
  @{ code='storage';         RType='Storage';         name='Storage Account';                token='/providers/microsoft.storage/storageaccounts/';                       arg='microsoft.storage/storageaccounts';                       sla='99.9% / 99.99%';              basis='LRS write / GRS read' },
  @{ code='keyvault';        RType='KeyVault';        name='Key Vault';                      token='/providers/microsoft.keyvault/vaults/';                               arg='microsoft.keyvault/vaults';                               sla='99.99%';                      basis='Standard' },
  @{ code='redis';           RType='Redis';           name='Cache for Redis';                token='/providers/microsoft.cache/redis/';                                   arg='microsoft.cache/redis';                                   sla='99.9%';                       basis='Standard / Premium' },
  @{ code='servicebus';      RType='ServiceBus';      name='Service Bus';                    token='/providers/microsoft.servicebus/namespaces/';                         arg='microsoft.servicebus/namespaces';                         sla='99.9% / 99.95%';              basis='Std / Premium' },
  @{ code='eventhub';        RType='EventHub';        name='Event Hubs';                     token='/providers/microsoft.eventhub/namespaces/';                           arg='microsoft.eventhub/namespaces';                           sla='99.95%';                      basis='Standard' },
  @{ code='eventgridtopic';  RType='EventGridTopic';  name='Event Grid Topic';               token='/providers/microsoft.eventgrid/topics/';                              arg='microsoft.eventgrid/topics';                              sla='99.99%';                      basis='Standard' },
  @{ code='eventgriddomain'; RType='EventGridDomain'; name='Event Grid Domain';              token='/providers/microsoft.eventgrid/domains/';                             arg='microsoft.eventgrid/domains';                             sla='99.99%';                      basis='Standard' },
  @{ code='apim';            RType='APIManagement';   name='API Management';                 token='/providers/microsoft.apimanagement/service/';                         arg='microsoft.apimanagement/service';                         sla='99.95% / 99.99%';             basis='Std / Premium multi-region' },
  @{ code='logicapps';       RType='LogicApps';       name='Logic Apps (Consumption)';       token='/providers/microsoft.logic/workflows/';                               arg='microsoft.logic/workflows';                               sla='99.9%';                       basis='Standard' },
  @{ code='notificationhub'; RType='NotificationHub'; name='Notification Hubs';              token='/providers/microsoft.notificationhubs/namespaces/';                   arg='microsoft.notificationhubs/namespaces';                   sla='99.9%';                       basis='Standard' },
  @{ code='relay';           RType='Relay';           name='Relay';                          token='/providers/microsoft.relay/namespaces/';                              arg='microsoft.relay/namespaces';                              sla='99.9%';                       basis='Standard' },
  @{ code='signalr';         RType='SignalR';         name='SignalR';                        token='/providers/microsoft.signalrservice/signalr/';                        arg='microsoft.signalrservice/signalr';                        sla='99.9%';                       basis='Standard' },
  @{ code='webpubsub';       RType='WebPubSub';       name='Web PubSub';                     token='/providers/microsoft.signalrservice/webpubsub/';                      arg='microsoft.signalrservice/webpubsub';                      sla='99.9%';                       basis='Standard' },
  @{ code='cognitive';       RType='Cognitive';       name='Cognitive Services / OpenAI';    token='/providers/microsoft.cognitiveservices/accounts/';                    arg='microsoft.cognitiveservices/accounts';                    sla='99.9%';                       basis='Standard' },
  @{ code='search';          RType='AISearch';        name='AI Search';                      token='/providers/microsoft.search/searchservices/';                         arg='microsoft.search/searchservices';                         sla='99.9%';                       basis='Standard 2+ replicas' },
  @{ code='appgw';           RType='AppGw';           name='Application Gateway';            token='/providers/microsoft.network/applicationgateways/';                   arg='microsoft.network/applicationgateways';                   sla='99.95%';                      basis='Standard_v2' },
  @{ code='loadbalancer';    RType='LoadBalancer';    name='Load Balancer';                  token='/providers/microsoft.network/loadbalancers/';                         arg='microsoft.network/loadbalancers';                         sla='99.99%';                      basis='Standard SKU' },
  @{ code='publicip';        RType='PublicIP';        name='Public IP';                      token='/providers/microsoft.network/publicipaddresses/';                     arg='microsoft.network/publicipaddresses';                     sla='99.99%';                      basis='Standard SKU' },
  @{ code='natgw';           RType='NatGateway';      name='NAT Gateway';                    token='/providers/microsoft.network/natgateways/';                           arg='microsoft.network/natgateways';                           sla='99.99%';                      basis='Standard' },
  @{ code='firewall';        RType='Firewall';        name='Firewall';                       token='/providers/microsoft.network/azurefirewalls/';                        arg='microsoft.network/azurefirewalls';                        sla='99.95% / 99.99%';             basis='Std / AZ' },
  @{ code='bastion';         RType='Bastion';         name='Bastion';                        token='/providers/microsoft.network/bastionhosts/';                          arg='microsoft.network/bastionhosts';                          sla='99.95%';                      basis='Standard' },
  @{ code='privateendpoint'; RType='PrivateEndpoint'; name='Private Endpoint';               token='/providers/microsoft.network/privateendpoints/';                      arg='microsoft.network/privateendpoints';                      sla='99.9%';                       basis='Standard' },
  @{ code='dnszone';         RType='DnsZone';         name='DNS Zone';                       token='/providers/microsoft.network/dnszones/';                              arg='microsoft.network/dnszones';                              sla='100%';                        basis='Public DNS' },
  @{ code='privatednszone';  RType='PrivateDnsZone';  name='Private DNS Zone';               token='/providers/microsoft.network/privatednszones/';                       arg='microsoft.network/privatednszones';                       sla='100%';                        basis='Private DNS' },
  @{ code='vnetgw';          RType='VNetGateway';     name='VPN / ER Gateway';               token='/providers/microsoft.network/virtualnetworkgateways/';                arg='microsoft.network/virtualnetworkgateways';                sla='99.95%';                      basis='VpnGw / ErGw' },
  @{ code='expressroute';    RType='ExpressRoute';    name='ExpressRoute Circuit';           token='/providers/microsoft.network/expressroutecircuits/';                  arg='microsoft.network/expressroutecircuits';                  sla='99.95%';                      basis='Standard' },
  @{ code='frontdoor';       RType='FrontDoor';       name='Front Door (Classic)';           token='/providers/microsoft.network/frontdoors/';                            arg='microsoft.network/frontdoors';                            sla='99.99%';                      basis='Classic' },
  @{ code='cdn';             RType='CDN';             name='CDN / Front Door Std/Premium';   token='/providers/microsoft.cdn/profiles/';                                  arg='microsoft.cdn/profiles';                                  sla='99.99%';                      basis='Std / Premium' },
  @{ code='trafficmanager';  RType='TrafficManager';  name='Traffic Manager';                token='/providers/microsoft.network/trafficmanagerprofiles/';                arg='microsoft.network/trafficmanagerprofiles';                sla='99.99%';                      basis='Standard' },
  @{ code='msi';             RType='ManagedIdentity'; name='Managed Identity';               token='/providers/microsoft.managedidentity/userassignedidentities/';        arg='microsoft.managedidentity/userassignedidentities';        sla='99.9%';                       basis='Standard' }
)

function K-Esc([string]$s) { $s.Replace("'", "''") }

$paramRows    = ($services | ForEach-Object { "'{0}','{1}'" -f (K-Esc $_.code), (K-Esc $_.name) }) -join ','
$paramQuery   = "datatable(value:string, label:string)[$paramRows] | project value, label"

$tokenMapRows = ($services | ForEach-Object { "'{0}','{1}','{2}'" -f (K-Esc $_.code), (K-Esc $_.token), (K-Esc $_.RType) }) -join ",`n"
$argMapRows   = ($services | ForEach-Object { "'{0}','{1}'" -f (K-Esc $_.arg), (K-Esc $_.RType) }) -join ",`n"
$expectedRows = ($services | ForEach-Object { "'{0}','{1}','{2}'" -f (K-Esc $_.RType), (K-Esc $_.sla), (K-Esc $_.basis) }) -join ",`n"

$rtypeCase   = (($services | ForEach-Object { "ResourceId has '{0}', '{1}'" -f (K-Esc $_.token), (K-Esc $_.RType) }) -join ', ') + ", 'Other'"
$argTypeCase = (($services | ForEach-Object { "tolower(type) == '{0}', '{1}'" -f (K-Esc $_.arg), (K-Esc $_.RType) }) -join ', ') + ", 'Other'"

$shell = @"
{
  "version": "Notebook/1.0",
  "items": [
    {
      "type": 1,
      "content": {
        "json": "# Azure Availability SLA\nPlatform availability for selected Azure services over a chosen period.\n\n- Default view is platform unavailability only (excludes user-initiated actions)\n- Choose one or more resource types in the filter\n- Turn on Include user actions to also show user-triggered operations in event views\n\nData source: AzureActivity (ResourceHealth + Administrative) and Azure Resource Graph for inventory."
      }
    },
    {
      "type": 9,
      "content": {
        "version": "KqlParameterItem/1.0",
        "parameters": [
          { "id": "p_date", "version": "KqlParameterItem/1.0", "name": "Date", "label": "Date range", "type": 4, "isRequired": true, "value": "P7D", "description": "Choose a period", "timeRangeDefinition": "generic" },
          { "id": "p_rtype", "version": "KqlParameterItem/1.0", "name": "ResourceTypes", "label": "Resource types", "type": 2, "isRequired": true, "multiSelect": true, "quote": "'", "delimiter": ",", "value": ["vm","vmss"], "query": "PARAM_QUERY", "queryType": 0, "resourceType": "microsoft.operationalinsights/workspaces" },
          { "id": "p_include", "version": "KqlParameterItem/1.0", "name": "IncludeUserInitiated", "label": "Include user actions", "type": 2, "isRequired": true, "multiSelect": false, "quote": "'", "delimiter": ",", "value": ["false"], "query": "datatable(v:string) [\"false\",\"true\"] | project v", "queryType": 0, "resourceType": "microsoft.operationalinsights/workspaces" }
        ],
        "style": "pills",
        "queryType": 0,
        "resourceType": "microsoft.operationalinsights/workspaces"
      }
    },
    { "type": 1, "content": { "json": "## Cumulative Uptime - per Region per Month" } },
    { "type": 3, "name": "RegionMonthMatrix", "content": { "version": "KqlItem/1.0", "query": "QQ_REGION_MONTH", "queryType": 0, "resourceType": "microsoft.operationalinsights/workspaces", "crossComponentResources": ["__WORKSPACE_RESOURCE_ID__"], "visualization": "table" } },
    { "type": 1, "content": { "json": "## Per-resource platform SLA for selected range" } },
    { "type": 3, "name": "ResourceTable", "content": { "version": "KqlItem/1.0", "query": "QQ_RESOURCE", "queryType": 0, "resourceType": "microsoft.operationalinsights/workspaces", "crossComponentResources": ["__WORKSPACE_RESOURCE_ID__"], "visualization": "table" } },
    { "type": 1, "content": { "json": "## Recent events for selected period" } },
    { "type": 3, "name": "EventLog", "content": { "version": "KqlItem/1.0", "query": "QQ_EVENT", "queryType": 0, "resourceType": "microsoft.operationalinsights/workspaces", "crossComponentResources": ["__WORKSPACE_RESOURCE_ID__"], "visualization": "table" } }
  ],
  "`$schema": "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"
}
"@

$prelude = @"
let DateRaw = tostring('{Date}');
let RawStart = todatetime('{Date:start}');
let RawEnd = todatetime('{Date:end}');
let RelativeDays = toint(extract('^P([0-9]+)D`$', 1, DateRaw));
let RelativeHours = toint(extract('^PT([0-9]+)H`$', 1, DateRaw));
let RelativeMinutes = toint(extract('^PT([0-9]+)M`$', 1, DateRaw));
let RangeStart = coalesce(RawStart, iff(isnotnull(RelativeDays), now() - 1d * RelativeDays, datetime(null)), iff(isnotnull(RelativeHours), now() - 1h * RelativeHours, datetime(null)), iff(isnotnull(RelativeMinutes), now() - 1m * RelativeMinutes, datetime(null)), ago(7d));
let RangeEnd = coalesce(RawEnd, now());
let _start = startofday(iff(RangeStart <= RangeEnd, RangeStart, RangeEnd));
let _end = endofday(iff(RangeStart <= RangeEnd, RangeEnd, RangeStart));
let Types = dynamic([{ResourceTypes}]);
let TokenMap = datatable(code:string, token:string, RType:string)[
$tokenMapRows
];
let argTypeMap = datatable(argType:string, RType:string)[
$argMapRows
];
let SelectedTokens = toscalar(TokenMap | where array_index_of(Types, code) >= 0 | summarize make_list(token));
let SelectedArgTypes = toscalar(argTypeMap | join kind=inner (TokenMap | where array_index_of(Types, code) >= 0 | project RType) on RType | summarize make_list(argType));
"@

$qRegion = $prelude + @"
let MatrixStart = startofmonth(_start);
let MatrixEndExclusive = startofmonth(datetime_add('month', 1, _end));
let MonthCount = datetime_diff('month', MatrixEndExclusive, MatrixStart);
let src = AzureActivity
| where TimeGenerated between (_start .. _end)
| where CategoryValue == 'ResourceHealth'
| extend ResourceId = tolower(coalesce(_ResourceId, ResourceId))
| where ResourceId has_any (SelectedTokens)
| extend Props = tostring(Properties), OpName = tolower(tostring(OperationNameValue))
| extend ReasonType = tolower(tostring(extractjson('`$.reasonType', Props))), Cause = tolower(tostring(extractjson('`$.cause', Props)))
| where ReasonType != 'userinitiated' and Cause != 'userinitiated'
| where not(OpName has 'deallocate' or OpName has 'power off' or OpName has 'poweroff')
| extend AvailState = tostring(extractjson('`$.currentHealthStatus', Props)), OccuredTime = coalesce(todatetime(extractjson('`$.eventTimestamp', Props)), todatetime(extractjson('`$.occuredTime', Props)), TimeGenerated), Region = coalesce(tostring(extractjson('`$.resourceLocation', Props)), tostring(extractjson('`$.location', Props)), tostring(ResourceGroup), 'unknown')
| order by ResourceId asc, OccuredTime asc;
src
| extend NextTimeRaw = next(OccuredTime)
| extend NextTime = coalesce(NextTimeRaw, _end)
| mv-expand m = range(0, MonthCount - 1) to typeof(int)
| extend WindowStart = startofmonth(datetime_add('month', m, MatrixStart)), WindowEnd = startofmonth(datetime_add('month', m + 1, MatrixStart))
| extend SegStart = iff(OccuredTime < WindowStart, WindowStart, OccuredTime), SegEnd = iff(NextTime > WindowEnd, WindowEnd, NextTime)
| where SegEnd > SegStart and SegStart < _end and SegEnd > _start
| extend SegSec = datetime_diff('second', SegEnd, SegStart), IsDown = AvailState != 'Available', WindowSec = datetime_diff('second', iff(WindowEnd > _end, _end, WindowEnd), iff(WindowStart < _start, _start, WindowStart)), Month = format_datetime(WindowStart, 'yyyy-MM')
| where WindowSec > 0
| summarize DownSec = sumif(SegSec, IsDown), WindowSec = max(WindowSec) by Region, Month
| extend SLA = round(((WindowSec - DownSec) * 100.0) / WindowSec, 4)
| project Region, Month, SLA
| evaluate pivot(Month, max(SLA))
"@

$qResource = $prelude + @"
let WindowSec = toreal(datetime_diff('second', _end, _start));
let expectedByType = datatable(RType:string, ExpectedSLA:string, SlaBasis:string)[
$expectedRows
];
let inventory = arg('').resources
| where tolower(type) in (SelectedArgTypes)
| project ResourceId = tolower(id), RType = tostring(case($argTypeCase)), Region = tostring(location);
let src = AzureActivity
| where TimeGenerated between (_start .. _end)
| where CategoryValue == 'ResourceHealth'
| extend ResourceId = tolower(coalesce(_ResourceId, ResourceId))
| where ResourceId has_any (SelectedTokens)
| extend Props = tostring(Properties), OpName = tolower(tostring(OperationNameValue))
| extend ReasonType = tolower(tostring(extractjson('`$.reasonType', Props))), Cause = tolower(tostring(extractjson('`$.cause', Props)))
| where ReasonType != 'userinitiated' and Cause != 'userinitiated'
| where not(OpName has 'deallocate' or OpName has 'power off' or OpName has 'poweroff')
| extend AvailState = tostring(extractjson('`$.currentHealthStatus', Props)), OccuredTime = coalesce(todatetime(extractjson('`$.eventTimestamp', Props)), todatetime(extractjson('`$.occuredTime', Props)), TimeGenerated), Region = coalesce(tostring(extractjson('`$.resourceLocation', Props)), tostring(extractjson('`$.location', Props)), tostring(ResourceGroup), 'unknown'), RType = case($rtypeCase)
| order by ResourceId asc, OccuredTime asc;
src
| extend NextTimeRaw = next(OccuredTime)
| extend NextTime = coalesce(NextTimeRaw, _end)
| extend SegStart = iff(OccuredTime < _start, _start, OccuredTime), SegEnd = iff(NextTime > _end, _end, NextTime)
| where SegEnd > SegStart
| extend SegSec = datetime_diff('second', SegEnd, SegStart), IsDown = AvailState != 'Available'
| summarize DownSec = sumif(SegSec, IsDown), Region = any(Region), RType = any(RType), PlatformEvents = count() by ResourceId
| join kind=fullouter hint.remote=left (inventory | project ResourceId, InvRType = RType, InvRegion = Region) on ResourceId
| extend ResourceId = coalesce(ResourceId, ResourceId1), RType = coalesce(RType, InvRType, 'Other'), Region = coalesce(Region, InvRegion, 'unknown'), DownSec = coalesce(DownSec, tolong(0)), PlatformEvents = coalesce(PlatformEvents, tolong(0))
| project-away ResourceId1, InvRType, InvRegion
| join kind=leftouter expectedByType on RType
| extend SLA = round(((WindowSec - todouble(DownSec)) * 100.0) / WindowSec, 4), UnavailableMinutes = round(todouble(DownSec) / 60.0, 2), ExpectedSLA = coalesce(ExpectedSLA, 'Unknown'), SlaBasis = coalesce(SlaBasis, 'Not mapped')
| extend ActualSLA = strcat(tostring(round(SLA, 4)), '%')
| order by SLA asc, UnavailableMinutes desc
| project ResourceId, RType, Region, ActualSLA, ExpectedSLA, SlaBasis, UnavailableMinutes, PlatformEvents
"@

$qEvent = $prelude + @"
let IncludeUser = tolower(tostring('{IncludeUserInitiated}')) == 'true';
let rh = AzureActivity
| where TimeGenerated between (_start .. _end)
| where CategoryValue == 'ResourceHealth'
| extend ResourceId = tolower(coalesce(_ResourceId, ResourceId))
| where ResourceId has_any (SelectedTokens)
| project TimeGenerated, CategoryValue, OperationNameValue, ResourceGroup, ResourceId;
let admin = AzureActivity
| where IncludeUser
| where TimeGenerated between (_start .. _end)
| where CategoryValue == 'Administrative'
| extend ResourceId = tolower(coalesce(_ResourceId, ResourceId))
| where ResourceId has_any (SelectedTokens)
| project TimeGenerated, CategoryValue, OperationNameValue, ResourceGroup, ResourceId;
union rh, admin
| order by TimeGenerated desc
"@

function ToJsonStr([string]$s) {
  $j = $s | ConvertTo-Json -Compress
  return $j.Substring(1, $j.Length - 2)
}

$p = 'C:\Users\nilelidi\Desktop\AzureSlaReport\platform\workbook-compute-sla.json'
Set-Content -Path $p -Value $shell -Encoding utf8
$c = Get-Content -Raw -Path $p
$c = $c.Replace('PARAM_QUERY',     (ToJsonStr $paramQuery))
$c = $c.Replace('QQ_REGION_MONTH', (ToJsonStr $qRegion))
$c = $c.Replace('QQ_RESOURCE',     (ToJsonStr $qResource))
$c = $c.Replace('QQ_EVENT',        (ToJsonStr $qEvent))
Set-Content -Path $p -Value $c -Encoding utf8
$null = Get-Content -Raw -Path $p | ConvertFrom-Json
Write-Host ("JSON valid; services: {0}" -f $services.Count)
