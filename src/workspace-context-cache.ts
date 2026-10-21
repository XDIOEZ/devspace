import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, stat, realpath, writeFile } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import type { ServerConfig } from "./config.js";
import { isPathInsideRoot } from "./roots.js";
import { loadWorkspaceSkills, type LoadedSkills } from "./skills.js";

const CACHE_VERSION = 1;
const CACHE_TTL_MS = 10 * 60 * 1000;
const MAX_CACHED_ROOTS = 32;
const MAX_SEARCH_FILE_BYTES = 128 * 1024;

interface SavedDiscovery {
  version: number;
  root: string;
  indexedAt: number;
  instructionPaths: string[];
}

export interface WorkspaceContextIndex {
  indexedAt: number;
  instructionPaths: string[];
  loadedSkills: LoadedSkills;
  searchText?: Promise<Map<string, string>>;
}

export interface WorkspaceContextResult {
  index: WorkspaceContextIndex;
  cacheHit: boolean;
}

export interface WorkspaceContextMatch {
  kind: "skill" | "instruction";
  name: string;
  description: string;
  path: string;
}

/** Reuse project discovery across workspace IDs, conversations and short service restarts. */
export class WorkspaceContextCache {
  private readonly entries = new Map<string, WorkspaceContextIndex>();
  private readonly pending = new Map<string, Promise<WorkspaceContextResult>>();
  private readonly directory: string;

  constructor(
    private readonly config: ServerConfig,
    private readonly discoverInstructions: (root: string) => Promise<string[]>,
  ) {
    this.directory = join(config.stateDir, "workspace-context-cache");
  }

  async get(root: string, refresh = false): Promise<WorkspaceContextResult> {
    const key = resolve(root);
    const cached = this.entries.get(key);
    if (!refresh && cached && isFresh(cached.indexedAt)) {
      this.remember(key, cached);
      return { index: cached, cacheHit: true };
    }
    const pending = this.pending.get(key);
    if (pending) return pending;

    const operation = this.load(key, refresh);
    this.pending.set(key, operation);
    try {
      return await operation;
    } finally {
      if (this.pending.get(key) === operation) this.pending.delete(key);
    }
  }

  /** Explicit refresh or a relevant editor mutation invalidates both cache layers. */
  async invalidate(root: string): Promise<void> {
    const key = resolve(root);
    this.entries.delete(key);
    await rm(this.snapshotPath(key), { force: true }).catch(() => undefined);
  }

  async search(
    index: WorkspaceContextIndex,
    root: string,
    canonicalRoot: string,
    query: string,
    limit: number,
  ): Promise<{ matches: WorkspaceContextMatch[]; totalMatches: number }> {
    const terms = query.toLocaleLowerCase().trim().split(/\s+/u).filter(Boolean);
    const candidates: WorkspaceContextMatch[] = [
      ...index.loadedSkills.skills
        .filter((skill) => !skill.disableModelInvocation)
        .map((skill) => ({
          kind: "skill" as const,
          name: skill.name,
          description: skill.description,
          path: skill.filePath,
        })),
      ...index.instructionPaths.map((path) => ({
        kind: "instruction" as const,
        name: relative(root, path).replace(/\\/g, "/") || "AGENTS.md",
        description: "Project instruction file",
        path,
      })),
    ];
    const contents = await (index.searchText ??= this.readSearchContents(candidates, canonicalRoot));
    const scored = candidates.flatMap((candidate) => {
      if (!contents.has(candidate.path)) return [];
      const name = candidate.name.toLocaleLowerCase();
      const path = candidate.path.toLocaleLowerCase();
      const description = candidate.description.toLocaleLowerCase();
      const body = contents.get(candidate.path) ?? "";
      if (!terms.every((term) => name.includes(term) || path.includes(term)
        || description.includes(term) || body.includes(term))) return [];
      const score = terms.reduce((sum, term) => sum
        + (name === term ? 100 : name.includes(term) ? 35 : 0)
        + (path.includes(term) ? 20 : 0)
        + (description.includes(term) ? 12 : 0)
        + (body.includes(term) ? 2 : 0), 0);
      return [{ candidate, score }];
    });
    scored.sort((a, b) => b.score - a.score || a.candidate.path.localeCompare(b.candidate.path));
    return {
      matches: scored.slice(0, limit).map(({ candidate }) => candidate),
      totalMatches: scored.length,
    };
  }

