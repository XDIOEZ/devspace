import assert from "node:assert/strict";
import { mkdtemp, mkdir, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { loadConfig } from "./config.js";
import { WorkspaceContextCache } from "./workspace-context-cache.js";
import { writeTestDevspaceConfig } from "./test-support/config.test.js";

test("workspace context discovery is cached in memory and on disk until refreshed", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "devspace-context-cache-test-"));
  t.after(async () => rm(dir, { recursive: true, force: true }));
  const root = join(dir, "project");
  await mkdir(root);
  await writeFile(join(root, "AGENTS.md"), "Initial project rules.");
  const loaded = loadConfig(writeTestDevspaceConfig(join(dir, "config"), {
    server: { port: 1 },
    workspaces: { allowedRoots: [dir], worktreeRoot: join(dir, "worktrees") },
    skills: { agentDir: join(dir, "agent") },
  }));
  const config = { ...loaded, skillsEnabled: false };
  let scans = 0;
  const discovery = async () => {
    scans += 1;
    return [join(root, "AGENTS.md")];
  };

  const firstCache = new WorkspaceContextCache(config, discovery);
  const first = await firstCache.get(root);
  assert.equal(first.cacheHit, false);
  assert.deepEqual(first.index.instructionPaths, [join(root, "AGENTS.md")]);
  assert.equal((await firstCache.get(root)).cacheHit, true);
  assert.equal(scans, 1);

  // Recreate the cache as if the DevSpace service restarted.
  const restartedCache = new WorkspaceContextCache(config, discovery);
  const restored = await restartedCache.get(root);
  assert.equal(restored.cacheHit, true);
  assert.equal(scans, 1);
  assert.equal((await restartedCache.get(root, true)).cacheHit, false);
  assert.equal(scans, 2);

  await restartedCache.invalidate(root);
  assert.equal((await restartedCache.get(root)).cacheHit, false);
  assert.equal(scans, 3);
});

test("text and path keyword lookups reuse the index until refresh", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "devspace-context-search-test-"));
  t.after(async () => rm(dir, { recursive: true, force: true }));
  const root = join(dir, "project");
  await mkdir(root);
  await writeFile(join(root, "AGENTS.md"), "quartz networking conventions\n");
  const loaded = loadConfig(writeTestDevspaceConfig(join(dir, "config"), {
    server: { port: 1 },
    workspaces: { allowedRoots: [dir], worktreeRoot: join(dir, "worktrees") },
    skills: { agentDir: join(dir, "agent") },
  }));
  let scanned = 0;
  const cache = new WorkspaceContextCache({ ...loaded, skillsEnabled: false }, async () => {
    scanned += 1;
    return [join(root, "AGENTS.md"), ...(scanned > 1 ? [join(root, "AGENT.md")] : [])];
  });
  const { index } = await cache.get(root);
  const canonicalRoot = await realpath(root);
  const first = await cache.search(index, root, canonicalRoot, "quartz", 10);
  assert.equal(first.totalMatches, 1);
  assert.equal(first.matches[0]?.path, join(root, "AGENTS.md"));

  await writeFile(join(root, "AGENT.md"), "replication logic\n");
  const stale = await cache.get(root);
  assert.equal(stale.cacheHit, true);
  assert.equal((await cache.search(stale.index, root, canonicalRoot, "replication", 10)).totalMatches, 0);
  const updated = await cache.get(root, true);
  assert.equal((await cache.search(updated.index, root, canonicalRoot, "replication", 10)).totalMatches, 1);
});

test("instruction search excludes symlinks that escape the workspace", {
  skip: process.platform === "win32",
}, async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "devspace-context-symlink-test-"));
  t.after(async () => rm(dir, { recursive: true, force: true }));
  const root = join(dir, "project");
  const outside = join(dir, "outside");
  await mkdir(root);
  await mkdir(outside);
  await writeFile(join(outside, "AGENTS.md"), "private text marker");
  await symlink(outside, join(root, "linked"), "dir");
  const loaded = loadConfig(writeTestDevspaceConfig(join(dir, "config"), {
    server: { port: 1 },
    workspaces: { allowedRoots: [dir], worktreeRoot: join(dir, "worktrees") },
    skills: { agentDir: join(dir, "agent") },
  }));
  const cache = new WorkspaceContextCache({ ...loaded, skillsEnabled: false }, async () => [
    join(root, "linked", "AGENTS.md"),
  ]);
  const { index } = await cache.get(root);
  const result = await cache.search(index, root, await realpath(root), "marker", 10);
  assert.equal(result.totalMatches, 0);
});
