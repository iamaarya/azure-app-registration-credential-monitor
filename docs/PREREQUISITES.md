# Prerequisites

- Azure Portal → Cloud Shell → PowerShell.
- PowerShell 7+.
- Azure permissions for Resource Group, Log Analytics, Automation, Runbook, Schedule, Diagnostics, Action Group and Azure Monitor alert creation/update.
- Automation managed identity: Graph `Application.Read.All` application permission.
- Deployment operator: `Application.Read.All` + `AppRoleAssignment.ReadWrite.All` with appropriate consent/role.
- Existing Automation **PowerShell 7.2** Runtime Environment.
- Az modules required by the Runbook available to the runtime.
- Azure Monitor email receiver verification.
- Dedicated test App Registration.
- No SendGrid.
