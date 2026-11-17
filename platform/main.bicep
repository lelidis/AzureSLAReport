// ============================================================================
//  main.bicep - Central SLA monitoring platform (private, keyless)
//
//  Resource group scope. Every data path uses a private endpoint and no shared
//  keys or connection strings exist. The only flow that leaves the VNet is the
//  Function's Azure Resource Graph call to management.azure.com (no private
//  endpoint exists for it): NAT gateway + NSG that only allows the
//  AzureResourceManager service tag. See README "Network and data flows".
//
//    az group create -n rg-sla-monitoring -l westeurope
//    az deployment group create -g rg-sla-monitoring -f main.bicep \
//        -p workspaceName=law-sla-prod storageAccountName=stslareportprod
//
//  Needs the Microsoft.App provider registered and a Flex Consumption region
//  (`az functionapp list-flexconsumption-locations`).
//
//  Optional: reuse an existing VNet (existing*SubnetId), Azure Monitor Private Link
//  Scope (existingAmplsResourceId) and private DNS zones (existingPrivateDnsZoneIds),
//  also from other resource groups or subscriptions. See README "Use an existing
//  network, Private Link scope and private DNS zones".
// ============================================================================

@description('Azure region for all resources. Must support Flex Consumption.')
param location string = resourceGroup().location

@description('Log Analytics workspace name.')
param workspaceName string

@description('Workspace data retention (days). 30-730. Use 400 for 12+ month reports.')
@minValue(30)
@maxValue(730)
param workspaceRetentionDays int = 400

@description('Globally unique storage account name (3-24 lowercase chars).')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Function App name.')
param functionAppName string = 'func-sla-${uniqueString(resourceGroup().id)}'

@description('Flex Consumption plan name.')
param appServicePlanName string = 'asp-sla-${uniqueString(resourceGroup().id)}'

@description('Private blob container that stores the HTML/CSV reports.')
param reportsContainerName string = 'reports'

@description('Private blob container that Flex Consumption uses for the deployed code package.')
param deploymentContainerName string = 'app-package'

@description('Create a NAT gateway for the Function subnet. The Function reads the resource inventory from Azure Resource Graph through management.azure.com, which has no private endpoint: this single flow leaves through the NAT gateway while the subnet NSG only allows the AzureResourceManager service tag. Set false only if you provide the same egress yourself (hub firewall/UDR to management.azure.com, or ARM Private Link). Ignored when an existing VNet is used.')
param deployNatGateway bool = true

@description('Address space for the VNet hosting private endpoints + Function integration (ignored when an existing VNet is used).')
param vnetAddressPrefix string = '10.50.0.0/24'

@description('Subnet for private endpoints (ignored when an existing VNet is used).')
param privateEndpointSubnetPrefix string = '10.50.0.0/26'

@description('Delegated subnet for Function VNet integration (Flex Consumption: /27 minimum, /26 recommended; ignored when an existing VNet is used).')
param functionSubnetPrefix string = '10.50.0.64/26'

@description('Existing subnet for the private endpoints (resource ID, any resource group or subscription). Set it together with existingFunctionSubnetId to use an existing VNet; leave both empty to create vnet-sla. The deployment identity needs Microsoft.Network/virtualNetworks/subnets/join/action on it.')
param existingPrivateEndpointSubnetId string = ''

@description('Existing subnet for the Function VNet integration (resource ID). Must be in the Function region, delegated to Microsoft.App/environments, /27 or larger and not used by anything else. The template does not change it, so it must already allow outbound HTTPS to management.azure.com (NAT gateway, hub firewall/UDR or ARM Private Link).')
param existingFunctionSubnetId string = ''

@description('Existing Azure Monitor Private Link Scope (resource ID, any resource group or subscription). When set, the workspace, Application Insights and the data collection endpoint are added to it and no scope or scope private endpoint is created; the scope, its private endpoint and its DNS must already serve the Function VNet. The deployment identity needs Contributor (or scopedResources/write plus deployments/write) on the scope resource group.')
param existingAmplsResourceId string = ''

@description('Create private DNS zone groups on the private endpoints. Set false when DNS records are created by policy or central DNS; no zones are created either.')
param createPrivateDnsZoneGroups bool = true

