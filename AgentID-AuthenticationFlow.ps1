<#
.SYNOPSIS
    Agent Authentication Flow - Autonomous Agent (App-Only).
    Two-step token exchange (T1 -> T2). CA-for-agents enforces on the T2 leg.

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
$tokenUrl              = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"

Write-Host "Agent under test: $AgentIdentityClientId" -ForegroundColor Gray

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
    $t1Token = $step1Response.access_token
    Write-Host "[OK] Blueprint authenticated - T1 obtained" -ForegroundColor Green
}
catch {
    Write-Host "[FAIL] Blueprint authentication failed" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) {
        $e = $_.ErrorDetails.Message | ConvertFrom-Json
        Write-Host "Error Code: $($e.error)" -ForegroundColor Yellow
        Write-Host "Description: $($e.error_description)" -ForegroundColor Yellow
    }
    exit
}

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
    $t2Token = $step2Response.access_token

    Write-Host "[WARN] Agent authenticated successfully!" -ForegroundColor Yellow
    Write-Host "The Conditional Access policy did NOT block this agent." -ForegroundColor Yellow
    Write-Host "`nAccess Token (T2) obtained: $($t2Token.Substring(0, [Math]::Min(50, $t2Token.Length)))..." -ForegroundColor Green
}
catch {
    Write-Host "[BLOCKED] Agent identity access denied!" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red

    if ($_.ErrorDetails.Message) {
        $errorDetails = $_.ErrorDetails.Message | ConvertFrom-Json
        Write-Host "`nError Code: $($errorDetails.error)" -ForegroundColor Yellow
        Write-Host "Description: $($errorDetails.error_description)" -ForegroundColor Yellow
    }

    Write-Host "`n[SUCCESS] Conditional Access policy is working." -ForegroundColor Green
    Write-Host "The agent was blocked from obtaining an access token." -ForegroundColor Green
}
