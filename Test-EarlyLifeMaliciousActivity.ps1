<#
.SYNOPSIS
    Lab harness for the Entra ID Protection for Agents detection:
    "Early life malicious activity" (riskEventType: earlyLifeMaliciousActivity).

.DESCRIPTION
    This detection is the one exception to Learning Mode. While Learning Mode<#
.SYNOPSIS
    v2 harness for "Early Life Malicious Activity" (earlyLifeMaliciousActivity),
    rebuilt to match Microsoft product-group guidance on how the detection
    actually triggers.

.DESCRIPTION
    CORRECTED MODEL (this replaces the burst-of-403s approach in v1):
      * The detection is driven by operation labels across FIVE activity
        categories: (1) environment mapping, (2) security-posture assessment,
        (3) privilege-related activity, (4) persistence-related changes,
        (5) data-access activity.
      * Trigger: a NEW agent, during its FIRST WEEK, that exercises AT LEAST
        TWO DIFFERENT categories.
      * The operations must be PERFORMED with the agent's SUPPORTED permissions
        (they must SUCCEED / 200 and appear in logs as actions the agent did).
        A 403 is a FAILED attempt - it feeds failedAccessAttempt, NOT early-life.
      * Evaluation is normalized hourly/daily, so activity is PACED over time,
        not fired in one micro-burst.
      * The listed paths are TELEMETRY MATCH LABELS, not API commands - confirm
        the real API and how it appears in logs.

    This script therefore:
      Phase 1  Create a FRESH agent under a blueprint that already inherits the
               two required read roles (Directory.Read.All + AuditLog.Read.All).
      Phase 2  PROBE both categories - verify the reads actually return 200
               (i.e. the roles are consented). If a category 403s, stop and
               print the exact consent command; do NOT proceed with failures.
      Phase 3  PACED activity: over several rounds spread across time, the agent
               performs SUCCESSFUL reads across BOTH categories
               (environment mapping + security-posture assessment).
      Phase 4  Poll + cleanup note.

    PREREQUISITE (one-time, on the blueprint):
      inheritablePermissions must list Microsoft Graph (allAllowed roles) AND
      both roles must be admin-consented on the blueprint principal:
        Directory.Read.All   (environment mapping)
        AuditLog.Read.All    (security-posture assessment)
      Use Grant-BlueprintInheritablePermission.ps1 for condition 1, then consent
      each role (clean Entra-module window):
        Add-EntraPermissionsToInheritToAgentIdentityBlueprintPrincipal `
          -AgentBlueprintId <bp> -Roles @('00000003-0000-0000-c000-000000000000/Directory.Read.All')
        Add-EntraPermissionsToInheritToAgentIdentityBlueprintPrincipal `
          -AgentBlueprintId <bp> -Roles @('00000003-0000-0000-c000-000000000000/AuditLog.Read.All')

