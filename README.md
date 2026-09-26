# Rune Weaver

A personal AI assistant that runs on your Mac. It chats, remembers facts, runs scheduled jobs, and calls local tools. Your data stays on your machine by default.

## What

Rune Weaver is a local-first harness. A Swift engine does the thinking and tool calls. A Mac app gives you the primary entry point with the engine and dashboard bundled in. A web dashboard gives you chat, approvals, memory, runs, schedules, and settings. A terminal gives you the same engine when you prefer the command line.

Runes are small plugins that add skills. The core stays small and each rune stays separate, so you can add email, browser, files, or your own tool without changing the core.

## Why use

- Local by default. Chat history lives in local SQLite. Memory lives in a local store. Cloud models are opt-in fallback, not required.
- Private by default. Keys and passwords live in the Keychain or environment, never in config files or logs. Writes that change state ask first.
- Plain to run. Download the app and launch it. One menu bar icon starts the engine and opens the dashboard.
- Swappable models. Use a local model, a local server, or a cloud endpoint. Tools and memory work the same either way.
- Search built in. SearXNG runs locally in an Apple Container machine for private web search. No Docker needed.

## Quick Start

### Run the app

This is the primary path for most users. You do not need Xcode, Swift, Node, or Vite. Everything is already built into the download.

1. Download the latest DMG from GitHub releases.
2. Open the DMG, drag Rune Weaver to Applications, then launch it.
3. The app lives in the menu bar and starts the engine for you.
4. Choose Open Web Dashboard from the menu bar icon, then open Settings.
5. Set your default provider and model, then Save. Open the Web pane and press Start to pull and run SearXNG.
6. Use the Chat tab in the same dashboard page. Approve or deny writes in the approvals inbox as they come in.

Config is stored at `~/.runeweaver/config.toml`. Edit it from the Settings page. You do not need to hand edit the file.

### Build from source

This path is for contributors who want to change the code. You need macOS with Xcode and Swift, plus Node for the dashboard build and the tools in the table below.

```bash
# 1. Clone and build (engine plus dashboard)
git clone https://github.com/<you>/rune-weaver.git
cd rune-weaver
make build

# 2. Start the engine service (API plus dashboard on loopback)
make run ARGS="serve"

# 3. Open the Settings web page first and fill in providers
# Open http://127.0.0.1:8082 in a browser, go to Settings.
# Set your default provider and model, then Save.
# Open the Web pane and press Start to pull and run SearXNG.
# Config is stored at ~/.runeweaver/config.toml but edit it from the page.

# 4. Chat
# Use the Chat tab in the same web page, or run in the terminal:
make run ARGS="chat"

# Check health any time (providers, memory, tools, search):
make run ARGS="status"
```

Search status shows in two places. The Profile menu in the top nav has a SearXNG row with a green or red dot, the URL as a tooltip, and Start and Stop buttons. The Settings Web pane has the same Start and Stop buttons plus health text. The `status` command prints `reachable` or `unreachable` for the configured URL.

Only three make commands cover daily dev use:

```bash
make build              # build engine plus dashboard bundle
make test               # run Swift plus dashboard tests
make run ARGS="<args>"  # run the engine, for example chat, serve, status
```

See CONTRIBUTING.md for the full contributor flow.

## Dependencies

App users can skip the build row. Install only what matches the features you use, in this order. The steps below assume you have Homebrew installed. If you do not use Homebrew, follow the official docs linked per tool.

