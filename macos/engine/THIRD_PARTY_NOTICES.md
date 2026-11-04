# macOS engine notices

This bundle launches an unmodified, separate tpws executable from zapret:
https://github.com/bol-van/zapret
Pinned revision: 73ee2aa04e6e94922e7dc07554a1c3a456dc3201.
License: MIT. Full text: LICENSE-tpws.txt in the app, or
vendor/zapret-73ee2aa04e6e94922e7dc07554a1c3a456dc3201/docs/LICENSE.txt in source.

The macOS build includes the epoll-shim sources shipped with tpws:
https://github.com/jiixyj/epoll-shim
License: MIT. Full text: EPOLL-SHIM-LICENSE.txt in the app, or
engine/EPOLL-SHIM-LICENSE in source. Per-file upstream notices remain in source.

The binary dynamically links the zlib and system libraries supplied with macOS.
