<#
.SYNOPSIS
  Deploys the nightly "Active users" group sync Logic App into a customer tenant.

.DESCRIPTION
  1. Checks prerequisites (Azure CLI, sign-in, source group).
  2. Creates the target security group when -ActiveGroupId is not given.
  3. Deploys azuredeploy.json (Logic App stays Disabled, dryRun = true).
  4. Grants the Logic App's managed identity the four Graph application roles.
  5. Enables the Logic App and optionally runs one dry run.

  Needs: Azure CLI, Contributor on the subscription, and a Global Administrator or
  Privileged Role Administrator (for the Graph role grants and for creating the group).

.EXAMPLE
  .\deploy.ps1 -SubscriptionId <id> -ResourceGroup rg-active-users -SourceGroupId <guid> `
      -SenderMailbox reports@contoso.com -NotifyEmail it-admins@contoso.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$SourceGroupId,
    [Parameter(Mandatory)] [string]$SenderMailbox,
    [Parameter(Mandatory)] [string]$NotifyEmail,
    [string]$Location = "westeurope",
    [string]$LogicAppName = "la-active-users-sync",
    [string]$ActiveGroupId,
    [string]$ActiveGroupName = "Active-Users-60d",
    [int]$InactivityDays = 60,
    [int]$MaxRemovalPercent = 10,
    [int]$ScheduleHour = 2,
    [string]$ScheduleTimeZone = "Israel Standard Time",
    [string]$TenantId,
    [switch]$UseDeviceCode,
    [switch]$SkipTestRun
)

$ErrorActionPreference = "Stop"
$graph = "https://graph.microsoft.com/v1.0"
$graphAppId = "00000003-0000-0000-c000-000000000000"
$roles = "AuditLog.Read.All", "Directory.Read.All", "GroupMember.ReadWrite.All", "Mail.Send"
$template = Join-Path $PSScriptRoot "azuredeploy.json"

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }

function Invoke-Graph([string]$Method, [string]$Uri, $Body) {
    $azArgs = @("rest", "--method", $Method, "--url", $Uri, "--resource", "https://graph.microsoft.com", "-o", "json")
    if ($Body) {
        $file = New-TemporaryFile
        $Body | ConvertTo-Json -Depth 10 | Set-Content $file -Encoding utf8
        $azArgs += @("--headers", "Content-Type=application/json", "--body", "@$file")
    }
    $out = az @azArgs
    if ($LASTEXITCODE -ne 0) { throw "Graph call failed: $Method $Uri" }
    if ($file) { Remove-Item $file -Force }
    if ($out) { $out | ConvertFrom-Json }
}

Step "Checking prerequisites"
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI is required: https://aka.ms/installazurecliwindows" }
if ($SourceGroupId -notmatch '^[0-9a-fA-F-]{36}$') { throw "SourceGroupId must be the group's object ID (GUID)." }

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account -or ($TenantId -and $account.tenantId -ne $TenantId)) {
    $loginArgs = @("login")
    if ($TenantId) { $loginArgs += @("--tenant", $TenantId) }
    if ($UseDeviceCode) { $loginArgs += "--use-device-code" }
    az @loginArgs | Out-Null
}
az account set --subscription $SubscriptionId
$account = az account show | ConvertFrom-Json
Write-Host "Tenant $($account.tenantId), subscription $($account.name)"

$source = Invoke-Graph GET "$graph/groups/${SourceGroupId}?`$select=id,displayName"
Write-Host "Source group: $($source.displayName)"

$skus = (Invoke-Graph GET "$graph/subscribedSkus?`$select=servicePlans").value.servicePlans.servicePlanName
if (-not ($skus -match "AAD_PREMIUM")) {
    Write-Warning "No Entra ID P1/P2 service plan found. Graph signInActivity needs a P1/P2 license; the flow will not return sign-in data without it."
}

