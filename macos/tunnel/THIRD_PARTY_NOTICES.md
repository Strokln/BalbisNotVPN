# macOS foreign-exit backend notices

Opera-proxy v1.31.0 from https://github.com/Alexey71/opera-proxy,
revision 453aa18803760c9c2d3cec9d666845df44a2ec10, is launched as a separate process.
The unmodified release binaries are downloaded with SHA-256 verification.
MIT license text: LICENSE. Dependency notices: licenses/ in source; copied alongside
this file in Balbis.app/Contents/Resources/licenses-opera/ in binary bundles.
They cover Go runtime, golang.org/x/net, golang.org/x/crypto, go-dns,
go-socks5, go-multierror, and go-http-digest-auth-client.
See the upstream source tree in vendor/ for original copyright and attribution.

The app's stdlib-only balbis-router also uses the Go runtime (go-runtime.txt).
The public SurfEasy/Opera service has its own availability and vendor terms;
this project is not affiliated with or endorsed by Opera or SurfEasy.
