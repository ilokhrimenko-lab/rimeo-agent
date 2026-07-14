# iOS + Intel Playback Issue

## Problem

On the iOS + Intel/macOS agent path, playback does not start immediately for some tracks, especially AIFF files.

The observed case:

- Track ID: `18575226`
- Source file: `Mahoo (CH) - California (Extended Mix).aiff`
- Agent receives `/stream` requests.
- File access succeeds.
- AIFF conversion succeeds.
- The local HTTP server returns `206 Partial Content`.
- Playback still fails or stalls shortly after the large audio range response begins.

## Evidence From Logs

The log shows that file access is not the failing point:

```text
TCC path result: operation=stream, location=downloads, exists=true, readable=true
```

AIFF conversion also succeeds:

```text
AIFF conversion complete: track=18575226, wav=.../conv_18575226.wav, bytes=53981172
```

The first browser/iOS probe request asks for only two bytes:

```text
Stream request: track=18575226, range=bytes=0-1
Stream response: status=206, bytes=0-1/53981172, length=2
```

Immediately after that, the client requests the entire converted WAV:

```text
Stream request: track=18575226, range=bytes=0-53981171
Stream response: status=206, bytes=0-53981171/53981172, length=53981172
```

Then Cloudflare closes the stream:

```text
cloudflared: ERR error="http2: stream closed"
cloudflared: ERR failed to serve incoming request error="Failed to proxy HTTP: http2: stream closed"
```

## Most Likely Root Cause

The failure is most likely caused by the combination of:

1. AIFF being converted to a large WAV file before playback.
2. iOS requesting the full WAV range instead of small progressive ranges.
3. Cloudflare tunnel / HTTP/2 closing the large audio stream before playback can stabilize.

This is not primarily a path, TCC, or ffmpeg issue. The agent successfully reads the file, converts it, and starts responding with valid `206` range responses.

## Secondary Issue

For AIFF files, conversion currently happens before range handling. That means even a tiny probe request like `bytes=0-1` triggers full AIFF to WAV conversion before the first audio bytes are returned.

This adds startup delay and makes the first playback attempt fragile.

## Architectural Constraint

The cloud relay path is not suitable for audio streaming.

The relay buffers local responses into memory and sends them back as base64 JSON. This can work for small endpoints such as `/api/status`, `/waveform`, and `/artwork`, but it is not a good transport for large audio ranges.

For remote playback, `/stream` should use a direct streaming transport such as Cloudflare tunnel, not the JSON relay.

## Recommended Solution

Use a stream-friendly cached audio format for remote playback instead of serving converted AIFF as WAV.

Recommended target format:

- AAC in M4A container, or
- MP3 as a fallback if AAC compatibility or tooling is a concern.

AAC/M4A is preferred because it is natively supported by iOS and produces much smaller files than WAV.

## Proposed Implementation Path

### 1. Add Stream Cache Conversion

Add a new conversion path for AIFF/AIF remote playback:

```text
AIFF source -> cached M4A/AAC stream file
```

Example cache name:

```text
stream_<trackID>.m4a
```

The existing WAV cache can remain for waveform, analysis, or local workflows if needed.

### 2. Serve M4A for AIFF `/stream`

When `/stream` receives an AIFF/AIF track:

- Ensure the stream cache exists.
- Serve the cached `.m4a` file.
- Return `Content-Type: audio/mp4`.
- Keep `Accept-Ranges: bytes`.
- Keep `206 Partial Content` behavior.

### 3. Prewarm Stream Cache

When the user opens a track, loads artwork, loads waveform, or triggers preload:

- Start stream-cache conversion in the background.
- Do not block `/waveform` or `/artwork`.
- Log whether playback uses a cache hit or waits for conversion.

This reduces first-play latency.

### 4. Avoid Full WAV Over Tunnel

Do not use the converted WAV file as the primary remote playback source for AIFF tracks.

WAV is too large and encourages heavy range requests such as:

```text
bytes=0-53981171
```

That is the exact shape that appears before Cloudflare closes the stream.

### 5. Improve Diagnostics

Add explicit stream transport logs:

```text
Stream source selected: track=<id>, source=aiff, served_format=m4a, bytes=<size>
Stream source selected: track=<id>, source=aiff, served_format=wav, reason=fallback
```

Also log whether a request is coming through:

- Cloudflare tunnel
- cloud relay
- local network

## Acceptance Criteria

Playback should be considered fixed when:

1. AIFF playback on iOS starts within a few seconds on first play.
2. Repeat playback starts quickly from cache.
3. Logs show AIFF served as `.m4a` or another compact stream format, not large WAV.
4. `/stream` still returns valid `206`, `Content-Range`, `Accept-Ranges`, and `Content-Length`.
5. Cloudflare no longer logs `http2: stream closed` immediately after full-file audio range requests.
6. Existing WAV, MP3, M4A, FLAC, and artwork/waveform endpoints continue to work.

## Verification Plan

Run local tests:

```bash
swift test
```

Manual checks:

1. Start the macOS Intel agent.
2. Confirm `cloudflared_found=true`.
3. Confirm `stream_transport=tunnel`.
4. Play the problematic AIFF track from iOS.
5. Confirm logs show stream cache conversion to M4A/AAC.
6. Confirm the stream response size is much smaller than the previous `53981172` byte WAV.
7. Confirm playback starts without Cloudflare `http2: stream closed` errors.

## Current Confidence

High confidence that the immediate playback failure is related to serving a large converted WAV over the remote streaming path.

Medium confidence that switching AIFF remote playback to cached M4A/AAC will resolve the issue fully. The remaining uncertainty is iOS browser behavior through the current web app and Cloudflare tunnel, which must be verified on the target Intel machine.

