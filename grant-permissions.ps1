<#
.SYNOPSIS
  Grants the Graph application roles the Logic App's managed identity needs.
  Use after the Deploy to Azure button (deploy.ps1 already does this).
  Needs a Global Administrator or Privileged Role Administrator sign-in.

.EXAMPLE
  .\grant-permissions.ps1 -ResourceGroup rg-active-users -LogicAppName la-active-users-sync
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$LogicAppName,
    [string]$SubscriptionId
)

$ErrorActionPreference = "Stop"
$graph = "https://graph.microsoft.com/v1.0"
$roles = "AuditLog.Read.All", "Directory.Read.All", "GroupMember.ReadWrite.All", "Mail.Send"

if ($SubscriptionId) { az account set --subscription $SubscriptionId }
$principalId = az resource show -g $ResourceGroup -n $LogicAppName --resource-type Microsoft.Logic/workflows --query identity.principalId -o tsv
if (-not $principalId) { throw "Logic App '$LogicAppName' not found or has no managed identity." }

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

$graphSp = (Invoke-Graph GET "$graph/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'").value[0]
$granted = (Invoke-Graph GET "$graph/servicePrincipals/$principalId/appRoleAssignments").value
foreach ($name in $roles) {
    $role = $graphSp.appRoles | Where-Object { $_.value -eq $name -and $_.allowedMemberTypes -contains "Application" }
    if ($granted | Where-Object { $_.appRoleId -eq $role.id }) { Write-Host "already granted: $name"; continue }
    Invoke-Graph POST "$graph/servicePrincipals/$principalId/appRoleAssignments" @{
        principalId = $principalId; resourceId = $graphSp.id; appRoleId = $role.id } | Out-Null
    Write-Host "granted: $name"
}
Write-Host "Done. Roles can take a few minutes to apply; then enable the Logic App."
