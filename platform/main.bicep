// ============================================================================
//  main.bicep - Central SLA monitoring platform (private, keyless)
//
//  Resource group scope. Every service-to-service path uses a private endpoint
//  and no shared keys or connection strings exist. See README "Network and data flows".
//
//    az group create -n rg-sla-monitoring -l westeurope
//    az deployment group create -g rg-sla-monitoring -f main.bicep \
//        -p workspaceName=law-sla-prod storageAccountName=stslareportprod
//
//  Needs the Microsoft.App provider registered and a Flex Consumption region
//  (`az functionapp list-flexconsumption-locations`).
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

@description('Where the Function reads the resource inventory: "loganalytics" (arg() through the private workspace, no ARM access needed) or "arm" (calls Azure Resource Graph on management.azure.com; needs ARM reachability from the VNet).')
@allowed([
  'loganalytics'
  'arm'
])
param inventorySource string = 'loganalytics'

@description('Address space for the VNet hosting private endpoints + Function integration.')
param vnetAddressPrefix string = '10.50.0.0/24'

@description('Subnet for private endpoints.')
param privateEndpointSubnetPrefix string = '10.50.0.0/26'

@description('Delegated subnet for Function VNet integration (Flex Consumption: /27 minimum, /26 recommended).')
param functionSubnetPrefix string = '10.50.0.64/26'

@description('Tag applied to all resources.')
param tags object = {
  workload: 'sla-monitoring'
  managedBy: 'bicep'
}

var storageSuffix = environment().suffixes.storage

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
// Virtual network: one subnet for private endpoints, one delegated to Flex
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
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

// ---------------------------------------------------------------------------
// Private DNS zones (+ VNet links). Index order is referenced below.
//   0 blob | 1 queue | 2 table | 3 sites
//   4 monitor | 5 oms | 6 ods | 7 agentsvc
// Enterprises with centralized DNS can remove these and link existing zones.
// ---------------------------------------------------------------------------
var privateDnsZoneNames = [
  'privatelink.blob.${storageSuffix}'
  'privatelink.queue.${storageSuffix}'
  'privatelink.table.${storageSuffix}'
  'privatelink.azurewebsites.net'
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
]
var zBlob = 0
var zSites = 3
var zMonitor = 4
var zOms = 5
var zOds = 6
var zAgent = 7

resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for name in privateDnsZoneNames: {
  name: name
  location: 'global'
  tags: tags
}]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (name, i) in privateDnsZoneNames: {
  parent: dnsZones[i]
  name: 'link-vnet-sla'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}]

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
    subnet: { id: peSubnet.id }
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

resource peStorageDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = [for (ep, i) in storageEndpoints: {
  parent: peStorage[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: ep.group, properties: { privateDnsZoneId: dnsZones[ep.zone].id } }
    ]
  }
}]

// ---------------------------------------------------------------------------
// Azure Monitor Private Link Scope (AMPLS) for LAW + App Insights (GA API).
// Diagnostic-settings / Activity Log delivery to the workspace uses Microsoft's
// private channel and is not blocked by the disabled public ingestion setting.
// ---------------------------------------------------------------------------
resource ampls 'Microsoft.Insights/privateLinkScopes@2021-09-01' = {
  name: 'ampls-sla'
  location: 'global'
  tags: tags
  properties: {
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'PrivateOnly'
    }
  }
}

resource amplsWorkspace 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-09-01' = {
  parent: ampls
  name: 'scoped-${workspaceName}'
  properties: { linkedResourceId: workspace.id }
}

resource amplsAppInsights 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-09-01' = {
  parent: ampls
  name: 'scoped-appi-sla'
  properties: { linkedResourceId: appInsights.id }
}

resource peAmpls 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-ampls-sla'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnet.id }
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
  dependsOn: [ amplsWorkspace, amplsAppInsights ]
}

resource peAmplsDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peAmpls
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'monitor', properties: { privateDnsZoneId: dnsZones[zMonitor].id } }
      { name: 'oms', properties: { privateDnsZoneId: dnsZones[zOms].id } }
      { name: 'ods', properties: { privateDnsZoneId: dnsZones[zOds].id } }
      { name: 'agentsvc', properties: { privateDnsZoneId: dnsZones[zAgent].id } }
      { name: 'blob', properties: { privateDnsZoneId: dnsZones[zBlob].id } }
    ]
  }
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
    virtualNetworkSubnetId: funcSubnet.id
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
        { name: 'INVENTORY_SOURCE', value: inventorySource }
      ]
    }
  }
  dependsOn: [
    deploymentContainer
    peStorageDns
    peAmplsDns
  ]
}

// Private endpoint for the Function (inbound admin/deploy plane). Public access is disabled above.
resource peSite 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${functionAppName}-sites'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnet.id }
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

resource peSiteDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peSite
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'sites', properties: { privateDnsZoneId: dnsZones[zSites].id } }
    ]
  }
}

// ---------------------------------------------------------------------------
// RBAC for the Function managed identity.
//   - Log Analytics Reader on the workspace (query API, incl. arg() inventory)
//   - Blob Data Owner (host state, code package, report upload) + Queue/Table
//     Data Contributor (Functions host with identity-based AzureWebJobsStorage)
//
// The inventory also needs Reader on every reported subscription (arg() and
// Azure Resource Graph evaluate the caller's permissions). This template is
// resource-group scoped, so grant it out-of-band (or via activity-export.bicep):
//   az role assignment create --assignee-object-id <functionAppPrincipalId> \
//     --assignee-principal-type ServicePrincipal --role Reader \
//     --scope /subscriptions/<subId>
// ---------------------------------------------------------------------------
var roleLogAnalyticsReader   = '73c42c96-874c-492b-b04d-ab87d138a893'
var roleBlobDataOwner        = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var roleQueueDataContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var roleTableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

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
output vnetId                 string = vnet.id
output workbookResourceId     string = workbook.id
