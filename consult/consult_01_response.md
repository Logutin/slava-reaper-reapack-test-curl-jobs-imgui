# Audit: Slava-Testing ReaPack Repository Workflow

## Findings

---

### F1 — Published index is corrupted by hand-editing

* **Severity:** Critical
* **Problem:** `index.xml` was manually/mechanically edited after `reapack-index` normalized it, producing the mangled v1.0.1 changelog (`notices.Document` run-on). The audit claim of "byte-for-byte preservation" was false.
* **Why it matters:** The changelog is a text node rendered verbatim in ReaPack's UI; a lost newline is a *semantic* regression, not cosmetic. Worse, hand-edits to a generated artifact are unverifiable and will be silently overwritten on the next scan. The index is the single source of truth: ReaPack repositories are made of a single XML index file describing its contents.
* **Required correction:** Discard the hand-restored file. Regenerate deterministically with `reapack-index --rebuild`, which will clear the index and rescan the whole git history. Since every release was committed with correct headers and one `@version` bump per release, rebuild output is reproducible. Diff old vs. new with an XML-aware canonicalizer, then commit.
* **Source:** reapack-index README (`--rebuild`); ReaPack Index Format wiki.

---

### F2 — Blanket `--amend` ban is the root cause of the corruption

* **Severity:** High
* **Problem:** Forbidding `--amend` outright left no sanctioned path to correct released version metadata, so the maintainer resorted to manual XML surgery.
* **Why it matters:** `--amend` is the *documented* mechanism for exactly this case: These tags are specific to the current version of the package (see @version). If you are running your own repository, note that by default reapack-index ignores changes made to these tags post-release unless the --amend option is used. The wiki's own release-repair recipe is: If you wish to alter a released version (eg. to fix a mistake), commit your changes then run: reapack-index --scan 7a4abf8 reapack-index --scan 7a4abf8 --amend
* **Required correction:** Keep the "no routine amend" policy, but explicitly permit `--scan <commit> --amend` as the sole approved repair path for released versions. Document that manual `index.xml` edits are always forbidden.
* **Source:** reapack-index wiki (Home, Packaging Documentation).

---

### F3 — "Byte-for-byte preservation" is the wrong acceptance criterion

* **Severity:** Medium
* **Problem:** The audit tested byte identity of historical blocks; the indexer legitimately reformats the whole document on every run.
* **Why it matters:** ReaPack consumes parsed XML, not bytes. Requiring byte identity guarantees false failures after every indexer or libxml upgrade, and — as demonstrated — encourages manual "restoration." However, whitespace **inside text nodes** (changelogs, RTF `<description>` CDATA) *is* content and must be preserved exactly.
* **Required correction:** Replace the check with: (a) XML canonicalization + node-level diff for structure/attributes, and (b) exact string comparison of text-node payloads (changelog, description, `<source>` URLs). Formatting-only diffs pass; text-node diffs fail.
* **Source:** ReaPack Index Format wiki (index is a parsed XML document, e.g. Description (documentation) of the repository or package in RTF format).

---

### F4 — Platform selector for Windows binaries must be `win64`, not `windows`

* **Severity:** High
* **Problem:** The design says "Windows x64 also receives" the binaries, but the manifest documentation shows generic selectors like @provides [windows] reaper_extension.dll — `[windows]` matches *both* 32- and 64-bit clients. Only `[win64]` targets x64 alone. The description does not confirm which was used.
* **Why it matters:** If `[windows]` was used, 32-bit REAPER installs x64 `curl.exe`/`7z.exe` that cannot execute — a silent runtime failure that no index validation catches.
* **Required correction:** Verify every binary entry uses `[win64]`; add a manual test on 32-bit Windows REAPER (package should install *without* the binaries) and on x64 (binaries present and executable).
* **Source:** reapack-index Packaging Documentation (`@provides` platform options).

---

### F5 — Linux behavior of a zero-source version is assumed, not tested

