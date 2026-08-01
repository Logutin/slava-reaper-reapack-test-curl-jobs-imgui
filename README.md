# Slava REAPER Test Suite

Interactive test scripts for REAPER, built with ReaImGui and distributed as one
ReaPack metapackage.

## Included Tests

| Script | Description |
|---|---|
| **test_Curl_Jobs** | Async HTTP operations and background task scheduling |
| **test_Files** | Filesystem utilities, path manipulation, and sandbox I/O |
| **test_docx** | DOCX archive extraction, XML parsing, and dialogue extraction |
| **test_neurocast_auth** | Authentication flow testing against Neurocast endpoints |

## Requirements

- REAPER 7.0+
- ReaImGui (install via ReaPack)

## Platform Support

- **Windows x64** — scripts and modules, plus bundled curl 8.13.0 and 7-Zip 26.00
- **macOS** — scripts and modules; uses `/usr/bin/curl` and system `unzip`
- **Linux** — intentionally unsupported; the index exposes no installable sources

## Installation

1. Add this repository URL to ReaPack:
   `https://github.com/Logutin/slava-reaper-reapack-test-curl-jobs-imgui/raw/main/index.xml`
2. Install **Slava REAPER Test Suite** from the package browser.
3. Find the four test scripts in REAPER's Actions list under `Slava-Testing`.

## License and Notices

Slava Logutin's Lua code is licensed under the
[MIT License](https://github.com/Logutin/slava-reaper-reapack-test-curl-jobs-imgui/blob/main/LICENSE).
Bundled binaries, generated Unicode data, and the third-party JSON module retain
their own terms. See the complete
[third-party notices and binary provenance](https://github.com/Logutin/slava-reaper-reapack-test-curl-jobs-imgui/blob/main/THIRD_PARTY_NOTICES.md).

The applicable license and notice files are installed with the package under
`Scripts/Slava-Testing/licenses/`.
