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
