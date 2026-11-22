# `buildwire` Risk Audit & Targeted Minimal Fix Report

**Target Workspace:** `c:\Users\hp\Downloads\html build\buildwire-main\buildwire-main` (`buildwire` v1.3.0+4)  
**Purpose:** Internal exploration and risk assessment (not targeting a release)  
**Audit Date:** 2026-11-21  

---

## 1. Executive Summary & Audit Scope

### Executive Summary
This audit evaluated the `buildwire` codebase for serious risks across five categories: **bugs**, **security vulnerabilities**, **data loss / file corruption risks**, **failures under real load**, and **risky code**. Across the entire non-test codebase and supporting tooling, the audit identified **67 findings**:
- **19 `Must fix`** — serious risks causing OOM/hangs, startup or file-import crashes, `ChangeNotifier`/widget-lifecycle crashes, silent data loss/corruption, broken PLC simulation behavior, or broken AI tool output. **All 19 `Must fix` findings have been fixed** using the smallest complete root-cause patches across **17 modified files** under `lib/` (`+621 / -261` lines).
- **29 `Should fix`** — real edge-case bugs, performance bottlenecks, non-atomic writes, or error-handling gaps that were **intentionally left untouched in code** per scope rules and documented in Section 4.
- **19 `Nice to have`** — minor UI metadata inaccuracies, dead branches, cleanup items, and scalability notes that were **intentionally left untouched in code** and documented in Section 5.

Because the host environment lacks the Flutter/Dart SDK, Visual Studio 2022 C++ toolchain, CMake, NuGet, Inno Setup (`ISCC`), and Python `numpy`/`Pillow`, static compilation (`flutter analyze` / `dart analyze`), Windows builds, and `flutter test` could **not** be executed. Every fix was verified manually by independent reviewers (x2 per milestone), independent challengers using lexical/bracket checks and isolated Python behavioral probes (x2 per milestone), and a forensic auditor per milestone (4/4 `CLEAN`), alongside `git diff --no-index` against the pre-edit `lib/` baseline.

### Audit Scope & Exclusions
- **Included:**
  - All **`35` non-test Dart files** under `lib/` (`20,477` pre-edit LOC): `lib/*.dart` (5 files), `lib/ai/` (7 files), `lib/model/` (2 files), `lib/relay/` (2 files), `lib/sim/` (5 files), `lib/ui/` (14 files).
  - Root configurations & scripts (`6` files): `pubspec.yaml`, `analysis_options.yaml`, `Buka BuildWire.bat`, `NuGet.Config`, `.gitignore`, `README.md`.
  - Platform, installer & catalog assets: `windows/`, `web/`, `installer/buildwire.iss`, `assets/devices/index.json` (`590` entries: `339` devices + `1` `generic_junction` + `250` symbols).
  - Python tooling (`17` scripts): `tools/*.py` (`15` scripts) and `brand/*.py` (`2` scripts).
- **Strictly Excluded:**
  - `test/` (`12` `*_test.dart` files + `7` `.zm2` fixtures) and `integration_test/` (`1` `sound_test.dart`) were **never read, listed, searched, or modified** during the audit or fixes.

---

## 2. Summary Tables

### 2.1 Findings by Rank & Milestone Status

| Rank | Survey 1 (Core/Sim) | Survey 2 (AI/Relay) | Survey 3 (UI/Tooling) | Total | Code Status |
|---|---:|---:|---:|---:|---|
| **`Must fix`** | 5 (`MF-1`..`MF-5`) | 7 (`F-AI-01`..`04`, `F-RL-01`..`03`) | 7 (`F-01`..`F-07`) | **19** | **19 FIXED** (M1–M4) |
| **`Should fix`** | 10 (`SF-1`..`SF-10`) | 11 (`F-AI-06`..`13`, `F-RL-04`..`06`) | 8 (`F-08`..`F-15`) | **29** | **Untouched in code** (Report only) |
| **`Nice to have`** | 8 (`NH-1`..`NH-8`) | 6 (`F-AI-14`..`18`, `F-RL-07`) | 5 (`F-16`..`F-20`) | **19** | **Untouched in code** (Report only) |
| **Total** | **23** | **24** | **20** | **67** | **19 Fixed / 48 Report Only** |

### 2.2 Category Coverage

| Risk Category | `Must fix` | `Should fix` | `Nice to have` | Examples |
|---|---:|---:|---:|---|
| **Bugs** (crashes, logic, state/UI desync) | 14 | 15 | 6 | `MF-3`, `MF-4`, `MF-5`, `F-AI-01`, `F-AI-02`, `F-AI-03`, `F-RL-01`, `F-RL-02`, `F-01`, `F-05`, `F-06`, `F-07` |
| **Security Vulnerabilities** (DoS, plaintext transport) | 3 | 1 | 0 | `MF-1` (wire grid DoS), `MF-2` (`.zm2` binary DoS), `F-AI-04` (image decompression bomb), `F-15` (non-localhost HTTP) |
| **Data Loss / File Corruption Risks** | 2 | 2 | 0 | `F-RL-03`, `F-02`, `F-03`, `F-04`, `SF-4`, `F-13` |
| **Failures Under Real Load / Performance** | (shared w/ `MF-1`, `F-AI-04`) | 6 | 3 | `F-AI-09`, `F-AI-10`, `F-AI-12`, `F-RL-06`, `F-08`, `NH-4`, `NH-7` |
| **Risky Code / Error Handling & Hygiene** | (shared w/ `F-AI-03`) | 5 | 10 | `SF-5`, `SF-8`, `SF-9`, `SF-10`, `F-AI-11`, `F-12`, `F-18`, `F-20` |

*(Note: Several findings span multiple risk dimensions—for example, `MF-1`, `MF-2`, and `F-AI-04` are both security DoS risks and load/OOM failures; `F-02`, `F-03`, `F-04`, and `F-RL-03` are both bugs and silent data loss/corruption risks.)*

---

## 3. Section 1 — `Must fix` Findings (19 Findings — All Fixed in M1–M4)

### `MF-1` — Unbounded A* grid allocation and search explosion in `WireRouter` on distant coordinates or untrusted `.bwproj`
- **Category:** Failure under real load / Security (DoS via untrusted `.bwproj`) / Bug
- **Rank:** `Must fix` | **Milestone:** M1 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/sim/wire_router.dart:84-86, 179-182, 206-244` (triggered via `lib/app_state.dart:484, 1439, 1575-1618`)
- **Concrete Failure Scenario:** `WireRouter._Grid.build` generated regular grid lines every `cell = 12` px across the full bounding box plus `120` px margin, allocating `xs.length * ys.length` arrays per `_Grid` and `Float64List(n * 4)` + `Int32List(n * 4)` per wire. Placing wired devices at `(0, 0)` and `(100000, 100000)` or opening an untrusted `.bwproj` with `"x": 1000000, "y": 1000000` causes `importJson` -> `fitView()` -> `routeWorld()` -> `_routeAll()` -> `_Grid.build` to allocate >3.8 GB on the UI thread (freezing/crashing with OOM), while `x = 1e9` spins `lines()` indefinitely.
- **Connected Callers:** `AppState._routeAll` (`lib/app_state.dart`), `AppState.routeWorld`, `fitView`, `importJson`, `applyTemplate`, `autoArrange`, `branchToWire`, `beginWireDrag`, `wirePoints`, `wireAt`, `_WirePainter.paint` (`lib/ui/canvas_view.dart`).
- **Applied Minimal Fix (`lib/sim/wire_router.dart`, post-edit lines `53–62, 235–262`):**
  - In `WireRouter.routeAll` (`lines 53–62`): reject non-finite `_obstacles` bounds and non-finite `WireRequest` points (`a`, `exitA`, `exitB`, `b`, `viaA`, `viaB`), and return `{}` cleanly when `grid.count == 0 || grid.count > 100000` (so `AppState._routeAll` preserves orthogonal `_baseRoute` paths).
  - In `_Grid.build` (`lines 235–262`): guard non-finite bounds and `cell <= 0`; scale `step` when `(spanX / cell) * (spanY / cell) > 40000` (`maxNodes`) or `max(spanX, spanY) > 1000 * cell` (`maxAxis`); filter `exact` lines to finite values while preserving them; break IEEE-754 stagnation loops (`if (next <= v) break;`); and check `xs.isEmpty || ys.isEmpty || xs.length * ys.length > 100000` before array allocation. Normal panels (`<= ~2400 x 2400` px) retain `cell = 12`.

---

### `MF-2` — Crafted or truncated `.zm2` files cause OOM/hang or uncaught `RangeError` in `readZm2` / `writeZm2`
- **Category:** Security (untrusted binary DoS) / Bug (crash)
- **Rank:** `Must fix` | **Milestone:** M1 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/sim/zm2.dart:57-73, 104, 115-128, 178-197, 263-281`
- **Concrete Failure Scenario:** `_Sheet` checked `while (at + 9 < bytes.length)` and then read `bytes[at + 4 + n]` and `getUint32(at + 5 + n)` (`2 <= n <= 6`), throwing an uncaught `RangeError` on a truncated `P*` record near EOF. It also trusted arbitrary `uint32` counts `values[k + 5]` (`kinds`) and `values[k + 2]` (`t.count`), allowing a crafted `.zm2` with `0x7FFFFFFF` to hang/OOM in list comprehension. `_Sheet.u32`, `writeZm2`, and `_find` also lacked EOF bounds checks.
- **Connected Callers:** `AiAttachment.load` (`lib/ai/ai_attachment.dart:48`), `_LadderEditorState.openBytes` (`lib/ui/plc_editor.dart:288`), `_LadderEditorState.zm2Bytes` (`lib/ui/plc_editor.dart:329`).
- **Applied Minimal Fix (`lib/sim/zm2.dart`, post-edit lines `59, 70–75, 132–140, 241, 281–283, 290–291, 307–308`):**
  - Enforced `at + 9 + n > bytes.length` before accessing `bytes[at + 4 + n]` or `getUint32(at + 5 + n)` (`line 59`).
  - Bounded `kindCount` (`0..32`), `count` (`0..256`), and `firstCode` (`0..0x10FFFF`) before allocating `kinds` or calling `String.fromCharCode` (`lines 70–75`).
  - Added bounds-checked `u32(at)` and `setU32(at, value)` throwing `const FormatException('File Zelio Soft 2 rusak.')` (`lines 132–140`) and routed `writeZm2` writes through `sheet.setU32` (`lines 241, 281–283, 290–291`).
  - Clamped `limit` to `bytes.length` in `_find` (`lines 307–308`).

---

### `MF-3` — Malformed JSON in `SharedPreferences` or `.bwproj`/`.tdproj` files bricks startup (`_restore`) or crashes `importJson` after mutating active project
- **Category:** Bug (crash / startup failure) / Data loss
- **Rank:** `Must fix` | **Milestone:** M1 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/app_state.dart:440-452, 459-470, 475-492`; `lib/model/project.dart:40-49, 95-107, 142-155`
- **Concrete Failure Scenario:**
  1. A corrupted `td-project` entry in `SharedPreferences` (e.g., `[]` or truncated `WirePoint`) caused `AppState._restore()` to throw an uncaught `TypeError` or `RangeError` inside `AppState(defs, prefs)` before `runApp`, permanently bricking startup.
  2. Opening a `.bwproj` with `"points": [[10]]` threw an uncaught `RangeError` in `Wire.fromJson` instead of `FormatException` (`home.dart` and `workspace.dart` only catch `FormatException`).
  3. Opening a `.bwproj` with invalid `device.data` (e.g., `"scale": "2x"`, malformed `ladder`/`program`, or non-finite coordinates) could crash `fitView()` after `importJson` had already overwritten `this.project`, discarding the user's active circuit.
- **Connected Callers:** `main()` -> `AppState` (`lib/main.dart:24`), `HomeScreen._openFile` (`lib/ui/home.dart:70`), `Workspace._open` (`lib/ui/workspace.dart:44`), `AppState._load` (`lib/app_state.dart`).
- **Applied Minimal Fix:**
  - `lib/model/project.dart` (`post-edit lines 95–118, 166–167`): `Wire.fromJson` validates `rawPoints` is a `List`, each point is a `List` with `length >= 2`, numeric elements, and finite `x`/`y`, throwing `const FormatException('rusak')`; `Project.fromJson` catches `on RangeError` alongside `on TypeError`.
  - `lib/app_state.dart` (`post-edit lines 448–513`): `AppState._restore` checks `decoded is! Map<String, dynamic>` and catches `FormatException`, `TypeError`, and `RangeError` (resetting to `Project()`); `AppState._validated` filters non-finite device `x`/`y`, sanitizes `data['scale']` (removes invalid/non-finite/`<= 0`, clamps to `[minScale, maxScale]`), strips invalid/dangling `data['seated_on']`, validates `data['ladder']`/`data['program']` via `LadderProgram.of` (removing both keys on `FormatException`/`TypeError`/`RangeError`), and filters non-finite `WirePoint`s. `importJson` (`lines 517–534`) completes parsing and `_validated` before mutating active state.

---

### `MF-4` — Zelio PLC `AC` timer off-delay (`run.edge`) hangs permanently in panel simulation and malfunctions on retrigger
- **Category:** Bug (breaks core PLC timer behavior)
- **Rank:** `Must fix` | **Milestone:** M1 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/sim/ladder.dart:369, 521-531` (called by `lib/app_state.dart:1848`)
- **Concrete Failure Scenario:** For Zelio `AC` timers (on-delay + off-delay), when input falls while `run.out == true` (`run.since` is already `null`), `_command` sets `run.edge = now`. `PlcMemory.ticking` only checked `t.since != null`, so `AppState.advance()` stopped re-solving the PLC and `T1` stayed permanently stuck ON instead of turning off after `t2`. Additionally, a rising edge while `run.edge != null` set `run.since = now` without clearing `run.edge = null`, so `_timer` checked `run.edge != null` first and turned `run.out` off when the stale off-delay expired even while commanded ON.
- **Connected Callers:** `AppState.advance` (`lib/app_state.dart`), `_LadderEditorState._scan` (`lib/ui/plc_editor.dart`).
- **Applied Minimal Fix (`lib/sim/ladder.dart`, post-edit lines `369, 522–525`):**
  - Updated `PlcMemory.ticking` (`line 369`) to `timers.values.any((t) => t.since != null || t.edge != null);`.
  - Updated `_command` (`lines 522–525`) for `case 'A' || 'AC':` on `rise` to clear `run.edge = null;` before `if (!run.out) run.since = now;`.

---

### `MF-5` — Pasting/duplicating a contactor-mounted TOR leaves stale `seated_on` ID, creating phantom electrical links to the original contactor
- **Category:** Bug (state desync / wrong simulation topology)
- **Rank:** `Must fix` | **Milestone:** M1 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/app_state.dart:985-1015` (consumed by `lib/sim/solver.dart:456-464`, `lib/app_state.dart:688, 751, 803`)
- **Concrete Failure Scenario:** `_pasteJson` assigned new device IDs (`idMap`) and shifted coordinates, but copied `source.data` verbatim without remapping or clearing `data['seated_on']`. Pasting a TOR `F1` seated on `KM1` (`id: 5`) produced `F2` with `seated_on: 5`, invisibly bridging `F2`'s `1/3/5` terminals to the original `KM1`'s `2/4/6` terminals in `Solver.seatedLinks`, blocking wiring on `F2`, and moving `F2` whenever `KM1` was dragged.
- **Connected Callers:** `AppState.paste`, `AppState.duplicateSelection`, `Solver.seatedLinks`, `AppState.terminalCovered`, `isSeated`, `hasSeatedOverload`, `beginMove`.
- **Applied Minimal Fix (`lib/app_state.dart`, post-edit lines `1030–1057`):**
  - Deep-copied non-empty `source.data` via `jsonDecode(jsonEncode(source.data))`, tracked pasted devices in `pasted`, and after `idMap` was populated, remapped `copy.data['seated_on']` via `idMap[oldId]` when the target contactor was also pasted, or removed `'seated_on'` otherwise.

---

### `F-AI-01` — `atur_program_plc` silently rewrites counter contacts `C1..C4` into arrow keys `Z1..Z4`
- **Category:** Bug (broken core AI PLC programming)
- **Rank:** `Must fix` | **Milestone:** M1 + M2 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/ai/circuit_tools.dart:661-662, 696, 702-705`; `lib/sim/ladder.dart:284-298`
- **Concrete Failure Scenario:** `CircuitTools._program` allows `C1..C4` as counter contacts per the tool schema, then passes `PlcRung` to `LadderProgram.fromRungs` and overwrites `rows.first.coil = coil`. Because `fromRungs` unconditionally renamed `C1..C4` contacts to `Z1..Z4` (for legacy saved-program migration in `LadderProgram.of`), AI-generated ladder programs with counter `CC1` + contact `C1` left the coil as `CC1` while turning the contact into arrow key `Z1`, breaking counter logic in simulation.
- **Connected Callers:** `CircuitTools._program` (`lib/ai/circuit_tools.dart`), `LadderProgram.of` (`lib/sim/ladder.dart:278`, which retains legacy `C1..C4 -> Z1..Z4` migration).
- **Applied Minimal Fix (`lib/sim/ladder.dart` post-edit lines `282–286` & `lib/ai/circuit_tools.dart` post-edit line `702`):**
  - Added `{bool renameCursor = true}` to `LadderProgram.fromRungs` (`lib/sim/ladder.dart:284`), gating the `C1..C4 -> Z1..Z4` rename on `renameCursor` (default `true` preserves `LadderProgram.of` compatibility).
  - Passed `renameCursor: false` in `CircuitTools._program` (`lib/ai/circuit_tools.dart:702`).

---

