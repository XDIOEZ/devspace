import { appendFileSync, existsSync, mkdirSync, readdirSync, renameSync, rmSync, statSync } from "node:fs";
import { createHash } from "node:crypto";
import { createConnection, createServer } from "node:net";
import { execFile, spawn } from "node:child_process";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import Database from "better-sqlite3";
import { loadConfig } from "../dist/config.js";

const execFileAsync = promisify(execFile);
const args = new Map(process.argv.slice(2).map((arg) => {
  const separator = arg.indexOf("=");
  return [arg.slice(0, separator), arg.slice(separator + 1)];
}));
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const expectedStateDir = requiredPath("--state-dir");
const configDir = requiredPath("--config-dir");
const tunnelMode = args.get("--tunnel-mode") ?? "ngrok";
if (!["ngrok", "external"].includes(tunnelMode)) {
  throw new Error(`Unsupported tunnel mode: ${tunnelMode}`);
}
const ngrokExecutable = tunnelMode === "ngrok" ? requiredPath("--ngrok") : undefined;
const ngrokConfig = tunnelMode === "ngrok" ? requiredPath("--ngrok-config") : undefined;
const guardianDir = join(expectedStateDir, "service-guardian");
const backupDir = join(guardianDir, "backups");
const states = new Map();
const launches = new Map();
let backedUpDate;
let backupRetryAfter = 0;
let authCheckAfter = 0;

// Require explicit installation paths instead of silently using another working directory.
function requiredPath(name) {
  const value = args.get(name);
  if (!value) throw new Error(`Missing installation argument: ${name}`);
  return resolve(value);
}

// Keep local diagnostic logs bounded; never write OAuth request bodies or credentials.
function appendLog(name, content) {
  const path = join(guardianDir, name);
  if (existsSync(path) && statSync(path).size > 2 * 1024 * 1024) {
    rmSync(`${path}.previous`, { force: true });
    renameSync(path, `${path}.previous`);
  }
  appendFileSync(path, content, { mode: 0o600 });
}

// Record state transitions, not the same healthy result every polling interval.
function report(service, state, details = {}) {
  if (states.get(service) === state) return;
  states.set(service, state);
  appendLog("guardian.jsonl", `${JSON.stringify({ time: new Date().toISOString(), service, state, ...details })}\n`);
}

// Read local health endpoints with a deadline; a timeout alone never triggers process termination.
async function getJson(url) {
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(3000) });
    return response.ok ? await response.json() : undefined;
  } catch {
    return undefined;
  }
}

// Avoid starting a second server when an existing listener is merely busy.
function portIsOpen(host, port) {
  return new Promise((resolveResult) => {
    const socket = createConnection({ host, port });
    const finish = (open) => { socket.destroy(); resolveResult(open); };
    socket.once("connect", () => finish(true));
    socket.once("error", (error) => finish(error.code !== "ECONNREFUSED"));
    socket.setTimeout(1500, () => finish(true));
  });
}

// Never duplicate or kill an existing ngrok agent, including one reconnecting after a network outage.
async function tunnelProcessExists() {
  if (!ngrokExecutable) return false;
  const { stdout } = await execFileAsync("tasklist.exe", ["/FI", `IMAGENAME eq ${basename(ngrokExecutable)}`, "/FO", "CSV", "/NH"],
    { windowsHide: true, timeout: 10000 });
  return stdout.toLowerCase().includes(`"${basename(ngrokExecutable).toLowerCase()}"`);
}