  private async load(root: string, refresh: boolean): Promise<WorkspaceContextResult> {
    const saved = refresh ? undefined : await this.readSnapshot(root);
    const instructionPaths = saved?.instructionPaths ?? await this.discoverInstructions(root);
    const index: WorkspaceContextIndex = {
      indexedAt: saved?.indexedAt ?? Date.now(),
      instructionPaths: [...new Set(instructionPaths)].filter((path) => isPathInsideRoot(path, root)),
      loadedSkills: loadWorkspaceSkills(this.config, root),
    };
    this.remember(root, index);
    if (!saved) await this.writeSnapshot(root, index).catch(() => undefined);
    return { index, cacheHit: Boolean(saved) };
  }

  private remember(root: string, index: WorkspaceContextIndex): void {
    this.entries.delete(root);
    this.entries.set(root, index);
    while (this.entries.size > MAX_CACHED_ROOTS) {
      const oldest = this.entries.keys().next().value;
      if (oldest === undefined) break;
      this.entries.delete(oldest);
    }
  }

  private snapshotPath(root: string): string {
    const key = createHash("sha256").update(root).digest("hex");
    return join(this.directory, `${key}.json`);
  }

  private async readSnapshot(root: string): Promise<SavedDiscovery | undefined> {
    try {
      const value: unknown = JSON.parse(await readFile(this.snapshotPath(root), "utf8"));
      if (!isSavedDiscovery(value, root)) return undefined;
      return value;
    } catch {
      return undefined;
    }
  }

  private async writeSnapshot(root: string, index: WorkspaceContextIndex): Promise<void> {
    await mkdir(this.directory, { recursive: true });
    const target = this.snapshotPath(root);
    const temporary = `${target}.${randomUUID()}.tmp`;
    try {
      await writeFile(temporary, JSON.stringify({
        version: CACHE_VERSION,
        root,
        indexedAt: index.indexedAt,
        instructionPaths: index.instructionPaths,
      } satisfies SavedDiscovery), { mode: 0o600 });
      await rename(temporary, target);
    } finally {
      await rm(temporary, { force: true }).catch(() => undefined);
    }
  }

  private async readSearchContents(
    candidates: WorkspaceContextMatch[],
    canonicalRoot: string,
  ): Promise<Map<string, string>> {
    const contents = new Map<string, string>();
    for (let offset = 0; offset < candidates.length; offset += 16) {
      await Promise.all(candidates.slice(offset, offset + 16).map(async (candidate) => {
        try {
          const resolved = await realpath(candidate.path);
          if (candidate.kind === "instruction" && !isPathInsideRoot(resolved, canonicalRoot)) return;
          const info = await stat(resolved);
          if (!info.isFile()) return;
          contents.set(candidate.path, info.size > MAX_SEARCH_FILE_BYTES
            ? ""
            : (await readFile(resolved, "utf8")).toLocaleLowerCase());
        } catch {
          // Exclude missing or inaccessible paths rather than offering unreadable results.
        }
      }));
    }
    return contents;
  }
}

function isFresh(indexedAt: number): boolean {
  return Number.isFinite(indexedAt) && indexedAt <= Date.now()
    && Date.now() - indexedAt < CACHE_TTL_MS;
}

function isSavedDiscovery(value: unknown, root: string): value is SavedDiscovery {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Partial<SavedDiscovery>;
  return candidate.version === CACHE_VERSION && candidate.root === root
    && typeof candidate.indexedAt === "number" && isFresh(candidate.indexedAt)
    && Array.isArray(candidate.instructionPaths)
    && candidate.instructionPaths.every((path) => typeof path === "string" && isPathInsideRoot(path, root));
}

export function isContextFilePath(path: string): boolean {
  return /(?:^|[/\\])(?:AGENT|AGENTS|CLAUDE|SKILL)\.md$/i.test(path)
    || /(?:^|[/\\])(?:\.agents|\.claude|\.codex)[/\\]skills[/\\].+\.md$/i.test(path);
}
