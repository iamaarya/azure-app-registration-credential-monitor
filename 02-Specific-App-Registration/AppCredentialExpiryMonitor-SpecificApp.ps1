#Requires -Version 7.0

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
   - Automation Variables (ExpiryThresholdDays, TargetApplicationAppIdsJson,
     TargetApplicationDisplayNamesJson, NotificationEmail)
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

 NOTE ON CONFIGURATION:
 The runbook now reads its target App IDs, display names, threshold, and
 notification email from Automation Variables at runtime. This means you
 can change what it monitors or the threshold by editing the Variables
 blade in the Automation Account -- no need to re-run this script or
 touch the schedule. The parameters below to this deployment script are
 only used to SEED those variables on first run (or to update them if you
 re-run the script with new values).
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

    [string[]]$TargetApplicationAppIds = @(),

    [string[]]$TargetApplicationDisplayNames = @(),

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


function Set-AutomationVariableValue {

    <#
        Creates the Automation Variable if it doesn't exist yet,
        otherwise updates its value. Wraps New-/Set-AzAutomationVariable
        so the deployment script is safely re-runnable.
    #>

    param(

        [string]$ResourceGroupName,

        [string]$AutomationAccountName,

        [string]$Name,

        [object]$Value,

        [switch]$Encrypted
    )

    $Existing =
        Get-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $Name `
            -ErrorAction SilentlyContinue

    if ($Existing) {

        Set-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $Name `
            -Value $Value `
            -Encrypted:$Encrypted.IsPresent `
            -ErrorAction Stop |
            Out-Null

        Write-Host `
            "Automation Variable updated: $Name" `
            -ForegroundColor Green
    }
    else {

        New-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $Name `
            -Value $Value `
            -Encrypted:$Encrypted.IsPresent `
            -ErrorAction Stop |
            Out-Null

        Write-Host `
            "Automation Variable created: $Name" `
            -ForegroundColor Green
    }
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

Write-Step "[1/14] Checking PowerShell"

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

Write-Step "[2/14] Checking Az PowerShell"

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

Write-Step "[3/14] Connecting to Azure"

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

Write-Step "[4/14] Creating Resource Group"

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

Write-Step "[5/14] Creating Log Analytics Workspace"

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

Write-Step "[6/14] Creating Automation Account"

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

Write-Step "[7/14] Configuring Microsoft Graph"

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
# 8. AUTOMATION VARIABLES (seed / update)
# ============================================================

Write-Step "[8/14] Seeding Automation Variables"

Write-Host `
    "These variables drive the runbook at runtime. Edit them" `
    -ForegroundColor Yellow

Write-Host `
    "any time in the Automation Account -> Variables blade to" `
    -ForegroundColor Yellow

Write-Host `
    "change targets or threshold without re-running this script." `
    -ForegroundColor Yellow

Write-Host ""


$TargetApplicationAppIdsJson =
    if ($TargetApplicationAppIds.Count -gt 0) {
        $TargetApplicationAppIds |
            ConvertTo-Json -Compress -AsArray
    }
    else {
        "[]"
    }


$TargetApplicationDisplayNamesJson =
    if ($TargetApplicationDisplayNames.Count -gt 0) {
        $TargetApplicationDisplayNames |
            ConvertTo-Json -Compress -AsArray
    }
    else {
        "[]"
    }


Set-AutomationVariableValue `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name "ExpiryThresholdDays" `
    -Value $ExpiryThresholdDays

Set-AutomationVariableValue `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name "TargetApplicationAppIdsJson" `
    -Value $TargetApplicationAppIdsJson

Set-AutomationVariableValue `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name "TargetApplicationDisplayNamesJson" `
    -Value $TargetApplicationDisplayNamesJson

Set-AutomationVariableValue `
    -ResourceGroupName $ResourceGroupName `
    -AutomationAccountName $AutomationAccountName `
    -Name "NotificationEmail" `
    -Value $NotificationEmail

Write-Host ""
Write-Host `
    "Automation Variables ready." `
    -ForegroundColor Green


# ============================================================
# 9. FIND EXISTING POWERSHELL 7.2 RUNTIME
# ============================================================

Write-Step "[9/14] Finding Existing PowerShell 7.2 Runtime"

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
# 10. CREATE / UPDATE RUNBOOK
# ============================================================

Write-Step "[10/14] Creating PowerShell 7.2 Runbook"

$RunbookCode = @'
param(
    [int]$ExpiryThresholdDays = 0,

    [string[]]$TargetApplicationAppIds = @(),

    [string[]]$TargetApplicationDisplayNames = @()
)

$ErrorActionPreference = "Stop"

# ============================================================
# LOAD DEFAULTS FROM AUTOMATION VARIABLES
#
# Job parameters, if supplied, always win. Otherwise the runbook
# falls back to the Automation Variables so it can run on a
# schedule with no parameters at all. Change targets/threshold by
# editing the Variables blade -- no script or schedule edits needed.
# ============================================================

if ($ExpiryThresholdDays -le 0) {

    $ExpiryThresholdDays =
        [int](Get-AutomationVariable -Name "ExpiryThresholdDays")
}

if (
    -not $TargetApplicationAppIds -or
    $TargetApplicationAppIds.Count -eq 0
) {

    $TargetApplicationAppIdsJson =
        Get-AutomationVariable -Name "TargetApplicationAppIdsJson"

    if (-not [string]::IsNullOrWhiteSpace($TargetApplicationAppIdsJson)) {

        $ParsedAppIds =
            $TargetApplicationAppIdsJson | ConvertFrom-Json

        $TargetApplicationAppIds =
            @($ParsedAppIds) | Where-Object { $_ }
    }
}

if (
    -not $TargetApplicationDisplayNames -or
    $TargetApplicationDisplayNames.Count -eq 0
) {

    $TargetApplicationDisplayNamesJson =
        $null

    try {

        $TargetApplicationDisplayNamesJson =
            Get-AutomationVariable -Name "TargetApplicationDisplayNamesJson"
    }
    catch {

        # Variable is optional; ignore if missing.
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetApplicationDisplayNamesJson)) {

        $ParsedDisplayNames =
            $TargetApplicationDisplayNamesJson | ConvertFrom-Json

        $TargetApplicationDisplayNames =
            @($ParsedDisplayNames) | Where-Object { $_ }
    }
}

Write-Output "=============================================="
Write-Output "Azure App Registration Credential Monitor"
Write-Output "=============================================="

Write-Output "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Output "Threshold: $ExpiryThresholdDays days"
Write-Output "Target App IDs: $($TargetApplicationAppIds -join ', ')"
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

try {

# ============================================================
# GET APPLICATION REGISTRATIONS
# ============================================================

$Applications = @()


$SelectClause =
    'id,appId,displayName,passwordCredentials,keyCredentials'


$BaseUri =
    'https://graph.microsoft.com/v1.0/applications'


$TargetFilters =
    @()


foreach ($TargetApplicationAppId in $TargetApplicationAppIds) {

    if (
        [string]::IsNullOrWhiteSpace($TargetApplicationAppId)
    ) {

        continue
    }

    $EscapedAppId =
        $TargetApplicationAppId -replace "'", "''"

    $TargetFilters +=
        "appId eq '$EscapedAppId'"
}


foreach (
    $TargetApplicationDisplayName in
    $TargetApplicationDisplayNames
) {

    if (
        [string]::IsNullOrWhiteSpace(
            $TargetApplicationDisplayName
        )
    ) {

        continue
    }

    $EscapedDisplayName =
        $TargetApplicationDisplayName -replace "'", "''"

    $TargetFilters +=
        "displayName eq '$EscapedDisplayName'"
}


$TargetFilter =
    if ($TargetFilters.Count -gt 0) {

        "(" + (
            $TargetFilters -join " or "
        ) + ")"
    }
    else {

        $null
    }


# ------------------------------------------------------------
# Build the query string using plain single-quoted literals for
# the OData parameter names ($select, $top, $filter) -- avoids
# backtick-escaped "`$" sequences entirely, since those have
# proven unreliable after the runbook text passes through the
# ARM draft/content upload.
# ------------------------------------------------------------

$QueryParts =
    @(
        ('$select=' + $SelectClause),
        '$top=999'
    )

if ($TargetFilter) {

    $QueryParts +=
        ('$filter=' + [uri]::EscapeDataString($TargetFilter))
}

$Uri =
    $BaseUri + '?' + ($QueryParts -join '&')

Write-Output "Request URI: $Uri"


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

if ($TargetFilter) {

    Write-Output `
        "Target filter applied: $TargetFilter"
}

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

}
catch {

    Write-Output ""
    Write-Output "=========================================="
    Write-Output "RUNBOOK ERROR - FULL DETAIL"
    Write-Output "=========================================="
    Write-Output ""
    Write-Output "Message         : $($_.Exception.Message)"
    Write-Output "Category        : $($_.CategoryInfo.Category)"
    Write-Output "TargetObject    : $($_.CategoryInfo.TargetName)"
    Write-Output "ScriptStackTrace: $($_.ScriptStackTrace)"

    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        Write-Output "ErrorDetails    : $($_.ErrorDetails.Message)"
    }

    if ($_.Exception.Response) {
        try {
            $ResponseBody =
                $_.Exception.Response.Content.ReadAsStringAsync().Result
            Write-Output "ResponseBody    : $ResponseBody"
        }
        catch {
            # Response body not readable; ignore.
        }
    }

    Write-Output ""
    Write-Output "The job will now be marked as Failed."

    throw
}
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
# 11. AUTOMATION DIAGNOSTIC SETTINGS
# ============================================================

Write-Step "[11/14] Configuring Automation Diagnostics"

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
# 12. DAILY SCHEDULE + RUNBOOK ASSOCIATION
# ============================================================

Write-Step "[12/14] Creating Daily Schedule"

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
#
# NOTE: No parameters are passed here anymore. The runbook reads
# ExpiryThresholdDays / TargetApplicationAppIdsJson /
# TargetApplicationDisplayNamesJson / NotificationEmail from the
# Automation Variables seeded in step [8/14]. This is what makes
# the schedule reliable without manual portal input.
# ------------------------------------------------------------

Write-Host ""
Write-Host "Linking Runbook -> Daily Schedule..." -ForegroundColor Cyan

$ExistingJobSchedules =
    Get-AzAutomationScheduledRunbook `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -RunbookName $RunbookName `
        -ScheduleName $ScheduleName `
        -ErrorAction SilentlyContinue

$AlreadyLinked =
    @($ExistingJobSchedules) |
    Where-Object {
        $_.RunbookName -eq $RunbookName -and
        $_.ScheduleName -eq $ScheduleName
    } |
    Select-Object -First 1

if (-not $AlreadyLinked) {

    Register-AzAutomationScheduledRunbook `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -RunbookName $RunbookName `
        -ScheduleName $ScheduleName `
        -ErrorAction Stop |
        Out-Null

    Write-Host "Runbook linked to Daily Schedule." -ForegroundColor Green
}
else {
    Write-Host "Runbook already linked to Daily Schedule." -ForegroundColor Yellow
}


# ============================================================
# 13. EMAIL ACTION GROUP
# ============================================================

Write-Step "[13/14] Creating Email Action Group"

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
# 14. AZURE MONITOR ALERT
# ============================================================

Write-Step "[14/14] Creating Azure Monitor Alert"

# ============================================================
# THIS IS YOUR ORIGINAL PORTAL KQL
# (with the AlertCount > 0 fix already applied so the alert
# only fires when a credential is actually expiring)
# ============================================================

$Kql = @"
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobStreams"
| where ResultDescription contains "CREDENTIAL_EXPIRING:"
| extend AlertJson = parse_json(
    substring(
        ResultDescription,
        indexof(ResultDescription, "CREDENTIAL_EXPIRING:") + 20
    )
)
| project
    TimeGenerated,
    ApplicationName = tostring(AlertJson.ApplicationName),
    CredentialType = tostring(AlertJson.CredentialType),
    ExpiryDate = tostring(AlertJson.ExpiryDate),
    DaysRemaining = toint(AlertJson.DaysRemaining),
    ApplicationId = tostring(AlertJson.ApplicationId)
| summarize AlertCount = count() by bin(TimeGenerated, 5m)
| where AlertCount > 0
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
# Automation Variables
# ------------------------------------------------------------

$RequiredVariableNames =
    @(
        "ExpiryThresholdDays",
        "TargetApplicationAppIdsJson",
        "NotificationEmail"
    )

foreach ($RequiredVariableName in $RequiredVariableNames) {

    $VerifyVariable =
        Get-AzAutomationVariable `
            -ResourceGroupName $ResourceGroupName `
            -AutomationAccountName $AutomationAccountName `
            -Name $RequiredVariableName `
            -ErrorAction SilentlyContinue

    if (-not $VerifyVariable) {

        throw `
            "Verification failed: Automation Variable '$RequiredVariableName' not found."
    }
}

Write-Host `
    "[OK] Automation Variables" `
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
Write-Host "Verifying Runbook -> Schedule association..." -ForegroundColor Cyan

$VerifyJobSchedules =
    Get-AzAutomationScheduledRunbook `
        -ResourceGroupName $ResourceGroupName `
        -AutomationAccountName $AutomationAccountName `
        -RunbookName $RunbookName `
        -ScheduleName $ScheduleName `
        -ErrorAction SilentlyContinue

$MatchingJobSchedule =
    @($VerifyJobSchedules) |
    Where-Object {
        $_.RunbookName -eq $RunbookName -and
        $_.ScheduleName -eq $ScheduleName
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
#
# No parameters are passed -- this proves the runbook can run
# purely off the Automation Variables, exactly as the daily
# schedule will.
# ============================================================

Write-Host ""
Write-Host `
    "Starting immediate Runbook test (reading Automation Variables)..." `
    -ForegroundColor Cyan


$TestJob =
    Start-AzAutomationRunbook `
        -ResourceGroupName `
            $ResourceGroupName `
        -AutomationAccountName `
            $AutomationAccountName `
        -Name `
            $RunbookName `
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
    "Threshold          : $ExpiryThresholdDays days (Automation Variable: ExpiryThresholdDays)"

Write-Host `
    "Target App IDs     : Automation Variable TargetApplicationAppIdsJson"

Write-Host `
    "Alert Email        : $NotificationEmail (Automation Variable: NotificationEmail)"

Write-Host `
    "Test Job ID        : $($TestJob.JobId)"

Write-Host ""

Write-Host `
    "All major resources passed verification." `
    -ForegroundColor Green

Write-Host ""
Write-Host "To change what gets monitored (no re-deploy needed):"
Write-Host "  1. Automation Account -> Variables"
Write-Host "  2. Edit TargetApplicationAppIdsJson, ExpiryThresholdDays, or NotificationEmail"
Write-Host "  3. Save -- the next scheduled or manual run picks it up automatically"
Write-Host ""
Write-Host "Next:"
Write-Host "  1. Automation Account -> Jobs"
Write-Host "  2. Check the test job output"
Write-Host "  3. Log Analytics -> Logs"
Write-Host "  4. Azure Monitor -> Alerts"
Write-Host ""
