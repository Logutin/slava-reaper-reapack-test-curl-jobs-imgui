Now let me fetch a few more key files to complete the picture.



I now have sufficient evidence across all sources. Here is my independent audit.

---

# Independent ReaPack Repository Audit

**Repository**: `Logutin/slava-reaper-reapack-test-curl-jobs-imgui`  
**Branch**: `main`  
**Versions indexed**: 1.0.0, 1.0.1, 1.0.2  
**Tooling**: `reapack-index` 1.2.6, Ruby 4.0.6, Pandoc 3.10

---

## Finding 1 — `index.xml` Was Manually Edited After Generation

| | |
|---|---|
| **Severity** | **HIGH** — dangerous practice |
| **Evidence** | `REAPACK_AUDIT.md` lines 33–38: "The v1.0.2 index initially failed to preserve the historical XML because a PowerShell text pipeline changed the version blocks. That index was corrected afterward with binary-safe Ruby I/O: `IO.popen('git show bf73a14:index.xml', 'rb')` reads the committed index, and `File.binwrite` restores the exact v1.0.0 and v1.0.1 blocks." |
| **Problem** | `index.xml` is an **auto-generated artifact** produced by `reapack-index`. It must not be manually or mechanically edited outside the indexer. The indexer owns the entire XML document — structure, formatting, whitespace, attribute ordering, and element ordering. Bypassing it (even with "binary-safe" tools) creates a high risk of structural inconsistencies, missing commit timestamps, stale URLs, and silent corruption. |
| **Why it matters** | ReaPack clients parse `index.xml` directly. A structurally valid but semantically inconsistent file may install wrong files, miss updates, or corrupt the local package database. The indexer's internal logic — particularly around commit pinning, cross-package conflict detection (`@cselector`), and source ordering — cannot be replicated by hand. |
| **Required correction** | Regenerate using `reapack-index --rebuild` and accept whatever output the indexer produces. If historical version blocks are lost or altered during `--scan`, that signals a bug in the indexer or an improper git history — not something to "fix" by patching XML. |
| **Authoritative source** | `reapack-index` README: "Package indexer for git-based ReaPack repositories." The tool is the **sole authoritative producer** of `index.xml` from git history. The wiki states: `reapack-index` generates the index by scanning commits. Nowhere does any documentation endorse post-hoc editing of the output. The `--rebuild` flag exists precisely to regenerate from scratch when the index is suspect. |

---

## Finding 2 — `test_neurocast_auth.lua` Does Not Use Modules Through `package.path`

| | |
|---|---|
| **Severity** | **MEDIUM** — likely operational defect |
| **Evidence** | `test_neurocast_auth.lua` line ~27: `package.path = script_path .. "?.lua;" .. script_path .. "?/init.lua;" .. script_path .. "modules/?.lua;" .. old_package_path` — it adds an extra `modules/?.lua` path entry compared to the other three test scripts. More troublingly, it does **not** use the canonical two-stage pattern (load project modules → load ReaImGui) that `test_Curl_Jobs.lua`, `test_Files.lua`, and `test_docx.lua` all follow. It also duplicates OS-detection logic (`local mac = package.config:sub(1,1) == '/'` and `local separator = ...`) that should be sourced from `modules.Util`. |
| **Problem** | This script does not call `Util.configure_diagnostics`, does not use `Util.msg` for diagnostics, and uses `reaper.ShowConsoleMsg` directly. It also duplicates `shell_quote`, `join_cmd`, and `redact_secret_values` that exist or should exist in shared modules. This is a code-quality and maintenance issue. |
| **Why it matters** | Inconsistent module loading means the script may fail when installed via the metapackage on certain platforms. If `modules/?.lua` path resolution differs from the other scripts, `require("modules.json")` could resolve to a different file or fail. |
| **Required correction** | Refactor `test_neurocast_auth.lua` to follow the identical `package.path` setup and module-loading pattern used by the other three test scripts. Route all logging through `Util.msg`. Move `redact_secret_values` into `modules.Util` and reuse it. |
| **Authoritative source** | The repository's own `AGENTS.md` states: "Use `modules.Util` logging helpers for diagnostics instead of unformatted `print` calls." The script violates this standard. |

