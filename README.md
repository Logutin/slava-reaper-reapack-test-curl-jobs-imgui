# Slava REAPER Test Suite

Interactive test scripts for REAPER, built with ReaImGui.

## Included Tests

| Script | Description |
|--------|-------------|
| **test_Curl_Jobs** | Async HTTP operations and background task scheduling |
| **test_Files** | Filesystem utilities, path manipulation, sandbox I/O |
| **test_docx** | DOCX archive extraction, XML parsing, dialogue extraction |
| **test_neurocast_auth** | Authentication flow testing against Neurocast endpoints |

## Requirements

- REAPER 7.0+
- ReaImGui (install via ReaPack)

## Platform Support

- **Windows x64** — full support (bundled curl and 7-Zip binaries)
- **macOS** — scripts and modules only (uses system utilities)

## Installation

1. Add this repository URL to ReaPack:
   `https://github.com/Logutin/slava-reaper-reapack-test-curl-jobs-imgui/raw/main/index.xml`
2. Install **Slava REAPER Test Suite** from the package browser.
3. Test scripts appear in the REAPER Actions list under the `Slava-Testing` category.

## License

See repository for license details.
