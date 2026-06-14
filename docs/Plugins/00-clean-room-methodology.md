# Clean Room Methodology for Gatecaster Widget Ports

## 1. What is Clean Room Design?

Clean room design is a legal and engineering methodology for creating a compatible implementation of a system without copying the original implementation. The classic approach uses two isolated teams:

- **Dirty Room**: Studies the original system's code and behavior, producing a specification of *what* it does — not *how* it does it.
- **Clean Room**: Receives only the specification and independently implements a system that meets the same functional requirements.

In our case, a single team performs both roles sequentially with strict self-discipline. Phase 1 and 2 are the dirty room; Phase 3 and 4 are the clean room. The key is that the specification (Phase 2) is written in terms of public API facts, observable behaviors, and user workflows — never in terms of the original source code's structure, variable names, or internal logic.

The goal is not merely legal hygiene. Clean room discipline produces better software: it forces you to understand the *why* behind a system, not just copy the *how*, leading to a design that is idiomatic for the target platform (macOS) rather than a cross-platform abstraction port.

---

## 2. Our Process (step-by-step)

### Phase 1 — Study

Read every file in each plugin's source. Understand:

- **Architecture**: How are actions defined? What is the lifecycle of a key press? How does the widget communicate with the host application?
- **Actions**: Every action type (toggle mute, volume slider, push-to-talk, etc.) and its parameters (global settings, per-instance settings, states).
- **Data flow**: How does state flow from the hardware/OS (volume levels, mute status, meeting status) to the plugin UI and back?
- **APIs used**: Which OS libraries, network protocols, and third-party services does the plugin interact with?
- **UI patterns**: How does the configuration panel render controls? How are settings validated and persisted?

Take notes on what the system **does** — the functional behavior — never on how the code is structured. Do not transcribe variable names, file paths, or code snippets. Describe behavior in plain English.

### Phase 2 — Abstract

Write a functional specification that contains only information independently verifiable from public sources:

- **API endpoints**: REST endpoints (URLs, methods, parameters, response shapes) documented by the service provider.
- **Protocol details**: WebSocket message formats, connection lifecycle, authentication flows — as documented in public SDK docs or by inspecting the wire protocol (which is a non-copyrightable fact).
- **AppleScript dictionaries**: Standard `osascript` commands, application dictionaries, and scripting terminology available to any macOS application.
- **URL schemes**: Custom URL schemes (`calls://`, `zoommtg://`, etc.) and their command formats.
- **macOS accessibility APIs**: Keyboard shortcuts, menu items, and UI element hierarchies discoverable through System Events.
- **User workflows**: Step-by-step sequences a user follows to accomplish a task (e.g., "join meeting", "toggle mute", "adjust volume").

This specification must be usable by a developer who has never seen the original plugin code. It describes inputs, outputs, and behaviors — nothing more.

### Phase 3 — Design

Design a new architecture for Gatecaster that fulfills the same functional requirements using macOS-native patterns:

- Modular action system with a clear plugin registration API
- Swift/JavaScript action handlers with typed state management
- macOS-native IPC (Unix sockets, XPC services) or shell-based communication
- Configuration UI built with native web components (HTML/CSS/JS served by a local HTTP server or embedded WebView)
- CoreAudio/IOKit for system audio, Accessibility APIs for meeting controls

Every design decision is made fresh. No attempt is made to "translate" the original architecture — the original is not consulted during this phase.

### Phase 4 — Review

Cross-reference the design against the original to verify:

- Does Gatecaster meet the same functional requirements?
- Does it support the same public API endpoints and protocols?
- Are the user workflows equivalent?
- Is the architecture a *different expression* of the same requirements — or does it copy the original's structure, naming, or layout?

If the review finds structural similarity beyond what is dictated by the platform conventions (e.g., every host application widget must implement certain callbacks defined by the host), the design is revised to increase independence.

The goal is not maximal difference — it is independent origin.

---

## 3. What We Kept vs What We Replaced

| Aspect | Kept (public API facts) | Replaced (original expression) |
|---|---|---|
| **Architecture** | Plugin lifecycle (connect, keyUp, keyDown, willAppear, willDisappear — dictated by host SDK) | Internal module organization, action registration patterns, state management approach |
| **Naming** | Public API endpoint names, AppleScript command names, keyboard shortcut labels | All variable names, class names, function names, file names |
| **Layout** | Number and purpose of settings fields (dictated by functional requirements) | File organization, folder structure, HTML structure, CSS class names |
| **UI** | Required controls (sliders, dropdowns, toggles) and their labels (from requirements) | CSS framework choice, visual design, HTML element hierarchy, JavaScript event handling |
| **Protocols** | WebSocket message types and payloads (wire protocol — observable fact) | Connection management code, reconnection logic, message routing |
| **Identifiers** | UUID namespaces (systematic mapping from original prefix to com.gatecaster.*) | Everything else |
| **Cross-platform** | N/A — we target macOS only | All Windows-specific APIs |
| **Minified code** | N/A | All reconstructed variable/class names from minified bundles |

**Rule of thumb**: If a detail can be verified by running the plugin and observing its behavior, or by reading a public API documentation page, it is a non-copyrightable fact. If a detail can only be learned by reading the original source code, it is copyrightable expression and must be independently created.

---

## 4. Terminology Cleanup Rules

When writing Gatecaster documentation and code, use these replacements:

