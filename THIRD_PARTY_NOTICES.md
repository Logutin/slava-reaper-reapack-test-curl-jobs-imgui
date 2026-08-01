# Third-Party Notices and Binary Provenance

The repository's own Lua code is licensed under the root MIT license. The
components below retain their own licenses. Copies of the notices required at
installation time are in `Slava-Testing/licenses/` and are delivered by the
ReaPack metapackage on the platforms where the corresponding components are
installed.

## Microsoft Windows inbox curl

The Windows package redistributes a copy of the curl executable shipped as a
standard Microsoft Windows component.

| Field | Value |
|---|---|
| Committed file | `Slava-Testing/bin/win/curl.exe` |
| Product and version | curl 8.13.0 / libcurl 8.13.0; release date 2025-04-02 |
| Architecture | Windows x86-64 (PE machine `0x8664`) |
| Original location | `C:\Windows\System32\curl.exe` |
| Upstream information | <https://curl.se/windows/microsoft.html> and <https://learn.microsoft.com/windows/curl/> |
| Original archive filename | Not applicable: copied from the Windows-serviced system component, not from a standalone curl archive |
| Date obtained | 2026-03-02 (earliest preserved creation timestamp of the source copy) |
| SHA-256 | `3345339164CF384EFF527B6C3160FEA8D849A4231EC6CA80513E3A739E505168` |
| Signature | Valid Microsoft code signature; signer: Microsoft 3rd Party Application Component |
| License | curl license (`licenses/curl-COPYING.txt`) |

`curl --version` reports Schannel, zlib 1.3.1, and WinIDN. Schannel and WinIDN
are Windows system facilities rather than bundled redistributable libraries.
zlib 1.3.1 is linked into this Microsoft build; its notice is reproduced in
`licenses/zlib-LICENSE.txt`. The executable's PE imports resolve only to
Windows system DLLs.

## 7-Zip

The Windows package redistributes parts of 7-Zip: `7z.exe` and `7z.dll` from
the official 7-Zip 26.00 x64 installer.

| Field | `7z.exe` | `7z.dll` |
|---|---|---|
| Product and version | 7-Zip 26.00 | 7-Zip 26.00 |
| Architecture | Windows x86-64 (PE machine `0x8664`) | Windows x86-64 (PE machine `0x8664`) |
| Upstream download | <https://7-zip.org/a/7z2600-x64.exe> | <https://7-zip.org/a/7z2600-x64.exe> |
| Original archive filename | `7z2600-x64.exe` | `7z2600-x64.exe` |
| Date obtained | 2026-03-12 (earliest preserved creation timestamp of the source copy) | 2026-04-16 (earliest preserved creation timestamp of the source copy) |
| SHA-256 | `4A41AA37786C7EAE7451E81C2C97458D5D1AE5A3A8154637A0D5F77ADC05E619` | `BBD705E3B58CA7677C1E9E67473F166A6712DA034DCB567D571FBB67507A443F` |

The downloaded installer used for provenance verification has SHA-256
`6FE18D5B3080E39678CABFA6CEF12CFB25086377389B803A36A3C43236A8A82C`.
Fresh extraction reproduced both committed binary hashes exactly.

Most 7-Zip code is licensed under GNU LGPL 2.1 or later. `7z.dll` also
contains code governed by BSD 3-Clause, BSD 2-Clause, and the unRAR license
restriction. The exact 7-Zip 26.00 `License.txt`, including the required BSD
and unRAR notices, is reproduced at `licenses/7-Zip-License.txt`. The license
identifies LZFSE decompression, Zstandard decompression, XXH64, and unRAR-derived
decompression code. `7z.exe i` reports the bundled 7z library as `7z.dll`
version 26.00. Upstream source for the redistributed version is available at
<https://7-zip.org/a/7z2600-src.7z> and the release announcement is at
<https://sourceforge.net/p/sevenzip/discussion/45797/thread/a1f7e08417/>.

## Unicode Character Database

`Slava-Testing/modules/Utf8SimpleLowerData.lua` is generated from the simple
lowercase mappings in Unicode 17.0.0 `UnicodeData.txt`. An exact comparison
against the upstream data produced 1,488 matching mappings with no difference.

- Source: <https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt>
- License: Unicode License V3, reproduced at
  `Slava-Testing/licenses/Unicode-License.txt`

## rxi json.lua

`Slava-Testing/modules/json.lua` is based on rxi's `json.lua` and retains its
full MIT copyright and permission notice in the source file itself.

- Upstream: <https://github.com/rxi/json.lua>
- License: MIT (the notice is embedded in every installed copy of the module)
