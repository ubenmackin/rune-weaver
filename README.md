# Rune Weaver

### Your personal, private AI companion for macOS.

Rune Weaver is an intelligent, local-first assistant that runs directly on your Mac. It chats, remembers facts, tracks long-term personal goals, automates your desktop, and safely coordinates tools to help you get things done. 

Your data stays on your machine by default—private, auditable, and completely under your control.

---

## What Makes Rune Weaver Different

### Private by Default, Local-First
Your thoughts and data belong to you. Rune Weaver runs locally on Apple Silicon using native frameworks. Chat history, indexed documents, and memories live in private local databases on your Mac. Cloud LLMs are an opt-in fallback, never a requirement.

### Lifelong Memory & Instant Recall
Never repeat yourself. Rune Weaver automatically remembers preferences, projects, and context across conversations. With an opt-in local index, it can instantly search across your documents, email, and Apple Messages to answer questions about your digital life—without sending your files to third-party servers.

### Autonomous Long-Horizon Goals
Rune Weaver isn't just a chatbot that answers one prompt and forgets. It holds long-term goals, breaks them down into structured steps, schedules progress, and steadily works toward them in the background while you focus on other things.

### Human in the Loop (Zero Surprise Actions)
The agent reads freely but acts with caution. Any action that alters state—sending an email, texting a contact, running a script, or writing a file—requires your explicit approval. File edits feature interactive, side-by-side diff previews in the Staged Changes drawer before anything touches your real filesystem.

### Swappable Intelligence
Run state-of-the-art open models (Gemma, Llama, Qwen) completely offline and free on your Mac via Apple's MLX framework or llama.cpp. Need massive reasoning power? Seamlessly connect cloud endpoints like OpenRouter with a single setting.

### Private Built-in Web Search
Search the web without tracking. Rune Weaver bundles its own local SearXNG search engine running in a private Apple container. Search queries stay entirely on your local machine—no ad trackers, no profiling, and no API keys required.

### Desktop Perception & Automation
With your permission, Rune Weaver can see your screen, analyze visual layouts, and automate repetitive tasks across apps. It comes pre-configured with sensitive-app protections that automatically refuse to interact with password managers, terminal windows, or system settings.

### Multi-Agent Swarms
When you have a large research task, Rune Weaver can fan out parallel background worker agents to explore multiple angles simultaneously and synthesize the results back to you.

### Always-On Health, Quietly Green
Rune Weaver keeps a private checkup running on itself — its memory ledger, its security policy, and its built-in safeguards. When everything passes, the System Pulse simply reads "Operational" and stays out of your way. When something needs attention, the dashboard shows a short, plain-language reason and a single to-do in your Approvals inbox — never a flood of alerts. It only returns to green after a fresh, passing check, never merely because time passed.

### A Brake for Odd Behavior
If your assistant ever starts acting unlike itself — an unusual burst of activity, repeated refused requests, or work in the middle of the night — Rune Weaver gently applies the brakes. Running work pauses, and you receive one plain card in your Approvals inbox explaining what it noticed (counts only — never your messages, files, or prompts). You then choose: resume, or keep things paused. It never approves anything on its own, never acts without you, and never resets itself on a timer.

### Instant Answers to Repeated Questions
Ask the same thing twice, and the second answer returns instantly — Rune Weaver keeps answers it produced entirely on its own right on your Mac. Anything that touched a tool, needed your approval, or sent a message is never replayed from memory, and stored answers are cleared the moment your notes, goals, or settings change.

### Send Later, Exactly as Approved
When the assistant suggests sending something later, your approval books it. Rune Weaver stores the exact approved message, recipient, and time — then sends precisely those words when the moment arrives, checking again that everything is still safe. You can review what is waiting and cancel in Schedules or the Needs Your Action queue. Change your mind? Cancelling or editing needs a fresh approval, so what goes out is always exactly what you agreed to.

---

## The Experience