@description('Existing private DNS zones by key (blob, queue, table, sites, monitor, oms, ods, agentsvc), each a resource ID that can be in another subscription. A listed zone is used as is and must already be linked to (or resolvable from) the Function VNet; the deployment identity needs Private DNS Zone Contributor on it. Every key left out is created here and linked to the VNet.')
param existingPrivateDnsZoneIds object = {}

@description('Tag applied to all resources.')
param tags object = {
  workload: 'sla-monitoring'
  managedBy: 'bicep'
}

var storageSuffix = environment().suffixes.storage

// Both existing subnets are needed to reuse a VNet; otherwise vnet-sla is created.
var useExistingVnet = !empty(existingPrivateEndpointSubnetId) && !empty(existingFunctionSubnetId)
var createNatGateway = !useExistingVnet && deployNatGateway
var existingFunctionVnetId = useExistingVnet ? first(split(existingFunctionSubnetId, '/subnets/')) : ''

// ---------------------------------------------------------------------------
// Log Analytics workspace (private ingestion + query only)
// ---------------------------------------------------------------------------
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: workspaceRetentionDays
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}

// ---------------------------------------------------------------------------
// Application Insights (workspace-based, private only)
// ---------------------------------------------------------------------------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-sla-prod'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Disabled'
  }
}

// ---------------------------------------------------------------------------
// Controlled egress for the Function subnet.
// Log Analytics, Storage, Application Insights and the data collection endpoint
// are all reached through private endpoints. The one exception is Azure Resource
// Manager (the Azure Resource Graph inventory): management.azure.com has no
// private endpoint, so that flow leaves through a NAT gateway and the NSG blocks
// every other internet destination. The subnet has no default outbound access.
// With an existing VNet none of this is created: the subnet owner provides the egress.
// ---------------------------------------------------------------------------
resource nsgFunctions 'Microsoft.Network/networkSecurityGroups@2023-11-01' = if (!useExistingVnet) {
  name: 'nsg-sla-functions'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-azure-resource-manager'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureResourceManager'
          destinationPortRange: '443'
        }
      }
      {
        name: 'deny-internet-outbound'
        properties: {
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource natIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (createNatGateway) {
  name: 'pip-nat-sla'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource natGateway 'Microsoft.Network/natGateways@2023-11-01' = if (createNatGateway) {
  name: 'nat-sla'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [ { id: natIp.id } ]
  }
}

// ---------------------------------------------------------------------------
// Virtual network: one subnet for private endpoints, one delegated to Flex
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = if (!useExistingVnet) {
  name: 'vnet-sla'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ vnetAddressPrefix ] }
    subnets: [
      {
        name: 'snet-privateendpoints'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-functions'
        properties: {
          addressPrefix: functionSubnetPrefix
          defaultOutboundAccess: false
          networkSecurityGroup: { id: nsgFunctions.id }
          natGateway: createNatGateway ? { id: natGateway.id } : null
          delegations: [
            {
              name: 'flexconsumption'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
    ]
  }
}

resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: 'snet-privateendpoints'
}

resource funcSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: 'snet-functions'
}

var peSubnetId = useExistingVnet ? existingPrivateEndpointSubnetId : peSubnet.id
var funcSubnetId = useExistingVnet ? existingFunctionSubnetId : funcSubnet.id

// ---------------------------------------------------------------------------
// Private DNS zones (+ VNet links). Index order is referenced below.
//   0 blob | 1 queue | 2 table | 3 sites
//   4 monitor | 5 oms | 6 ods | 7 agentsvc
// A zone listed in existingPrivateDnsZoneIds (any subscription) is used as is and
// must already be linked to / resolvable from the Function VNet. Every other zone
// is created here and linked to the VNet. createPrivateDnsZoneGroups=false creates
// no zones and no zone groups (records come from policy / central DNS).
// ---------------------------------------------------------------------------
var privateDnsZones = [
  { key: 'blob', name: 'privatelink.blob.${storageSuffix}' }
  { key: 'queue', name: 'privatelink.queue.${storageSuffix}' }
  { key: 'table', name: 'privatelink.table.${storageSuffix}' }
  { key: 'sites', name: 'privatelink.azurewebsites.net' }
  { key: 'monitor', name: 'privatelink.monitor.azure.com' }
  { key: 'oms', name: 'privatelink.oms.opinsights.azure.com' }
  { key: 'ods', name: 'privatelink.ods.opinsights.azure.com' }
  { key: 'agentsvc', name: 'privatelink.agentsvc.azure-automation.net' }
]
var zBlob = 0
var zSites = 3
var zMonitor = 4
var zOms = 5
var zOds = 6
var zAgent = 7

var zoneProvided = [for z in privateDnsZones: contains(existingPrivateDnsZoneIds, z.key) ? !empty(existingPrivateDnsZoneIds[z.key]) : false]
var zoneLinkVnetId = useExistingVnet ? existingFunctionVnetId : vnet.id

resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for (z, i) in privateDnsZones: if (createPrivateDnsZoneGroups && !zoneProvided[i]) {
  name: z.name
  location: 'global'
  tags: tags
}]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (z, i) in privateDnsZones: if (createPrivateDnsZoneGroups && !zoneProvided[i]) {
  parent: dnsZones[i]
  name: 'link-vnet-sla'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: zoneLinkVnetId }
  }
}]