* **Severity:** High
* **Problem:** Every source is platform-scoped and "Linux receives no sources," yet the package still appears in the Linux index. How ReaPack presents/handles a version with no applicable files on the running platform is untested.
* **Why it matters:** Depending on ReaPack version, the package may be hidden, shown-but-uninstallable, or install as an empty phantom entry in the registry — each outcome affects sync/uninstall semantics. For a repository whose stated purpose is *testing ReaPack workflows*, this is a core scenario, not an edge case.
* **Required correction:** Add explicit Linux GUI tests: browse, attempt install, "install all," synchronize, uninstall. Record observed behavior per ReaPack version. If a defined behavior is wanted, consider shipping at least one platform-neutral file (e.g., the licence files, which have no reason to be platform-scoped — see F6).
* **Source:** ReaPack Index Format wiki (platform attribute on `<source>`).

---

### F6 — Per-platform source duplication is a maintenance hazard

* **Severity:** Medium
* **Problem:** 50 sources per version because platform-neutral files (Lua scripts, modules, licences/notices) are duplicated per platform (8 main entries for 4 scripts, 30 for 15 modules, 9 licence entries).
* **Why it matters:** Every duplicated line must stay in sync across platforms; a missed edit yields divergent installs per OS. It also interacts with the ownership rule: ReaPack packages have exclusive ownership over the files they install. reapack-index enforces this exclusivity rule to ensure all packages in the repository may be successfully installed at the same time. Each package must provide a unique set of target file names — duplicated target paths are only tolerated while platform selectors remain disjoint; one typo creates a conflict or an unintended cross-platform install.
* **Required correction:** Scope only the genuinely platform-specific files (the three Windows binaries). Leave Lua files and licences unscoped unless the "Linux gets nothing" property is itself the test objective — if so, document that rationale in the manifest.
* **Source:** reapack-index Packaging Documentation (file ownership; `@provides`).

---

### F7 — About-metadata handling is essentially correct, with two caveats

