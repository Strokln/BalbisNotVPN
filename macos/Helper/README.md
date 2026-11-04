# Privileged PAC helper

Build each architecture with Swift 5 and the macOS 13 target, then combine with `lipo`:

```
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 HelperProtocol.swift main.swift -framework SystemConfiguration -o helper-arm64
xcrun swiftc -swift-version 5 -target x86_64-apple-macos13.0 HelperProtocol.swift main.swift -framework SystemConfiguration -o helper-x86_64
lipo -create helper-arm64 helper-x86_64 -output helper
./helper --self-test
```

The installer must create `/Library/PrivilegedHelperTools/local.balbis.proxy` owned by root with no group/other write bits, containing `helper` and root-owned `config.json` (`{"uid":501}`, using the actual authorized non-root user ID). All ancestors must be real root-owned directories without group/other write permission. The daemon stores its independent journal and lock there. Do not remove an existing journal during upgrades or UID changes. Root starts the daemon through launchd; this directory contains no installer.

Wire messages are one JSON object plus newline. Only `ping`, `install`, and `restore` exist. Ping returns version `1`; install returns `installed`; restore returns `restored`, or `no-session` when no privileged journal exists. Failures return `success:false`. Peer UID must match configuration even for ping. Install and restore require service name, session UUID and strict loopback PAC URL.

Offline tests exercise URL rejection, conflicting proxy flags, exact PAC restoration, empty URL removal and preservation of unrelated newer settings. They never read privileged state, bind a socket, or modify networking. Live launchd, authorization, concurrent VPN changes and network preference application need separate controlled integration testing. A crash between commit and apply retains the journal; install retries re-apply preferences. A restoration whose current URL no longer belongs to the session releases its journal without changing settings.

Installer/uninstaller may invoke the digest-verified helper with `--check-stopped` as root after launchd bootout. This read-only probe validates helper storage and an existing root-owned regular `daemon.lock`, then waits at most five seconds to acquire its process lock. It creates no files, opens no sockets, and performs no network operations. A live lock or unsafe storage fails the probe; non-root invocation is rejected.