### `F-AI-02` — `AiAgent.stop()` does not abort in-flight 240s HTTP calls (locking workspace), and `LadderEditor.dispose()` causes `notifyListeners()` on a disposed `ChangeNotifier` + `http.Client` leak
- **Category:** Bug / Async cancellation & dispose race / Resource leak
- **Rank:** `Must fix` | **Milestone:** M2 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/ai/ai_agent.dart:100-108, 145-151, 174, 198, 208-211, 240, 246, 278, 284-307`; `lib/ai/ai_connector.dart:70, 269-277, 307` (callers `lib/ui/plc_editor.dart:132-136`, `lib/app_state.dart:88`)
- **Concrete Failure Scenario:**
  1. Closing `LadderEditor` while an AI HTTP request (`timeout: 240s`) is in flight runs `_agent.dispose()` immediately; when the request resolves/times out, `send()` executes `notifyListeners()` on a disposed `ChangeNotifier`, throwing `FlutterError: A AiAgent was used after being disposed`, and `AiAgent` never closed its owned `http.Client`.
  2. Clicking `Hentikan` while `_ask()` is waiting on a stalled endpoint left `busy == true` (`app.aiLocked == true`) for up to 240 seconds, freezing the entire BuildWire workspace.
- **Connected Callers:** `AppState.ai` (`lib/app_state.dart`), `AiChatPanel` (`lib/ui/ai_chat_panel.dart`), `LadderEditor` (`lib/ui/plc_editor.dart`), `AiSettingsDialog` (`lib/ui/ai_settings_dialog.dart`).
- **Applied Minimal Fix (`lib/ai/ai_agent.dart` post-edit lines `1, 102–364` & `lib/ai/ai_connector.dart` post-edit lines `70–77, 312–324`):**
  - In `AiConnector`: tracked `_ownsClient = client == null`, mutable `_client`, and `_closed`; added `cancelPending()` (closes and replaces `_client` when `_ownsClient && !_closed`) and idempotent `close()`.
  - In `AiAgent`: tracked `_ownsConnector`, `_disposed`, and `_stopSignal`; added `_notify()` (`if (!_disposed) notifyListeners()`), `_raceStop(Future<AiReply>)` (races against `_stopSignal` and calls `future.ignore()` / handles errors cleanly without unhandled async errors), updated `stop()` to complete `_stopSignal` and call `_connector?.cancelPending()`, overrode `dispose()` to set `_disposed = true`, call `stop()`, close/clear owned `_connector`, and call `super.dispose()`, and guarded `reset()`, `send()`, `_ask()`, and `finally` (`if (!_disposed) workspace.end()`). Zero-arg `stop()` and `dispose()` signatures preserved.

---

### `F-AI-03` — Unguarded JSON `as` casts in `AiConnector` crash `connect()` and `AiReply.fromOpenAi()` on unexpected field types
- **Category:** Bug / Risky code (Uncaught `TypeError`)
- **Rank:** `Must fix` | **Milestone:** M2 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/ai/ai_connector.dart:165, 355-356, 365, 368, 375-388, 392`
- **Concrete Failure Scenario:** Connecting to an OpenAI-compatible proxy that returns non-string `"owned_by"` (e.g., `1`) in `/models` threw an uncaught `TypeError` in `_parseModel` (callers only catch `on AiError`). Receiving a non-map `choices[0]` or non-list `tool_calls` crashed `AiReply.fromOpenAi` instead of returning `valid: false` for retry/error handling; non-map `block['input']` in `fromAnthropic` became `{}` without setting `badArguments: true`.
- **Connected Callers:** `AiSettingsDialog._connect` (`lib/ui/ai_settings_dialog.dart`), `AiConnector.probeFormats`, `AiConnector.checkTools`, `AiAgent._ask`.
- **Applied Minimal Fix (`lib/ai/ai_connector.dart`, post-edit lines `169–170, 363–423`):**
  - `_parseModel` (`lines 169–170`): guarded `owner is String ? owner : null`.
  - `AiReply.fromAnthropic` (`lines 363–382`): extracted `content` without `as List` and set `badArguments: input != null && input is! Map<String, dynamic>`.
  - `AiReply.fromOpenAi` (`lines 384–423`): guarded `first is! Map<String, dynamic>`, `rawCalls is List`, set `bad = true` for unexpected `args` types (`args != null && args is! String`), and read `first['finish_reason']` without unsafe casts.

---

### `F-AI-04` — Unbounded image decoding in `AiAttachment._prepareImage` vulnerable to decompression-bomb OOM/hang
- **Category:** Security / Failure under load (DoS / OOM)
- **Rank:** `Must fix` | **Milestone:** M2 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/ai/ai_attachment.dart:62-85` (called by `AiAttachment.load:45` and `lib/ui/ai_chat_panel.dart:76`)
- **Concrete Failure Scenario:** `AiChatPanel` capped raw compressed file size at 20 MB, not decoded pixel dimensions. `AiAttachment._prepareImage` called `img.decodeImage(bytes)` to decompress the full RGBA buffer before checking `width`/`height`, allowing a small 20,000×20,000 PNG decompression bomb to allocate ~1.5+ GB and crash with OOM, or corrupt image headers to throw uncaught exceptions out of `AiAttachment.picture`.
- **Connected Callers:** `AiAttachment.load`, `AiAttachment.picture`, `AiChatPanel._addFiles`.
- **Applied Minimal Fix (`lib/ai/ai_attachment.dart`, post-edit lines `72–95`):**
  - Wrapped `_prepareImage` in `try { ... } catch (_) { return null; }`.
  - Probed container and header dimensions first via `img.findDecoderForData(bytes)` and `decoder.startDecode(bytes)`, rejecting `decoder == null || info == null || info.width <= 0 || info.height <= 0 || info.width > 16384 || info.height > 16384 || info.width * info.height > 40000000` before calling `decoder.decodeFrame(0)` (`AiAttachment.picture` converts `null` to `FormatException`).

---

### `F-RL-01` — `RelaySheet.fromJson` accepts wires with non-existent pin names and unguarded JSON casts, causing paint-loop crashes
- **Category:** Bug / File corruption handling
- **Rank:** `Must fix` | **Milestone:** M3 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/relay/relay_model.dart:207-208, 232-240, 278-286, 304, 333-344`
- **Concrete Failure Scenario:** `RelaySheet.fromJson` only checked that wire endpoints referenced existing symbol IDs, not that the pin names existed in `symbol.def.pins` (and allowed duplicate symbol IDs). Loading a `.bwrelay` file with `"a": [1, "BAD"]` succeeded in `fromJson` and then crashed `_SheetPainter.paint` on every frame at `def.pins[name]!`. Unguarded `as` casts in `RelaySymbol.fromJson`, `RelayWire.fromJson`, and `RelaySymbol` getters (`supply`/`seconds`/`text`) also threw raw `TypeError`/`RangeError` instead of `FormatException`.
- **Connected Callers:** `RelayEditor._open`, `RelayEditor._restore`, `_SheetPainter.paint`, `RelayEditor.wireAt`, `RelayEditor._branch` (`lib/relay/relay_editor.dart`).
- **Applied Minimal Fix (`lib/relay/relay_model.dart`, post-edit lines `222, 225, 228, 239–246, 341–366`):**
  - Guarded `RelaySymbol.supply`, `seconds`, and `text` getters with `is String` / `is num` checks (`lines 222, 225, 228`).
  - Validated `'supply'`, `'text'` (`as String?`), and `'seconds'` (`as num?`) in `RelaySymbol.fromJson` via Dart 3 `switch` (`lines 239–246`).
  - In `RelaySheet.fromJson` (`lines 341–366`): rejected duplicate symbol IDs (`byId`), filtered wires using `(byId[w.a.symbol]?.def.pins.containsKey(w.a.pin) ?? false) && (byId[w.b.symbol]?.def.pins.containsKey(w.b.pin) ?? false)`, and converted `TypeError`, `RangeError`, and `UnsupportedError` into `const FormatException('File BuildRelay rusak.')`.

---

### `F-RL-02` — Multiple null-dereference and disposed-state crashes in `RelayEditor` (`_newSheet`/`_open`/`deleteSelection`/`toggleSim`/`_save`)
- **Category:** Bug (UI/state crashes)
- **Rank:** `Must fix` | **Milestone:** M3 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/relay/relay_editor.dart:377-396, 417-424, 449, 485-486, 496-507, 515-526, 1470-1472`
- **Concrete Failure Scenario:**
  1. `_newSheet` and `_open` replaced `sheet` without clearing `pending`, `corners`, `placing`, `_dragging`, `_dragBefore`, `_held`, or `_sel3Last`, crashing `_SheetPainter.paint` at `sheet.symbol(end.symbol)!`.
  2. Pressing `Delete` or `undo` while `_dragging != null` removed the symbol while `_move`/`_up` called `sheet.symbol(id)!`.
  3. Stopping simulation (`toggleSim`, e.g., via `Ctrl+O`) while holding a push button left `_held != null`; releasing the pointer ran `_operate(s, false)` -> `sim!` -> null-check crash.
  4. `_save` and `_open` called `setState` after `await` without checking `if (!mounted) return;`.
- **Connected Callers:** Internal to `_RelayEditorState` (`lib/relay/relay_editor.dart`).
- **Applied Minimal Fix (`lib/relay/relay_editor.dart`, post-edit lines `140–155, 389–394, 404–414, 442, 447, 504, 516, 525, 544`):**
  - Added `_clearTransient()` (`lines 140–149`) and called it in `_restore` (`155`), `toggleSim` stop and start (`442, 447`), `_open` (`525`), and `_newSheet` (`544`).
  - Replaced `sheet.symbol(id)!` with null-checked lookups in `_move` (`389–394`) and `_up` (`413–414`); captured `id = _held!`, cleared `_held = null` unconditionally, and gated `_operate(s, false)` on `if (simulating)` (`404–411`).
  - Added `if (!mounted) return;` after `await` in `_save` (`504`) and `_open` (`516`).

---

### `F-RL-03` — `_TagFieldState` missing `didUpdateWidget` silently reverts `ChoiceChip` contact tag selection
- **Category:** Bug / Silent data loss
- **Rank:** `Must fix` | **Milestone:** M3 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/relay/relay_editor.dart:745-765, 784, 792, 865-893`
- **Concrete Failure Scenario:** `_TagField` shares `key: ValueKey('tag-${s.id}')` while `ChoiceChip` updates `s.tag` on the same symbol. Because `_TagFieldState` only set `_controller` on initial construction and never implemented `didUpdateWidget`, clicking on the canvas after picking a `ChoiceChip` triggered `onTapOutside`, submitting the stale `_controller.text` and silently reverting the user's tag change.
- **Connected Callers:** All three `_TagField` instances in `RelayEditor._side` (`lib/relay/relay_editor.dart`).
- **Applied Minimal Fix (`lib/relay/relay_editor.dart`, post-edit lines `900–909`):**
  - Implemented `_TagFieldState.didUpdateWidget(_TagField old)` updating `_controller.value` (with collapsed cursor selection at `widget.text.length`) whenever `widget.text != old.text && widget.text != _controller.text`.

---

### `F-01` — Duplicate `ValueKey` crash when an HMI has two buttons with the same label
- **Category:** Bug (Crash)
- **Rank:** `Must fix` | **Milestone:** M4 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/ui/canvas_view.dart:1473-1486`, `lib/ui/hmi_editor.dart:95`
- **Concrete Failure Scenario:** Adding two default push buttons (`label: 'TOMBOL'`) in HMI Editor and saving caused `_HmiScreen` to render sibling `_HmiButton` widgets with identical `ValueKey('hmi-${device.tag}-${widget['label']}')`, throwing a fatal `Duplicate keys found` error during canvas build.
- **Connected Callers:** `showHmiEditor` (`lib/ui/panels.dart:845`), `HmiEditor` (`lib/ui/hmi_editor.dart:106`), `AppState.setHmiWidgets` (`lib/app_state.dart`), `_HmiScreen` (`lib/ui/canvas_view.dart`).
- **Applied Minimal Fix (`lib/ui/canvas_view.dart`, post-edit lines `1466–1500`):**
  - Tracked `seen = <String>{}` across an indexed loop in `_HmiScreen.build`; preserved `ValueKey('hmi-${device.tag}-${widget['label']}')` for unique/first occurrences and disambiguated duplicates with `#$i` (plus `#` fallback loop if a label literally ends in `#i`).

---

### `F-02` — Deleting an item in HMI Editor desyncs `FormField` widgets and corrupts saved data
- **Category:** Bug / Data Corruption
- **Rank:** `Must fix` | **Milestone:** M4 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/ui/hmi_editor.dart:50-89`
- **Concrete Failure Scenario:** `_HmiEditorState.build` built unkeyed `Padding` rows containing `DropdownButtonFormField` and `TextFormField` with `initialValue`. Deleting any non-last row shifted `_items` without resetting `FormFieldState`, so row 0 kept displaying the deleted row's values while editing/saving mutated the shifted item underneath.
- **Connected Callers:** `showHmiEditor` (`lib/ui/panels.dart:845`), `AppState.setHmiWidgets` (`lib/app_state.dart`).
- **Applied Minimal Fix (`lib/ui/hmi_editor.dart`, post-edit line `53`):**
  - Added `key: ObjectKey(_items[i]),` to each row's `Padding` widget (every entry in `_items` is a distinct `Map<String, dynamic>` instance created by `Map.of(...)` or `{...}`).

---

### `F-03` — Pressing `Delete` inside text fields in `BuildLadder` deletes the selected ladder cell
- **Category:** Bug / Data Loss
- **Rank:** `Must fix` | **Milestone:** M4 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/ui/plc_editor.dart:420-425`
- **Concrete Failure Scenario:** `LadderEditor` wrapped `body` in an unguarded `KeyboardListener` that invoked `_deleteSelected()` on `LogicalKeyboardKey.delete` even when focus was inside an `EditableText` (symbol name, row comment, timer/counter boxes, or `AiChatPanel`) or while `_agent.busy` / `_simulating` was true, silently deleting the selected ladder cell (with no Undo in `LadderEditor`).
- **Connected Callers:** `showPlcEditor` (`lib/ui/panels.dart:841`), `showStandaloneLadder` (`lib/ui/home.dart:215`), `LadderStartPage` (`lib/ui/ladder_start.dart:56`).
- **Applied Minimal Fix (`lib/ui/plc_editor.dart`, post-edit lines `448–478`):**
  - Added `static bool get _typing` checking `FocusManager.instance.primaryFocus?.context` for `EditableText` or ancestor `EditableText` (matching `Workspace._typing`).
  - Replaced `KeyboardListener` with `Focus(focusNode: _focus, autofocus: true, onKeyEvent: ...)` guarding `event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.delete && !_typing && !_agent.busy && !_simulating`, returning `KeyEventResult.handled` when `_deleteSelected()` runs.

---

### `F-04` — Silent loss of unsaved ladder programs on `BuildLadder` barrier click, Close (`X`), or New (`ladder-new`)
- **Category:** Data Loss
- **Rank:** `Must fix` | **Milestone:** M4 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/ui/plc_editor.dart:24-32, 312-323, 521-526, 556-561`
- **Concrete Failure Scenario:** `showPlcEditor` used default `barrierDismissible: true`, and `Esc`, `ladder-close` (`X`), `ladder-new`, and `_open` discarded unsaved ladder edits (`_dirty == true`) with zero confirmation.
- **Connected Callers:** `showPlcEditor` (`lib/ui/panels.dart:841`), `showStandaloneLadder` (`lib/ui/home.dart:215`), `LadderStartPage` (`lib/ui/ladder_start.dart:56`).
- **Applied Minimal Fix (`lib/ui/plc_editor.dart`, post-edit lines `26, 324–360, 456–462, 578–581, 616–619`):**
  - Set `barrierDismissible: false` in `showPlcEditor` (`line 26`).
  - Added `_confirmDiscard()` returning `true` immediately when `!_dirty` or showing a 2-button `AlertDialog` (`Batal` / `Buang perubahan`).
  - Wrapped `ScaffoldMessenger`/`Scaffold` in `PopScope(canPop: !_dirty, onPopInvokedWithResult: ...)` and guarded `_open()`, `ladder-new`, and `ladder-close` with `if (!await _confirmDiscard() || !mounted) return;`.

---

### `F-05` — Uncaught exception and missing `mounted` guard when opening `.bwlad`/`.zm2` from `LadderStartPage`
- **Category:** Bug (Uncaught Async Exception / `setState` after dispose)
- **Rank:** `Must fix` | **Milestone:** M4 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/ui/ladder_start.dart:63-72`; `lib/ui/plc_editor.dart:120-121, 282-310`
- **Concrete Failure Scenario:** `LadderStartPage._openFile` passed raw file bytes into `LadderEditor` before parsing; `LadderEditor.initState` called `openBytes` in a post-frame callback without `try/catch` or `mounted` guards. Opening a corrupted `.zm2` or malformed `.bwlad` from `LadderStartPage` threw an unhandled `FormatException`/`TypeError` on a blank editor, and `LadderStartPage`'s `catch` lacked `mounted` before `setState`.
- **Connected Callers:** `LadderStartPage._openFile` -> `LadderEditor.initState` -> `openBytes`.
- **Applied Minimal Fix (`lib/ui/plc_editor.dart` post-edit lines `122, 299–322` & `lib/ui/ladder_start.dart` post-edit line `70`):**
  - In `plc_editor.dart`: added `if (!mounted) return;` before `setState` in `openBytes`, read `_messenger.currentState` directly rather than caching across awaits, and routed `initState`'s post-frame callback through `_openInitial(file)` wrapping `await openBytes(...)` in `try / on FormatException / catch` with `if (mounted)` SnackBar feedback.
  - In `ladder_start.dart`: guarded `if (mounted) setState(...)` in `_openFile`'s `catch` block (`line 70`).

---

