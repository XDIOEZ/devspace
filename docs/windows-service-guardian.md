# Local Windows service guardian

This optional installation helper supervises an existing, already-authorized DevSpace checkout. Tunnel mode `ngrok` also supervises its user-owned ngrok agent; mode `external` leaves the tunnel to a separately managed client such as SakuraFrp. It is not part of the MCP server or OAuth provider. It does not change credentials, token lifetimes, registration records, or the tunnel domain.

## Installation arguments

Run `scripts/windows-service-guardian.mjs` using the same Node executable as DevSpace, with `--env-file` pointing at the checkout's existing `.env`. Pass these absolute paths as `--name=value` arguments:

- `--config-dir`: the existing directory containing `config.jsonc`.
- `--state-dir`: the current state directory, containing `devspace.sqlite` and existing OAuth registrations.
- `--tunnel-mode`: `ngrok` (default) or `external`.
- `--ngrok`: the current `ngrok.exe` executable, required only in `ngrok` mode.
- `--ngrok-config`: the current ngrok configuration file, required only in `ngrok` mode. Credentials stay in that file.

The installation is intended for a per-user Windows Task Scheduler task with a logon trigger, interactive/limited privileges, no execution time limit, and `IgnoreNew` for multiple instances. The task launches Node through the GUI-subsystem `wscript.exe` helper so the guardian and its recovery do not create or flash a console window on the desktop. A named recovery trigger runs every minute so an exited guardian does not remain offline; Task Scheduler ignores that trigger while the existing instance is running. This does not provide service availability after the Windows user signs out. Keep using the original Windows user. Do not run it as another account with a different configuration or authorization database.

`scripts/install-windows-service-guardian.ps1` registers and starts the `PCC-DevSpace-Guardian` task. Supply the existing paths through its `StateDir` and `ConfigDir` parameters, plus `TunnelMode external` for a separately managed tunnel or `NgrokExecutable` and `NgrokConfig` for ngrok. It restricts the snapshot/log directories to the current user and SYSTEM and refuses to overwrite a task with a different action. Reinstallation safely upgrades the previous direct-`node.exe` action to the hidden launcher when every other action argument still matches this guardian installation, and updates the named recovery trigger without duplicating it. The installer does not stop or restart existing services.

## Recovery policy

The guardian checks local service status every 15 seconds. It adopts healthy existing processes without replacing them. It starts DevSpace only if the local port has no listener, and starts ngrok only if no existing agent is detected. Process exits use bounded retry backoff. A busy listener, a reconnecting tunnel, or an OAuth error does not cause a restart. No process is killed.

An OS-managed named pipe prevents duplicate guardian instances. The state directory is pinned at installation, and missing/empty authorization databases stop recovery rather than silently provisioning a different identity. The guardian must be reinstalled deliberately after moving the state directory.

## Backups and diagnosis

The guardian saves a consistent SQLite online backup once per UTC day, including committed WAL state, retaining seven dated snapshots in `state/service-guardian/backups`. Keep this directory private to the Windows user and SYSTEM. Treat backups as sensitive: they contain client registrations and authorization state. Nothing is uploaded. Backup failures are recorded and retried separately from process recovery.

Bounded logs are stored under `state/service-guardian`. When ngrok's local inspector is available on port 4040, recent `invalid_client`/`invalid_grant` failures are recorded only as an error code and short client fingerprint. Raw requests, credentials, and tokens are never copied to guardian diagnostics.

The observer uses the captured HTTP request's URI, not the inspector record's own resource URI. Results are tracked separately as `oauth_client:<fingerprint>`; a successful token exchange clears that client's diagnostic failure state, not another client's state. These fingerprints do not identify connector display names, and an error for one client is not evidence that another connection has failed. Missing, malformed, or incomplete inspector data never stops process supervision. Observation does not retry, revoke, or replace any client's credentials.

Backups are not restored automatically. Restoring stale refresh-token state can conflict with token rotation; preserve the current database and perform recovery deliberately, or reauthorize the affected connection. Missing client registration cannot safely be repaired by accepting an arbitrary refresh request.

## Remove or validate

Disable/remove the guardian's own scheduled task and stop only its process. Existing DevSpace and ngrok processes are not deliberately terminated by the guardian.

To validate recovery manually, stop an idle service only after all active work is finished, then check that its original endpoint returns and its original authorization remains usable. Separately confirm that an invalid connection is reported as an OAuth failure without restarting the healthy service. Source syntax checks and observing healthy running processes do not establish that an end-to-end recovery test has passed.