Step "Target group"
if (-not $ActiveGroupId) {
    $existing = (Invoke-Graph GET "$graph/groups?`$filter=displayName eq '$ActiveGroupName'&`$select=id,displayName").value
    if ($existing) {
        $ActiveGroupId = $existing[0].id
        Write-Host "Using existing group '$ActiveGroupName' ($ActiveGroupId)"
    } else {
        $new = Invoke-Graph POST "$graph/groups" @{
            displayName = $ActiveGroupName; mailNickname = ($ActiveGroupName -replace '[^a-zA-Z0-9]', '')
            mailEnabled = $false; securityEnabled = $true
            description = "Maintained by Logic App $LogicAppName. Do not edit manually."
        }
        $ActiveGroupId = $new.id
        Write-Host "Created group '$ActiveGroupName' ($ActiveGroupId)"
    }
}
if ($ActiveGroupId -eq $SourceGroupId) { throw "The target group must differ from the source group." }

Step "Deploying Logic App (Disabled, dryRun = true)"
az group create --name $ResourceGroup --location $Location | Out-Null
$result = az deployment group create --resource-group $ResourceGroup --name "active-users-sync" `
    --template-file $template --only-show-errors `
    --parameters logicAppName=$LogicAppName sourceGroupId=$SourceGroupId activeGroupId=$ActiveGroupId `
                 senderMailbox=$SenderMailbox notifyEmail=$NotifyEmail inactivityDays=$InactivityDays `
                 maxRemovalPercent=$MaxRemovalPercent scheduleHour=$ScheduleHour `
                 scheduleTimeZone="$ScheduleTimeZone" dryRun=true state=Disabled `
    --query properties.outputs.logicAppPrincipalId.value -o tsv
if ($LASTEXITCODE -ne 0 -or -not $result) { throw "Deployment failed." }
$principalId = $result.Trim()
Write-Host "Managed identity: $principalId"

Step "Granting Microsoft Graph application roles"
$graphSp = (Invoke-Graph GET "$graph/servicePrincipals?`$filter=appId eq '$graphAppId'").value[0]
$granted = (Invoke-Graph GET "$graph/servicePrincipals/$principalId/appRoleAssignments").value
foreach ($name in $roles) {
    $role = $graphSp.appRoles | Where-Object { $_.value -eq $name -and $_.allowedMemberTypes -contains "Application" }
    if ($granted | Where-Object { $_.appRoleId -eq $role.id }) { Write-Host "  already granted: $name"; continue }
    Invoke-Graph POST "$graph/servicePrincipals/$principalId/appRoleAssignments" @{
        principalId = $principalId; resourceId = $graphSp.id; appRoleId = $role.id } | Out-Null
    Write-Host "  granted: $name"
}

Step "Waiting for the role grants to propagate (about 3 minutes)"
Start-Sleep -Seconds 180

Step "Enabling the Logic App"
$workflowUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Logic/workflows/$LogicAppName"
az rest --method post --url "$workflowUrl/enable?api-version=2016-06-01" | Out-Null

function Wait-LatestRun {
    $status = "Running"
    for ($i = 0; $i -lt 40 -and $status -in @("Running", "Waiting", ""); $i++) {
        Start-Sleep -Seconds 10
        $status = az rest --method get --url "$workflowUrl/runs?api-version=2016-06-01" --query "value[0].properties.status" -o tsv
    }
    $status
}

if (-not $SkipTestRun) {
    Step "Checking the first run (enabling starts one immediately; dry run, nothing is changed)"
    $status = Wait-LatestRun
    for ($attempt = 1; $attempt -le 2 -and $status -ne "Succeeded"; $attempt++) {
        Write-Host "Run status: $status. Waiting 2 minutes and retrying (permissions may still be propagating)..."
        Start-Sleep -Seconds 120
        az rest --method post --url "$workflowUrl/triggers/Recurrence_Nightly/run?api-version=2016-06-01" | Out-Null
        $status = Wait-LatestRun
    }
    Write-Host "Test run status: $status"
    if ($status -ne "Succeeded") {
        Write-Warning "The test run did not succeed. Open the run history in the portal and check the failed step (see README, Troubleshooting)."
    }
}

Step "Done"
Write-Host @"
Logic App : $LogicAppName  (resource group $ResourceGroup)
Source    : $SourceGroupId
Target    : $ActiveGroupId
Mode      : DRY RUN (reports only). Review the CSV emails sent to $NotifyEmail.
Go live   : Logic App > Parameters > dryRun = false (or redeploy with -dryRun false).

Recommended: restrict Mail.Send to the sender mailbox. See README.md, section 'Restrict mail access'.
"@


