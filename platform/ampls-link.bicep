// Adds one resource (workspace, Application Insights or data collection endpoint)
// to an Azure Monitor Private Link Scope. A module so that main.bicep can deploy it
// into the resource group / subscription that owns the scope.

@description('Name of the existing Azure Monitor Private Link Scope.')
param amplsName string

@description('Name of the scoped resource to create on the Private Link Scope.')
param scopedResourceName string

@description('Resource ID of the workspace, Application Insights component or data collection endpoint to add.')
param linkedResourceId string

resource ampls 'Microsoft.Insights/privateLinkScopes@2021-09-01' existing = {
  name: amplsName
}

resource scopedResource 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-09-01' = {
  parent: ampls
  name: scopedResourceName
  properties: { linkedResourceId: linkedResourceId }
}
