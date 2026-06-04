# Azure Availability SLA Report

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2F608b261054df7abd8bc45fe8b70d47386c45b902%2Fplatform%2Fmain.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2F608b261054df7abd8bc45fe8b70d47386c45b902%2Fplatform%2FcreateUiDefinition.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg?sanitize=true)](https://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2F608b261054df7abd8bc45fe8b70d47386c45b902%2Fplatform%2Fmain.json)

Self-service Azure Workbook + Bicep platform that produces platform-availability SLA reports across many Azure services from `AzureActivity` Resource Health events, enriched with an Azure Resource Graph (ARG) inventory so even 100%-healthy resources appear.

## What it provides

Two consumer surfaces, fed by the same `AzureActivity` data and the same 49-service catalog:

1. **Interactive Azure Workbook** (live, RBAC-gated, ad-hoc filtering).
2. **Static monthly report** — a timer-triggered Function App renders the same tables to HTML/CSV and publishes them to the storage account's `$web` static website (no Azure sign-in needed to read).

Both surfaces show:

- **Cumulative Uptime - per Region per Month** (pivot by month).
- **Per-resource platform SLA for selected range** with `RType`, `Region`, `ActualSLA`, `ExpectedSLA` (Microsoft published), `SlaBasis`, `UnavailableMinutes`, `PlatformEvents`.
- **Recent events** for the selected period (ResourceHealth + optional Administrative when `Include user actions = true`). *(Workbook only.)*
- 49 supported resource types out of the box (VM/VMSS, App Service, AKS, Container Apps, SQL, SQL MI, Cosmos, Postgres/MySQL Flex, Storage, Key Vault, Redis, Service Bus, Event Hub/Grid, APIM, Logic Apps, SignalR, Web PubSub, Cognitive Services / OpenAI, AI Search, App Gateway, Load Balancer, Public IP, NAT GW, Firewall, Bastion, Front Door, CDN, Traffic Manager, ExpressRoute, VPN/ER GW, DNS / Private DNS, Managed Identity, Static Web Apps, Service Fabric, Batch, Synapse, Data Explorer, Data Factory, Databricks, MariaDB).

The workbook strictly excludes user-initiated actions from SLA math (uses `reasonType`/`cause` and operation-name hygiene) so values reflect platform unavailability only.

## Architecture

- [platform/main.bicep](platform/main.bicep) — Resource group scope. Deploys:
  - Log Analytics workspace (400-day retention by default)
  - Storage account (hosts the `$web` static website for the monthly report)
  - Application Insights (workspace-based) for Function invocation telemetry
  - Function App (PowerShell 7.4, timer-triggered: `0 0 6 1 * *`, 1st of month 06:00 UTC) + Consumption (Y1) plan
  - RBAC for the Function managed identity: `Log Analytics Reader` on the workspace, plus `Storage Blob Data Contributor`, `Storage Blob Data Owner`, `Storage Queue Data Contributor` and `Storage Table Data Contributor` on the storage account (the last three are required because the host uses identity-based `AzureWebJobsStorage`)
  - Azure Workbook (queries injected from `workbook-compute-sla.json`)
- [platform/function/](platform/function/) — PowerShell Function App code. `GenerateSlaReport/run.ps1` builds the ARG inventory, computes per-resource and region×month availability, and uploads HTML/CSV to `$web`. Deployed separately from the template (see step 2 of "After the hub template deploys").
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
- **The Function App's managed identity also needs `Reader` on every subscription it reports on** — it calls Azure Resource Graph (`Search-AzGraph`) to inventory resources for the 100% backfill. Because `main.bicep` is resource-group scoped it cannot create this subscription-level assignment; grant it after the hub deploys (step 3 below). The simplest path is to pass the Function's `functionAppPrincipalId` as the `readerPrincipalId` to `activity-export.bicep`, which covers both the workbook reader and the Function in one assignment.

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
- `storageAccount` — name of the storage account hosting the report
- `workbookResourceId` — open this in the portal

## After the hub template deploys (required for all options)

The template (button, ARM, or Bicep) provisions the infrastructure but does **not** turn on the static website, push the Function code, or grant the Function the subscription access it needs for the inventory. Run these three steps once after any of Option A/B/C.

Set these from the deployment outputs first:

```powershell
$rg = 'rg-sla-monitoring'
$storageAccount = '<output: storageAccount>'
$functionAppName = az functionapp list -g $rg --query "[0].name" -o tsv
$functionPrincipalId = '<output: functionAppPrincipalId>'
```

### Step 1 — Enable static website hosting

Bicep cannot toggle the static-website feature, so enable it once:

```powershell
az storage blob service-properties update `
  --account-name $storageAccount `
  --static-website --index-document index.html `
  --auth-mode login
```

The public report URL is then `https://<storageAccount>.z6.web.core.windows.net/`.

### Step 2 — Deploy the Function code

The template deploys the empty Function App; publish the PowerShell code (`run.ps1`, `function.json`, `host.json`, `profile.ps1`, `requirements.psd1`) with a zip push. Build the archive so `host.json` sits at the **root** of the zip:

```powershell
Compress-Archive -Path ./platform/function/* -DestinationPath ./platform/function-deploy.zip -Force

az functionapp deployment source config-zip `
  -g $rg -n $functionAppName --src ./platform/function-deploy.zip
```

> If your tenant disables SCM basic auth (recommended), zip deploy needs it briefly. Enable it, deploy, then disable again:
> ```powershell
> az resource update -g $rg --namespace Microsoft.Web --parent sites/$functionAppName `
>   --resource-type basicPublishingCredentialsPolicies -n scm --set properties.allow=true -o none
> # ... run the config-zip command above ...
> az resource update -g $rg --namespace Microsoft.Web --parent sites/$functionAppName `
>   --resource-type basicPublishingCredentialsPolicies -n scm --set properties.allow=false -o none
> ```

### Step 3 — Grant the Function identity `Reader` on each reported subscription

The Function calls Azure Resource Graph to inventory resources for the 100% backfill, which requires `Reader`. This is the same `readerPrincipalId` used in the per-subscription enablement below — pass `$functionPrincipalId` there to cover it in one shot, or grant it directly:

```powershell
az role assignment create `
  --assignee-object-id $functionPrincipalId `
  --assignee-principal-type ServicePrincipal `
  --role Reader `
  --scope /subscriptions/<subscriptionId>
```

### Step 4 — (Optional) Trigger a run now

The Function runs automatically on the 1st of each month. To produce a report immediately:

```powershell
$key = az functionapp keys list -g $rg -n $functionAppName --query masterKey -o tsv
Invoke-RestMethod -Method Post `
  -Uri "https://$functionAppName.azurewebsites.net/admin/functions/GenerateSlaReport" `
  -Headers @{ 'x-functions-key' = $key } -ContentType 'application/json' -Body '{}'
```

Then open `https://$storageAccount.z6.web.core.windows.net/` — the page shows the `Generated` timestamp and the resource count.

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

## Use the report

**Interactive workbook:**

- Portal → Monitor → Workbooks → "Azure Compute Availability SLA" (in the hub RG).
- Pick `Date range`, one or more `Resource types`, and optionally enable `Include user actions`.
- All visuals re-run automatically when filters change.

**Static monthly report:**

- Open `https://<storageAccount>.z6.web.core.windows.net/` (refreshed on the 1st of each month, or on demand via Step 4 above).
- `index.html` is the latest report; per-month `AzSla_<yyyy-MM>.html`, `AzSla_<yyyy-MM>.csv`, and `AzSla_RegionMatrix_<yyyy-MM>.csv` are also published.

## Verification

In the workspace’s Logs blade:

```kusto
AzureActivity
| where TimeGenerated > ago(7d)
| summarize Events = count() by SubscriptionId, CategoryValue
| order by Events desc
```

Each monitored subscription should appear with `ResourceHealth` rows. Missing rows mean either `activity-export.bicep` was never deployed there or `ResourceHealth` is not enabled.

To confirm the Function ran, check its telemetry in Application Insights (`appi-sla-prod`):

```kusto
AppTraces
| where TimeGenerated > ago(1d)
| where Message has 'Reporting month' or Message has 'Inventory resources' or Message has 'Report published'
| order by TimeGenerated desc
```

If `Inventory resources ... : 0`, the Function identity is missing `Reader` on the subscription (step 3) or there are genuinely no matching resources.

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

The static report uses an equivalent `$services` catalog embedded in [platform/function/GenerateSlaReport/run.ps1](platform/function/GenerateSlaReport/run.ps1). Keep the two lists in sync, then redeploy the Function code (step 2 in "After the hub template deploys") so the HTML/CSV report matches the workbook.

## Multi-subscription / multi-tenant patterns

- For many subscriptions, wrap step 2 in a loop or use Azure Policy `DeployIfNotExists` for `Microsoft.Insights/diagnosticSettings` at management-group scope so newly created subscriptions auto-enroll.
- For multi-tenant, deploy the hub once per tenant; subscription-level enablement and the `Reader` assignment must be repeated in each tenant.

## Notes and limitations

- The workbook reads `AzureActivity` (`ResourceHealth` + optional `Administrative`). It does not require per-resource diagnostic settings.
- Resource Health emits sparsely for some services; the ARG inventory join ensures 100%-healthy resources still appear as `SLA = 100%`.
- `ServiceHealth` (incidents/advisories) is not part of SLA math.
- `inject-queries.ps1` is the single source of truth for the workbook content. Do not hand-edit `workbook-compute-sla.json`.
