# Bicdop Automation

Automation is available in the 0.8.14 development build. Its Node store is
separate from the workspace registry. The Controller uses the existing
pinned OpenSSH transport and Cluster enrollment.

## Run the simulated email archiver

Use an ordinary, non-elevated PowerShell session from the Bicdop checkout.

```powershell
Import-Module ./Bicdop/Bicdop.psd1
bicdop automation register email-archiver --path ./examples/automation/email-archiver
bicdop automation schedule email-archiver --daily 08:00 --timezone Asia/Jakarta
bicdop automation enable email-archiver
bicdop automation run email-archiver
bicdop automation tick
bicdop automation logs email-archiver --json
```

The example simulates quotas and processes oldest-first message sizes until
each eligible batch reaches approximately 1 GiB. It has no email network
access, mailbox state, credentials, or deletion code.

## Schedule execution

Run `bicdop automation watch` in a dedicated, non-elevated Node session for
continuous scheduling. Alternatively, invoke `bicdop automation tick`
periodically from Windows Task Scheduler configured for the same Windows user.
The installer does not create a scheduler task or service. For Task Scheduler,
use a locally controlled script that imports Bicdop and executes `automation
tick`; verify the chosen trigger, identity and Python availability independently.
The worker needs no active Controller connection.

`schedule NAME --daily HH:mm --timezone ZONE` runs every day. Add
`--weekday Monday` for a weekly run. Use a Windows time-zone ID or
`Asia/Jakarta`. A due slot is eligible during its local minute. Missed slots
are skipped, including gaps at DST transitions, and repeating clock minutes
are deduplicated. Jobs run sequentially per worker and overlap for the same
job is blocked by a file lock. Long jobs can cause other slots to be missed.

`run NAME` queues a manual run. `stop NAME` clears its pending request and
signals an active worker to stop the running process tree. `disable NAME`
stops future dispatch and clears pending work. A previous run that was
interrupted before the outcome could be saved is marked Unknown on the next
worker tick. This system cannot guarantee exactly-once effects in an external app.

`retry NAME --run-id ID` explicitly queues a new run for a failed, timed-out,
or cancelled attempt. Use `inspect`, `status`, `logs`, `history`, or
`failures` with a job name, and `list` for all registered jobs. These accept
`--json`. Recent runs are retained, including timestamp, status, exit code,
and capped output samples. The Node is the source of truth for history.
The Controller reads it directly when the Node is reachable.

## Register an installed job

Each installation has a `bicdop-job.json` file as shown in
`examples/automation/email-archiver`. Schema 1 requires `schema`, `id`,
`version`, `runtime`, and `entry`. Optional keys are `description`,
`arguments` (array of strings), and `timeoutSeconds` (1 to 86400).
Supported runtimes are `python`, `powershell`, and `executable`.
The file extension must match. Paths stay inside the registered directory
and cannot traverse links. The entry's SHA-256 is pinned during registration.
Install and verify trusted code and dependencies locally before registration,
and protect the whole installation directory with your Windows permissions.
Run without administrative privileges.

A job can print a line beginning `BICDOP_RESULT ` followed by valid JSON
with `schema: 1` and a `metrics` object of finite numeric measurements.
The worker validates that object independently of the process exit code.
Avoid emitting credentials. Basic password/token label masking is best effort
and cannot sanitize arbitrary output. Put real application credentials in a
store the application is authorized to access, outside this manifest and log.

## Manage an approved Node

Follow [Cluster and Blueprint](README.Cluster.md) for enrollment.
Use the manual per-account Agent configuration and start the worker under
the same standard Windows account and Bicdop data root used by the SSH Agent.
The protected Agent provisioned by `agent setup` currently has no integrated
Automation worker/account provisioning.

Install the sample app on the Node. Then, on the Node, run
`automation register email-archiver --path DIRECTORY --remote`. Explicit
`--remote` approval requires the job's installed directory to be separate from
the Agent's Blueprint workspace. The Controller can send a small ZIP after local approval of its exact digest.
Start `automation watch` on the Node.

From the Controller:

```powershell
bicdop automation list --node pc-01
bicdop automation enable email-archiver --node pc-01
bicdop automation schedule email-archiver --node pc-01 --daily 08:00 --timezone Asia/Jakarta
bicdop automation run email-archiver --node pc-01
bicdop automation logs email-archiver --node pc-01 --json
```

Use `--cluster all` for all approved Nodes, or `--cluster GROUP` for a named
group. Results show each Node separately. A waiting run survives disconnects
because it is recorded on the Node before acknowledgement. A user allowed to
manage a remote-approved job may see its outputs and change its schedule or
trigger it, so share keys only with trusted operators.

## Deploy a reviewed ZIP

Create a ZIP on the Controller with `bicdop-job.json` and the entry files
at its root. Obtain its SHA-256 with `Get-FileHash` in PowerShell and verify
the package out of band. On the Node, approve only the reviewed SHA-256
with `bicdop automation approve-artifact SHA256`. Then run on the Controller:

```powershell
bicdop automation deploy ./email-archiver.zip --node pc-01
```

This process caps the archive at 36 KB, limits extraction to 64 entries and
1 MiB expanded, rejects unsafe paths and links, and verifies the digest again.
It stages a new versioned path keyed by digest and registers it
disabled. Existing job registrations or artifacts are not overwritten.
Dependencies still need to be installed separately. Use `automation deploy
PACKAGE.zip` locally to stage and register after local confirmation.

## Blueprint schedule policy

The existing v1 Blueprint resource list accepts an `automation` resource:

```json
{
  "id": "email-job",
  "type": "automation",
  "name": "email-archiver",
  "value": { "enabled": true, "time": "08:00", "timezone": "Asia/Jakarta" }
}
```

Optionally add `day` (English weekday) in `value` or `dependsOn` at resource
level. The job must already be registered on the Node. Plan and drift inspect
the schedule and enabled state, and reapply reconciles only differences.
Manual changes are reported as drift. Apply does not queue a manual run. Once
enabled, the next eligible schedule can be picked up by the worker. Use
`blueprint plan NAME --node NODE` or `--cluster GROUP` for remote planning.

## Known limits

This build supports local registration and approved ZIP deployment. It does
not implement dependency installation, artifact upgrades or rollback,
automatic service provisioning, cron expressions, catch-up runs, automatic
backoff, per-operation SSH roles, or cached offline Controller views.
The live scheduler and process cleanup require end-to-end testing on the
actual Windows deployment account before relying on them in production.
