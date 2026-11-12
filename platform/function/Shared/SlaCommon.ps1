# =============================================================================
# SlaCommon.ps1 - helpers shared by the SLA Functions (dot-sourced by run.ps1)
#
#   - Managed identity tokens (local IDENTITY_ENDPOINT, no network egress)
#   - REST helper with retry, Log Analytics query helper
#   - The 49-service catalog (identical to platform/inject-queries.ps1)
#   - Azure Resource Graph inventory through Azure Resource Manager
#
# Pure REST with the managed identity: no Az modules, no PowerShell Gallery.
# =============================================================================

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
    $r = Invoke-Rest -Method Post -Uri "https://api.loganalytics.azure.com/v1/workspaces/$($env:WORKSPACE_ID)/query" `
        -Resource 'https://api.loganalytics.io' -Body $body -Headers @{ Prefer = 'wait=600' }
    if ($r.error) { throw "Log Analytics query error: $($r.error.message)" }
    $cols = @($r.tables[0].columns | ForEach-Object { $_.name })
    foreach ($row in $r.tables[0].rows) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $row[$i] }
        [pscustomobject]$o
    }
}

# -----------------------------------------------------------------------------
# Service catalog: RType, name, token (ResourceHealth path), arg (ARG type), sla, basis
# -----------------------------------------------------------------------------
$script:ServiceCatalog = @(
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

# -----------------------------------------------------------------------------
# Inventory from Azure Resource Graph through Azure Resource Manager
# (management.azure.com). Pages with $skipToken, so it is complete for any size.
# ARM has no private endpoint of its own: the Function reaches it through the
# egress path in main.bicep (NAT gateway + NSG that only allows the
# AzureResourceManager service tag). Needs Reader on every reported subscription.
# Returns ResourceId (lowercase id), RType, Region and ArgType per resource.
# -----------------------------------------------------------------------------
function Get-ArgInventory {
    $argToRType = @{}
    foreach ($s in $script:ServiceCatalog) { $argToRType[$s.arg] = $s.RType }
    $argList = ($script:ServiceCatalog | ForEach-Object { "'" + $_.arg + "'" }) -join ','
    $query = "resources | where tolower(type) in ($argList) | project ResourceId = tolower(id), Region = tostring(location), ArgType = tolower(type)"
    $inventory = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    do {
        $options = @{ '$top' = 1000 }
        if ($skipToken) { $options['$skipToken'] = $skipToken }
        $body = @{ query = $query; options = $options } | ConvertTo-Json -Compress
        $page = Invoke-Rest -Method Post -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' `
            -Resource 'https://management.azure.com/' -Body $body
        foreach ($r in $page.data) {
            $rt = $argToRType[$r.ArgType]
            $inventory.Add([pscustomobject]@{ ResourceId = $r.ResourceId; RType = $(if ($rt) { $rt } else { 'Other' }); Region = $r.Region; ArgType = $r.ArgType })
        }
        $skipToken = $page.'$skipToken'
    } while ($skipToken)
    return $inventory.ToArray()
}
