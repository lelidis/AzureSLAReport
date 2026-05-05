# Azure Availability SLA Report

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2F328563dca2d59496168bbfb9e8b26eb7ca64c1f6%2Fplatform%2Fmain.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2F328563dca2d59496168bbfb9e8b26eb7ca64c1f6%2Fplatform%2FcreateUiDefinition.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg?sanitize=true)](https://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2F328563dca2d59496168bbfb9e8b26eb7ca64c1f6%2Fplatform%2Fmain.json)

Self-service Azure Workbook + Bicep platform that produces platform-availability SLA reports across many Azure services from `AzureActivity` Resource Health events, enriched with an Azure Resource Graph (ARG) inventory so even 100%-healthy resources appear.

## What it provides

- **Cumulative Uptime - per Region per Month** (pivot by month).
- **Per-resource platform SLA for selected range** with `RType`, `Region`, `ActualSLA`, `ExpectedSLA` (Microsoft published), `SlaBasis`, `UnavailableMinutes`, `PlatformEvents`.
- **Recent events** for the selected period (ResourceHealth + optional Administrative when `Include user actions = true`).
- 49 supported resource types out of the box (VM/VMSS, App Service, AKS, Container Apps, SQL, SQL MI, Cosmos, Postgres/MySQL Flex, Storage, Key Vault, Redis, Service Bus, Event Hub/Grid, APIM, Logic Apps, SignalR, Web PubSub, Cognitive Services / OpenAI, AI Search, App Gateway, Load Balancer, Public IP, NAT GW, Firewall, Bastion, Front Door, CDN, Traffic Manager, ExpressRoute, VPN/ER GW, DNS / Private DNS, Managed Identity, Static Web Apps, Service Fabric, Batch, Synapse, Data Explorer, Data Factory, Databricks, MariaDB).

The workbook strictly excludes user-initiated actions from SLA math (uses `reasonType`/`cause` and operation-name hygiene) so values reflect platform unavailability only.

## Architecture

- [platform/main.bicep](platform/main.bicep) — Resource group scope. Deploys:
  - Log Analytics workspace
  - Storage account
  - Function App (PowerShell, timer-triggered) + plan + RBAC (LA Reader, Blob Data Contributor)
  - Azure Workbook (queries injected from `workbook-compute-sla.json`)
- [platform/activity-export.bicep](platform/activity-export.bicep) — **Subscription scope.** Deploys per monitored subscription:
  - Activity Log diagnostic setting → workspace (`ResourceHealth` + `Administrative`)
  - `Reader` role assignment for the SLA report identity (so ARG inventory works)
- [platform/inject-queries.ps1](platform/inject-queries.ps1) — Generates `workbook-compute-sla.json` from a service catalog. Single source of truth for what the workbook contains.

The workbook JSON contains a placeholder `__WORKSPACE_RESOURCE_ID__` that Bicep replaces at deploy time, so the same file is portable across environments.

## Prerequisites

- Azure CLI 2.55+ with Bicep (`az bicep install`).
- Permission to deploy at:
  - Resource group scope in the “hub” subscription that hosts the workspace and workbook.
  - Subscription scope in every subscription you want monitored (Owner or User Access Administrator + Monitoring Contributor).
- The principal opening the workbook needs `Reader` on each monitored subscription. The `activity-export` module assigns this automatically when given the principal’s object id.

## Deployment

You can deploy the hub three ways. Pick whichever fits your audience; all three produce the same resources.

| Option | Tooling needed | Best for |
| --- | --- | --- |
| Portal "Deploy to Azure" button | Browser only | One-click adoption, demos |
| ARM JSON via Azure CLI | `az` | Users without Bicep installed |
| Bicep via Azure CLI | `az` + Bicep | CI/CD, this repo's source of truth |

### Option A — Deploy to Azure (portal form)

Click the button at the top of this README, or use this direct link:

> https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2Fmain%2Fplatform%2Fmain.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2Fmain%2Fplatform%2FcreateUiDefinition.json

The portal will prompt for subscription, resource group, location, workspace name, storage account name, and (optional) Function App / plan names — no CLI required. The button references [platform/main.json](platform/main.json) and [platform/createUiDefinition.json](platform/createUiDefinition.json) over `raw.githubusercontent.com`, so the repo and those two files must be public.

If you fork this repo, swap `lelidis/AzureSLAReport/main` in the URL above for `<owner>/<repo>/<branch>`.

### Option B — ARM JSON via Azure CLI

```powershell
$rg = 'rg-sla-monitoring'
$location = 'westeurope'

az group create -n $rg -l $location

az deployment group create `
  --resource-group $rg `
  --template-file ./platform/main.json `
  --parameters workspaceName=law-sla-prod storageAccountName=stslareportprod
```

If you change `main.bicep` or the workbook, recompile before deploying:

```powershell
az bicep build --file ./platform/main.bicep            --outfile ./platform/main.json
az bicep build --file ./platform/activity-export.bicep --outfile ./platform/activity-export.json
```

### Option C — Bicep (source of truth)

#### 1. Hub deployment (workspace, storage, function, workbook)

```powershell
$rg = 'rg-sla-monitoring'
$location = 'westeurope'
$workspaceName = 'law-sla-prod'
$storageAccountName = 'stslareportprod'   # globally unique, 3-24 lowercase

az group create -n $rg -l $location

# Regenerate workbook JSON from the service catalog (idempotent)
./platform/inject-queries.ps1

az deployment group create `
  --resource-group $rg `
  --template-file ./platform/main.bicep `
  --parameters workspaceName=$workspaceName storageAccountName=$storageAccountName
```

Outputs include:

- `workspaceId` — full LAW resource id
- `functionAppPrincipalId` — managed identity object id used by SLA exports
- `workbookResourceId` — open this in the portal

## Per-subscription enablement (applies to all deployment options)

Run for each subscription you want included in the report. `readerPrincipalId` is the identity that opens the workbook (a user, group, or the `functionAppPrincipalId` for unattended use).

The portal currently does not support subscription-scope deployments through "Deploy to Azure" buttons, so use the CLI for this step:

```powershell
$workspaceId = '<output from step 1: workspaceId>'
$readerPrincipalId = '<objectId of user/group/SP>'
$location = 'westeurope'

$subs = @(
  '00000000-0000-0000-0000-000000000000',
  '11111111-1111-1111-1111-111111111111'
)
foreach ($sub in $subs) {
  az account set --subscription $sub
  az deployment sub create `
    --name sla-activity-export `
    --location $location `
    --template-file ./platform/activity-export.bicep `
    --parameters workspaceResourceId=$workspaceId `
                 readerPrincipalId=$readerPrincipalId `
                 principalType=ServicePrincipal
}
```

For users/groups, set `principalType=User` or `principalType=Group`.

## Use the workbook

- Portal → Monitor → Workbooks → "Azure Compute Availability SLA" (in the hub RG).
- Pick `Date range`, one or more `Resource types`, and optionally enable `Include user actions`.
- All visuals re-run automatically when filters change.

## Verification

In the workspace’s Logs blade:

```kusto
AzureActivity
| where TimeGenerated > ago(7d)
| summarize Events = count() by SubscriptionId, CategoryValue
| order by Events desc
```

Each monitored subscription should appear with `ResourceHealth` rows. Missing rows mean either `activity-export.bicep` was never deployed there or `ResourceHealth` is not enabled.

## Adding or removing services

Edit the `$services` catalog at the top of [platform/inject-queries.ps1](platform/inject-queries.ps1). Each row defines:

- `code` — value used in the filter
- `name` — friendly label shown in the dropdown
- `RType` — internal type label used in tables
- `token` — Resource Health path token, e.g. `/providers/microsoft.web/sites/`
- `arg` — ARG type, e.g. `microsoft.web/sites`
- `sla` / `basis` — published expected SLA shown in the per-resource table

Re-run the script and redeploy the hub:

```powershell
./platform/inject-queries.ps1
az deployment group create -g $rg -f ./platform/main.bicep -p workspaceName=$workspaceName storageAccountName=$storageAccountName
```

## Multi-subscription / multi-tenant patterns

- For many subscriptions, wrap step 2 in a loop or use Azure Policy `DeployIfNotExists` for `Microsoft.Insights/diagnosticSettings` at management-group scope so newly created subscriptions auto-enroll.
- For multi-tenant, deploy the hub once per tenant; subscription-level enablement and the `Reader` assignment must be repeated in each tenant.

## Notes and limitations

- The workbook reads `AzureActivity` (`ResourceHealth` + optional `Administrative`). It does not require per-resource diagnostic settings.
- Resource Health emits sparsely for some services; the ARG inventory join ensures 100%-healthy resources still appear as `SLA = 100%`.
- `ServiceHealth` (incidents/advisories) is not part of SLA math.
- `inject-queries.ps1` is the single source of truth for the workbook content. Do not hand-edit `workbook-compute-sla.json`.