- **Menu Bar Companion**: Lives quietly in your Mac's menu bar. One click opens the dashboard, displays system health, or lets you adjust privacy settings.
- **Web Dashboard**: A responsive, clean dashboard designed for macOS Safari, iPad, or mobile. Features:
  - **System Pulse**: One glance tells you everything is healthy. Green reads "Operational" and stays quiet; yellow reads "Degraded" and opens a short Details list; red reads "Needs action" with **Open inbox**, **Re-check**, and **Open Policy** buttons — and only turns green again after a fresh passing check.
  - **Chat**: Fluid streaming conversation with tool-call transparency — and repeated questions answered instantly. Approval requests decide inline via a split Allow / Deny banner: the Allow chevron lists durations and Deny always mints a durable deny, both duration-only with no scope.
  - **Approvals Inbox**: Pending | History segmented view for approvals and file diffs, including the plain-language brake card whenever the behavior brake pauses work for your review. Every pending request renders as its own decidable card, grouped by the chat session that filed it with a target line naming the resolved target, so a parked turn always reads beside the conversation it came from. Pending cards carry split Allow / Deny buttons with the duration picker plus This target / All targets / Custom scope radios — the only scope controls in the product — while the History pane audits past decisions with a Clear-logs button.
  - **Needs Your Action**: The Dashboard landing card mirrors pending approvals with split Allow / Deny buttons: the Allow chevron lists durations and Deny always mints a durable deny, both duration-only with no scope. Scope choices live only in the Inbox.
  - **Standing Rules**: Standing rules are managed in Settings → Access, whose five sections (Rules, Bash & Shell, Network, Credentials, and Files) gather every persistent "what the agent may do" decision in one pane.
  - **Work & Goals**: Track active projects, milestones, and scheduled background tasks — including approved messages waiting for their send time.
  - **Memory Explorer**: Search and manage what your assistant remembers about you.

---

## Quick Start

### Run the App (Recommended)

Everything you need is bundled inside the app download. You do **not** need Xcode, Swift, Python, Node, or terminal tools.

1. **Download**: Grab the latest `RuneWeaver.dmg` from GitHub releases.
2. **Install**: Open the DMG and drag **Rune Weaver** into your `/Applications` folder.
3. **Launch**: Open Rune Weaver from Applications or Spotlight. A rune icon will appear in your menu bar.
4. **Permissions**: On first launch, the Permissions setup window guides you through enabling Accessibility, Screen Recording (for desktop perception), and Full Disk Access (for Apple Messages indexing).
5. **Start Chatting**: Click the menu bar icon, choose **Open Web Dashboard**, and start exploring!

---

## Command Surface

The terminal stays intentionally small: `rune-weaver serve` starts the engine, and the web dashboard it serves is the everyday surface for chat, goals, memory, and approvals.

- `rune-weaver serve` — Start the engine service (REST, WebSocket, and the web dashboard). Loopback by default; LAN binds require owner auth.
- `rune-weaver status` — Show system status: LLM providers, search, memory stats, and active tools.
- `rune-weaver auth` — Manage the single-owner bearer token that guards non-loopback access: generate, rotate, or check it (only a fingerprint prefix is ever shown).
- `rune-weaver policy verify` — Formally verify the declarative security policy: credential confinement, rule-shadow prevention, and local-exemption safety.

---

## Technical Documentation & Contributor Links

For power users, contributors, and developers who want to look under the hood or build from source:

- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Comprehensive architecture overview, subsystem breakdown, actor lifecycle, and security invariants.
- **[CONFIG.md](CONFIG.md)** — Complete configuration reference for `~/.runeweaver/config.toml` and declarative security policies in `policy.toml`.
- **[PLUGIN_DEV.md](PLUGIN_DEV.md)** — Developer guide for creating custom Swift and Python capability plugins ("Runes").
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — Building from source, prerequisite dependencies, running test suites, and release procedures.
- **[Web/README.md](Web/README.md)** — Dashboard frontend development guide (React, TypeScript, Vite, Tailwind CSS).

---

## License

Rune Weaver is open-source software licensed under the [MIT License](LICENSE).
