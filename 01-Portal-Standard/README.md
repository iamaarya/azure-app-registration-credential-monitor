# Azure App Registration Credential Expiry Monitor

## Option 1 — Azure Portal Deployment

This method monitors **all Azure App Registrations** and detects client secrets and certificates that are approaching expiration.

The detected credentials are sent to Log Analytics, where an Azure Monitor alert can trigger an email notification.

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

Prerequisites
You need:
An Azure subscription
Permission to create Azure resources
Permission to grant Microsoft Graph application permissions
An email address for notifications
Step 1 — Create Log Analytics Workspace
Go to:
Azure Portal → Log Analytics workspaces → Create
Configure:
Subscription: Your subscription
Resource Group: Your monitoring resource group
Workspace Name: law-app-credential-monitor
Region: Your Azure region
Click:
Review + Create → Create
Step 2 — Create Automation Account
Go to:
Azure Portal → Automation Accounts → Create
Configure:
Subscription: Your subscription
Resource Group: Your monitoring resource group
Automation Account: aa-app-credential-monitor
Region: Your Azure region
Under Identity:
System assigned: On
Click:
Review + Create → Create
Step 3 — Create the Runbook
Open:
Automation Account → Runbooks → Create a runbook
Configure:
Name:           AppCredentialExpiryMonitor
Runbook type:   PowerShell
Runtime:        7.2
Create the Runbook.
Step 4 — Grant Microsoft Graph Permission
The Automation Account uses its System Assigned Managed Identity to access Microsoft Graph.
Grant the Managed Identity:
Microsoft Graph
    Application permission
        Application.Read.All
This allows the Runbook to read App Registrations and their credentials.
The Runbook does not need the client secrets themselves. It only reads credential metadata such as expiration dates.
Step 5 — Add the Runbook Script
Open:
Automation Account → Runbooks → AppCredentialExpiryMonitor → Edit
The Runbook should authenticate using the Automation Account Managed Identity and query Microsoft Graph.
For the all-application monitoring approach, the Runbook retrieves all App Registrations:
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
The Runbook checks:
Client secrets
Certificates
The default expiry threshold is:
10 days
When a credential is approaching expiration, the Runbook writes:
CREDENTIAL_EXPIRING: {JSON}
Example:
CREDENTIAL_EXPIRING: {"ApplicationName":"my-app","ApplicationId":"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx","CredentialType":"Client Secret","ExpiryDate":"2026-08-25 00:00:00","DaysRemaining":6}
Step 6 — Save and Publish
After adding the Runbook code:
Click Save
Click Publish
The Runbook is now ready to execute.
Step 7 — Test the Runbook
Open:
Runbook → Test pane → Start
Verify that the Runbook:
Authenticates using the Managed Identity
Authenticates to Microsoft Graph
Retrieves App Registrations
Checks client secrets
Checks certificates
Detects credentials approaching expiration
Example output:
Microsoft Graph authentication successful.

App Registrations found: 25

CREDENTIAL_EXPIRING:
{"ApplicationName":"my-app",
 "ApplicationId":"...",
 "CredentialType":"Client Secret",
 "ExpiryDate":"...",
 "DaysRemaining":5}
Step 8 — Configure Automation Diagnostics
Go to:
Automation Account → Diagnostic settings
Create a diagnostic setting.
Enable:
JobLogs
JobStreams
Select:
Send to Log Analytics workspace
Choose:
law-app-credential-monitor
Click Save.
This sends the Automation Runbook output to Log Analytics.
Step 9 — Create the Daily Schedule
Go to:
Automation Account → Runbooks → AppCredentialExpiryMonitor → Schedules
Click:
Add a schedule
Create:
Name:       Daily-AppCredential-Check
Frequency:  Recurring
Interval:   1 Day
Time zone:  UTC
Link the schedule to:
AppCredentialExpiryMonitor
Step 10 — Verify Logs in Log Analytics
Go to:
Log Analytics Workspace → Logs
Run:
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where StreamType_s == "Output"
| where ResultDescription startswith "CREDENTIAL_EXPIRING:"
| extend AlertJson = parse_json(
    substring(
        ResultDescription,
        strlen("CREDENTIAL_EXPIRING: ")
    )
)
| project
    TimeGenerated,
    ApplicationName = tostring(AlertJson.ApplicationName),
    CredentialType = tostring(AlertJson.CredentialType),
    ExpiryDate = tostring(AlertJson.ExpiryDate),
    DaysRemaining = toint(AlertJson.DaysRemaining),
    ApplicationId = tostring(AlertJson.ApplicationId)
| order by DaysRemaining asc
The query returns credentials detected by the Runbook.
Example:
ApplicationName    CredentialType    DaysRemaining
---------------------------------------------------
my-app              Client Secret       5
another-app         Certificate          8
Step 11 — Create an Email Action Group
Go to:
Azure Monitor → Alerts → Action groups → Create
Configure an email notification.
Example:
Action Group:
ag-app-credential-expiry
Add the email address that should receive credential expiry notifications.
Step 12 — Create the Azure Monitor Alert
Go to:
Azure Monitor → Alerts → Create → Alert rule
Scope
Select:
law-app-credential-monitor
Condition
Use the KQL from Step 10.
Configure:
Measure:      Table rows / Count
Operator:     Greater than
Threshold:    0
Recommended evaluation:
Evaluation frequency: 5 minutes
Lookback window:      15 minutes
Actions
Select:
ag-app-credential-expiry
Alert details
Example:
Alert name:
App Registration Credential Expiry
Create the alert.
Step 13 — Test the Alert
For testing, use a credential that expires within the configured threshold.
For example:
Expiry Threshold: 10 days
Credential expiry: 5 days
Run the Runbook manually.
Verify the complete flow:
Runbook
   |
   v
Microsoft Graph
   |
   v
App Registration
   |
   v
Credential Expiry Detected
   |
   v
CREDENTIAL_EXPIRING
   |
   v
Automation JobStreams
   |
   v
Log Analytics
   |
   v
KQL returns a row
   |
   v
Azure Monitor Alert
   |
   v
Email Notification
What This Method Monitors
This version automatically discovers all App Registrations accessible to the Runbook through Microsoft Graph.
It checks:
App Registrations
    |
    +-- Client Secrets
    |
    +-- Certificates
No Application IDs need to be manually entered.
Important Security Notes
Never store client secrets in this repository.
Never store certificate private keys in this repository.
Application (Client) IDs are identifiers and are safe to use for configuration.
The Runbook uses a System Assigned Managed Identity.
Microsoft Graph Application.Read.All is used to read application and credential metadata.