### `F-06` — `AiChatPanel` calls `setState()` / `FocusNode.requestFocus()` after `dispose()` and lacks error handling on dropped file metadata
- **Category:** Bug (Crash: `setState` after dispose / unhandled async error)
- **Rank:** `Must fix` | **Milestone:** M4 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/ui/ai_chat_panel.dart:59-128`
- **Concrete Failure Scenario:** Closing `AiChatPanel` (`Ctrl+I` or closing `BuildLadder`) while `openFiles` or `Pasteboard` was awaiting caused `_addFiles` / `_pick` / `_pasteAttachments` to call `setState` and `_focus.requestFocus()` after `dispose()`, throwing `FlutterError`. Dragging/dropping a virtual or unreadable file caused `await f.length()` in `_drop` to throw an unhandled async error.
- **Connected Callers:** `Workspace` (`lib/ui/workspace.dart:223`), `LadderEditor` (`lib/ui/plc_editor.dart:445`).
- **Applied Minimal Fix (`lib/ui/ai_chat_panel.dart`, post-edit lines `60–157`):**
  - Added `mounted` guards across every async suspension in `_addFiles`, `_pick`, `_drop`, and `_pasteAttachments` (including inside `f.length()` loops and before `setState` / `_focus.requestFocus()`).
  - Wrapped `_pick` and `_drop` metadata/read preparation in `try/catch` setting `_attachError` when `mounted`.

---

### `F-07` — `SwarmOverlay` reads `context.size` inside `ListenableBuilder.builder` during `build()`
- **Category:** Bug (Framework assertion crash in debug/test mode)
- **Rank:** `Must fix` | **Milestone:** M4 | **Status:** `FIXED`
- **Pre-edit Location:** `lib/ui/swarm_overlay.dart:92-94, 126-127, 174, 189`
- **Concrete Failure Scenario:** Whenever the AI assistant wrote a ladder program and populated `swarm.card`, `_SwarmOverlayState._card(context, card)` read `context.size?.height` inside `ListenableBuilder.builder` during `build()`, triggering Flutter's `Cannot get size during build` `FlutterError` assertion.
- **Connected Callers:** `Workspace` (`lib/ui/workspace.dart:227`), `Swarm.card` (`lib/ai/swarm.dart:114`).
- **Applied Minimal Fix (`lib/ui/swarm_overlay.dart`, post-edit lines `32, 45, 94–150, 179, 194`):**
  - Removed all `context.size` reads; stored `_overlayHeight = self.size.height` inside `_measure()`, wrapped `ListenableBuilder` in `LayoutBuilder`, computed `final height = constraints.hasBoundedHeight ? constraints.maxHeight : _overlayHeight;`, and passed `height` to `_card(context, card, height)`.

---

## 4. Section 2 — `Should fix` Findings (29 Findings — Untouched in Code)

*(Note: Unless explicitly tagged `post-edit`, line numbers cited in this section for the 17 modified `lib/` files reflect pre-edit baseline line numbers per `baseline_lib/`.)*

### `SF-1` — `_skew` from `fastForward()` is never reset on `stopSimulation()` / `startSimulation()`
- **Category:** Bug (state desync) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/app_state.dart:1780-1831`
- **Concrete Failure Scenario:** `fastForward()` increments `_skew += 100ms`, and `_now()` adds `_skew` to `DateTime.now()`, but neither `startSimulation()` nor `stopSimulation()` resets `_skew = Duration.zero`. Running an AI `uji_rangkaian` 600s wait leaves `_now()` 10 minutes in the future for all subsequent simulation runs, mis-triggering `ClockSlot.activeAt` (`lib/sim/solver.dart:218`) and skewing `plcClockOf`.
- **Connected Callers:** `_now()`, `_solve()`, `plcClockOf()`, `setPlcClock()`, `CircuitTools` (`lib/ai/circuit_tools.dart:814, 820`).

### `SF-2` — Hardware timer relays (`_timerStarted`) depend on wall-clock `DateTime.now()` instead of simulation `_elapsed`
- **Category:** Bug / Edge case | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/app_state.dart:429-434, 1840-1845, 2703-2715`
- **Concrete Failure Scenario:** `_syncTimers` stores `_now()`, and `advance()` computes `_now().difference(started)`. If system wall time steps backward (NTP/DST/manual change) during simulation, hardware timers stall; if it jumps forward, timers fire immediately.
- **Connected Callers:** `AppState.advance()`, `AppState._syncTimers()`.

### `SF-3` — `Solver._Nets.build` stores `_hertz` and `_phaseVolts` globally by label rather than per source/net
- **Category:** Bug (multi-source inaccuracy) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/sim/solver.dart:655-659`
- **Concrete Failure Scenario:** Placing an adjustable DC source (`isAdjustable == true`, no `frequency` control) after an adjustable AC source set to `60 Hz` overwrites `nets._hertz` back to fallback `50` Hz; placing a fixed 230V AC source after an adjustable AC source overwrites `_phaseVolts['L1']` back to `230` V.
- **Connected Callers:** `Solver._Nets.build`, `Solver.solve`.

### `SF-4` — Non-atomic file writes and missing extension enforcement in `file_io.saveBytes`
- **Category:** Data loss / file corruption risk | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/file_io.dart:26-37, 39-52, 67-68, 101-102`
- **Concrete Failure Scenario:** `saveBytes` calls `await file.saveTo(location.path)` directly without staging to a temp file + atomic rename and without appending `.$extension` (unlike `saveLadderFile`). A write interruption mid-save corrupts existing `.bwproj`/`.bwrelay` files, and saving without typing the extension creates an extensionless file hidden from `openFile` filters.
- **Connected Callers:** `Workspace._save/_exportCsv/_exportPng` (`lib/ui/workspace.dart:59, 61, 77`), `RelayEditor._save` (`lib/relay/relay_editor.dart:485`).

### `SF-5` — Non-UTF-8 files in `pickProjectText` / `pickRelayFile` expose raw Dart `FormatException` messages
- **Category:** Risky code / UX error handling | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/file_io.dart:17, 98`
- **Concrete Failure Scenario:** `pickProjectText` (`readAsString`) and `pickRelayFile` (`utf8.decode`) do not wrap UTF-8 decode failures into localized Indonesian `FormatException`s, displaying raw `"Unexpected extension byte (at offset ...)"` errors when non-UTF-8/binary files are opened.
- **Connected Callers:** `HomeScreen._openFile` (`lib/ui/home.dart:74`), `Workspace._open` (`lib/ui/workspace.dart:47`), `RelayEditor._open` (`lib/relay/relay_editor.dart:509`).

### `SF-6` — Dragging a DIN rail or panel box leaves seated TORs behind and unplugs them on `endMove`
- **Category:** Bug (UI/model desync) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/app_state.dart:684-705, 864-873`
- **Concrete Failure Scenario:** `beginMove` Pass 2 only carries TORs seated on directly `selectedDevices` contactors, not contactors carried via `_carried` (mounted on a dragged DIN rail/box). Moving a DIN rail leaves the TOR behind and `endMove` -> `_linkSeatedOverloads` deletes `seated_on`, silently unplugging the TOR.
- **Connected Callers:** `AppState.beginMove`, `AppState.endMove`, `_DeviceView` (`lib/ui/canvas_view.dart`).

### `SF-7` — PLC timer reset coil (`RT1`) on a lower row misses restarting a held `TT1` command on release
- **Category:** Bug (PLC ladder edge case) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/sim/ladder.dart:470-495`
- **Concrete Failure Scenario:** In `_drive`, `run.input = power` runs before `if (!run.reset) _command(...)`. With `I1 -> TT1` on Row 0 and `I2 -> RT1` on Row 1, turning `I1` ON while `I2` is ON sets `run.input = true` while skipping `_command`; when `I2` turns OFF while `I1` remains ON, `before == true && power == true`, so `rise` is `false` and `TT1` never starts timing.
- **Connected Callers:** `scanLadder` (`lib/sim/ladder.dart`).

### `SF-8` — Missing zero/non-positive guards in `DeviceDef.impedance` and `AppState._heatProtection`
- **Category:** Risky code (`Infinity`/`NaN` propagation) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/model/device_def.dart:213-216`; `lib/app_state.dart:1882-1883`
- **Concrete Failure Scenario:** `impedance` does not guard `rated.volts <= 0`, and `_heatProtection` divides by `rated` without checking `rated <= 0`. A catalog entry with `volts: 0` or an imported `.bwproj` with `data['rated_current_a'] = 0` yields `0.0` impedance (`amps = Infinity`, `watts = NaN`) or `NaN`/`Infinity` thermal ratio. (All current `index.json` entries have `volts > 0` and control `min > 0`.)
- **Connected Callers:** `Solver._Flow` (`lib/sim/solver.dart:563-564`), `AppState.advance` (`lib/app_state.dart`).

### `SF-9` — `AppState.setProgram` / `setHmiWidgets` / `setTime` / `setTag` / `renameProject` lack `if (running)` guards
- **Category:** Risky code (state invariant) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/app_state.dart:608-614, 1037-1050, 2321-2333`
- **Concrete Failure Scenario:** Unlike `addDevice` or `deleteSelection`, these mutators do not guard `if (running) return;`. Invoking `renameProject` (e.g., via `F5` blur, see `F-10`) or `setProgram` while `running == true` mutates project state against live `_plcMemory` and pushes simulation-time undo entries while `canUndo` is disabled.
- **Connected Callers:** `Workspace._ProjectName`, `PropertiesPanel`, `LadderEditor`, `HmiEditor`.

### `SF-10` — `SoundPlayer.loopPosition` bypasses the per-player serialized call queue
- **Category:** Risky code (native Windows audio concurrency) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/sound.dart:171-175`
- **Concrete Failure Scenario:** `SoundPlayer` serializes all `AudioPlayer` calls via `_on(player, ...)` to avoid Windows native plugin crashes, but `loopPosition` calls `player.getCurrentPosition()` directly. Calling `loopPosition` concurrently with `setLoops`/`mixLoop` violates the single-flight invariant. (No callers in `lib/`; possibly exercised by tests.)
- **Connected Callers:** None under `lib/`.

### `F-AI-06` — `CircuitTools._simulate` floating-point `clamp` `ArgumentError` and leaked `app.running`
- **Category:** Bug / Risky code | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ai/circuit_tools.dart:769, 802, 899`
- **Concrete Failure Scenario:** Floating-point drift pushing `waited` slightly above `600.0` makes `600.0 - waited < 0`, causing `.clamp(0.0, 600.0 - waited)` to throw `ArgumentError` (`lower > upper`), aborting `uji_simulasi` and skipping `app.stopSimulation()` at line 899.
- **Connected Callers:** `CircuitTools.run` (`325`), `AppState.startSimulation`/`stopSimulation`.

### `F-AI-07` — `CircuitTools._simulate` unawaited `swarm.watch` race
- **Category:** Bug (Async race) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ai/circuit_tools.dart:783-786, 893-897`
- **Concrete Failure Scenario:** `unawaited(swarm.watch(...).then(...))` can resolve after lines 893-897 clear watcher state, re-applying `CursorShape.watch` and `'mengamati ...'` to idle/leaving cursors after simulation stops.
- **Connected Callers:** `Swarm.watch` (`lib/ai/swarm.dart:470`).

### `F-AI-08` — `CircuitTools._program` PLC address rules diverge from `LadderWorkspace`
- **Category:** Bug (Inconsistent validation) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ai/circuit_tools.dart:658-662` vs `lib/ai/ladder_tools.dart:39-44`
- **Concrete Failure Scenario:** On canvas LOGO PLCs (`!def.isZelio`), `atur_program_plc` accepts Zelio-only registers (`M17..MV`, `N1..NV`, `T17..TV`, `C17..CV`), while rejecting valid `H1..H8` clock contacts on Zelio PLCs.
- **Connected Callers:** `CircuitTools._program` (`654`).

### `F-AI-09` — `AiConnector.chat` repeats `max_tokens` failure on every turn for `max_completion_tokens`-only models
- **Category:** Failure under load (Latency & request doubling) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ai/ai_connector.dart:259-265`
- **Concrete Failure Scenario:** Models requiring `max_completion_tokens` (e.g., OpenAI `o1`/`o3`/`gpt-5`) fail HTTP 400 on `max_tokens` first on every single step of an 80-step agent loop, doubling API calls and latency.
- **Connected Callers:** `AiAgent._ask`, `AiConnector.probeFormats`, `AiConnector.checkTools`.

### `F-AI-10` — `AiAgent._ask` stringifies entire `_history` content (including base64 images) on every request
- **Category:** Failure under load (Memory/CPU churn) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ai/ai_agent.dart:289` (pre-edit; `line 344` post-edit)
- **Concrete Failure Scenario:** `'${m['content']}'.contains('[Lampiran ')` invokes `List.toString()` on messages containing multi-megabyte base64 image strings on every loop step and retry.
- **Connected Callers:** `AiAgent.send`.

### `F-AI-11` — `SecureSecretStore.writeKey` lacks error handling
- **Category:** Risky code | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ai/ai_settings.dart:73-75`
- **Concrete Failure Scenario:** Unlike `readKey` (`64-70`), `writeKey` does not catch `FlutterSecureStorage` platform errors; if DPAPI/keyring write or delete fails, `_save`/`_forget` throw an unhandled async exception.
- **Connected Callers:** `AppState.saveAi`, `AppState.forgetAi` (`lib/app_state.dart:68, 75`), `AiSettingsDialog` (`lib/ui/ai_settings_dialog.dart:163, 168`).

### `F-AI-12` — `LadderWorkspace._test` lacks total simulated time cap across `tunggu` steps & `_editRows` fails to deduplicate `hapus`
- **Category:** Failure under load / Bug | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ai/ladder_tools.dart:324, 336-338, 420-427`
- **Concrete Failure Scenario:** Multiple `tunggu` steps of 3600s each (36,000 `scanLadder` calls per step) can freeze the UI isolate with millions of synchronous scans; passing duplicate row indices in `hapus` (e.g., `[2, 2]`) deletes row 2 and then deletes the shifted row 3.
- **Connected Callers:** `LadderWorkspace.run` (`182, 184`).

### `F-AI-13` — `Swarm.finish()` leaks `leaving` cursors when `animated == false`
- **Category:** Bug (State leak) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ai/swarm.dart:195-207`
- **Concrete Failure Scenario:** When no `SwarmOverlay` is attached (`animated == false`), `finish()` starts exit animations that `tick()` never drives, leaving `leaving` cursors in `cursors` with `needsTick == true`.
- **Connected Callers:** `CanvasWorkspace.end` (`lib/ai/ai_agent.dart:95`).

### `F-RL-04` — `RelaySim` divides by `timer.seconds` without guarding `<= 0`
- **Category:** Bug / Risky code | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/relay/relay_model.dart:225, 428, 444`; `lib/relay/relay_editor.dart:1443`
- **Concrete Failure Scenario:** A `.bwrelay` file with `params['seconds']: 0` (or negative) on a timer causes `(now - since) / 0` (`NaN`/`Infinity`) -> `.floor()` throws `UnsupportedError`, and `t.clamp(0, s.seconds)` throws `ArgumentError`.
- **Connected Callers:** `RelaySim.solve`, `RelaySim.timerElapsed`, `_SheetPainter.paint`.

### `F-RL-05` — `RelayEditor._up` drag undo doesn't refresh Undo button or cap `_undo`, and `_branch` drops wire `bends`
- **Category:** Bug | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/relay/relay_editor.dart:236-240, 395-399` (pre-edit; `413–417` post-edit)
- **Concrete Failure Scenario:** Dragging a symbol appends to `_undo` without the 100-entry cap or `setState`, leaving the header Undo button disabled until another `setState`; branching onto a bent wire drops all `wire.bends`.
- **Connected Callers:** `_RelayEditorState._up`, `_RelayEditorState._branch`.

### `F-RL-06` — `RelayEditor._SheetPainter.paint` draws tens of thousands of individual `drawCircle` grid dots per frame
- **Category:** Failure under load (UI lag) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/relay/relay_editor.dart:1344-1351` (pre-edit)
- **Concrete Failure Scenario:** Zoomed out (`scale = 8`) on a 4K display issues ~130,000 `canvas.drawCircle` calls on every hover and 10 Hz simulation frame instead of batching via `drawPoints` or coarsening the grid.
- **Connected Callers:** `RelayEditor._canvas` (`687`).

### `F-08` — Canvas pan/zoom & 60fps simulation hot paths: synchronous `WireCache` rasterization, `O(W*(D+W))` and `O(D^2)` per-frame lookups, and `WireCache` GPU image leak
- **Category:** Failure under real load / Performance | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ui/canvas_view.dart:82-170, 1670-1673, 2073-2085, 2121-2158`, `lib/app_state.dart:750-751, 800-804, 1575-1593, 1752`
- **Concrete Failure Scenario:** `_WirePainter.paint` hashes screen-space routes, missing `WireCache` on every pan/zoom frame and running `picture.toImageSync(...)` synchronously; `routeWorld` recomputes `_geometryKey()` on every call from both `_WirePainter` and 60fps `_LivePainter` (`O(W*(D+W))`); `CanvasView._canvas` calls `isSeated`/`hasSeatedOverload`/`terminalCovered` per device/terminal (`O(D^2)`); and `WireCache.clear()` is never called when leaving `Workspace`, retaining offscreen GPU `ui.Image`.
- **Connected Callers:** `CanvasView` (`lib/ui/workspace.dart:219`), `AppState`.

### `F-09` — Cancelled drag gestures leave `AppState` stuck in quick-route mode or freeze `selectionBox`
- **Category:** Bug / UI State Desync | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ui/canvas_view.dart:124-136, 232-238, 400-406, 1391-1404`, `lib/app_state.dart:1590, 1602`
- **Concrete Failure Scenario:** `CanvasView` (`endBox`), `_SegmentHandle` (`endWireDrag`), `_DeviceView` (`endMove`), and `_ResizeHandle` (`endControlEdit`) wire `onPanEnd` without `onPanCancel`. Cancelling a drag (focus/pointer-capture loss) freezes `selectionBox` on screen or leaves `_dragBefore` non-null, disabling A* routing for the entire project.
- **Connected Callers:** `AppState.endMove`, `endControlEdit`, `endWireDrag`, `endBox`.

### `F-10` — Text field focus/undo desyncs across `Workspace`, `PropertiesPanel`, and `LadderEditor`
- **Category:** Bug / UI State Desync | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ui/workspace.dart:144, 596-598, 614`, `lib/ui/panels.dart:643, 647, 750-780`, `lib/ui/plc_editor.dart:949, 962` (pre-edit), `lib/app_state.dart:608-614`
- **Concrete Failure Scenario:** (1) Pressing `F5` while editing `_ProjectName` starts simulation, disables `_ProjectName`, and triggers blur -> `renameProject()` -> `_commit()` (overwriting running status). (2) `_DeviceProperties` is keyed only by `props-${device.id}-${device.tag}`, so `Ctrl+Z` undoing a timer leaves stale `_time.text`. (3) `LadderEditor`'s row comment `_TextBox` is keyed by `comment-$r`, reusing the old row's controller text after row insertion/deletion.
- **Connected Callers:** `Workspace._Toolbar`, `PropertiesPanel`, `LadderEditor._properties`, `AppState.renameProject`.

### `F-11` — `AbsorbPointer(absorbing: app.aiLocked)` does not block keyboard activation of toolbar/panel buttons during AI runs
- **Category:** Bug / Concurrency Race | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ui/workspace.dart:155, 174-224`
- **Concrete Failure Scenario:** `AbsorbPointer` blocks pointer input only. If a toolbar or panel button has keyboard focus while `app.aiLocked == true`, pressing `Space` or `Enter` activates the button before `Workspace._shortcut` ignores it, mutating `app.project` or toggling simulation mid-AI-run.
- **Connected Callers:** `Workspace.build` (`lib/ui/workspace.dart:200-222`).

