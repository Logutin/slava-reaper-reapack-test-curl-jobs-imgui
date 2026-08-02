## Bottom line

The external audits found several **real workflow weaknesses**, but both also overstate some risks. The first audit is substantially stronger. The second contains several claims that are plainly false for the current repository.

Most importantly, **your current `index.xml` is not showing the earlier corruption anymore**:

* it has a valid XML declaration;
* the `<index>` root has the repository name;
* the v1.0.1 changelog has its newline restored;
* package About metadata is present.

So the repository is not presently in the broken state described by the audits. The **process that produced and repaired it remains fragile**, however.

## The most important lesson: generated file versus source

Think of the repository as having two layers:

1. **Package headers and Git history** are what you maintain.
2. **`index.xml`** is the catalogue generated from them.

For a ReaPack client, `index.xml` is the catalogue it reads. For you as the maintainer, the Git history and package metadata should normally be the source from which that catalogue can be reproduced.

Your workflow crossed those layers when it copied old `<version>` blocks back into the generated XML with Ruby. That repair apparently restored the intended bytes, but it is not a good routine procedure. Both audits correctly identify this as the largest process weakness.

The models are too absolute when they say that `index.xml` may **never** be edited. Even the official template historically told maintainers to edit the repository name in `index.xml`. But manually assembling or replacing **package-version blocks** is fragile and should not be part of normal releases. ([GitHub][1])

## Byte-for-byte preservation was the wrong goal

This is the clearest and most valuable finding from both audits.

These two XML fragments are equivalent to an XML parser:

```xml
<version name="1.0.1">
  <source file="a.lua">...</source>
</version>
```

```xml
<version name="1.0.1"><source file="a.lua">...</source></version>
```

The spaces and line breaks **between elements** are formatting.

But this change is not equivalent:

```text
installed notices.
Document safe release/platform rules
```

```text
installed notices.Document safe release/platform rules
```

That newline is inside the changelog text itself, so users see different content.

Your acceptance criterion should therefore be:

* same version name, author and timestamp;
* same changelog text;
* same target filenames;
* same platform and Main-action attributes;
* same commit-pinned URLs;
* same package documentation content where applicable.

It should **not** require identical indentation, line endings, attribute layout or serialization. The official documentation promises that previous changelogs are preserved, but it does not promise byte-identical XML formatting. ([GitHub][2])

Your current `REAPACK_AUDIT.md` still emphasizes `byte_preserved=true`. That should eventually be replaced with a semantic comparison report.

## `--amend`: neither routine nor forbidden

Your original rule—never use `--amend` for ordinary releases—is good.

The absolute prohibition is too strong. Official documentation says version-specific metadata changes are normally ignored after release unless `--amend` is used. The CLI describes it as “Update existing versions.” ([GitHub][3])

A good policy is:

> Never use `--amend` during a normal new-version release. Use it only after an explicit decision to repair metadata belonging to an already published version.

That does **not** mean every formatting difference requires `--amend`. It is for an intentional correction such as a wrong author, wrong changelog or wrong provided-file metadata.

The first audit calls the blanket ban “the root cause.” That is overstated. The immediate cause was the PowerShell transformation plus the decision to pursue byte identity. Still, documenting an approved repair path would reduce the temptation to manipulate XML manually.

## Do not run `--rebuild` blindly

Both audits prescribe an immediate `--rebuild`. That recommendation is reasonable as a **diagnostic**, not automatically as the cure.

`--rebuild` clears the index and scans the entire Git history. That can expose old package states, repeated versions, moved files or historical mistakes. The CLI explicitly describes it as clearing and rescanning the whole history. ([GitHub][3])

The safe experiment is:

```powershell
reapack-index --rebuild --output index.rebuilt.xml --no-commit
```

Then compare `index.rebuilt.xml` semantically with the public `index.xml`.

Do not replace the public index merely because an external model said “rebuild.” First inspect what the rebuild actually reconstructs.

## Findings that are genuinely useful

### Add CI

Both audits are right that this repository is testing a package workflow almost entirely by hand. The official template included automated `reapack-index` execution through GitHub Actions, although that template is now archived and should be treated as a reference rather than copied blindly. ([GitHub][1])

A useful CI workflow would:

1. check out the complete Git history;
2. use pinned Ruby, `reapack-index` and Pandoc versions;
3. run `reapack-index --check --strict --warnings`;
4. verify that `index.xml` is well-formed XML;
5. compare historical versions semantically;
6. optionally verify that every source URL resolves.

CI does not replace REAPER itself, but it catches metadata and generation mistakes.

