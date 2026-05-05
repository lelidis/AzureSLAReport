// ============================================================================
//  policy-resource-health.bicep   (OPTIONAL - for tenant-wide governance)
//
//  RECOMMENDED PATH FIRST: run `Enable-ResourceHealthIngestion.ps1` to flip
//  on the subscription Activity Log diagnostic setting (category=ResourceHealth)
//  for each subscription. That gets data flowing in minutes.
//
//  This template assigns a built-in policy at MG scope to enforce that setting
//  on existing & future subscriptions. Microsoft renames/replaces built-in
//  definitions occasionally, so the GUID is parameterized.
//
//  Find the current built-in definition with:
//    az policy definition list --query "[?policyType=='BuiltIn'] | [?contains(displayName, 'activity log') && contains(displayName, 'Log Analytics')].{name:name, displayName:displayName}" -o table
// ============================================================================
targetScope = 'managementGroup'

@description('Resource ID of the central Log Analytics workspace.')
param workspaceId string

@description('GUID of the built-in policy definition. See header for lookup command.')
param policyDefinitionGuid string

@description('Location for the policy assignment identity.')
param location string = 'westeurope'

@description('Policy assignment name (max 24 chars).')
@maxLength(24)
param assignmentName string = 'sla-rh-to-law'

var policyDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', policyDefinitionGuid)

resource assignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: assignmentName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Send Resource Health to central Log Analytics'
    policyDefinitionId: policyDefinitionId
    parameters: {
      logAnalytics: { value: workspaceId }
      effect:       { value: 'DeployIfNotExists' }
    }
  }
}

var roleLogAnalyticsContributor = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
var roleMonitoringContributor   = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'

resource raLA 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, assignment.id, roleLogAnalyticsContributor)
  properties: {
    principalId: assignment.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', roleLogAnalyticsContributor)
  }
}

resource raMon 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, assignment.id, roleMonitoringContributor)
  properties: {
    principalId: assignment.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', roleMonitoringContributor)
  }
}

output assignmentPrincipalId string = assignment.identity.principalId
