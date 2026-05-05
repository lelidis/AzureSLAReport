// ============================================================================
//  main.bicep - Central SLA monitoring platform
//  Deploys: Log Analytics workspace, Storage (static website),
//           Azure Workbook, Function App (PowerShell, timer-triggered),
//           Managed Identity role assignments.
//
//  Scope: Resource Group
//  Usage:
//    az group create -n rg-sla-monitoring -l westeurope
//    az deployment group create -g rg-sla-monitoring -f main.bicep \
//        -p workspaceName=law-sla-prod storageAccountName=stslareportprod
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

@description('App Service plan name.')
param appServicePlanName string = 'asp-sla-${uniqueString(resourceGroup().id)}'

@description('Tag applied to all resources.')
param tags object = {
  workload: 'sla-monitoring'
  managedBy: 'bicep'
}

// ---------------------------------------------------------------------------
// Log Analytics workspace (single source of truth, 12-month+ retention)
// ---------------------------------------------------------------------------
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: workspaceRetentionDays
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

// ---------------------------------------------------------------------------
// Storage account: hosts $web static site for monthly HTML/CSV reports
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
  }
}

// Enable static website hosting (requires post-deploy or deployment script).
// Bicep cannot toggle the static-website feature directly; use the deploy script below.

// ---------------------------------------------------------------------------
// App Service plan (Consumption / Y1) and PowerShell Function App
// ---------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: { name: 'Y1', tier: 'Dynamic' }
  properties: { reserved: false }
}

resource func 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: '7.4'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',     value: 'powershell' }
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'WORKSPACE_ID',     value: workspace.properties.customerId }
        { name: 'STORAGE_ACCOUNT',  value: storage.name }
        { name: 'STATIC_CONTAINER', value: '$web' }
        { name: 'MATRIX_MONTHS',    value: '12' }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC: Function MI -> LA Reader  +  Storage Blob Data Contributor
// ---------------------------------------------------------------------------
var roleLogAnalyticsReader = '73c42c96-874c-492b-b04d-ab87d138a893'
var roleBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var roleMonitoringReader   = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'

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

// ---------------------------------------------------------------------------
// Azure Workbook (self-service report)
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
output workspaceId      string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output functionAppPrincipalId string = func.identity.principalId
output storageAccount   string = storage.name
output staticWebsiteHint string = 'Run: az storage blob service-properties update --account-name ${storage.name} --static-website --index-document index.html --auth-mode login'
output workbookResourceId string = workbook.id