| Order | Dependency | Needed for | Notes |
|-------|------------|------------|-------|
| 1 | Apple Container CLI (`container`) | SearXNG search and sandbox detonation | No Docker needed. The CLI ships the isolation used by search and untrusted files. |
| 1a | Container system service (`container system start` plus `container list` verify) | SearXNG search and sandbox detonation | Start once with `container system start`, verify with `container list`. The engine and `scripts/searxng-up.sh` heal it automatically when down (XPC/system-service). |
| 2 | SearXNG image | Local web search | Pulled automatically on first Start from the Settings Web pane or the Profile menu. First pull is about 150 MB, later starts reuse it. |
| 3 | Python 3 plus Playwright plus Chromium | Browser automation tools | Needed only if you use browser tools. See install steps below. |
| 4 | Whisper (optional) | Voice input | Needed only if you use speech to text. Skip it for text chat. See install steps below. |
| 5 | Xcode plus Swift plus Node plus Vite (contributors only) | Building from source with `make build` | Not needed for the DMG app. The app bundles the built dashboard, so no Node server runs in normal use. |

### Python 3

The engine shells out to `python3` for email and browser bridges. You need Python 3.10 or later.

```bash
brew install python
python3 --version
```

If you do not use Homebrew, get an installer from the official docs: https://www.python.org/downloads/

### Playwright plus Chromium

Needed only if you use the browser tools. Install the Python package, then download Chromium:

```bash
python3 -m pip install playwright
python3 -m playwright install chromium
```

The short form `pip install playwright` plus `playwright install chromium` works too when your `pip` points at the same Python. If you do not use Homebrew Python, follow the official docs: https://playwright.dev/python/docs/intro

### Whisper

Needed only if you use speech to text. Pick one of the two options.

Option A is the compiled binary, which is the smaller install:

```bash
brew install whisper-cpp
which whisper-cpp
```

The engine also looks for `whisper-cli`, `whisper`, and `main` on PATH, so any of those names works.

Option B is the Python package:

```bash
python3 -m pip install openai-whisper
```

If you do not use Homebrew, follow the official docs for either build: https://github.com/ggerganov/whisper.cpp or https://github.com/openai/whisper

### Xcode, Swift, Node

Contributors only. The DMG app does not need any of this.

- Install Xcode from the App Store, then check `swift --version` for Swift 6.
- Install Node 20 or later with `brew install node`, then check `node --version`.
- Vite ships with the repo `Web` dependencies, so `make build` handles it once Node is present. If you do not use Homebrew, get Node from: https://nodejs.org/

## Indexing

Rune Weaver can build a local index of your files, mail, and Apple Messages so recall can search them by keyword and, when embeddings are on, by meaning. Indexing is opt-in: a fresh install never reads a mailbox or walks your home directory until you enable it. Indexed text and any derived vectors live in `~/.runeweaver/index.db`; credentials resolve from the Keychain at run time and are never written to the index.

Turn it on in the dashboard, or in `~/.runeweaver/config.toml`:

```toml
[index]
enabled = true
files = true      # local files; on once the indexer is enabled
mail = false      # opt in to index a configured [email.accounts] mailbox
messages = false  # opt in to index Apple Messages (needs Full Disk Access)
```

The remaining `[index]` keys bound what a run touches:

