# Curl + Jobs ReaImGui Test

A standalone copy of the REAPER-hosted `Curl` + `Jobs` interactive tester from the private `Logutin/auphonic-mt` repository, with only the local runtime dependencies needed by this test.

## Runtime requirements

- REAPER
- ReaImGui installed through ReaPack
- `curl` available on the operating system PATH

Windows 10/11 normally includes `curl.exe`. On macOS the script uses `/usr/bin/curl`.

## Layout

- `test_Curl_Jobs.lua` — ReaImGui test entry point
- `modules/` — minimal Lua dependency set copied from the source repository

## Install manually

Copy the complete folder into REAPER's `Scripts` directory, preserving the `modules` subfolder, then load `test_Curl_Jobs.lua` from REAPER's Action List.

The script writes temporary test artifacts under REAPER's resource path at `Data/Curl_Jobs_Module_Test/tmp`.

## Source policy

`Logutin/auphonic-mt` is treated as read-only. Development and packaging changes belong only in this repository.
