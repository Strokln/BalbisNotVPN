# Native macOS engine

Upstream: https://github.com/bol-van/zapret, pinned revision
`73ee2aa04e6e94922e7dc07554a1c3a456dc3201`.
Archive SHA256: `dcef784d413ef95e98b34f0b657aac801b1f9b0601d6d9d95f6bf418d18e4533`.
Only tpws and its license/readme are vendored, without source modifications.
MIT license: vendor/zapret-*/docs/LICENSE.txt. epoll-shim attribution is
preserved separately in EPOLL-SHIM-LICENSE (https://github.com/jiixyj/epoll-shim).

`./build.sh x86_64 [output]` or `./build.sh arm64 [output]` compiles using
Apple Command Line Tools and system zlib/pthreads; no installs or root.
ARCH environment variable is accepted when positional architecture is absent.
Both architectures cross-compile with deployment target macOS 13.
`./fetch.sh` verifies the pinned source archive; the supplied source tree
allows offline builds.

Foreground invocation (replace PORT):

```
tpws --bind-addr=127.0.0.1 --port=PORT --socks
```

Strategies (append to the base invocation):

* Baseline: no extra flags.
* TCP split: `--split-pos=1,midsld`
* TCP + TLS record split: `--split-pos=1,midsld --tlsrec=sniext+1`

Readiness: connect to loopback PORT, send bytes `05 01 00`, require reply
`05 00`, then close. Also check child process termination while waiting.
A TCP listener alone does not prove SOCKS readiness. Stop via SIGTERM and wait.
Never use --daemon in the app. Upstream intentionally rejects CONNECT to local
interface addresses (including loopback). SOCKS has no authentication, so keep
binding to loopback. It supports TCP CONNECT, not UDP/QUIC. Only traffic explicitly
sent through SOCKS is processed. Split strategies are heuristics, with no
assurance of bypassing a particular remote DPI.

Local verification: `python3 macos/tests/test_engine.py -v` from Balbis root.
The tests build a separate disposable test-only executable with the
`test-loopback.patch` applied in a temporary source directory. It relaxes the
local destination guard solely for test endpoints; shipped binaries keep the
guard. Tests cover HTTP byte preservation and real TLS ping/pong for all three
strategies, plus byte-for-byte reassembly of two generated TLS ClientHello records.
The tests never touch system proxies, VPN, routes, or DNS settings.
Native runtime tested on macOS 13 Intel; arm64 is cross-compiled, not executed.
TCP writes can be coalesced by the network stack; TLS record split is verified
at the record level, and no claim about observed wire packet boundaries is made.
