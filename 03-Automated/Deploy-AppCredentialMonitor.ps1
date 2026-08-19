#Requires -Version 7.0
# PREREQUISITES
# - Recommended: Azure Portal -> Cloud Shell -> PowerShell.
# - PowerShell 7+ is required.
# - Az / Microsoft.Graph modules are installed or loaded by the deployment script.
# - Signed-in identity needs Azure rights to create/update the solution resources.
# - Deployment operator needs sufficient Graph consent/privileges for Application.Read.All
#   and AppRoleAssignment.ReadWrite.All to assign Application.Read.All to the managed identity.
# - Automation Account must have an existing PowerShell 7.2 Runtime Environment.
# - Required Az modules must be available to the Runbook runtime.
# - Azure Monitor email receiver must be verified.

<#
===============================================================
 Azure App Registration Credential Expiry Monitor
 AUTOMATIC DEPLOYMENT

 Recommended execution:
 Azure Portal -> Cloud Shell -> PowerShell

 Automation Runtime:
 Existing PowerShell 7.2 Runtime

 Creates:
   - Resource Group
   - Log Analytics Workspace
   - Automation Account
   - System Assigned Managed Identity
   - Microsoft Graph Application.Read.All
   - PowerShell 7.2 Runbook
   - Daily Schedule
   - Runbook -> Schedule association
   - Automation Diagnostic Settings
   - Email Action Group
   - Azure Monitor Log Alert

 Detects:
   - Client Secrets
   - Certificates

 Default threshold:
   10 days
===============================================================
#>

param(

    [string]$ResourceGroupName =
        "rg-app-credential-monitor",

    [string]$Location =
        "centralindia",

    [string]$WorkspaceName =
        "law-app-credential-monitor",

    [string]$AutomationAccountName =
        "aa-app-credential-monitor",

    [string]$RunbookName =
        "AppCredentialExpiryMonitor",

    [string]$ScheduleName =
        "Daily-AppCredential-Check",

    [string]$DiagnosticSettingName =
        "Automation-To-LogAnalytics",

    [string]$ActionGroupName =
        "ag-app-credential-expiry",

    [string]$AlertName =
        "alert-app-credential-expiry",

    [int]$ExpiryThresholdDays =
        10,

    [string]$NotificationEmail = ""
)

$ErrorActionPreference = "Stop"


# ============================================================
# FUNCTIONS
# ============================================================

function Write-Step {

    param(
        [string]$Message
    )

    Write-Host ""
    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host $Message `
        -ForegroundColor Cyan

    Write-Host "============================================================" `
        -ForegroundColor Cyan
}


function Test-EmailAddress {

    param(
        [string]$Email
    )

    return $Email -match '^[^@\s]+@[^@\s]+\.[^@\s]+$'
}


function Get-ManagementToken {

    $TokenObject =
        Get-AzAccessToken `
            -ResourceUrl "https://management.azure.com/" `
            -ErrorAction Stop

    if (-not $TokenObject.Token) {

        throw "Unable to acquire Azure Management token."
    }

    if (
        $TokenObject.Token -is
        [System.Security.SecureString]
    ) {

        return [System.Net.NetworkCredential]::new(
            "",
            $TokenObject.Token
        ).Password
    }

    return [string]$TokenObject.Token
}


function Invoke-ArmRequest {

    param(

        [ValidateSet(
            "GET",
            "PUT",
            "PATCH",
            "POST",
            "DELETE"
        )]
        [string]$Method,

        [string]$Uri,

        [object]$Body = $null,

        [string]$ContentType =
            "application/json"
    )

    $AccessToken =
        Get-ManagementToken

    $Headers = @{
        Authorization =
            "Bearer $AccessToken"

        "Content-Type" =
            $ContentType
    }

    if ($null -ne $Body) {

        if ($ContentType -eq "application/json") {

            $Payload =
                $Body |
                ConvertTo-Json -Depth 30
        }
        else {

            $Payload =
                [string]$Body
        }

        return Invoke-RestMethod `
            -Method $Method `
            -Uri $Uri `
            -Headers $Headers `
            -Body $Payload `
            -ContentType $ContentType `
            -ErrorAction Stop
    }

    return Invoke-RestMethod `
        -Method $Method `
        -Uri $Uri `
        -Headers $Headers `
        -ErrorAction Stop
}


# ============================================================
# HEADER
# ============================================================

Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor Green

Write-Host `
    " Azure App Registration Credential Expiry Monitor" `
    -ForegroundColor Green

Write-Host `
    " AUTOMATIC DEPLOYMENT" `
    -ForegroundColor Green

Write-Host "============================================================" `
    -ForegroundColor Green


# ============================================================
# EMAIL
# ============================================================

if (
    [string]::IsNullOrWhiteSpace(
        $NotificationEmail
    )
) {

    $NotificationEmail =
        Read-Host `
            "Enter email address for credential expiry alerts"
}


