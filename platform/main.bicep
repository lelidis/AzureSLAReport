// ============================================================================
//  main.bicep - Central SLA monitoring platform (ENTERPRISE / PRIVATE)
//
//  Deploys a fully private, no-public-ingress stack:
//    - Log Analytics workspace (public ingestion/query DISABLED)
//    - Application Insights (workspace-based, public access DISABLED)
//    - Azure Monitor Private Link Scope (AMPLS) for LAW + App Insights
//    - Storage account (public network access DISABLED, no static website;
//      reports written to a PRIVATE blob container, accessed via RBAC)
//    - VNet with private-endpoint and Function-integration subnets
//    - Private Endpoints: storage blob/file/queue/table, Function (sites), AMPLS
//    - Private DNS zones + VNet links for all of the above
//    - Function App on Elastic Premium (EP1) with regional VNet integration,
//      public access DISABLED, SCM/FTP basic auth DISABLED
//    - Azure Workbook (self-service report)
//    - Managed-identity role assignments
//
//  Scope: Resource Group
//  Usage:
//    az group create -n rg-sla-monitoring -l westeurope
//    az deployment group create -g rg-sla-monitoring -f main.bicep \
//        -p workspaceName=law-sla-prod storageAccountName=stslareportprod
//
//  NOTE: User/agent access to the workbook and the private report container is
//  expected over your corporate network (ExpressRoute/VPN) that can reach this
//  VNet's private endpoints. The Function still needs OUTBOUND egress to
//  management.azure.com and login.microsoftonline.com (Azure Resource Graph and
//  Entra token) - these have no Private Link; allow them via your NAT/firewall.
// ============================================================================

@description('Azure region for all resources.')
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

@description('App Service (Elastic Premium) plan name.')
param appServicePlanName string = 'asp-sla-${uniqueString(resourceGroup().id)}'

@description('Private blob container that stores the HTML/CSV reports.')
param reportsContainerName string = 'reports'

@description('Address space for the VNet hosting private endpoints + Function integration.')
param vnetAddressPrefix string = '10.50.0.0/24'

@description('Subnet for private endpoints.')
param privateEndpointSubnetPrefix string = '10.50.0.0/26'

@description('Delegated subnet for Function regional VNet integration.')
param functionSubnetPrefix string = '10.50.0.64/26'

@description('Tag applied to all resources.')
param tags object = {
  workload: 'sla-monitoring'
  managedBy: 'bicep'
}

var contentShareName = toLower(functionAppName)
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
// Virtual network: one subnet for private endpoints, one delegated to the plan
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
              name: 'webserverfarm'
              properties: { serviceName: 'Microsoft.Web/serverFarms' }
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
//   0 blob | 1 file | 2 queue | 3 table | 4 sites
//   5 monitor | 6 oms | 7 ods | 8 agentsvc
// Enterprises with centralized DNS can remove these and link existing zones.
// ---------------------------------------------------------------------------
var privateDnsZoneNames = [
  'privatelink.blob.${storageSuffix}'
  'privatelink.file.${storageSuffix}'
  'privatelink.queue.${storageSuffix}'
  'privatelink.table.${storageSuffix}'
  'privatelink.azurewebsites.net'
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
]
var zBlob = 0
var zFile = 1
var zQueue = 2
var zTable = 3
var zSites = 4
var zMonitor = 5
var zOms = 6
var zOds = 7
var zAgent = 8

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
// Storage account: PRIVATE. Hosts the report container (no static website).
// allowSharedKeyAccess stays on only for the Function content share (EP plan
// requirement); the report data plane uses Entra/RBAC, not keys.
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
    publicNetworkAccess: 'Disabled'
    allowSharedKeyAccess: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
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

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource contentShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: contentShareName
  properties: { shareQuota: 5120 }
}

// ----- Storage private endpoints (blob / file / queue / table) -------------
resource peBlob 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${storageAccountName}-blob'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      { name: 'blob', properties: { privateLinkServiceId: storage.id, groupIds: [ 'blob' ] } }
    ]
  }
}
resource peBlobDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peBlob
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'blob', properties: { privateDnsZoneId: dnsZones[zBlob].id } }
    ]
  }
}

resource peFile 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${storageAccountName}-file'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      { name: 'file', properties: { privateLinkServiceId: storage.id, groupIds: [ 'file' ] } }
    ]
  }
}
resource peFileDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peFile
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'file', properties: { privateDnsZoneId: dnsZones[zFile].id } }
    ]
  }
}

