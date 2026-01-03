# Provenance

## Inspired By

**Repository**: [hyperpolymath/panoptes](https://github.com/hyperpolymath/panoptes)

## Challenge

The panoptes video analysis tool uses subprocess calls to `ffmpeg` and `ffprobe` for:
- Video metadata extraction (`ffprobe -show_format -show_streams`)
- Frame extraction and analysis
- Format detection

**Location**: `src/analyzers/video.rs` (lines 26-44)

```rust
// Current approach - subprocess call
Command::new("ffprobe")
    .args(["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams"])
    .arg(&path)
    .output()
```

## Problem

1. **Performance**: Each video file spawns a new ffprobe process
2. **Parsing overhead**: JSON output must be parsed from stdout
3. **Error handling**: Process errors are harder to handle than FFI errors
4. **Batch operations**: Analyzing many files is slow due to process spawn overhead

## Solution

This Zig FFI library provides direct bindings to libavformat/libavcodec (FFmpeg's core libraries), enabling:
- In-process metadata extraction
- Direct access to codec parameters
- Streaming analysis without temp files
- Batch processing without process spawn overhead

## How It Helps

| Before (subprocess) | After (FFI) |
|---------------------|-------------|
| ~50ms per file (process spawn) | ~2ms per file |
| JSON parsing required | Direct struct access |
| stderr/stdout parsing | Proper error types |
| One file at a time | Batch streaming |

## Usage in panoptes

Replace subprocess calls with FFI:
```zig
const ffmpeg = @import("zig-ffmpeg-ffi");
const meta = try ffmpeg.probe(path);
defer meta.deinit();
// Direct access to duration, codec, bitrate, etc.
```
