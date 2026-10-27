// Rune Weaver Dashboard — Structured poll predicate model tests.
import { describe, expect, it } from "vitest";
import {
  MAX_POLL_PREDICATES,
  POLL_SINCE_DAYS_MAX,
  POLL_SINCE_DAYS_MIN,
  POLL_SINCE_PRESETS,
  pollPredicatePreview,
  predicatesFromJob,
  predicatesToPayload,
  validatePollPredicates,
  type SchedulerJob,
} from "./scheduler";

function baseJob(overrides: Partial<SchedulerJob> = {}): SchedulerJob {
  return {
    id: "job-1",
    name: "mail watcher",
    schedule: "",
    prompt: "Summarize arrivals",
    enabled: true,
    pollAccount: "icloud",
    pollQuery: null,
    pollMailbox: "INBOX",
    pollIntervalSeconds: 300,
    pollLimit: 10,
    createdAt: new Date(0).toISOString(),
    updatedAt: new Date(0).toISOString(),
    ...overrides,
  };
}

describe("predicatesFromJob", () => {
  it("renders a legacy pollQuery as one Contains row", () => {
    const rows = predicatesFromJob(baseJob({ pollQuery: "from:alerts" }));
    expect(rows).toEqual([{ kind: "contains", value: "from:alerts" }]);
  });

  it("returns no rows when neither structured fields nor legacy query exist", () => {
    expect(predicatesFromJob(baseJob())).toEqual([]);
  });

  it("reads pollQuery as Contains alongside structured fields", () => {
    const rows = predicatesFromJob(
      baseJob({ pollQuery: "legacy", pollFrom: "alerts@example.com" }),
    );
    expect(rows).toEqual([
      { kind: "contains", value: "legacy" },
      { kind: "from", value: "alerts@example.com" },
    ]);
  });

  it("round-trips structured fields", () => {
    const job = baseJob({
      pollContains: "invoice",
      pollFrom: "billing@example.com",
      pollSubject: "due",
      pollUnreadOnly: true,
      pollSinceDays: 7,
      pollQuery: "invoice",
    });
    expect(predicatesFromJob(job)).toEqual([
      { kind: "contains", value: "invoice" },
      { kind: "from", value: "billing@example.com" },
      { kind: "subject", value: "due" },
      { kind: "unread" },
      { kind: "sinceDays", days: 7 },
    ]);
  });
});

describe("predicatesToPayload", () => {
  it("maps rows to structured fields and mirrors Contains into pollQuery", () => {
    const payload = predicatesToPayload([
      { kind: "contains", value: "invoice" },
      { kind: "from", value: "billing@example.com" },
      { kind: "subject", value: "due" },
      { kind: "unread" },
      { kind: "sinceDays", days: 7 },
    ]);
    expect(payload).toEqual({
      pollContains: "invoice",
      pollFrom: "billing@example.com",
      pollSubject: "due",
      pollUnreadOnly: true,
      pollSinceDays: 7,
      pollQuery: "invoice",
    });
  });

  it("clears pollQuery when no Contains row exists", () => {
    const payload = predicatesToPayload([{ kind: "unread" }]);
    expect(payload.pollQuery).toBeNull();
    expect(payload.pollContains).toBeNull();
    expect(payload.pollUnreadOnly).toBe(true);
    expect(payload.pollSinceDays).toBeNull();
  });

  it("round-trips through predicatesFromJob", () => {
    const payload = predicatesToPayload([
      { kind: "contains", value: "hello" },
      { kind: "sinceDays", days: 30 },
    ]);
    const rows = predicatesFromJob(baseJob({ ...payload }));
    expect(rows).toEqual([
      { kind: "contains", value: "hello" },
      { kind: "sinceDays", days: 30 },
    ]);
  });
});

describe("pollPredicatePreview", () => {
  it("joins rows as one AND sentence", () => {
    const text = pollPredicatePreview([
      { kind: "contains", value: "invoice" },
      { kind: "from", value: "billing@example.com" },
      { kind: "unread" },
      { kind: "sinceDays", days: 7 },
    ]);
    expect(text).toBe(
      'Contains "invoice" AND From "billing@example.com" AND Unread only AND Within last 7 days',
    );
  });

  it("reads empty rows as match-all", () => {
    expect(pollPredicatePreview([])).toBe("Match all mail");
  });
});

describe("validatePollPredicates", () => {
  it("allows zero rows as match-all", () => {
    expect(validatePollPredicates([])).toBeNull();
    expect(validatePollPredicates(null)).toBeNull();
    expect(validatePollPredicates(undefined)).toBeNull();
  });

  it("passes unread-only rows with no value", () => {
    expect(validatePollPredicates([{ kind: "unread" }])).toBeNull();
  });

  it("rejects blank text values with scoped messages", () => {
    expect(
      validatePollPredicates([{ kind: "contains", value: "  " }]),
    ).toContain("Predicate 1");
    expect(
      validatePollPredicates([{ kind: "from", value: "" }]),
    ).toContain("Predicate 1");
    expect(
      validatePollPredicates([{ kind: "subject", value: "" }]),
    ).toContain("Predicate 1");
  });

  it("rejects out-of-range and non-integer days", () => {
    const low = validatePollPredicates([{ kind: "sinceDays", days: 0 }]);
    expect(low).toContain("Predicate 1");
    expect(low).toContain("1");
    expect(low).toContain("90");
    const high = validatePollPredicates([{ kind: "sinceDays", days: 91 }]);
    expect(high).toContain("Predicate 1");
    const fractional = validatePollPredicates([
      { kind: "sinceDays", days: 1.5 },
    ]);
    expect(fractional).toContain("Predicate 1");
  });

  it("rejects more than five rows", () => {
    const rows = Array.from({ length: MAX_POLL_PREDICATES + 1 }, (_, i) => ({
      kind: "contains" as const,
      value: `term-${i}`,
    }));
    const failure = validatePollPredicates(rows);
    expect(failure).toContain(String(MAX_POLL_PREDICATES));
  });
});

describe("predicate bounds", () => {
  it("pins the since-days window and presets", () => {
    expect(POLL_SINCE_DAYS_MIN).toBe(1);
    expect(POLL_SINCE_DAYS_MAX).toBe(90);
    expect([...POLL_SINCE_PRESETS]).toEqual([1, 7, 30]);
    expect(MAX_POLL_PREDICATES).toBe(5);
  });
});
