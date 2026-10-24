// Rune Weaver Dashboard — Guard test for the config to Settings coverage ledger.

import { describe, expect, it } from "vitest";
import {
  CONFIG_COVERAGE_EXCLUSIONS,
  CONFIG_SETTINGS_COVERAGE,
  coverageForConfigKey,
  SETTINGS_SURFACES,
} from "./configCoverage";

// The web suite carries no @types/node (the production bundle must never gain
// a Node dependency), so the Node global the test-only probes reach for is
// declared locally, mirroring the `process` shim in vite.config.ts.
declare const process: { cwd: () => string };

const EXPECTED_LEAF_KEYS: readonly string[] = [
  "engine.name",
  "engine.log_level",
  "engine.compaction_threshold_percent",
  "engine.max_tool_iterations",
  "server.hostname",
  "server.port",
  "server.allowed_hosts",
  "auth.token_env",
  "auth.token_file",
  "llm.default_provider",
  "llm.fallback_provider",
  "llm.providers.*.enabled",
  "llm.providers.*.model",
  "llm.providers.*.server_url",
  "llm.providers.*.api_key_env",
  "llm.providers.*.provider_type",
  "llm.providers.*.api_style",
  "llm.providers.*.context_length",
  "llm.providers.*.supports_vision",
  "llm.providers.*.slot_count",
  "llm.providers.*.cache_prompt",
  "memory.vector_db_path",
  "memory.episodes_db_path",
  "memory.embedding_model",
  "memory.embedding_backend",
  "memory.recall_per_tier_limit",
  "memory.recall_auto_limit",
  "memory.recall_threshold",
  "memory.recall_max_chars",
  "memory.recall_per_hit_chars",
  "memory.recall_doc_pool_multiplier",
  "memory.recall_episodic_weight",
  "voice.stt_provider",
  "voice.whisper_model",
  "voice.tts_provider",
  "containers.memory_mb",
  "containers.max_concurrent",
  "containers.ttl_minutes",
  "files.deny_patterns",
  "files.allow_roots",
  "files.require_approval_on_deny",
  "files.write_mode",
  "files.write_paths",
  "files.write_paths.*.path",
  "files.write_paths.*.posture",
  "index.enabled",
  "index.files",
  "index.mail",
  "index.messages",
  "index.calendars",
  "index.reminders",
  "index.roots",
  "index.exclude",
  "index.max_file_mb",
  "index.mail_vector_window",
  "index.icloud_evicted",
  "index.nightly_budget",
  "index.db_path",
  "index.effort",
  "index.workers",
  "index.thermal_backoff",
  "index.pause_on_battery",
  "index.max_vector_chunks_per_document",
  "index.mailbox_deny",
  "email.accounts.*.name",
  "email.accounts.*.type",
  "email.accounts.*.host",
  "email.accounts.*.port",
  "email.accounts.*.username",
  "email.accounts.*.smtp_host",
  "email.accounts.*.smtp_port",
  "email.accounts.*.smtp_security",
  "home.homekit.enabled",
  "home.home_assistant.enabled",
  "home.home_assistant.url",
  "home.home_assistant.token_env",
  "scheduler.max_tool_iterations",
  "scheduler.on_tool_limit",
  "scheduler.jobs.*.name",
  "scheduler.jobs.*.prompt",
  "scheduler.jobs.*.enabled",
  "scheduler.jobs.*.schedule",
  "scheduler.jobs.*.poll_account",
  "scheduler.jobs.*.poll_query",
  "scheduler.jobs.*.poll_mailbox",
  "scheduler.jobs.*.poll_interval_seconds",
  "scheduler.jobs.*.poll_limit",
  "scheduler.jobs.*.max_tool_iterations",
  "scheduler.jobs.*.on_tool_limit",
  "plugins.plugins_dir",
  "plugins.marketplace_index_url",
  "plugins.auto_rescan",
  "browser.searxng_url",
  "browser.search_timeout_seconds",
  "browser.max_results",
  "browser.timeout_seconds",
  "browser.fetch_timeout_seconds",
  "media.timeout_seconds",
  "media.sonarr.enabled",
  "media.sonarr.url",
  "media.sonarr.api_key_env",
  "media.sonarr.default_quality_profile",
  "media.sonarr.default_root_folder",
  "media.radarr.enabled",
  "media.radarr.url",
  "media.radarr.api_key_env",
  "media.radarr.default_quality_profile",
  "media.radarr.default_root_folder",
  "desktop.max_image_dimension",
  "desktop.jpeg_quality",
  "desktop.blocked_apps",
  "security.untrusted_labeling",
  "security.email_credential_filter",
  "goals.enabled",
  "goals.step_interval_minutes",
  "goals.max_active_goals",
  "goals.max_steps_per_goal",
  "goals.plan_timeout_seconds",
  "goals.max_triggers_per_goal",
  "goals.max_tool_iterations",
  "goals.max_step_budget_exceeded_retries",
  "bash.enabled",
  "bash.default_action",
  "bash.timeout_seconds",
  "bash.allow_network",
  "bash.cpu_seconds",
  "bash.memory_mb",
  "bash.sandbox_mode",
  "bash.host_allow_patterns",
  "bash.rules",
  "bash.rules.*.pattern",
  "bash.rules.*.action",
  "proactive.mode",
  "proactive.judge_timeout_seconds",
  "ideas.enabled",
  "ideas.max_per_cycle",
  "ideas.timeout_seconds",
  "fanout.max_workers",
  "fanout.worker_timeout_seconds",
  "fanout.full_tools",
  "workspace.quota_mb",
  "workspace.quota_files",
  "workspace.tmp_ttl_days",
  "persona.assistant_name",
  "persona.tone",
  "persona.style",
  "persona.user_name",
  "persona.avatar",
  "notifications.approval_requested",
  "notifications.scheduler_run",
  "notifications.goal_advance",
  "notifications.idea_proposed",
  "notifications.index_failed",
  "notifications.chat_failed",
];