* **Severity:** Low
* **Problem/assessment:** The split is right: repository About comes from `--about README.md` (matching the template convention: Replace the contents of this file (README.md). This will be the text shown when using ReaPack's "About this repository" feature.), and package About comes from the header's `@about`. Caveats: (1) Markdown conversion requires Pandoc — Many other formats (such as Markdown) are supported if Pandoc is installed on your computer — so a machine without Pandoc silently degrades the About content; (2) `@about` is a package-level tag regenerated on scan, so post-release About fixes do *not* require `--amend` (unlike `@changelog`); the workflow should state this to avoid unnecessary repairs. Compare the maintainer's confirmation for package tags: It's a package tag, so it's always updated even without --amend (which is for all version-related tags).
* **Required correction:** Pin the toolchain (Ruby gem version + Pandoc presence) in the release checklist or CI; add a GUI check that both About panes render RTF correctly (headings, links).
* **Source:** reapack-index wiki (repository metadata); ReaPack developer thread.

---

### F8 — Commit-pinned URLs depend on immutable history; the workflow never states this

* **Severity:** Medium
* **Problem:** Sources are pinned to commit SHAs (the indexer's default template resolves to "https://github.com/YourUser/YourRepository/raw/$commit/$path"). Nothing in the routine forbids history rewrites, force-pushes, branch deletion, or repo rename.
* **Why it matters:** Any rewrite orphans every pinned URL for all published versions simultaneously — a total repository outage that `--check` cannot detect. It also breaks `--rebuild` (F1's recovery path), which walks the same history.
* **Required correction:** Add a written invariant: default branch is protected; no force-push; no squash of release commits; repo renames require re-verifying old raw URLs (GitHub redirects usually hold, but test). Add an automated link-checker that HTTP-HEADs every `<source>` URL in `index.xml` after each release.
* **Source:** ReaPack developer thread (URL template); reapack-index README (`--rebuild` rescans git history).

---

### F9 — No CI; the release routine is manual where an official automation exists

* **Severity:** Medium
* **Problem:** All nine steps are manual. The upstream template already provides A template for GitHub-hosted ReaPack repositories with automated reapack-index running from GitHub Actions.
* **Why it matters:** Manual sequencing caused this incident (scan → About regeneration → inspection → separate commit leaves windows for mistakes). Automation also guarantees a consistent indexer/Pandoc environment (see F7).
* **Required correction:** Adopt the template's GitHub Actions workflow: run `--check --strict` on every push/PR (fail the build on `F` results, per the wiki: If you see a different output containg 'F' and errors, fix them and recheck before continuing), and let the action run the scan and commit `index.xml`. Humans only edit package files and bump `@version`/`@changelog`.
* **Source:** cfillion/reapack-repository-template; reapack-index wiki.

---

### F10 — Check runs *after* the source commit

* **Severity:** Low
* **Problem:** Step order is commit (4) → check (5). Since --check Test every package including uncommited changes, validation should precede the commit.
* **Why it matters:** A failing header is already immortalized in a commit that pinned URLs may reference; fixing it requires another commit and care not to index the broken one.
* **Required correction:** Reorder: check → commit → scan. (CI per F9 makes this moot.)
* **Source:** reapack-index README.

---

### F11 — Metapackage/`@noindex` design is correct (validated, not a defect)

* **Severity:** Info
* **Assessment:** Using one `@metapackage` manifest that excludes itself and provides `[main]` scripts plus unregistered modules matches the documented pattern — This will create a package containing two files without including itself (because of @metapackage) — and marking provided files is correct: Add @noindex or NoIndex: true at the top of Library_File.lua and User_Callable_File.lua to prevent them from being also indexed. One residual test: confirm exactly **4** actions appear in the Action List (all sections intended), and that the 15 modules do **not** appear.
* **Source:** reapack-index wiki Examples.

---

### F12 — Missing test matrix

* **Severity:** Medium
* **Problem:** GUI testing is acknowledged as incomplete; several cases are not even listed.
* **Required tests (per platform: win32, win64, macOS, Linux):**
  1. Clean install of latest; verify full file manifest on disk, including `licenses/` subtree and (win64 only) the three binaries.
  2. Update `1.0.1 → 1.0.2`; verify changelog dialog renders the (repaired) changelog with correct line breaks.
  3. Downgrade/reinstall of a pinned older version (exercises SHA-pinned URLs of *historical* commits).
  4. Uninstall; verify zero residue — binaries, licences, and any files a user modified are removed (ReaPack ownership means any edits made by a user will be lost when updating/reinstalling/uninstalling the package).
  5. Action List: exactly 4 registrations after install; 0 after uninstall.
  6. Package About and Repository About render correctly (RTF, links).
  7. Linux zero-source behavior (F5).
  8. Automated: `--check --strict` in CI; XML schema/canonical diff of `index.xml` (F3); HTTP liveness of all `<source>` URLs (F8).
* **Source:** ReaPack forum thread (ownership/uninstall semantics); reapack-index wiki.

---

## Direct answers to the numbered questions

1. **Wrong/fragile:** manual XML restoration (F1), absolute `--amend` ban (F2), byte-identity audit (F3), possible `[windows]`-vs-`[win64]` mismatch (F4), untested Linux empty version (F5), check-after-commit ordering (F10), no CI (F9).
2. **Manual restoration legitimate?** No. The index is a generated artifact; the only legitimate repair paths are `--scan <commit> --amend` or `--rebuild`.
3. **Byte-for-byte vs semantic:** Semantic preservation is sufficient for structure/formatting; text-node content (changelogs, About RTF, URLs) must be exact. Byte-identity is neither achievable nor meaningful across indexer runs.
4. **About handling:** Repository About from `README.md` via `--about` (requires Pandoc); package About from header `@about`, refreshed on scan without `--amend`. Current design is correct; pin the toolchain.
5. **Missing tests:** See F12.
6. **Risks:** covered in F4 (selectors), F11 (metapackage), F6 (duplication/ownership), F12-4 (uninstall ownership), F8 (commit pinning), F1/F3 (regeneration), plus versioning is safe (segments fit ReaPack's rules: ReaPack treats versions names as segments of whole numbers and letters optionally separated by one or more non-alphanumeric character (such as dots). A valid version must start with a digit. Individual number segments must fit in an unsigned 16-bit integer (0 to 65535).).
7. **Repeatability:** protect the branch; adopt the official GitHub Actions template; `--check --strict` gates every push; a single `--rebuild` now to purge the hand-edited index; thereafter, only `scan`/`amend` ever touch `index.xml`.

## Verdict

**Acceptable with fixes.** The package architecture (metapackage, `@noindex`, platform scoping, SHA pinning) follows upstream guidance, but the published index is currently corrupt and must be regenerated via `--rebuild`, the `--amend` policy must be amended to allow documented repairs, the Windows selector and Linux behavior must be verified, and the manual routine should be replaced by the official CI automation before further test releases.
