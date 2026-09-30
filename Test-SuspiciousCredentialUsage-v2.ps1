<#
.SYNOPSIS
    v2 clean-room harness for "Suspicious Credential Usage"
    (riskEventType: suspiciousCredentialUsage).

.DESCRIPTION
    Per Microsoft product-group guidance:
      Meaning  : create/delete a federated identity credential on the blueprint
                 application or its service principal, OR add a password/client
                 secret. Active labels: Create/Delete Application FIC,
                 Create/Delete ServicePrincipal FIC, AddPassword.
                 (Delete ServicePrincipal FIC is flagged "not observed" - avoid.)
      Timing   : blueprint OLDER THAN SEVEN DAYS; child authentication during a
                 later UTC hour AND within the seven-day alert window.
      Lab path : an authorized admin adds a TEMPORARY credential to a disposable
                 blueprint; a child agent then authenticates SUCCESSFULLY.
      Cleanup  : remove ONLY test credentials - never a production credential.
      Interpretation: the rule CORRELATES the blueprint credential operation with
                 child activity. It does NOT prove use of the exact new credential.

    Because the blueprint must be >7 days old, a from-scratch lab is TWO STAGES:

      -Stage Create   (day 0)   Create blueprint + principal + agent. No secret
                                yet. Record IDs and the creation date.
      -Stage Trigger  (day 7+)  Verify age >= 7 days, add a TEMPORARY tagged
                                secret (the signal), have the child agent
                                authenticate successfully in a later UTC hour,
                                poll, and remove ONLY that test secret.

    If you already have a blueprint older than 7 days, skip Create and run
    -Stage Trigger against it directly.