// Adding a RuneWeaverConfig leaf key rides one change across ledger, Settings
// UI, and config.toml.example, with EXPECTED_LEAF_KEYS updated alongside; the
// Swift and example probes below fail otherwise, so a silent drift cannot land.
type SwiftFieldKind =
  | { kind: "template"; key: string }
  | { kind: "suffix"; suffix: string }
  | { kind: "skip" };

// Bracketed instances collapse to wildcard templates while bare \(var).leaf
// forms defer to suffix existence, since the calling prefix selects the family.
function normalizeSwiftField(raw: string): SwiftFieldKind {
  if (raw.includes("\\(suffix)") || raw.includes("(suffix)")) {
    return { kind: "skip" };
  }
  if (/^\\?\([^)]*\)\.[a-z_][a-z_0-9]*$/.test(raw)) {
    return { kind: "suffix", suffix: raw.slice(raw.lastIndexOf(".") + 1) };
  }
  let template = raw.replace(/\[[^\]]*\]/g, ".*");
  template = template.replace(/\\?\([^)]*\)/g, "*");
  if (
    template === "*" ||
    template.endsWith(".*") ||
    template.includes("(") ||
    template.includes("\\")
  ) {
    return { kind: "skip" };
  }
  if (/^email\.accounts\.(?!\*\.).+/.test(template)) {
    return {
      kind: "template",
      key: `email.accounts.*.${template.slice("email.accounts.".length)}`,
    };
  }
  if (/^scheduler\.jobs\.(?!\*\.).+/.test(template)) {
    return {
      kind: "template",
      key: `scheduler.jobs.*.${template.slice("scheduler.jobs.".length)}`,
    };
  }
  if (/^bash\.rules\.(?!\*\.).+/.test(template)) {
    return {
      kind: "template",
      key: `bash.rules.*.${template.slice("bash.rules.".length)}`,
    };
  }
  if (/^files\.write_paths\.(?!\*\.).+/.test(template)) {
    return {
      kind: "template",
      key: `files.write_paths.*.${template.slice("files.write_paths.".length)}`,
    };
  }
  if (/^files\.write_path_rules\.(?!\*\.).+/.test(template)) {
    return {
      kind: "template",
      key: `files.write_path_rules.*.${template.slice("files.write_path_rules.".length)}`,
    };
  }
  if (/^llm\.providers\.[^*]+\..+/.test(template)) {
    const parts = template.split(".");
    return { kind: "template", key: `llm.providers.*.${parts[parts.length - 1]}` };
  }
  return { kind: "template", key: template };
}