.NOTES
    Two categories are enough per the PG ("read groups plus directory audit
    records"). This uses the agent's supported permissions only - no 403-probing,
    no permission bypass. Re-run it daily across the agent's first week to
    reinforce the signal against hourly/daily normalization.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$BlueprintAppId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TenantId,
    [Parameter(Mandatory)][string]$ExistingSecret,

    # Reuse an agent (must still be in its first week). Omit to create a fresh one.
    [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$ReuseAgentObjectId,

    # Pacing: rounds of multi-category activity, spread by this gap.
    [int]$Rounds = 4,
    [int]$RoundGapMinutes = 15,

    [string]$NamePrefix = 'LAB-earlylife2-',
    [int]$DetectionPollMinutes = 0,      # 0 = don't poll here; use Get-AgentRiskDetection.ps1 later
    [string]$StatePath   = (Join-Path $PSScriptRoot ("earlylife2-run-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))),
    [string]$CallLogPath = (Join-Path $PSScriptRoot ("earlylife2-calls-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date)))
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$GraphV1 = 'https://graph.microsoft.com/v1.0'
$GraphBeta = 'https://graph.microsoft.com/beta'

function Write-Phase{param($m)Write-Host "`n=== $m ===" -ForegroundColor Cyan}
function Write-Ok{param($m)Write-Host "  [OK]  $m" -ForegroundColor Green}
function Write-Info{param($m)Write-Host "  [--]  $m" -ForegroundColor Gray}
function Write-Warn2{param($m)Write-Host "  [!!]  $m" -ForegroundColor Yellow}

function Get-AgentToken {
    param($Bp,$Secret,$AgentId)
    $t1 = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
        client_id=$Bp; scope='api://AzureADTokenExchange/.default'; grant_type='client_credentials'; client_secret=$Secret; fmi_path=$AgentId }
    $t2 = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
        client_id=$AgentId; scope='https://graph.microsoft.com/.default'; grant_type='client_credentials'
        client_assertion_type='urn:ietf:params:oauth:client-assertion-type:jwt-bearer'; client_assertion=$t1.access_token }
    return $t2.access_token
}

$script:Log = New-Object System.Collections.Generic.List[object]
function Invoke-AgentRead {
    param($Category,$Label,$Uri,$Token,[switch]$Eventual)
    $h = @{ Authorization = "Bearer $Token" }
    if ($Eventual) { $h['ConsistencyLevel'] = 'eventual' }
    $t=(Get-Date).ToUniversalTime(); $status=$null
    try { Invoke-RestMethod -Method GET -Uri $Uri -Headers $h | Out-Null; $status=200 }
    catch { $status = try{[int]$_.Exception.Response.StatusCode.value__}catch{-1} }
    $script:Log.Add([pscustomobject]@{utc=$t.ToString('o');category=$Category;label=$Label;status=$status;uri=$Uri})
    $c = if($status -eq 200){'Green'}elseif($status -in 401,403){'Yellow'}else{'Red'}
    Write-Host ("    {0,-22} {1,-42} -> HTTP {2}" -f $Category,$Label,$status) -ForegroundColor $c
    return $status
}

# Operation sets - MS telemetry labels mapped to the real Graph read.
# Category 1: environment mapping (covered by Directory.Read.All)
$envOps = @(
    @{ L='servicePrincipals';                           U="$GraphV1/servicePrincipals?`$top=20&`$select=id,appId" }
    @{ L='servicePrincipals/$count';                    U="$GraphV1/servicePrincipals/`$count"; E=$true }
    @{ L='applications';                                U="$GraphV1/applications?`$top=20&`$select=id,appId" }
    @{ L='users/$count';                                U="$GraphV1/users/`$count"; E=$true }
    @{ L='groups';                                      U="$GraphV1/groups?`$top=20&`$select=id" }
    @{ L='roleManagement/directory/roleDefinitions';    U="$GraphV1/roleManagement/directory/roleDefinitions?`$top=20" }
    @{ L='roleManagement/directory/roleAssignments';    U="$GraphV1/roleManagement/directory/roleAssignments?`$top=20" }
)
# Category 2: security-posture assessment (covered by AuditLog.Read.All)
$postureOps = @(
    @{ L='auditLogs/directoryAudits';                   U="$GraphV1/auditLogs/directoryAudits?`$top=5" }
    @{ L='auditLogs/signIns';                           U="$GraphV1/auditLogs/signIns?`$top=5" }
)

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
$scopes = @('Application.Read.All')
if (-not $ReuseAgentObjectId) { $scopes += 'AgentIdentity.Create.All','User.Read' }
if ($DetectionPollMinutes -gt 0) { $scopes += 'IdentityRiskEvent.Read.All' }
Connect-MgGraph -TenantId $TenantId -Scopes $scopes -NoWelcome
Write-Ok "Connected as $((Get-MgContext).Account)"

# =============================================================================
Write-Phase 'Phase 1 - Fresh first-week agent under the granted blueprint'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ($ReuseAgentObjectId) {
    $agentId = $ReuseAgentObjectId
    Write-Info "Reusing agent $agentId (must still be within its first week)."
} else {
    $me = Invoke-MgGraphRequest -Method GET -Uri "$GraphV1/me?`$select=id,userPrincipalName"
    $agentName = "$NamePrefix-agent-$stamp"
    $agentId = $null
    for ($i=1; $i -le 10 -and -not $agentId; $i++) {
        try { $a = Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/servicePrincipals/microsoft.graph.agentIdentity" -ContentType 'application/json' `
                -Body (@{ displayName=$agentName; agentIdentityBlueprintId=$BlueprintAppId; 'sponsors@odata.bind'=@("$GraphV1/users/$($me.id)") } | ConvertTo-Json)
              $agentId = $a.id }
        catch { Write-Info "agent create attempt $i not ready; waiting 15s..."; Start-Sleep 15 }
    }
    if (-not $agentId) { throw "Could not create agent." }
    Write-Ok "Created fresh agent '$agentName'  objectId=$agentId"
}

$tok = $null
for ($i=1; $i -le 10 -and -not $tok; $i++) {
    try { $tok = Get-AgentToken -Bp $BlueprintAppId -Secret $ExistingSecret -AgentId $agentId }
    catch { Write-Info "token attempt $i not ready; waiting 15s..."; Start-Sleep 15 }
}
if (-not $tok) { throw "Agent could not authenticate." }
Write-Ok "Agent authenticated."

$state = [ordered]@{ RunUtc=(Get-Date).ToUniversalTime().ToString('o'); TenantId=$TenantId
    BlueprintAppId=$BlueprintAppId; AgentObjectId=$agentId; NamePrefix=$NamePrefix
    CreatedFresh=(-not $ReuseAgentObjectId); Rounds=$Rounds; RoundGapMinutes=$RoundGapMinutes; CallLog=$CallLogPath }
$state | ConvertTo-Json -Depth 6 | Set-Content $StatePath

# =============================================================================
Write-Phase 'Phase 2 - Probe both categories (must be 200 = permissions consented)'
$envProbe     = Invoke-AgentRead -Category 'environment-mapping' -Label 'groups (probe)'              -Uri "$GraphV1/groups?`$top=1&`$select=id" -Token $tok
$postureProbe = Invoke-AgentRead -Category 'security-posture'    -Label 'auditLogs/directoryAudits (probe)' -Uri "$GraphV1/auditLogs/directoryAudits?`$top=1" -Token $tok

$gm = '00000003-0000-0000-c000-000000000000'
if ($envProbe -ne 200) {
    Write-Warn2 "Environment-mapping probe returned $envProbe - Directory.Read.All is not effective for this agent."
    Write-Host "  Consent it (clean Entra-module window):" -ForegroundColor Yellow
    Write-Host "    Add-EntraPermissionsToInheritToAgentIdentityBlueprintPrincipal -AgentBlueprintId $BlueprintAppId -Roles @('$gm/Directory.Read.All')" -ForegroundColor White
}
if ($postureProbe -ne 200) {
    Write-Warn2 "Security-posture probe returned $postureProbe - AuditLog.Read.All is not effective for this agent."
    Write-Host "  Consent it (clean Entra-module window):" -ForegroundColor Yellow
    Write-Host "    Add-EntraPermissionsToInheritToAgentIdentityBlueprintPrincipal -AgentBlueprintId $BlueprintAppId -Roles @('$gm/AuditLog.Read.All')" -ForegroundColor White
}
if ($envProbe -ne 200 -or $postureProbe -ne 200) {
    Write-Warn2 "Need BOTH categories to succeed for a valid two-category early-life signal. Consent the missing role(s), wait a few minutes, re-run."
    throw "Prerequisite not met: both category reads must return 200."
}
Write-Ok "Both categories return 200 - the agent can PERFORM operations in two categories."

# =============================================================================
Write-Phase "Phase 3 - Paced two-category activity ($Rounds rounds, ${RoundGapMinutes}m apart)"
Write-Info "Each round performs SUCCESSFUL reads across environment-mapping + security-posture."
Write-Info "Pacing matters: hourly/daily normalization. Re-run daily across the first week to reinforce."
for ($r=1; $r -le $Rounds; $r++) {
    Write-Info "Round $r/$Rounds  ($(Get-Date -Format HH:mm))"
    # refresh token each round (also natural, benign sign-ins)
    try { $tok = Get-AgentToken -Bp $BlueprintAppId -Secret $ExistingSecret -AgentId $agentId } catch { Write-Warn2 "token refresh failed: $($_.Exception.Message)" }
    foreach ($op in $envOps)     { Invoke-AgentRead -Category 'environment-mapping' -Label $op.L -Uri $op.U -Token $tok -Eventual:([bool]($op.E)) | Out-Null; Start-Sleep -Seconds 2 }
    foreach ($op in $postureOps) { Invoke-AgentRead -Category 'security-posture'    -Label $op.L -Uri $op.U -Token $tok | Out-Null; Start-Sleep -Seconds 2 }
    $script:Log | Export-Csv -Path $CallLogPath -NoTypeInformation -Encoding UTF8
    if ($r -lt $Rounds) { Write-Info "Sleeping ${RoundGapMinutes}m before next round..."; Start-Sleep -Seconds ($RoundGapMinutes*60) }
}

$ok2   = @($script:Log | Where-Object status -eq 200).Count
$cat1  = @($script:Log | Where-Object {$_.category -eq 'environment-mapping' -and $_.status -eq 200}).Count
$cat2  = @($script:Log | Where-Object {$_.category -eq 'security-posture' -and $_.status -eq 200}).Count
Write-Ok "Done. $ok2 successful category operations logged -> $CallLogPath"
Write-Info "Environment-mapping successes: $cat1   Security-posture successes: $cat2"
if ($cat1 -gt 0 -and $cat2 -gt 0) { Write-Ok "Two DISTINCT categories exercised with success - the early-life two-category condition is met." }
else { Write-Warn2 "One category has no successes - not a valid two-category signal. Check consent." }

# =============================================================================
Write-Phase 'Phase 4 - Detection & cleanup'
Write-Info "Offline detection. Watch: ID Protection > Risk detections > Agent detections (agent $agentId)."
Write-Info "Poll later:  .\Get-AgentRiskDetection.ps1 -TenantId $TenantId -AgentObjectId $agentId"
if (-not $ReuseAgentObjectId) {
    Write-Info "When done (after it fires), delete the fresh agent:"
    Write-Host "  Invoke-MgGraphRequest -Method DELETE -Uri `"$GraphV1/servicePrincipals/$agentId`"" -ForegroundColor DarkGray
}
Write-Info "State: $StatePath"
try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}
Write-Phase 'Done'
    suppresses BEHAVIOURAL alerts for agents without enough history, a separate
    detector runs in parallel to catch a "newly created agent [that] immediately
    exhibited MULTIPLE suspicious behaviour patterns, acting like an attacker."
    So the trigger profile is precise:
        brand-new agent  +  NO benign history  +  several attacker patterns at once,
    all within the agent's first minutes of life.

    This script builds a clean room from scratch and then misbehaves immediately:
      Phase 1  Create a fresh blueprint, its principal, a secret, and one agent.
      Phase 2  IMMEDIATELY (no warm-up) run a multi-pattern attacker burst:
                 P1  Sign-in spike       - many rapid token acquisitions (T1->T2)
                 P2  Failed access probe  - unauthorized resource reads -> 403
                 P3  Directory recon      - broad enumeration attempts -> 403
               interleaved, so the agent's very first behaviour looks like an
               attacker sweeping a freshly stolen identity.
      Phase 3  Poll agentRiskDetections for earlyLifeMaliciousActivity.
      Phase 4  Print the cleanup commands (nothing auto-deleted - the activity
               must persist for the offline detection to correlate).

    Why no permissions are granted: an attacker on a new agent probes broadly and
    mostly fails. Failed probing (403) + a sign-in spike are themselves the
    suspicious patterns; granting Directory.Read.All would add benign history and
    a propagation delay, weakening the "malicious from birth" signal. So the agent
    is deliberately left unpermissioned.

.NOTES
    Scopes: AgentIdentityBlueprint.Create, AgentIdentityBlueprintPrincipal.Create,
            AgentIdentityBlueprint.AddRemoveCreds.All, AgentIdentity.Create.All,
            User.Read, IdentityRiskEvent.Read.All
    Everything created is tagged 'LAB-earlylife-' for guarded cleanup.
    Blog note: capture the run's timeline (CSV) + the Agent detections tab entry;
    the interleaved multi-pattern burst is the story.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TenantId,

    # Reuse an existing blueprint instead of creating one (skips Phase 1 creation).
    [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$BlueprintAppId,
    [string]$ExistingSecret,

    # Attacker-burst tuning.
    [int]$SpikeCount = 20,        # rapid token acquisitions (sign-in spike)
    [int]$SpikeGapMs = 400,
    [int]$ProbeRepeat = 3,        # failed-access + recon passes

    [string]$NamePrefix = 'LAB-earlylife-',
    [int]$DetectionPollMinutes = 60,
    [int]$DetectionPollIntervalSeconds = 300,
    [string]$StatePath   = (Join-Path $PSScriptRoot ("earlylife-run-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))),
    [string]$CallLogPath = (Join-Path $PSScriptRoot ("earlylife-calls-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date)))
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$GraphV1 = 'https://graph.microsoft.com/v1.0'
$GraphBeta = 'https://graph.microsoft.com/beta'
$BpNs = 'microsoft.graph.agentIdentityBlueprint'

function Write-Phase{param([string]$m)Write-Host "`n=== $m ===" -ForegroundColor Cyan}
function Write-Ok{param([string]$m)Write-Host "  [OK]  $m" -ForegroundColor Green}
function Write-Info{param([string]$m)Write-Host "  [--]  $m" -ForegroundColor Gray}
function Write-Warn2{param([string]$m)Write-Host "  [!!]  $m" -ForegroundColor Yellow}

$script:Log = New-Object System.Collections.Generic.List[object]
function Add-Log{param($pattern,$label,$status,$note)
    $script:Log.Add([pscustomobject]@{utc=(Get-Date).ToUniversalTime().ToString('o');pattern=$pattern;label=$label;status=$status;note=$note})}

function Get-AgentToken {
    param([string]$Bp,[string]$Secret,[string]$AgentId)
    $t1 = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
        client_id=$Bp; scope='api://AzureADTokenExchange/.default'; grant_type='client_credentials'
        client_secret=$Secret; fmi_path=$AgentId }
    $t2 = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
        client_id=$AgentId; scope='https://graph.microsoft.com/.default'; grant_type='client_credentials'
        client_assertion_type='urn:ietf:params:oauth:client-assertion-type:jwt-bearer'; client_assertion=$t1.access_token }
    return $t2.access_token
}

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
$connectScopes = @('AgentIdentityBlueprint.Create','AgentIdentityBlueprintPrincipal.Create',
    'AgentIdentityBlueprint.AddRemoveCreds.All','AgentIdentity.Create.All','User.Read','IdentityRiskEvent.Read.All')
Connect-MgGraph -TenantId $TenantId -Scopes $connectScopes -NoWelcome
Write-Ok "Connected as $((Get-MgContext).Account)"

# =============================================================================
Write-Phase 'Phase 1 - Clean room: fresh blueprint, principal, secret, agent'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$me = Invoke-MgGraphRequest -Method GET -Uri "$GraphV1/me?`$select=id,userPrincipalName"

if ($BlueprintAppId -and $ExistingSecret) {
    Write-Info "Reusing supplied blueprint $BlueprintAppId (skipping creation)."
    $bpAppId = $BlueprintAppId; $secret = $ExistingSecret; $createdBlueprint = $false
} else {
    # 1a. Blueprint
    $bpName = "$NamePrefix-bp-$stamp"
    $bp = Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/applications/$BpNs" `
        -Headers @{'OData-Version'='4.0'} -ContentType 'application/json' `
        -Body (@{ displayName=$bpName; 'sponsors@odata.bind'=@("$GraphV1/users/$($me.id)") } | ConvertTo-Json)
    $bpAppId = $bp.appId
    Write-Ok "Blueprint created: '$bpName'  appId=$bpAppId"

    # 1b. Blueprint principal
    try {
        Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal" `
            -ContentType 'application/json' -Body (@{ appId=$bpAppId } | ConvertTo-Json) | Out-Null
        Write-Ok "Blueprint principal created."
    } catch { Write-Warn2 "Principal create: $($_.Exception.Message) (may already exist / provisioning)" }

    # 1c. Secret (retry for propagation)
    $secret = $null
    for ($i=1; $i -le 10 -and -not $secret; $i++) {
        try {
            $add = Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/applications(appId='$bpAppId')/$BpNs/addPassword" `
                -ContentType 'application/json' -Body (@{ passwordCredential=@{ displayName="$NamePrefix-secret-$stamp"; endDateTime=(Get-Date).ToUniversalTime().AddDays(1).ToString('o') } } | ConvertTo-Json)
            $secret = $add.secretText
        } catch { Write-Info "addPassword attempt $i not ready ($($_.Exception.Message)); waiting 15s..."; Start-Sleep 15 }
    }
    if (-not $secret) { throw "Could not add secret after retries - blueprint still propagating." }
    Write-Ok "Secret added."
    $createdBlueprint = $true
}

# 1d. Agent identity (retry for propagation)
$agentName = "$NamePrefix-agent-$stamp"
$agentId = $null
for ($i=1; $i -le 10 -and -not $agentId; $i++) {
    try {
        $agent = Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/servicePrincipals/microsoft.graph.agentIdentity" `
            -ContentType 'application/json' -Body (@{ displayName=$agentName; agentIdentityBlueprintId=$bpAppId; 'sponsors@odata.bind'=@("$GraphV1/users/$($me.id)") } | ConvertTo-Json)
        $agentId = $agent.id
    } catch { Write-Info "agent create attempt $i not ready ($($_.Exception.Message)); waiting 15s..."; Start-Sleep 15 }
}
if (-not $agentId) { throw "Could not create agent after retries." }
Write-Ok "Agent created: '$agentName'  objectId=$agentId  (BORN - clock starts now)"

$state = [ordered]@{ RunUtc=(Get-Date).ToUniversalTime().ToString('o'); TenantId=$TenantId
    BlueprintAppId=$bpAppId; AgentObjectId=$agentId; AgentName=$agentName
    CreatedBlueprint=$createdBlueprint; NamePrefix=$NamePrefix; CallLog=$CallLogPath }
$state | ConvertTo-Json -Depth 6 | Set-Content $StatePath

# First token (retry for propagation) - this is also the first "sign-in".
$tok = $null
for ($i=1; $i -le 10 -and -not $tok; $i++) {
    try { $tok = Get-AgentToken -Bp $bpAppId -Secret $secret -AgentId $agentId }
    catch { Write-Info "first token attempt $i not ready ($($_.Exception.Message)); waiting 15s..."; Start-Sleep 15 }
}
if (-not $tok) { throw "Agent could not authenticate after retries." }
Write-Ok "Agent authenticated for the first time."

# =============================================================================
Write-Phase 'Phase 2 - Immediate multi-pattern attacker burst (early life)'
Write-Warn2 "NO warm-up. The agent''s first actions are the attack - this is the early-life signal."

$failTargets = @(
    "$GraphV1/security/alerts_v2?`$top=1",
    "$GraphV1/auditLogs/signIns?`$top=1",
    "$GraphV1/deviceManagement/managedDevices?`$top=1",
    "$GraphBeta/identityGovernance/accessReviews/definitions?`$top=1"
)
$reconTargets = @(
    "$GraphV1/users?`$top=50&`$select=id,userPrincipalName",
    "$GraphV1/servicePrincipals?`$top=50&`$select=id,appId",
    "$GraphV1/applications?`$top=50&`$select=id,appId",
    "$GraphV1/directoryRoles",
    "$GraphV1/groups?`$top=50&`$select=id"
)

function Try-Read{param($uri,$pattern,$label)
    try { Invoke-RestMethod -Method GET -Uri $uri -Headers @{Authorization="Bearer $tok"} | Out-Null; $s=200 }
    catch { $s = try{[int]$_.Exception.Response.StatusCode.value__}catch{-1} }
    Add-Log $pattern $label $s $uri
    $c = if($s -eq 200){'Yellow'}elseif($s -in 401,403){'Green'}else{'Red'}
    Write-Host ("    {0,-14} {1,-30} -> HTTP {2}" -f $pattern,$label,$s) -ForegroundColor $c }

# P1: sign-in spike - rapid repeated token acquisition
Write-Info "P1 sign-in spike: $SpikeCount rapid token acquisitions"
for ($i=1; $i -le $SpikeCount; $i++) {
    try { $tok = Get-AgentToken -Bp $bpAppId -Secret $secret -AgentId $agentId; Add-Log 'signInSpike' "token #$i" 200 $null }
    catch { Add-Log 'signInSpike' "token #$i" -1 $_.Exception.Message }
    if ($i % 5 -eq 0) { Write-Host ("    ...{0}/{1} tokens" -f $i,$SpikeCount) -ForegroundColor Gray }
    Start-Sleep -Milliseconds $SpikeGapMs
}
Write-Ok "Sign-in spike done ($SpikeCount acquisitions in ~$([math]::Round($SpikeCount*$SpikeGapMs/1000))s)."

# P2 + P3 interleaved: failed-access probing and directory recon
for ($p=1; $p -le $ProbeRepeat; $p++) {
    Write-Info "Probe pass $p/$ProbeRepeat (failed-access + recon, interleaved)"
    foreach ($u in $failTargets)  { Try-Read -uri $u -pattern 'failedAccess' -label ($u -replace '.*graph\.com/(v1\.0|beta)/','') ; Start-Sleep -Milliseconds 500 }
    foreach ($u in $reconTargets) { Try-Read -uri $u -pattern 'recon'        -label ($u -replace '.*graph\.com/(v1\.0|beta)/','') ; Start-Sleep -Milliseconds 500 }
}

$script:Log | Export-Csv -Path $CallLogPath -NoTypeInformation -Encoding UTF8
$spike = @($script:Log|Where-Object pattern -eq 'signInSpike').Count
$failed = @($script:Log|Where-Object {$_.pattern -in 'failedAccess','recon' -and $_.status -in 401,403}).Count
$succ = @($script:Log|Where-Object {$_.pattern -in 'failedAccess','recon' -and $_.status -eq 200}).Count
Write-Ok "Attacker burst recorded ($($script:Log.Count) events) -> $CallLogPath"
Write-Info "Patterns emitted: sign-in spike x$spike ; probing failures (401/403) x$failed ; unexpected successes x$succ"
Write-Info "Three distinct suspicious patterns at birth = the early-life malicious profile."

# =============================================================================
Write-Phase 'Phase 3 - Poll for earlyLifeMaliciousActivity'
Write-Warn2 'OFFLINE detection. Portal (ID Protection > Risk detections > Agent detections) is authoritative.'
$deadline=(Get-Date).AddMinutes($DetectionPollMinutes)
$filter="agentId eq '$agentId'"   # widen: catch earlyLife OR any other detection on this fresh agent
do {
  try { $r=Invoke-MgGraphRequest -Method GET -Uri "$GraphBeta/identityProtection/agentRiskDetections?`$filter=$([uri]::EscapeDataString($filter))&`$top=25"
        if(@($r.value).Count){ Write-Ok "DETECTION(S) FOUND on this agent:"; $r.value | ForEach-Object { Write-Host ("   {0}  {1}  {2}" -f $_.riskEventType,$_.riskLevel,$_.detectedDateTime) -ForegroundColor Green }; break } }
  catch { Write-Warn2 "Poll error: $($_.Exception.Message)" }
  if((Get-Date) -lt $deadline){ Write-Info ("Nothing yet - next check in {0}s (deadline {1:HH:mm})." -f $DetectionPollIntervalSeconds,$deadline); Start-Sleep -Seconds $DetectionPollIntervalSeconds }
} while((Get-Date) -lt $deadline)

# =============================================================================
Write-Phase 'Phase 4 - Cleanup (run AFTER the detection surfaces)'
Write-Info "State: $StatePath   Call log: $CallLogPath"
Write-Info "When done, remove the lab artifacts (all tagged '$NamePrefix'):"
Write-Host "  # delete the agent identity" -ForegroundColor DarkGray
Write-Host "  Invoke-MgGraphRequest -Method DELETE -Uri `"$GraphV1/servicePrincipals/$agentId`"" -ForegroundColor DarkGray
if ($createdBlueprint) {
  Write-Host "  # delete the blueprint (removes its secret too)" -ForegroundColor DarkGray
  Write-Host "  Invoke-MgGraphRequest -Method DELETE -Uri `"$GraphV1/applications(appId='$bpAppId')`"" -ForegroundColor DarkGray
} else {
  Write-Host "  # blueprint was reused - sweep its test secret with Clear-LabTestSecrets.ps1 -TestSecretPrefix '$NamePrefix'" -ForegroundColor DarkGray
}
try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}
Write-Phase 'Done'
