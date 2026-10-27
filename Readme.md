# cli-oci-setup

`oci_onboarding.sh` prepares an OCI tenancy for onboarding into Cisco Multicloud Defence.
It creates the IAM group, policy, user and API key that the MCD controller uses to
discover and manage resources, and prints the three values you paste into the
controller when adding the OCI account.

## Prerequisites

* [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) installed and
  configured (`oci setup config`) with a principal that can create IAM groups, policies and users
  in the tenancy root.
* `jq`
* `openssl`

## Usage

```bash
./oci_onboarding.sh [-p <prefix>]
```

| Flag | Description |
|---|---|
| `-p <prefix>` | Prefix for the group, policy and user names. Defaults to `ciscomcd`. |
| `-h` | Help. |

The script will prompt you to either enter compartment OCIDs directly or pick them from a
list, then ask where to write the generated API key pair.

## What it creates

| Resource | Name |
|---|---|
| Group | `<prefix>-controller-group` |
| Policy (attached at tenancy root) | `<prefix>-controller-policy` |
| User | `<prefix>-controller-user` |
| API key | uploaded to the user; key pair written to the directory you choose |

The policy grants **management** permissions (`manage instances`,
`manage virtual-network-family`, `manage load-balancers`, ...) only in the compartments you
select, and **read/discovery** permissions (`read virtual-network-family`,
`read instance-family`, `read load-balancers`, `inspect compartments`) at the tenancy level.
It also grants `read resource-availability in tenancy`, which the controller uses to read
OCI service limits (load balancers, cores, VCNs) before creating a gateway.

> **Accounts onboarded before this statement was added:** add
> `Allow group <prefix>-controller-group to read resource-availability in tenancy` to the
> existing `<prefix>-controller-policy`, in the console or with `oci iam policy update`. Without
> it, the controller cannot read the limits and leaves them out of its gateway checks.

> **Note on discovery scope:** because the read permissions are tenancy-wide, the controller
> discovers resources across every compartment in the tenancy, not just the ones selected here.
> In tenancies with many compartments this produces a large burst of OCI API calls per discovery
> request and can hit OCI's rate limits (HTTP 429 `TooManyRequests`).

## Output

At the end the script prints the values needed by the controller:

* Tenancy OCID
* User OCID
* Private key

## Re-running

The script is idempotent: an existing group, policy, user or group membership with the same
name is reused rather than recreated (the policy statements are updated in place). A new API
key is generated on every run — OCI allows a maximum of 3 API keys per user, so delete unused
ones if you re-run repeatedly.

## Uninstalling

Each run writes `delete-oci-cisco-mcd-setup.sh` to the current directory. It removes only the
resources that run actually created, so it will not delete a group, policy or user that already
existed and was reused.