if (
    [string]::IsNullOrWhiteSpace(
        $NotificationEmail
    )
) {

    throw "Notification email address is required."
}


if (
    -not (
        Test-EmailAddress `
            $NotificationEmail
    )
) {

    throw "Invalid email address: $NotificationEmail"
}


Write-Host ""
Write-Host `
    "Notification Email : $NotificationEmail" `
    -ForegroundColor Green

Write-Host `
    "Expiry Threshold   : $ExpiryThresholdDays days" `
    -ForegroundColor Green


# ============================================================
# 1. POWERSHELL
# ============================================================

Write-Step "[1/13] Checking PowerShell"

if (
    $PSVersionTable.PSVersion.Major -lt 7
) {

    throw @"
PowerShell 7 or later is required.

For the easiest viewer experience:
Azure Portal -> Cloud Shell -> PowerShell
"@
}


Write-Host `
    "PowerShell Version: $($PSVersionTable.PSVersion)" `
    -ForegroundColor Green


# ============================================================
# 2. AZ MODULE
# ============================================================

Write-Step "[2/13] Checking Az PowerShell"

if (
    -not (
        Get-Module `
            -ListAvailable `
            -Name Az.Accounts
    )
) {

    Write-Host `
        "Az PowerShell not found. Installing..." `
        -ForegroundColor Yellow

    Install-Module Az `
        -Scope CurrentUser `
        -Repository PSGallery `
        -Force `
        -AllowClobber `
        -ErrorAction Stop
}


Import-Module Az.Accounts
Import-Module Az.Resources
Import-Module Az.Automation
Import-Module Az.OperationalInsights


Write-Host `
    "Az PowerShell ready." `
    -ForegroundColor Green


# ============================================================
# 3. AZURE LOGIN
# ============================================================

Write-Step "[3/13] Connecting to Azure"

$AzureContext =
    Get-AzContext


if (-not $AzureContext) {

    Connect-AzAccount

    $AzureContext =
        Get-AzContext
}


if (-not $AzureContext) {

    throw "Azure authentication failed."
}


$SubscriptionId =
    $AzureContext.Subscription.Id

$TenantId =
    $AzureContext.Tenant.Id


Write-Host `
    "Subscription : $($AzureContext.Subscription.Name)" `
    -ForegroundColor Green

Write-Host `
    "Subscription ID : $SubscriptionId" `
    -ForegroundColor Green

Write-Host `
    "Tenant ID : $TenantId" `
    -ForegroundColor Green


# ============================================================
# 4. RESOURCE GROUP
# ============================================================

Write-Step "[4/13] Creating Resource Group"

$ResourceGroup =
    Get-AzResourceGroup `
        -Name $ResourceGroupName `
        -ErrorAction SilentlyContinue


if (-not $ResourceGroup) {

    New-AzResourceGroup `
        -Name $ResourceGroupName `
        -Location $Location `
        -ErrorAction Stop |
        Out-Null

    Write-Host `
        "Resource Group created." `
        -ForegroundColor Green
}
else {

    Write-Host `
        "Resource Group already exists." `
        -ForegroundColor Yellow
}


# ============================================================
# 5. LOG ANALYTICS
# ============================================================

Write-Step "[5/13] Creating Log Analytics Workspace"

$Workspace =
    Get-AzOperationalInsightsWorkspace `
        -ResourceGroupName $ResourceGroupName `
        -Name $WorkspaceName `
        -ErrorAction SilentlyContinue


if (-not $Workspace) {

    $Workspace =
        New-AzOperationalInsightsWorkspace `
            -ResourceGroupName $ResourceGroupName `
            -Name $WorkspaceName `
            -Location $Location `
            -Sku PerGB2018 `
            -ErrorAction Stop

    Write-Host `
        "Log Analytics Workspace created." `
        -ForegroundColor Green
}
else {

    Write-Host `
        "Log Analytics Workspace already exists." `
        -ForegroundColor Yellow
}


$WorkspaceResourceId =
    $Workspace.ResourceId


# ============================================================
# 6. AUTOMATION ACCOUNT
# ============================================================

Write-Step "[6/13] Creating Automation Account"

$Automation =
    Get-AzAutomationAccount `
        -ResourceGroupName $ResourceGroupName `
        -Name $AutomationAccountName `
        -ErrorAction SilentlyContinue


if (-not $Automation) {

    $Automation =
        New-AzAutomationAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name $AutomationAccountName `
            -Location $Location `
            -AssignSystemIdentity `
            -ErrorAction Stop

    Write-Host `
        "Automation Account created." `
        -ForegroundColor Green
}
else {

    Write-Host `
        "Automation Account already exists." `
        -ForegroundColor Yellow
}


$Automation =
    Get-AzAutomationAccount `
        -ResourceGroupName $ResourceGroupName `
        -Name $AutomationAccountName `
        -ErrorAction Stop


if (
    -not $Automation.Identity.PrincipalId
) {

    Write-Host `
        "Enabling System Assigned Managed Identity..." `
        -ForegroundColor Yellow

    Set-AzAutomationAccount `
        -ResourceGroupName $ResourceGroupName `
        -Name $AutomationAccountName `
        -AssignSystemIdentity `
        -ErrorAction Stop |
        Out-Null

    Start-Sleep -Seconds 5

    $Automation =
        Get-AzAutomationAccount `
            -ResourceGroupName $ResourceGroupName `
            -Name $AutomationAccountName `
            -ErrorAction Stop
}


$ManagedIdentityObjectId =
    $Automation.Identity.PrincipalId


if (
    [string]::IsNullOrWhiteSpace(
        $ManagedIdentityObjectId
    )
) {

    throw `
        "System Assigned Managed Identity was not created."
}


Write-Host ""
Write-Host `
    "Managed Identity Object ID:" `
    -ForegroundColor Green

Write-Host `
    $ManagedIdentityObjectId `
    -ForegroundColor Green


# ============================================================
# 7. MICROSOFT GRAPH
# ============================================================

Write-Step "[7/13] Configuring Microsoft Graph"

if (
    -not (
        Get-Module `
            -ListAvailable `
            -Name Microsoft.Graph.Authentication
    )
) {

    Write-Host `
        "Microsoft Graph modules not found. Installing..." `
        -ForegroundColor Yellow

    Install-Module Microsoft.Graph `
        -Scope CurrentUser `
        -Repository PSGallery `
        -Force `
        -AllowClobber `
        -ErrorAction Stop
}


Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Applications


Write-Host ""
Write-Host `
    "Microsoft Graph sign-in required." `
    -ForegroundColor Yellow

Write-Host `
    "A device code will appear." `
    -ForegroundColor Yellow

Write-Host ""


Connect-MgGraph `
    -TenantId $TenantId `
    -Scopes `
        "Application.Read.All",
        "AppRoleAssignment.ReadWrite.All" `
    -UseDeviceAuthentication `
    -NoWelcome `
    -ErrorAction Stop


$MgContext =
    Get-MgContext `
        -ErrorAction Stop


if (-not $MgContext) {

    throw `
        "Microsoft Graph authentication failed."
}


Write-Host `
    "Microsoft Graph authentication successful." `
    -ForegroundColor Green

Write-Host `
    "Graph Account: $($MgContext.Account)" `
    -ForegroundColor Green


$GraphAppId =
    "00000003-0000-0000-c000-000000000000"


$GraphSP =
    Get-MgServicePrincipal `
        -Filter "appId eq '$GraphAppId'" `
        -Property Id,AppId,DisplayName,AppRoles `
        -ErrorAction Stop


if (-not $GraphSP) {

    throw `
        "Microsoft Graph service principal was not found."
}


$GraphSPId =
    $GraphSP.Id


Write-Host `
    "Microsoft Graph service principal found." `
    -ForegroundColor Green


$ApplicationReadAllRole =
    $GraphSP.AppRoles |
    Where-Object {

        $_.Value -eq "Application.Read.All" -and

        $_.AllowedMemberTypes -contains "Application"

    } |
    Select-Object -First 1


if (-not $ApplicationReadAllRole) {

    throw `
        "Application.Read.All was not found on Microsoft Graph."
}


$ApplicationReadAllRoleId =
    $ApplicationReadAllRole.Id


Write-Host `
    "Application.Read.All found." `
    -ForegroundColor Green

Write-Host `
    "App Role ID: $ApplicationReadAllRoleId" `
    -ForegroundColor Green


$ExistingAssignment =
    Get-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId `
            $ManagedIdentityObjectId `
        -All `
        -ErrorAction Stop |
    Where-Object {

        $_.ResourceId -eq $GraphSPId -and

        $_.AppRoleId -eq
            $ApplicationReadAllRoleId
    }


if (-not $ExistingAssignment) {

    Write-Host `
        "Assigning Application.Read.All..." `
        -ForegroundColor Yellow

    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId `
            $ManagedIdentityObjectId `
        -PrincipalId `
            $ManagedIdentityObjectId `
        -ResourceId `
            $GraphSPId `
        -AppRoleId `
            $ApplicationReadAllRoleId `
        -ErrorAction Stop |
        Out-Null

    Write-Host `
        "Application.Read.All assigned." `
        -ForegroundColor Green
}
else {

    Write-Host `
        "Application.Read.All already assigned." `
        -ForegroundColor Yellow
}


Disconnect-MgGraph


# ============================================================
# 8. FIND EXISTING POWERSHELL 7.2 RUNTIME
# ============================================================

Write-Step "[8/13] Finding Existing PowerShell 7.2 Runtime"

$ManagementUrl =
    "https://management.azure.com"


$RuntimeListUri =
    "$ManagementUrl/subscriptions/$SubscriptionId" +
    "/resourceGroups/$ResourceGroupName" +
    "/providers/Microsoft.Automation" +
    "/automationAccounts/$AutomationAccountName" +
    "/runtimeEnvironments" +
    "?api-version=2024-10-23"


$RuntimeList =
    Invoke-ArmRequest `
        -Method GET `
        -Uri $RuntimeListUri


$Runtime72 =
    @(
        $RuntimeList.value
    ) |
    Where-Object {

        $_.properties.runtime.language -eq "PowerShell" -and

        $_.properties.runtime.version -eq "7.2"

    } |
    Select-Object -First 1


if (-not $Runtime72) {

    throw @"
PowerShell 7.2 Runtime Environment was not found.

Open:
Automation Account
 -> Runtime Environments

and verify that the PowerShell 7.2 runtime exists.
"@
}


$RuntimeEnvironmentName =
    $Runtime72.name


Write-Host ""
Write-Host `
    "PowerShell 7.2 Runtime found:" `
    -ForegroundColor Green

Write-Host `
    $RuntimeEnvironmentName `
    -ForegroundColor Green


# ============================================================
# 9. CREATE / UPDATE RUNBOOK
# ============================================================

Write-Step "[9/13] Creating PowerShell 7.2 Runbook"

$RunbookCode = @'
param(
    [int]$ExpiryThresholdDays = 10
)

$ErrorActionPreference = "Stop"

Write-Output "=============================================="
Write-Output "Azure App Registration Credential Monitor"
Write-Output "=============================================="

Write-Output "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Output "Threshold: $ExpiryThresholdDays days"
Write-Output ""

# ============================================================
# MANAGED IDENTITY
# ============================================================

Disable-AzContextAutosave -Scope Process

Connect-AzAccount `
    -Identity `
    -ErrorAction Stop |
    Out-Null

Write-Output "Managed Identity authentication successful."


# ============================================================
# MICROSOFT GRAPH TOKEN
# ============================================================

$TokenObject =
    Get-AzAccessToken `
        -ResourceUrl `
            "https://graph.microsoft.com/" `
        -ErrorAction Stop


if (-not $TokenObject.Token) {

    throw "Unable to acquire Microsoft Graph access token."
}


if (
    $TokenObject.Token -is
    [System.Security.SecureString]
) {

    $GraphToken =
        [System.Net.NetworkCredential]::new(
            "",
            $TokenObject.Token
        ).Password
}
else {

    $GraphToken =
        [string]$TokenObject.Token
}


if (
    [string]::IsNullOrWhiteSpace(
        $GraphToken
    )
) {

    throw "Microsoft Graph token conversion failed."
}


$Headers = @{
    Authorization =
        "Bearer $GraphToken"
}


Write-Output `
    "Microsoft Graph authentication successful."


# ============================================================
# GET APPLICATION REGISTRATIONS
# ============================================================

$Applications = @()


$Uri =
    "https://graph.microsoft.com/v1.0/applications" +
    "?`$select=id,appId,displayName,passwordCredentials,keyCredentials" +
    "&`$top=999"


while ($Uri) {

    $Response =
        Invoke-RestMethod `
            -Method GET `
            -Uri $Uri `
            -Headers $Headers `
            -ErrorAction Stop


    $Applications +=
        $Response.value


    $Uri =
        $Response.'@odata.nextLink'
}


Write-Output `
    "App Registrations found: $($Applications.Count)"

Write-Output ""


# ============================================================
# DETECT EXPIRING CREDENTIALS
# ============================================================

$Now =
    [DateTime]::UtcNow


$ThresholdDate =
    $Now.AddDays(
        $ExpiryThresholdDays
    )


$ExpiringCredentials =
    @()


foreach ($Application in $Applications) {

    # --------------------------------------------------------
    # CLIENT SECRETS
    # --------------------------------------------------------

    foreach (
        $Secret in
        $Application.passwordCredentials
    ) {

        if (
            -not $Secret.endDateTime
        ) {

            continue
        }


        $ExpiryDate =
            [DateTime]$Secret.endDateTime


        if (
            $ExpiryDate -le
            $ThresholdDate
        ) {

            $DaysRemaining =
                [math]::Floor(
                    (
                        $ExpiryDate -
                        $Now
                    ).TotalDays
                )


            $ExpiringCredentials +=
                [PSCustomObject]@{

                    ApplicationName =
                        $Application.displayName

                    ApplicationId =
                        $Application.appId

                    CredentialType =
                        "Client Secret"

                    ExpiryDate =
                        $ExpiryDate.ToString(
                            "yyyy-MM-dd HH:mm:ss"
                        )

                    DaysRemaining =
                        $DaysRemaining
                }
        }
    }


    # --------------------------------------------------------
    # CERTIFICATES
    # --------------------------------------------------------

    foreach (
        $Certificate in
        $Application.keyCredentials
    ) {

        if (
            -not $Certificate.endDateTime
        ) {

            continue
        }


        $ExpiryDate =
            [DateTime]$Certificate.endDateTime


        if (
            $ExpiryDate -le
            $ThresholdDate
        ) {

            $DaysRemaining =
                [math]::Floor(
                    (
                        $ExpiryDate -
                        $Now
                    ).TotalDays
                )


            $ExpiringCredentials +=
                [PSCustomObject]@{

                    ApplicationName =
                        $Application.displayName

                    ApplicationId =
                        $Application.appId

                    CredentialType =
                        "Certificate"

                    ExpiryDate =
                        $ExpiryDate.ToString(
                            "yyyy-MM-dd HH:mm:ss"
                        )

                    DaysRemaining =
                        $DaysRemaining
                }
        }
    }
}


# ============================================================
# OUTPUT FOR LOG ANALYTICS
# ============================================================

if (
    $ExpiringCredentials.Count -eq 0
) {

    Write-Output ""
    Write-Output "=========================================="
    Write-Output "NO EXPIRING CREDENTIALS"
    Write-Output "=========================================="

    Write-Output ""
    Write-Output `
        "No client secrets or certificates are"

    Write-Output `
        "expiring within $ExpiryThresholdDays days."
}
else {

    Write-Output ""
    Write-Output "=========================================="
    Write-Output "CREDENTIAL EXPIRY ALERT"
    Write-Output "=========================================="

    Write-Output ""
    Write-Output `
        "Found $($ExpiringCredentials.Count) credential(s)"

    Write-Output `
        "expiring within $ExpiryThresholdDays days."

    Write-Output ""

    foreach (
        $Credential in
        (
            $ExpiringCredentials |
            Sort-Object DaysRemaining
        )
    ) {

        # ----------------------------------------------------
        # STRUCTURED OUTPUT
        # This is consumed by the original portal KQL.
        # ----------------------------------------------------

        $AlertObject =
            [PSCustomObject]@{

                AlertType =
                    "AppRegistrationCredentialExpiry"

                ApplicationName =
                    $Credential.ApplicationName

                ApplicationId =
                    $Credential.ApplicationId

                CredentialType =
                    $Credential.CredentialType

                ExpiryDate =
                    $Credential.ExpiryDate

                DaysRemaining =
                    $Credential.DaysRemaining

                DetectionTime =
                    (Get-Date).ToString(
                        "yyyy-MM-dd HH:mm:ss"
                    )
            }


        Write-Output `
            "CREDENTIAL_EXPIRING: $(
                $AlertObject |
                ConvertTo-Json -Compress
            )"


        # ----------------------------------------------------
        # HUMAN READABLE OUTPUT
        # ----------------------------------------------------

        Write-Output ""

        Write-Output `
            "Application   : $(
                $Credential.ApplicationName
            )"

        Write-Output `
            "Application ID: $(
                $Credential.ApplicationId
            )"

        Write-Output `
            "Credential    : $(
                $Credential.CredentialType
            )"

        Write-Output `
            "Expires       : $(
                $Credential.ExpiryDate
            )"

        Write-Output `
            "Days Remaining: $(
                $Credential.DaysRemaining
            )"

        Write-Output `
            "------------------------------------------"
    }

    Write-Output ""
    Write-Output "ACTION REQUIRED:"
    Write-Output `
        "Review and rotate the affected credentials."
}


Write-Output ""
Write-Output "Credential monitoring completed."
'@


# ------------------------------------------------------------
# Runbook URI
# ------------------------------------------------------------

$RunbookUri =
    "$ManagementUrl/subscriptions/$SubscriptionId" +
    "/resourceGroups/$ResourceGroupName" +
    "/providers/Microsoft.Automation" +
    "/automationAccounts/$AutomationAccountName" +
    "/runbooks/$RunbookName" +
    "?api-version=2024-10-23"


$RunbookBody = @{

    name =
        $RunbookName

    location =
        $Location

    properties = @{

        runbookType =
            "PowerShell"

        runtimeEnvironment =
            $RuntimeEnvironmentName

        description =
            "Azure App Registration credential expiry monitor"

        logProgress =
            $true

        logVerbose =
            $true

        draft = @{}
    }
}


Invoke-ArmRequest `
    -Method PUT `
    -Uri $RunbookUri `
    -Body $RunbookBody |
    Out-Null


Write-Host `
    "Runbook created/updated." `
    -ForegroundColor Green


# ------------------------------------------------------------
# Upload Runbook Code
# ------------------------------------------------------------

$DraftContentUri =
    "$ManagementUrl/subscriptions/$SubscriptionId" +
    "/resourceGroups/$ResourceGroupName" +
    "/providers/Microsoft.Automation" +
    "/automationAccounts/$AutomationAccountName" +
    "/runbooks/$RunbookName" +
    "/draft/content" +
    "?api-version=2024-10-23"


Invoke-ArmRequest `
    -Method PUT `
    -Uri $DraftContentUri `
    -Body $RunbookCode `
    -ContentType "text/powershell" |
    Out-Null


Write-Host `
    "Runbook code uploaded." `
    -ForegroundColor Green


# ------------------------------------------------------------
# Publish
# ------------------------------------------------------------

$PublishUri =
    "$ManagementUrl/subscriptions/$SubscriptionId" +
    "/resourceGroups/$ResourceGroupName" +
    "/providers/Microsoft.Automation" +
    "/automationAccounts/$AutomationAccountName" +
    "/runbooks/$RunbookName" +
    "/publish" +
    "?api-version=2024-10-23"


Invoke-ArmRequest `
    -Method POST `
    -Uri $PublishUri |
    Out-Null


Write-Host `
    "Runbook published." `
    -ForegroundColor Green


# ============================================================
# 10. AUTOMATION DIAGNOSTIC SETTINGS
# ============================================================

Write-Step "[10/13] Configuring Automation Diagnostics"

$AutomationResourceId =
    "/subscriptions/$SubscriptionId" +
    "/resourceGroups/$ResourceGroupName" +
    "/providers/Microsoft.Automation" +
    "/automationAccounts/$AutomationAccountName"


$DiagnosticUri =
    "$ManagementUrl$AutomationResourceId" +
    "/providers/Microsoft.Insights" +
    "/diagnosticSettings/$DiagnosticSettingName" +
    "?api-version=2021-05-01-preview"


$DiagnosticBody = @{

    properties = @{

        workspaceId =
            $WorkspaceResourceId

        logs = @(

            @{
                category =
                    "JobLogs"

                enabled =
                    $true
            },

            @{
                category =
                    "JobStreams"

                enabled =
                    $true
            }
        )

        metrics = @(

            @{
                category =
                    "AllMetrics"

                enabled =
                    $true
            }
        )
    }
}


Invoke-ArmRequest `
    -Method PUT `
    -Uri $DiagnosticUri `
    -Body $DiagnosticBody |
    Out-Null


Write-Host `
    "[OK] Automation diagnostics configured." `
    -ForegroundColor Green


# ============================================================
# 11. DAILY SCHEDULE + RUNBOOK ASSOCIATION
# ============================================================

Write-Step "[11/13] Creating Daily Schedule"

$ScheduleUri =
    "$ManagementUrl/subscriptions/$SubscriptionId" +
    "/resourceGroups/$ResourceGroupName" +
    "/providers/Microsoft.Automation" +
    "/automationAccounts/$AutomationAccountName" +
    "/schedules/$ScheduleName" +
    "?api-version=2024-10-23"


$ExistingSchedule =
    $null


try {

    $ExistingSchedule =
        Invoke-ArmRequest `
            -Method GET `
            -Uri $ScheduleUri
}
catch {

    $StatusCode =
        $_.Exception.Response.StatusCode.value__

    if ($StatusCode -ne 404) {

        throw
    }

    Write-Host `
        "Daily Schedule does not exist yet. It will be created." `
        -ForegroundColor Yellow
}


if (-not $ExistingSchedule) {

    $ScheduleStartTime =
        (Get-Date).ToUniversalTime().AddMinutes(15)


    $ScheduleBody = @{

        name =
            $ScheduleName

        properties = @{

            description =
                "Daily check for expiring App Registration credentials"

            startTime =
                $ScheduleStartTime.ToString(
                    "yyyy-MM-ddTHH:mm:ss+00:00"
                )

            interval =
                1

            frequency =
                "Day"

            timeZone =
                "UTC"
        }
    }


    Invoke-ArmRequest `
        -Method PUT `
        -Uri $ScheduleUri `
        -Body $ScheduleBody |
        Out-Null


    Write-Host `
        "Daily Schedule created." `
        -ForegroundColor Green
}
else {

    Write-Host `
        "Daily Schedule already exists." `
        -ForegroundColor Yellow
}


# ------------------------------------------------------------
# Link Runbook -> Schedule
# ------------------------------------------------------------

$ExistingJobSchedulesUri =
    "$ManagementUrl/subscriptions/$SubscriptionId" +
    "/resourceGroups/$ResourceGroupName" +
    "/providers/Microsoft.Automation" +
    "/automationAccounts/$AutomationAccountName" +
    "/jobSchedules" +
    "?api-version=2024-10-23"


$ExistingJobSchedules =
    Invoke-ArmRequest `
        -Method GET `
        -Uri $ExistingJobSchedulesUri


$AlreadyLinked =
    @($ExistingJobSchedules.value) |
    Where-Object {

        $_.properties.runbook.name -eq
            $RunbookName -and

        $_.properties.schedule.name -eq
            $ScheduleName

    } |
    Select-Object -First 1


if (-not $AlreadyLinked) {

    $JobScheduleId =
        [guid]::NewGuid().ToString()


    $JobScheduleUri =
        "$ManagementUrl/subscriptions/$SubscriptionId" +
        "/resourceGroups/$ResourceGroupName" +
        "/providers/Microsoft.Automation" +
        "/automationAccounts/$AutomationAccountName" +
        "/jobSchedules/$JobScheduleId" +
        "?api-version=2024-10-23"


    $JobScheduleBody = @{

        properties = @{

            schedule = @{

                name =
                    $ScheduleName
            }

            runbook = @{

                name =
                    $RunbookName
            }

            parameters = @{

                EXPIRYTHRESHOLDDAYS =
                    "$ExpiryThresholdDays"
            }
        }
    }


    Invoke-ArmRequest `
        -Method PUT `
        -Uri $JobScheduleUri `
        -Body $JobScheduleBody |
        Out-Null


    Write-Host `
        "Runbook linked to Daily Schedule." `
        -ForegroundColor Green
}
else {

    Write-Host `
        "Runbook already linked to Daily Schedule." `
        -ForegroundColor Yellow
}


# ============================================================
# 12. EMAIL ACTION GROUP
# ============================================================

Write-Step "[12/13] Creating Email Action Group"

$ActionGroupResourceId =
    "/subscriptions/$SubscriptionId" +
    "/resourceGroups/$ResourceGroupName" +
    "/providers/Microsoft.Insights" +
    "/actionGroups/$ActionGroupName"


$ActionGroupUri =
    "$ManagementUrl$ActionGroupResourceId" +
    "?api-version=2023-01-01"


$ActionGroupBody = @{

    location =
        "Global"

    properties = @{

        groupShortName =
            "AppCred"

        enabled =
            $true

        emailReceivers = @(

            @{

                name =
                    "CredentialExpiryEmail"

                emailAddress =
                    $NotificationEmail

                useCommonAlertSchema =
                    $true
            }
        )
    }
}


Invoke-ArmRequest `
    -Method PUT `
    -Uri $ActionGroupUri `
    -Body $ActionGroupBody |
    Out-Null


Write-Host `
    "[OK] Email Action Group created." `
    -ForegroundColor Green


# ============================================================
# 13. AZURE MONITOR ALERT
# ============================================================

Write-Step "[13/13] Creating Azure Monitor Alert"

# ============================================================
# THIS IS YOUR ORIGINAL PORTAL KQL
# ============================================================

$Kql = @"
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
"@


$AlertResourceId =
    "/subscriptions/$SubscriptionId" +
    "/resourceGroups/$ResourceGroupName" +
    "/providers/Microsoft.Insights" +
    "/scheduledQueryRules/$AlertName"


$AlertUri =
    "$ManagementUrl$AlertResourceId" +
    "?api-version=2023-12-01"


$AlertBody = @{

    location =
        $Location

    kind =
        "LogAlert"

    properties = @{

        displayName =
            "App Registration Credential Expiry"

        description =
            "Alerts when App Registration client secrets or certificates are approaching expiration."

        severity =
            2

        enabled =
            $true

        evaluationFrequency =
            "PT5M"

        windowSize =
            "PT15M"

        autoMitigate =
            $true

        scopes = @(
            $WorkspaceResourceId
        )

        criteria = @{

            allOf = @(

                @{

                    query =
                        $Kql

                    timeAggregation =
                        "Count"

                    operator =
                        "GreaterThan"

                    threshold =
                        0

                    failingPeriods = @{

                        numberOfEvaluationPeriods =
                            1

                        minFailingPeriodsToAlert =
                            1
                    }
                }
            )
        }

        actions = @{

            actionGroups = @(
                $ActionGroupResourceId
            )
        }
    }
}


Invoke-ArmRequest `
    -Method PUT `
    -Uri $AlertUri `
    -Body $AlertBody |
    Out-Null


Write-Host `
    "[OK] Azure Monitor Alert created." `
    -ForegroundColor Green


# ============================================================
# FINAL VERIFICATION
# ============================================================

Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor Cyan

Write-Host `
    " VERIFYING DEPLOYMENT" `
    -ForegroundColor Cyan

Write-Host "============================================================" `
    -ForegroundColor Cyan


# ------------------------------------------------------------
# Managed Identity
# ------------------------------------------------------------

$VerifyAutomation =
    Get-AzAutomationAccount `
        -ResourceGroupName $ResourceGroupName `
        -Name $AutomationAccountName `
        -ErrorAction Stop


if (
    -not $VerifyAutomation.Identity.PrincipalId
) {

    throw `
        "Verification failed: Managed Identity missing."
}


Write-Host `
    "[OK] Managed Identity" `
    -ForegroundColor Green


# ------------------------------------------------------------
# Runtime
# ------------------------------------------------------------

$VerifyRuntime =
    Invoke-ArmRequest `
        -Method GET `
        -Uri (
            "$ManagementUrl/subscriptions/$SubscriptionId" +
            "/resourceGroups/$ResourceGroupName" +
            "/providers/Microsoft.Automation" +
            "/automationAccounts/$AutomationAccountName" +
            "/runtimeEnvironments/$RuntimeEnvironmentName" +
            "?api-version=2024-10-23"
        )


if (
    $VerifyRuntime.properties.runtime.version -ne "7.2"
) {

    throw `
        "Verification failed: Runbook runtime is not PowerShell 7.2."
}


Write-Host `
    "[OK] PowerShell 7.2 Runtime" `
    -ForegroundColor Green


# ------------------------------------------------------------
# Runbook
# ------------------------------------------------------------

$VerifyRunbook =
    Invoke-ArmRequest `
        -Method GET `
        -Uri $RunbookUri


if (
    $VerifyRunbook.properties.runtimeEnvironment `
        -ne $RuntimeEnvironmentName
) {

    throw `
        "Verification failed: Runbook is not linked to PowerShell 7.2."
}


Write-Host `
    "[OK] Runbook linked to PowerShell 7.2" `
    -ForegroundColor Green


# ------------------------------------------------------------
# Schedule + Association
# ------------------------------------------------------------

Write-Host ""
Write-Host `
    "Verifying Runbook -> Schedule association..." `
    -ForegroundColor Cyan


$JobSchedules =
    Invoke-ArmRequest `
        -Method GET `
        -Uri $ExistingJobSchedulesUri


$MatchingJobSchedule =
    @($JobSchedules.value) |
    Where-Object {

        $_.properties.runbook.name -eq
            $RunbookName -and

        $_.properties.schedule.name -eq
            $ScheduleName

    } |
    Select-Object -First 1


if ($MatchingJobSchedule) {

    Write-Host `
        "[OK] Runbook is attached to Daily Schedule" `
        -ForegroundColor Green
}
else {

    throw @"
The Runbook/Schedule association was not found.

Runbook : $RunbookName
Schedule: $ScheduleName
"@
}


# ------------------------------------------------------------
# Action Group
# ------------------------------------------------------------

$VerifyActionGroup =
    Invoke-ArmRequest `
        -Method GET `
        -Uri $ActionGroupUri


if (-not $VerifyActionGroup) {

    throw `
        "Verification failed: Action Group not found."
}


Write-Host `
    "[OK] Email Action Group" `
    -ForegroundColor Green


# ------------------------------------------------------------
# Alert
# ------------------------------------------------------------

$VerifyAlert =
    Invoke-ArmRequest `
        -Method GET `
        -Uri $AlertUri


if (-not $VerifyAlert) {

    throw `
        "Verification failed: Alert not found."
}


Write-Host `
    "[OK] Azure Monitor Alert" `
    -ForegroundColor Green


# ============================================================
# START TEST JOB
# ============================================================

Write-Host ""
Write-Host `
    "Starting immediate Runbook test..." `
    -ForegroundColor Cyan


$TestJob =
    Start-AzAutomationRunbook `
        -ResourceGroupName `
            $ResourceGroupName `
        -AutomationAccountName `
            $AutomationAccountName `
        -Name `
            $RunbookName `
        -Parameters @{
            ExpiryThresholdDays =
                $ExpiryThresholdDays
        } `
        -ErrorAction Stop


if (-not $TestJob) {

    throw `
        "Test Runbook job could not be started."
}


Write-Host `
    "[OK] Test Runbook job started." `
    -ForegroundColor Green


# ============================================================
# SUCCESS
# ============================================================

Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor Green

Write-Host `
    " DEPLOYMENT COMPLETE" `
    -ForegroundColor Green

Write-Host "============================================================" `
    -ForegroundColor Green

Write-Host ""

Write-Host `
    "Resource Group     : $ResourceGroupName"

Write-Host `
    "Automation Account : $AutomationAccountName"

Write-Host `
    "Runbook            : $RunbookName"

Write-Host `
    "Runtime            : PowerShell 7.2"

Write-Host `
    "Workspace          : $WorkspaceName"

Write-Host `
    "Threshold          : $ExpiryThresholdDays days"

Write-Host `
    "Alert Email        : $NotificationEmail"

Write-Host `
    "Test Job ID        : $($TestJob.JobId)"

Write-Host ""

Write-Host `
    "All major resources passed verification." `
    -ForegroundColor Green

Write-Host ""
Write-Host "Next:"
Write-Host "  1. Automation Account -> Jobs"
Write-Host "  2. Check the test job output"
Write-Host "  3. Log Analytics -> Logs"
Write-Host "  4. Azure Monitor -> Alerts"
Write-Host ""
