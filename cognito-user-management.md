# Cognito User Management — LabLumen

> Run all commands from a terminal authenticated as `lablumen-admin` with the correct AWS profile.
> The User Pool ID is fetched dynamically from SSM — no hardcoding needed.

---

## Prerequisites

Set the Pool ID in your shell session first. All commands below depend on `$POOL_ID`.

```powershell
$POOL_ID = (aws ssm get-parameter --name "/lablumen/config/cognito-user-pool-id" --query "Parameter.Value" --output text)
echo "Pool ID: $POOL_ID"
```

---

## Create a Staff User

Roles available: `LAB_STAFF`, `LAB_ADMIN`

> **Example:** `staff@lablumen.com` / `Staff@123` in group `LAB_STAFF`

### Step 1 — Create the user (email verified, no welcome email)

```powershell
aws cognito-idp admin-create-user `
  --user-pool-id $POOL_ID `
  --username "staff@lablumen.com" `
  --user-attributes Name=email,Value=staff@lablumen.com Name=email_verified,Value=true `
  --temporary-password "Staff@123" `
  --message-action SUPPRESS
```

### Step 2 — Set a permanent password (skips force-reset on first login)

```powershell
aws cognito-idp admin-set-user-password `
  --user-pool-id $POOL_ID `
  --username "staff@lablumen.com" `
  --password "Staff@123" `
  --permanent
```

### Step 3 — Create the groups (skip if they already exist)

```powershell
# LAB_STAFF — operational staff
aws cognito-idp create-group `
  --user-pool-id $POOL_ID `
  --group-name "LAB_STAFF" `
  --description "Lab staff members with operational access"

# LAB_ADMIN — admins (also grants staff panel access)
aws cognito-idp create-group `
  --user-pool-id $POOL_ID `
  --group-name "LAB_ADMIN" `
  --description "Lab administrators"
```

### Step 4 — Add the user to the group

```powershell
aws cognito-idp admin-add-user-to-group `
  --user-pool-id $POOL_ID `
  --username "staff@lablumen.com" `
  --group-name "LAB_STAFF"
```

### Step 5 — Verify

```powershell
aws cognito-idp admin-get-user `
  --user-pool-id $POOL_ID `
  --username "staff@lablumen.com"
```

---

## Create a Patient User

Patient users have **no group**. They land on `/app` after login.

```powershell
aws cognito-idp admin-create-user `
  --user-pool-id $POOL_ID `
  --username "patient@lablumen.com" `
  --user-attributes Name=email,Value=patient@lablumen.com Name=email_verified,Value=true `
  --temporary-password "Patient@123" `
  --message-action SUPPRESS

aws cognito-idp admin-set-user-password `
  --user-pool-id $POOL_ID `
  --username "patient@lablumen.com" `
  --password "Patient@123" `
  --permanent
```

---

## Other Useful Commands

### List all users in the pool

```powershell
aws cognito-idp list-users --user-pool-id $POOL_ID
```

### List members of a group

```powershell
aws cognito-idp list-users-in-group `
  --user-pool-id $POOL_ID `
  --group-name "LAB_STAFF"
```

### Remove a user from a group

```powershell
aws cognito-idp admin-remove-user-from-group `
  --user-pool-id $POOL_ID `
  --username "staff@lablumen.com" `
  --group-name "LAB_STAFF"
```

### Disable / Enable a user

```powershell
# Disable
aws cognito-idp admin-disable-user --user-pool-id $POOL_ID --username "staff@lablumen.com"

# Re-enable
aws cognito-idp admin-enable-user --user-pool-id $POOL_ID --username "staff@lablumen.com"
```

### Delete a user

```powershell
aws cognito-idp admin-delete-user `
  --user-pool-id $POOL_ID `
  --username "staff@lablumen.com"
```

### Reset a user password (force reset on next login)

```powershell
aws cognito-idp admin-reset-user-password `
  --user-pool-id $POOL_ID `
  --username "staff@lablumen.com"
```

---

## Panel Access Reference

| Cognito Group | Panel URL (dev) | Route |
|---|---|---|
| `LAB_STAFF` | `https://app-dev.rnld101.xyz/staff` | `/staff` |
| `LAB_ADMIN` | `https://app-dev.rnld101.xyz/staff` | `/staff` |
| *(no group)* | `https://app-dev.rnld101.xyz/app` | `/app` |

> **Note:** After changing a user's group in Cognito, the user **must log out and log back in**
> for the new `cognito:groups` claim to be reflected in their JWT token.