var dnsZoneIds = [for (z, i) in privateDnsZones: zoneProvided[i] ? existingPrivateDnsZoneIds[z.key] : dnsZones[i].id]

// ---------------------------------------------------------------------------
// Storage account: PRIVATE and KEYLESS. Hosts the report container, the Flex
// deployment container and the Functions host state. Every caller uses Entra
// ID (managed identity / RBAC); shared-key access is switched off.
// ---------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource reportsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: reportsContainerName
  properties: { publicAccess: 'None' }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainerName
  properties: { publicAccess: 'None' }
}

// ----- Storage private endpoints (blob / queue / table) --------------------
// Functions host state uses blob + queue + table; the report upload uses blob.
var storageEndpoints = [
  { group: 'blob', zone: zBlob }
  { group: 'queue', zone: 1 }
  { group: 'table', zone: 2 }
]

resource peStorage 'Microsoft.Network/privateEndpoints@2023-11-01' = [for ep in storageEndpoints: {
  name: 'pe-${storageAccountName}-${ep.group}'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: ep.group
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [ ep.group ]
        }
      }
    ]
  }
}]

resource peStorageDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = [for (ep, i) in storageEndpoints: if (createPrivateDnsZoneGroups) {
  parent: peStorage[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: ep.group, properties: { privateDnsZoneId: dnsZoneIds[ep.zone] } }
    ]
  }
}]

// ---------------------------------------------------------------------------
// Azure Monitor Private Link Scope (AMPLS) for LAW + App Insights + the data
// collection endpoint (GA API). With existingAmplsResourceId the three resources
// are added to that scope (any resource group or subscription) and no scope or
// scope private endpoint is created here.
// Diagnostic-settings / Activity Log delivery to the workspace uses Microsoft's
// private channel and is not blocked by the disabled public ingestion setting.
// ---------------------------------------------------------------------------
var useExistingAmpls = !empty(existingAmplsResourceId)
var amplsIdParts = split(existingAmplsResourceId, '/')
var amplsSubscriptionId = useExistingAmpls ? amplsIdParts[2] : subscription().subscriptionId
var amplsResourceGroup = useExistingAmpls ? amplsIdParts[4] : resourceGroup().name
var amplsName = useExistingAmpls ? last(amplsIdParts) : 'ampls-sla'

// A shared scope can hold several deployments: make the scoped resource names unique per resource group.
var scopedNameSuffix = uniqueString(resourceGroup().id)
var scopedWorkspaceName = useExistingAmpls ? 'scoped-${take(workspaceName, 30)}-${scopedNameSuffix}' : 'scoped-${workspaceName}'
var scopedAppInsightsName = useExistingAmpls ? 'scoped-appi-sla-${scopedNameSuffix}' : 'scoped-appi-sla'
var scopedDceName = useExistingAmpls ? 'scoped-dce-sla-${scopedNameSuffix}' : 'scoped-dce-sla'

resource ampls 'Microsoft.Insights/privateLinkScopes@2021-09-01' = if (!useExistingAmpls) {
  name: amplsName
  location: 'global'
  tags: tags
  properties: {
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'PrivateOnly'
    }
  }
}