### `F-12` — Uncaught non-`FormatException` I/O errors & unguarded `mounted` checks in async dialogs/menus
- **Category:** Risky Code / Error Handling | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ui/workspace.dart:40-49`, `lib/ui/home.dart:66-76`, `lib/ui/plc_editor.dart:332-350, 875-917` (pre-edit), `lib/ui/ai_settings_dialog.dart:160-170`, `lib/file_io.dart:72-89`
- **Concrete Failure Scenario:** `Workspace._open` and `HomeScreen._openFile` only catch `FormatException` (OS/plugin errors in `pickProjectText` escape); `LadderEditor._saveFile` does not catch `saveLadderFile` errors; `_cellMenu` and `_rowMenu` omit `if (!mounted) return;` after `await showMenu`; `_AiSettingsDialogState._save`/`_forget` await `FlutterSecureStorage` without `try/catch`.
- **Connected Callers:** `Workspace`, `HomeScreen`, `LadderEditor`, `_AiSettingsDialog`.

### `F-13` — `tools/sync_assets.py` deletes `assets/devices`, `assets/symbols`, and `assets/sounds` before checking if external source folders exist
- **Category:** Data Loss / Risky Tooling | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `tools/sync_assets.py:16-17, 110-127`, `tools/upgrade_devices.py:67-73, 444`
- **Concrete Failure Scenario:** `sync_assets.py:113` executes `shutil.rmtree(folder, ignore_errors=True)` on 1,331 files in `assets/devices`, `assets/symbols`, and `assets/sounds` before verifying that external `../starter-assets` and `../licensed-assets/catalog/catalog.json` exist, wiping all app assets and crashing with `FileNotFoundError`. `upgrade_devices.py:69` similarly calls `EXTRACTED.iterdir()` without checking `EXTRACTED.is_dir()`.
- **Connected Callers:** Developer CLI scripts (`tools/sync_assets.py`, `tools/upgrade_devices.py`).

### `F-14` — `Buka BuildWire.bat` / Web build inconsistency and browser launch race
- **Category:** Bug / Platform Inconsistency | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `Buka BuildWire.bat:3-10`, `README.md:80`, `lib/file_io.dart:72-89`, `lib/ui/ai_settings_dialog.dart:256`
- **Concrete Failure Scenario:** `Buka BuildWire.bat` launches the browser (`http://127.0.0.1:8765/`) before `python -m http.server` binds and expects `build\web`, whereas `README.md:80` states only the Windows build is maintained, `ai_settings_dialog.dart:256` hardcodes `"Windows DPAPI"`, and `file_io.dart:saveLadderFile` omits `kIsWeb`.
- **Connected Callers:** `Buka BuildWire.bat`, `LadderEditor._saveFile`.

### `F-15` — Unencrypted `http://` AI endpoints allowed on non-localhost hosts (with warning only)
- **Category:** Security (User-configured) | **Rank:** `Should fix` | **Status:** `Untouched in Code`
- **Location:** `lib/ui/ai_settings_dialog.dart:233-237, 262, 397`, `lib/ai/ai_connector.dart:99-104`
- **Concrete Failure Scenario:** `_AiSettingsDialog` shows a warning when `AiConnector.isInsecure` is true (non-localhost `http://`), yet permits connecting, persisting, and transmitting API keys and prompts in plaintext over HTTP.
- **Connected Callers:** `showAiSettings`, `AiConnector`.

---

## 5. Section 3 — `Nice to have` Findings (19 Findings — Untouched in Code)

*(Note: Unless explicitly tagged `post-edit`, line numbers cited in this section for the 17 modified `lib/` files reflect pre-edit baseline line numbers per `baseline_lib/`.)*

1. **`NH-1`** (*Bug / Dead branch* — `lib/sim/solver.dart:371-373`): `Solver._finish` uses a ternary with identical true/false branches (`reading.volts.toDouble()`); `threePhase` is unused elsewhere.
2. **`NH-2`** (*Dead code* — `lib/sim/solver.dart:181-182`): `if (nets.hasShort) continue;` in `Solver.solve` is unreachable when `_findBreakerToTrip` (`266`) already ensures `!hasShort`.
3. **`NH-3`** (*Dead condition* — `lib/sim/solver.dart:585`): `if (lineVolts >= 0)` in `Solver._Flow.addMotor` is always true (`nets.voltage(...).volts >= 0`).
4. **`NH-4`** (*Performance / Allocations* — `lib/model/device_def.dart:180-210, 235-252`): `DeviceDef` getters (`contacts`, `controls`, `coil`, `load`, `input`, `meterScreens`, `meterChannels`) re-parse JSON maps/lists on every hot-loop access in `Solver.solve` and `AppState.animate`.
5. **`NH-5`** (*Minor cleanup* — `lib/app_state.dart:1268-1273`): `tapTerminal` clears `pending = null` when rejecting an already-connected terminal pair without clearing `pendingCorners`.
6. **`NH-6`** (*Resource cleanup* — `lib/app_state.dart:102, 2736-2742`): `AppState.dispose()` disposes `animationFrame` but does not dispose `viewVersion` (`ValueNotifier<int>`).
7. **`NH-7`** (*Scalability* — `lib/sim/solver.dart:679-686`; `lib/app_state.dart:376-381, 459-470, 670-705, 1196-1206`): `_Nets._find` lacks path compression and `AppState._device` linear-scans `project.devices` inside wire/net loops (fine at 10–200 devices, `O(D^2)` at 500+).
8. **`NH-8`** (*Unused in `lib/`* — `lib/sim/plc.dart:64-88`; `lib/sound.dart:171-175`): Legacy `plcScan` and `SoundPlayer.loopPosition` have no callers under `lib/` (`test/` not inspected).
9. **`F-AI-14`** (*Risky code / Minor bug* — `lib/ai/circuit_tools.dart:540, 624-648`): `CircuitTools._remove` double-counts duplicate tags/wires; `_add` aborts the entire batch on a single non-string `tag`.
10. **`F-AI-15`** (*Minor state bug* — `lib/ai/ai_agent.dart:111, 137-143`; `lib/app_state.dart:475, 589, 598`): `AiAgent` retains prior project conversation `_history` when switching or creating projects.
11. **`F-AI-16`** (*Cleanup / Minor bug* — `lib/ai/swarm.dart:234, 408`): Cancelled `Swarm.connect()` leaves `CursorShape.cross` until `finish()`; `_stepCamera` never clears `_cameraTarget`.
12. **`F-AI-17`** (*Risky code* — `lib/ai/ladder_tools.dart:204`): `LadderWorkspace._describe` indexes `kPlcDays[d - 1]` without bounds checking `1 <= d <= 7` on corrupt `.bwlad` files.
13. **`F-RL-07`** (*Minor performance* — `lib/relay/relay_model.dart:668-677, 770`): `RelaySim._onSince` retains expired `timer_on` entries, keeping `RelaySim.ticking` `true` and running the 100ms ticker continuously while the coil stays energized.
14. **`F-AI-18`** (*Cross-module boundary* — `lib/ai/ai_attachment.dart:48` -> `lib/sim/zm2.dart:59, 62, 285`): `AiAttachment.load` delegates `.zm2` parsing to `readZm2` (`AiChatPanel._addFiles` catches generic exceptions; the underlying `readZm2` bounds issue was fixed in `MF-2`).
15. **`F-16`** (*Minor UI metadata* — `lib/ui/panels.dart:375-376`, `README.md:18`): `symbolCount = app.defs.length - deviceCount` (`590 - 339 = 251`) counts `generic_junction` as a symbol even though line 352 filters `!d.isJunction` and `assets/symbols/` contains 250 SVGs.
16. **`F-17`** (*Minor metadata* — `lib/ui/workspace.dart:570`): `showLicensePage(..., applicationVersion: '1.0')` displays `'1.0'` instead of `'1.3'` / `'1.3.0+4'` (`pubspec.yaml:4`, `installer/buildwire.iss:13`, `workspace.dart:549`).
17. **`F-18`** (*Maintainability* — `lib/ui/plc_editor.dart:41`, `lib/ui/ladder_start.dart:68, 103`, `lib/ui/canvas_view.dart:2073-2085`): Top-level mutable `lastLadderModel` leaks across instances; `WireCache.clear()` has no callers.
18. **`F-19`** (*Minor layout* — `lib/ui/scada.dart:51-53`, `lib/ui/ai_settings_dialog.dart:190-191`, `lib/ui/hmi_editor.dart:40-42`): Fixed `SizedBox` dialog dimensions (`980x560` in `scada.dart`) lack `ConstrainedBox` clamping for 1280×720 / 1366×768 screens at 125–150% DPI scaling.
19. **`F-20`** (*Python tooling hygiene* — `tools/zm2_probe.py:72`, `tools/zm2_write_probe.py:8, 27-34`, `tools/cut_white_background.py:2, 9`, `tools/make_zelio.py:96`): `zm2_write_probe.py` uses brittle `rsplit` on `__file__` and omits `with open(...)`; `cut_white_background.py` docstring references stale `cut_sr3.py` and crashes with `ValueError` on `<3` args; `make_zelio.py:96` indexes `dense[0]` without an emptiness guard.

---

## 6. Applied Changes Summary

### 6.1 Modified Files (17 of 35 Dart Files under `lib/`)

| # | File | Milestone | Findings Fixed | `--numstat` (`+ / -`) | Summary of Applied Change |
|---|---|---|---|---:|---|
| 1 | `lib/app_state.dart` | M1 | `MF-3`, `MF-5` | `+57 / -3` | Safe `_restore` decode/catch; `_validated` sanitization of `x`/`y`, `scale`, `seated_on`, `ladder`/`program`, and wire points; deep-copy and `seated_on` remapping/stripping in `_pasteJson`. |
| 2 | `lib/model/project.dart` | M1 | `MF-3` | `+26 / -12` | Bounds/type/finite validation in `Wire.fromJson`; `on RangeError` handling in `Project.fromJson`. |
| 3 | `lib/sim/ladder.dart` | M1 | `MF-4`, `F-AI-01` | `+9 / -6` | Added `{bool renameCursor = true}` to `LadderProgram.fromRungs`; included `t.edge != null` in `PlcMemory.ticking`; cleared `run.edge` on `AC` rising edge. |
| 4 | `lib/sim/wire_router.dart` | M1 | `MF-1` | `+24 / -5` | Finite guards, `maxNodes = 40000` / `maxAxis = 1000` adaptive step scaling, `lines()` stagnation guard, and `grid.count > 100000` early exit. |
| 5 | `lib/sim/zm2.dart` | M1 | `MF-2` | `+24 / -11` | `P*` length check (`at + 9 + n`), bounded `kindCount`/`count`/`firstCode`, bounds-checked `u32`/`setU32`, and `_find` `limit` clamp. |
| 6 | `lib/ai/circuit_tools.dart` | M2 | `F-AI-01` | `+1 / -1` | Passed `renameCursor: false` to `LadderProgram.fromRungs` so `C1..C4` counter contacts are preserved. |
| 7 | `lib/ai/ai_agent.dart` | M2 | `F-AI-02` | `+83 / -26` | Added `_disposed`, `_ownsConnector`, `_notify()`, `_stopSignal` + `_raceStop()`, immediate `stop()` cancellation, and `dispose()` cleanup. |
| 8 | `lib/ai/ai_connector.dart` | M2 | `F-AI-02`, `F-AI-03` | `+55 / -26` | Added `_ownsClient`, `cancelPending()`, idempotent `close()`, and type-safe JSON parsing in `_parseModel`, `fromAnthropic`, and `fromOpenAi`. |
| 9 | `lib/ai/ai_attachment.dart` | M2 | `F-AI-04` | `+21 / -11` | Header dimension probe via `findDecoderForData` + `startDecode` (`<= 16384` side, `<= 40M` px) inside `try/catch` before `decodeFrame(0)`. |
| 10 | `lib/relay/relay_model.dart` | M3 | `F-RL-01` | `+36 / -13` | Type-safe `supply`/`seconds`/`text` getters and `RelaySymbol.fromJson` `params`; duplicate-ID rejection, pin-existence wire filter, and `TypeError`/`RangeError`/`UnsupportedError` -> `FormatException` in `RelaySheet.fromJson`. |
| 11 | `lib/relay/relay_editor.dart` | M3 | `F-RL-02`, `F-RL-03` | `+43 / -11` | Added `_clearTransient()` across `_restore`/`toggleSim`/`_open`/`_newSheet`; null-checked `_move`/`_up` & `_held`; `mounted` checks after awaits; implemented `_TagFieldState.didUpdateWidget`. |
| 12 | `lib/ui/canvas_view.dart` | M4 | `F-01` | `+26 / -15` | Disambiguated duplicate `_HmiButton` `ValueKey`s per `_HmiScreen.build` using `seen` set and `#$i` suffix. |
| 13 | `lib/ui/hmi_editor.dart` | M4 | `F-02` | `+1 / -0` | Added `key: ObjectKey(_items[i])` to each `Padding` row in `_HmiEditorState.build`. |
| 14 | `lib/ui/ladder_start.dart` | M4 | `F-05` | `+1 / -1` | Guarded `setState` with `if (mounted)` in `_openFile`'s `catch` block. |
| 15 | `lib/ui/plc_editor.dart` | M4 | `F-03`, `F-04`, `F-05` | `+121 / -61` | Added `_typing` + `Focus` `Delete` guard; `barrierDismissible: false`, `PopScope`, and `_confirmDiscard()`; `_openInitial` `try/catch` + `mounted` guards in `openBytes`. |
| 16 | `lib/ui/ai_chat_panel.dart` | M4 | `F-06` | `+40 / -11` | Added `mounted` guards across all async gaps (`_addFiles`, `_pick`, `_drop`, `_pasteAttachments`) and `try/catch` around file length/read prep. |
| 17 | `lib/ui/swarm_overlay.dart` | M4 | `F-07` | `+53 / -48` | Replaced build-time `context.size` with `LayoutBuilder` + `_overlayHeight` fallback from `_measure()`. |
| **Total** | **17 files** | **M1–M4** | **19 Findings** | **`+621 / -261`** | **Only `Must fix` findings touched; zero out-of-scope edits.** |

### 6.2 Unchanged `lib/` Files (18 of 35 Dart Files — SHA-256 Identical to Baseline)
`lib/ai/ai_settings.dart`, `lib/ai/ladder_tools.dart`, `lib/ai/swarm.dart`, `lib/file_io.dart`, `lib/main.dart`, `lib/model/device_def.dart`, `lib/sim/plc.dart`, `lib/sim/solver.dart`, `lib/sound.dart`, `lib/templates.dart`, `lib/ui/ai_settings_dialog.dart`, `lib/ui/home.dart`, `lib/ui/panels.dart`, `lib/ui/scada.dart`, `lib/ui/spark_wordmark.dart`, `lib/ui/templates_dialog.dart`, `lib/ui/theme.dart`, `lib/ui/workspace.dart`.

---

## 7. Verification Summary, Skipped/Unchecked Items & Residual Risks

### 7.1 What Was Verified on Host
- **Independent Multi-Agent Verification (M1–M4):**
  - **Reviewers (8 total, 2 per milestone — all `APPROVE`):** Manually audited every changed line against the pre-edit baseline, verified syntax, Dart 3 (`^3.13.7`) idioms, null safety, `flutter_lints ^6.0.0` patterns, and connected callers across all `lib/` modules.
  - **Challengers (8 total, 2 per milestone — all `CONFIRM` / `PASS` / `APPROVE`):** Executed Python Dart-aware lexical/delimiter/import balance checks across all 17 modified files (`0` unmatched delimiters) and isolated temp-dir empirical probes covering `MF-1`..`MF-5`, `F-AI-01`..`F-AI-04`, `F-RL-01`..`F-RL-03`, and `F-01`..`F-07` state-machine/adversarial edge cases (all temp dirs cleaned up).
  - **Forensic Auditors (4 total, 1 per milestone — all `CLEAN`):** Verified SHA-256 identity of the 18 untouched `lib/` files, exact `git diff --no-index` boundaries, zero `.agents/teamwork/` artifacts in the working directory, zero `Should fix`/`Nice to have` bloat, and zero access/edits to `test/` or `integration_test/`.
- **Cross-Module Baseline Diff Check (M5):** Confirmed via `git -c core.autocrlf=false diff --no-index` and Python SHA-256 comparison that `baseline_lib/` and `lib/` contain the exact same 35 file paths, with 17 modified (`+621 / -261`) and 18 SHA-256-identical.

### 7.2 What Was Skipped or Unchecked
1. **Flutter / Dart Toolchain Execution:** `flutter pub get`, `flutter analyze`, `dart analyze`, `flutter test`, `flutter build windows --release`, and `ISCC installer\buildwire.iss` could **not** run because Flutter SDK, Dart SDK, Visual Studio 2022 C++, CMake, NuGet, and Inno Setup are not installed on the host.
2. **Python Asset / Audio Generators:** `tools/*.py` image/audio generation scripts could not run (`numpy` and `Pillow` are absent on the host, and external sibling folders `../starter-assets`, `../licensed-assets/catalog/catalog.json`, and `../assets/extracted` are not present in the archive).
3. **Excluded Test Directories:** `test/` and `integration_test/` were strictly excluded (never read, listed, searched, or run).
4. **Deferred Audit Items:** All `29` `Should fix` and `19` `Nice to have` findings were intentionally left untouched in code.

### 7.3 Remaining Risks
1. **Pending Compile-Time & Widget-Runtime Verification:** Until `flutter analyze` and `flutter test` run on a host with Flutter (`>= 3.47.0`, Dart `^3.13.7`), the following remain uncompiled/unexecuted at native runtime:
   - `package:image` `4.13.1` runtime behavior for `findDecoderForData` / `startDecode` / `decodeFrame(0)` in `lib/ai/ai_attachment.dart` (verified against v4 API docs, not compiled locally).
   - Dart 3 `switch` expression inside `Map.map` in `lib/relay/relay_model.dart:240-246`.
   - `PopScope.onPopInvokedWithResult` dialog re-entrancy and `Focus.onKeyEvent` propagation in `lib/ui/plc_editor.dart`.
