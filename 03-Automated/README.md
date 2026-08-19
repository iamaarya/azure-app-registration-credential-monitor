# 03 — Automated

Run this from Azure Portal → Cloud Shell → PowerShell.

```powershell
./Deploy-AppCredentialMonitor.ps1
```

The automated solution creates/configures the monitoring stack and starts a test job. It can also accept target application parameters when you want the automated deployment to monitor a specific App Registration.

There is intentionally no separate automated-specific folder.
