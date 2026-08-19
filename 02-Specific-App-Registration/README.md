# App Registration — Credential Expiry Monitor (Automation Variables Edition)

Monitor Azure App Registrations for expiring client secrets and certificates using Azure Automation, Microsoft Graph, Log Analytics, and Azure Monitor.

This version reads its configuration — which apps to watch, the expiry threshold, and the alert email — from **Azure Automation Variables** instead of script parameters. That means the daily schedule runs itself with no manual input, and you can change what it monitors at any time from the Portal without re-running the deployment.

## Architecture

```
Azure Automation → Managed Identity → Microsoft Graph → App Registrations
      ↑                                                       ↓
Automation Variables                                (Secrets & Certificates)
(targets, threshold, email)                                   ↓
                                                        Log Analytics
                                                                ↓
                                                        Azure Monitor
                                                                ↓
                                                         Email Alert
```

## How Configuration Works Now

| | Old (parameters) | This version (variables) |
|---|---|---|
| Daily schedule | Needed target IDs baked into the schedule | Runbook reads targets itself — schedule needs nothing |
| Change targets/threshold | Edit script, re-run deployment | Edit **Automation Account → Variables**, save |
| One-off manual run with different settings | Pass parameters | Still works — parameters override variables for that run only |

The deployment script seeds four Automation Variables on first run and keeps them updated if you re-run it:

- `TargetApplicationAppIdsJson` — JSON array of App IDs to monitor (empty = monitor **all** apps in the tenant)
- `TargetApplicationDisplayNamesJson` — optional, JSON array of display names as an alternative to App IDs
- `ExpiryThresholdDays` — days-before-expiry to alert on
- `NotificationEmail` — alert recipient

## Prerequisites

- Azure subscription with resource creation permissions
- Permission to grant Microsoft Graph application permissions
- PowerShell 7 or later
- Azure Portal Cloud Shell (PowerShell)
- An existing PowerShell 7.2 Runtime Environment in the target Automation Account

## Quick Start

### Option A — Run it bare (fastest)

```powershell
./AppCredentialExpiryMonitor-SpecificApp.ps1
```

You'll only be prompted for one thing: your notification email. Everything else uses defaults:

- **Expiry threshold:** 10 days
- **Target apps:** none specified → monitors **every** App Registration in the tenant

