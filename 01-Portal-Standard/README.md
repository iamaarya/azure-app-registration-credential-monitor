# Azure App Registration Credential Expiry Monitor

Monitors all Azure App Registrations, detects client secrets and certificates approaching expiration, and sends findings to Log Analytics where an Azure Monitor alert can notify by email.

---

## Table of contents
- Architecture
- Prerequisites
- Quick start
- Deployment steps
  - Create Log Analytics workspace
  - Create Automation Account
  - Create the Runbook
  - Grant Microsoft Graph permission
  - Add the Runbook script
  - Save and publish
  - Test the Runbook
  - Configure Automation diagnostics
  - Schedule the Runbook
  - Verify logs in Log Analytics (KQL)
  - Create an Action Group and Alert
  - Test the end-to-end flow
- What this monitors
- Troubleshooting & testing
- Security notes

---

## Architecture

```text
                 Automation Account
                         |
                         v
                PowerShell 7.2
                     Runbook
                         |
                         v
                 Microsoft Graph
                         |
                         v
              ALL App Registrations
                         |
                +--------+--------+
                |                 |
                v                 v
         Client Secrets     Certificates
                |                 |
                +--------+--------+
                         |
                         v
                Expiry Detection
                         |
                         v
               CREDENTIAL_EXPIRING
                         |
                         v
                    JobStreams
                         |
                         v
                 Log Analytics
                         |
                         v
                       KQL
                         |
                         v
                 Azure Monitor
                     Alert
                         |
                         v
                      Email
```

---

## Prerequisites
- An Azure subscription
- Permission to create Azure resources
- Appropriate Microsoft Entra permissions to grant Microsoft Graph application permissions
- An email address for notifications
- Azure Cloud Shell / PowerShell

---

## Quick start
1. Create a Log Analytics workspace.
2. Create an Automation Account with a System Assigned Managed Identity.
3. Create a PowerShell 7.2 runbook that queries Microsoft Graph for applications and their credentials.
4. Grant the managed identity Microsoft Graph Application permission: Application.Read.All.
5. Configure Automation diagnostics to send runbook output to Log Analytics.
6. Add a schedule to run daily (or configure as desired).
7. Create a KQL-based alert and action group to send email notifications.

---

## Deployment steps

### Step 1 — Create Log Analytics workspace
- Azure Portal → Log Analytics workspaces → Create
- Subscription: your subscription  
- Resource group: your monitoring resource group  
- Workspace name: `law-app-credential-monitor`  
- Region: choose your Azure region  
- Review + Create → Create

### Step 2 — Create Automation Account
- Azure Portal → Automation Accounts → Create  
- Subscription: your subscription  
- Resource group: your monitoring resource group  
- Automation account name: `aa-app-credential-monitor`  
- Region: choose your Azure region  
- Under Identity: System assigned = On  
- Review + Create → Create

### Step 3 — Create the Runbook
- Automation Account → Runbooks → Create a runbook  
- Name: `AppCredentialExpiryMonitor`  
- Runbook type: PowerShell  
- Runtime: 7.2  
- Create the runbook

### Step 4 — Grant Microsoft Graph permission (assign Application.Read.All)
The Automation Account's System Assigned Managed Identity (the Runbook identity) must be granted the Microsoft Graph application permission Application.Read.All (Application permission) so the runbook can read all App Registrations.

Follow these steps to grant the permission:

1. In the Azure Portal go to your Automation Account → Identity → System assigned.
2. Copy the Object (principal) ID shown on that page — this is the Managed Identity Object (principal) ID you'll use below.
3. The Runbook managed identity requires the Microsoft Graph Application permission: `Application.Read.All` (Application permission). Do NOT add `AppRoleAssignment.ReadWrite.All` as a permission required by the Runbook — that scope is only needed by an administrator/deployment account when performing the assignment.
4. From an administrator context (for example, using Azure Cloud Shell or PowerShell with an admin account that can grant app role assignments), run the following Microsoft Graph PowerShell script to assign Application.Read.All to the Automation Account Managed Identity.

```powershell
Connect-MgGraph -Scopes "Application.Read.All","AppRoleAssignment.ReadWrite.All"

# UPDATE ONLY THIS VALUE
$ManagedIdentityObjectId = "YOUR-MANAGED-IDENTITY-OBJECT-ID"

# Microsoft Graph App ID
$GraphAppId = "00000003-0000-0000-c000-000000000000"

$ManagedIdentity = Get-MgServicePrincipal `
    -ServicePrincipalId $ManagedIdentityObjectId

$Graph = Get-MgServicePrincipal `
    -Filter "appId eq '$GraphAppId'" `
    -Property AppRoles

$Permission = $Graph.AppRoles |
    Where-Object {
        $_.Value -eq "Application.Read.All" -and
        $_.AllowedMemberTypes -contains "Application"
    }

New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $ManagedIdentity.Id `
    -PrincipalId $ManagedIdentity.Id `
    -ResourceId $Graph.Id `
    -AppRoleId $Permission.Id
```

Important notes:
- Update only `$ManagedIdentityObjectId` with the Object (principal) ID of your Automation Account Managed Identity.
- The `Connect-MgGraph` call in the example includes `AppRoleAssignment.ReadWrite.All` because the administrator performing the assignment must have the ability to add the app role assignment; the runbook itself does not require that permission.
- After you assign `Application.Read.All` (application permission) to the Managed Identity, ensure admin consent is applied at tenant level if required by your tenant policies.

