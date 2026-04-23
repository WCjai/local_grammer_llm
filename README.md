# Local Scribe

**On-device & online LLM-powered writing assistant that works system-wide across every Android app.**

Type a `?command` (e.g. `?fix`, `?rewrite`, `?polite`) at the end of any text field in any app — Local Scribe intercepts it via an Android Accessibility Service, processes the text through a local on-device LLM (Google MediaPipe) or the Gemini API, and replaces the text in-place with the corrected/transformed result.

Alternatively, **highlight text in any app** → tap "Local Scribe" from the context menu → pick a command from the bottom sheet → get the processed result via Android's native `PROCESS_TEXT` intent.

---

## Table of Contents

- [Introduction](#introduction)
- [How It Works](#how-it-works)
- [Core Processing Pipeline](#core-processing-pipeline)
- [Feature List](#feature-list)
- [Features in Detail](#features-in-detail)
- [PROCESS_TEXT Highlight-to-Transform](#process_text-highlight-to-transform)
- [Architecture Overview](#architecture-overview)
- [Screens & Navigation](#screens--navigation)
- [File Structure](#file-structure)
- [Platform Channel API Reference](#platform-channel-api-reference)
- [Native Android Components](#native-android-components)
- [Built-in Commands Reference](#built-in-commands-reference)
- [Dependencies](#dependencies)
- [Development Setup](#development-setup)
- [Configuration](#configuration)
- [Known Issues & TODOs](#known-issues--todos)

---

## Introduction

Local Scribe is a Flutter application designed as a personal writing assistant. It is built for a single user ("jAi") and runs entirely on-device with an optional online fallback. The app's core value proposition is **system-wide text transformation** — it doesn't require you to copy-paste text into a separate app. Instead, you type a trigger command directly inside any text field (WhatsApp, email, notes, browser, etc.), and the text gets processed and replaced automatically.

**Dual LLM modes:**
- **Local mode** — Uses Google MediaPipe's `LlmInference` engine with `.task` or `.litertlm` model files stored on-device. Fully offline, no data leaves the phone.
- **Online mode** — Calls the Google Gemini API (`v1beta generateContent` endpoint) with user-provided API key. Supports models: `gemini-2.5-flash-lite`, `gemini-2.5-flash`, `gemini-2.5-pro`, `gemma-3n-e2b-it`, `gemma-3n-e4b-it`, `gemma-4-31b-it`, `gemma-4-26b-a4b-it`.
- **Best mode** — Tries online first, falls back to local if network is unavailable.

---

## How It Works

```
1. User types in any app:  "hey whats up ?fix iam doing well"
2. Accessibility Service detects "?fix" in the text
3. Strips the command, extracts "hey whats up " (text BEFORE ?fix) as input text
4. Text after the command (" iam doing well") is preserved separately
5. (Optional) Shows a context window overlay for additional instructions
6. Builds a structured prompt with [TASK], [CONTEXT], [RULES], [TEXT] tags
7. Routes to local LLM or Gemini API based on current mode setting
8. Receives LLM response in JSON format: {"output": "Hey, what's up?"}
9. (Optional) Shows a preview overlay with Apply/Cancel buttons
10. Replaces the text field content with: processed result + preserved text after command
    → "Hey, what's up? iam doing well"
```

**Anti-loop protection:** The service tracks a hash of the last applied text to avoid re-triggering on text it just set.

**Command format:** `?keyword` or `?keyword:arg` (e.g. `?rewrite:formal`). The `?` prefix and keyword are stripped before processing. Only the text **before** the `?keyword` is sent to the LLM; any text after the command is preserved as-is and appended to the result. Custom prompts can use `{text}` as a placeholder for user input.

---

## Core Processing Pipeline

This section documents exactly how input text flows through the system, from keystroke detection to final output.

### Stage 1: Event Detection (`onAccessibilityEvent`)

```
AccessibilityEvent (TYPE_VIEW_TEXT_CHANGED or TYPE_VIEW_FOCUSED)
  → Find the editable node (text field) from event source
  → Read the full text content of that field
  → Skip if blank or if hash matches lastAppliedHash (anti-loop)
  → Attempt to parse a command from the text
  → Skip if a generation job is already active
  → Set busy = true, launch coroutine
```

### Stage 2: Command Parsing (`parseLastCommand`)

The regex `(?i)\?($keywords)(?::(\w+))?\b` is built from all registered keywords (12 built-in + any custom). It finds the **last** matching `?keyword` in the text and splits it into a `Parsed` object:

```
Input:  "hi, how are you? ?fix iam doing well"
Regex matches: ?fix (at index 18)

Parsed {
  before:  "hi, how are you? "     ← sent to LLM
  after:   " iam doing well"       ← preserved as-is
  command: "fix"
  arg:     null
}
```

For commands with arguments (colon-separated):
```
Input:  "this needs work ?rewrite:formal more text here"

Parsed {
  before:  "this needs work "
  after:   " more text here"
  command: "rewrite"
  arg:     "formal"
}
```

**Edge case:** If `before` is blank/empty, the command is silently removed from the text field and no LLM call is made.

### Stage 3: Context Collection (Optional)

If "Show add context window" is enabled AND the command is not `scribe`:
- A floating overlay dialog appears with a text input
- User can type additional instructions (e.g. "keep it under 50 words")
- User presses "Add" (includes context) or "Cancel" (proceeds without it)
- The context text is later injected into the `[CONTEXT]` tag of the prompt

### Stage 4: Prompt Construction

Two prompt formats exist depending on the command:

**Standard commands** (`buildTaggedPrompt`) — used for all commands except `scribe`:
```
You are a writing engine.

OUTPUT FORMAT (mandatory):
Return ONLY valid JSON exactly like:
{"output":"..."}
No other keys. No extra text. No markdown.
If you cannot comply, return: {"output":""}

[TASK]
<task description from mapCommandToTask() or custom prompt>
[/TASK]

[CONTEXT]
<user-provided context, or "(none)">
[/CONTEXT]

[RULES]
Keep the same language as the input unless the task says otherwise.
Keep the SAME point of view and pronouns (do NOT change I/you/She/He/they).
Preserve the original meaning and intent exactly.
Do not add new facts or remove unique details.
Keep names, numbers, dates and places unchanged.
Do not mention the task, rules, or context in the output.
Output only the final answer (no explanations, no quotes, no formatting).
[/RULES]

[TEXT]
<the text before the ?command>
[/TEXT]
```

**Scribe command** (`buildScribePrompt`) — a simpler open-ended prompt:
```
Respond in the same language as the input. Provide only the final answer.
No explanations. Input: "<text>"
```
(If context was provided: `Use this context: "<context>".` is prepended.)

**Task resolution order:**
1. Check if the keyword has a **custom prompt** saved in SharedPreferences → use that as the task
2. Otherwise use `mapCommandToTask()` which maps built-in keywords to their hardcoded task descriptions
3. For `?rewrite`, the arg (`:formal`, `:friendly`, `:short`) selects a specific task variant

### Stage 5: LLM Generation (`generateAccordingToMode`)

The prompt is routed based on the API mode setting:

| Mode | Behavior |
|---|---|
| `local` | Calls `LlmInference.generateResponse(prompt)` using the on-device MediaPipe model. Validates prompt fits within token limit (`maxTokens=512 - outputTokens=128 = 384 input tokens max`). |
| `online` | Calls the Gemini API via HTTP POST to `generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`. Requires API key + internet. |
| `best` | Tries online first (if API key is set and internet is available). On any failure, falls back to local. |

**Timeout:** 20 seconds (`withTimeout(20_000)`).

### Stage 6: Output Post-Processing (`postProcessOutput`)

The raw LLM response goes through a multi-stage cleanup pipeline:

```
Raw LLM output
  │
  ├─ removeThinkOnly()        Strip <think>...</think> tags (chain-of-thought artifacts)
  │
  ├─ stripJsonWrappers()      Remove wrapping: '''...''', """...""", ```json...```
  │
  ├─ extractJsonOutput()      Try to parse as JSON and extract the "output" field
  │   ├─ Fast path: direct JSONObject parse → obj.getString("output")
  │   └─ Fallback: locate "output" key in string, find surrounding { }, parse substring
  │
  ├─ (if JSON extraction fails) Accept as plain text (last resort)
  │
  └─ normalizeLineBreaks()    Convert \r\n, \n, /n to actual newlines
```

**For `scribe` command only:** Skips JSON extraction — just strips `<think>` tags and returns raw text.

### Stage 7: Result Assembly & Application

```
resultText = post-processed LLM output
newText = resultText + parsed.after    ← re-attach text that was after the command

Example:
  resultText = "Hi, how are you?"
  parsed.after = " iam doing well"
  newText = "Hi, how are you? iam doing well"
```

**If "Show preview" is enabled:**
- A floating overlay card shows `newText` in a scrollable view
- User presses "Apply" → text is set into the field
- User presses "Cancel" → original text is restored (command is stripped)

**If "Show preview" is disabled:**
- `newText` is applied directly into the text field

**Text is set** via `AccessibilityNodeInfo.ACTION_SET_TEXT`, and `lastAppliedHash` is updated to the new text's hash to prevent re-triggering.

### Stage 8: Cleanup

- Overlay is hidden
- `busy` flag is reset to `false`
- The service is ready for the next command

### Error Handling

| Scenario | Behavior |
|---|---|
| Generation timeout (>20s) | Silently cancelled, overlay hidden |
| User cancels (overlay cancel button) | Current `genJob` is cancelled, command is stripped from text, overlay hidden |
| LLM not ready / model not found | Exception caught, overlay hidden |
| Network error (online mode) | In "best" mode: falls back to local. In "online" mode: exception, overlay hidden |
| Input too long for local model | Exception: "Input too long for model (tokens=X, maxInput=384)" |
| Empty LLM result | No text replacement happens, overlay hidden |

---

## Feature List

- System-wide text interception via Android Accessibility Service
- On-device LLM inference (Google MediaPipe `.task`/`.litertlm` models)
- Online LLM via Google Gemini API (7 model choices)
- Smart mode switching: Local only / Online only / Use the Best
- 12 built-in text transformation commands
- Custom prompt CRUD (create, read, update, delete)
- AI-powered Prompt Generator chat (BETA) — describe what you need, get command suggestions
- Preview overlay before applying text changes
- Context window overlay for adding extra instructions per-request
- Model file picker with copy progress bar
- API key validation with visual feedback
- Cached command descriptions using LLM-generated summaries
- PROCESS_TEXT intent: highlight text in any app → pick a command from a bottom-sheet overlay → apply or copy result
- Vision/image input support for compatible models (via screenshot capture in ProcessText flow)
- Configurable token limits (max tokens, output tokens) via settings drawer
- Full light + dark mode support across all screens and the PROCESS_TEXT overlay
- First-launch onboarding wizard (engine setup + accessibility permission)
- Material 3 purple-themed UI

---

## Features in Detail

### Accessibility Service Text Interception
The core feature. `TypiLikeAccessibilityService` (extends `AccessibilityService`) listens for `TYPE_VIEW_TEXT_CHANGED` and `TYPE_VIEW_FOCUSED` events. When it detects a `?keyword` pattern at the end of text in any editable field, it triggers the LLM pipeline. The service operates as a foreground service with `BIND_ACCESSIBILITY_SERVICE` permission and uses `TYPE_ACCESSIBILITY_OVERLAY` windows for UI overlays.

### On-Device LLM (MediaPipe)
Uses `com.google.mediapipe:tasks-genai:0.10.27` for local inference. Users pick a `.task` or `.litertlm` model file via the in-app file picker, which copies it to internal storage. LLM config: `maxTokens=512`, `topK=100`, reserved output tokens = 128. The model is initialized on-demand and shared between `MainActivity` (for chat/description generation) and `TypiLikeAccessibilityService` (for text processing).

### Online Gemini API
Calls `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` with `X-Goog-Api-Key` header. Supports 7 models: `gemini-2.5-flash-lite`, `gemini-2.5-flash`, `gemini-2.5-pro`, `gemma-3n-e2b-it`, `gemma-3n-e4b-it`, `gemma-4-31b-it`, `gemma-4-26b-a4b-it`. API key is validated by sending a test "ping" request. The app checks network connectivity before attempting online calls.

### Custom Prompts
Users can create custom commands with their own keyword and prompt text. Custom prompts are stored as a JSON object in `SharedPreferences` under the `custom_prompts` key. Built-in keywords (12 reserved words) cannot be overridden. The prompt text should contain `{text}` as a placeholder for user input.

### AI Prompt Generator (BETA)
A chat interface (`ChatPage`) where users describe what kind of text transformations they want. The LLM generates 3–5 command suggestions in a structured JSON format (`{"prompts": [{"keyword": "...", "label": "...", "prompt": "..."}]}`). Users can add suggestions directly as custom commands. The chat includes JSON repair and regex fallback extraction for handling malformed LLM output.

### Preview Overlay
When enabled ("Show preview" toggle), after the LLM generates output, a floating overlay card shows the result text with "Apply" and "Cancel" buttons. The user can review the transformation before it's applied to the text field.

### Context Window
When enabled ("Show add context window" toggle), before LLM processing begins, a floating overlay dialog with a text input appears, allowing the user to type additional instructions (e.g. "make it shorter" or "keep the greeting"). This context is injected into the `[CONTEXT]` section of the prompt.

### Model File Picker
Opens Android's file picker filtered for `.task` and `.litertlm` files. Selected files are copied to internal app storage with real-time progress streaming via `EventChannel('local_llm_progress')`. Progress is displayed as a linear progress bar in the UI.

---

## PROCESS_TEXT Highlight-to-Transform

Android's `ACTION_PROCESS_TEXT` intent allows apps to register as text processors. When a user selects text in **any** app and taps the overflow menu, "Local Scribe" appears as an option.

### Flow

```
1. User highlights text in any app (Chrome, Notes, Gmail, etc.)
2. Taps "Local Scribe" from the context/overflow menu
3. ProcessTextActivity launches with a transparent overlay
4. A Flutter bottom sheet slides up showing:
   - The selected text (preview, max 3 lines)
   - A grid of all available commands (built-in + custom)
5. User taps a command (e.g. ?fix, ?rewrite, ?polite)
6. LLM processes the text (same pipeline: prompt → local/online/best → post-process)
7. Result is displayed with action buttons:
   - "Apply" — returns processed text to the source app (replaces selection)
   - "Copy" — copies result to clipboard
   - "Back" — return to command selection
8. Tapping outside the sheet or the ✕ button dismisses without changes
```

### Architecture

| Component | Role |
|---|---|
| `ProcessTextActivity` | Kotlin `FlutterActivity` subclass; receives `EXTRA_PROCESS_TEXT` from the intent, starts Flutter with `processTextMain` entry point, exposes `MethodChannel('process_text')` |
| `processTextMain()` | Secondary Dart entry point (`@pragma('vm:entry-point')`) that runs `ProcessTextApp` → `ProcessTextPage` |
| `ProcessTextPage` | Flutter bottom-sheet UI: command grid, loading spinner, result preview with Apply/Copy/Back buttons |
| Transparent theme | `ProcessTextTheme` (both light/dark `styles.xml`) uses `Theme.Translucent.NoTitleBar` so the source app remains visible behind the overlay |

### MethodChannel (`process_text`)

| Method | Arguments | Returns | Description |
|---|---|---|---|
| `getProcessTextData` | — | `Map{text, readOnly}` | Get the highlighted text and read-only flag from the intent |
| `getPrompts` | — | `List<Map>` | Get all prompts (built-in + custom) |
| `getShowPreview` | — | `bool` | Get preview setting |
| `getShowContext` | — | `bool` | Get context window setting |
| `getModelSupportsVision` | — | `bool` | Check whether the loaded model supports image input |
| `generate` | `text, command, arg?, context?, imagePath?` | `String` | Build prompt, run LLM, post-process, return result. `imagePath` enables vision input. |
| `captureScreenshot` | — | `String?` | Trigger AccessibilityService screenshot + crop activity. Returns crop file path or null. |
| `finishWithResult` | `text: String` | `bool` | Return processed text to source app via `RESULT_OK` |
| `dismiss` | — | `bool` | Cancel and close the activity |

### Read-Only vs Editable

The `EXTRA_PROCESS_TEXT_READONLY` flag from the intent determines whether the source app supports receiving modified text back:
- **Editable (`readOnly=false`):** "Apply" button is shown — returns processed text to replace the selection.
- **Read-only (`readOnly=true`):** Only "Copy" button is shown — user can copy the result to clipboard.

---

## Architecture Overview

| Aspect | Detail |
|---|---|
| **Framework** | Flutter 3.10.8+ with Dart |
| **State management** | `provider` package — `ChangeNotifier`-based providers (`ModelProvider`, `ServiceProvider`, `SettingsProvider`, `CommandsProvider`, `ThemeProvider`) |
| **Code structure** | Multi-file: entry point in `lib/main.dart`, app shell in `lib/app.dart`, screens in `lib/ui/screens/`, widgets in `lib/ui/widgets/`, providers in `lib/providers/`, services in `lib/services/`, models in `lib/models/` |
| **Navigation** | Imperative `Navigator.push()` with `MaterialPageRoute` |
| **Platform bridge** | `MethodChannel('local_llm')` for request/response + `EventChannel('local_llm_progress')` for streaming + `MethodChannel('process_text')` for PROCESS_TEXT flow |
| **Native code** | Kotlin — `MainActivity.kt` (~850 lines) + `TypiLikeAccessibilityService.kt` (~1,000 lines) + `ProcessTextActivity.kt` (~310 lines) |
| **Persistence** | Android `SharedPreferences` (`local_llm_prefs`) for all settings, model path, custom prompts, API config |
| **Flutter persistence** | `shared_preferences` package for caching LLM-generated command descriptions, onboarding state, dark mode preference, and chat history |
| **LLM engine** | Google MediaPipe `LlmInference` (on-device) + Google Gemini API (online) |
| **UI theme** | Material 3, purple `ColorScheme` (#6C4AD5 primary light / #9B80E8 dark), full light + dark mode support |
| **Overlay system** | Android `WindowManager` with `TYPE_ACCESSIBILITY_OVERLAY` for loading/preview/context UIs |

---

## Screens & Navigation

The app has **5 main screens** plus a secondary process-text screen, navigated via `Navigator.push()`:

### 0. Onboarding (`OnboardingScreen`) — First-launch only
- Shown once when `has_completed_onboarding` pref is `false`
- **Page 1 — Engine:** Choose Local or Cloud (Online) mode. Local: file picker to copy a `.task`/`.litertlm` model. Cloud: select Gemini model, enter API key, validate.
- **Page 2 — Accessibility:** Prompts user to enable the accessibility service with a live status indicator. Automatically advances when permission is granted.
- On completion, sets `has_completed_onboarding = true` and navigates to `DashboardScreen`.

### 1. Dashboard (`DashboardScreen`) — Main Screen
- AppBar: "Local Scribe" title + dark/light mode toggle (sun/moon icon via `ThemeProvider`)
- Settings drawer (gear icon): AI mode dropdown, local model picker with copy progress, online API config (model selector, API key field, validate button), configurable max/output token sliders, vision support toggle
- Accessibility service toggle card (color-coded: green when active, red when off)
- Two action buttons: "Prompt Generator" → `ChatScreen` (BETA tag), "Manage Prompts" → `ManagePromptsScreen`
- "How to use?" → `DemoScreen` (disabled until service is enabled)
- Settings card: "Show preview" and "Show add context window" toggles
- Available commands grid: two-column layout of all built-in + custom commands with LLM-generated descriptions

### 2. Chat / Prompt Generator (`ChatScreen`) — BETA
- Chat-style interface with user (right, purple) and assistant (left) message bubbles
- Users describe what prompts they want; LLM generates 3–5 keyword/label/prompt suggestions
- Suggestion cards with "Add" button to save as custom commands
- Chat history persisted across sessions via `SharedPreferences` (`prompt_gen_history` key)

### 3. Demo Screen (`DemoScreen`)
- Quick tutorial with usage instructions
- Command buttons (`?fix`, `?rewrite`, `?summ`, `?polite`, `?casual`) for quick reference
- Real-time command detection regex display
- Test text field for experimentation

### 4. Manage Prompts (`ManagePromptsScreen`)
- ListView of all prompts — custom prompts first, then built-in (marked "Default")
- Built-in prompts are read-only; custom prompts have edit/delete icons
- FAB to add new prompt via dialog (keyword + prompt text fields)
- Keyword validation: 3–20 chars, lowercase letters/numbers/underscore, no reserved words

### 5. Process Text (`ProcessTextScreen`) — Secondary Entry Point
- Launched via `processTextMain()` secondary entry point
- Transparent overlay bottom sheet over the source app
- Command grid → loading spinner → result preview with Apply/Copy/Back buttons
- Optional context input and image capture (vision-capable models)
- Respects the app's dark/light mode preference from SharedPreferences

---

## File Structure

```
local_grammer_llm/
├── pubspec.yaml                          # Flutter project config; deps: provider ^6.1.2, shared_preferences ^2.2.3; SDK ^3.10.8
├── analysis_options.yaml                 # Lint rules (flutter_lints/flutter.yaml)
├── devtools_options.yaml                 # DevTools config
├── README.md                             # This file
│
├── lib/
│   ├── main.dart                         # App entry point: initialises SharedPreferences, sets up
│   │                                     #   MultiProvider with all 5 providers, boots App widget.
│   │                                     #   Also exports processTextMain() entry point.
│   ├── app.dart                          # App widget: MaterialApp with full light + dark ColorScheme,
│   │                                     #   Material 3 theme, routes to OnboardingScreen or DashboardScreen.
│   │
│   ├── models/
│   │   ├── chat_message.dart             # ChatMessage (role, text, suggestions) + PromptSuggestion
│   │   └── prompt_models.dart            # CommandInfo, PromptSpec, PromptEntry
│   │
│   ├── providers/
│   │   ├── model_provider.dart           # ModelProvider: LLM init, model file pick/copy, progress stream
│   │   ├── service_provider.dart         # ServiceProvider: accessibility grant check, service enable/disable
│   │   ├── settings_provider.dart        # SettingsProvider: API mode/model/key, token config, preview/context
│   │   │                                 #   toggles, vision flag. Supported models:
│   │   │                                 #   gemini-2.5-flash-lite, gemini-2.5-flash, gemini-2.5-pro,
│   │   │                                 #   gemma-3n-e2b-it, gemma-3n-e4b-it, gemma-4-31b-it, gemma-4-26b-a4b-it
│   │   ├── commands_provider.dart        # CommandsProvider: loads built-in + custom commands, generates
│   │   │                                 #   LLM descriptions, caches to SharedPreferences
│   │   └── theme_provider.dart           # ThemeProvider: light/dark toggle, persisted via SharedPreferences
│   │
│   ├── services/
│   │   ├── platform_channel_service.dart # LlmChannelService: wraps MethodChannel('local_llm') +
│   │   │                                 #   EventChannel('local_llm_progress'). All model, service,
│   │   │                                 #   settings, prompt CRUD, and generation calls.
│   │   ├── preferences_service.dart      # PreferencesService: Flutter-side SharedPreferences wrapper.
│   │   │                                 #   Manages onboarding flag, command description cache.
│   │   └── process_text_channel.dart     # ProcessTextChannelService: wraps MethodChannel('process_text').
│   │                                     #   getProcessTextData, getPrompts, generate (with optional
│   │                                     #   imagePath for vision), captureScreenshot, finishWithResult, dismiss.
│   │
│   └── ui/
│       ├── screens/
│       │   ├── dashboard_screen.dart     # Main screen: service toggle, model status, command grid,
│       │   │                             #   settings drawer, navigation to chat/prompts/demo
│       │   ├── onboarding_screen.dart    # First-launch wizard: engine setup + accessibility grant
│       │   ├── chat_screen.dart          # Prompt Generator BETA: chat UI, LLM suggestion parsing,
│       │   │                             #   JSON repair, history persistence via SharedPreferences
│       │   ├── demo_screen.dart          # Tutorial screen with test text field
│       │   ├── manage_prompts_screen.dart# Prompt CRUD: list, add, edit, delete custom prompts
│       │   └── process_text_screen.dart  # ProcessText overlay: command grid, result preview,
│       │                                 #   Apply/Copy actions, dark mode sync, vision image capture
│       │
│       └── widgets/
│           ├── app_snackbar.dart         # Typed snack bar helper (success / error / info styles)
│           ├── beta_tag.dart             # Small "BETA" label chip
│           ├── command_item.dart         # Single command card (icon, keyword, description)
│           ├── command_row.dart          # Row layout wrapper for command grid items
│           ├── engine_card.dart          # Selectable card for Local / Cloud engine choice (onboarding)
│           ├── no_glow_scroll.dart       # ScrollBehavior that removes overscroll glow
│           └── suggestions_list.dart    # Renders LLM prompt suggestions with Add action
│
├── test/
│   └── widget_test.dart                  # Smoke test (OUTDATED — references old UI text)
│
├── android/
│   ├── build.gradle.kts                  # Top-level Android Gradle config
│   ├── settings.gradle.kts               # Gradle settings
│   ├── gradle.properties                 # Gradle properties
│   └── app/
│       ├── build.gradle.kts              # App-level Gradle: applicationId, native deps
│       │                                 #   (MediaPipe 0.10.27, coroutines 1.8.1, constraintlayout 2.1.4)
│       └── src/
│           └── main/
│               ├── AndroidManifest.xml   # Permissions (INTERNET, ACCESS_NETWORK_STATE),
│               │                         #   MainActivity, ProcessTextActivity, TypiLikeAccessibilityService
│               ├── kotlin/com/example/local_grammer_llm/
│               │   ├── MainActivity.kt           # Flutter↔native bridge (~850 lines): 21+ MethodChannel
│               │   │                             #   handlers, LLM init, Gemini API, file picker, prompt CRUD,
│               │   │                             #   12 built-in prompts, SharedPreferences persistence
│               │   ├── ProcessTextActivity.kt    # PROCESS_TEXT intent handler (~310 lines):
│               │   │                             #   FlutterActivity with transparent theme,
│               │   │                             #   processTextMain Dart entry point,
│               │   │                             #   MethodChannel('process_text'), LLM generation,
│               │   │                             #   vision/screenshot support
│               │   └── TypiLikeAccessibilityService.kt  # Core accessibility service (~1,000 lines):
│               │                                        #   text interception, command regex parsing,
│               │                                        #   overlay UI (loading/preview/context),
│               │                                        #   LLM routing (local/online/best), text replacement,
│               │                                        #   structured prompt builder with [TASK]/[RULES]/[TEXT] tags
│               └── res/
│                   ├── layout/
│                   │   └── llm_overlay.xml        # Overlay layout: loading spinner, preview card, context dialog
│                   ├── xml/
│                   │   └── typi_like_accessibility_config.xml  # Accessibility event types & flags config
│                   ├── drawable/                  # Button and card background drawables
│                   ├── values/
│                   │   ├── strings.xml            # App name "Local Scribe", accessibility description
│                   │   └── styles.xml             # Launch theme, normal theme, ProcessTextTheme (light)
│                   └── values-night/
│                       └── styles.xml             # Dark mode launch theme, ProcessTextTheme
│
├── ios/                                  # iOS platform files (standard Flutter template)
├── macos/                                # macOS platform files (standard Flutter template)
└── assets/
    └── tutorial/                         # Tutorial assets for the Demo screen
```

---

## Platform Channel API Reference

All Flutter ↔ native communication goes through `MethodChannel('local_llm')` and `EventChannel('local_llm_progress')`.

### MethodChannel Calls (Flutter → Native)

| Method | Arguments | Returns | Description |
|---|---|---|---|
| `init` | `modelPath: String?` | `bool` | Initialize LLM engine with model file. Uses saved path if arg is blank. |
| `getModelPath` | — | `String` | Get saved model file path |
| `hasModel` | — | `bool` | Check if model file exists at saved path |
| `getModelName` | — | `String` | Get filename of saved model |
| `isAccessibilityGranted` | — | `bool` | Check if accessibility service permission is granted |
| `getServiceEnabled` | — | `bool` | Get service enabled toggle state |
| `setServiceEnabled` | `enabled: bool` | `bool` | Set service enabled/disabled |
| `getShowPreview` | — | `bool` | Get "show preview" toggle state |
| `setShowPreview` | `enabled: bool` | `bool` | Set "show preview" toggle |
| `getShowContext` | — | `bool` | Get "show context window" toggle state |
| `setShowContext` | `enabled: bool` | `bool` | Set "show context window" toggle |
| `getApiMode` | — | `String` | Get current API mode (`local`/`online`/`best`) |
| `setApiMode` | `mode: String` | `bool` | Set API mode |
| `getApiModel` | — | `String` | Get selected Gemini model name |
| `setApiModel` | `model: String` | `bool` | Set Gemini model |
| `getApiKey` | — | `String` | Get saved Gemini API key |
| `setApiKey` | `key: String` | `bool` | Save Gemini API key |
| `validateApiKey` | `model: String, key: String` | `bool` | Validate API key by making a test request |
| `openAccessibilitySettings` | — | `bool` | Open Android accessibility settings screen |
| `getMaxTokens` | — | `int` | Get configured max token count |
| `setMaxTokens` | `value: int` | `bool` | Set max token count |
| `getOutputTokens` | — | `int` | Get reserved output token count |
| `setOutputTokens` | `value: int` | `bool` | Set reserved output token count |
| `getModelSupportsVision` | — | `bool` | Get vision support toggle state |
| `setModelSupportsVision` | `enabled: bool` | `bool` | Set vision support toggle |
| `getPrompts` | — | `List<Map>` | Get all prompts (built-in + custom) with keyword, prompt, builtIn flag |
| `addPrompt` | `keyword: String, prompt: String` | `bool` | Add a custom prompt (rejects built-in keywords) |
| `updatePrompt` | `keyword: String, prompt: String, oldKeyword: String?` | `bool` | Update a custom prompt (supports keyword rename) |
| `deletePrompt` | `keyword: String` | `bool` | Delete a custom prompt (rejects built-in) |
| `setModelPath` | `path: String` | `bool` | Set model path and close existing LLM |
| `pickModel` | — | `Map` | Open file picker for model files, copy to internal storage |
| `generate` | `prompt: String` | `String` | Run LLM inference (routes to local/online/best) |
| `close` | — | `bool` | Close LLM engine and free resources |

### EventChannel Stream

| Channel | Event Data | Description |
|---|---|---|
| `local_llm_progress` | `double` (0.0–1.0) | Model file copy progress during `pickModel` |

---

## Native Android Components

### MainActivity.kt (~850 lines)
The Flutter-to-native bridge. Handles all `MethodChannel` calls, manages the `LlmInference` instance for in-app use (chat, description generation), implements the Gemini API client, file picker with progress streaming, and prompt CRUD against `SharedPreferences`. Contains the 12 built-in prompt definitions.

### TypiLikeAccessibilityService.kt (~1,000 lines)
The core accessibility service. Key responsibilities:
- **Event handling:** Listens for `TYPE_VIEW_TEXT_CHANGED` and `TYPE_VIEW_FOCUSED`
- **Command parsing:** Regex-based detection of `?keyword` patterns from all registered keywords (built-in + custom)
- **Prompt building:** Constructs structured prompts with `[TASK]`, `[CONTEXT]`, `[RULES]`, `[TEXT]` tags requiring `{"output":"..."}` JSON responses
- **LLM routing:** Tries online (Gemini API) first in "best" mode, falls back to local (MediaPipe)
- **Overlay UI:** Three overlay modes managed via `WindowManager`:
  - Loading: spinner + cancel button
  - Preview: scrollable text + Apply/Cancel buttons
  - Context: text input + Add/Cancel buttons
- **Text replacement:** Uses `AccessibilityNodeInfo.ACTION_SET_TEXT` to replace text in the source app
- **Output processing:** JSON extraction, `<think>` tag removal, bracket repair, line break normalization

**Prompt enforcement rules:**
- Keep same language as input
- Keep same point of view / pronouns
- Preserve meaning, names, numbers, dates, places
- Output only the final answer in JSON format

### Accessibility Config (typi_like_accessibility_config.xml)
- Events: `typeViewTextChanged | typeViewFocused`
- Feedback: `feedbackGeneric`
- Flags: `flagReportViewIds | flagRetrieveInteractiveWindows`
- `canRetrieveWindowContent: true`
- Notification timeout: 100ms

### ProcessTextActivity.kt (~310 lines)
Handles Android's `ACTION_PROCESS_TEXT` intent. Extends `FlutterActivity` with a transparent background and a secondary Dart entry point (`processTextMain`). Communicates with Flutter via `MethodChannel('process_text')`. Contains its own LLM generation pipeline (same prompt building, output processing, and local/online/best routing as `TypiLikeAccessibilityService`). Reads settings from the same `SharedPreferences` (`local_llm_prefs`). Returns processed text to the source app via `setResult(RESULT_OK, intent)` with `EXTRA_PROCESS_TEXT`. Also exposes `captureScreenshot` for AccessibilityService-triggered crop and `getModelSupportsVision` for vision-capable model detection. Pushes `onNewText` method calls to the Flutter layer to re-render the overlay when the source text changes.

### Overlay Layout (llm_overlay.xml)
Full-screen overlay containing three swappable card views: loading (progress spinner + cancel), preview (ScrollView text + Apply/Cancel buttons), and context (EditText input + Add/Cancel buttons). Max height constrained to 60% of screen.

---

## Built-in Commands Reference

| Command | Trigger | Prompt Description |
|---|---|---|
| **Fix** | `?fix` | Correct grammar, spelling, and punctuation. Keep the same language. Return only the corrected text. |
| **Rewrite** | `?rewrite` | Rewrite the text clearly while preserving meaning. Supports colon-separated arguments: `?rewrite:formal`, `?rewrite:friendly`, `?rewrite:short`. |
| **Scribe** | `?scribe` | Respond in the same language. Provide only the most relevant and complete answer. No explanations. |
| **Summarize** | `?summ` | Summarize in one or two sentences in the same language. Return only the summary. |
| **Polite** | `?polite` | Rewrite in a polite and professional tone. Same language. |
| **Casual** | `?casual` | Rewrite in a casual and friendly tone. Same language. |
| **Expand** | `?expand` | Expand with more detail while keeping the same language. |
| **Translate** | `?translate` | Translate the text into English. |
| **Bullet** | `?bullet` | Convert into clear bullet points. Same language. |
| **Improve** | `?improve` | Improve writing clarity and quality. Keep meaning and language. |
| **Rephrase** | `?rephrase` | Rephrase completely while keeping the same meaning and language. |
| **Formal** | `?formal` | Rewrite in a formal, professional tone. Same language. |

---

## Dependencies

### Flutter Dependencies (pubspec.yaml)

| Package | Version | Purpose |
|---|---|---|
| `flutter` (sdk) | — | Core framework |
| `provider` | `^6.1.2` | State management (`ChangeNotifier`-based providers) |
| `shared_preferences` | `^2.2.3` | Local key-value storage for caching command descriptions, onboarding state, dark mode, chat history |

### Dev Dependencies

| Package | Version | Purpose |
|---|---|---|
| `flutter_test` (sdk) | — | Testing framework |
| `flutter_lints` | `^6.0.0` | Lint rules |

### Native Android Dependencies (build.gradle.kts)

| Package | Version | Purpose |
|---|---|---|
| `com.google.mediapipe:tasks-genai` | `0.10.27` | On-device LLM inference engine |
| `androidx.constraintlayout:constraintlayout` | `2.1.4` | Layout for overlay views |
| `org.jetbrains.kotlinx:kotlinx-coroutines-android` | `1.8.1` | Kotlin coroutines for async operations |

---

## Development Setup

### Prerequisites
- Flutter SDK `>=3.10.8`
- Android SDK with Java 17
- An Android device with USB debugging enabled (accessibility service requires a real device or emulator with accessibility support)
- (Optional) A `.task` or `.litertlm` model file for local LLM mode
- (Optional) A Google Gemini API key for online mode

### Build & Run

```bash
# Clone the repository
git clone <repo-url>
cd local_grammer_llm

# Get Flutter dependencies
flutter pub get

# Connect Android device via USB (verify with)
flutter devices

# Run in debug mode
flutter run
```

### First Launch Setup
1. Open the app → tap the gear icon to open AI Settings drawer
2. **For local mode:** Tap "Pick Model" and select a `.task` or `.litertlm` file
3. **For online mode:** Switch mode to "Online only", select a Gemini model, enter API key, tap "Validate API"
4. Go back to the main screen → enable the Accessibility Service toggle (will open Android settings)
5. Find "Local Scribe" in accessibility services and enable it
6. Open any app, type some text followed by `?fix` (or any command) — the text will be processed

---

## Configuration

| Setting | Value | Location |
|---|---|---|
| Application ID | `com.example.local_grammer_llm` | `android/app/build.gradle.kts` |
| Min SDK | `flutter.minSdkVersion` | `android/app/build.gradle.kts` |
| Target SDK | `flutter.targetSdkVersion` | `android/app/build.gradle.kts` |
| Compile SDK | `flutter.compileSdkVersion` | `android/app/build.gradle.kts` |
| Java/Kotlin target | Java 17 | `android/app/build.gradle.kts` |
| Dart SDK | `^3.10.8` | `pubspec.yaml` |
| Default model path | `/data/local/tmp/llm/model.task` | `MainActivity.kt` |
| Default API mode | `local` | `MainActivity.kt` |
| Default API model | `gemini-2.5-flash` | `MainActivity.kt` |
| Supported API models | `gemini-2.5-flash-lite`, `gemini-2.5-flash`, `gemini-2.5-pro`, `gemma-3n-e2b-it`, `gemma-3n-e4b-it`, `gemma-4-31b-it`, `gemma-4-26b-a4b-it` | `SettingsProvider` |
| Default LLM max tokens | 512 (configurable) | `MainActivity.kt`, `TypiLikeAccessibilityService.kt` |
| Default LLM output tokens | 128 (configurable) | `MainActivity.kt`, `TypiLikeAccessibilityService.kt` |
| SharedPreferences name | `local_llm_prefs` | Both Kotlin files |

---

## Known Issues & TODOs

- **Outdated widget test:** `test/widget_test.dart` references UI text that no longer exists. The test will fail.
- **Release signing:** `android/app/build.gradle.kts` uses debug signing for release builds (marked with `// TODO`).
- **No error boundary:** No global error handling or crash reporting.
- **iOS/macOS/Linux/Windows:** Platform shells exist but have no native LLM or accessibility integration — the app's core features are Android-only.
- **Application ID:** Still uses the default `com.example.local_grammer_llm` — should be changed before publishing.