async function collectSwiftLedgerEvidence(): Promise<{
  templates: Set<string>;
  suffixes: Set<string>;
}> {
  const { readFileSync, readdirSync } = (await import(
    // @ts-expect-error node builtin without @types/node; test-only probe.
    "node:fs"
  )) as {
    readFileSync: (path: string, encoding: string) => string;
    readdirSync: (dir: string) => string[];
  };
  const { resolve } = (await import(
    // @ts-expect-error node builtin without @types/node; test-only probe.
    "node:path"
  )) as { resolve: (...segments: string[]) => string };
  const candidates = [
    resolve(process.cwd(), "../Sources/RuneWeaverCore"),
    resolve(process.cwd(), "Sources/RuneWeaverCore"),
  ];
  let coreDir: string | null = null;
  for (const candidate of candidates) {
    try {
      readdirSync(candidate);
      coreDir = candidate;
      break;
    } catch {
      continue;
    }
  }
  if (coreDir === null) {
    throw new Error("Swift core sources unavailable for coverage drift check");
  }
  const templates = new Set<string>();
  const suffixes = new Set<string>();
  // Cron schedule fields plus plugin manifest fields share the field shape
  // without being RuneWeaverConfig leaf keys, so only Config-owned sources
  // participate in the drift check.
  for (const entry of readdirSync(coreDir)) {
    if (!entry.startsWith("Config") || !entry.endsWith(".swift")) {
      continue;
    }
    const text = readFileSync(resolve(coreDir, entry), "utf8");
    const raws: string[] = [];
    const fieldPattern = /field:\s*"([^"]*)"/g;
    let match: RegExpExecArray | null;
    while ((match = fieldPattern.exec(text)) !== null) {
      raws.push(match[1]);
    }
    const defaultPattern = /field\s*:\s*String\s*=\s*"([^"]*)"/g;
    while ((match = defaultPattern.exec(text)) !== null) {
      raws.push(match[1]);
    }
    for (const raw of raws) {
      const normalized = normalizeSwiftField(raw);
      if (normalized.kind === "template") {
        templates.add(normalized.key);
      } else if (normalized.kind === "suffix") {
        suffixes.add(normalized.suffix);
      }
    }
  }
  return { templates, suffixes };
}

// Commented example keys count: defaults ship commented, so stripped headers
// plus stripped keys form the template set with provider and array instances
// collapsed; home arrays stay concrete matching the ledger shape.
function toExampleTemplate(path: string[], key: string): string {
  if (path.length === 3 && path[0] === "llm" && path[1] === "providers") {
    return `llm.providers.*.${key}`;
  }
  const dotted = path.join(".");
  if (dotted === "email.accounts") {
    return `email.accounts.*.${key}`;
  }
  if (dotted === "scheduler.jobs") {
    return `scheduler.jobs.*.${key}`;
  }
  if (dotted === "bash.rules") {
    return `bash.rules.*.${key}`;
  }
  return `${dotted}.${key}`;
}

async function collectExampleLedgerKeys(): Promise<Set<string>> {
  const { readFileSync } = (await import(
    // @ts-expect-error node builtin without @types/node; test-only probe.
    "node:fs"
  )) as { readFileSync: (path: string, encoding: string) => string };
  const { resolve } = (await import(
    // @ts-expect-error node builtin without @types/node; test-only probe.
    "node:path"
  )) as { resolve: (...segments: string[]) => string };
  const candidates = [
    resolve(process.cwd(), "../Config/config.toml.example"),
    resolve(process.cwd(), "Config/config.toml.example"),
  ];
  let text: string | null = null;
  for (const candidate of candidates) {
    try {
      text = readFileSync(candidate, "utf8");
      break;
    } catch {
      continue;
    }
  }
  if (text === null) {
    throw new Error("config.toml.example unavailable for coverage drift check");
  }
  const keys = new Set<string>();
  let path: string[] = [];
  for (const rawLine of text.split("\n")) {
    let line = rawLine.trim();
    if (line.startsWith("#")) {
      line = line.slice(1).trim();
    }
    if (line === "" || line.startsWith("#")) {
      continue;
    }
    if (line.startsWith("[[") && line.endsWith("]]")) {
      const body = line.slice(2, -2).trim();
      if (body !== "") {
        path = body
          .split(".")
          .map((part) => part.trim())
          .filter((part) => part !== "");
      }
      continue;
    }
    if (line.startsWith("[") && line.endsWith("]")) {
      const body = line.slice(1, -1).trim();
      if (body !== "") {
        path = body
          .split(".")
          .map((part) => part.trim())
          .filter((part) => part !== "");
      }
      continue;
    }
    const separator = line.indexOf("=");
    if (separator === -1 || path.length === 0) {
      continue;
    }
    const key = line.slice(0, separator).trim();
    if (!/^[A-Za-z_][A-Za-z_0-9]*$/.test(key)) {
      continue;
    }
    keys.add(toExampleTemplate(path, key));
  }
  return keys;
}