// Chained so the scope is updated one resource at a time.
module amplsLinkWorkspace 'ampls-link.bicep' = {
  name: 'ampls-link-workspace'
  scope: resourceGroup(amplsSubscriptionId, amplsResourceGroup)
  params: {
    amplsName: amplsName
    scopedResourceName: scopedWorkspaceName
    linkedResourceId: workspace.id
  }
  dependsOn: [ ampls ]
}

module amplsLinkAppInsights 'ampls-link.bicep' = {
  name: 'ampls-link-appinsights'
  scope: resourceGroup(amplsSubscriptionId, amplsResourceGroup)
  params: {
    amplsName: amplsName
    scopedResourceName: scopedAppInsightsName
    linkedResourceId: appInsights.id
  }
  dependsOn: [ amplsLinkWorkspace ]
}

// ---------------------------------------------------------------------------
// Inventory ingestion (Logs Ingestion API over the same Private Link scope).
// arg('') cannot be used on a workspace reached through Azure Monitor Private
// Link ("The Azure Data Explorer (ADX) pattern cannot be used with Private
// Link"), so the RefreshInventory Function writes a daily Azure Resource Graph
// snapshot into SlaInventory_CL and the workbook joins that table instead.
// ---------------------------------------------------------------------------
var inventoryTableName = 'SlaInventory_CL'
var inventoryStream = 'Custom-${inventoryTableName}'
var inventoryColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'ResourceId', type: 'string' }
  { name: 'RType', type: 'string' }
  { name: 'Region', type: 'string' }
  { name: 'ArgType', type: 'string' }
]

resource inventoryTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  parent: workspace
  name: inventoryTableName
  properties: {
    schema: { name: inventoryTableName, columns: inventoryColumns }
    retentionInDays: 30
  }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: 'dce-sla'
  location: location
  tags: tags
  properties: {
    networkAcls: { publicNetworkAccess: 'Disabled' }
  }
}

module amplsLinkDce 'ampls-link.bicep' = {
  name: 'ampls-link-dce'
  scope: resourceGroup(amplsSubscriptionId, amplsResourceGroup)
  params: {
    amplsName: amplsName
    scopedResourceName: scopedDceName
    linkedResourceId: dce.id
  }
  dependsOn: [ amplsLinkAppInsights ]
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-sla-inventory'
  location: location
  tags: tags
  properties: {
    dataCollectionEndpointId: dce.id
    streamDeclarations: {
      '${inventoryStream}': { columns: inventoryColumns }
    }
    destinations: {
      logAnalytics: [ { name: 'law', workspaceResourceId: workspace.id } ]
    }
    dataFlows: [
      {
        streams: [ inventoryStream ]
        destinations: [ 'law' ]
        transformKql: 'source'
        outputStream: inventoryStream
      }
    ]
  }
  dependsOn: [ inventoryTable ]
}

resource peAmpls 'Microsoft.Network/privateEndpoints@2023-11-01' = if (!useExistingAmpls) {
  name: 'pe-ampls-sla'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'azuremonitor'
        properties: {
          privateLinkServiceId: ampls.id
          groupIds: [ 'azuremonitor' ]
        }
      }
    ]
  }
  dependsOn: [ amplsLinkWorkspace, amplsLinkAppInsights, amplsLinkDce ]
}

resource peAmplsDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = if (!useExistingAmpls && createPrivateDnsZoneGroups) {
  parent: peAmpls
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'monitor', properties: { privateDnsZoneId: dnsZoneIds[zMonitor] } }
      { name: 'oms', properties: { privateDnsZoneId: dnsZoneIds[zOms] } }
      { name: 'ods', properties: { privateDnsZoneId: dnsZoneIds[zOds] } }
      { name: 'agentsvc', properties: { privateDnsZoneId: dnsZoneIds[zAgent] } }
      { name: 'blob', properties: { privateDnsZoneId: dnsZoneIds[zBlob] } }
    ]
  }
  dependsOn: [ dnsZones ]
}

// ---------------------------------------------------------------------------
// Flex Consumption plan + PowerShell Function App with VNet integration.
// Flex needs no Azure Files content share, no shared keys and no storage
// connection string: host state and the code package use the managed identity.
// ---------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  properties: { reserved: true }
}