// Retry exited services with bounded backoff, preserving the user's authentication and tunnel settings.
function launch(service, executable, commandArgs) {
  const previous = launches.get(service) ?? { failures: 0, retryAfter: 0 };
  if (previous.child || Date.now() < previous.retryAfter) return;
  const failures = previous.failures + 1;
  const state = { failures, retryAfter: Date.now() + Math.min(5000 * 2 ** Math.min(failures - 1, 6), 300000) };
  launches.set(service, state);
  const child = spawn(executable, commandArgs, {
    cwd: root,
    env: service === "devspace" ? { ...process.env, DEVSPACE_CONFIG_DIR: configDir }
      : Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("DEVSPACE_"))),
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  state.child = child;
  child.stdout.on("data", (data) => appendLog(`${service}.log`, data));
  child.stderr.on("data", (data) => appendLog(`${service}.log`, data));
  child.once("error", (error) => {
    state.child = undefined;
    report(service, "start_failed", { code: error.code });
  });
  child.once("exit", (code) => {
    state.child = undefined;
    report(service, "exited", { code });
  });
  report(service, "starting", { pid: child.pid });
}

// Reject missing or empty identity databases rather than creating a fresh, incompatible OAuth identity.
function openExistingState() {
  const db = new Database(join(expectedStateDir, "devspace.sqlite"), { readonly: true, fileMustExist: true });
  try {
    if (db.prepare("select count(*) as count from oauth_clients").get().count === 0) {
      throw new Error("OAuth client registrations are missing; restore state or reauthorize explicitly.");
    }
    return db;
  } catch (error) {
    db.close();
    throw error;
  }
}

// Use SQLite's online backup API, including WAL data, and retain seven completed daily snapshots.
async function backupState() {
  const date = new Date().toISOString().slice(0, 10);
  if (backedUpDate === date || Date.now() < backupRetryAfter) return;
  const path = join(backupDir, `devspace-${date}.sqlite`);
  const db = openExistingState();
  try {
    if (!existsSync(path)) {
      await db.backup(`${path}.partial`);
      renameSync(`${path}.partial`, path);
    }
    const snapshots = readdirSync(backupDir).filter((name) => /^devspace-\d{4}-\d{2}-\d{2}\.sqlite$/.test(name)).sort();
    for (const name of snapshots.slice(0, -7)) rmSync(join(backupDir, name));
    backedUpDate = date;
    report("state_backup", date);
  } finally {
    db.close();
  }
}

// Observe each OAuth client's latest result without letting inspector failures interrupt service recovery.
async function observeAuthFailures() {
  if (Date.now() < authCheckAfter) return;
  authCheckAfter = Date.now() + 60000;
  try {
    const capture = await getJson("http://127.0.0.1:4040/api/requests/http?limit=100");
    if (!Array.isArray(capture?.requests)) return;
    const latestByClient = new Map();
    const cutoff = Date.now() - 10 * 60 * 1000;
    for (const request of capture.requests) {
      try {
        // The outer uri addresses the inspector record, not the captured HTTP request.
        const path = new URL(request.request?.uri ?? "/", "http://127.0.0.1").pathname;
        const time = Date.parse(request.start);
        const status = request.response?.status_code;
        if (path !== "/token" || !Number.isFinite(time) || time < cutoff
          || (status !== 200 && !(status >= 400))) continue;
        const raw = Buffer.from(request.request.raw, "base64").toString();
        const body = new URLSearchParams(raw.split("\r\n\r\n").slice(1).join("\r\n\r\n"));
        const clientId = body.get("client_id");
        if (!clientId) continue;
        const fingerprint = createHash("sha256").update(clientId).digest("hex").slice(0, 8).toUpperCase();
        let state = "healthy";
        if (status !== 200) {
          const response = Buffer.from(request.response.raw, "base64").toString()
            .split("\r\n\r\n").slice(1).join("\r\n\r\n");
          state = JSON.parse(response).error;
          if (!["invalid_client", "invalid_grant"].includes(state)) continue;
        }
        if (!latestByClient.has(fingerprint) || latestByClient.get(fingerprint).time < time) {
          latestByClient.set(fingerprint, { state, time });
        }
      } catch {
        // Ignore an incomplete capture without discarding the other clients' observations.
      }
    }
    for (const [fingerprint, { state, time }] of latestByClient) {
      report(`oauth_client:${fingerprint}`, state, {
        requestTime: new Date(time).toISOString(),
        ...(state === "healthy" ? {} : {
          action: "check_original_registration_or_reauthorize; do_not_restart_services",
        }),
      });
    }
  } catch {
    // Optional diagnostics must not terminate the guardian or copy credentials into error logs.
  }
}