### Step 5 — Add the Runbook script
- Automation Account → Runbooks → `AppCredentialExpiryMonitor` → Edit
- Authenticate using the Automation Account Managed Identity (MSI) and query Microsoft Graph.
- Example: retrieve all applications (paginated)

```powershell
$Applications = @()
$Uri = "https://graph.microsoft.com/v1.0/applications?`$select=id,appId,displayName,passwordCredentials,keyCredentials&`$top=999"

while ($Uri) {
    $Response = Invoke-RestMethod `
        -Method GET `
        -Uri $Uri `
        -Headers $Headers

    $Applications += $Response.value
    $Uri = $Response.'@odata.nextLink'
}
```

- The runbook inspects:
  - `passwordCredentials` (client secrets)
  - `keyCredentials` (certificates)
- Default expiry threshold (recommended): 10 days
- When a credential is within the threshold, the runbook should write a line to output in this format:
  `CREDENTIAL_EXPIRING: {"ApplicationName":"my-app","ApplicationId":"...","CredentialType":"Client Secret","ExpiryDate":"2026-08-25 00:00:00","DaysRemaining":6}`

(Implement the script to compute DaysRemaining and output this exact prefix so KQL can parse it.)

### Step 6 — Save and Publish
- After adding the code: Click Save → Click Publish

### Step 7 — Test the Runbook
- Runbook → Test pane → Start
- Verify:
  - Authenticates using Managed Identity
  - Authenticates to Microsoft Graph
  - Retrieves applications
  - Checks client secrets and certificates
  - Emits `CREDENTIAL_EXPIRING:` lines for expiring credentials

Example test output (console):
```
Microsoft Graph authentication successful.
App Registrations found: 25

CREDENTIAL_EXPIRING:
{"ApplicationName":"my-app","ApplicationId":"...","CredentialType":"Client Secret","ExpiryDate":"...","DaysRemaining":5}
```

### Step 8 — Configure Automation Diagnostics
- Automation Account → Diagnostic settings → Add diagnostic setting
- Enable:
  - JobLogs
  - JobStreams
- Send to: Log Analytics workspace → choose `law-app-credential-monitor`
- Save

This causes runbook output (JobStreams) to flow into AzureDiagnostics in Log Analytics.

### Step 9 — Create the Daily Schedule
- Automation Account → Runbooks → `AppCredentialExpiryMonitor` → Schedules → Add a schedule
- Create schedule:
  - Name: `Daily-AppCredential-Check`
  - Frequency: Recurring
  - Interval: 1 Day
  - Time zone: UTC
- Link the schedule to the runbook

### Step 10 — Verify logs in Log Analytics (KQL)
- Log Analytics → Logs → run this KQL to find emitted credentials:

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where StreamType_s == "Output"
| where ResultDescription startswith "CREDENTIAL_EXPIRING:"
| extend AlertJson = parse_json(
    substring(ResultDescription, strlen("CREDENTIAL_EXPIRING: "))
)
| project
    TimeGenerated,
    ApplicationName = tostring(AlertJson.ApplicationName),
    CredentialType = tostring(AlertJson.CredentialType),
    ExpiryDate = tostring(AlertJson.ExpiryDate),
    DaysRemaining = toint(AlertJson.DaysRemaining),
    ApplicationId = tostring(AlertJson.ApplicationId)
| order by DaysRemaining asc
```

Example KQL results:
```
ApplicationName    CredentialType    DaysRemaining
---------------------------------------------------
my-app              Client Secret       5
another-app         Certificate          8
```

### Step 11 — Create an Email Action Group
- Azure Monitor → Alerts → Action groups → Create
- Add an email notification target
- Example action group name: `ag-app-credential-expiry`

### Step 12 — Create the Azure Monitor Alert
- Azure Monitor → Alerts → Create → Alert rule
- Scope: select the `law-app-credential-monitor` workspace
- Condition: use the KQL from Step 10
  - Measure: Table rows / Count
  - Operator: Greater than
  - Threshold: 0
- Recommended evaluation:
  - Frequency: 5 minutes
  - Lookback window: 15 minutes
- Actions: select `ag-app-credential-expiry`
- Alert details example:
  - Name: `App Registration Credential Expiry`
- Create the alert rule

### Step 13 — Test the Alert (end‑to‑end)
- Create or modify a credential that will expire within your threshold (e.g., 5 days).
- Run the runbook manually or wait for scheduled run.
- Confirm:
  - Runbook emits `CREDENTIAL_EXPIRING` to JobStreams
  - KQL returns a row
  - Alert fires and the action group sends the email

---

## What this method monitors
- All App Registrations accessible to the runbook via Microsoft Graph
  - Client secrets (passwordCredentials)
  - Certificates (keyCredentials)
- No application IDs need to be manually entered

---

## Troubleshooting & tips
- If no results appear in Log Analytics:
  - Confirm Automation diagnostics were configured to send JobStreams
  - Confirm the runbook is publishing the `CREDENTIAL_EXPIRING:` output exactly as shown
  - Check managed identity has Application.Read.All granted and admin consented
- If Graph API calls fail:
  - Validate the runbook obtains a valid access token using the managed identity
  - Inspect detailed runbook job logs in JobLogs/JobStreams for error details
- Pagination: the Graph query must follow `@odata.nextLink` to enumerate all applications

---

## Security notes (important)
- Never store client secrets or certificate private keys in this repository.
- Application (Client) IDs are safe to store; they are identifiers only.
- The runbook uses a System Assigned Managed Identity to avoid embedding credentials.
- Microsoft Graph permission required: Application.Read.All (application permission). Grant and consent at tenant level only after reviewing access policies.

---
