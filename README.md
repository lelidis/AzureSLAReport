# Azure Availability SLA Report

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2F608b261054df7abd8bc45fe8b70d47386c45b902%2Fplatform%2Fmain.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2F608b261054df7abd8bc45fe8b70d47386c45b902%2Fplatform%2FcreateUiDefinition.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg?sanitize=true)](https://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2F608b261054df7abd8bc45fe8b70d47386c45b902%2Fplatform%2Fmain.json)

Self-service Azure Workbook + Bicep platform that produces platform-availability SLA reports across many Azure services from `AzureActivity` Resource Health events, enriched with an Azure Resource Graph (ARG) inventory so even 100%-healthy resources appear.

> **This branch (`enterprise-private`) is the private, no-public-ingress build.** Storage public access and the public `$web` static website are removed; the Function App, Log Analytics workspace, App Insights and Storage are reached only through private endpoints inside a dedicated VNet (Azure Monitor Private Link Scope for the monitoring data). Reports land in a **private blob container** read via Entra ID / RBAC. The one-click "Deploy to Azure" button and `armviz` badges above target the **public** `main` branch and are **not** the path for this architecture — deploy it from the CLI/CI with network line-of-sight to the private endpoints (corporate ExpressRoute/VPN). The Function still needs **outbound** egress to `management.azure.com` (Azure Resource Graph) and `login.microsoftonline.com` (Entra token); neither has Private Link, so allow them via your NAT gateway/firewall.

## What it provides

Two consumer surfaces, fed by the same `AzureActivity` data and the same 49-service catalog:

1. **Interactive Azure Workbook** (live, RBAC-gated, ad-hoc filtering).
2. **Private monthly report** — a timer-triggered Function App renders the same tables to HTML/CSV and writes them to a **private blob container**. Authorized users read them via the Azure Portal Storage browser or Azure Storage Explorer with **`Storage Blob Data Reader`** over the private endpoint (Azure sign-in + RBAC required).

Both surfaces show:

- **Cumulative Uptime - per Region per Month** (pivot by month).
- **Per-resource platform SLA for selected range** with `RType`, `Region`, `ActualSLA`, `ExpectedSLA` (Microsoft published), `SlaBasis`, `UnavailableMinutes`, `PlatformEvents`.
- **Recent events** for the selected period (ResourceHealth + optional Administrative when `Include user actions = true`). *(Workbook only.)*
- 49 supported resource types out of the box (VM/VMSS, App Service, AKS, Container Apps, SQL, SQL MI, Cosmos, Postgres/MySQL Flex, Storage, Key Vault, Redis, Service Bus, Event Hub/Grid, APIM, Logic Apps, SignalR, Web PubSub, Cognitive Services / OpenAI, AI Search, App Gateway, Load Balancer, Public IP, NAT GW, Firewall, Bastion, Front Door, CDN, Traffic Manager, ExpressRoute, VPN/ER GW, DNS / Private DNS, Managed Identity, Static Web Apps, Service Fabric, Batch, Synapse, Data Explorer, Data Factory, Databricks, MariaDB).

The workbook strictly excludes user-initiated actions from SLA math (uses `reasonType`/`cause` and operation-name hygiene) so values reflect platform unavailability only.

## Architecture

- [platform/main.bicep](platform/main.bicep) — Resource group scope. Deploys (all private):
  - Log Analytics workspace (400-day retention by default; public ingestion + query **Disabled**)
  - Application Insights (workspace-based; public access **Disabled**) for Function invocation telemetry
  - Azure Monitor Private Link Scope (**AMPLS**, `PrivateOnly`) scoping the workspace + App Insights
  - Storage account (`publicNetworkAccess=Disabled`, no static website) with a **private `reports` container** for the monthly output
  - VNet `vnet-sla` with a private-endpoint subnet and a subnet delegated to the plan for Function regional VNet integration
  - Private endpoints + private DNS zones for storage (blob/file/queue/table), the Function (`sites`), and AMPLS (`azuremonitor`)
  - Function App (PowerShell 7.4, timer-triggered: `0 0 6 1 * *`, 1st of month 06:00 UTC) on an **Elastic Premium (EP1)** plan with VNet integration, public access **Disabled**, and SCM/FTP basic auth **Disabled**
  - RBAC for the Function managed identity: `Log Analytics Reader` on the workspace, plus `Storage Blob Data Contributor`, `Storage Blob Data Owner`, `Storage Queue Data Contributor` and `Storage Table Data Contributor` on the storage account (the last three are required because the host uses identity-based `AzureWebJobsStorage`)
  - Azure Workbook (queries injected from `workbook-compute-sla.json`)
- [platform/function/](platform/function/) — PowerShell Function App code. `GenerateSlaReport/run.ps1` builds the ARG inventory, computes per-resource and region×month availability, and writes HTML/CSV to the private `reports` container via managed identity. Deployed separately from the template (see step 2 of "After the hub template deploys").
- [platform/activity-export.bicep](platform/activity-export.bicep) — **Subscription scope.** Deploys per monitored subscription:
  - Activity Log diagnostic setting → workspace (`ResourceHealth` + `Administrative`)
  - `Reader` role assignment for the SLA report identity (so ARG inventory works)
- [platform/inject-queries.ps1](platform/inject-queries.ps1) — Generates `workbook-compute-sla.json` from a service catalog. Single source of truth for what the workbook contains.

The workbook JSON contains a placeholder `__WORKSPACE_RESOURCE_ID__` that Bicep replaces at deploy time, so the same file is portable across environments.

## Prerequisites

- Azure CLI 2.55+ with Bicep (`az bicep install`).
- **Network line-of-sight to the private endpoints** for anyone deploying the Function code, reading the report, or opening the workbook (run from a host on the VNet, or via ExpressRoute/VPN/peering that can reach `vnet-sla`). The default `10.50.0.0/24` address space must not overlap your existing networks — override `vnetAddressPrefix`/`privateEndpointSubnetPrefix`/`functionSubnetPrefix` if it does.
- **Outbound egress** from the Function subnet to `management.azure.com` and `login.microsoftonline.com` (ARG + Entra token have no Private Link). Provide it via a NAT gateway or allow these FQDNs through your firewall.
- Permission to deploy at:
  - Resource group scope in the “hub” subscription that hosts the workspace and workbook.
  - Subscription scope in every subscription you want monitored (Owner or User Access Administrator + Monitoring Contributor).
- The principal opening the workbook needs `Reader` on each monitored subscription. The `activity-export` module assigns this automatically when given the principal’s object id.
- **The Function App's managed identity also needs `Reader` on every subscription it reports on** — it calls Azure Resource Graph (`Search-AzGraph`) to inventory resources for the 100% backfill. Because `main.bicep` is resource-group scoped it cannot create this subscription-level assignment; grant it after the hub deploys (step 3 below). The simplest path is to pass the Function's `functionAppPrincipalId` as the `readerPrincipalId` to `activity-export.bicep`, which covers both the workbook reader and the Function in one assignment.

## Deployment

> On this `enterprise-private` branch, prefer **Option B (ARM JSON)** or **Option C (Bicep)** from a host with line-of-sight to the target VNet. The portal **Option A** button can still *create* the resources, but everything it deploys is private — you will need VNet connectivity (and the post-deploy steps) before you can publish code or read a report.

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
- `reportsContainer` — the private blob container the report is written to
- `reportBlobPathHint` — how to read the private report
- `vnetId` — the VNet hosting the private endpoints
- `workbookResourceId` — open this in the portal

## After the hub template deploys (required for all options)

The template provisions the infrastructure but does **not** push the Function code, grant report readers their RBAC, or grant the Function the subscription access it needs for the inventory. Run these steps once after deploying.

> **All of the steps below must run from a host with network line-of-sight to `vnet-sla`'s private endpoints** (a VM/agent on the VNet, or your workstation over ExpressRoute/VPN). Because the Function App, storage and workspace have public access disabled, commands that touch their data/SCM planes from the public internet will fail.

> **Set `$rg` to the resource group you actually deployed into.** `rg-sla-monitoring` is only an example. With the portal button (Option A) you pick or create the RG in the form, so it may be anything (e.g. `rg-slareport08`). With Options B/C it's the name you passed to `az group create`. If you set the wrong name here, the next commands fail with `ResourceGroupNotFound` even though a group exists — the name simply doesn't match.

> **Make sure the CLI is pointed at the subscription you deployed into.** The portal shows resources across *all* your subscriptions, but `az` only operates on the **active** one. If you deployed via the button into a different subscription, `az functionapp list -g <rg>` returns `ResourceGroupNotFound` (or shows a *previous* deployment) until you switch context:
>
> ```powershell
> az account set --subscription <subscriptionId-or-name>
> az account show --query "{name:name, id:id}" -o table   # confirm
> ```

If you're not sure which subscription/group/Function App was created, list across every subscription you can see:

```powershell
# Every SLA Function App in every subscription you have access to
az graph query -q "resources | where type =~ 'microsoft.web/sites' and name startswith 'func-sla' | project name, resourceGroup, subscriptionId" -o table

# (fallback if the resource-graph CLI extension isn't installed)
az functionapp list --query "[?starts_with(name,'func-sla')].{name:name, rg:resourceGroup}" -o table
```

Then set the variables from that output (and the deployment outputs):

```powershell
$rg = '<your resource group>'                  # e.g. rg-sla-monitoring or rg-slareport08
$functionAppName = az functionapp list -g $rg --query "[0].name" -o tsv
$storageAccount  = az storage account list -g $rg --query "[0].name" -o tsv
$functionPrincipalId = az functionapp identity show -g $rg -n $functionAppName --query principalId -o tsv

# Sanity check — all three should print a value
$rg; $functionAppName; $storageAccount; $functionPrincipalId
```

### Step 1 — Grant report readers `Storage Blob Data Reader`

There is no public website. People read the report from the private `reports` container, which requires a data-plane role. Grant it to the user/group that should see reports:

```powershell
$readerObjectId = az ad signed-in-user show --query id -o tsv   # or a group/user objectId
$storageId = az storage account show -g $rg -n $storageAccount --query id -o tsv

az role assignment create `
  --assignee-object-id $readerObjectId `
  --assignee-principal-type User `
  --role "Storage Blob Data Reader" `
  --scope $storageId
```

### Step 2 — Deploy the Function code (private)

The template deploys the empty Function App. Because public access and SCM basic auth are disabled, publish the PowerShell code (`run.ps1`, `function.json`, `host.json`, `profile.ps1`, `requirements.psd1`) over the **private** plane. Build the archive so `host.json` sits at the **root** of the zip.

> **Run these from the repo root** (the folder containing `platform/`). The `./platform/...` paths are relative, so if you're elsewhere you'll get `path '...\platform' either does not exist or is not a valid file system path`. `cd` into your clone first:
>
> ```powershell
> cd <path-to-your-clone>   # e.g. C:\Users\<you>\Desktop\AzureSlaReport
> ```

```powershell
Compress-Archive -Path ./platform/function/* -DestinationPath ./platform/function-deploy.zip -Force
```

**Recommended — Run From Package from the private container (no SCM, no keys).** Upload the zip to a private blob the Function MI can read, then point the app at it. The MI already has `Storage Blob Data Owner/Contributor` from the template.

```powershell
# Upload the package to a private 'deploy' container (created on first use)
az storage container create --account-name $storageAccount -n deploy --auth-mode login -o none
az storage blob upload --account-name $storageAccount -c deploy `
  -n function-deploy.zip -f ./platform/function-deploy.zip --auth-mode login --overwrite -o none

# Point the app at the package via its (private) blob endpoint and restart
$pkgUrl = "https://$storageAccount.blob.$((az cloud show --query suffixes.storageEndpoint -o tsv))/deploy/function-deploy.zip"
az functionapp config appsettings set -g $rg -n $functionAppName `
  --settings WEBSITE_RUN_FROM_PACKAGE=$pkgUrl -o none
az functionapp restart -g $rg -n $functionAppName
```

> The Function pulls the package over its VNet integration using its managed identity — no shared keys and nothing leaves the private network. Re-upload the blob and `restart` to ship updates.
>
> **Alternative:** run `az functionapp deployment source config-zip -g $rg -n $functionAppName --src ./platform/function-deploy.zip` from a build agent/jumpbox **on the VNet**; the SCM private endpoint accepts an Entra bearer token, so it works even with basic auth disabled.

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
# Run from a host on the VNet (the function endpoint is private):
$key = az functionapp keys list -g $rg -n $functionAppName --query masterKey -o tsv
Invoke-RestMethod -Method Post `
  -Uri "https://$functionAppName.azurewebsites.net/admin/functions/GenerateSlaReport" `
  -Headers @{ 'x-functions-key' = $key } -ContentType 'application/json' -Body '{}'
```

Then open the latest `index.html` from the private `reports` container (Portal → the storage account → **Storage browser** → **Blob containers** → `reports`, or Azure Storage Explorer) — the page shows the `Generated` timestamp and the resource count.

## Per-subscription enablement (applies to all deployment options)

Run for each subscription you want included in the report. `readerPrincipalId` is the identity that opens the workbook (a user, group, or the `functionAppPrincipalId` for unattended use).

The portal currently does not support subscription-scope deployments through "Deploy to Azure" buttons, so use the CLI for this step.

Common setup for both options below:

```powershell
$workspaceId = '<output from step 1: workspaceId>'
$readerPrincipalId = '<objectId of user/group/SP>'   # or $functionPrincipalId for unattended use
$location = 'westeurope'
```

### Option 1 — Specific subscriptions

List only the subscriptions you want to monitor:

```powershell
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

### Option 2 — All existing subscriptions

Enumerate every enabled subscription you have access to and enroll them all. This also auto-includes any subscription added later when you re-run it:

```powershell
# All enabled subscriptions in the current tenant you can access
$subs = az account list --query "[?state=='Enabled'].id" -o tsv

foreach ($sub in $subs) {
  Write-Host "Enrolling subscription $sub ..."
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

> Notes:
> - `az account list` only returns subscriptions in tenants you're signed into. For multi-tenant, sign in per tenant (`az login --tenant <tenantId>`) and re-run.
> - You need permission to deploy at subscription scope (Owner or Contributor + User Access Administrator) in **each** subscription; any you lack rights on will error and can be skipped.
> - To also pull subscriptions across tenants/management groups in one shot, use `az account management-group` enumeration or the Azure Policy pattern in "Multi-subscription / multi-tenant patterns" below for hands-off auto-enrollment of future subscriptions.

For users/groups, set `principalType=User` or `principalType=Group`.

## Use the report

**Interactive workbook:**

- Portal → Monitor → Workbooks → "Azure Compute Availability SLA" (in the hub RG).
- Pick `Date range`, one or more `Resource types`, and optionally enable `Include user actions`.
- All visuals re-run automatically when filters change.

**Private monthly report:**

- In the Azure Portal, open the storage account → **Storage browser** → **Blob containers** → `reports` (or use Azure Storage Explorer). Requires `Storage Blob Data Reader` (Step 1) and network access to the private endpoint.
- `index.html` is the latest report; per-month `AzSla_<yyyy-MM>.html`, `AzSla_<yyyy-MM>.csv`, and `AzSla_RegionMatrix_<yyyy-MM>.csv` are also written. Download an `.html` and open it locally, or preview it inline from the Storage browser.

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
