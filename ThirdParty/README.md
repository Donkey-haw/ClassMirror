# Third-party components

ClassMirror embeds a modified subset of the UxPlay v1.73.7 receiver core. The
upstream renderer and GStreamer integration are not included; ClassMirror uses
VideoToolbox, Metal, AudioToolbox, and AVAudioEngine instead.

- Project: <https://github.com/FDH2/UxPlay>
- Tag: `v1.73.7`
- Commit: `df67c212a433cf6dda3676dd40c097900d24e645`
- Archive SHA-256: `65feb8732de666a7161a9e562aa603a7f5fe0ebb890c2a30c5e1a9c85c76309f`
- License: GPL-3.0

The imported source is stored in `AirPlayCoreTarget/Upstream`. Only the
receiver subset needed by the app is imported, and the Swift-facing wrapper
lives outside it in `AirPlayCoreTarget/ClassMirrorReceiver.c`. The original
copyright and license headers are retained.

The following upstream files are modified. Each carries a
`modified for ClassMirror` line in its header:

| File | Change |
| --- | --- |
| `dnssd.c`, `dnssd.h` | Optional peer-to-peer (AWDL) Bonjour registration; the RAOP `sf` TXT record is omitted |
| `netutils.c`, `netutils.h` | `SO_RECV_ANYIF` on listening sockets in peer-to-peer mode |
| `pairing.c`, `pairing.h` | SRP proof lengths are validated and sized for SHA-1 (20 bytes) |
| `raop.c`, `raop_handlers.h` | Digest-auth nonce is kept per RTSP connection; only submitted PIN attempts count as failures; buffers are freed on an invalid SRP proof length |

To list the exact changes, diff `AirPlayCoreTarget/Upstream` against `lib/` in
the pinned UxPlay archive (`script/bootstrap_phase0.sh` extracts it to
`.phase0/UxPlay-1.73.7`).

`script/bootstrap_phase0.sh` separately downloads the fixed archive into the
ignored `.phase0/` directory. That build is only a comparison baseline.

The Phase 0 runner uses UxPlay's per-connection random-code mode (`-pw` with no fixed password). It intentionally keeps UxPlay's default active-client lock; `-nohold` is not enabled because that option allows a new client to evict the active classroom session.

Additional components:

- llhttp 9.3.0 — MIT
- PlayFair — GPL-3.0
- OpenSSL 3.6.4 — Apache-2.0; downloaded and checksum-verified for Release builds
- libplist 2.7.0 — LGPL-2.1-or-later; downloaded and checksum-verified for Release builds

See `../THIRD_PARTY_NOTICES.md`, the source headers, and the license files next
to the imported components. Release app bundles include the applicable license
texts in `Contents/Resources/ThirdPartyNotices`.