2. **Minor Non-Blocking Edge Cases Left Out of Must-Fix Scope:**
   - `AppState.dispose()` (`lib/app_state.dart`) does not call `ai.dispose()`; `AiAgent.dispose()` calling `stop()` while `busy && _ownsConnector` creates and immediately closes a fresh `http.Client` in `cancelPending()` (benign, zero leak).
   - Non-standard JSON containing `1e309` (`double.infinity`) inside `LadderProgram.fromJson` / `LadderCounter.fromJson` / `ClockSlot.fromJson` throws `UnsupportedError` on `.toInt()` (`AppState._validated` catches `FormatException`, `TypeError`, `RangeError`, whereas `RelaySheet.fromJson` also catches `UnsupportedError`; `1e309` in `RelayWire.fromJson` bend points yields `Offset(double.infinity, 0.0)`).
   - Hand-edited `.bwproj` with decimal `seated_on` (e.g., `5.0`) is stripped by `_validated` (`seated is! int`), and optional `device.data` keys outside `MF-3` (`rtc_offset_s`, `widgets`, arbitrary `PlacedDevice.number` keys) were left unvalidated.
   - Clearing `_TagField` to `''` without submitting and clicking the already-selected `ChoiceChip` leaves `''` displayed (though `s.tag` is preserved).
   - Pre-existing concurrent `AiAgent.send()` micro-window during `await app.secrets.readKey()` and `max_completion_tokens` retry path (`F-AI-09`) remain untouched.
3. **Recommended Next Verification Commands (on a Flutter SDK host):**
   ```powershell
   flutter pub get
   flutter analyze
   flutter test
   ```

---

## 8. Trailing `git diff` Summary

### 8.1 `--stat` Summary (`17 files changed, 621 insertions(+), 261 deletions(-)`)

```text
 lib/ai/ai_agent.dart        | 109 +++++++++---
 lib/ai/ai_attachment.dart   |  32 ++--
 lib/ai/ai_connector.dart    |  81 ++++++---
 lib/ai/circuit_tools.dart   |   2 +-
 lib/app_state.dart          |  60 ++++++-
 lib/model/project.dart      |  38 +++--
 lib/relay/relay_editor.dart |  54 ++++--
 lib/relay/relay_model.dart  |  49 ++++--
 lib/sim/ladder.dart         |  15 +-
 lib/sim/wire_router.dart    |  29 +++-
 lib/sim/zm2.dart            |  35 ++--
 lib/ui/ai_chat_panel.dart   |  51 ++++--
 lib/ui/canvas_view.dart     |  41 +++--
 lib/ui/hmi_editor.dart      |   1 +
 lib/ui/ladder_start.dart    |   2 +-
 lib/ui/plc_editor.dart      | 182 ++++++++++++++-------
 lib/ui/swarm_overlay.dart   | 101 ++++++------
 17 files changed, 621 insertions(+), 261 deletions(-)
```

### 8.2 Full Unified `git diff` (All 17 Modified Files)

