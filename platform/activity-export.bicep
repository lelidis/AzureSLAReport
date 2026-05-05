// ============================================================================
//  activity-export.bicep — Subscription-scope module
//
//  Deploys:
//    - Subscription-level diagnostic setting that exports Activity Log
//      (ResourceHealth + Administrative) to a target Log Analytics workspace.
//    - Reader role assignment on this subscription for a given principal
//      (e.g., the Function App managed identity hosting the SLA report).
//
//  Run once per monitored subscription:
//    az deployment sub create \
//      --location <region> \
//      --name sla-activity-export \
//      --template-file ./activity-export.bicep \
//      --parameters \
//          workspaceResourceId=<full LAW resource id> \
//          readerPrincipalId=<objectId of identity that opens the workbook> \
//          principalType=ServicePrincipal
// ============================================================================
targetScope = 'subscription'

@description('Full resource ID of the Log Analytics workspace receiving Activity Log.')
param workspaceResourceId string

@description('Object ID granted Reader on this subscription (for ARG inventory in the workbook).')
param readerPrincipalId string

@description('Principal type for the role assignment.')
@allowed([
  'User'
  'Group'
  'ServicePrincipal'
])
param principalType string = 'ServicePrincipal'

@description('Diagnostic setting name.')
param settingName string = 'to-sla-workspace'

resource activityExport 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: settingName
  scope: subscription()
  properties: {
    workspaceId: workspaceResourceId
    logs: [
      { category: 'Administrative',  enabled: true }
      { category: 'ResourceHealth',  enabled: true }
      { category: 'ServiceHealth',   enabled: false }
      { category: 'Alert',           enabled: false }
      { category: 'Autoscale',       enabled: false }
      { category: 'Policy',          enabled: false }
      { category: 'Recommendation',  enabled: false }
      { category: 'Security',        enabled: false }
    ]
  }
}

var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource readerRa 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, readerPrincipalId, readerRoleId)
  properties: {
    principalId: readerPrincipalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
  }
}

output diagnosticSettingId string = activityExport.id
output readerRoleAssignmentId string = readerRa.id