resource peQueue 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${storageAccountName}-queue'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      { name: 'queue', properties: { privateLinkServiceId: storage.id, groupIds: [ 'queue' ] } }
    ]
  }
}
resource peQueueDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peQueue
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'queue', properties: { privateDnsZoneId: dnsZones[zQueue].id } }
    ]
  }
}

resource peTable 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${storageAccountName}-table'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      { name: 'table', properties: { privateLinkServiceId: storage.id, groupIds: [ 'table' ] } }
    ]
  }
}
resource peTableDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peTable
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'table', properties: { privateDnsZoneId: dnsZones[zTable].id } }
    ]
  }
}

// ---------------------------------------------------------------------------
// Azure Monitor Private Link Scope (AMPLS) for LAW + App Insights.
// AMPLS is a GA capability; the ARM API version carries a -preview suffix.
// ---------------------------------------------------------------------------
resource ampls 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = {
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

resource amplsWorkspace 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'scoped-${workspaceName}'
  properties: { linkedResourceId: workspace.id }
}

resource amplsAppInsights 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
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
      { name: 'azuremonitor', properties: { privateLinkServiceId: ampls.id, groupIds: [ 'azuremonitor' ] } }
    ]
  }
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
  dependsOn: [ amplsWorkspace, amplsAppInsights ]
}

// ---------------------------------------------------------------------------
// Elastic Premium (EP1) plan + PowerShell Function App with VNet integration
// ---------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  kind: 'elastic'
  sku: { name: 'EP1', tier: 'ElasticPremium' }
  properties: {
    reserved: false
    maximumElasticWorkerCount: 1
  }
}

var storageContentConn = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${storageSuffix}'

resource func 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Disabled'
    virtualNetworkSubnetId: funcSubnet.id
    siteConfig: {
      powerShellVersion: '7.4'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: true
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',     value: 'powershell' }
        // Host storage via managed identity (no key); requires the blob/queue/table data roles below.
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        // EP content share requires a key-based connection string; routed over VNet via the file private endpoint.
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: storageContentConn }
        { name: 'WEBSITE_CONTENTSHARE', value: contentShareName }
        { name: 'WEBSITE_CONTENTOVERVNET', value: '1' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'WORKSPACE_ID',      value: workspace.properties.customerId }
        { name: 'STORAGE_ACCOUNT',   value: storage.name }
        { name: 'REPORTS_CONTAINER', value: reportsContainerName }
        { name: 'MATRIX_MONTHS',     value: '12' }
      ]
    }
  }
  dependsOn: [
    contentShare
    peBlobDns
    peFileDns
    peQueueDns
    peTableDns
  ]
}

// Private endpoint for the Function (inbound). Public access is disabled above.
resource peSite 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${functionAppName}-sites'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      { name: 'sites', properties: { privateLinkServiceId: func.id, groupIds: [ 'sites' ] } }
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

// Disable basic publishing credentials (SCM + FTP). Deploy via identity/CI/CD.
resource scmBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: func
  name: 'scm'
  properties: { allow: false }
}
resource ftpBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2023-12-01' = {
  parent: func
  name: 'ftp'
  properties: { allow: false }
}

// ---------------------------------------------------------------------------
// RBAC: Function MI -> LA Reader + Storage data roles
// ---------------------------------------------------------------------------
var roleLogAnalyticsReader   = '73c42c96-874c-492b-b04d-ab87d138a893'
var roleBlobDataContributor  = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
// Identity-based AzureWebJobsStorage (no connection string) requires the host
// identity to have blob + queue + table data access, not just blob.
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

resource raBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, func.id, roleBlobDataContributor)
  scope: storage
  properties: {
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleBlobDataContributor)
  }
}

// Host storage (AzureWebJobsStorage) uses the function identity. The PowerShell
// host needs blob (owner), queue and table data access to start.
//
// NOTE: The function also queries Azure Resource Graph (Search-AzGraph) to build
// the resource inventory used for 100% uptime backfill. That requires the function
// MI to have **Reader** on the subscription(s) being reported. Because this template
// is resource-group scoped it cannot create a subscription-scoped assignment; grant
// it out-of-band (or via activity-export.bicep), e.g.:
//   az role assignment create --assignee-object-id <func.identity.principalId> \
//     --assignee-principal-type ServicePrincipal --role Reader \
//     --scope /subscriptions/<subId>
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