// Recheck the pinned identity before each recovery, including configuration edits made while running.
function loadPinnedConfig() {
  if (!existsSync(join(configDir, "config.jsonc"))) throw new Error("The original DevSpace configuration is missing.");
  const config = loadConfig();
  if (resolve(config.stateDir).toLowerCase() !== expectedStateDir.toLowerCase()) {
    throw new Error("The configured state directory changed. Refusing to start with another OAuth database.");
  }
  if (config.host !== "127.0.0.1") throw new Error("The installed guardian requires the existing loopback listener.");
  return config;
}

// Recover only stopped processes; preserve busy listeners, live tunnels, and all active MCP work.
async function supervise() {
  const config = loadPinnedConfig();
  const health = await getJson(`http://127.0.0.1:${config.port}/healthz`);
  if (health?.ok && health.name === "devspace") {
    const state = launches.get("devspace");
    if (state) { state.failures = 0; state.retryAfter = 0; }
    report("devspace", "healthy");
  } else if (await portIsOpen("127.0.0.1", config.port)) {
    report("devspace", "listener_present_no_restart");
  } else {
    const db = openExistingState();
    db.close();
    launch("devspace", process.execPath, [`--env-file=${join(root, ".env")}`, join(root, "dist", "cli.js"), "serve"]);
  }

  if (tunnelMode === "external") {
    report("tunnel", "externally_managed");
  } else {
    const tunnels = await getJson("http://127.0.0.1:4040/api/tunnels");
    if (tunnels?.tunnels?.some((tunnel) => tunnel.public_url === config.publicBaseUrl)) {
      const state = launches.get("ngrok");
      if (state) { state.failures = 0; state.retryAfter = 0; }
      report("ngrok", "endpoint_present");
    } else if (tunnels || await tunnelProcessExists()) {
      report("ngrok", "agent_present_no_restart");
    } else {
      launch("ngrok", ngrokExecutable, ["http", `--url=${new URL(config.publicBaseUrl).hostname}`, String(config.port),
        `--config=${ngrokConfig}`, "--log=stdout", "--log-format=json", "--log-level=info"]);
    }
  }
}

// Pin the original configuration and acquire an OS-managed single-instance lock before supervising.
async function main() {
  if (process.platform !== "win32") throw new Error("This local guardian is Windows-only.");
  process.env.DEVSPACE_CONFIG_DIR = configDir;
  loadPinnedConfig();
  const requiredFiles = [join(root, ".env"), join(root, "dist", "cli.js")];
  if (tunnelMode === "ngrok") requiredFiles.push(ngrokExecutable, ngrokConfig);
  for (const path of requiredFiles) {
    if (!existsSync(path)) throw new Error(`Required installation file is missing: ${path}`);
  }
  const db = openExistingState();
  db.close();
  mkdirSync(backupDir, { recursive: true, mode: 0o700 });
  const lockName = createHash("sha256").update(expectedStateDir.toLowerCase()).digest("hex").slice(0, 16);
  const lock = createServer((socket) => socket.destroy());
  lock.on("error", (error) => {
    if (error.code === "EADDRINUSE") process.exit(0);
    throw error;
  });
  await new Promise((resolveListen) => lock.listen(`\\\\.\\pipe\\devspace-guardian-${lockName}`, resolveListen));
  report("guardian", "started", { pid: process.pid });
  while (true) {
    try {
      await supervise();
      report("supervision", "ok");
    } catch (error) {
      report("supervision", "failed", { message: error.message });
    }
    try {
      await backupState();
    } catch (error) {
      backupRetryAfter = Date.now() + 5 * 60 * 1000;
      report("state_backup", "failed", { message: error.message });
    }
    await observeAuthFailures();
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 15000));
  }
}

main().catch((error) => {
  if (existsSync(guardianDir)) report("guardian", "startup_failed", { message: error.message });
  console.error(error.message);
  process.exit(1);
});
