```markdown name=03-Automated/README.md url=https://github.com/iamaarya/azure-app-registration-credential-monitor/blob/main/03-Automated/README.md
# 03 — Automated

Run from Azure Portal → Cloud Shell → PowerShell:

```powershell
./Deploy-AppCredentialMonitor.ps1
```

This automated deployment configures an Azure monitoring stack that checks Microsoft Entra (Azure AD) App Registration client secrets and certificates and sends an email when credentials approach expiry.

## Quick overview

- Auth: Runbook uses a system-assigned Managed Identity and Microsoft Graph (Application.Read.All).
- Frequency: Daily runbook job that writes findings to Log Analytics; Azure Monitor triggers an alert and sends email via an Action Group.
- Default alert threshold: credentials expiring within 10 days.

## What it creates

- Resource Group
- Log Analytics Workspace
- Azure Automation Account (PowerShell 7.2 runbook)
- System-assigned Managed Identity
- Microsoft Graph permission: Application.Read.All
- Daily schedule, diagnostic settings, Action Group, and Azure Monitor Log Alert

## What it monitors

- Client secrets
- Certificates

## Usage example

```powershell
.\Deploy-AppCredentialMonitor.ps1 `
  -NotificationEmail "admin@contoso.com" `
  -ExpiryThresholdDays 30
```

## Defaults

- Resource Group: rg-app-credential-monitor  
- Location: centralindia  
- Log Analytics: law-app-credential-monitor  
- Automation Account: aa-app-credential-monitor  
- Runbook: AppCredentialExpiryMonitor  
- Schedule: Daily  
- Expiry Threshold: 10 days  
- Alert Severity: 2

## Prerequisites

- Azure subscription and resource creation permissions  
- PowerShell 7+ (recommended Cloud Shell → PowerShell)  
- PowerShell 7.2 runtime available in the Automation Account  
- Required Az modules available to the Automation runtime  
- Verified Azure Monitor email receiver  
- Microsoft Graph permissions (Application.Read.All, AppRoleAssignment.ReadWrite.All)

## Testing & verification

The script starts a test runbook job and verifies the Managed Identity, runtime, runbook, schedule, Action Group, and Azure Monitor alert. After deployment check:
- Automation Account → Jobs  
- Log Analytics → Logs  
- Azure Monitor → Alerts

## Important

This solution detects and alerts on expiring credentials — it does not rotate them automatically.

---
CloudWithAarya
#Azure #MicrosoftEntra #AzureMonitor #Automation #MicrosoftGraph #CloudWithAarya
```