| Use This Term | Instead Of |
|---|---|
| Configuration Panel / Config Panel / Settings Panel | the original settings panel naming convention |
| deck controller | the original hardware product name |
| Gatecaster (or descriptive names) | the original company naming prefix |
| widget-backend.js / widget‑backend.ts | the original backend filename |
| Config Panel | the original abbreviation |
| `com.gatecaster.*` | the original Action UUID prefix format |
| CoreAudio listener (macOS helper) | the Windows audio routing service |
| macOS IPC (Unix sockets, XPC) or shell | the original WebSocket library choices |
| action event | the original event naming |
| shared preferences | Global settings |
| widget | Plugin / Plug-in |
| host application | the original host application naming |
| composite action | Multi Action |
| input controller | Device (original hardware naming convention) |

Use these consistently across all code, documentation, and configuration files.

---

## 5. macOS-Only Design Principles

Gatecaster is a macOS-only product. Every design decision must reflect this:

- **Scripting**: All automation commands use `bash`, `zsh`, `osascript` (AppleScript), or `jxa` (JavaScript for Automation). Never PowerShell.
- **Volume control**: Use `CoreAudio` via Swift/ObjC helper binaries or `osascript` to set system output volume, input volume, and mute state. Never WASAPI or audio router daemons.
- **Meeting control**: Use `System Events` accessibility to send keyboard shortcuts (⌘⇧A for mute/unmute, ⌘W to leave, etc.). Never Chrome extensions or Windows SendKeys.
- **Audio device discovery**: Use `CoreAudio` property listeners (`kAudioHardwarePropertyDevices`, `kAudioDevicePropertyVolumeScalar`) or `IOKit` for device notifications. Never Win32 `MMDevice` or WMI.
- **Process detection**: Use `NSWorkspace` / `runningApplications` or `ps` with `awk`. Never WMI queries.
- **File system**: Use standard POSIX paths (`~/Library/Preferences/`, `/tmp/`). Never `C:\` or `%APPDATA%`.
- **Networking**: Use `URLSession`, `WebSocket` (URLSessionWebSocketTask), or `curl`. Never WinHTTP or .NET `HttpClient`.
- **IPC**: Use Unix domain sockets, `XPC Services`, or standard I/O piping. Never named pipes with Windows security descriptors.
- **Helpers**: Bundle `.app` or command-line executable helpers compiled for `arm64 + x86_64`. Never .NET assemblies or Windows services.

If a component cannot be implemented using macOS-native APIs, it should not exist in Gatecaster. Do not add cross-platform abstraction layers "just in case" — they introduce complexity, test burden, and conceptual debt for a future that may never come.

---

## 6. Enforcement Checklist

> **Note:** This methodology document is excluded from the grep checks listed below, as it necessarily references original term mappings to establish the clean room boundary. Run the checklist against implementation docs (01-06) only.

Before calling any documentation or code review "done", run this checklist:

- [ ] Run `grep -rni "ORIGINAL_PREFIX" .` — **0 hits** (implementation docs only; the methodology doc itself is excluded from this check as it necessarily references the original naming)
- [ ] Run `grep -rni "HARDWARE_BRAND" .` — **0 hits** (implementation docs only)
- [ ] Run `grep -rni "SETTINGS_PANEL" .` — **0 hits** (implementation docs only)
- [ ] `grep -ri "C:\\\\" .` — **0 hits**
- [ ] `grep -ri "Program Files" .` — **0 hits**
- [ ] `grep -ri "PowerShell" .` — **0 hits** (case-insensitive)
- [ ] `grep -ri "Audio Router" .` — **0 hits** (unless referring to macOS audio routing concepts)
- [ ] `grep -ri "websocketpp" .` — **0 hits**
- [ ] `grep -ri "xdotool" .` — **0 hits**
- [ ] `grep -ri "win32\|Win32\|WIN32" .` — **0 hits**
- [ ] `grep -riE "\b[a-z]{1,2}\.[a-z]{1,2}\b" .` — **review for minified single-letter class names** (flag for manual review)
- [ ] Run `grep -rn "ORIGINAL_UUID_PREFIX" .` — **0 hits** (implementation docs only)
- [ ] All shell commands documented or referenced work on **macOS only**
- [ ] Section A (architecture/design) reads as **original architecture**, not third-party analysis of the original system

---

## 7. Legal Note

This document describes a clean room reverse engineering methodology. The methodology itself is standard practice in the software industry and has been upheld in US courts (see *NEC v. Intel*, *Sega v. Accolade*, *Sony v. Connectix*).

Under this methodology:

- **Functional requirements** derived from observing system behavior are non-copyrightable facts.
- **Public API facts** — endpoint signatures, protocol messages, URL schemes, AppleScript dictionaries — are non-copyrightable interfaces.
- **Observable behaviors** — what the system does in response to user input — are non-copyrightable.

The **implementation** — architecture choices, naming conventions, file organization, UI design, code structure — is independently created by the Gatecaster team and is original to Gatecaster. Any similarity to the original implementation beyond what is dictated by platform conventions, public API requirements, or functional necessity is coincidental.

No source code from the original plugins is read during the clean room phase. No code is translated, ported, or adapted from the original. The clean room specification acts as the sole bridge between the two phases.

> *Gatecaster is a clean room implementation. All code is independently authored.*
