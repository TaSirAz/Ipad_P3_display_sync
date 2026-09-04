# iPadDisplay Native — 2360×1640

iPad receiver for the Windows iPadDisplay V7.1 native-resolution (M) driver and USB sender. Requires iPadOS 17 or later. This is an Xcode iPad application, with GitHub Actions configured to compile it on a macOS runner.

## Build and install

1. Open **Actions → Build native iPad IPA**. A push to `main` touching the app or build workflow also starts a build.
2. Download the successful run's **iPadDisplayNative-unsigned** artifact and extract the IPA.
3. The IPA is **unsigned**. Sign and install it locally on your own iPad using your Apple account, for example with [Sideloadly for Windows](https://sideloadly.io/). No Apple password or signing certificate belongs in this repository. Free-account profiles expire after seven days and need refreshing. Xcode on a Mac can also run the project with your Personal Team.
4. Open **iPadDisplay Native** on iPad. Wait for `READY v3 • NATIVE 2360×1640 • USB :55001`.
5. Only then switch the Windows driver and sender to the matching M build. The Windows `--probe-receiver` command verifies the native receiver handshake before installation.

This uses a distinct app identifier (`local.iPadDisplayV7.Native`) and USB port, so the previous receiver can remain installed for rollback. Tap the image to hide/show the status overlay. Keep the app in the foreground and landscape, full screen.

## Transport and display

- Source framebuffer: 2360×1640, 128-pixel tiles, 19×13 grid. Last tile is 56×104. The first tiled frame must contain all 247 tiles; complete-frame packet types publish atomically.
- USB port 55001. Receiver sends a 32-byte `IPD71ACK` handshake: version 3, width, height, 60 Hz, DXGI format 24 (BGR10A2), tile size 128; all numeric fields little-endian UInt32.
- Sender packets retain the 32-byte header / 16-byte tile-header layout, with new magic `IPD71RAW`. Types 1=tile, 2=commit and 3=complete RAW frame (15,481,600 bytes, no extra commit), and 4=complete lossless RAW frame. Header reserved fields are zero.
- Metal texture and drawable use `bgr10a2Unorm` and Display P3. No JPEG/H.264, chroma subsampling, or 8-bit intermediate is introduced by this receiver.
- GPU completion gates CPU texture reuse. The receiver rejects partial initial frames, duplicate tiles, out-of-bounds tiles and mixed batches.
- 60 Hz is the requested display refresh. Sustained 60 distinct full-screen frames per second still requires measurement; raw full-frame payload alone is 7.431 Gbit/s before overhead.

## Validation

The workflow runs actual Swift framebuffer tests (native edges, 247 tiles, immutable snapshots, malformed batches), then builds the device application with Xcode. Windows tests and physical iPad checks are separate. A source archive is not proof that Xcode compilation or physical display validation has passed: consult the workflow result.

The v3 receiver sends 32-byte IPD71STA reports: sequence, total received frames and actual Metal presentations (three little-endian UInt64 values). Reset blank frames are excluded. RX and shown counters measure different stages; static content does not imply 60 changing frames.


Type 4 uses independent raw LZ4 blocks compatible with Apple's `COMPRESSION_LZ4_RAW`. The payload begins with four little-endian UInt32 fields: codec=1, block count (1..64), decoded frame bytes=15481600, reserved=0. A table follows with two UInt32 fields per block: decoded size and encoded size. Bit 31 of encoded size marks an uncompressed block; its lower 31 bits are the byte count. Block bytes follow the table. Every frame is self-contained. No earlier framebuffer is needed to decode it. Incorrect totals, incomplete blocks, decoded overflow, old sequences and invalid headers are rejected before publication.

The Windows fixture in `tests/fixtures/bgr10a2-lz4.bin` contains only a generated synthetic pattern. The workflow uses Apple Compression to decode it and compares all 3,870,400 pixels against the original 10-bit values; it also checks malformed and truncated payloads. Compression changes the number of transmitted bytes, not the pixel values, gamut, channel precision or resolution. Incompressible frames can use the uncompressed type 3 packet.

Build 5 (protocol v3) passed the Swift tests and the Xcode device build in run 33888253210. Real iPad throughput and presentation rate must still be measured for each transport mode and workload.