describe("configCoverage", () => {
  it("leaves no RuneWeaverConfig leaf key unmapped", () => {
    for (const key of EXPECTED_LEAF_KEYS) {
      expect(CONFIG_SETTINGS_COVERAGE[key]).toBeDefined();
      expect(coverageForConfigKey(key)).not.toBe("none");
    }
    for (const key of Object.keys(CONFIG_SETTINGS_COVERAGE)) {
      expect(EXPECTED_LEAF_KEYS).toContain(key);
    }
  });

  it("resolves bash sandbox keys to bash-pane", () => {
    expect(coverageForConfigKey("bash.sandbox_mode")).toBe("bash-pane");
    expect(coverageForConfigKey("bash.host_allow_patterns")).toBe("bash-pane");
    expect(coverageForConfigKey("bash.sandboxMode")).toBe("bash-pane");
    expect(coverageForConfigKey("bash.hostAllowPatterns")).toBe("bash-pane");
  });

  it("resolves bash camelCase aliases to bash-pane", () => {
    expect(coverageForConfigKey("bash.defaultAction")).toBe("bash-pane");
    expect(coverageForConfigKey("bash.timeoutSeconds")).toBe("bash-pane");
    expect(coverageForConfigKey("bash.cpuSeconds")).toBe("bash-pane");
    expect(coverageForConfigKey("bash.memoryMb")).toBe("bash-pane");
    expect(coverageForConfigKey("bash.allowNetwork")).toBe("bash-pane");
  });

  it("requires non-empty reasons for exclusions with surface none", () => {
    for (const [key, reason] of Object.entries(CONFIG_COVERAGE_EXCLUSIONS)) {
      expect(reason.trim().length).toBeGreaterThan(0);
      expect(coverageForConfigKey(key)).toBe("none");
    }
  });

  it("uses surface identifiers from the fixed set exclusively", () => {
    for (const surface of Object.values(CONFIG_SETTINGS_COVERAGE)) {
      expect(SETTINGS_SURFACES).toContain(surface);
    }
  });

  it("resolves concrete dynamic instances through wildcard templates", () => {
    expect(coverageForConfigKey("llm.providers.mlx.enabled")).toBe("llm-pane");
    expect(coverageForConfigKey("email.accounts.icloud.host")).toBe("scheduler-pane");
    expect(coverageForConfigKey("scheduler.jobs.morning digest.prompt")).toBe(
      "scheduler-pane",
    );
    expect(coverageForConfigKey("bash.rules.0.pattern")).toBe("bash-pane");
  });

  it("returns none for a synthetic unmapped key", () => {
    expect(coverageForConfigKey("synthetic.unmapped_key")).toBe("none");
  });

  it("fails when Swift field literals drift from the ledger", async () => {
    const { templates, suffixes } = await collectSwiftLedgerEvidence();
    expect(templates.size).toBeGreaterThan(0);
    for (const key of templates) {
      if (key in CONFIG_COVERAGE_EXCLUSIONS) {
        continue;
      }
      expect(
        coverageForConfigKey(key),
        `Swift field ${key} needs ledger plus UI plus example in the same change`,
      ).not.toBe("none");
    }
    const ledgerKeys = Object.keys(CONFIG_SETTINGS_COVERAGE);
    for (const suffix of suffixes) {
      expect(
        ledgerKeys.some((ledgerKey) => ledgerKey.endsWith(`.${suffix}`)),
        `Swift suffix .${suffix} needs a ledger wildcard template`,
      ).toBe(true);
    }
  });

  it("fails when config.toml.example drifts from the ledger", async () => {
    const exampleKeys = await collectExampleLedgerKeys();
    expect(exampleKeys.size).toBeGreaterThan(0);
    for (const key of exampleKeys) {
      if (key in CONFIG_COVERAGE_EXCLUSIONS) {
        continue;
      }
      expect(
        coverageForConfigKey(key),
        `Example key ${key} needs ledger plus UI in the same change`,
      ).not.toBe("none");
    }
  });

  it("keeps every ledger key backed by Swift sources or the example", async () => {
    const { templates: swiftTemplates, suffixes } =
      await collectSwiftLedgerEvidence();
    const exampleKeys = await collectExampleLedgerKeys();
    for (const ledgerKey of Object.keys(CONFIG_SETTINGS_COVERAGE)) {
      if (swiftTemplates.has(ledgerKey) || exampleKeys.has(ledgerKey)) {
        continue;
      }
      const leaf = ledgerKey.slice(ledgerKey.lastIndexOf(".") + 1);
      expect(
        suffixes.has(leaf),
        `Ledger key ${ledgerKey} needs Swift plus example backing`,
      ).toBe(true);
    }
  });
});