This gets the whole pipeline (resource group, workspace, automation account, runbook, schedule, alert) stood up immediately. Narrow the scope afterward — see [Adding Variables After Deployment](#adding-variables-after-deployment) below.

### Option B — Run it with values upfront

```powershell
./AppCredentialExpiryMonitor-SpecificApp.ps1 `
    -NotificationEmail "you@example.com" `
    -ExpiryThresholdDays 15 `
    -TargetApplicationAppIds "11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222"
```

Any values you pass here are written straight into the Automation Variables during deployment.

## Adding Variables After Deployment

If you ran it bare (Option A) or just want to change something later, no re-run is needed:

1. **Azure Portal → Automation Account → Variables**
2. Edit the value you want to change:
   - `TargetApplicationAppIdsJson` — paste a JSON array of App IDs, e.g. `["11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222"]`
   - `ExpiryThresholdDays` — change `10` to whatever number you want
   - `NotificationEmail` — update the recipient
3. **Save**

The next scheduled run (or any manual run without parameters) picks up the new value automatically. Nothing else needs to change.

### Where to get App Registration Client IDs

1. **Azure Portal → Microsoft Entra ID → App registrations**
2. Select the app to monitor
3. Copy the **Application (client) ID**, e.g. `11111111-1111-1111-1111-111111111111`

## What Gets Created

- Resource Group
- Log Analytics Workspace
- Azure Automation Account with System Assigned Managed Identity
- Automation Variables (`TargetApplicationAppIdsJson`, `TargetApplicationDisplayNamesJson`, `ExpiryThresholdDays`, `NotificationEmail`)
- Runbook (PowerShell 7.2)
- Daily automation schedule (no parameters attached — reads variables)
- Automation diagnostic settings → Log Analytics
- Email Action Group
- Azure Monitor Log Alert

## How It Works

1. Runbook authenticates via Managed Identity
2. If no parameters were supplied for the run, it reads `TargetApplicationAppIdsJson`, `TargetApplicationDisplayNamesJson`, and `ExpiryThresholdDays` from Automation Variables
3. Queries Microsoft Graph — filtered by Client IDs/display names if any are set, otherwise all apps in the tenant
4. Checks client secrets (`passwordCredentials`) and certificates (`keyCredentials`)
5. Sends structured output to Log Analytics
6. Azure Monitor alert triggers on the `CREDENTIAL_EXPIRING:` pattern (aggregated with `AlertCount > 0` to avoid false positives)
7. Email notification sent to the address in `NotificationEmail`

## Verification

After deployment:

1. **Azure Portal → Automation Account → Jobs** — check the test job output
2. If you scoped to specific apps, expected output includes a line like:
   `Target filter applied: (appId eq '...')`
   If you ran bare with no targets, you'll instead see the full count of App Registrations found tenant-wide
3. **Automation Account → Variables** — confirm all four variables are present and correctly valued

## Alert Output

For each expiring credential, you'll see:

- Application name
- Application ID
- Credential type (Secret/Certificate)
- Expiry date
- Days remaining

## Security Notes

✅ Uses **System Assigned Managed Identity** (no stored secrets)
✅ Grants **Microsoft Graph Application.Read.All** only
✅ Automation Variables are plain (unencrypted) by default — do not store secrets in them, only App IDs, names, thresholds, and email addresses
✅ Never commit real credentials or secrets to this repository

## Parameters (deployment script — used only to seed/update variables)

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `ResourceGroupName` | No | `rg-app-credential-monitor` | Resource group name |
| `Location` | No | `centralindia` | Azure region |
| `WorkspaceName` | No | `law-app-credential-monitor` | Log Analytics workspace |
| `AutomationAccountName` | No | `aa-app-credential-monitor` | Automation Account name |
| `RunbookName` | No | `AppCredentialExpiryMonitor` | Runbook name |
| `ScheduleName` | No | `Daily-AppCredential-Check` | Schedule name |
| `ExpiryThresholdDays` | No | `10` | Threshold for alerts |
| `TargetApplicationAppIds` | No | Empty (monitors all apps) | Client IDs to monitor |
| `TargetApplicationDisplayNames` | No | Empty | Display names to monitor, alternative to App IDs |
| `NotificationEmail` | Prompted if not passed | — | Alert recipient |

## Re-running the Script

The script is safe to re-run. Every resource check is "does this already exist?" first — re-running updates the Automation Variables and republishes the runbook in place rather than creating duplicates.

## Next Steps

- Check **Log Analytics** for detailed logs: **Azure Portal → Log Analytics Workspace → Logs**
- Review automation diagnostic settings output
- Narrow monitoring scope or adjust the threshold any time via **Automation Account → Variables** — no redeploy required    -NotificationEmail "you@example.com"
```

**With custom expiry threshold (default: 10 days):**
```powershell
.\AppCredentialExpiryMonitor-SpecificApp.ps1 `
    -TargetApplicationAppIds "11111111-1111-1111-1111-111111111111" `
    -ExpiryThresholdDays 30 `
    -NotificationEmail "you@example.com"
```

## What Gets Created

- Resource Group
- Log Analytics Workspace
- Azure Automation Account with System Assigned Managed Identity
- Runbook (PowerShell 7.2)
- Daily automation schedule
- Email Action Group
- Azure Monitor Log Alert

## How It Works

1. Runbook authenticates via Managed Identity
2. Queries Microsoft Graph (filtered by Client IDs only)
3. Checks client secrets (`passwordCredentials`) and certificates (`keyCredentials`)
4. Sends output to Log Analytics
5. Azure Monitor alert triggers on `CREDENTIAL_EXPIRING:` pattern
6. Email notification sent to configured address

## Verification

After deployment:
1. Go to: **Azure Portal → Automation Account → Jobs**
2. Check the test job output
3. Expected output shows: `Target filter applied: (appId eq '...')`

## Alert Output

For each expiring credential, you'll see:
- Application name
- Application ID
- Credential type (Secret/Certificate)
- Expiry date
- Days remaining

## Security Notes

✅ Uses **System Assigned Managed Identity** (no stored secrets)  
✅ Grants **Microsoft Graph Application.Read.All** only  
✅ Never commit real credentials or secrets to this repository  

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `ResourceGroupName` | No | `rg-app-credential-monitor` | Resource group name |
| `Location` | No | `centralindia` | Azure region |
| `WorkspaceName` | No | `law-app-credential-monitor` | Log Analytics workspace |
| `AutomationAccountName` | No | `aa-app-credential-monitor` | Automation Account name |
| `RunbookName` | No | `AppCredentialExpiryMonitor` | Runbook name |
| `ScheduleName` | No | `Daily-AppCredential-Check` | Schedule name |
| `ExpiryThresholdDays` | No | `10` | Threshold for alerts |
| `TargetApplicationAppIds` | Yes | Empty | Client IDs to monitor |
| `NotificationEmail` | **Yes** | — | Alert recipient |

## Next Steps

- Check **Log Analytics** for detailed logs: **Azure Portal → Log Analytics Workspace → Logs**
- Review automation diagnostic settings output
- Customize the expiry threshold as needed
