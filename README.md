# Azure App Registration Credential Expiry Monitor

Monitor Azure App Registration client secrets and certificates before they expire.

**Notifications:** Azure Monitor Action Group → Email  
**SendGrid:** Not used.

## Video Structure

```text
1. Portal / Standard
       ↓
2. Specific App Registration
       ↓
3. Automated
```

## Architecture

```text
                  Microsoft Entra ID
                 App Registrations
                        │
                        ▼
                Azure Automation
                PowerShell Runbook
                        │
                 System Identity
                        │
                        ▼
                 Microsoft Graph
                        │
           ┌────────────┴────────────┐
           │                         │
      ALL applications        Specific application
           │                         │
           └────────────┬────────────┘
                        ▼
               Expiry threshold check
                        │
                        ▼
               CREDENTIAL_EXPIRING
                        │
                        ▼
                Automation JobStreams
                        │
                        ▼
                 Log Analytics
                        │
                        ▼
                Azure Monitor Alert
                        │
                        ▼
                  Action Group
                        │
                        ▼
                       Email
```

## Prerequisites

Recommended execution: **Azure Portal → Cloud Shell → PowerShell**. Viewers do not need to install PowerShell, Azure CLI, or Microsoft Graph locally.

They need an Azure subscription, permission to create/update the required Azure resources, appropriate Microsoft Entra/Graph privileges, a notification email, and a PowerShell 7.2 Runtime Environment in Automation.

The Automation Account system-assigned managed identity needs Microsoft Graph **Application.Read.All** application permission. Admin consent may be required.

Azure Monitor Action Group email is used. **No SendGrid.** The email receiver must be verified.

## Important terminology

This monitors an **Entra App Registration**, not the Azure App Service resource itself. For a web application, use the App Registration's **Application (client) ID**.

## Video flow

### 1 — Portal / Standard
Monitor all App Registrations.

### 2 — Specific App Registration
Target one App Registration using its Application (client) ID. The alerting pipeline remains the same.

### 3 — Automated
Create the monitoring solution automatically. The automated script can also accept a target App Registration, so there is no separate fourth folder.

## Cloud Shell

```powershell
git clone <YOUR-GITHUB-REPOSITORY-URL>
cd azure-app-registration-credential-monitor
cd 03-Automated
./Deploy-AppCredentialMonitor.ps1
```

## Repository

```text
azure-app-registration-credential-monitor/
│
├── README.md
│
├── 01-Portal-Standard/
│   ├── README.md
│   ├── AppCredentialExpiryMonitor.ps1
│   └── credential-expiry-alert.kql
│
├── 02-Specific-App-Registration/
│   ├── README.md
│   ├── AppCredentialExpiryMonitor-SpecificApp.ps1
│   └── credential-expiry-alert-specific.kql
│
├── 03-Automated/
│   ├── README.md
│   └── Deploy-AppCredentialMonitor.ps1
│
└── docs/
    ├── PREREQUISITES.md
    ├── ARCHITECTURE.md
    ├── VIDEO-FLOW.md
    └── REVIEW-NOTES.md
```