### Check before committing

The documented routine currently commits source changes and then runs `--check`. Since `--check` also tests uncommitted changes, running it before the source commit gives faster feedback. ([GitHub][3])

A better order is:

```text
edit → check → commit source → scan → inspect → commit index
```

Running the check again after committing is harmless and useful in CI.

### Protect published Git history

Your source URLs contain commit hashes. This is good because each version keeps pointing to the exact files it originally published. But it means you must not force-push or rewrite history in a way that removes those commits.

Beginner version:

> Once a commit is mentioned by `index.xml`, treat that commit as permanent.

Branch protection and a “no force-push after publication” rule are worthwhile. Current versions are indeed pinned to historical commit hashes.

### Complete actual ReaPack tests

Your repository audit honestly says these are still unverified:

* update an installed v1.0.1 to v1.0.2;
* clean-install v1.0.2;
* uninstall it;
* confirm an unrelated sentinel file survives.

These tests matter because static checks cannot prove that:

* ReaPack offers the update;
* files are replaced correctly;
* actions stay registered;
* package-owned files are removed;
* unrelated files remain;
* both About dialogs render correctly.

This is the most important unfinished work.

## Findings that are valid but overstated

### Linux behavior

Testing Linux once would be informative: does the package disappear, appear as incompatible, or show an empty version?

But it is not a high-severity defect. Linux is intentionally unsupported, and every provided file is restricted to Windows x64 or macOS.

Do **not** follow the audit’s suggestion to make licences unscoped merely to change Linux behavior. An unscoped source would intentionally install something on Linux, contradicting your stated design.

### Platform duplication

The 50 entries look repetitive because the same scripts and modules must be listed separately for `win64` and `darwin` while excluding Linux.

That is a maintenance cost, but it is not an architectural error. ReaPack permits a space-separated set of options and supports platform-specific sources. Additional provided files are `nomain` by default. ([GitHub][2])

Your duplication is serving an explicit purpose:

```text
install on Windows x64
OR install on macOS
NOT install on Linux
```

The useful improvement is an automated comparison ensuring the Windows and macOS Lua-file sets remain identical—not making the files unscoped.

### `test_neurocast_auth.lua`

The second audit correctly observes that this script uses a different module-loading and logging style. It has an extra bare-`json` fallback and duplicates helper logic.

That is a code-maintenance issue, not evidence of a ReaPack installation failure. Its current path setup is internally consistent, and no demonstrated failure was supplied. Treat this as optional refactoring after the ReaPack workflow has been proven.

## Incorrect findings from the second audit

Several findings should be discarded:

* **“XML declaration or named root may be missing.”** False. Both are present.
* **“README installation URL is blank.”** False. The URL is present.
* **“The binaries might use `[windows]` instead of `[win64]`.”** False for this repository. The manifest uses `[win64]`.
* **“`[main win64]` is undocumented or ambiguous.”** Not persuasive. The official syntax explicitly allows a space-separated list of options, and `main` and `win64` are both documented options. The generated XML correctly contains both `main="main"` and `platform="win64"`. ([GitHub][2])
* **“The current index is still corrupt.”** Outdated. The previously mangled changelog is now restored.

These errors probably arose from incomplete web fetching and from the model inspecting the repository while commits were changing.

## Recommended priority

1. **Stop using byte identity as the release invariant.**
2. **Document `--amend` as an exceptional repair tool, not a routine command.**
3. **Prohibit manual replacement of package/version XML blocks in the normal workflow.**
4. **Add CI validation with a pinned toolchain.**
5. **Perform the real v1.0.1 → v1.0.2 update and uninstall tests.**
6. **Optionally generate a temporary rebuilt index and compare it semantically.**
7. **Treat Linux behavior and `test_neurocast_auth.lua` cleanup as secondary work.**

The architectural core—one metapackage, `@noindex` support files, platform-scoped sources, commit-pinned versions, and separate package/repository About metadata—is sound. The blind spot is mainly **repeatability of the release process**, not the ReaPack package design itself.

[1]: https://github.com/cfillion/reapack-repository-template "GitHub - cfillion/reapack-repository-template: A GitHub repository template for ReaPack repositories using reapack-index for testing and deployment, automated using GitHub Actions. · GitHub"
[2]: https://github.com/cfillion/reapack-index/wiki/Packaging-Documentation "Packaging Documentation · cfillion/reapack-index Wiki · GitHub"
[3]: https://github.com/cfillion/reapack-index "GitHub - cfillion/reapack-index: Package indexer for git-based ReaPack repositories · GitHub"