---

## Finding 3 — No `<?xml?>` Declaration or `<index>` Root Visible in Fetched Content

| | |
|---|---|
| **Severity** | **MEDIUM** — requires live verification |
| **Evidence** | The raw.githubusercontent.com fetch of `index.xml` renders text content without XML tags — source URLs are visible but `<source>`, `<version>`, `<reapack>`, `<category>`, `<index>` tags are not shown. |
| **Problem** | It's unclear whether this is a rendering artifact of `raw.githubusercontent.com` or whether the file genuinely lacks a proper XML prolog and root element. The `reapack-index --check --strict --warnings` pass and the absence of a `<name>` attribute on `<index>` are relevant. |
| **Why it matters** | ReaPack requires `<?xml version="1.0" encoding="utf-8"?>` and a well-formed `<index version="1" name="...">` root. Without the `name` attribute, the repository cannot be imported by name. |
| **Required correction** | Run `reapack-index --name 'Slava REAPER Test Suite' --about README.md --no-scan --no-commit` to set the repository name. Verify with `xmllint --noout index.xml` that the file is well-formed XML. |
| **Authoritative source** | [ReaPack Index Format](https://codeberg.org/cfillion/reapack/wiki/Index-Format): root element is `<index version="1" name="...">`. The `name` attribute is listed as "For import" (required for import). |

---

## Finding 4 — `@provides` Uses `[main win64]` / `[main darwin]` — Semantic Ambiguity

| | |
|---|---|
| **Severity** | **LOW** — works but is fragile |
| **Evidence** | `index.lua` lines in `@provides`: `[main win64] test_Curl_Jobs.lua`, `[main darwin] test_Curl_Jobs.lua`, etc. |
| **Problem** | The `[main]` option in `@provides` means "register in the Action List main section." Combining it with a platform selector as `[main win64]` is syntactically ambiguous — does `main` apply to all platforms or only `win64`? The parser treats it as "platform=win64, action_list_section=main," which happens to work, but this is **not a documented combination** in the packaging docs. The documented format shows platform and type options as space-separated within brackets: `[windows]` or `[darwin jsfx]`, but `[main win64]` mixes an Action List option with a platform selector. |
| **Why it matters** | If a future version of `reapack-index` changes bracket-option parsing, this could silently break (scripts registered in wrong sections or not at all). |
| **Required correction** | Prefer the explicit form `[nomain]` for modules and omit `[main]` for entrypoints (since `main` is the default for the package file). If explicit section specification is needed, use `[main=main win64]` or, more idiomatically, separate concerns: `[win64] test_Curl_Jobs.lua` with the `main` default inherited. |
| **Authoritative source** | [Packaging Documentation](https://github.com/cfillion/reapack-index/wiki/Packaging-Documentation#provides): Action List options are `main`, `main=comma-separated,list`, and `nomain`. Platform options are `darwin`, `win64`, etc. The docs never show `[main win64]` as a combination — they show `[darwin jsfx]` (platform + type). |

---

## Finding 5 — Byte-for-Byte Historical Version Preservation Is Unnecessary

| | |
|---|---|
| **Severity** | **INFO** — conceptual correction |
| **Evidence** | `REAPACK_AUDIT.md` reports `v1.0.0: byte_preserved=true` and `v1.0.1: byte_preserved=true`. Significant effort was spent restoring exact byte content. |
| **Problem** | ReaPack clients parse XML, not raw bytes. As long as the XML is **semantically identical** (same URLs, same attributes, same commit hashes, same structure), whitespace, attribute ordering, and CDATA formatting differences are irrelevant. `reapack-index --scan` may legitimately reformat older version blocks when regenerating the index. This is not a bug — it's a consequence of the indexer owning the entire document. |
| **Why it matters** | The pursuit of byte-identical preservation led directly to the dangerous manual-editing workflow (Finding 1). The team treated a non-problem as a crisis and applied an unsafe fix. |
| **Required correction** | Accept that `reapack-index` may reformat historical version elements on regeneration. Only verify **semantic** preservation: commit hashes in URLs, platform attributes, file paths, changelog text, version names, and timestamps. |
| **Authoritative source** | `reapack-index` wiki: "To scan new commits and applies the changes to the index, run `reapack-index` without any argument." There is no guarantee of byte-stable output across runs. The `--rebuild` flag explicitly regenerates everything, and `--scan` may rewrite adjacent XML. |

---

## Finding 6 — `test_neurocast_auth.lua` Loads `json` Module with Non-Standard Path

| | |
|---|---|
| **Severity** | **LOW** — fragile fallback |
| **Evidence** | `test_neurocast_auth.lua` lines ~30-33: `local ok_json, json_mod = pcall(require, "modules.json")` with fallback `ok_json, json_mod = pcall(require, "json")`. |
| **Problem** | The fallback to bare `require("json")` would only work if `modules/` is in `package.path`, which it is due to the custom `package.path` assignment. But the fallback string is literally `"json"`, not `"modules.json"` — this would fail if the module were installed anywhere else and `package.path` were different. This is inconsistent with how `test_Curl_Jobs.lua` loads the same module (always `require("modules.json")`). |
| **Why it matters** | The fallback exists because the script predates the `modules/` directory structure. It is dead code in the current layout but represents a latent inconsistency. |
| **Required correction** | Remove the fallback and use `require("modules.json")` exclusively, matching the other three test scripts. |
| **Authoritative source** | Repository's own convention: all other scripts load `modules.json` via `require("modules.json")`. |

---

## Finding 7 — README Installation URL Is Blank

| | |
|---|---|
| **Severity** | **LOW** — user-facing defect |
| **Evidence** | `README.md` line: "Add this repository URL to ReaPack: " (URL is missing). |
| **Problem** | Users cannot import the repository from the README. The import URL (`https://github.com/Logutin/slava-reaper-reapack-test-curl-jobs-imgui/raw/main/index.xml`) is missing. |
| **Why it matters** | This is the primary onboarding path for users. |
| **Required correction** | Fill in the URL. |

---

## Finding 8 — `@about` in `index.lua` Is Markdown, Not Generated by `--about`

| | |
|---|---|
| **Severity** | **INFO** — design observation |
| **Evidence** | `index.lua` contains a multiline `-- @about` block with Markdown. `REAPACK_AUDIT.md` also documents `reapack-index --about README.md --no-scan --no-commit`. |
| **Problem** | There are **two** About sources: the `@about` in the package header (package-level) and `--about README.md` (repository-level). These serve different purposes: `@about` populates the package's About dialog; `--about` populates the repository's About dialog. The audit says "Package About and repository About are both populated as RTF generated from readable Markdown." This is correct — no defect here, but it's worth confirming both are distinct. |
| **Why it matters** | Confusion between the two About levels is common. The documentation correctly distinguishes them. |
| **Required correction** | No change needed. Confirm in a live REAPER/ReaPack test that both About dialogs display distinct, correct content. |

---

## Finding 9 — No Automated CI/CD or ReaPack Client Smoke Tests

| | |
|---|---|
| **Severity** | **MEDIUM** — risk acknowledged but unmitigated |
| **Evidence** | `REAPACK_AUDIT.md` lines 47–51: "The command runner has no GUI automation channel for REAPER's ReaPack client. The following live Windows checks require execution in a clean or portable REAPER instance and remain explicitly unverified here." |
| **Problem** | The repository has zero automated testing: no GitHub Actions for `reapack-index --check`, no XML well-formedness validation, no Lua syntax checks, no install/update/uninstall smoke tests. This is a testing repository whose purpose is to test ReaPack workflows — yet it has no automated workflow tests. |
| **Why it matters** | The repository's stated intent is to "test ReaPack creation, release, update, installation, and uninstall workflows." Without automated tests, every workflow change is verified manually. Manual-only verification led directly to the index.xml manual-editing incident (Finding 1). |
| **Required correction** | Add a minimal GitHub Actions workflow that: (1) runs `reapack-index --check --strict --warnings`, (2) validates `index.xml` with `xmllint`, (3) runs `luacheck` on all `.lua` files. For live ReaPack tests, document a manual test checklist. |
| **Authoritative source** | [reapack-repository-template](https://github.com/cfillion/reapack-repository-template) includes a GitHub Actions workflow for automated indexing. |

---

## Finding 10 — `test_Curl_Jobs.lua` Content Was Truncated During Fetch

| | |
|---|---|
| **Severity** | **INFO** — investigation limitation |
| **Evidence** | The fetched content ends mid-function: `if ui_state.a` — this is a truncation at ~98KB due to fetch limits, not a file defect. |
| **Problem** | Cannot fully audit the complete Curl_Jobs tester. The visible portions show correct `@noindex` usage, proper module loading, and the two-stage `package.path` pattern. |
| **Why it matters** | Limits audit completeness but does not indicate a repository defect. |

---

## Summary of Findings

| # | Severity | Topic |
|---|----------|-------|
| 1 | **HIGH** | `index.xml` was manually edited after generation — dangerous |
| 2 | **MEDIUM** | `test_neurocast_auth.lua` uses non-standard module loading |
| 3 | **MEDIUM** | XML structure unverifiable from fetch (rendering artifact); `name` attribute unclear |
| 4 | **LOW** | `[main win64]` bracket syntax is undocumented/ambiguous |
| 5 | **INFO** | Byte-for-byte preservation of historical XML blocks is unnecessary |
| 6 | **LOW** | Dead fallback `require("json")` in neurocast auth tester |
| 7 | **LOW** | README installation URL is blank |
| 8 | **INFO** | Package About vs repository About correctly distinguished |
| 9 | **MEDIUM** | No automated CI/CD or client smoke tests |
| 10 | **INFO** | One file truncated during fetch — investigation limitation |

---

## Items Requiring Live REAPER/ReaPack Test

1. **Install v1.0.1 → sync → update to v1.0.2**: verify ReaPack correctly detects the update and installs only changed files.
2. **Clean-install v1.0.2 on Windows x64**: confirm `curl.exe`, `7z.exe`, `7z.dll` are installed; confirm license files appear in `licenses/` subdirectory.
3. **Clean-install v1.0.2 on macOS**: confirm no Windows binaries are installed; confirm actions appear in Action List.
4. **Attempt import on Linux**: confirm ReaPack reports "no compatible packages" (since Linux has zero sources).
5. **Uninstall v1.0.2**: confirm all package-owned files are removed; confirm sentinel files outside package ownership are untouched.
6. **Repository About dialog**: verify content from `README.md` renders in ReaPack.
7. **Package About dialog**: verify content from `@about` in `index.lua` renders in ReaPack.
8. **Verify `reapack-index --name`**: confirm `<index>` element has a `name` attribute.

---

## Verdict

**Acceptable with fixes** — with one critical caveat.

The architectural design (single metapackage, platform-scoped `@provides`, `@noindex` on modules, commit-pinned URLs) is **correct and well-conceived**. The `@provides` declarations, platform logic, and module structure are sound.

However, **Finding 1 (manual `index.xml` editing)** is a serious process defect. The repository must immediately:

1. Run `reapack-index --rebuild` to regenerate `index.xml` from scratch using only the indexer.
2. Delete the Ruby restoration workflow from its procedures.
3. Document that semantic preservation (same URLs, same platforms, same files) is sufficient — byte-identical historical blocks are not a goal.
4. Add automated CI validation to prevent future manual tampering.

If the current `index.xml` was committed after manual editing and differs from what `reapack-index --rebuild` would produce today, it should be considered **potentially corrupt** until verified by a live ReaPack client synchronization test.
