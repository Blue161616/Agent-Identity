# Agent Authentication Flow - Autonomous Agent (App-Only)
# This demonstrates the two-step token exchange process

$tenantId = "<Tenant-ID>"
$blueprintAppId = "<Blueprint-ID>"
$blueprintClientSecret = "<Blueprint-ClientSecret>"
$agentIdentityClientId = "<Agent-Object-ID>"  

$tokenUrl = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"

# ============================================================
# STEP 1: Blueprint gets exchange token (T1)
# ============================================================
Write-Host "Step 1: Blueprint requesting exchange token (T1)..." -ForegroundColor Cyan

$step1Body = @{
    client_id     = $blueprintAppId
    scope         = "api://AzureADTokenExchange/.default"
    fmi_path      = $agentIdentityClientId  # Points to the agent identity
    client_secret = $blueprintClientSecret
    grant_type    = "client_credentials"
}

try {
    $step1Response = Invoke-RestMethod -Method POST -Uri $tokenUrl -Body $step1Body -ContentType "application/x-www-form-urlencoded"
    $t1Token = $step1Response.access_token
    Write-Host "✓ Blueprint authenticated - T1 obtained" -ForegroundColor Green
}
catch {
    Write-Host "✗ Blueprint authentication failed" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit
}

# ============================================================
# STEP 2: Agent Identity exchanges T1 for resource token (T2)
# THIS IS WHERE CA POLICY SHOULD BLOCK THE HIGH-RISK AGENT
# ============================================================
Write-Host "`nStep 2: Agent Identity requesting resource token (T2)..." -ForegroundColor Cyan
Write-Host "This is where the Conditional Access policy should block..." -ForegroundColor Yellow

$step2Body = @{
    client_id                = $agentIdentityClientId
    scope                    = "https://graph.microsoft.com/.default"  # Resource to access
    client_assertion_type    = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
    client_assertion         = $t1Token
    grant_type              = "client_credentials"
}

try {
    $step2Response = Invoke-RestMethod -Method POST -Uri $tokenUrl -Body $step2Body -ContentType "application/x-www-form-urlencoded"
    $t2Token = $step2Response.access_token
    
    Write-Host "⚠ WARNING: Agent authenticated successfully!" -ForegroundColor Yellow
    Write-Host "The Conditional Access policy did NOT block the high-risk agent." -ForegroundColor Yellow
    Write-Host "`nAccess Token (T2) obtained: $($t2Token.Substring(0,50))..." -ForegroundColor Green
}
catch {
    Write-Host "✓ BLOCKED: Agent identity access denied!" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    
    if ($_.ErrorDetails.Message) {
        $errorDetails = $_.ErrorDetails.Message | ConvertFrom-Json
        Write-Host "`nError Code: $($errorDetails.error)" -ForegroundColor Yellow
        Write-Host "Description: $($errorDetails.error_description)" -ForegroundColor Yellow
    }
    
    Write-Host "`n✓✓ SUCCESS: Conditional Access policy is working!" -ForegroundColor Green
    Write-Host "The high-risk agent was blocked from obtaining an access token." -ForegroundColor Green
}
