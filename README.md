# Active Users Group Sync (Logic App)

A nightly Azure Logic App that keeps a **cloud-only security group** (for example `Active-Users-60d`) in sync with the members of a **source group** who signed in during the last N days (default 60).

- Adds source-group members who are active and not yet in the target group.
- Removes target-group members who are no longer active.
- Accounts **created** in the last N days count as active (grace period for new hires).
- Safety cap: if removals exceed `maxRemovalPercent` (default 10%) of the target group, **nobody** is removed and the report says so.
- Dry run (default): reports only. Every run emails an admin summary with a CSV (`Action, UserPrincipalName, DisplayName, LastSignIn`).
- Any failure sends a failure email. Scales to 10k+ users (id-only paging and Graph `$batch`).

## Prerequisites

| Need | Why |
|---|---|
| Entra ID P1 or P2 licence | Graph `signInActivity` is only returned with P1/P2 |
| Azure subscription, Contributor on a resource group | Deploys the Logic App (Consumption, about cents per month) |
| Global Administrator or Privileged Role Administrator (once) | Grants Graph roles to the Logic App's managed identity, creates the target group |
| A sender mailbox (a shared mailbox is recommended) | Sends the report |
| Azure CLI | Used by `deploy.ps1` |

## Deploy (recommended): one command

```powershell
.\deploy.ps1 -SubscriptionId <sub-id> -ResourceGroup rg-active-users `
    -SourceGroupId <source group object id> `
    -SenderMailbox reports@contoso.com -NotifyEmail it-admins@contoso.com
```

The script checks prerequisites, creates the target group (`Active-Users-60d`, or pass `-ActiveGroupId` / `-ActiveGroupName`), deploys the template **Disabled** with `dryRun = true`, grants the Graph roles, waits about 3 minutes for them to propagate, enables the Logic App and checks the first run.

Useful options: `-InactivityDays 90`, `-MaxRemovalPercent 5`, `-ScheduleHour 3`, `-ScheduleTimeZone "W. Europe Standard Time"`, `-Location northeurope`, `-TenantId <id>`, `-UseDeviceCode`.

## Deploy (alternative): Deploy to Azure button

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fitziktdk%2Fentra-active-users-60d-sync%2Fmain%2Fazuredeploy.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fitziktdk%2Fentra-active-users-60d-sync%2Fmain%2FcreateUiDefinition.json)

The portal form creates the Logic App Disabled. Then run the permission step below (`grant-permissions.ps1`) and enable it.

### Grant permissions (portal route only)

```powershell
.\grant-permissions.ps1 -ResourceGroup <rg> -LogicAppName <name>
```

Roles can take up to a few minutes to apply. Then enable the Logic App.

## Go live

1. Leave `dryRun = true` for about a week. Review the CSV in each morning's email: the adds and removals should match what you expect.
2. Check the removal cap suits the group size (a cap of 10% of 1,000 users = 100 removals per night).
3. Logic App > **Parameters** (designer) > set `dryRun` to `false` and save. Or redeploy with `dryRun=false`.

Changing a setting later: Logic App > Logic app designer > **Parameters**. Redeploying the template overwrites them with the values you pass.

## Flow diagrams

[English](docs/nightly-active-users-60d-en.png) | [Hebrew / עברית](docs/nightly-active-users-60d-he.png) (editable `.excalidraw` files are in the same folder)

## What the flow does (6 steps)

1. Read all members of the source group (ids only).
2. Read users who signed in within N days (ids only, 999 per page); keep only source-group members. Then add users created within N days (grace period).
3. Read the current target-group members.
4. Work out changes: adds = active and not in target; removals = in target and not active. Look up UPN / name / last sign-in for the changed users only (Graph `$batch`, 20 per call) and build the CSV.
5. If `dryRun` is false: add users, then remove users only when under the cap. Both use `$batch`, 20 per call; failed items are counted and retried next night.
6. Email the summary and CSV. If anything failed, a failure email is sent instead.

## Restrict mail access (recommended)

`Mail.Send` as an application role allows sending as **any** mailbox. Limit it to the sender mailbox with Exchange Online RBAC for Applications:

```powershell
Connect-ExchangeOnline
$sp = <the Logic App managed identity object id>
New-ServicePrincipal -AppId <managed identity application (client) id> -ObjectId $sp -DisplayName "la-active-users-sync"
New-ManagementScope -Name "ActiveUsersSender" -RecipientRestrictionFilter "PrimarySmtpAddress -eq 'reports@contoso.com'"
New-ManagementRoleAssignment -App $sp -Role "Application Mail.Send" -CustomResourceScope "ActiveUsersSender"
```

Then remove the broad `Mail.Send` Graph role from the managed identity. See Microsoft Learn: "Role Based Access Control for Applications in Exchange Online".

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Run failed, `Forbidden` on a Graph call | Role grants not applied yet (wait 5 minutes) or missing roles. Re-run `deploy.ps1`, it is idempotent |
| `ErrorInvalidUser` on the email step | `senderMailbox` is not a valid mailbox UPN |
| Email says REMOVAL CAP EXCEEDED | More removals than `maxRemovalPercent`. Review the CSV, then raise the cap or fix the source data. Nothing was removed |
| Everyone shows as `WouldRemove` with empty `LastSignIn` | No Entra ID P1/P2, or sign-in data not populated yet. Check licensing |
| HTTP 429 in a step | Graph throttling; the step retries automatically |
| CSV shows only an object id | The member is not a user object (device, deleted) or the lookup failed |
| Failed changes > 0 in the email | Some adds or removals failed; they are retried the next night |

## Uninstall

Delete the Logic App (or the resource group). Optionally delete the target group and the managed-identity role assignments (they disappear with the Logic App).

## Files

| File | Purpose |
|---|---|
| `azuredeploy.json` | ARM template (Logic App with all parameters) |
| `createUiDefinition.json` | Portal form for the Deploy to Azure button |
| `deploy.ps1` | One-command deployment, groups, permissions, enable and test |
| `grant-permissions.ps1` | Graph role grants only (for the portal button route) |
| `README.md` | This guide |
