# Bicdop Cluster and Blueprint

Bicdop 0.8.14 development includes a Windows Cluster Controller and an Agent
invoked on demand by OpenSSH. Shared inventory, Blueprint files, and audit
records are stored under the current account's Bicdop data directory. Existing
workspace and session files keep their previous format.

## Set up with Bicdop

On the Controller, use Full Installation and run `bicdop cluster key`. It
creates a dedicated Ed25519 key under the current user's Bicdop data directory
and prints the IPv4 addresses, public key path, and identity file path. The
generated private key has no passphrase and is restricted to the current
Windows account. Copy only the `.pub` file to the Agent.

On the Agent, run `bicdop agent setup` and enter the Controller IP and public
key path. Windows requests administrator approval. Setup configures the
OpenSSH Server feature, dedicated `bicdopagent` account, restricted subsystem,
and Private/Domain firewall rule limited to the Controller IP. It uses
`%ProgramData%\BicdopClusterAgent\Workspace` as the Agent root.

On the Controller, copy the Agent public host key shown by
`bicdop agent setup --info`. Then register it using the Agent address and the
private identity path shown earlier by `cluster key`.

```powershell
bicdop cluster add pc-01 192.168.1.20 bicdopagent "C:\Keys\agent-host.pub" 22 "C:\path\to\controller_ed25519"
bicdop cluster approve pc-01
bicdop cluster health pc-01
```

Compare the fingerprint on both computers before approval. Managed setup
requires an unused OpenSSH configuration and will stop rather than replace an
existing one. If setup stops after provisioning begins, review the message and
any protected staging files before retrying.

`agent revoke` disables the managed account, service, and firewall rule after
another administrator confirmation. Revoke managed access before uninstalling
Bicdop if the Agent should stop accepting connections. Managed setup keeps the
Administrator-owned Agent snapshot under ProgramData. Per-account Agent module
updates do not modify this snapshot.

## Manual setup on two Windows computers

1. On the controller, choose **Full installation** in Setup. On the Agent,
   choose **Cluster Agent only** or **Full installation**. Before enrolling a
   device, use a dedicated, non-administrator Windows account on the Agent,
   with a separate development folder accessible to that account.
2. With the Agent account, import the installed module and enable it. Replace
   the default paths below if Setup used a different location.

   ```powershell
   Import-Module "$env:LOCALAPPDATA\Programs\Bicdop\bundled\Bicdop.psd1"
   bicdop agent enable "C:\Development\Cluster"
   bicdop agent status
   ```

3. Enable Windows OpenSSH Server using your normal administrative process.
   Limit TCP 22 to the trusted LAN or the controller's IP in the Windows
   firewall. Install the controller's SSH public key in the dedicated
   account's authorized keys. Keep the private key on the controller, using a
   passphrase and the Windows SSH agent as appropriate. The Controller uses
   the SSH agent and default OpenSSH identity paths. For a dedicated key,
   use `cluster add NAME HOST USER HOST-KEY.pub PORT IDENTITY-FILE`. Bicdop
   stores the file path only. Keep the key protected with Windows file ACLs.

   Register the `bicdop` subsystem and restrict the dedicated account to the
   same entry point. Substitute the actual installed script path and account
   name. Add the subsystem in the global section. Add the matching account
   block at the end, after any other global options.

   ```text
   Subsystem bicdop powershell.exe -NoLogo -NoProfile -NonInteractive -File "C:/Users/bicdopagent/AppData/Local/Programs/Bicdop/Start-Bicdop.ps1" -Agent

   Match User bicdopagent
       AuthenticationMethods publickey
       PasswordAuthentication no
       PermitTTY no
       DisableForwarding yes
       ForceCommand powershell.exe -NoLogo -NoProfile -NonInteractive -File "C:/Users/bicdopagent/AppData/Local/Programs/Bicdop/Start-Bicdop.ps1" -Agent
   ```

   Validate the config with `sshd -t` and restart OpenSSH Server using the
   normal Windows service tools. Confirm the dedicated account does not grant
   an ordinary shell. Manual setup changes the SSH configuration independently of Bicdop.
   See the [Windows OpenSSH server configuration](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration).

