// Rune Weaver Dashboard — Per-lane throughput formatting and rendering coverage.
import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import type { IndexLiveQueueLane, IndexLiveStatus } from "../../api";
import IndexBentoHeader from "./IndexBentoHeader";
import { formatLaneRate, resolveIndexPipelineSteps } from "./indexHelpers";

describe("IndexQueueRate and Per-Lane Throughput", () => {
  it("formats lane rate accurately for active, completed, and queued states", () => {
    const activeLane: IndexLiveQueueLane = {
      lane: "imageOCR",
      label: "Image & PDF OCR",
      queued: 12500,
      processed: 276,
      indexed: 212,
      rate: 2.4,
    };
    expect(formatLaneRate(activeLane)).toBe("2.4 docs/s");

    const completedLaneWithRate: IndexLiveQueueLane = {
      lane: "fastText",
      label: "Fast Text",
      queued: 8664,
      processed: 8664,
      indexed: 120,
      rate: 95.2,
    };
    expect(formatLaneRate(completedLaneWithRate)).toBe("Done (95 docs/s)");

    const completedLaneWithoutRate: IndexLiveQueueLane = {
      lane: "keywordData",
      label: "Keyword Data",
      queued: 500,
      processed: 500,
      indexed: 0,
      rate: null,
    };
    expect(formatLaneRate(completedLaneWithoutRate)).toBe("Done");

    const queuedLane: IndexLiveQueueLane = {
      lane: "mediaSpeech",
      label: "Media Speech",
      queued: 50,
      processed: 0,
      indexed: 0,
      rate: null,
    };
    expect(formatLaneRate(queuedLane)).toBe("Queued");

    const emptyLane: IndexLiveQueueLane = {
      lane: "empty",
      label: "Empty",
      queued: 0,
      processed: 0,
      indexed: 0,
    };
    expect(formatLaneRate(emptyLane)).toBeNull();
  });

  it("incorporates phase throughput into pipeline steps", () => {
    const discoveringLive: IndexLiveStatus = {
      trigger: "onDemand",
      phase: "discovering",
      stage: "files",
      scanned: 82979,
      indexed: 0,
      skipped: 0,
      errors: 0,
      rate: 280,
      elapsedMs: 295000,
      current: null,
    };
    const stepsDiscovering = resolveIndexPipelineSteps(discoveringLive);
    expect(stepsDiscovering[0].metric).toBe("82,979 scanned · 280 files/s");

    const extractingLive: IndexLiveStatus = {
      trigger: "onDemand",
      phase: "extracting",
      stage: "files",
      scanned: 82979,
      indexed: 212,
      skipped: 0,
      errors: 0,
      rate: 54.3,
      elapsedMs: 310000,
      current: null,
      queues: [
        { lane: "fastText", label: "Fast Text", queued: 1000, processed: 1000, indexed: 50, rate: 90 },
        { lane: "imageOCR", label: "Image OCR", queued: 2000, processed: 500, indexed: 20, rate: 2.5 },
      ],
    };
    const stepsExtracting = resolveIndexPipelineSteps(extractingLive);
    expect(stepsExtracting[1].metric).toBe("1500 / 3000 · 54 docs/s");
  });

  it("renders per-lane rate inside IndexBentoHeader queue lane cards", () => {
    const queueLanes: IndexLiveQueueLane[] = [
      {
        lane: "fastText",
        label: "Fast Text",
        queued: 8000,
        processed: 8000,
        indexed: 100,
        rate: 88,
      },
      {
        lane: "imageOCR",
        label: "Image & PDF OCR",
        queued: 12000,
        processed: 300,
        indexed: 20,
        rate: 2.4,
      },
    ];

    render(
      <IndexBentoHeader
        action={null}
        actionBusy={false}
        cancelBusy={false}
        cancelling={false}
        indexingEnabled={true}
        progressActive={true}
        showLiveBlock={true}
        liveHeaderText="Manual Run: Reading... · 82,979 scanned · 212 indexed · 2.4 docs/s · 320s"
        liveCurrent="photos/camera.jpg"
        pipelineSteps={[]}
        queueLanes={queueLanes}
        liveSources={[]}
        reclaimSummary={null}
        status={null}
        onRun={() => {}}
        onCancel={() => {}}
        onOpenPrune={() => {}}
        onReclaim={() => {}}
        onOpenRebuild={() => {}}
      />
    );

    const fastTextCounts = screen.getByTestId("index-queue-counts-fastText");
    expect(fastTextCounts.textContent).toContain("8000 / 8000 · Done (88 docs/s)");

    const imageCounts = screen.getByTestId("index-queue-counts-imageOCR");
    expect(imageCounts.textContent).toContain("300 / 12,000 · 2.4 docs/s");
  });
});
