# Azure Availability SLA Report

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2Fa3b8b29054352c13dc2d36e945eac354f713ac52%2Fplatform%2Fmain.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2Fa3b8b29054352c13dc2d36e945eac354f713ac52%2Fplatform%2FcreateUiDefinition.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg?sanitize=true)](https://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2Fa3b8b29054352c13dc2d36e945eac354f713ac52%2Fplatform%2Fmain.json)

Self-service Azure Workbook + Bicep platform that produces platform-availability SLA reports across many Azure services from `AzureActivity` Resource Health events, enriched with an Azure Resource Graph (ARG) inventory so even 100%-healthy resources appear.

> **This branch (`enterprise-private`) is the private, keyless build.** Every data path goes over a private endpoint: the Function App runs on **Flex Consumption** with a managed identity, Storage has public access **and** shared keys disabled, and Log Analytics / Application Insights / the data collection endpoint are reached through an Azure Monitor Private Link Scope. Reports land in a **private blob container** read via Entra ID / RBAC. The only flow that cannot use a private endpoint is the Function's Azure Resource Graph call to `management.azure.com`: it leaves through a NAT gateway and an NSG that allows **only** the `AzureResourceManager` service tag (see [Network and data flows](#network-and-data-flows)).
>
> The badges above are pinned to this branch's reviewed template (commit `a3b8b29`), so the **Deploy to Azure** button now provisions the *private* stack — but it only **creates the infrastructure**. Whichever deploy option you pick, you must then run the **post-deploy steps** ([After the hub template deploys](#after-the-hub-template-deploys-required-for-all-options)) from a host that can reach the new VNet's private endpoints (a VM/agent on the VNet, or your workstation over ExpressRoute/VPN).

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
  - Log Analytics workspace (400-day retention by default; public ingestion + query **Disabled**) with the custom table `SlaInventory_CL` (daily resource-inventory snapshot, 30-day retention)
  - Application Insights (workspace-based; public access **Disabled**) for Function invocation telemetry
  - Azure Monitor Private Link Scope (**AMPLS**, `PrivateOnly`) scoping the workspace, App Insights and a data collection endpoint (`dce-sla`, public access **Disabled**) with the data collection rule `dcr-sla-inventory` used by the Logs Ingestion API
  - Storage account: `publicNetworkAccess=Disabled`, **shared-key access disabled**, no static website; a private `reports` container (monthly output) and an `app-package` container (Function code)
  - VNet `vnet-sla` with a private-endpoint subnet and a subnet delegated to `Microsoft.App/environments` for Function VNet integration. The Function subnet has no default outbound access and carries an NSG (`nsg-sla-functions`: allow TCP 443 to `AzureResourceManager`, deny every other internet destination) and a NAT gateway (`nat-sla`, optional via `deployNatGateway`)
  - Private endpoints + private DNS zones for storage (blob/queue/table), the Function (`sites`), and AMPLS (`azuremonitor`)
  - Function App on a **Flex Consumption** plan (Linux, PowerShell 7.6) with two timer functions, `RefreshInventory` (daily, `0 30 2 * * *`) and `GenerateSlaReport` (`0 0 6 1 * *`, 1st of month 06:00 UTC); public access **Disabled**, a system-assigned identity and no connection strings
  - RBAC for the Function identity: `Log Analytics Reader` on the workspace, `Monitoring Metrics Publisher` on the data collection rule, plus `Storage Blob Data Owner`, `Storage Queue Data Contributor` and `Storage Table Data Contributor` on the storage account (the Functions host and the code package use the identity)
  - Azure Workbook (queries injected from `workbook-compute-sla.json`)
  - Optional: reuse your own VNet, Azure Monitor Private Link Scope and private DNS zones (also from other subscriptions) instead of creating them — see [Use an existing network, Private Link scope and private DNS zones](#use-an-existing-network-private-link-scope-and-private-dns-zones)
- [platform/ampls-link.bicep](platform/ampls-link.bicep) — Small module used by `main.bicep` to add the workspace, App Insights and the data collection endpoint to the Private Link scope. A module so the scope can live in another resource group or subscription. — PowerShell Function App code: `host.json`, `Shared/SlaCommon.ps1` (managed-identity REST helpers, the 49-service catalog and the Azure Resource Graph inventory), `RefreshInventory/` and `GenerateSlaReport/`. Both functions are pure REST with the managed identity (no Az modules). `RefreshInventory` writes the Resource Graph inventory to `SlaInventory_CL`; `GenerateSlaReport` reads the events through the Log Analytics query API, computes per-resource and region×month availability, and writes HTML/CSV to the private `reports` container. Deployed separately from the template (see step 2 of "After the hub template deploys").
- [platform/activity-export.bicep](platform/activity-export.bicep) — **Subscription scope.** Deploys per monitored subscription:
  - Activity Log diagnostic setting → workspace (`ResourceHealth` + `Administrative`)
  - `Reader` role assignment for the SLA report identity (so the Azure Resource Graph inventory works)
- [platform/inject-queries.ps1](platform/inject-queries.ps1) — Generates `workbook-compute-sla.json` from a service catalog. Single source of truth for what the workbook contains.

The workbook JSON contains a placeholder `__WORKSPACE_RESOURCE_ID__` that Bicep replaces at deploy time, so the same file is portable across environments.

## Network and data flows

Every flow stays on the Microsoft backbone and, wherever a private endpoint exists, uses it. No shared keys or connection strings are involved, and the only flow that leaves the VNet is the Azure Resource Graph call to Azure Resource Manager.

| Flow | Path | Private |
| --- | --- | --- |
| Activity Log → workspace | Diagnostic setting over Microsoft's private channel (not affected by the disabled public ingestion setting) | Yes |
| Function → Log Analytics query API (Resource Health events) | AMPLS private endpoint (`privatelink.monitor.azure.com`) | Yes |
| Function → `SlaInventory_CL` (daily inventory snapshot, Logs Ingestion API) | Data collection endpoint inside the AMPLS (same private endpoint) | Yes |
| Function → Application Insights | AMPLS private endpoint | Yes |
| Function → Storage (report upload, host state, code package) | Private endpoints for blob, queue and table | Yes |
| Function → Entra token | Local platform endpoint (`IDENTITY_ENDPOINT`); nothing leaves the VNet | Yes |
| Code deployment / admin | Function `sites` private endpoint | Yes |
| Readers → report container and workbook | Storage + AMPLS private endpoints, reached over your corporate network | Yes |
| Function → Azure Resource Graph inventory (`management.azure.com`) | Azure Resource Manager has no private endpoint, so this one flow uses the NAT gateway. The NSG allows only TCP 443 to the `AzureResourceManager` service tag and denies every other internet destination | **No** — metadata only (resource IDs, types, locations) |

Design choices that follow from this:

- **Flex Consumption instead of Elastic Premium.** EP1 needs an Azure Files content share, which only supports shared keys. Flex keeps host state and the code package in blob storage under the managed identity, so shared-key access is disabled on the account. It also scales to zero.
- **REST instead of Az modules.** Managed dependencies download from powershellgallery.com and an Az sign-in calls `management.azure.com`. The Functions call the Log Analytics, Logs Ingestion, Blob and Resource Graph REST APIs directly with the identity token, so there is nothing to download and the only destination outside the VNet is Azure Resource Manager.
- **No ARM Private Link.** It can only be applied at the root management group (tenant-wide), is not supported by AKS and breaks Azure Bastion, so the template does not depend on it and uses the NAT gateway + NSG path above instead. If your tenant already uses ARM Private Link, or you route egress through a hub firewall, deploy with `deployNatGateway=false` and make sure `management.azure.com` stays reachable from `snet-functions` (keep the NSG rule for `AzureResourceManager`).
- **The inventory is a workspace table, not `arg('')`.** Verified on a Private Link workspace: a Log Analytics query that contains `arg("")` fails with HTTP 400 `The Azure Data Explorer (ADX) pattern cannot be used with Private Link`. Neither the workbook nor the report therefore calls `arg()`. The `RefreshInventory` Function reads the inventory from Azure Resource Graph once a day and writes it through the Logs Ingestion API (data collection endpoint inside the AMPLS) to `SlaInventory_CL`; the workbook joins that table, and the monthly report reads Resource Graph directly. A resource created after the last snapshot (02:30 UTC) appears in the workbook the next day.

### Verify private connectivity

From a host on the VNet (or connected over VPN/ExpressRoute):

```powershell
nslookup <storageAccount>.blob.core.windows.net   # expect a private address from your VNet range (default 10.50.0.0/24)
nslookup api.loganalytics.azure.com               # expect a private address as well
nslookup management.azure.com                     # expect a PUBLIC address (the one flow without a private endpoint)
./platform/Test-SlaPlatform.ps1 -ResourceGroup $rg -WorkspaceName <workspaceName>
```

After step 4 below has loaded the inventory, run this once in the workspace's **Logs** blade. It proves the table the workbook reads is filled:

```kusto
SlaInventory_CL
| summarize Resources = count(), Snapshot = max(TimeGenerated)
```

## Prerequisites

- Azure CLI 2.55+ with Bicep (`az bicep install`).
- The `Microsoft.App` resource provider registered (`az provider register -n Microsoft.App`) and a region that supports Flex Consumption (`az functionapp list-flexconsumption-locations -o table`).
- **Network line-of-sight to the private endpoints** for anyone deploying the Function code, reading the report, or opening the workbook (run from a host on the VNet, or via ExpressRoute/VPN/peering that can reach `vnet-sla`). The default `10.50.0.0/24` address space must not overlap your existing networks — override `vnetAddressPrefix`/`privateEndpointSubnetPrefix`/`functionSubnetPrefix` if it does, or [use your existing network](#use-an-existing-network-private-link-scope-and-private-dns-zones).
- **Outbound HTTPS to `management.azure.com` — nothing else.** The Function reads the resource inventory from Azure Resource Graph. The template provides that path: a NAT gateway (fixed hourly charge, see the Azure pricing page) plus an NSG that allows only the `AzureResourceManager` service tag and blocks every other internet destination. If you route egress through your own firewall or use ARM Private Link, deploy with `deployNatGateway=false`.
- Permission to deploy at:
  - Resource group scope in the “hub” subscription that hosts the workspace and workbook.
  - Subscription scope in every subscription you want monitored (Owner or User Access Administrator + Monitoring Contributor).
- The principal opening the workbook needs `Reader` on each monitored subscription. The `activity-export` module assigns this automatically when given the principal’s object id.
- **The Function App's managed identity also needs `Reader` on every subscription it reports on** — the inventory comes from Azure Resource Graph, which evaluates the caller's permissions. Because `main.bicep` is resource-group scoped it cannot create this subscription-level assignment; grant it after the hub deploys (step 3 below). The simplest path is to pass the Function's `functionAppPrincipalId` as the `readerPrincipalId` to `activity-export.bicep`, which covers both the workbook reader and the Function in one assignment.

## Deployment

Every deployment of this branch follows the **same three phases**. The only choice is *how you create the infrastructure* in Phase 1; Phases 2 and 3 are identical and mandatory because the stack is private.

- **Phase 1 — Create the private infrastructure.** Pick **one** option: [Option A (portal button)](#option-a--deploy-to-azure-portal-form), [Option B (ARM JSON)](#option-b--arm-json-via-azure-cli), or [Option C (Bicep)](#option-c--bicep-source-of-truth). All three create the same resources; the deploy command itself is control-plane only and can run from anywhere.
- **Phase 2 — Finish the setup** ([After the hub template deploys](#after-the-hub-template-deploys-required-for-all-options)). Steps 1–4: grant readers RBAC, deploy the Function code, grant the Function `Reader`, and load the inventory (plus an optional report run). **Run these from a host with VNet access** — steps 2 and 4 reach the private Function endpoint (steps 1 and 3 are role assignments and run from anywhere).
- **Phase 3 — Enroll subscriptions** ([Per-subscription enablement](#per-subscription-enablement-applies-to-all-deployment-options)). Turn on Activity Log export for each subscription you want reported.

> **“VNet access”** means the machine running the command can reach `vnet-sla`'s private endpoints — a VM/build agent on that VNet, or your workstation over ExpressRoute/VPN/peering. The storage data plane and the Function SCM/admin plane are **not** reachable from the public internet on this branch.

### Phase 1 — create the infrastructure (choose one option)

All three options below create the **same private resources**. They differ only in tooling.

| Option | Tooling needed | Best for |
| --- | --- | --- |
| A — Portal “Deploy to Azure” button | Browser only | Quick provisioning; you still finish from a VNet-connected host |
| B — ARM JSON via Azure CLI | `az` | Users without Bicep installed |
| C — Bicep via Azure CLI | `az` + Bicep | CI/CD, this repo's source of truth |

### Option A — Deploy to Azure (portal form)

Click the button at the top of this README, or use this direct link (pinned to this branch's reviewed commit):

> https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2Fa3b8b29054352c13dc2d36e945eac354f713ac52%2Fplatform%2Fmain.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Flelidis%2FAzureSLAReport%2Fa3b8b29054352c13dc2d36e945eac354f713ac52%2Fplatform%2FcreateUiDefinition.json

The form prompts for subscription, resource group, location, workspace name, retention, storage account name and whether to create the NAT gateway for the Azure Resource Graph call (keep it checked unless you route that egress through your own firewall). The Function App and plan names use the template defaults. The VNet, subnets, private endpoints, AMPLS and private DNS use the template defaults (`10.50.0.0/24` address space) — review the [Prerequisites](#prerequisites) if that range clashes with your network, and in that case use Option B/C so you can override `vnetAddressPrefix`/`privateEndpointSubnetPrefix`/`functionSubnetPrefix`. The portal form cannot reuse an existing VNet, Private Link scope or private DNS zones either: for that, use Option B/C with the [existing-resources parameters](#use-an-existing-network-private-link-scope-and-private-dns-zones).

> The button only **creates** the (private) resources. You cannot read a report from the portal form — once it finishes, continue with Phase 2 from a host that can reach the VNet. The button references [platform/main.json](platform/main.json) and [platform/createUiDefinition.json](platform/createUiDefinition.json) over `raw.githubusercontent.com`, so the repo and those two files must remain public.

If you fork this repo, swap `lelidis/AzureSLAReport/a3b8b29054352c13dc2d36e945eac354f713ac52` in the URL above for `<owner>/<repo>/<branch-or-commit>`.

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

The CLI deployment itself works from anywhere (it is control-plane only). You still need VNet access for the post-deploy steps. If you change `main.bicep` or the workbook, recompile before deploying:

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
- `vnetId` — the VNet hosting the private endpoints (`vnet-sla`, or the VNet of your existing Function subnet)
- `amplsResourceId` — the Private Link scope in use (`ampls-sla`, or your existing scope)
- `inventoryTable` / `dataCollectionRuleId` — the workspace table the workbook reads and the rule the Function writes it through
- `workbookResourceId` — open this in the portal

Add `--parameters deployNatGateway=false` to the command above if you provide the egress to `management.azure.com` yourself (hub firewall or ARM Private Link).

## Use an existing network, Private Link scope and private DNS zones

By default the template creates its own VNet (`vnet-sla`), Azure Monitor Private Link Scope and private DNS zones. If you already run a hub network, a central Private Link scope or central private DNS zones, in any resource group or **subscription**, point the template at them instead. The three parts are independent: use any combination. They are template parameters rather than portal-form fields, so deploy with [Option B or C](#phase-1--create-the-infrastructure-choose-one-option) and a parameters file. Phase 2 and Phase 3 are unchanged.

| Parameter | Default | Effect |
| --- | --- | --- |
| `existingPrivateEndpointSubnetId` and `existingFunctionSubnetId` | empty | Use these subnets (resource IDs) instead of creating `vnet-sla`. **Set both.** No VNet, NSG or NAT gateway is created and neither subnet is modified. |
| `existingAmplsResourceId` | empty | Add the workspace, Application Insights and the data collection endpoint to this Private Link scope. No scope and no scope private endpoint are created. |
| `existingPrivateDnsZoneIds` | `{}` | Resource IDs of existing private DNS zones, keyed as in the table below. A listed zone is used as is; every zone you leave out is created in the resource group and linked to the Function's VNet. |
| `createPrivateDnsZoneGroups` | `true` | Set `false` when DNS records come from Azure Policy or central automation: no zones, links or zone groups are created and the private endpoints get no DNS records from this template. |

| `existingPrivateDnsZoneIds` key | Private DNS zone | Used by |
| --- | --- | --- |
| `blob`, `queue`, `table` | `privatelink.blob.core.windows.net`, `privatelink.queue.core.windows.net`, `privatelink.table.core.windows.net` | Storage private endpoints |
| `sites` | `privatelink.azurewebsites.net` | Function private endpoint |
| `monitor`, `oms`, `ods`, `agentsvc` | `privatelink.monitor.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.agentsvc.azure-automation.net` | Private endpoint of a scope this template creates (not needed with `existingAmplsResourceId`) |

Example parameters file (all three parts; save as `byo.parameters.json`):

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "workspaceName": { "value": "law-sla-prod" },
    "storageAccountName": { "value": "stslareportprod" },
    "existingPrivateEndpointSubnetId": { "value": "/subscriptions/<netSub>/resourceGroups/<netRg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<peSubnet>" },
    "existingFunctionSubnetId": { "value": "/subscriptions/<netSub>/resourceGroups/<netRg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<functionSubnet>" },
    "existingAmplsResourceId": { "value": "/subscriptions/<monSub>/resourceGroups/<monRg>/providers/Microsoft.Insights/privateLinkScopes/<scope>" },
    "existingPrivateDnsZoneIds": {
      "value": {
        "blob": "/subscriptions/<dnsSub>/resourceGroups/<dnsRg>/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net",
        "queue": "/subscriptions/<dnsSub>/resourceGroups/<dnsRg>/providers/Microsoft.Network/privateDnsZones/privatelink.queue.core.windows.net",
        "table": "/subscriptions/<dnsSub>/resourceGroups/<dnsRg>/providers/Microsoft.Network/privateDnsZones/privatelink.table.core.windows.net",
        "sites": "/subscriptions/<dnsSub>/resourceGroups/<dnsRg>/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net"
      }
    }
  }
}
```

```powershell
az deployment group create -g $rg -f ./platform/main.json -p '@byo.parameters.json'
```

**What must already be true**

- *Existing subnets.* Both are in the Function's region (the resource group's location unless you set `location`). The Function subnet is delegated to `Microsoft.App/environments`, is `/27` or larger and is used by nothing else. The template does not change it, so **you provide its egress**: outbound TCP 443 to `management.azure.com` (the Azure Resource Graph call) through a NAT gateway, your firewall/UDR or ARM Private Link; the NSG and NAT gateway of the default build are not created. Any NSG on the private endpoint subnet must allow inbound 443 from the Function subnet.
- *Existing Private Link scope.* Its private endpoint, with working DNS for the Function's VNet, already exists: this template creates none in this mode, and a VNet can connect to only one scope. The workspace, Application Insights and data collection endpoint are created with public access disabled, so they are reachable only through that endpoint. They are added as scoped resources named `scoped-<workspace>-<suffix>`, `scoped-appi-sla-<suffix>` and `scoped-dce-sla-<suffix>`; the suffix is unique per resource group, so several deployments can share one scope.
- *Existing private DNS zones.* Each zone you pass already resolves from the Function's VNet (linked to it, or reached through your DNS forwarders). The template only writes the private endpoint records into it through a zone group; it never links or changes an existing zone. Zones you leave out are created and linked to the Function's VNet.

**Permissions for the identity that runs the deployment**, in addition to the usual deployment rights on the target resource group:

| Resource | Permission |
| --- | --- |
| Existing subnets | `Microsoft.Network/virtualNetworks/subnets/join/action` on both (included in *Network Contributor*) |
| Existing private DNS zones | `Microsoft.Network/privateDnsZones/join/action` and permission to write the private endpoint records, for example *Private DNS Zone Contributor*, on each zone you pass |
| VNet, when the template creates and links zones | `Microsoft.Network/virtualNetworks/join/action` on the VNet |
| Existing Private Link scope | `Microsoft.Insights/privateLinkScopes/scopedResources/write` plus `Microsoft.Resources/deployments/write` in the scope's resource group (*Contributor* there is enough): the template runs a small nested deployment in that group |

`Test-SlaPlatform.ps1` understands these deployments: it expects 4 private endpoints (5 when the template creates the scope) and reports the Function subnet check as `SKIP` if it cannot read a subnet in another subscription.

## After the hub template deploys (required for all options)

The template provisions the infrastructure but does **not** push the Function code, grant report readers their RBAC, or grant the Function the subscription access it needs for the inventory. Run these steps once after deploying.

> **Steps 2 and 4 must run from a host with network line-of-sight to `vnet-sla`'s private endpoints** (a VM/agent on the VNet, or your workstation over ExpressRoute/VPN): the Function's deployment and admin endpoints are private. Steps 1 and 3 are Azure role assignments and run from anywhere.

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

The template deploys the empty Function App. Flex Consumption deploys a zip package through the app's deployment endpoint (`<app>.scm.azurewebsites.net`), which is reachable only over the private endpoint, so run this from a host with VNet access. You need `Contributor` (or `Website Contributor`) on the Function App. The package contains only `host.json`, `Shared/`, `RefreshInventory/` and `GenerateSlaReport/` — no modules to bundle and nothing to download at runtime.

> **Run these from the repo root** (the folder containing `platform/`). The `./platform/...` paths are relative, so if you're elsewhere you'll get `path '...\platform' either does not exist or is not a valid file system path`. `cd` into your clone first:
>
> ```powershell
> cd <path-to-your-clone>   # e.g. C:\Users\<you>\Desktop\AzureSlaReport
> ```

```powershell
Compress-Archive -Path ./platform/function/* -DestinationPath ./platform/function-deploy.zip -Force

az functionapp deployment source config-zip `
  -g $rg -n $functionAppName --src ./platform/function-deploy.zip
```

The zip must have `host.json` at its **root** (the command above does that). If the deployment cannot reach the endpoint, check that `nslookup $functionAppName.scm.azurewebsites.net` returns a private address from your VNet range.

### Step 3 — Grant the Function identity `Reader` on each reported subscription

The Function queries the resource inventory through Azure Resource Graph, which requires `Reader`. This is the same `readerPrincipalId` used in the per-subscription enablement below — pass `$functionPrincipalId` there to cover it in one shot, or grant it directly:

```powershell
az role assignment create `
  --assignee-object-id $functionPrincipalId `
  --assignee-principal-type ServicePrincipal `
  --role Reader `
  --scope /subscriptions/<subscriptionId>
```

### Step 4 — Load the inventory (and optionally trigger a report now)

Two timer functions run automatically: `RefreshInventory` daily at 02:30 UTC and `GenerateSlaReport` on the 1st of each month. Run them once now so the workbook has an inventory and you can see a report immediately:

```powershell
# Run from a host on the VNet (the function endpoint is private):
$key = az functionapp keys list -g $rg -n $functionAppName --query masterKey -o tsv
$headers = @{ 'x-functions-key' = $key }

# 1) Inventory snapshot for the workbook (Azure Resource Graph -> SlaInventory_CL)
Invoke-RestMethod -Method Post -Headers $headers -ContentType 'application/json' -Body '{}' `
  -Uri "https://$functionAppName.azurewebsites.net/admin/functions/RefreshInventory"

# 2) Optional: produce the monthly report now
Invoke-RestMethod -Method Post -Headers $headers -ContentType 'application/json' -Body '{}' `
  -Uri "https://$functionAppName.azurewebsites.net/admin/functions/GenerateSlaReport"
```

Both calls return immediately (HTTP 202) and run in the background. The first inventory rows reach `SlaInventory_CL` after a few minutes (about 5 minutes on a fresh workspace); until then the workbook lists no resources. Then open the latest `index.html` from the private `reports` container (Portal → the storage account → **Storage browser** → **Blob containers** → `reports`, or Azure Storage Explorer) — the page shows the `Generated` timestamp and the resource count.

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
| where Message has 'Reporting month' or Message has 'Inventory' or Message has 'Report published'
| order by TimeGenerated desc
```

If `Inventory resources ... : 0`, the Function identity is missing `Reader` on the subscription (step 3) or there are genuinely no matching resources. A successful `RefreshInventory` run logs `Inventory snapshot ... ingested: <n> resources`, and the same rows are in the workspace:

```kusto
SlaInventory_CL
| summarize Resources = count(), Snapshot = max(TimeGenerated) by Region
```

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Run fails with `Inventory through Azure Resource Graph failed` | The call to `management.azure.com` failed. Check the Function identity has `Reader` on the subscriptions. A timeout means the Function has no route to Azure Resource Manager: confirm the NAT gateway (`nat-sla`) is attached to `snet-functions` and `nsg-sla-functions` still allows TCP 443 to `AzureResourceManager`, or provide the equivalent egress if you deployed with `deployNatGateway=false`. |
| Workbook lists no resources / `SlaInventory_CL` is empty | Run `RefreshInventory` once (step 4) and wait a few minutes. If its log shows an ingestion error, check that the Function identity has `Monitoring Metrics Publisher` on `dcr-sla-inventory` (role propagation can take minutes) and that `dce-sla` is scoped in the AMPLS. |
| A query fails with `The Azure Data Explorer (ADX) pattern cannot be used with Private Link` | The query uses `arg()` or `adx()`, which Log Analytics blocks over Private Link. Read the inventory from `SlaInventory_CL` instead (this is why the workbook does not call `arg()`). |
| `403` or `AuthorizationPermissionMismatch` writing the report | The Function identity is missing `Storage Blob Data Owner` on the storage account (the template assigns it; role propagation can take a few minutes). |
| Deployment command cannot connect | The host is not on the VNet or cannot resolve the private DNS zone. Verify with `nslookup $functionAppName.scm.azurewebsites.net`. |
| Workbook or Logs blade shows connection errors in the portal | Your browser must reach the AMPLS private endpoint over your corporate network. Allow local network access for the portal in Edge/Chrome if prompted. |
| `AuthorizationFailed` on `.../subnets/join/action`, `.../privateDnsZones/join/action` or `.../virtualNetworks/join/action` | The deploying identity lacks join permission on the existing subnet, private DNS zone or VNet. Grant it on that resource (for example *Network Contributor* on the subnet, *Private DNS Zone Contributor* on the zone) and redeploy. |
| The nested deployment `ampls-link-*` fails with `AuthorizationFailed` | Adding a scoped resource to an existing Private Link scope needs `Microsoft.Insights/privateLinkScopes/scopedResources/write` and `Microsoft.Resources/deployments/write` in the scope's resource group. |
| Storage, the Function or Log Analytics resolve to public addresses and calls fail | With an existing private DNS zone, the zone is not linked to (or resolvable from) the Function's VNet. Link it or forward it to your resolver; the template never links an existing zone. |
| With an existing VNet, a run fails with a timeout toward `management.azure.com` | The existing Function subnet has no outbound path to Azure Resource Manager on TCP 443. Add a NAT gateway, a firewall route or ARM Private Link to that subnet. |

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

The Functions use an equivalent catalog (`$script:ServiceCatalog`) in [platform/function/Shared/SlaCommon.ps1](platform/function/Shared/SlaCommon.ps1). Keep the two lists in sync, then redeploy the Function code (step 2 in "After the hub template deploys") so the inventory table and the HTML/CSV report match the workbook.

## Multi-subscription / multi-tenant patterns

- For many subscriptions, wrap step 2 in a loop or use Azure Policy `DeployIfNotExists` for `Microsoft.Insights/diagnosticSettings` at management-group scope so newly created subscriptions auto-enroll.
- For multi-tenant, deploy the hub once per tenant; subscription-level enablement and the `Reader` assignment must be repeated in each tenant.

## Remove the deployment

1. For every enrolled subscription, delete the Activity Log export and the Function's `Reader` assignment:

   ```powershell
   az monitor diagnostic-settings subscription delete --name to-sla-workspace --yes
   az role assignment delete --assignee $functionPrincipalId --role Reader --scope /subscriptions/<subscriptionId>
   ```

2. Delete the resource group: `az group delete -n $rg --yes`. The Flex Consumption app releases its subnet asynchronously, so the virtual network (and the NAT gateway) can take a few minutes to disappear.
3. A deleted workspace stays recoverable for 14 days. To remove it immediately, unlink it from the AMPLS first and then delete it with `--force`; a workspace that is still scoped in an AMPLS cannot be force-deleted:

   ```powershell
   az monitor private-link-scope scoped-resource delete -g $rg --scope-name ampls-sla -n scoped-<workspaceName> --yes
   az monitor log-analytics workspace delete -g $rg -n <workspaceName> --force true --yes
   ```

   With `existingAmplsResourceId`, the three scoped resources live in your scope, not in `$rg`. List and delete them there first:

   ```powershell
   az monitor private-link-scope scoped-resource list -g <scopeRg> --scope-name <scope> --subscription <scopeSub> --query "[?contains(lower(linkedResourceId), '/resourcegroups/$($rg.ToLower())/')].name" -o tsv
   az monitor private-link-scope scoped-resource delete -g <scopeRg> --scope-name <scope> --subscription <scopeSub> -n <name> --yes
   ```

## Notes and limitations

- The workbook reads `AzureActivity` (`ResourceHealth` + optional `Administrative`). It does not require per-resource diagnostic settings.
- Resource Health emits sparsely for some services; the inventory (Azure Resource Graph snapshot) ensures 100%-healthy resources still appear as `SLA = 100%`.
- `ServiceHealth` (incidents/advisories) is not part of SLA math.
- `inject-queries.ps1` is the single source of truth for the workbook content. Do not hand-edit `workbook-compute-sla.json`.