.NOTES
    Cleanup is guarded: it deletes only the KeyId this run minted, re-validated
    live against the test prefix, and never the last credential on the blueprint.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][ValidateSet('Create','Trigger')][string]$Stage,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TenantId,

    # Required for -Stage Trigger (from the Create output, or an existing >7d blueprint).
    [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$BlueprintAppId,
    [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$AgentObjectId,

    [int]$MinBlueprintAgeDays = 7,
    [string]$Scope = 'https://graph.microsoft.com/.default',
    [string]$TestSecretPrefix = 'LAB-suspcred2-TEST-',
    [string]$NamePrefix = 'LAB-suspcred2-',
    [int]$DetectionPollMinutes = 0,
    [string]$StatePath = (Join-Path $PSScriptRoot ("suspcred2-run-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))),
    [switch]$Force
)
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
$GraphV1='https://graph.microsoft.com/v1.0'; $GraphBeta='https://graph.microsoft.com/beta'
$BpNs='microsoft.graph.agentIdentityBlueprint'
function Write-Phase{param($m)Write-Host "`n=== $m ===" -ForegroundColor Cyan}
function Write-Ok{param($m)Write-Host "  [OK]  $m" -ForegroundColor Green}
function Write-Info{param($m)Write-Host "  [--]  $m" -ForegroundColor Gray}
function Write-Warn2{param($m)Write-Host "  [!!]  $m" -ForegroundColor Yellow}
function Get-JwtBody{param($j)try{if(-not $j -or ($j.Split('.').Count -lt 2)){return $null};$p=$j.Split('.')[1].Replace('-','+').Replace('_','/');switch($p.Length%4){2{$p+='=='}3{$p+='='}};return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))|ConvertFrom-Json}catch{return $null}}

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

# ================================ STAGE: Create ==============================
if ($Stage -eq 'Create') {
  Connect-MgGraph -TenantId $TenantId -Scopes 'AgentIdentityBlueprint.Create','AgentIdentityBlueprintPrincipal.Create','AgentIdentity.Create.All','User.Read' -NoWelcome
  Write-Ok "Connected as $((Get-MgContext).Account)"
  Write-Phase 'Stage Create (day 0) - blueprint + principal + agent (no secret yet)'
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $me=Invoke-MgGraphRequest GET "$GraphV1/me?`$select=id"
  $bp=Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/applications/$BpNs" -Headers @{'OData-Version'='4.0'} -ContentType 'application/json' -Body (@{displayName="$NamePrefix-bp-$stamp";'sponsors@odata.bind'=@("$GraphV1/users/$($me.id)")}|ConvertTo-Json)
  $bpAppId=$bp.appId
  Write-Ok "Blueprint appId=$bpAppId  created=$($bp.createdDateTime)"
  try{Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal" -ContentType 'application/json' -Body (@{appId=$bpAppId}|ConvertTo-Json)|Out-Null;Write-Ok "Principal created."}catch{Write-Warn2 "principal: $($_.Exception.Message)"}
  $agentId=$null
  for($i=1;$i -le 10 -and -not $agentId;$i++){try{$agentId=(Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/servicePrincipals/microsoft.graph.agentIdentity" -ContentType 'application/json' -Body (@{displayName="$NamePrefix-agent-$stamp";agentIdentityBlueprintId=$bpAppId;'sponsors@odata.bind'=@("$GraphV1/users/$($me.id)")}|ConvertTo-Json)).id}catch{Start-Sleep 15}}
  if(-not $agentId){throw "agent create failed."}
  Write-Ok "Agent objectId=$agentId"
  @{Stage='Created';RunUtc=(Get-Date).ToUniversalTime().ToString('o');TenantId=$TenantId;BlueprintAppId=$bpAppId;AgentObjectId=$agentId;BlueprintCreated=$bp.createdDateTime}|ConvertTo-Json|Set-Content $StatePath
  $eligible=(Get-Date).AddDays($MinBlueprintAgeDays)
  Write-Phase "WAIT - the blueprint must be > $MinBlueprintAgeDays days old"
  Write-Info ("Eligible on/after: {0:yyyy-MM-dd HH:mm} local" -f $eligible)
  Write-Info "Then run the trigger stage:"
  Write-Host "  .\Test-SuspiciousCredentialUsage-v2.ps1 -Stage Trigger -TenantId $TenantId -BlueprintAppId $bpAppId -AgentObjectId $agentId" -ForegroundColor White
  Write-Info "State: $StatePath"
  try{Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null}catch{}
  return
}

# =============================== STAGE: Trigger ==============================
if (-not $BlueprintAppId -or -not $AgentObjectId){throw "-Stage Trigger needs -BlueprintAppId and -AgentObjectId (from the Create output)."}
$scopes=@('AgentIdentityBlueprint.AddRemoveCreds.All','Application.Read.All')
if($DetectionPollMinutes -gt 0){$scopes+='IdentityRiskEvent.Read.All'}
Connect-MgGraph -TenantId $TenantId -Scopes $scopes -NoWelcome
Write-Ok "Connected as $((Get-MgContext).Account)"

Write-Phase 'Stage Trigger - verify age, add temp secret, child authenticates'
$bp=Invoke-MgGraphRequest GET "$GraphV1/applications(appId='$BlueprintAppId')?`$select=id,displayName,createdDateTime,passwordCredentials"
$age=((Get-Date).ToUniversalTime()-([datetime]$bp.createdDateTime).ToUniversalTime()).TotalDays
Write-Info ("Blueprint '{0}' age {1:N1} d" -f $bp.displayName,$age)
if($age -lt $MinBlueprintAgeDays){throw ("Blueprint is only {0:N1} d old; the rule wants > {1} d. Wait, or use an older blueprint." -f $age,$MinBlueprintAgeDays)}
Write-Ok "Age requirement met."

$secretName="$TestSecretPrefix$(Get-Date -Format yyyyMMdd-HHmmss)"
$add=Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/applications(appId='$BlueprintAppId')/$BpNs/addPassword" -ContentType 'application/json' -Body (@{passwordCredential=@{displayName=$secretName;endDateTime=(Get-Date).ToUniversalTime().AddDays(2).ToString('o')}}|ConvertTo-Json)
$secret=$add.secretText;$keyId=$add.keyId
Write-Ok "Added temp secret KeyId=$keyId Name='$secretName' (the credential signal)"
$state=[ordered]@{RunUtc=(Get-Date).ToUniversalTime().ToString('o');TenantId=$TenantId;BlueprintAppId=$BlueprintAppId;AgentObjectId=$AgentObjectId;KeyId=$keyId;SecretDisplayName=$secretName;CredentialAddedUtc=(Get-Date).ToUniversalTime().ToString('o')}
$state|ConvertTo-Json|Set-Content $StatePath

# later UTC hour than credential-add
# Parse the stored 'o' timestamp as UTC (a bare [datetime] cast turns the Z-suffixed
# string into LOCAL time, which breaks the same-hour comparison and skips the wait).
$nowUtc=(Get-Date).ToUniversalTime();$addUtc=[datetime]::Parse($state.CredentialAddedUtc,$null,[System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
if($nowUtc.ToString('yyyyMMddHH') -eq $addUtc.ToString('yyyyMMddHH')){
  $next=$addUtc.Date.AddHours($addUtc.Hour+1);$wait=$next-$nowUtc
  if($wait.TotalSeconds -gt 0 -and $wait.TotalMinutes -le 65){Write-Warn2 ("Waiting {0:N0} min to cross into a later UTC hour (PG timing)." -f $wait.TotalMinutes);Start-Sleep -Seconds ([int]$wait.TotalSeconds+5)}
}

# child authenticates successfully (T1 -> T2)
$t1=Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{client_id=$BlueprintAppId;scope='api://AzureADTokenExchange/.default';grant_type='client_credentials';client_secret=$secret;fmi_path=$AgentObjectId}
$t2=Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{client_id=$AgentObjectId;scope=$Scope;grant_type='client_credentials';client_assertion_type='urn:ietf:params:oauth:client-assertion-type:jwt-bearer';client_assertion=$t1.access_token}
$claims=Get-JwtBody $t2.access_token
Write-Ok "Child agent authenticated successfully.$(if($claims){" oid=$($claims.oid)"})"
if($claims -and $claims.oid -ne $AgentObjectId){Write-Warn2 "token oid != AgentObjectId - inspect."}

if($DetectionPollMinutes -gt 0){
  Write-Phase 'Poll for suspiciousCredentialUsage'
  $deadline=(Get-Date).AddMinutes($DetectionPollMinutes);$filter="riskEventType eq 'suspiciousCredentialUsage' and agentId eq '$AgentObjectId'"
  do{try{$r=Invoke-MgGraphRequest GET "$GraphBeta/identityProtection/agentRiskDetections?`$filter=$([uri]::EscapeDataString($filter))&`$top=25";if(@($r.value).Count){Write-Ok "DETECTION FOUND";($r.value|ConvertTo-Json -Depth 6)|Write-Host;break}}catch{Write-Warn2 $_.Exception.Message};if((Get-Date) -lt $deadline){Start-Sleep 300}}while((Get-Date) -lt $deadline)
}

Write-Phase 'Guarded cleanup - remove ONLY this run''s test secret'
$doIt=$Force -or $PSCmdlet.ShouldProcess("blueprint $BlueprintAppId","removePassword $keyId ('$secretName')")
if($doIt){
  $live=Invoke-MgGraphRequest GET "$GraphV1/applications(appId='$BlueprintAppId')?`$select=passwordCredentials"
  $creds=@($live.passwordCredentials);$match=$creds|Where-Object{$_.keyId -eq $keyId}
  if(-not $match){Write-Ok "Already absent."}
  elseif($match.displayName -notlike "$TestSecretPrefix*"){Write-Warn2 "Live name '$($match.displayName)' not test-prefixed - NOT deleting."}
  elseif($creds.Count -le 1){Write-Warn2 "Refusing to remove the last credential."}
  else{Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/applications(appId='$BlueprintAppId')/$BpNs/removePassword" -ContentType 'application/json' -Body (@{keyId=$keyId}|ConvertTo-Json)|Out-Null;Write-Ok "Removed test secret $keyId."}
}else{Write-Warn2 "Cleanup declined. Test secret $keyId still present."}
Write-Info "Poll later: .\Get-AgentRiskDetection.ps1 -TenantId $TenantId -AgentObjectId $AgentObjectId -RiskEventType suspiciousCredentialUsage"
Write-Info "Interpretation: correlation of the blueprint credential op with child activity - NOT proof the exact new secret was used."
try{Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null}catch{}
Write-Phase 'Done'
