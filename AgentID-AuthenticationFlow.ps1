<#
.SYNOPSIS
    Agent Authentication Flow - Autonomous Agent (App-Only).
    Two-step token exchange (T1 -> T2). CA-for-agents enforces on the T2 leg.

.DESCRIPTION
    Outcomes on the T2 leg are reported as one of three distinct results:
      [BLOCKED]  Conditional Access denied the token (AADSTS53003)  -> policy works
      [FAIL]     T2 failed for a non-CA reason (bad assertion, missing permission, ...)
      [WARN]     Agent obtained a token                              -> CA did NOT block

    Script/runtime errors, unfilled placeholders and HTML error pages from the
    token endpoint are never reported as a CA block.

.PARAMETER AgentIdentityClientId
    The agent identity object ID under test. Pass with
    -AgentIdentityClientId <guid>, or omit to be prompted.

.EXAMPLE
    .\AgentID-AuthenticationFlow.ps1 -AgentIdentityClientId 00000000-0000-0000-0000-000000000000
#>
param(
    [Parameter(Mandatory = $true, HelpMessage = "Agent identity object ID (the agent under test)")]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$AgentIdentityClientId
)

# ---- Config (stable across runs) ---------------------------
$blueprintClientSecret = "<BLUEPRINT-SECRET>"   # prefer a SecureString prompt / vault in real use
$tenantId              = "<TENANT-ID>"
$blueprintAppId        = "<BLUEPRINT-APP-ID>"

# Refuse to run with placeholders still in place
foreach ($v in 'tenantId', 'blueprintAppId', 'blueprintClientSecret') {
    if ((Get-Variable $v -ValueOnly) -match '^<.*>$') {
        Write-Host "[FAIL] `$$v is still a placeholder - fill in the config block first." -ForegroundColor Red
        exit
    }
}

$tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"

Write-Host "Agent under test: $AgentIdentityClientId" -ForegroundColor Gray
Write-Host "Token endpoint:   $tokenUrl" -ForegroundColor Gray

# ---- Helpers -------------------------------------------------
function Test-HtmlErrorPage {
    <#
        The token endpoint returns JSON. If we got an HTML page back, the
        request never arrived as a valid OAuth call (wrong tenant/URL, etc.).
        Returns $true (and prints the embedded AADSTS code) if it was HTML.
    #>
    param([string]$Leg, $Response)
    if ($Response -is [string] -and $Response -match '<!DOCTYPE html') {
        $aadsts = [regex]::Match($Response, 'AADSTS\d+: [^"\\]+').Value
        Write-Host "[FAIL] $Leg`: token endpoint returned an HTML error page, not a token response." -ForegroundColor Red
        Write-Host "       Check `$tokenUrl / tenant ID. Embedded error: $aadsts" -ForegroundColor Yellow
        return $true
    }
    return $false
}

function Write-TokenError {
    <# Prints the AADSTS error from a failed Invoke-RestMethod, or the raw exception. #>
    param($ErrorRecord)
    if ($ErrorRecord.ErrorDetails.Message) {
        try {
            $e = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json
            Write-Host "Error Code: $($e.error)" -ForegroundColor Yellow
            Write-Host "Description: $($e.error_description)" -ForegroundColor Yellow
        }
        catch {
            Write-Host "Raw error body: $($ErrorRecord.ErrorDetails.Message)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Error: $($ErrorRecord.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
# STEP 1: Blueprint gets exchange token (T1)
# fmi_path points at the agent identity's object ID
# ============================================================
Write-Host "`nStep 1: Blueprint requesting exchange token (T1)..." -ForegroundColor Cyan

$step1Body = @{
    client_id     = $blueprintAppId
    scope         = "api://AzureADTokenExchange/.default"
    fmi_path      = $AgentIdentityClientId
    client_secret = $blueprintClientSecret
    grant_type    = "client_credentials"
}

try {
    $step1Response = Invoke-RestMethod -Method POST -Uri $tokenUrl -Body $step1Body -ContentType "application/x-www-form-urlencoded"
}
catch {
    Write-Host "[FAIL] Blueprint authentication failed" -ForegroundColor Red
    Write-TokenError $_
    exit
}

# Outside the try: a non-token response here is a script/config problem, not an auth decision
if (Test-HtmlErrorPage -Leg 'T1' -Response $step1Response) { exit }

$t1Token = $step1Response.access_token
if (-not $t1Token) {
    Write-Host "[FAIL] T1 call succeeded but returned no access_token. Raw response:" -ForegroundColor Red
    $step1Response | ConvertTo-Json -Depth 5
    exit
}
Write-Host "[OK] Blueprint authenticated - T1 obtained" -ForegroundColor Green

# ============================================================
# STEP 2: Agent identity exchanges T1 for a resource token (T2)
# THIS is where the CA Agent policy (risk or attribute) should block.
# ============================================================
Write-Host "`nStep 2: Agent identity requesting resource token (T2)..." -ForegroundColor Cyan
Write-Host "This is where the Conditional Access policy should block..." -ForegroundColor Yellow

$step2Body = @{
    client_id             = $AgentIdentityClientId
    scope                 = "https://graph.microsoft.com/.default"
    client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    client_assertion      = $t1Token
    grant_type            = "client_credentials"
}

try {
    $step2Response = Invoke-RestMethod -Method POST -Uri $tokenUrl -Body $step2Body -ContentType "application/x-www-form-urlencoded"
}
catch {
    # Decide first, then label. Only AADSTS53003 counts as a CA block.
    $desc = $null
    if ($_.ErrorDetails.Message) {
        try { $desc = ($_.ErrorDetails.Message | ConvertFrom-Json).error_description } catch { }
    }

    if ($desc -like '*AADSTS53003*') {
        Write-Host "[BLOCKED] Agent identity access denied by Conditional Access" -ForegroundColor Red
        Write-Host "Description: $desc" -ForegroundColor Yellow
        Write-Host "`n[SUCCESS] Conditional Access policy is working." -ForegroundColor Green
        Write-Host "The agent was blocked from obtaining an access token." -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] T2 failed, but NOT a CA block:" -ForegroundColor Red
        Write-TokenError $_
    }
    exit
}

# Outside the try: a non-token response here is a script/config problem, not a CA decision
if (Test-HtmlErrorPage -Leg 'T2' -Response $step2Response) { exit }

$t2Token = $step2Response.access_token
if (-not $t2Token) {
    Write-Host "[FAIL] T2 call succeeded but returned no access_token. Raw response:" -ForegroundColor Red
    $step2Response | ConvertTo-Json -Depth 5
    exit
}

Write-Host "[WARN] Agent authenticated - CA did NOT block this agent." -ForegroundColor Yellow
Write-Host "T2 token: $($t2Token.Substring(0, [Math]::Min(50, $t2Token.Length)))..." -ForegroundColor Green
Write-Host "Paste the full token into jwt.ms to confirm oid/appid = the agent identity." -ForegroundColor Gray
