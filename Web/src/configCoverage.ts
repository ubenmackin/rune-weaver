// Rune Weaver Dashboard — Config to Settings coverage ledger.
//
// Purpose: maps every RuneWeaverConfig leaf key to its owning Settings surface
// so coverage, interface, and example stay in lockstep on config changes, with
// bash snake_case canonical plus camelCase aliases accepted on decode.
// Scope: ledger data plus lookup only; Settings panes, REST DTOs, and TOML
// decoding stay with their owners.
// Architectural role: fail-loudly contract that every leaf key resolves to
// exactly one surface identifier or an explicit exclusion with reason.

export const SETTINGS_SURFACES = [
  "bash-modal",
  "files-pane",
  "policy-pane",
  "index-pane",
  "browser-pane",
  "desktop-pane",
  "media-pane",
  "goals-pane",
  "scheduler-pane",
  "memory-pane",
  "voice-pane",
  "workspace-pane",
  "security-pane",
  "server-pane",
  "auth-pane",
  "llm-pane",
  "plugins-pane",
  "fanout-pane",
  "proactive-pane",
  "ideas-pane",
  "persona-pane",
] as const;

export type SettingsSurface = (typeof SETTINGS_SURFACES)[number];

// Engine shares server-pane, containers shares security-pane, email shares
// scheduler-pane via poll_account linkage, and home shares plugins-pane:
// the fixed set carries no dedicated pane for those sections.
export const CONFIG_SETTINGS_COVERAGE: Record<string, SettingsSurface> = {
  "engine.name": "server-pane",
  "engine.log_level": "server-pane",
  "engine.compaction_threshold_percent": "server-pane",
  "engine.max_tool_iterations": "server-pane",
  "server.hostname": "server-pane",
  "server.port": "server-pane",
  "server.allowed_hosts": "server-pane",
  "auth.token_env": "auth-pane",
  "auth.token_file": "auth-pane",
  "llm.default_provider": "llm-pane",
  "llm.fallback_provider": "llm-pane",
  "llm.providers.*.enabled": "llm-pane",
  "llm.providers.*.model": "llm-pane",
  "llm.providers.*.server_url": "llm-pane",
  "llm.providers.*.api_key_env": "llm-pane",
  "llm.providers.*.provider_type": "llm-pane",
  "llm.providers.*.api_style": "llm-pane",
  "llm.providers.*.context_length": "llm-pane",
  "llm.providers.*.supports_vision": "llm-pane",
  "llm.providers.*.slot_count": "llm-pane",
  "llm.providers.*.cache_prompt": "llm-pane",
  "memory.vector_db_path": "memory-pane",
  "memory.episodes_db_path": "memory-pane",
  "memory.embedding_model": "memory-pane",
  "memory.embedding_backend": "memory-pane",
  "memory.recall_per_tier_limit": "memory-pane",
  "memory.recall_auto_limit": "memory-pane",
  "memory.recall_threshold": "memory-pane",
  "memory.recall_max_chars": "memory-pane",
  "memory.recall_per_hit_chars": "memory-pane",
  "memory.recall_doc_pool_multiplier": "memory-pane",
  "memory.recall_episodic_weight": "memory-pane",
  "voice.stt_provider": "voice-pane",
  "voice.whisper_model": "voice-pane",
  "voice.tts_provider": "voice-pane",
  "containers.memory_mb": "security-pane",
  "containers.max_concurrent": "security-pane",
  "containers.ttl_minutes": "security-pane",
  "files.deny_patterns": "files-pane",
  "files.allow_roots": "files-pane",
  "files.require_approval_on_deny": "files-pane",
  "files.write_mode": "files-pane",
  "index.enabled": "index-pane",
  "index.files": "index-pane",
  "index.mail": "index-pane",
  "index.messages": "index-pane",
  "index.calendars": "index-pane",
  "index.reminders": "index-pane",
  "index.roots": "index-pane",
  "index.exclude": "index-pane",
  "index.max_file_mb": "index-pane",
  "index.mail_vector_window": "index-pane",
  "index.icloud_evicted": "index-pane",
  "index.describe_images_with_llm": "index-pane",
  "index.nightly_budget": "index-pane",
  "index.db_path": "index-pane",
  "index.effort": "index-pane",
  "index.workers": "index-pane",
  "index.thermal_backoff": "index-pane",
  "index.pause_on_battery": "index-pane",
  "index.max_vector_chunks_per_document": "index-pane",
  "index.mailbox_deny": "index-pane",
  "email.accounts.*.name": "scheduler-pane",
  "email.accounts.*.type": "scheduler-pane",
  "email.accounts.*.host": "scheduler-pane",
  "email.accounts.*.port": "scheduler-pane",
  "email.accounts.*.username": "scheduler-pane",
  "email.accounts.*.smtp_host": "scheduler-pane",
  "email.accounts.*.smtp_port": "scheduler-pane",
  "email.accounts.*.smtp_security": "scheduler-pane",
  "home.homekit.enabled": "plugins-pane",
  "home.home_assistant.enabled": "plugins-pane",
  "home.home_assistant.url": "plugins-pane",
  "home.home_assistant.token_env": "plugins-pane",
  "scheduler.max_tool_iterations": "scheduler-pane",
  "scheduler.on_tool_limit": "scheduler-pane",
  "scheduler.jobs.*.name": "scheduler-pane",
  "scheduler.jobs.*.prompt": "scheduler-pane",
  "scheduler.jobs.*.enabled": "scheduler-pane",
  "scheduler.jobs.*.schedule": "scheduler-pane",
  "scheduler.jobs.*.poll_account": "scheduler-pane",
  "scheduler.jobs.*.poll_query": "scheduler-pane",
  "scheduler.jobs.*.poll_mailbox": "scheduler-pane",
  "scheduler.jobs.*.poll_interval_seconds": "scheduler-pane",
  "scheduler.jobs.*.poll_limit": "scheduler-pane",
  "scheduler.jobs.*.max_tool_iterations": "scheduler-pane",
  "scheduler.jobs.*.on_tool_limit": "scheduler-pane",
  "plugins.plugins_dir": "plugins-pane",
  "plugins.marketplace_index_url": "plugins-pane",
  "plugins.auto_rescan": "plugins-pane",
  "browser.searxng_url": "browser-pane",
  "browser.search_timeout_seconds": "browser-pane",
  "browser.max_results": "browser-pane",
  "browser.timeout_seconds": "browser-pane",
  "browser.fetch_timeout_seconds": "browser-pane",
  "media.timeout_seconds": "media-pane",
  "media.sonarr.enabled": "media-pane",
  "media.sonarr.url": "media-pane",
  "media.sonarr.api_key_env": "media-pane",
  "media.sonarr.default_quality_profile": "media-pane",
  "media.sonarr.default_root_folder": "media-pane",
  "media.radarr.enabled": "media-pane",
  "media.radarr.url": "media-pane",
  "media.radarr.api_key_env": "media-pane",
  "media.radarr.default_quality_profile": "media-pane",
  "media.radarr.default_root_folder": "media-pane",
  "desktop.max_image_dimension": "desktop-pane",
  "desktop.jpeg_quality": "desktop-pane",
  "desktop.blocked_apps": "desktop-pane",
  "security.untrusted_labeling": "security-pane",
  "security.email_credential_filter": "security-pane",
  "goals.enabled": "goals-pane",
  "goals.step_interval_minutes": "goals-pane",
  "goals.max_active_goals": "goals-pane",
  "goals.max_steps_per_goal": "goals-pane",
  "goals.plan_timeout_seconds": "goals-pane",
  "goals.max_triggers_per_goal": "goals-pane",
  "goals.max_tool_iterations": "goals-pane",
  "goals.max_step_budget_exceeded_retries": "goals-pane",
  "bash.enabled": "bash-modal",
  "bash.default_action": "bash-modal",
  "bash.timeout_seconds": "bash-modal",
  "bash.allow_network": "bash-modal",
  "bash.cpu_seconds": "bash-modal",
  "bash.memory_mb": "bash-modal",
  "bash.sandbox_mode": "bash-modal",
  "bash.host_allow_patterns": "bash-modal",
  "bash.rules": "bash-modal",
  "bash.rules.*.pattern": "bash-modal",
  "bash.rules.*.action": "bash-modal",
  "proactive.mode": "proactive-pane",
  "proactive.judge_timeout_seconds": "proactive-pane",
  "ideas.enabled": "ideas-pane",
  "ideas.max_per_cycle": "ideas-pane",
  "ideas.timeout_seconds": "ideas-pane",
  "fanout.max_workers": "fanout-pane",
  "fanout.worker_timeout_seconds": "fanout-pane",
  "fanout.full_tools": "fanout-pane",
  "workspace.quota_mb": "workspace-pane",
  "workspace.quota_files": "workspace-pane",
  "workspace.tmp_ttl_days": "workspace-pane",
  "persona.assistant_name": "persona-pane",
  "persona.tone": "persona-pane",
  "persona.style": "persona-pane",
  "persona.user_name": "persona-pane",
  "persona.avatar": "persona-pane",
};

