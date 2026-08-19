# Specific App Registration — Credential Expiry Monitor

Monitor **specific Azure App Registrations** for expiring client secrets and certificates using Azure Automation, Microsoft Graph, Log Analytics, and Azure Monitor.

## Architecture

```
Azure Automation → Managed Identity → Microsoft Graph → Selected App Registrations
                                                              ↓
                                                    (Secrets & Certificates)
                                                              ↓
                                                      Log Analytics
                                                              ↓
                                                      Azure Monitor
                                                              ↓
                                                       Email Alert
```

## When to Use This Version

Use this when you want to monitor **specific App Registrations** instead of all in the tenant:
- Production-App
- Payment-App
- Customer-API

## Prerequisites

- Azure subscription with resource creation permissions
- Permission to grant Microsoft Graph application permissions
- Email address for notifications
- PowerShell 7 or later
- Azure Portal Cloud Shell (PowerShell)

## Quick Start

### Step 1: Get App Registration Client IDs

1. Go to: **Azure Portal → Microsoft Entra ID → App registrations**
2. Select each App Registration to monitor
3. Copy the **Application (client) ID**

Example: `11111111-1111-1111-1111-111111111111`

### Step 2: Run the Deployment Script

Navigate to `02-Specific-App-Registration` and run:

```powershell
.\AppCredentialExpiryMonitor-SpecificApp.ps1 `
    -TargetApplicationAppIds "11111111-1111-1111-1111-111111111111","22222222-2222-2222-2222-222222222222" `
    -NotificationEmail "you@example.com"
```

**For a single App Registration:**
```powershell
.\AppCredentialExpiryMonitor-SpecificApp.ps1 `
    -TargetApplicationAppIds "11111111-1111-1111-1111-111111111111" `
    -NotificationEmail "you@example.com"
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
| `TargetApplicationAppIds` | No | Empty | Client IDs to monitor |
| `NotificationEmail` | **Yes** | — | Alert recipient |

## Next Steps

- Check **Log Analytics** for detailed logs: **Azure Portal → Log Analytics Workspace → Logs**
- Review automation diagnostic settings output
- Customize the expiry threshold as needed
