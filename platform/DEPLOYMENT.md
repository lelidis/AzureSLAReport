# Azure Compute SLA — Tenant-wide 12-month Self-Service Reporting

End-to-end Azure-native solution. Replaces the local PowerShell script with a
durable, governed pipeline:

| Concern | Approach |
|---|---|
| **Data retention** | Diagnostic Settings → central Log Analytics (400-day retention). |
| **Coverage** | Azure Policy (DeployIfNotExists) on management group → auto-enrolls every existing & future subscription/VM/VMSS. |
| **Self-service UX** | Azure Workbook (interactive, RBAC-gated). |
| **Static distribution** | Storage Static Website refreshed monthly by a Function App. |
| **Compute** | Function App (PowerShell, timer-triggered, consumption plan). |
| **Identity** | System-assigned Managed Identity for the Function; policy MI for remediation. |
| **Cost** | A few €/month at small/medium scale (LA ingest dominates). |

Architecture diagram is in the chat answer above.

---

## Repository layout

```
platform/
├─ main.bicep                       # central RG: LA, Storage, Workbook, Function App
├─ policy-resource-health.bicep     # MG-scoped policy assignment
├─ workbook-compute-sla.json        # serialized workbook template
├─ queries.kql                      # raw KQL (workbook-independent)
└─ function/
   ├─ host.json
   ├─ requirements.psd1
   ├─ profile.ps1
   └─ GenerateSlaReport/
      ├─ function.json              # 0 0 6 1 * *  (1st of month, 06:00 UTC)
      └─ run.ps1
```

---

## Step 1 — Pick the central region & names

```powershell
$tenantId  = (Get-AzContext).Tenant.Id
$mgId      = '<your-management-group-id>'   # e.g. tenant root
$rg        = 'rg-sla-monitoring'
$location  = 'westeurope'
$workspace = 'law-sla-prod'
$storage   = "stslareport$((Get-Random -Minimum 1000 -Maximum 9999))"
```

## Step 2 — Deploy the central platform

```powershell
az group create -n $rg -l $location

az deployment group create -g $rg `
    -f platform/main.bicep `
    -p workspaceName=$workspace `
       storageAccountName=$storage

# Enable static website hosting (Bicep can't toggle this directly)
az storage blob service-properties update `
    --account-name $storage `
    --static-website --index-document index.html `
    --auth-mode login
```

Outputs you'll need next:
- `workspaceId` (full resource ID)
- `staticWebsiteHint` → tells you the public URL `https://<storage>.z6.web.core.windows.net/`

## Step 3 — Deploy the Resource Health policy at management-group scope

```powershell
$workspaceId = az monitor log-analytics workspace show `
    -g $rg -n $workspace --query id -o tsv

az deployment mg create `
    --management-group-id $mgId `
    --location $location `
    -f platform/policy-resource-health.bicep `
    -p workspaceId=$workspaceId
```

Then create a remediation task (one time per assignment):

```powershell
az policy remediation create `
    --name remediate-sla-rh `
    --management-group $mgId `
    --policy-assignment "/providers/Microsoft.Management/managementGroups/$mgId/providers/Microsoft.Authorization/policyAssignments/Send-ResourceHealth-To-LAW"
```

> **Note**: Verify the policy definition GUID in `policy-resource-health.bicep` against the current catalog (`az policy definition list --query "[?contains(displayName,'Resource Health')]"`). Microsoft has shipped several built-in definitions for this; if your tenant's variant is named differently, swap the GUID. For broad coverage, prefer an **initiative** that targets `Microsoft.Compute/virtualMachines` and `Microsoft.Compute/virtualMachineScaleSets`.

## Step 4 — Deploy the Function code

```powershell
# From repo root
Compress-Archive -Path platform/function/* -DestinationPath function.zip -Force
az functionapp deployment source config-zip `
    -g $rg -n <functionAppName> --src function.zip
```

Verify the run after the next monthly trigger or invoke manually:

```powershell
az rest --method post `
    --uri "https://management.azure.com/subscriptions/<sub>/resourceGroups/$rg/providers/Microsoft.Web/sites/<functionAppName>/functions/GenerateSlaReport/invoke?api-version=2022-03-01" `
    --body '{}'
```

## Step 5 — Grant users access

There are two consumer surfaces. Pick either or both.

### A. Azure Workbook (recommended)

Assign on the **resource group** holding the workbook + workspace:

| Role | Purpose |
|---|---|
| `Reader` | List the workbook |
| `Log Analytics Reader` | Run the embedded KQL |
| `Workbook Reader` | View workbook content |

```powershell
az role assignment create --assignee <user-or-group-objectId> `
    --role 'Log Analytics Reader' --scope (az group show -n $rg --query id -o tsv)
az role assignment create --assignee <user-or-group-objectId> `
    --role 'Workbook Reader'      --scope (az group show -n $rg --query id -o tsv)
```

Users open: **Azure Portal → Monitor → Workbooks → "Azure Compute Availability SLA"**.

### B. Static HTML site

The Function publishes `index.html` + monthly CSV/HTML files to `$web`. Two distribution options:

1. **Public** — leave the static website public (already the default for `$web`). Share `https://<storage>.z6.web.core.windows.net/`.
2. **Private** — disable anonymous access on the storage account, put **Azure Front Door + Microsoft Entra auth** in front (template available on request), or use **Azure Storage Browser** with Storage Blob Data Reader role on `$web`.

---

## Step 6 — Schedule, alerts, and cost guardrails

- **Workspace cap**: configure a daily ingestion cap on the LA workspace (`Settings → Daily Cap`) — Resource Health volume is small, but a runaway diagnostic setting could spike.
- **SLA-breach alert**: schedule an Azure Monitor *Log Search Alert* using the per-resource KQL with `| where AvailabilityPct < 99.9` and a 24-hour cadence.
- **Cost expectation** (rough order of magnitude):
  - LA ingestion for ResourceHealth: < 0.5 GB/month per 1,000 VMs.
  - Function App on Y1 (Consumption): pennies per execution, 1× / month.
  - Storage static website + a few MB of HTML/CSV: cents.

---

## How this differs from the local script

| | Local PowerShell script | This solution |
|---|---|---|
| Retention | ~30 days (Resource Health REST limit) | 12+ months (LA workspace) |
| Data freshness | On-demand at runtime | Continuous (real-time ingestion) |
| Audience | Single operator | Any user with RBAC |
| Coverage | Whatever the operator can read | Tenant-wide, governed by policy |
| Reproducibility | Per-run files on a workstation | Versioned, deterministic, signed deployments |
| Identity | Operator's Azure CLI session | Function MI + Policy MI, least-privilege |

The local script (`New-AzComputeSlaReport.ps1`) remains useful for ad-hoc runs and as the source-of-truth for the SLA tier classification logic, which can be ported into a watchlist or KQL function (`_GetSlaTier`) that the workbook joins on.

---

## Roadmap / next steps

- **SLA-tier enrichment**: nightly Function pushes per-VM SLA tier (Zones / AvSet / single-Premium / single-Standard) into a **Log Analytics Watchlist**; workbook joins it for *committed vs measured* coloring tenant-wide.
- **Add storage / network / AKS** SLA panels using the same pattern (`ResourceHealthEvent` already covers them).
- **Export to Power BI** via the Log Analytics connector for executive scorecards.
- **Service health correlation**: join `ServiceHealth` events to attribute downtime to platform vs customer-side causes.