export const CONFIG_COVERAGE_EXCLUSIONS: Record<string, string> = {
  "index.always_skipped":
    "Derived from the file walker prune list; read-only with no owner editing.",
};

// Concrete provider, account, job, and rule names collapse to their wildcard
// template so one entry covers every dynamic instance.
function toTemplateKey(key: string): string {
  if (key.startsWith("llm.providers.")) {
    const parts = key.split(".");
    if (parts.length >= 4) return `llm.providers.*.${parts[parts.length - 1]}`;
  }
  if (key.startsWith("email.accounts.")) {
    const parts = key.split(".");
    if (parts.length >= 3) return `email.accounts.*.${parts[parts.length - 1]}`;
  }
  if (key.startsWith("scheduler.jobs.")) {
    const parts = key.split(".");
    if (parts.length >= 3) return `scheduler.jobs.*.${parts[parts.length - 1]}`;
  }
  if (key.startsWith("bash.rules.")) {
    const parts = key.split(".");
    if (parts.length >= 3) return `bash.rules.*.${parts[parts.length - 1]}`;
  }
  return key;
}

// Dashboard sends snake_case; decode also accepts camelCase aliases.
const BASH_CAMEL_ALIASES: Record<string, string> = {
  "bash.defaultAction": "bash.default_action",
  "bash.timeoutSeconds": "bash.timeout_seconds",
  "bash.cpuSeconds": "bash.cpu_seconds",
  "bash.memoryMb": "bash.memory_mb",
  "bash.allowNetwork": "bash.allow_network",
  "bash.sandboxMode": "bash.sandbox_mode",
  "bash.hostAllowPatterns": "bash.host_allow_patterns",
};

export function coverageForConfigKey(key: string): SettingsSurface | "none" {
  const normalized = (key ?? "").trim();
  const canonical = BASH_CAMEL_ALIASES[normalized] ?? normalized;
  const direct = CONFIG_SETTINGS_COVERAGE[canonical];
  if (direct !== undefined) return direct;
  if (canonical in CONFIG_COVERAGE_EXCLUSIONS) return "none";
  if (canonical.includes("*")) return "none";
  const template = toTemplateKey(canonical);
  if (template !== canonical) {
    const mapped = CONFIG_SETTINGS_COVERAGE[template];
    if (mapped !== undefined) return mapped;
  }
  return "none";
}
