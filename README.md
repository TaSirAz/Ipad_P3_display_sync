# iPadDisplay Native — 2360×1640

iPad receiver for the Windows iPadDisplay V7.1 native-resolution (M) driver and USB sender. Requires iPadOS 17 or later. This is an Xcode iPad application, with GitHub Actions configured to compile it on a macOS runner.

## Build and install

1. Open **Actions → Build native iPad IPA**. A push to `main` touching the app or build workflow also starts a build.
2. Download the successful run's **iPadDisplayNative-unsigned** artifact and extract the IPA.
3. The IPA is **unsigned**. Sign and install it locally on your own iPad using your Apple account, for example with [Sideloadly for Windows](https://sideloadly.io/). No Apple password or signing certificate belongs in this repository. Free-account profiles expire after seven days and need refreshing. Xcode on a Mac can also run the project with your Personal Team.
4. Open **iPadDisplay Native** on iPad. Wait for `READY • NATIVE 2360×1640 • USB :55001`.
5. Only then switch the Windows driver and sender to the matching M build. The Windows `--probe-receiver` command verifies the native receiver handshake before installation.

This uses a distinct app identifier (`local.iPadDisplayV7.Native`) and USB port, so the previous receiver can remain installed for rollback. Tap the image to hide/show the status overlay. Keep the app in the foreground and landscape, full screen.

## Transport and display

- Source framebuffer: 2360×1640, 128-pixel tiles, 19×13 grid. Last tile is 56×104. The first committed frame must contain all 247 tiles.
- USB port 55001. Receiver sends a 32-byte `IPD71ACK` handshake: version 1, width, height, 60 Hz, DXGI format 24 (BGR10A2), tile size 128; all numeric fields little-endian UInt32.
- Sender packets retain the 32-byte header / 16-byte tile-header layout, with new magic `IPD71RAW`. Types 1=tile and 2=commit. Header reserved fields are zero.
- Metal texture and drawable use `bgr10a2Unorm` and Display P3. No JPEG/H.264, chroma subsampling, or 8-bit intermediate is introduced by this receiver.
- GPU completion gates CPU texture reuse. The receiver rejects partial initial frames, duplicate tiles, out-of-bounds tiles and mixed batches.
- 60 Hz is the requested display refresh. Sustained 60 distinct full-screen frames per second still requires measurement; raw full-frame payload alone is 7.431 Gbit/s before overhead.

## Validation

The workflow runs actual Swift framebuffer tests (native edges, 247 tiles, immutable snapshots, malformed batches), then builds the device application with Xcode. Windows tests and physical iPad checks are separate. A source archive is not proof that Xcode compilation or physical display validation has passed: consult the workflow result.
