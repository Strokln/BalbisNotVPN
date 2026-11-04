# Opera HTTP CONNECT backend

Upstream: https://github.com/Alexey71/opera-proxy, MIT, v1.31.0,
revision 453aa18803760c9c2d3cec9d666845df44a2ec10.
`vendor/opera-proxy-1.31.0` contains the unmodified source and its license.
Source archive SHA256: acd8aa1dd65385293f89c83dcffcbb1e0ec34282ad2faf8ebc08762bcbcae627.
`LICENSE` and `licenses/` preserve upstream/dependency/runtime notices.

`fetch.sh` retrieves pinned release binaries and verifies SHA256 before installing:

| Architecture | SHA256 |
| --- | --- |
| x86_64 | bf68aeac95311d9a7c7229249a3188901bb252beff18737e2643e2558efcbb2a |
| arm64 | 9f2b2b268d5d5ffe272cc40f07df374190becab65117512d683f3a17b90a9d25 |

Binaries report v1.31.0 and include Go1.27.3 runtime (CGO disabled).
Intel binary launched and real HTTP CONNECT/TLS traffic tested on macOS13.
Arm64 Mach-O has deployment minimum 13.0; runtime testing requires Apple Silicon.
Source go.mod requires Go1.26.0 and requests toolchain Go1.27.3. No Go installation
is needed for these prebuilt Opera binaries. For the app's separate stdlib router,
`fetch-go.sh` installs checksum-pinned Go1.26.10 under `macos/build/tools/go`,
without changing PATH or global installations. This compiler runs on this Intel
macOS13 host and can cross compile with `CGO_ENABLED=0 GOOS=darwin
GOARCH=amd64|arm64 GOTOOLCHAIN=local`.

## Foreground server interface

```
opera-proxy -bind-address 127.0.0.1:PORT -country EU \
  -init-retries 1 -timeout 12s -server-selection fastest \
  -server-selection-timeout 20s \
  -server-selection-test-url https://www.cloudflare.com/cdn-cgi/trace \
  -server-selection-dl-limit 4096 -verbosity 40
```

Use this long-running command without `-list-proxies`. Registration is anonymous
and automatic; no user server or Opera credentials are required. EU is a regional
preference, not a guarantee of a particular country or AI service acceptance.
No persistent state directory is needed; optionally use an app-owned per-session
cwd. Send SIGTERM, then wait; escalate to SIGKILL only after a bounded timeout.
Use an actual HTTPS CONNECT fetch through localhost as health check. A listening
socket alone cannot verify that an overseas exit works.

Optionally add `-proxy socks5://127.0.0.1:TPWS_PORT` to send API/tunnel dial-outs
through tpws DPI segmentation. This must point directly to tpws, never to a router
that sends AI traffic back to Opera. This chain was tested successfully for EU
and AM. `-fake-SNI` exists but was not necessary or tested.

Builtin fastest selection benchmarks candidates before serving. On failure retry
with `-country AM`; no silent DIRECT fallback. If desired, enumerate candidates
with `-country EU,AM -list-proxies-all-out /session/endpoints.csv -verbosity 40`.
This CSV contains only endpoint metadata, no credentials. Header:
`country_code,country_name,host,ip_address,port`. Optional benchmark adds
`speed_ms,speed_status`; usable status is `ok`.
`endpoints.py` demonstrates this safe discovery, validates global IP addresses and
ports, deduplicates them, and prints JSON. `--through-socks TPWS_PORT` is supported.
Choose an endpoint using normal server mode and `-override-proxy-address IP:PORT`.
Do not use `-list-proxies` in app logs: that separate mode emits live login,
password and Proxy-Authorization before CSV. Do not copy private Windows Balbis
relay keys; none are present in this macOS backend.

## Verification and limitations

`python3 macos/tests/test_tunnel_backend.py -v`: four offline tests cover pinned
binary integrity, native launch/flags, CSV filtering/deduplication and failed
benchmark exclusion. `python3 macos/tunnel/probe.py --country EU` is an explicit
live integration probe with disposable localhost port, process, cwd and log. It
returns exit country without exposing an IP or authentication output.

Observed 2026-11-04: API anonymous/device registration succeeds. EU discovery
included 77.111.244.47:443 (timed out) and 77.111.247.19:443 (TLS success,
Netherlands/Amsterdam). AM 77.111.246.61:443 returned US/Ashburn. These are
observations, not pinned production servers. Builtin fastest EU also selected a
working NL exit without an override. Both successful endpoints worked when
Opera's dial-outs went through local tpws split/TLS-record segmentation.

Opera is a third-party shared service with changeable reachability and no SLA;
regional exit does not guarantee ChatGPT/Claude/Gemini access. If unavailable,
the application can explicitly import the user's own upstream proxy. Opera's
`-proxy` flag is a transport to Opera, not a standalone external-proxy replacement:
that fallback belongs in the app/router. Only proxy-aware TCP traffic is carried;
UDP/QUIC and system VPN routing are outside this backend. Tests changed no VPN,
DNS, system proxies or network routes.