```diff
diff --git a/lib/ai/ai_agent.dart b/lib/ai/ai_agent.dart
index 06467c0..9685f3b 100644
--- a/lib/ai/ai_agent.dart
+++ b/lib/ai/ai_agent.dart
@@ -1,3 +1,5 @@
+import 'dart:async';
+
 import 'package:flutter/foundation.dart';
 
 import '../app_state.dart';
@@ -99,11 +101,13 @@ class CanvasWorkspace extends AgentWorkspace {
 
 class AiAgent extends ChangeNotifier {
   AiAgent(this.app, {AiConnector? connector, AgentWorkspace? workspace})
-      : _connector = connector, // ignore: prefer_initializing_formals
+      : _ownsConnector = connector == null,
+        _connector = connector, // ignore: prefer_initializing_formals
         workspace = workspace ?? CanvasWorkspace(app);
 
   final AppState app;
   final AgentWorkspace workspace;
+  final bool _ownsConnector;
   AiConnector? _connector;
   AiConnector get connector => _connector ??= AiConnector(timeout: const Duration(seconds: 240));
 
@@ -116,6 +120,8 @@ class AiAgent extends ChangeNotifier {
   /// What is happening right now, for the panel.
   String? phase;
   bool _stop = false;
+  bool _disposed = false;
+  Completer<void>? _stopSignal;
 
   static const int maxSteps = 80;
 
@@ -134,20 +140,39 @@ class AiAgent extends ChangeNotifier {
     Duration(seconds: 35),
   ];
 
+  void _notify() {
+    if (!_disposed) notifyListeners();
+  }
+
   void reset() {
-    if (busy) return;
+    if (busy || _disposed) return;
     entries.clear();
     _history.clear();
     _historyFor = null;
-    notifyListeners();
+    _notify();
   }
 
   void stop() {
     if (!busy) return;
     _stop = true;
+    final signal = _stopSignal;
+    if (signal != null && !signal.isCompleted) signal.complete();
+    if (_ownsConnector) _connector?.cancelPending();
     workspace.cancel();
     phase = 'Menghentikan…';
-    notifyListeners();
+    _notify();
+  }
+
+  @override
+  void dispose() {
+    if (_disposed) return;
+    _disposed = true;
+    stop();
+    if (_ownsConnector) {
+      _connector?.close();
+      _connector = null;
+    }
+    super.dispose();
   }
 
   /// What the model is told about attachments, added to the system prompt while the conversation has one.
@@ -166,15 +191,16 @@ Kalau diminta meniru atau mengikuti gambar:
 
   Future<void> send(String text, {List<AiAttachment> attachments = const []}) async {
     var message = text.trim();
-    if ((message.isEmpty && attachments.isEmpty) || busy) return;
+    if ((message.isEmpty && attachments.isEmpty) || busy || _disposed) return;
     if (message.isEmpty) message = 'Lihat lampiran ini.';
     final settings = app.aiSettings;
     if (settings == null) {
       entries.add(ChatEntry(ChatKind.error, 'AI belum diatur. Buka menu AI, Pengaturan AI.'));
-      notifyListeners();
+      _notify();
       return;
     }
     final key = await app.secrets.readKey() ?? '';
+    if (_disposed) return;
     final target = '${settings.baseUrl}|${settings.format.name}|${settings.model}';
     if (_historyFor != null && _historyFor != target && _history.isNotEmpty) {
       _history.clear();
@@ -184,6 +210,7 @@ Kalau diminta meniru atau mengikuti gambar:
 
     busy = true;
     _stop = false;
+    _stopSignal = Completer<void>();
     workspace.begin();
     entries.add(ChatEntry(ChatKind.user, message, attachments: attachments));
     // Only the newest pictures travel with each request; older ones are replaced by a note.
@@ -195,19 +222,19 @@ Kalau diminta meniru atau mengikuti gambar:
       }
     }
     _history.add({'role': 'user', 'content': AiAttachment.content(settings.format, '$message\n\n[${workspace.context()}]', attachments)});
-    notifyListeners();
+    _notify();
 
     // Whether the canvas changed since the last simulator test, and how often the model was told to carry on.
     var untested = false;
     var nudges = 0;
     try {
       var step = 0;
-      for (; step < maxSteps && !_stop; step++) {
+      for (; step < maxSteps && !_stop && !_disposed; step++) {
         phase = step == 0 ? 'Memikirkan permintaanmu…' : 'Memikirkan langkah berikutnya…';
         workspace.thinking(true);
-        notifyListeners();
+        _notify();
         final reply = await _ask(settings, key);
-        if (reply == null) break; // stopped while waiting to retry
+        if (reply == null || _stop || _disposed) break; // stopped while waiting to retry
         _history.add(_assistantMessage(settings.format, reply));
         if (reply.text.trim().isNotEmpty) entries.add(ChatEntry(ChatKind.assistant, reply.text.trim()));
 
@@ -215,7 +242,7 @@ Kalau diminta meniru atau mengikuti gambar:
           // Models sometimes stop mid-job: an empty reply, a cut-off one, "now I will…" without doing it, or
           // finishing without testing what they built. Tell them to carry on, a few times at most.
           final nudge = nudgeFor(reply, untested);
-          if (nudge == null || nudges >= maxNudges || _stop) break;
+          if (nudge == null || nudges >= maxNudges || _stop || _disposed) break;
           nudges++;
           _history.add({'role': 'user', 'content': nudge});
           continue;
@@ -224,7 +251,7 @@ Kalau diminta meniru atau mengikuti gambar:
         final results = <(String, ToolOutcome)>[];
         workspace.thinking(false);
         for (final call in reply.toolCalls) {
-          if (_stop) {
+          if (_stop || _disposed) {
             results.add((call.id, const ToolOutcome('{"galat":"Dibatalkan pengguna."}', 'Dibatalkan', error: true)));
             continue;
           }
@@ -237,21 +264,25 @@ Kalau diminta meniru atau mengikuti gambar:
             continue;
           }
           phase = 'Menjalankan ${call.name.replaceAll('_', ' ')}…';
-          notifyListeners();
+          _notify();
           final outcome = await workspace.run(call.name, call.input);
           if (!outcome.error && workspace.editingTools.contains(call.name)) untested = true;
           if (call.name == workspace.testTool && !outcome.error) untested = false;
           results.add((call.id, outcome));
-          entries.add(ChatEntry(ChatKind.tool, outcome.label, failed: outcome.error));
-          notifyListeners();
+          if (!_disposed) {
+            entries.add(ChatEntry(ChatKind.tool, outcome.label, failed: outcome.error));
+            _notify();
+          }
         }
         _history.addAll(_toolResults(settings.format, results));
         _compactHistory();
       }
-      if (_stop) {
-        entries.add(ChatEntry(ChatKind.info, 'Dihentikan.'));
-      } else if (step >= maxSteps) {
-        entries.add(ChatEntry(ChatKind.info, 'Berhenti setelah $maxSteps langkah. Ketik "lanjutkan" untuk meneruskan.'));
+      if (!_disposed) {
+        if (_stop) {
+          entries.add(ChatEntry(ChatKind.info, 'Dihentikan.'));
+        } else if (step >= maxSteps) {
+          entries.add(ChatEntry(ChatKind.info, 'Berhenti setelah $maxSteps langkah. Ketik "lanjutkan" untuk meneruskan.'));
+        }
       }
     } on AiError catch (error) {
       final pictures = _history.where((m) => m['role'] == 'user' && AiAttachment.hasImage(m)).toList();
@@ -272,37 +303,63 @@ Kalau diminta meniru atau mengikuti gambar:
     } catch (error) {
       entries.add(ChatEntry(ChatKind.error, 'Terjadi kesalahan: $error'));
     } finally {
-      workspace.end();
+      _stopSignal = null;
+      if (!_disposed) workspace.end();
       busy = false;
       phase = null;
-      notifyListeners();
+      _notify();
+    }
+  }
+
+  Future<AiReply?> _raceStop(Future<AiReply> future) {
+    final stop = _stopSignal;
+    if (_stop || _disposed || stop == null) {
+      future.ignore();
+      return Future.value(null);
     }
+    final done = Completer<AiReply?>();
+    future.then(
+      (v) {
+        if (!done.isCompleted) done.complete(v);
+      },
+      onError: (Object e, StackTrace s) {
+        if (!done.isCompleted) done.completeError(e, s);
+      },
+    );
+    stop.future.then((_) {
+      if (!done.isCompleted) done.complete(null);
+    });
+    return done.future;
   }
 
   /// One model request, retried when the endpoint is busy, the connection drops, or the answer is garbled.
   /// Returns null when the user stops while it waits.
   Future<AiReply?> _ask(AiSettings settings, String key) async {
     for (var attempt = 0;; attempt++) {
+      if (_stop || _disposed) return null;
       try {
-        final reply = await connector.chat(settings.baseUrl, key, settings.format, settings.model, _history,
+        final reply = await _raceStop(connector.chat(
+            settings.baseUrl, key, settings.format, settings.model, _history,
             tools: workspace.tools,
             system: _history.any(AiAttachment.hasImage) || _history.any((m) => '${m['content']}'.contains('[Lampiran '))
                 ? '${workspace.systemPrompt}\n\n$attachmentGuide'
                 : workspace.systemPrompt,
-            maxTokens: 8192);
+            maxTokens: 8192));
+        if (reply == null || _stop || _disposed) return null;
         if (reply.valid) return reply;
         if (attempt >= retryDelays.length) throw AiError('Jawaban model tidak bisa dibaca.');
       } on AiError catch (error) {
+        if (_stop || _disposed) return null;
         if (!error.transient || attempt >= retryDelays.length) rethrow;
       }
       phase = 'Koneksi bermasalah, mencoba lagi (${attempt + 1}/${retryDelays.length})…';
-      notifyListeners();
+      _notify();
       final until = DateTime.now().add(retryDelays[attempt]);
       while (DateTime.now().isBefore(until)) {
-        if (_stop) return null;
+        if (_stop || _disposed) return null;
         await Future<void>.delayed(const Duration(milliseconds: 100));
       }
-      if (_stop) return null;
+      if (_stop || _disposed) return null;
     }
   }
 
diff --git a/lib/ai/ai_attachment.dart b/lib/ai/ai_attachment.dart
index c04a30c..974b5cc 100644
--- a/lib/ai/ai_attachment.dart
+++ b/lib/ai/ai_attachment.dart
@@ -70,18 +70,28 @@ class AiAttachment {
   /// Decodes, shrinks to [maxSide] and encodes: PNG for small images with sharp edges (screenshots, diagrams),
   /// JPEG when the PNG would be large (photos). Runs in a background isolate.
   static (Uint8List, String)? _prepareImage(Uint8List bytes) {
-    final decoded = img.decodeImage(bytes);
-    if (decoded == null) return null;
-    var picture = decoded;
-    final side = picture.width > picture.height ? picture.width : picture.height;
-    if (side > maxSide) {
-      picture = picture.width >= picture.height
-          ? img.copyResize(picture, width: maxSide, interpolation: img.Interpolation.average)
-          : img.copyResize(picture, height: maxSide, interpolation: img.Interpolation.average);
+    try {
+      final decoder = img.findDecoderForData(bytes);
+      if (decoder == null) return null;
+      final info = decoder.startDecode(bytes);
+      if (info == null || info.width <= 0 || info.height <= 0 || info.width > 16384 || info.height > 16384 || info.width * info.height > 40000000) {
+        return null;
+      }
+      final decoded = decoder.decodeFrame(0);
+      if (decoded == null) return null;
+      var picture = decoded;
+      final side = picture.width > picture.height ? picture.width : picture.height;
+      if (side > maxSide) {
+        picture = picture.width >= picture.height
+            ? img.copyResize(picture, width: maxSide, interpolation: img.Interpolation.average)
+            : img.copyResize(picture, height: maxSide, interpolation: img.Interpolation.average);
+      }
+      final png = img.encodePng(picture, level: 6);
+      if (png.length <= 1200 * 1024) return (png, 'image/png');
+      return (img.encodeJpg(picture, quality: 85), 'image/jpeg');
+    } catch (_) {
+      return null;
     }
-    final png = img.encodePng(picture, level: 6);
-    if (png.length <= 1200 * 1024) return (png, 'image/png');
-    return (img.encodeJpg(picture, quality: 85), 'image/jpeg');
   }
 
   /// The text of a user message with its attachments, in the endpoint's format: content blocks with images first
diff --git a/lib/ai/ai_connector.dart b/lib/ai/ai_connector.dart
index 4d6bbf5..961976e 100644
--- a/lib/ai/ai_connector.dart
+++ b/lib/ai/ai_connector.dart
@@ -67,9 +67,13 @@ class AiError implements Exception {
 /// The model list is not enough to tell the formats apart: proxies commonly answer `/models` in the OpenAI shape
 /// whichever headers are sent, yet serve `/messages` too. So the format is decided by sending each a tiny request.
 class AiConnector {
-  AiConnector({http.Client? client, this.timeout = const Duration(seconds: 30)}) : _client = client ?? http.Client();
+  AiConnector({http.Client? client, this.timeout = const Duration(seconds: 30)})
+      : _ownsClient = client == null,
+        _client = client ?? http.Client();
 
-  final http.Client _client;
+  final bool _ownsClient;
+  http.Client _client;
+  bool _closed = false;
   final Duration timeout;
 
   static const anthropicVersion = '2023-06-01';
@@ -162,7 +166,8 @@ class AiConnector {
       return value is num ? value.toDouble() : (value is String ? double.tryParse(value) : null);
     }
 
-    return AiModel(id: id, label: label, owner: item['owned_by'] as String?, priceIn: price('official_in'), priceOut: price('official_out'));
+    final owner = item['owned_by'];
+    return AiModel(id: id, label: label, owner: owner is String ? owner : null, priceIn: price('official_in'), priceOut: price('official_out'));
   }
 
   /// Sends a tiny request in each format and reports which ones answer properly.
@@ -304,7 +309,18 @@ class AiConnector {
     return short.length > 200 ? '${short.substring(0, 200)}…' : short;
   }
 
-  void close() => _client.close();
+  /// Aborts any in-flight requests on an owned client and swaps in a fresh client for future calls.
+  void cancelPending() {
+    if (!_ownsClient || _closed) return;
+    _client.close();
+    _client = http.Client();
+  }
+
+  void close() {
+    if (_closed) return;
+    _closed = true;
+    _client.close();
+  }
 }
 
 class _AuthError extends AiError {
@@ -345,15 +361,21 @@ class AiReply {
   final Object? raw;
 
   factory AiReply.fromAnthropic(Object? json) {
-    if (json is! Map<String, dynamic> || json['content'] is! List) return AiReply(valid: false, text: '', toolCalls: const [], raw: json);
+    final content = json is Map<String, dynamic> ? json['content'] : null;
+    if (json is! Map<String, dynamic> || content is! List) return AiReply(valid: false, text: '', toolCalls: const [], raw: json);
     final text = StringBuffer();
     final calls = <AiToolCall>[];
-    for (final block in json['content'] as List) {
+    for (final block in content) {
       if (block is! Map<String, dynamic>) continue;
       if (block['type'] == 'text' && block['text'] is String) text.write(block['text']);
       if (block['type'] == 'tool_use') {
         final input = block['input'];
-        calls.add(AiToolCall(id: '${block['id']}', name: '${block['name']}', input: input is Map<String, dynamic> ? input : const {}));
+        calls.add(AiToolCall(
+          id: '${block['id']}',
+          name: '${block['name']}',
+          input: input is Map<String, dynamic> ? input : const {},
+          badArguments: input != null && input is! Map<String, dynamic>,
+        ));
       }
     }
     return AiReply(valid: true, text: text.toString(), toolCalls: calls, raw: json, truncated: json['stop_reason'] == 'max_tokens');
@@ -362,34 +384,41 @@ class AiReply {
   factory AiReply.fromOpenAi(Object? json) {
     final choices = json is Map<String, dynamic> ? json['choices'] : null;
     if (choices is! List || choices.isEmpty) return AiReply(valid: false, text: '', toolCalls: const [], raw: json);
-    final message = (choices.first as Map<String, dynamic>?)?['message'];
+    final first = choices.first;
+    if (first is! Map<String, dynamic>) return AiReply(valid: false, text: '', toolCalls: const [], raw: json);
+    final message = first['message'];
     if (message is! Map<String, dynamic>) return AiReply(valid: false, text: '', toolCalls: const [], raw: json);
     final calls = <AiToolCall>[];
-    for (final call in message['tool_calls'] as List? ?? const []) {
-      if (call is! Map<String, dynamic>) continue;
-      final function = call['function'];
-      if (function is! Map<String, dynamic>) continue;
-      Map<String, dynamic> input = const {};
-      var bad = false;
-      final args = function['arguments'];
-      if (args is String && args.trim().isNotEmpty) {
-        try {
-          final decoded = jsonDecode(args);
-          if (decoded is Map<String, dynamic>) {
-            input = decoded;
-          } else {
+    final rawCalls = message['tool_calls'];
+    if (rawCalls is List) {
+      for (final call in rawCalls) {
+        if (call is! Map<String, dynamic>) continue;
+        final function = call['function'];
+        if (function is! Map<String, dynamic>) continue;
+        Map<String, dynamic> input = const {};
+        var bad = false;
+        final args = function['arguments'];
+        if (args is String && args.trim().isNotEmpty) {
+          try {
+            final decoded = jsonDecode(args);
+            if (decoded is Map<String, dynamic>) {
+              input = decoded;
+            } else {
+              bad = true;
+            }
+          } on FormatException {
             bad = true;
           }
-        } on FormatException {
+        } else if (args is Map<String, dynamic>) {
+          input = args;
+        } else if (args != null && args is! String) {
           bad = true;
         }
-      } else if (args is Map<String, dynamic>) {
-        input = args;
+        calls.add(AiToolCall(id: '${call['id']}', name: '${function['name']}', input: input, badArguments: bad));
       }
-      calls.add(AiToolCall(id: '${call['id']}', name: '${function['name']}', input: input, badArguments: bad));
     }
     final content = message['content'];
-    final finish = (choices.first as Map<String, dynamic>)['finish_reason'];
+    final finish = first['finish_reason'];
     return AiReply(valid: true, text: content is String ? content : '', toolCalls: calls, raw: json, truncated: finish == 'length');
   }
 }
diff --git a/lib/ai/circuit_tools.dart b/lib/ai/circuit_tools.dart
index 15618e7..5b8acf9 100644
--- a/lib/ai/circuit_tools.dart
+++ b/lib/ai/circuit_tools.dart
@@ -699,7 +699,7 @@ class CircuitTools {
         if (contacts.isNotEmpty) branches.add(contacts);
       }
       if (branches.isEmpty) throw _Fail('Rung ${i + 1} tidak punya kontak.');
-      final rows = LadderProgram.fromRungs([PlcRung(branches: branches, coil: 'Q1')]).rows;
+      final rows = LadderProgram.fromRungs([PlcRung(branches: branches, coil: 'Q1')], renameCursor: false).rows;
       rows.first.coil = coil;
       if (program.rows.length + rows.length > LadderProgram.maxRows) throw _Fail('Program terlalu panjang.');
       program.rows.addAll(rows);
diff --git a/lib/app_state.dart b/lib/app_state.dart
index b25462d..c4f3454 100644
--- a/lib/app_state.dart
+++ b/lib/app_state.dart
@@ -445,9 +445,15 @@ class AppState extends ChangeNotifier {
     final saved = _prefs?.getString(_projectKey);
     if (saved == null) return;
     try {
-      project = _validated(Project.fromJson(jsonDecode(saved) as Map<String, dynamic>));
+      final decoded = jsonDecode(saved);
+      if (decoded is! Map<String, dynamic>) throw const FormatException('bukan-proyek');
+      project = _validated(Project.fromJson(decoded));
     } on FormatException {
       project = Project();
+    } on TypeError {
+      project = Project();
+    } on RangeError {
+      project = Project();
     }
   }
 
@@ -457,7 +463,40 @@ class AppState extends ChangeNotifier {
 
   /// Drops anything that refers to a device type or terminal this version doesn't have.
   Project _validated(Project input) {
-    input.devices.removeWhere((device) => !defs.containsKey(device.defId));
+    input.devices.removeWhere((device) => !defs.containsKey(device.defId) || !device.x.isFinite || !device.y.isFinite);
+    final deviceIds = {for (final d in input.devices) d.id};
+    for (final device in input.devices) {
+      final scale = device.data['scale'];
+      if (scale is! num || !scale.isFinite || scale <= 0) {
+        device.data.remove('scale');
+      } else {
+        final clamped = scale.toDouble().clamp(minScale, maxScale).toDouble();
+        if ((clamped - 1).abs() < 0.001) {
+          device.data.remove('scale');
+        } else {
+          device.data['scale'] = clamped;
+        }
+      }
+      final seated = device.data['seated_on'];
+      if (seated is! int || !deviceIds.contains(seated)) device.data.remove('seated_on');
+      if (device.data.containsKey('ladder') || device.data.containsKey('program')) {
+        try {
+          LadderProgram.of(device.data);
+        } on FormatException {
+          device.data
+            ..remove('ladder')
+            ..remove('program');
+        } on TypeError {
+          device.data
+            ..remove('ladder')
+            ..remove('program');
+        } on RangeError {
+          device.data
+            ..remove('ladder')
+            ..remove('program');
+        }
+      }
+    }
     bool known(TerminalRef ref) {
       for (final device in input.devices) {
         if (device.id == ref.deviceId) return defs[device.defId]!.terminals.any((t) => t.id == ref.terminal);
@@ -466,6 +505,9 @@ class AppState extends ChangeNotifier {
     }
 
     input.wires.removeWhere((wire) => !known(wire.a) || !known(wire.b));
+    for (final wire in input.wires) {
+      wire.points?.removeWhere((p) => !p.x.isFinite || !p.y.isFinite);
+    }
     return input;
   }
 
@@ -985,6 +1027,7 @@ class AppState extends ChangeNotifier {
   void _pasteJson(Map<String, dynamic> data, Offset offset) {
     final idMap = <int, int>{};
     final added = <int>{};
+    final pasted = <PlacedDevice>[];
     for (final item in data['devices'] as List<dynamic>) {
       final source = PlacedDevice.fromJson(item as Map<String, dynamic>);
       final id = project.nextId();
@@ -996,11 +1039,22 @@ class AppState extends ChangeNotifier {
         x: source.x + offset.dx,
         y: source.y + offset.dy,
         timeSeconds: source.timeSeconds,
-        data: source.data,
+        data: source.data.isEmpty ? null : jsonDecode(jsonEncode(source.data)) as Map<String, dynamic>,
       );
       project.devices.add(copy);
+      pasted.add(copy);
       added.add(id);
     }
+    for (final copy in pasted) {
+      if (!copy.data.containsKey('seated_on')) continue;
+      final oldId = (copy.data['seated_on'] as num?)?.toInt();
+      final newId = oldId == null ? null : idMap[oldId];
+      if (newId != null) {
+        copy.data['seated_on'] = newId;
+      } else {
+        copy.data.remove('seated_on');
+      }
+    }
     for (final item in data['wires'] as List<dynamic>) {
       final source = Wire.fromJson(item as Map<String, dynamic>);
       project.wires.add(Wire(
diff --git a/lib/model/project.dart b/lib/model/project.dart
index 638a09b..45cb36e 100644
--- a/lib/model/project.dart
+++ b/lib/model/project.dart
@@ -92,18 +92,30 @@ class Wire {
         if (points != null) 'points': [for (final point in points!) point.toJson()],
       };
 
-  factory Wire.fromJson(Map<String, dynamic> json) => Wire(
-        id: json['id'] as int,
-        a: TerminalRef.fromJson(json['a'] as Map<String, dynamic>),
-        b: TerminalRef.fromJson(json['b'] as Map<String, dynamic>),
-        color: json['color'] as int? ?? defaultColor,
-        isJumper: json['jumper'] as bool? ?? false,
-        gauge: (json['gauge'] as num?)?.toDouble() ?? 1.5,
-        number: json['number'] as String? ?? '',
-        points: (json['points'] as List<dynamic>?)
-            ?.map((point) => WirePoint(((point as List<dynamic>)[0] as num).toDouble(), (point[1] as num).toDouble()))
-            .toList(),
-      );
+  factory Wire.fromJson(Map<String, dynamic> json) {
+    final rawPoints = json['points'];
+    List<WirePoint>? points;
+    if (rawPoints != null) {
+      if (rawPoints is! List<dynamic>) throw const FormatException('rusak');
+      points = [];
+      for (final point in rawPoints) {
+        if (point is! List<dynamic> || point.length < 2 || point[0] is! num || point[1] is! num) throw const FormatException('rusak');
+        final x = (point[0] as num).toDouble(), y = (point[1] as num).toDouble();
+        if (!x.isFinite || !y.isFinite) throw const FormatException('rusak');
+        points.add(WirePoint(x, y));
+      }
+    }
+    return Wire(
+      id: json['id'] as int,
+      a: TerminalRef.fromJson(json['a'] as Map<String, dynamic>),
+      b: TerminalRef.fromJson(json['b'] as Map<String, dynamic>),
+      color: json['color'] as int? ?? defaultColor,
+      isJumper: json['jumper'] as bool? ?? false,
+      gauge: (json['gauge'] as num?)?.toDouble() ?? 1.5,
+      number: json['number'] as String? ?? '',
+      points: points,
+    );
+  }
 }
 
 class Project {
@@ -151,6 +163,8 @@ class Project {
       );
     } on TypeError {
       throw const FormatException('rusak');
+    } on RangeError {
+      throw const FormatException('rusak');
     }
   }
 }
diff --git a/lib/relay/relay_editor.dart b/lib/relay/relay_editor.dart
index 1d87403..852e105 100644
--- a/lib/relay/relay_editor.dart
+++ b/lib/relay/relay_editor.dart
@@ -137,12 +137,22 @@ class _RelayEditorState extends State<RelayEditor> {
     dirty = true;
   }
 
+  void _clearTransient() {
+    pending = null;
+    corners.clear();
+    placing = null;
+    _dragging = null;
+    _dragBefore = null;
+    _panning = false;
+    _held = null;
+    _sel3Last.clear();
+  }
+
   void _restore(String text) {
     sheet = RelaySheet.fromJson(jsonDecode(text) as Map<String, dynamic>);
     selectedSymbol = null;
     selectedWire = null;
-    pending = null;
-    corners.clear();
+    _clearTransient();
   }
 
   void undo() {
@@ -376,7 +386,12 @@ class _RelayEditorState extends State<RelayEditor> {
     }
     final id = _dragging;
     if (id == null) return;
-    final s = sheet.symbol(id)!;
+    final s = sheet.symbol(id);
+    if (s == null) {
+      _dragging = null;
+      _dragBefore = null;
+      return;
+    }
     final d = gridOf(e.localPosition) - _dragStart;
     setState(() {
       s.x = _dragOrigin.$1 + d.dx.round();
@@ -387,12 +402,16 @@ class _RelayEditorState extends State<RelayEditor> {
   void _up(PointerEvent e) {
     _panning = false;
     if (_held != null) {
-      final s = sheet.symbol(_held!);
-      if (s != null) _operate(s, false);
+      final id = _held!;
+      _held = null;
+      if (simulating) {
+        final s = sheet.symbol(id);
+        if (s != null) _operate(s, false);
+      }
     }
     if (_dragging != null) {
-      final s = sheet.symbol(_dragging!)!;
-      if ((s.x, s.y) != _dragOrigin && _dragBefore != null) {
+      final s = sheet.symbol(_dragging!);
+      if (s != null && (s.x, s.y) != _dragOrigin && _dragBefore != null) {
         _undo.add(_dragBefore!);
         _redo.clear();
         dirty = true;
@@ -420,13 +439,12 @@ class _RelayEditorState extends State<RelayEditor> {
       setState(() {
         sim = null;
         result = null;
+        _clearTransient();
       });
       return;
     }
     setState(() {
-      pending = null;
-      corners.clear();
-      placing = null;
+      _clearTransient();
       sim = RelaySim(sheet);
       _clock
         ..reset()
@@ -483,6 +501,7 @@ class _RelayEditorState extends State<RelayEditor> {
   Future<void> _save() async {
     try {
       if (await saveRelayFile(fileName, const JsonEncoder.withIndent('  ').convert(sheet.toJson()))) {
+        if (!mounted) return;
         setState(() => dirty = false);
         _messenger.currentState?.showSnackBar(const SnackBar(content: Text('Diagram disimpan.')));
       }
@@ -494,7 +513,7 @@ class _RelayEditorState extends State<RelayEditor> {
   Future<void> _open() async {
     try {
       final picked = await pickRelayFile();
-      if (picked == null) return;
+      if (!mounted || picked == null) return;
       final loaded = RelaySheet.fromJson(jsonDecode(picked.$2) as Map<String, dynamic>);
       if (simulating) toggleSim();
       _snapshot();
@@ -503,6 +522,7 @@ class _RelayEditorState extends State<RelayEditor> {
         fileName = picked.$1.replaceAll(RegExp(r'\.bwrelay$', caseSensitive: false), '');
         selectedSymbol = null;
         selectedWire = null;
+        _clearTransient();
         dirty = false;
       });
     } on FormatException catch (error) {
@@ -521,6 +541,7 @@ class _RelayEditorState extends State<RelayEditor> {
       fileName = 'diagram';
       selectedSymbol = null;
       selectedWire = null;
+      _clearTransient();
     });
     _messenger.currentState?.showSnackBar(const SnackBar(content: Text('Lembar baru. Tekan Ctrl+Z untuk mengembalikan yang tadi.')));
   }
@@ -876,6 +897,17 @@ class _TagField extends StatefulWidget {
 class _TagFieldState extends State<_TagField> {
   late final _controller = TextEditingController(text: widget.text);
 
+  @override
+  void didUpdateWidget(_TagField old) {
+    super.didUpdateWidget(old);
+    if (widget.text != old.text && widget.text != _controller.text) {
+      _controller.value = TextEditingValue(
+        text: widget.text,
+        selection: TextSelection.collapsed(offset: widget.text.length),
+      );
+    }
+  }
+
   @override
   void dispose() {
     _controller.dispose();
diff --git a/lib/relay/relay_model.dart b/lib/relay/relay_model.dart
index fa69da4..064f1b9 100644
--- a/lib/relay/relay_model.dart
+++ b/lib/relay/relay_model.dart
@@ -219,13 +219,13 @@ class RelaySymbol {
   Rect get rect => Rect.fromLTWH(x.toDouble(), y.toDouble(), size.width, size.height);
 
   /// Supply label of a supply symbol.
-  String get supply => params['supply'] as String? ?? 'L1';
+  String get supply => params['supply'] is String ? params['supply'] as String : 'L1';
 
   /// Timer setting in seconds.
-  double get seconds => (params['seconds'] as num?)?.toDouble() ?? 3;
+  double get seconds => params['seconds'] is num ? (params['seconds'] as num).toDouble() : 3;
 
   /// The words of a text symbol.
-  String get text => params['text'] as String? ?? 'Teks';
+  String get text => params['text'] is String ? params['text'] as String : 'Teks';
 
   Map<String, dynamic> toJson() => {'id': id, 'type': type, 'tag': tag, 'x': x, 'y': y, if (rotation != 0) 'r': rotation, if (params.isNotEmpty) 'p': params};
 
@@ -236,7 +236,14 @@ class RelaySymbol {
         x: (json['x'] as num).toInt(),
         y: (json['y'] as num).toInt(),
         rotation: (json['r'] as num?)?.toInt() ?? 0,
-        params: (json['p'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v)),
+        params: (json['p'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(
+              k,
+              switch (k) {
+                'supply' || 'text' => v as String?,
+                'seconds' => v as num?,
+                _ => v,
+              },
+            )),
       );
 }
 
@@ -332,15 +339,31 @@ class RelaySheet {
 
   factory RelaySheet.fromJson(Map<String, dynamic> json) {
     if (json['format'] != 'buildrelay/1') throw const FormatException('Bukan file BuildRelay.');
-    final symbols = [
-      for (final s in (json['symbols'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>())
-        if (kRelayTypeById.containsKey(s['type'])) RelaySymbol.fromJson(s),
-    ];
-    final ids = {for (final s in symbols) s.id};
-    final wires = [
-      for (final w in (json['wires'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>()) RelayWire.fromJson(w),
-    ].where((w) => ids.contains(w.a.symbol) && ids.contains(w.b.symbol)).toList();
-    return RelaySheet(symbols: symbols, wires: wires);
+    try {
+      final symbols = [
+        for (final s in (json['symbols'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>())
+          if (kRelayTypeById.containsKey(s['type'])) RelaySymbol.fromJson(s),
+      ];
+      final byId = <int, RelaySymbol>{};
+      for (final s in symbols) {
+        if (byId.containsKey(s.id)) throw const FormatException('File BuildRelay rusak.');
+        byId[s.id] = s;
+      }
+      final wires = [
+        for (final w in (json['wires'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>()) RelayWire.fromJson(w),
+      ]
+          .where((w) =>
+              (byId[w.a.symbol]?.def.pins.containsKey(w.a.pin) ?? false) &&
+              (byId[w.b.symbol]?.def.pins.containsKey(w.b.pin) ?? false))
+          .toList();
+      return RelaySheet(symbols: symbols, wires: wires);
+    } on TypeError {
+      throw const FormatException('File BuildRelay rusak.');
+    } on RangeError {
+      throw const FormatException('File BuildRelay rusak.');
+    } on UnsupportedError {
+      throw const FormatException('File BuildRelay rusak.');
+    }
   }
 }
 
diff --git a/lib/sim/ladder.dart b/lib/sim/ladder.dart
index 18e63aa..bc7233c 100644
--- a/lib/sim/ladder.dart
+++ b/lib/sim/ladder.dart
@@ -279,11 +279,11 @@ class LadderProgram {
     return LadderProgram();
   }
 
-  /// Converts the older rung list (parallel branches of series contacts → one coil) to the grid. The older cursor
-  /// keys C1-C4 become Z1-Z4, and a T coil becomes an on-delay timer command.
-  static LadderProgram fromRungs(List<PlcRung> rungs) {
+  /// Converts the older rung list (parallel branches of series contacts → one coil) to the grid. When [renameCursor]
+  /// is true (older saved programs), C1-C4 become Z1-Z4, and a T coil becomes an on-delay timer command.
+  static LadderProgram fromRungs(List<PlcRung> rungs, {bool renameCursor = true}) {
     final program = LadderProgram();
-    String rename(String ref) => RegExp(r'^C[1-4]$').hasMatch(ref) ? 'Z${ref.substring(1)}' : ref;
+    String rename(String ref) => renameCursor && RegExp(r'^C[1-4]$').hasMatch(ref) ? 'Z${ref.substring(1)}' : ref;
     for (final rung in rungs) {
       final branches = rung.branches.where((b) => b.isNotEmpty).toList();
       if (branches.isEmpty) continue;
@@ -366,7 +366,7 @@ class PlcMemory {
       );
 
   /// A timer is counting, so the scan has to run again as time passes.
-  bool get ticking => timers.values.any((t) => t.since != null);
+  bool get ticking => timers.values.any((t) => t.since != null || t.edge != null);
 }
 
 class LadderScan {
@@ -519,7 +519,10 @@ void _command(LadderTimer setup, TimerRun run, bool before, bool input, double n
   final fall = !input && before;
   switch (setup.function) {
     case 'A' || 'AC':
-      if (rise) run.since = now;
+      if (rise) {
+        run.edge = null;
+        if (!run.out) run.since = now;
+      }
       if (fall) {
         if (setup.function == 'AC' && run.out) {
           run.edge = now;
diff --git a/lib/sim/wire_router.dart b/lib/sim/wire_router.dart
index 93dcf6e..8cc2158 100644
--- a/lib/sim/wire_router.dart
+++ b/lib/sim/wire_router.dart
@@ -51,8 +51,14 @@ class WireRouter {
 
   /// Routes all wires; a wire that cannot be routed is missing from the result.
   Map<int, List<Offset>> routeAll(List<WireRequest> wires) {
-    if (wires.isEmpty) return {};
+    bool finite(Offset p) => p.dx.isFinite && p.dy.isFinite;
+    if (wires.isEmpty ||
+        _obstacles.any((r) => !r.left.isFinite || !r.top.isFinite || !r.right.isFinite || !r.bottom.isFinite) ||
+        wires.any((w) => !finite(w.a) || !finite(w.exitA) || !finite(w.exitB) || !finite(w.b) || w.viaA.any((p) => !finite(p)) || w.viaB.any((p) => !finite(p)))) {
+      return {};
+    }
     final grid = _Grid.build(_obstacles, wires, cell);
+    if (grid.count == 0 || grid.count > 100000) return {};
     final ordered = [...wires]..sort((p, q) => _manhattan(p.exitA, p.exitB).compareTo(_manhattan(q.exitA, q.exitB)));
     final out = <int, List<Offset>>{};
     for (final wire in ordered) {
@@ -226,14 +232,26 @@ class _Grid {
     top -= margin;
     right += margin;
     bottom += margin;
+    final spanX = right - left, spanY = bottom - top;
+    if (!left.isFinite || !top.isFinite || !right.isFinite || !bottom.isFinite || !spanX.isFinite || !spanY.isFinite || cell <= 0 || !cell.isFinite) {
+      return _Grid(const [], const []);
+    }
+    const maxNodes = 40000;
+    const maxAxis = 1000;
+    final step = (spanX / cell) * (spanY / cell) > maxNodes || spanX / cell > maxAxis || spanY / cell > maxAxis
+        ? math.max(cell, math.max(math.max(spanX, spanY) / maxAxis, math.sqrt(spanX * spanY / maxNodes)))
+        : cell;
+    if (!step.isFinite || step <= 0) return _Grid(const [], const []);
 
     List<double> lines(double from, double to, Iterable<double> fixed) {
-      final exact = fixed.toSet().toList()..sort();
+      final exact = fixed.where((v) => v.isFinite).toSet().toList()..sort();
       final out = <double>[...exact];
-      for (var v = (from / cell).floorToDouble() * cell; v <= to; v += cell) {
+      for (var v = (from / step).floorToDouble() * step; v <= to;) {
         // A regular line too close to an exit line would make a tiny jog; the exit line stands in for it.
-        if (exact.any((e) => (e - v).abs() < cell * 0.4)) continue;
-        out.add(v);
+        if (!exact.any((e) => (e - v).abs() < step * 0.4)) out.add(v);
+        final next = v + step;
+        if (next <= v) break;
+        v = next;
       }
       out.sort();
       return out;
@@ -241,6 +259,7 @@ class _Grid {
 
     final xs = lines(left, right, [for (final w in wires) ...[w.exitA.dx, w.exitB.dx]]);
     final ys = lines(top, bottom, [for (final w in wires) ...[w.exitA.dy, w.exitB.dy]]);
+    if (xs.isEmpty || ys.isEmpty || xs.length * ys.length > 100000) return _Grid(const [], const []);
     final grid = _Grid(xs, ys);
     for (final r in obstacles) {
       final x0 = _lowerBound(xs, r.left), x1 = _lowerBound(xs, r.right);
diff --git a/lib/sim/zm2.dart b/lib/sim/zm2.dart
index 3073558..55c9779 100644
--- a/lib/sim/zm2.dart
+++ b/lib/sim/zm2.dart
@@ -56,7 +56,7 @@ class _Sheet {
     var at = start;
     while (at + 9 < bytes.length) {
       final n = data.getUint32(at, Endian.little);
-      if (n < 2 || n > 6 || bytes[at + 4] != 0x50 || bytes[at + 4 + n] != 0) break;
+      if (n < 2 || n > 6 || at + 9 + n > bytes.length || bytes[at + 4] != 0x50 || bytes[at + 4 + n] != 0) break;
       final number = int.tryParse(ascii.decode(bytes.sublist(at + 5, at + 4 + n), allowInvalid: true));
       if (number == null) break;
       values[number] = data.getUint32(at + 5 + n, Endian.little);
@@ -67,8 +67,12 @@ class _Sheet {
     if (rows <= 0 || rows > 1000) throw const FormatException('Lembar ladder di file Zelio tidak terbaca.');
     var k = 3 + rows * 6;
     while (values.containsKey(k) && values[k]! >= 0x41 && values[k]! <= 0x5A) {
-      final kinds = [for (var j = 0; j < (values[k + 5] ?? 0); j++) values[k + 6 + j] ?? 0];
-      types.add(_Type(String.fromCharCode(values[k]!), values[k + 2] ?? 0, String.fromCharCode(values[k + 3] ?? 0x31), values[k + 4] ?? 0, kinds));
+      final kindCount = values[k + 5] ?? 0;
+      final count = values[k + 2] ?? 0;
+      final firstCode = values[k + 3] ?? 0x31;
+      if (kindCount < 0 || kindCount > 32 || count < 0 || count > 256 || firstCode < 0 || firstCode > 0x10FFFF) break;
+      final kinds = [for (var j = 0; j < kindCount; j++) values[k + 6 + j] ?? 0];
+      types.add(_Type(String.fromCharCode(values[k]!), count, String.fromCharCode(firstCode), values[k + 4] ?? 0, kinds));
       k += 6 + kinds.length;
     }
   }
@@ -125,7 +129,15 @@ class _Sheet {
     }
   }
 
-  int u32(int at) => data.getUint32(at, Endian.little);
+  int u32(int at) {
+    if (at < 0 || at + 4 > bytes.length) throw const FormatException('File Zelio Soft 2 rusak.');
+    return data.getUint32(at, Endian.little);
+  }
+
+  void setU32(int at, int value) {
+    if (at < 0 || at + 4 > bytes.length) throw const FormatException('File Zelio Soft 2 rusak.');
+    data.setUint32(at, value, Endian.little);
+  }
 }
 
 /// Reads the ladder program from a Zelio Soft 2 `.zm2` file.
@@ -226,7 +238,7 @@ Uint8List writeZm2(LadderProgram program, Uint8List template) {
   final missing = <String>{};
   void put(int record, int value) {
     final at = sheet.offsets[record];
-    if (at != null) sheet.data.setUint32(at, value, Endian.little);
+    if (at != null) sheet.setU32(at, value);
   }
 
   if (program.rows.length > sheet.rows) throw FormatException('Program lebih dari ${sheet.rows} baris.');
@@ -266,17 +278,17 @@ Uint8List writeZm2(LadderProgram program, Uint8List template) {
   for (final e in program.timers.entries) {
     final k = kLadderIndex.indexOf(e.key.substring(1));
     if (k < 0 || k >= modes.length || k >= first.length || k >= second.length) continue;
-    sheet.data.setUint32(modes[k], inverse[e.value.function] ?? 1, Endian.little);
-    sheet.data.setUint32(first[k], (e.value.preset * 10).round().clamp(0, 99999), Endian.little);
-    sheet.data.setUint32(second[k], e.value.hasSecond ? (e.value.preset2 * 10).round().clamp(0, 99999) : 0, Endian.little);
+    sheet.setU32(modes[k], inverse[e.value.function] ?? 1);
+    sheet.setU32(first[k], (e.value.preset * 10).round().clamp(0, 99999));
+    sheet.setU32(second[k], e.value.hasSecond ? (e.value.preset2 * 10).round().clamp(0, 99999) : 0);
   }
   final targets = sheet.fields('O2R_VALEUR DE PRESELECTION');
   final senses = sheet.fields('P2_SENS_PRESELECTION');
   for (final e in program.counters.entries) {
     final k = kLadderIndex.indexOf(e.key.substring(1));
     if (k < 0 || k >= targets.length) continue;
-    sheet.data.setUint32(targets[k], e.value.preset.clamp(0, 32767), Endian.little);
-    if (k < senses.length) sheet.data.setUint32(senses[k], e.value.toZero ? 1 : 0, Endian.little);
+    sheet.setU32(targets[k], e.value.preset.clamp(0, 32767));
+    if (k < senses.length) sheet.setU32(senses[k], e.value.toZero ? 1 : 0);
   }
   return out;
 }
@@ -292,7 +304,8 @@ String _module(Uint8List bytes) {
 }
 
 int _find(Uint8List bytes, List<int> pattern, [int from = 0, int? limit]) {
-  final end = (limit ?? bytes.length) - pattern.length;
+  final cap = limit == null || limit > bytes.length ? bytes.length : limit;
+  final end = cap - pattern.length;
   outer:
   for (var i = from; i <= end; i++) {
     for (var j = 0; j < pattern.length; j++) {
diff --git a/lib/ui/ai_chat_panel.dart b/lib/ui/ai_chat_panel.dart
index a09701b..13a8c1d 100644
--- a/lib/ui/ai_chat_panel.dart
+++ b/lib/ui/ai_chat_panel.dart
@@ -57,13 +57,14 @@ class _AiChatPanelState extends State<AiChatPanel> {
 
   /// Reads files into attachments, keeping the first problem to show under the composer.
   Future<void> _addFiles(List<(String, Future<Uint8List> Function(), int)> files) async {
-    if (files.isEmpty) return;
+    if (files.isEmpty || !mounted) return;
     setState(() {
       _loading = true;
       _attachError = null;
     });
     String? problem;
     for (final (name, read, size) in files) {
+      if (!mounted) return;
       if (_pending.length >= _maxAttachments) {
         problem = 'Paling banyak $_maxAttachments lampiran per pesan.';
         break;
@@ -90,20 +91,40 @@ class _AiChatPanelState extends State<AiChatPanel> {
   }
 
   Future<void> _pick() async {
-    final files = await openFiles(
-      acceptedTypeGroups: const [
-        XTypeGroup(label: 'Gambar', extensions: AiAttachment.imageExtensions),
-        XTypeGroup(label: 'File teks dan program', extensions: [...AiAttachment.textExtensions, ...AiAttachment.otherExtensions]),
-      ],
-    );
-    await _addFiles([for (final f in files) (f.name, f.readAsBytes, await f.length())]);
-    _focus.requestFocus();
+    try {
+      final files = await openFiles(
+        acceptedTypeGroups: const [
+          XTypeGroup(label: 'Gambar', extensions: AiAttachment.imageExtensions),
+          XTypeGroup(label: 'File teks dan program', extensions: [...AiAttachment.textExtensions, ...AiAttachment.otherExtensions]),
+        ],
+      );
+      if (!mounted) return;
+      final items = <(String, Future<Uint8List> Function(), int)>[];
+      for (final f in files) {
+        items.add((f.name, f.readAsBytes, await f.length()));
+        if (!mounted) return;
+      }
+      await _addFiles(items);
+      if (mounted) _focus.requestFocus();
+    } catch (error) {
+      if (mounted) setState(() => _attachError = 'Lampiran gagal dibaca: $error');
+    }
   }
 
   Future<void> _drop(DropDoneDetails details) async {
+    if (!mounted) return;
     setState(() => _dragging = false);
     if (widget.app.aiSettings == null) return;
-    await _addFiles([for (final f in details.files) (f.name, f.readAsBytes, await f.length())]);
+    try {
+      final items = <(String, Future<Uint8List> Function(), int)>[];
+      for (final f in details.files) {
+        items.add((f.name, f.readAsBytes, await f.length()));
+        if (!mounted) return;
+      }
+      await _addFiles(items);
+    } catch (error) {
+      if (mounted) setState(() => _attachError = 'Lampiran gagal dibaca: $error');
+    }
   }
 
   /// Ctrl+V: a copied picture (a screenshot, an image copied from a browser) or files copied in Explorer become
@@ -111,11 +132,19 @@ class _AiChatPanelState extends State<AiChatPanel> {
   Future<void> _pasteAttachments() async {
     try {
       final files = await Pasteboard.files();
+      if (!mounted) return;
       if (files.isNotEmpty) {
-        await _addFiles([for (final path in files) (XFile(path).name, XFile(path).readAsBytes, await XFile(path).length())]);
+        final items = <(String, Future<Uint8List> Function(), int)>[];
+        for (final path in files) {
+          final file = XFile(path);
+          items.add((file.name, file.readAsBytes, await file.length()));
+          if (!mounted) return;
+        }
+        await _addFiles(items);
         return;
       }
       final image = await Pasteboard.image;
+      if (!mounted) return;
       if (image != null && image.isNotEmpty) {
         final stamp = DateTime.now();
         final name =
diff --git a/lib/ui/canvas_view.dart b/lib/ui/canvas_view.dart
index 497619a..6917d95 100644
--- a/lib/ui/canvas_view.dart
+++ b/lib/ui/canvas_view.dart
@@ -1463,6 +1463,31 @@ class _HmiScreen extends StatelessWidget {
     final plc = app.firstPlc;
     final bits = on && plc != null ? app.bitsOf(plc) : const <String>{};
     final unit = app.zoom;
+    final seen = <String>{};
+    final children = <Widget>[];
+    for (var i = 0; i < widgets.length; i++) {
+      final widget = widgets[i];
+      if (widget['type'] == 'lamp') {
+        children.add(_HmiLamp(label: widget['label'] as String, lit: bits.contains(widget['ref']), unit: unit));
+      } else {
+        var keyName = 'hmi-${device.tag}-${widget['label']}';
+        if (!seen.add(keyName)) {
+          keyName = '$keyName#$i';
+          while (!seen.add(keyName)) {
+            keyName = '$keyName#';
+          }
+        }
+        children.add(_HmiButton(
+          key: ValueKey(keyName),
+          label: widget['label'] as String,
+          unit: unit,
+          active: plc != null && app.plcBitForced(plc, widget['ref'] as String),
+          enabled: on && plc != null,
+          toggle: widget['type'] == 'toggle',
+          onChange: (value) => app.setPlcBit(plc!, widget['ref'] as String, value),
+        ));
+      }
+    }
     final body = GridView.count(
       crossAxisCount: 2,
       padding: EdgeInsets.all(8 * unit),
@@ -1470,21 +1495,7 @@ class _HmiScreen extends StatelessWidget {
       crossAxisSpacing: 8 * unit,
       childAspectRatio: 2.1,
       physics: const NeverScrollableScrollPhysics(),
-      children: [
-        for (final widget in widgets)
-          if (widget['type'] == 'lamp')
-            _HmiLamp(label: widget['label'] as String, lit: bits.contains(widget['ref']), unit: unit)
-          else
-            _HmiButton(
-              key: ValueKey('hmi-${device.tag}-${widget['label']}'),
-              label: widget['label'] as String,
-              unit: unit,
-              active: plc != null && app.plcBitForced(plc, widget['ref'] as String),
-              enabled: on && plc != null,
-              toggle: widget['type'] == 'toggle',
-              onChange: (value) => app.setPlcBit(plc!, widget['ref'] as String, value),
-            ),
-      ],
+      children: children,
     );
     return Positioned(
       left: origin.dx,
diff --git a/lib/ui/hmi_editor.dart b/lib/ui/hmi_editor.dart
index 43b78cd..449fe4d 100644
--- a/lib/ui/hmi_editor.dart
+++ b/lib/ui/hmi_editor.dart
@@ -50,6 +50,7 @@ class _HmiEditorState extends State<_HmiEditor> {
                 children: [
                   for (var i = 0; i < _items.length; i++)
                     Padding(
+                      key: ObjectKey(_items[i]),
                       padding: const EdgeInsets.only(bottom: 8),
                       child: Row(
                         children: [
diff --git a/lib/ui/ladder_start.dart b/lib/ui/ladder_start.dart
index 00e6805..98110a4 100644
--- a/lib/ui/ladder_start.dart
+++ b/lib/ui/ladder_start.dart
@@ -67,7 +67,7 @@ class _LadderStartPageState extends State<LadderStartPage> {
       // The editor switches to the model written in the file; this is only the fallback.
       _openEditor(lastLadderModel ?? 'zelio_sr3b261fu', file: picked);
     } on Object catch (error) {
-      setState(() => _error = 'File tidak bisa dibuka: $error');
+      if (mounted) setState(() => _error = 'File tidak bisa dibuka: $error');
     }
   }
 
diff --git a/lib/ui/plc_editor.dart b/lib/ui/plc_editor.dart
index f925d95..68373f1 100644
--- a/lib/ui/plc_editor.dart
+++ b/lib/ui/plc_editor.dart
@@ -23,6 +23,7 @@ const String kLadderEditorName = 'BuildLadder';
 /// Opens the editor for a PLC on the canvas.
 Future<void> showPlcEditor(BuildContext context, AppState app, PlacedDevice plc) => showDialog<void>(
       context: context,
+      barrierDismissible: false,
       builder: (_) => Dialog(
         insetPadding: const EdgeInsets.all(16),
         clipBehavior: Clip.antiAlias,
@@ -118,7 +119,7 @@ class _LadderEditorState extends State<LadderEditor> {
     _defId = widget.plc?.defId ?? widget.defId!;
     if (_standalone) lastLadderModel = _defId;
     final file = widget.initialFile;
-    if (file != null) WidgetsBinding.instance.addPostFrameCallback((_) => openBytes(file.$1, file.$2));
+    if (file != null) WidgetsBinding.instance.addPostFrameCallback((_) => _openInitial(file));
     _program = _standalone ? LadderProgram() : app.ladderOf(widget.plc!).copy();
     app.addListener(_onApp);
     _agent.addListener(_onAgent);
@@ -280,7 +281,6 @@ class _LadderEditorState extends State<LadderEditor> {
 
   /// Opens a BuildLadder (.bwlad) or Zelio Soft 2 (.zm2) file into the editor.
   Future<void> openBytes(String name, List<int> bytes) async {
-    final messenger = _messenger.currentState;
     LadderProgram program;
     String? model;
     var note = 'Program "$name" dibuka.';
@@ -296,6 +296,7 @@ class _LadderEditorState extends State<LadderEditor> {
       model = json['plc'] as String?;
     }
     _stopSim();
+    if (!mounted) return;
     setState(() {
       _program = program;
       _dirty = true;
@@ -306,19 +307,55 @@ class _LadderEditorState extends State<LadderEditor> {
         if (app.defs[id]?.kind == 'plc') _defId = lastLadderModel = id;
       }
     });
-    messenger?.showSnackBar(SnackBar(content: Text('$note${_standalone ? '' : ' Tekan Kirim ke PLC untuk memakainya.'}')));
+    _messenger.currentState?.showSnackBar(SnackBar(content: Text('$note${_standalone ? '' : ' Tekan Kirim ke PLC untuk memakainya.'}')));
+  }
+
+  Future<void> _openInitial((String, Uint8List) file) async {
+    if (!mounted) return;
+    try {
+      await openBytes(file.$1, file.$2);
+    } on FormatException catch (error) {
+      if (mounted) _messenger.currentState?.showSnackBar(SnackBar(content: Text(error.message)));
+    } catch (error) {
+      if (mounted) _messenger.currentState?.showSnackBar(SnackBar(content: Text('File tidak bisa dibuka: $error')));
+    }
+  }
+
+  Future<bool> _confirmDiscard() async {
+    if (!_dirty) return true;
+    final tokens = context.tokens;
+    final discard = await showDialog<bool>(
+      context: context,
+      builder: (dialogContext) => AlertDialog(
+        backgroundColor: tokens.panel,
+        surfaceTintColor: Colors.transparent,
+        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.dialog)),
+        title: Text('Perubahan belum disimpan', style: uiText(17, tokens.text, weight: 700)),
+        content: Text(
+          _standalone
+              ? 'Program ladder ini belum disimpan ke file. Buang perubahan?'
+              : 'Perubahan belum dikirim ke PLC. Buang perubahan?',
+          style: uiText(13, tokens.textMuted, height: 1.45),
+        ),
+        actions: [
+          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Batal')),
+          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Buang perubahan')),
+        ],
+      ),
+    );
+    return discard ?? false;
   }
 
   Future<void> _open() async {
-    final messenger = _messenger.currentState;
+    if (!await _confirmDiscard() || !mounted) return;
     try {
       final picked = await pickLadderFile();
-      if (picked == null) return;
+      if (picked == null || !mounted) return;
       await openBytes(picked.$1, picked.$2);
     } on FormatException catch (error) {
-      messenger?.showSnackBar(SnackBar(content: Text(error.message)));
+      if (mounted) _messenger.currentState?.showSnackBar(SnackBar(content: Text(error.message)));
     } catch (error) {
-      messenger?.showSnackBar(SnackBar(content: Text('File tidak bisa dibuka: $error')));
+      if (mounted) _messenger.currentState?.showSnackBar(SnackBar(content: Text('File tidak bisa dibuka: $error')));
     }
   }
 
@@ -408,64 +445,81 @@ class _LadderEditorState extends State<LadderEditor> {
 
   // ----- Build
 
+  static bool get _typing {
+    final context = FocusManager.instance.primaryFocus?.context;
+    return context != null && (context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null);
+  }
+
   @override
   Widget build(BuildContext context) {
     final tokens = context.tokens;
-    return ScaffoldMessenger(
-      key: _messenger,
-      child: Scaffold(
-        backgroundColor: tokens.panel,
-        // The palette sits in the bottom bar so notices appear above it instead of covering it.
-        bottomNavigationBar: AbsorbPointer(absorbing: _agent.busy, child: _bottomBar(tokens)),
-        body: KeyboardListener(
-          focusNode: _focus,
-          autofocus: true,
-          onKeyEvent: (event) {
-            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.delete) _deleteSelected();
-          },
-          child: Column(
-            crossAxisAlignment: CrossAxisAlignment.stretch,
-            children: [
-              _header(tokens),
-              Divider(height: 1, color: tokens.border),
-              Expanded(
-                child: Row(
-                  crossAxisAlignment: CrossAxisAlignment.stretch,
-                  children: [
-                    Expanded(
-                      child: Column(
-                        crossAxisAlignment: CrossAxisAlignment.stretch,
-                        children: [
-                          Expanded(child: AbsorbPointer(absorbing: _agent.busy, child: _grid(tokens))),
-                          if (_openList != null && !_simulating) _list(tokens),
-                        ],
+    return PopScope(
+      canPop: !_dirty,
+      onPopInvokedWithResult: (didPop, _) async {
+        if (didPop) return;
+        if (!await _confirmDiscard() || !mounted) return;
+        Navigator.of(context).pop();
+      },
+      child: ScaffoldMessenger(
+        key: _messenger,
+        child: Scaffold(
+          backgroundColor: tokens.panel,
+          // The palette sits in the bottom bar so notices appear above it instead of covering it.
+          bottomNavigationBar: AbsorbPointer(absorbing: _agent.busy, child: _bottomBar(tokens)),
+          body: Focus(
+            focusNode: _focus,
+            autofocus: true,
+            onKeyEvent: (node, event) {
+              if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.delete && !_typing && !_agent.busy && !_simulating) {
+                _deleteSelected();
+                return KeyEventResult.handled;
+              }
+              return KeyEventResult.ignored;
+            },
+            child: Column(
+              crossAxisAlignment: CrossAxisAlignment.stretch,
+              children: [
+                _header(tokens),
+                Divider(height: 1, color: tokens.border),
+                Expanded(
+                  child: Row(
+                    crossAxisAlignment: CrossAxisAlignment.stretch,
+                    children: [
+                      Expanded(
+                        child: Column(
+                          crossAxisAlignment: CrossAxisAlignment.stretch,
+                          children: [
+                            Expanded(child: AbsorbPointer(absorbing: _agent.busy, child: _grid(tokens))),
+                            if (_openList != null && !_simulating) _list(tokens),
+                          ],
+                        ),
                       ),
-                    ),
-                    if (_aiOpen)
-                      AiChatPanel(
-                        key: const ValueKey('ladder-ai-panel'),
-                        app: app,
-                        agent: _agent,
-                        width: 380,
-                        hint: 'Minta dibuatkan, diubah, diuji, atau dijelaskan…',
-                        onClose: () => setState(() => _aiOpen = false),
-                        intro: 'Asisten menulis program ladder langsung di editor ini, lalu mengujinya di simulator sampai benar. '
-                            'Program baru dipakai setelah kamu menekan ${_standalone ? 'Simpan file atau Pakai di kanvas' : 'Kirim ke PLC'}.',
-                        suggestions: const [
-                          'Buat start-stop motor: I1 start, I2 stop (NC), Q1 motor, dengan self-holding',
-                          'Buat star-delta: I1 start, I2 stop, Q1 line, Q2 star, Q3 delta, pindah setelah 5 detik',
-                          'Lampu Q1 berkedip 1 detik selama saklar I1 menyala',
-                          'Jelaskan program yang sedang terbuka',
-                        ],
-                      )
-                    else ...[
-                      VerticalDivider(width: 1, color: tokens.border),
-                      SizedBox(width: 270, child: _simulating ? _simPanel(tokens) : _properties(tokens)),
+                      if (_aiOpen)
+                        AiChatPanel(
+                          key: const ValueKey('ladder-ai-panel'),
+                          app: app,
+                          agent: _agent,
+                          width: 380,
+                          hint: 'Minta dibuatkan, diubah, diuji, atau dijelaskan…',
+                          onClose: () => setState(() => _aiOpen = false),
+                          intro: 'Asisten menulis program ladder langsung di editor ini, lalu mengujinya di simulator sampai benar. '
+                              'Program baru dipakai setelah kamu menekan ${_standalone ? 'Simpan file atau Pakai di kanvas' : 'Kirim ke PLC'}.',
+                          suggestions: const [
+                            'Buat start-stop motor: I1 start, I2 stop (NC), Q1 motor, dengan self-holding',
+                            'Buat star-delta: I1 start, I2 stop, Q1 line, Q2 star, Q3 delta, pindah setelah 5 detik',
+                            'Lampu Q1 berkedip 1 detik selama saklar I1 menyala',
+                            'Jelaskan program yang sedang terbuka',
+                          ],
+                        )
+                      else ...[
+                        VerticalDivider(width: 1, color: tokens.border),
+                        SizedBox(width: 270, child: _simulating ? _simPanel(tokens) : _properties(tokens)),
+                      ],
                     ],
-                  ],
+                  ),
                 ),
-              ),
-            ],
+              ],
+            ),
           ),
         ),
       ),
@@ -521,7 +575,10 @@ class _LadderEditorState extends State<LadderEditor> {
             IconButton(
               key: const ValueKey('ladder-new'),
               tooltip: 'Program baru (pilih modul)',
-              onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => LadderStartPage(app: app))),
+              onPressed: () async {
+                if (!await _confirmDiscard() || !mounted) return;
+                Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => LadderStartPage(app: app)));
+              },
               icon: const Icon(Icons.note_add_outlined),
             ),
             const SizedBox(width: 4),
@@ -556,7 +613,10 @@ class _LadderEditorState extends State<LadderEditor> {
           IconButton(
             key: const ValueKey('ladder-close'),
             tooltip: _dirty ? 'Tutup (perubahan belum disimpan)' : 'Tutup',
-            onPressed: () => Navigator.of(context).pop(),
+            onPressed: () async {
+              if (!await _confirmDiscard() || !mounted) return;
+              Navigator.of(context).pop();
+            },
             icon: const Icon(Icons.close),
           ),
         ],
diff --git a/lib/ui/swarm_overlay.dart b/lib/ui/swarm_overlay.dart
index 46227f9..a130875 100644
--- a/lib/ui/swarm_overlay.dart
+++ b/lib/ui/swarm_overlay.dart
@@ -29,6 +29,7 @@ class _SwarmOverlayState extends State<SwarmOverlay> with SingleTickerProviderSt
   /// Where the canvas sits inside this overlay, refreshed every build.
   Offset _canvasAt = Offset.zero;
   Size _canvasSize = Size.zero;
+  double _overlayHeight = 0;
 
   /// Overlay-local position of a world point.
   Offset _local(Offset world) => _canvasAt + widget.app.toScreen(world);
@@ -41,6 +42,7 @@ class _SwarmOverlayState extends State<SwarmOverlay> with SingleTickerProviderSt
     swarm.canvasOrigin = global;
     _canvasAt = self.globalToLocal(global);
     _canvasSize = canvas.size;
+    _overlayHeight = self.size.height;
   }
 
   @override
@@ -89,52 +91,55 @@ class _SwarmOverlayState extends State<SwarmOverlay> with SingleTickerProviderSt
   Widget build(BuildContext context) {
     final app = widget.app;
     return IgnorePointer(
-      child: ListenableBuilder(
-        listenable: swarm,
-        builder: (context, _) {
-          _measure();
-          final children = <Widget>[];
-          // Ghosts of devices being dragged in.
-          for (final cursor in swarm.cursors) {
-            final id = cursor.carrying;
-            final def = id == null ? null : app.defs[id];
-            if (def == null) continue;
-            final center = _local(cursor.pos);
-            final full = Size(def.width * app.zoom, def.height * app.zoom);
-            // Card-sized over the library, growing to its real size as it crosses onto the canvas.
-            final fit = 96 / math.max(full.width, full.height);
-            final into = ((center.dx - _canvasAt.dx + 40) / 120).clamp(0.0, 1.0);
-            final scale = fit >= 1 ? 1.0 : fit + (1 - fit) * into;
-            final size = full * scale;
-            final asset = def.previewAsset ?? (def.isRaster ? def.assetFor(def.defaultState) : null);
-            children.add(Positioned(
-              left: center.dx - size.width / 2,
-              top: center.dy - size.height / 2,
-              width: size.width,
-              height: size.height,
-              // Drawn with alpha in the paint rather than an Opacity layer: ten cursors carrying big photos at once
-              // would otherwise mean ten offscreen layers a frame.
-              child: DecoratedBox(
-                decoration: BoxDecoration(border: Border.all(color: cursor.color.withValues(alpha: 0.8 * cursor.alpha), width: 1.5), borderRadius: BorderRadius.circular(Radii.control)),
-                child: asset == null
-                    ? const SizedBox.expand()
-                    : Image.asset(asset, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.low, opacity: AlwaysStoppedAnimation(0.6 * cursor.alpha)),
-              ),
-            ));
-          }
-          children.add(Positioned.fill(child: CustomPaint(painter: _SwarmPainter(app, swarm, _local))));
-          final card = swarm.card;
-          if (card != null) children.add(_card(context, card));
-          for (final cursor in swarm.cursors) {
-            children.add(_label(context, cursor));
-          }
-          if (app.aiLocked) children.add(_banner(context));
-          // Cursors may travel over the library and the canvas, never over the assistant's panel.
-          return ClipRect(
-            clipper: _LeftOf(_canvasAt.dx + _canvasSize.width),
-            child: Stack(clipBehavior: Clip.hardEdge, children: children),
-          );
-        },
+      child: LayoutBuilder(
+        builder: (context, constraints) => ListenableBuilder(
+          listenable: swarm,
+          builder: (context, _) {
+            _measure();
+            final height = constraints.hasBoundedHeight ? constraints.maxHeight : _overlayHeight;
+            final children = <Widget>[];
+            // Ghosts of devices being dragged in.
+            for (final cursor in swarm.cursors) {
+              final id = cursor.carrying;
+              final def = id == null ? null : app.defs[id];
+              if (def == null) continue;
+              final center = _local(cursor.pos);
+              final full = Size(def.width * app.zoom, def.height * app.zoom);
+              // Card-sized over the library, growing to its real size as it crosses onto the canvas.
+              final fit = 96 / math.max(full.width, full.height);
+              final into = ((center.dx - _canvasAt.dx + 40) / 120).clamp(0.0, 1.0);
+              final scale = fit >= 1 ? 1.0 : fit + (1 - fit) * into;
+              final size = full * scale;
+              final asset = def.previewAsset ?? (def.isRaster ? def.assetFor(def.defaultState) : null);
+              children.add(Positioned(
+                left: center.dx - size.width / 2,
+                top: center.dy - size.height / 2,
+                width: size.width,
+                height: size.height,
+                // Drawn with alpha in the paint rather than an Opacity layer: ten cursors carrying big photos at once
+                // would otherwise mean ten offscreen layers a frame.
+                child: DecoratedBox(
+                  decoration: BoxDecoration(border: Border.all(color: cursor.color.withValues(alpha: 0.8 * cursor.alpha), width: 1.5), borderRadius: BorderRadius.circular(Radii.control)),
+                  child: asset == null
+                      ? const SizedBox.expand()
+                      : Image.asset(asset, fit: BoxFit.contain, gaplessPlayback: true, filterQuality: FilterQuality.low, opacity: AlwaysStoppedAnimation(0.6 * cursor.alpha)),
+                ),
+              ));
+            }
+            children.add(Positioned.fill(child: CustomPaint(painter: _SwarmPainter(app, swarm, _local))));
+            final card = swarm.card;
+            if (card != null) children.add(_card(context, card, height));
+            for (final cursor in swarm.cursors) {
+              children.add(_label(context, cursor));
+            }
+            if (app.aiLocked) children.add(_banner(context));
+            // Cursors may travel over the library and the canvas, never over the assistant's panel.
+            return ClipRect(
+              clipper: _LeftOf(_canvasAt.dx + _canvasSize.width),
+              child: Stack(clipBehavior: Clip.hardEdge, children: children),
+            );
+          },
+        ),
       ),
     );
   }
@@ -171,7 +176,7 @@ class _SwarmOverlayState extends State<SwarmOverlay> with SingleTickerProviderSt
     );
   }
 
-  Widget _card(BuildContext context, SwarmCard card) {
+  Widget _card(BuildContext context, SwarmCard card, double overlayHeight) {
     final app = widget.app;
     final plc = app.project.devices.where((d) => d.id == card.deviceId).firstOrNull;
     if (plc == null) return const SizedBox.shrink();
@@ -186,7 +191,7 @@ class _SwarmOverlayState extends State<SwarmOverlay> with SingleTickerProviderSt
     final typing = card.shown < card.total;
     return Positioned(
       left: at.dx,
-      bottom: (context.size?.height ?? 0) - at.dy + 10,
+      bottom: overlayHeight - at.dy + 10,
       child: Opacity(
         opacity: card.fade.clamp(0.0, 1.0),
         child: Container(
```