- `roots` and `exclude` define the file walk. Excluded directories are pruned without being walked, and symlinks and Finder aliases are detected and skipped without traversal. `exclude` ships with `.build`, `*.app`, `*.log`, `*.tmp`, `.DS_Store`, `.bun`, `.cocoapods`, `.npm`, `.npm-packages`, `.nvm`, `.cache`, `.gradle`, `.swiftpm`, `.swiftly`, `.gem`, `.rvm`, `.cpan`, `.local`, `.docker`, `.ollama`, `.terraform.d`, `.ipynb_checkpoints`, `.ipython`, `.jupyter`, `.matplotlib`, `.vscode`, `.vscode-insiders`, `.zsh_sessions`, `gopath`, `go`, and `nltk_data` — ordinary editable globs that seed the Index Policy "Exclude patterns" editor. Matching is case-insensitive, so an uppercase `.LOG` is covered, and bare directory names match at any depth. A stored `exclude` array keeps its existing contents, so an existing install adds the new globs once in the editor rather than having `config.toml` rewritten underneath it.
- `max_file_mb` (default `20`) caps the size of any one file the indexer reads.
- `mail_vector_window` (default `2y`) sets how far back mail is vectorized; older mail is still indexed and searchable by keyword.
- `icloud_evicted` (default `skip`) leaves iCloud files whose bytes are evicted out of the index; set `download` to fetch them first.
- `describe_images_with_llm` (default `false`) describes images and scanned PDFs with the configured model.
- `nightly_budget` (default `0`, unlimited) caps the items processed per run.
- `max_vector_chunks_per_document` (default `128`) caps how many chunks per document carry vectors; extra chunks stay keyword-searchable.
- `effort` (default `balanced`) sets how much CPU a run uses: `light` resolves to 1 worker, `balanced` to half the cores up to 4 workers, `performance` to all but one core, and `custom` to the explicit `workers` count. The count resolves once at run start; thermal pressure can back a run off below it.
- `workers` (default `0`, derive from `effort`) carries the explicit worker count used only when `effort` is `custom` (1-64, clamped to the core count at run start).
- `thermal_backoff` (default `true`) backs a run off when the system reports thermal pressure.
- `pause_on_battery` (default `false`) pauses a run while on battery power and resumes it on AC power.
- `mailbox_deny` (default `["Trash", "Junk", "Spam", "Deleted*"]`) skips Trash-class mailboxes without dialing. Matching is case-insensitive against the full mailbox name plus every slash-separated hierarchy segment, so `Trash` covers `Trash` and `INBOX/Trash` while `Deleted*` covers `Deleted Messages`. Edit it in the Index Policy "Denied mailboxes" editor; clearing the list opts every mailbox back in.
- `db_path` sets where the index database lives.

In addition to your `exclude` patterns, the walk always skips media libraries (`Music`, `Pictures`, `Movies`), `Library`, `.Trash`, the app's own `.runeweaver` state, and VCS, dependency, build, and cache trees (`Music`, `Pictures`, `Movies`, `Library`, `.Trash`, `.runeweaver`, `.git`, `node_modules`, `DerivedData`, `__pycache__`, `.venv`). These built-ins cannot be removed by configuration; they appear in the Index Policy scope copy rather than duplicated in the editable `exclude` list. The shipped `exclude` defaults above cover machine-output files (`*.log`, `*.tmp`, `.DS_Store`) and package-manager, build, model, and agent caches holding machine output rather than documents. They churn constantly and carry almost no recall signal — a measured backfill had 2,120 `.log` files accounting for 67% of chunks, 69% of text, and 42% of vectors — so they stay out by default but remain ordinary globs you can read, change, or opt back in.

Chunk text is stored once: the `indexed_chunks` table holds the text and the FTS5 index is contentless, so keyword search adds index overhead without a second copy of the text. A typical home index lands between about 200 MB and 1 GB, depending on how much text you index and how much of it carries vectors. Text is chunked at roughly 512 tokens with 64 tokens of overlap, so the store scales with the volume of text it holds; each vectorized chunk adds one embedding on top of its stored text, bounded per document by `max_vector_chunks_per_document`.

### What gets indexed