resource func 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: funcSubnetId
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: { type: 'SystemAssignedIdentity' }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'powershell'
        version: '7.6'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'WORKSPACE_ID', value: workspace.properties.customerId }
        { name: 'STORAGE_BLOB_ENDPOINT', value: storage.properties.primaryEndpoints.blob }
        { name: 'REPORTS_CONTAINER', value: reportsContainerName }
        { name: 'MATRIX_MONTHS', value: '12' }
        { name: 'DCE_LOGS_INGESTION_ENDPOINT', value: dce.properties.logsIngestion.endpoint }
        { name: 'DCR_IMMUTABLE_ID', value: dcr.properties.immutableId }
        { name: 'INVENTORY_STREAM', value: inventoryStream }
      ]
    }
  }
  dependsOn: [
    deploymentContainer
    dnsLinks
    peStorageDns
    peAmplsDns
    amplsLinkDce
  ]
}

// Private endpoint for the Function (inbound admin/deploy plane). Public access is disabled above.
resource peSite 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${functionAppName}-sites'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'sites'
        properties: {
          privateLinkServiceId: func.id
          groupIds: [ 'sites' ]
        }
      }
    ]
  }
}

resource peSiteDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = if (createPrivateDnsZoneGroups) {
  parent: peSite
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'sites', properties: { privateDnsZoneId: dnsZoneIds[zSites] } }
    ]
  }
}

// ---------------------------------------------------------------------------
// RBAC for the Function managed identity.
//   - Log Analytics Reader on the workspace (query API)
//   - Blob Data Owner (host state, code package, report upload) + Queue/Table
//     Data Contributor (Functions host with identity-based AzureWebJobsStorage)
//   - Monitoring Metrics Publisher on the data collection rule (inventory ingestion)
//
// The inventory also needs Reader on every reported subscription (Azure Resource
// Graph evaluates the caller's permissions). This template is resource-group
// scoped, so grant it out-of-band (or via activity-export.bicep):
//   az role assignment create --assignee-object-id <functionAppPrincipalId> \
//     --assignee-principal-type ServicePrincipal --role Reader \
//     --scope /subscriptions/<subId>
// ---------------------------------------------------------------------------
var roleLogAnalyticsReader   = '73c42c96-874c-492b-b04d-ab87d138a893'
var roleBlobDataOwner        = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var roleQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var roleTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var roleMonitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'

resource raLaReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, func.id, roleLogAnalyticsReader)
  scope: workspace
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleLogAnalyticsReader)
  }
}

resource raBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, func.id, roleBlobDataOwner)
  scope: storage
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobDataOwner)
  }
}

resource raQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, func.id, roleQueueDataContributor)
  scope: storage
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleQueueDataContributor)
  }
}

resource raTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, func.id, roleTableDataContributor)
  scope: storage
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleTableDataContributor)
  }
}

resource raDcr 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dcr.id, func.id, roleMonitoringMetricsPublisher)
  scope: dcr
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleMonitoringMetricsPublisher)
  }
}

// ---------------------------------------------------------------------------
// Azure Workbook (self-service report) - primary consumer surface
// ---------------------------------------------------------------------------
resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'compute-sla-workbook-v2')
  location: location
  kind: 'shared'
  properties: {
    displayName: 'Azure Compute Availability SLA'
    category: 'workbook'
    sourceId: workspace.id
    serializedData: replace(loadTextContent('./workbook-compute-sla.json'), '__WORKSPACE_RESOURCE_ID__', workspace.id)
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output workspaceId            string = workspace.id
output workspaceCustomerId    string = workspace.properties.customerId
output functionAppPrincipalId string = func.identity.principalId
output functionAppName        string = func.name
output storageAccount         string = storage.name
output reportsContainer       string = reportsContainerName
output reportBlobPathHint     string = 'Reports are private. Read via Portal Storage browser / Storage Explorer with Storage Blob Data Reader on ${storage.name}/${reportsContainerName} over the private endpoint.'
output vnetId                 string = useExistingVnet ? existingFunctionVnetId : vnet.id
output amplsResourceId        string = useExistingAmpls ? existingAmplsResourceId : ampls.id
output inventoryTable         string = inventoryTableName
output dataCollectionRuleId   string = dcr.id
output workbookResourceId     string = workbook.id
