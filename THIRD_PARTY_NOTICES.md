# Third-party notices

ClassMirror contains or links the components below. Copyright notices in the
original source files remain authoritative.

## UxPlay

- Project: <https://github.com/FDH2/UxPlay>
- Imported release: `v1.73.7`
- Upstream commit: `df67c212a433cf6dda3676dd40c097900d24e645`
- License: GNU General Public License version 3
- Local source: `ThirdParty/AirPlayCoreTarget/Upstream`

ClassMirror embeds a modified receiver-only subset and replaces UxPlay's
GStreamer renderer with native macOS media pipelines. ClassMirror as a whole is
distributed under GPL-3.0. The full license is in `LICENSE`.

## PlayFair

- Included through UxPlay
- License: GNU General Public License version 3
- License text: `ThirdParty/AirPlayCoreTarget/Upstream/playfair/LICENSE.md`

## llhttp

- Included through UxPlay
- Version in imported headers: 9.3.0
- License: MIT
- License text: `ThirdParty/AirPlayCoreTarget/Upstream/llhttp/LICENSE-MIT`

## OpenSSL

- Release build version: 3.6.4
- Project: <https://www.openssl.org/>
- License: Apache License 2.0
- Acquisition and checksum: `script/build_vendor_dependencies.sh`

## libplist

- Release build version: 2.7.0
- Project: <https://github.com/libimobiledevice/libplist>
- License: GNU Lesser General Public License 2.1 or later
- Acquisition and checksum: `script/build_vendor_dependencies.sh`

Apple system frameworks used by the application are not redistributed with
ClassMirror.