| Format | Text extraction | Vectors | Notes |
|--------|-----------------|---------|-------|
| PDF with a text layer | Full body | Yes | Native text layer. |
| Scanned or image-only PDF | None (metadata only) | No | Eligible for an LLM description when `describe_images_with_llm` is on. |
| Encrypted or unreadable PDF | None | No | Counted as an error; not indexed. |
| DOCX | Full body | Yes | Paragraph text from the document body. |
| XLSX | Full body | Yes | Worksheet rows with shared strings resolved. |
| PPTX | Full body | Yes | Text from each slide. |
| TXT, MD, CSV, JSON | Full body | Yes | Decoded as text. |
| HTML | Body text | Yes | Tags, scripts, and styles stripped. |
| iWork (Pages, Numbers, Keynote) | Best-effort (partial) | No | Modern text is a binary payload, so body text is often missing; only package XML text is recovered. |
| Email bodies | Subject plus body | Yes, inside `mail_vector_window` | Read over IMAP with `BODY.PEEK`, so mail is never marked read. |
| Email attachments | Attachment text | Yes, inside `mail_vector_window` | Fetched read-only, staged in confined temp, extracted, then deleted; oversize attachments are skipped. |
| Apple Messages | Message text, tapbacks, and attachment text | No (keyword only) | Reads an isolated snapshot of `chat.db`; needs Full Disk Access. |
| Images, audio, video | None | No | Not indexed; images can be described when `describe_images_with_llm` is on. |
| Machine output (`*.log`, `*.tmp`, `.DS_Store`) and tool caches | None by default | No | Skipped by the shipped `exclude` defaults; editable, can be opted back in. |
| Evicted iCloud files | None by default | No | `icloud_evicted = "skip"` (default) leaves them out; `"download"` fetches them first. |

Files are vectorized only when extraction is clean and the document is under 2 MB. Partial or oversized documents stay keyword-only, and mail older than the vector window can gain vectors later through backfill. Long documents vectorize at most `max_vector_chunks_per_document` chunks (default `128`, first chunks in document order); the remaining chunks stay keyword-searchable, so a capped document is still fully findable by keyword.

### Run effort, thermal backoff, and battery

`effort` sets the CPU budget for a run: `light` resolves to 1 worker, `balanced` to half the cores up to 4 workers, `performance` to all but one core, and `custom` to the explicit `workers` count (1-64, clamped to the core count). The count resolves once at run start and stays fixed for that run; an on-demand run uses the same mapping as the nightly run. When macOS reports thermal pressure, a run backs off below its resolved workers (pausing embedding batches first) and resumes when pressure clears, so a long run never fights the cooling system. When `pause_on_battery` is on, a run pauses on battery power and resumes on AC power; a paused run keeps committed batches and continues where it left off. The dashboard Index Policy form edits the preset, the custom worker count, the thermal and battery toggles, and the per-document vector cap, and `GET /index/status` reports the resolved preset plus worker and core counts so the status line renders without a second fetch.

### Privacy and permissions

Describing images with the LLM sends document image content to the configured provider. When that provider is remote, the content leaves your machine. The description is stored as an AI-generated chunk marked with its origin and model, and the prompt instructs the model not to reproduce secrets. A text-only provider is never sent image content.

Apple Messages indexing reads `~/Library/Messages/chat.db`, which macOS protects with TCC. There is no prompt API for Full Disk Access, so access is detected at run time: turning Messages on and saving succeeds, and the first Rebuild / Run Now (or nightly run) reports a permission error when access is missing. The dashboard surfaces that error with guided steps before the next run.

- When you run the app, grant Full Disk Access to RuneWeaver.app under System Settings > Privacy & Security > Full Disk Access: click +, add RuneWeaver.app, toggle it ON, authenticate, then restart the app.
- When you run `rune-weaver serve` from a terminal, macOS attributes the read to your terminal emulator, so grant Full Disk Access to that emulator (for example Terminal.app or iTerm2) in the same pane instead.