4. Copy the Agent's **public host key** (normally
   `C:\ProgramData\ssh\ssh_host_ed25519_key.pub`) to the controller through a
   trusted channel. Check its fingerprint on the Agent with
   `ssh-keygen -lf C:\ProgramData\ssh\ssh_host_ed25519_key.pub`. Add and approve
   it on the controller only when that fingerprint matches the preview.

   ```powershell
   bicdop cluster add pc-01 192.168.1.20 bicdopagent "C:\Keys\pc-01.pub"
   bicdop cluster approve pc-01
   bicdop cluster health pc-01
   bicdop remote exec pc-01 -- "git --version"
   ```

   If Git or Python is missing from the Agent account's PATH, the corresponding
   diagnostic reports an error. Agent-only setup omits bundled Git and GitHub
   CLI. The Agent's read-only diagnostics run from its configured root.

## Manage devices and changes

`cluster list` shows persisted inventory. `cluster inspect DEVICE` shows device
identity, endpoint, capabilities and last contact. `cluster health [TARGET]`
queries live health. `cluster group DEVICE GROUP` assigns a group, and
`cluster assign DEVICE BLUEPRINT` assigns a saved Blueprint for `cluster check
[TARGET]`. `cluster audit` displays recent operation records.

Targets can be a device name, `group:NAME`, or `all`. Bulk operations select
approved devices in name order and run one device at a time. Rejected and
unreachable devices are reported individually. Stage a rollout by selecting
one device or one group before using `--cluster all`.

`cluster revoke DEVICE` stops new requests from that controller. Remove the
controller's key on the Agent to revoke SSH access. `agent revoke` disables
Agent requests and rotates its Bicdop identity. When rotating the SSH host
key, revoke and remove the old controller entry, then add and approve the
new fingerprint. An active SSH command may finish despite revocation.

## Blueprint files

`blueprint create developer` writes a template named
`developer.blueprint.yaml`. Edit it as JSON, the supported YAML 1.2 subset for
this version. Use `blueprint list` to see its path. The schema is:

```json
{
  "apiVersion": "bicdop.io/v1",
  "kind": "Blueprint",
  "metadata": { "name": "developer", "description": "Developer defaults" },
  "spec": {
    "resources": [
      { "id": "folder", "type": "directory", "path": "src" },
      { "id": "readme", "type": "file", "path": "src/readme.txt", "value": "Hello", "dependsOn": ["folder"] },
      { "id": "mode", "type": "environment", "name": "BICDOP_MODE", "value": "development" }
    ]
  }
}
```

Directories and text files use relative paths inside the Agent root or, for
local execution, the current directory. Links, junctions, hidden path
components and traversal are rejected. Environment resources set only
nonempty `BICDOP_*` variables for the current user. Package, service, tool,
and workspace resources inspect an exact installed display name, running
service, executable on PATH, or registered workspace name. When missing,
those resources report **Unsupported** and block dependents. They do not
install packages, manage services, or register workspaces.

```powershell
bicdop blueprint validate developer
bicdop blueprint plan developer
bicdop blueprint apply developer --cluster group:pilot
bicdop blueprint drift developer --cluster all
bicdop blueprint history developer
```

Plan and drift do not change resources. Apply is explicitly confirmed and
reconciles supported resources, with verification after writes. Rollback is
not implemented. An apply can partially succeed before a later resource
fails. Review the result and plan again before retrying. The audit records
request IDs and outcomes without storing file contents or command arguments.

## Update and recovery

`version` displays the loaded version offline. `update --check` reports the
latest published build and its release channel. Normal updates apply stable
releases only, with the existing verified installer extraction flow.

`agent update` checks for a stable module locally. Remote module updates
require opt-in on the Agent with `agent enable ROOT --allow-updates`.
`cluster update DEVICE` and `cluster update --cluster group:pilot` apply updates
sequentially after confirmation. The next Agent invocation imports the newest
verified module. To recover locally, turn off Agent access and restore an
earlier trusted installation and its managed module directory.

## Security and verification limits

- Keep the Agent non-elevated, restrict its SSH account and firewall, and
  verify host fingerprints independently. Bicdop pins the Ed25519 host key and
  does not accept unknown hosts. Protect the Controller account, SSH keys,
  Agent working directory, and local audit files from other users.
- Remote exec accepts only `git status`, `git --version`, and
  `python --version`. There is no interactive shell or arbitrary remote script
  execution through the Bicdop subsystem.
- SSH protects each transport session. Recent apply and update request IDs
  are recorded so replays are rejected. Requests have a Controller timeout of
  30 seconds, or 180 seconds for update. Interrupting the Controller stops its
  current SSH client. An Agent write already started can finish, so verify
  state after an interruption.
- This development build uses sequential rollout and manual reconciliation.
  It has no durable job queue, automatic retry, automatic rollback, or
  background reconciliation scheduler. A fully provisioned two-PC Windows
  setup is required to validate enrollment and firewall/service configuration
  on the target LAN.
