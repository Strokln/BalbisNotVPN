# Third-party notices

Balbis by Strokin is distributed under the root MIT LICENSE. Vendored components retain their original licenses; that root license does not replace their terms.

- tpws from bol-van/zapret, revision 73ee2aa04e6e94922e7dc07554a1c3a456dc3201: macos/engine/vendor/zapret-*/docs/LICENSE.txt. Includes epoll-shim (macos/engine/EPOLL-SHIM-LICENSE), uthash, kavl and platform headers with per-file notices. Preserve these notices when redistributing sources.
- opera-proxy v1.31.0, revision 453aa18803760c9c2d3cec9d666845df44a2ec10: macos/tunnel/LICENSE and macos/tunnel/vendor/opera-proxy-1.31.0/LICENSE. Dependency and Go runtime licenses are in macos/tunnel/licenses; these include Apache-2.0 go-multierror and BSD/MIT dependencies.
- Go runtime used by Balbis's own router: macos/tunnel/licenses/go-runtime.txt.
- System frameworks, zlib and system libraries are supplied by macOS, not redistributed here.

Source archives and downloaded binaries are pinned by checksum in the component scripts and documentation. Downloaded tools and prebuilt binaries are excluded from this source tree.