The engine never bypasses TCC. Without the grant, a Messages run reports a permission error instead of crashing. You can open the pane directly with `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.

### Managing the index

The Memory → Index Status pane in the dashboard starts a run, cancels a run in flight, prunes entries older than a cutoff, resets the index, and reclaims file space. Prune deletes older indexed documents and their chunks; reset clears the whole index; Reclaim keeps every document and compacts the database file so freed pages return to the OS. The pane reports both the logical size (chunk-text bytes) and the on-disk file size of `index.db`: the two differ because freed pages, the FTS index, and vectors all live in the file until a prune, reset, or Reclaim compacts it. Turning `enabled` back off, or deleting `~/.runeweaver/index.db`, leaves recall with episodic and semantic memory only.

Narrowing policy never deletes immediately. Files that fall out of policy — a root removed, a new `exclude` pattern, or the files source toggled off — are retired on the next complete, uncancelled, unbudgeted run. Mail retires the same way when a mailbox joins `mailbox_deny`: denied mailboxes skip silently with skipped counts and their stored documents plus chunks retire on the next complete run only, with checkpoints dropped so re-allowing a mailbox re-indexes it from scratch while `Archive` and every other mailbox indexes exactly as before. Messages rows are never retired by policy narrowing, and `mail_vector_window` bounds vectorization rather than retention. A cancelled run or a `nightly_budget`-capped run never retires anything, so a partial pass cannot delete documents it never examined.

Unchanged files take a fast path: a file whose size and modification time match the stored row is skipped without re-hashing. The tradeoff is a 1-second granularity window — a same-size edit made within the same 1-second modification-time window is not detected until the next size or mtime change.

### Reading the status

The Memory → Index Status pane shows a Last run strip, a Last errors list, and content charts. Here is what each number means.

Every run is saved to run history, so the Last run strip survives a dashboard reload or an engine restart. A fresh install with no runs yet shows an honest empty state, and the very first run in flight names itself instead of looking like empty history.

Last errors mixes two things: a whole-run failure (for example a source that could not be read, such as Messages without Full Disk Access) plus the most recent per-file warnings (for example an unreadable PDF). The file list is capped to the newest entries, longest lines truncated with an expander, so it stays readable on a large home directory.

A Last run of `ok` means the run finished without being cancelled or interrupted. Individual files can still have errors inside an `ok` run — those per-file errors still add to the error count and still appear under Last errors. Check the error count there rather than reading `ok` as "nothing was skipped."

Chart percents are shares of the index total across the rows on screen. A Files row at 60% means 60% of the indexed documents are files; the remaining 40% is mail plus messages. The bars scale the same way, so no row is stretched — the longest fills only its share and tiny buckets read as slivers.

Mail fills in from newest to oldest across runs. Each run reads the next window downward by mail number (UID) and records how far it got per mailbox, so a large mailbox backfills over several runs. When a window cannot be fully fetched, the recorded mark (watermark) stays held below the gap instead of jumping over it, so the gap is retried rather than skipped forever.

Messages catches up fully on every run. Each run reads everything newer than the last recorded message in bounded batches until it reaches the newest message, then records the new mark for next time.

## Releasing

The version lives in one place: the `VERSION` file at the repo root.

```bash
# 1. Edit VERSION to the new X.Y.Z
echo "0.2.0" > VERSION

# 2. Stamp the Swift constant and sync the dashboard manifest
make version

# 3. Build and test
make build
make test

# 4. Tag the release
git add VERSION Web/package.json Web/package-lock.json
git commit -m "Release 0.2.0"
git tag v0.2.0
git push && git push --tags
```

`make version` regenerates `Sources/RuneWeaverCore/GeneratedVersion.swift` from `VERSION` and syncs `Web/package.json` via `npm version`. The engine, CLI, and `/health` read the stamped constant, and the dashboard reads the version at runtime from `/health.version`.

The generated file is gitignored: fresh clones bootstrap it via `make version` (already a prereq of `make build`, `make test`, and `make run`), so no hand edits are needed. A previously tracked copy may still exist in the working tree until the maintainer untracks it with `git rm --cached Sources/RuneWeaverCore/GeneratedVersion.swift`; do not edit it by hand either way.

## Links

- [ARCHITECTURE.md](ARCHITECTURE.md) for the architecture overview, project layout, security model, and design notes.
- [CONTRIBUTING.md](CONTRIBUTING.md) for how to contribute.
- [CONFIG.md](CONFIG.md) for the full config reference. The Settings page writes the same file, so prefer the page over hand edits.
- [PLUGIN_DEV.md](PLUGIN_DEV.md) for how to write a rune.
- [Web/README.md](Web/README.md) for dashboard development.

## License

MIT License. See `LICENSE` for the full text.
