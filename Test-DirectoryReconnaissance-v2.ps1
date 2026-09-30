<#
.SYNOPSIS
    v2 clean-room harness for "Entra Directory Reconnaissance"
    (riskEventType: entraDirectoryReconnaissance).

.DESCRIPTION
    Per Microsoft product-group guidance, the rule looks for an agent PERFORMING:
      * a listed HIGHER-RISK directory operation, OR
      * a short BURST of listed operations, OR
      * an operation NOT PREVIOUSLY SEEN for that agent.
    The higher-risk subset (confirmed):
      Read ServicePrincipal owners
      Read ServicePrincipal appRoleAssignedTo
      Read User owners            (no clean public Graph path - see note)
      Read User appRoleAssignments
      Read Application extensionProperties
    These are PERFORMED reads, so they must SUCCEED (200) - the agent needs
    Directory.Read.All. A fresh agent also satisfies "not previously seen."
    The listed paths are telemetry match labels, not API commands; confirm the
    real call produces the label in the agent's logs.

    TWO RUNS (because admin consent is interactive and can't run in-script):
      RUN 1 - from scratch (no -BlueprintAppId):
              creates blueprint + principal + secret + inheritablePermissions
              (allAllowed), then prints the consent command and the exact RUN 2
              command, and exits.
      RUN 2 - after you consent Directory.Read.All (-BlueprintAppId + -ExistingSecret):
              creates a FRESH agent, probes a higher-risk read (must be 200),
              then performs the higher-risk operations as a short burst, logs
              each call, and (optionally) polls.

.NOTES
    "Read User owners" has no clean /users/{id}/owners path in Graph; the label
    exists internally but isn't produced by a simple public call, so it is left
    out. The other four map cleanly. Cleanup commands are printed at the end.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TenantId,
    # Provide after consent to run RUN 2 (the actual recon).
    [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$BlueprintAppId,
    [string]$ExistingSecret,
    # Optional explicit lab targets for the higher-risk reads.
    [string]$TargetServicePrincipalId,
    [string]$TargetUserId,
    [string]$TargetApplicationId,
    [int]$BurstRepeat = 2,
    [int]$BurstGapSeconds = 1,
    [switch]$IncludeUnverifiedUserOwners,
    [string]$NamePrefix = 'LAB-recon2-',
    [int]$DetectionPollMinutes = 0,
    [string]$StatePath   = (Join-Path $PSScriptRoot ("recon2-run-{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))),
    [string]$CallLogPath = (Join-Path $PSScriptRoot ("recon2-calls-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date)))
)
$ErrorActionPreference = 'Stop'; Set-StrictMode -Version Latest
$GraphV1='https://graph.microsoft.com/v1.0'; $GraphBeta='https://graph.microsoft.com/beta'
$BpNs='microsoft.graph.agentIdentityBlueprint'; $Gm='00000003-0000-0000-c000-000000000000'
function Write-Phase{param($m)Write-Host "`n=== $m ===" -ForegroundColor Cyan}
function Write-Ok{param($m)Write-Host "  [OK]  $m" -ForegroundColor Green}
function Write-Info{param($m)Write-Host "  [--]  $m" -ForegroundColor Gray}
function Write-Warn2{param($m)Write-Host "  [!!]  $m" -ForegroundColor Yellow}
function Get-AgentToken{param($bp,$sec,$aid)
  $t1=Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{client_id=$bp;scope='api://AzureADTokenExchange/.default';grant_type='client_credentials';client_secret=$sec;fmi_path=$aid}
  $t2=Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{client_id=$aid;scope='https://graph.microsoft.com/.default';grant_type='client_credentials';client_assertion_type='urn:ietf:params:oauth:client-assertion-type:jwt-bearer';client_assertion=$t1.access_token}
  $t2.access_token}
$script:Log=New-Object System.Collections.Generic.List[object]
function Invoke-AgentRead{param($Label,$Uri,$Token)
  $t=(Get-Date).ToUniversalTime();$s=$null
  try{Invoke-RestMethod -Method GET -Uri $Uri -Headers @{Authorization="Bearer $Token"}|Out-Null;$s=200}
  catch{$s=try{[int]$_.Exception.Response.StatusCode.value__}catch{-1}}
  $script:Log.Add([pscustomobject]@{utc=$t.ToString('o');label=$Label;status=$s;uri=$Uri})
  $c=if($s -eq 200){'Green'}elseif($s -in 401,403){'Yellow'}else{'Red'}
  Write-Host ("    {0,-42} -> HTTP {1}" -f $Label,$s) -ForegroundColor $c; return $s}

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

# ============================ RUN 1: build clean room ========================
if (-not $BlueprintAppId) {
  Connect-MgGraph -TenantId $TenantId -Scopes 'AgentIdentityBlueprint.Create','AgentIdentityBlueprintPrincipal.Create','AgentIdentityBlueprint.AddRemoveCreds.All','AgentIdentityBlueprint.ReadWrite.All','User.Read' -NoWelcome
  Write-Ok "Connected as $((Get-MgContext).Account)"
  Write-Phase 'RUN 1 - Build blueprint + principal + secret + inheritable listing'
  $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
  $me=Invoke-MgGraphRequest GET "$GraphV1/me?`$select=id"
  $bp=Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/applications/$BpNs" -Headers @{'OData-Version'='4.0'} -ContentType 'application/json' -Body (@{displayName="$NamePrefix-bp-$stamp";'sponsors@odata.bind'=@("$GraphV1/users/$($me.id)")}|ConvertTo-Json)
  $bpAppId=$bp.appId;$bpObjId=$bp.id
  Write-Ok "Blueprint appId=$bpAppId"
  try{Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/servicePrincipals/microsoft.graph.agentIdentityBlueprintPrincipal" -ContentType 'application/json' -Body (@{appId=$bpAppId}|ConvertTo-Json)|Out-Null;Write-Ok "Principal created."}catch{Write-Warn2 "principal: $($_.Exception.Message)"}
  $secret=$null
  for($i=1;$i -le 10 -and -not $secret;$i++){try{$secret=(Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/applications(appId='$bpAppId')/$BpNs/addPassword" -ContentType 'application/json' -Body (@{passwordCredential=@{displayName="$NamePrefix-secret-$stamp";endDateTime=(Get-Date).ToUniversalTime().AddDays(2).ToString('o')}}|ConvertTo-Json)).secretText}catch{Start-Sleep 15}}
  if(-not $secret){throw "addPassword failed (propagation)."}
  Write-Ok "Secret added."
  Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/applications/$BpNs/$bpObjId/inheritablePermissions" -Headers @{'OData-Version'='4.0'} -ContentType 'application/json' -Body (@{resourceAppId=$Gm;inheritableScopes=@{'@odata.type'='#microsoft.graph.allAllowedScopes';kind='allAllowed'};inheritableRoles=@{'@odata.type'='#microsoft.graph.allAllowedRoles';kind='allAllowed'}}|ConvertTo-Json -Depth 5)|Out-Null
  Write-Ok "Microsoft Graph roles listed as inheritable (allAllowed)."
  Write-Phase 'NEXT: consent Directory.Read.All, then re-run (RUN 2)'
  Write-Host "  1) Clean Entra-module window:" -ForegroundColor Yellow
  Write-Host "     Import-Module Microsoft.Entra.Applications" -ForegroundColor White
  Write-Host "     Connect-Entra -Scopes 'AgentIdentityBlueprint.UpdateAuthProperties.All'" -ForegroundColor White
  Write-Host "     Add-EntraPermissionsToInheritToAgentIdentityBlueprintPrincipal -AgentBlueprintId $bpAppId -Roles @('$Gm/Directory.Read.All')" -ForegroundColor White
  Write-Host "  2) Back here (RUN 2):" -ForegroundColor Yellow
  Write-Host "     .\Test-DirectoryReconnaissance-v2.ps1 -TenantId $TenantId -BlueprintAppId $bpAppId -ExistingSecret '$secret'" -ForegroundColor White
  try{Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null}catch{}
  return
}

# ============================ RUN 2: fresh agent + recon =====================
if (-not $ExistingSecret){throw "RUN 2 needs -ExistingSecret (printed by RUN 1)."}
$scopes=@('AgentIdentity.Create.All','Application.Read.All','User.Read')
if($DetectionPollMinutes -gt 0){$scopes+='IdentityRiskEvent.Read.All'}
Connect-MgGraph -TenantId $TenantId -Scopes $scopes -NoWelcome
Write-Ok "Connected as $((Get-MgContext).Account)"

Write-Phase 'RUN 2 - Create a fresh agent (not previously seen)'
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$me=Invoke-MgGraphRequest GET "$GraphV1/me?`$select=id"
$agentId=$null
for($i=1;$i -le 10 -and -not $agentId;$i++){try{$agentId=(Invoke-MgGraphRequest -Method POST -Uri "$GraphV1/servicePrincipals/microsoft.graph.agentIdentity" -ContentType 'application/json' -Body (@{displayName="$NamePrefix-agent-$stamp";agentIdentityBlueprintId=$BlueprintAppId;'sponsors@odata.bind'=@("$GraphV1/users/$($me.id)")}|ConvertTo-Json)).id}catch{Start-Sleep 15}}
if(-not $agentId){throw "agent create failed."}
Write-Ok "Fresh agent objectId=$agentId"
$tok=$null;for($i=1;$i -le 10 -and -not $tok;$i++){try{$tok=Get-AgentToken $BlueprintAppId $ExistingSecret $agentId}catch{Start-Sleep 15}}
if(-not $tok){throw "agent auth failed."}

@{RunUtc=(Get-Date).ToUniversalTime().ToString('o');TenantId=$TenantId;BlueprintAppId=$BlueprintAppId;AgentObjectId=$agentId;NamePrefix=$NamePrefix;CallLog=$CallLogPath}|ConvertTo-Json|Set-Content $StatePath

Write-Phase 'Probe - a higher-risk read must return 200 (Directory.Read.All consented)'
# resolve targets
if(-not $TargetServicePrincipalId){try{$TargetServicePrincipalId=((Invoke-RestMethod "$GraphV1/servicePrincipals?`$top=1&`$select=id" -Headers @{Authorization="Bearer $tok"}).value|Select-Object -First 1).id}catch{}}
if(-not $TargetUserId){try{$TargetUserId=((Invoke-RestMethod "$GraphV1/users?`$top=1&`$select=id" -Headers @{Authorization="Bearer $tok"}).value|Select-Object -First 1).id}catch{}}
if(-not $TargetApplicationId){try{$TargetApplicationId=((Invoke-RestMethod "$GraphV1/applications?`$top=1&`$select=id" -Headers @{Authorization="Bearer $tok"}).value|Select-Object -First 1).id}catch{}}
if(-not $TargetServicePrincipalId){Write-Warn2 "Could not list a service principal - Directory.Read.All likely NOT consented.";Write-Host "  Consent it (clean Entra window):" -ForegroundColor Yellow;Write-Host "    Add-EntraPermissionsToInheritToAgentIdentityBlueprintPrincipal -AgentBlueprintId $BlueprintAppId -Roles @('$Gm/Directory.Read.All')" -ForegroundColor White;throw "Prerequisite not met."}
Write-Info "Targets: SP=$TargetServicePrincipalId User=$TargetUserId App=$TargetApplicationId"

Write-Phase 'Higher-risk directory reads (short burst; expect 200)'
$ops=@()
if($TargetServicePrincipalId){$ops+=@{L='Read ServicePrincipal owners';U="$GraphV1/servicePrincipals/$TargetServicePrincipalId/owners"};$ops+=@{L='Read ServicePrincipal appRoleAssignedTo';U="$GraphV1/servicePrincipals/$TargetServicePrincipalId/appRoleAssignedTo"}}
if($TargetUserId){$ops+=@{L='Read User appRoleAssignments';U="$GraphV1/users/$TargetUserId/appRoleAssignments"};if($IncludeUnverifiedUserOwners){$ops+=@{L='Read User owners (UNVERIFIED->ownedObjects)';U="$GraphV1/users/$TargetUserId/ownedObjects"}}}
if($TargetApplicationId){$ops+=@{L='Read Application extensionProperties';U="$GraphV1/applications/$TargetApplicationId/extensionProperties"}}
for($b=1;$b -le $BurstRepeat;$b++){Write-Info "Burst pass $b/$BurstRepeat";foreach($op in $ops){Invoke-AgentRead $op.L $op.U $tok|Out-Null;Start-Sleep -Seconds $BurstGapSeconds}}
$script:Log|Export-Csv -Path $CallLogPath -NoTypeInformation -Encoding UTF8
$ok=@($script:Log|Where-Object status -eq 200).Count
Write-Ok "Recorded $($script:Log.Count) higher-risk reads ($ok x 200) -> $CallLogPath"
if($ok -eq 0){Write-Warn2 "No 200s - reads failed; Directory.Read.All not effective. Consent it and re-run."}

if($DetectionPollMinutes -gt 0){
  Write-Phase 'Poll for entraDirectoryReconnaissance'
  $deadline=(Get-Date).AddMinutes($DetectionPollMinutes);$filter="riskEventType eq 'entraDirectoryReconnaissance' and agentId eq '$agentId'"
  do{try{$r=Invoke-MgGraphRequest GET "$GraphBeta/identityProtection/agentRiskDetections?`$filter=$([uri]::EscapeDataString($filter))&`$top=25";if(@($r.value).Count){Write-Ok "DETECTION FOUND";($r.value|ConvertTo-Json -Depth 6)|Write-Host;break}}catch{Write-Warn2 $_.Exception.Message};if((Get-Date) -lt $deadline){Start-Sleep 300}}while((Get-Date) -lt $deadline)
}

Write-Phase 'Cleanup (after it fires)'
Write-Host "  Invoke-MgGraphRequest -Method DELETE -Uri `"$GraphV1/servicePrincipals/$agentId`"" -ForegroundColor DarkGray
Write-Host "  Invoke-MgGraphRequest -Method DELETE -Uri `"$GraphV1/applications(appId='$BlueprintAppId')`"" -ForegroundColor DarkGray
Write-Info "Poll later: .\Get-AgentRiskDetection.ps1 -TenantId $TenantId -AgentObjectId $agentId -RiskEventType entraDirectoryReconnaissance"
try{Disconnect-MgGraph -ErrorAction SilentlyContinue|Out-Null}catch{}
Write-Phase 'Done'
