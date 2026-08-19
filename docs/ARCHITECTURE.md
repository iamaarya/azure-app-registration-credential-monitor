# Architecture

```text
Azure Automation
      ↓
System-assigned Managed Identity
      ↓
Microsoft Graph
      ↓
All App Registrations OR one target App ID
      ↓
Secrets + Certificates
      ↓
Expiry threshold
      ↓
CREDENTIAL_EXPIRING JSON
      ↓
JobStreams → Log Analytics
      ↓
Azure Monitor Log Alert
      ↓
Action Group → Email
```
