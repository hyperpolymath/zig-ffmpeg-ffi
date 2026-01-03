// SPDX-License-Identifier: AGPL-3.0-or-later
//! Zig FFI bindings for FFmpeg (libavformat, libavcodec, libavutil)
//!
//! Provides high-level Zig interface for video/audio metadata extraction
//! and format operations, replacing subprocess calls to ffprobe/ffmpeg.
//!
//! Inspired by: hyperpolymath/panoptes video analysis needs

const std = @import("std");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/dict.h");
    @cInclude("libavutil/rational.h");
});

pub const Error = error{
    OpenFailed,
    StreamInfoFailed,
    NoStreams,
    InvalidStream,
    CodecNotFound,
    AllocationFailed,
};

/// Media stream type
pub const StreamType = enum {
    video,
    audio,
    subtitle,
    data,
    attachment,
    unknown,

    pub fn fromAvMediaType(media_type: c.AVMediaType) StreamType {
        return switch (media_type) {
            c.AVMEDIA_TYPE_VIDEO => .video,
            c.AVMEDIA_TYPE_AUDIO => .audio,
            c.AVMEDIA_TYPE_SUBTITLE => .subtitle,
            c.AVMEDIA_TYPE_DATA => .data,
            c.AVMEDIA_TYPE_ATTACHMENT => .attachment,
            else => .unknown,
        };
    }
};

/// Stream information
pub const StreamInfo = struct {
    index: u32,
    stream_type: StreamType,
    codec_name: ?[]const u8,
    codec_long_name: ?[]const u8,
    width: ?u32,
    height: ?u32,
    sample_rate: ?u32,
    channels: ?u32,
    bit_rate: i64,
    duration_seconds: f64,
    frame_rate: ?f64,
};

/// Media file metadata
pub const MediaInfo = struct {
    format_name: ?[]const u8,
    format_long_name: ?[]const u8,
    duration_seconds: f64,
    bit_rate: i64,
    streams: []StreamInfo,
    metadata: std.StringHashMap([]const u8),

    allocator: std.mem.Allocator,
    format_ctx: *c.AVFormatContext,

    pub fn deinit(self: *MediaInfo) void {
        self.metadata.deinit();
        self.allocator.free(self.streams);
        c.avformat_close_input(@ptrCast(&self.format_ctx));
    }
};

/// Probe a media file and extract metadata
/// Equivalent to: ffprobe -show_format -show_streams
pub fn probe(allocator: std.mem.Allocator, path: []const u8) Error!MediaInfo {
    var format_ctx: ?*c.AVFormatContext = null;

    // Open input file
    const path_z = allocator.dupeZ(u8, path) catch return Error.AllocationFailed;
    defer allocator.free(path_z);

    if (c.avformat_open_input(&format_ctx, path_z.ptr, null, null) < 0) {
        return Error.OpenFailed;
    }
    errdefer c.avformat_close_input(&format_ctx);

    // Get stream info
    if (c.avformat_find_stream_info(format_ctx, null) < 0) {
        return Error.StreamInfoFailed;
    }

    const ctx = format_ctx orelse return Error.OpenFailed;
    const nb_streams = @as(usize, @intCast(ctx.nb_streams));

    if (nb_streams == 0) {
        return Error.NoStreams;
    }

    // Extract stream information
    var streams = allocator.alloc(StreamInfo, nb_streams) catch return Error.AllocationFailed;
    errdefer allocator.free(streams);

    for (0..nb_streams) |i| {
        const stream = ctx.streams[i];
        const codecpar = stream.*.codecpar;

        const codec = c.avcodec_find_decoder(codecpar.*.codec_id);

        streams[i] = StreamInfo{
            .index = @intCast(i),
            .stream_type = StreamType.fromAvMediaType(codecpar.*.codec_type),
            .codec_name = if (codec) |cd| std.mem.span(cd.*.name) else null,
            .codec_long_name = if (codec) |cd| std.mem.span(cd.*.long_name) else null,
            .width = if (codecpar.*.width > 0) @intCast(codecpar.*.width) else null,
            .height = if (codecpar.*.height > 0) @intCast(codecpar.*.height) else null,
            .sample_rate = if (codecpar.*.sample_rate > 0) @intCast(codecpar.*.sample_rate) else null,
            .channels = if (codecpar.*.ch_layout.nb_channels > 0) @intCast(codecpar.*.ch_layout.nb_channels) else null,
            .bit_rate = codecpar.*.bit_rate,
            .duration_seconds = timeToSeconds(stream.*.duration, stream.*.time_base),
            .frame_rate = rationalToFloat(stream.*.avg_frame_rate),
        };
    }

    // Extract metadata
    var metadata = std.StringHashMap([]const u8).init(allocator);
    var entry: ?*c.AVDictionaryEntry = null;
    while (true) {
        entry = c.av_dict_get(ctx.metadata, "", entry, c.AV_DICT_IGNORE_SUFFIX);
        if (entry) |e| {
            const key = std.mem.span(e.*.key);
            const value = std.mem.span(e.*.value);
            metadata.put(key, value) catch {};
        } else break;
    }

    return MediaInfo{
        .format_name = if (ctx.iformat) |fmt| std.mem.span(fmt.*.name) else null,
        .format_long_name = if (ctx.iformat) |fmt| std.mem.span(fmt.*.long_name) else null,
        .duration_seconds = timeToSeconds(ctx.duration, .{ .num = 1, .den = c.AV_TIME_BASE }),
        .bit_rate = ctx.bit_rate,
        .streams = streams,
        .metadata = metadata,
        .allocator = allocator,
        .format_ctx = ctx,
    };
}

/// Get FFmpeg version string
pub fn version() []const u8 {
    return std.mem.span(c.av_version_info());
}

/// Convert AVRational to float
fn rationalToFloat(r: c.AVRational) ?f64 {
    if (r.den == 0) return null;
    return @as(f64, @floatFromInt(r.num)) / @as(f64, @floatFromInt(r.den));
}

/// Convert timestamp to seconds
fn timeToSeconds(pts: i64, time_base: c.AVRational) f64 {
    if (pts == c.AV_NOPTS_VALUE or time_base.den == 0) {
        return 0.0;
    }
    return @as(f64, @floatFromInt(pts)) * @as(f64, @floatFromInt(time_base.num)) / @as(f64, @floatFromInt(time_base.den));
}

// =============================================================================
// C FFI exports for Rust/Deno/ReScript consumers
// =============================================================================

/// Opaque handle for MediaInfo
pub const FFIMediaInfo = opaque {};

/// C-compatible stream info
pub const CStreamInfo = extern struct {
    index: u32,
    stream_type: u32, // 0=video, 1=audio, 2=subtitle, 3=data, 4=attachment, 5=unknown
    width: u32,
    height: u32,
    sample_rate: u32,
    channels: u32,
    bit_rate: i64,
    duration_seconds: f64,
    frame_rate: f64,
};

var global_allocator: std.mem.Allocator = std.heap.c_allocator;

/// Probe a file and return opaque handle
export fn ffmpeg_probe(path: [*:0]const u8) ?*FFIMediaInfo {
    const info = probe(global_allocator, std.mem.span(path)) catch return null;
    const ptr = global_allocator.create(MediaInfo) catch return null;
    ptr.* = info;
    return @ptrCast(ptr);
}

/// Get duration in seconds
export fn ffmpeg_get_duration(handle: *FFIMediaInfo) f64 {
    const info: *MediaInfo = @ptrCast(@alignCast(handle));
    return info.duration_seconds;
}

/// Get bit rate
export fn ffmpeg_get_bitrate(handle: *FFIMediaInfo) i64 {
    const info: *MediaInfo = @ptrCast(@alignCast(handle));
    return info.bit_rate;
}

/// Get stream count
export fn ffmpeg_get_stream_count(handle: *FFIMediaInfo) u32 {
    const info: *MediaInfo = @ptrCast(@alignCast(handle));
    return @intCast(info.streams.len);
}

/// Get stream info by index
export fn ffmpeg_get_stream(handle: *FFIMediaInfo, index: u32, out: *CStreamInfo) bool {
    const info: *MediaInfo = @ptrCast(@alignCast(handle));
    if (index >= info.streams.len) return false;

    const stream = info.streams[index];
    out.* = CStreamInfo{
        .index = stream.index,
        .stream_type = @intFromEnum(stream.stream_type),
        .width = stream.width orelse 0,
        .height = stream.height orelse 0,
        .sample_rate = stream.sample_rate orelse 0,
        .channels = stream.channels orelse 0,
        .bit_rate = stream.bit_rate,
        .duration_seconds = stream.duration_seconds,
        .frame_rate = stream.frame_rate orelse 0.0,
    };
    return true;
}

/// Free media info handle
export fn ffmpeg_free(handle: *FFIMediaInfo) void {
    const info: *MediaInfo = @ptrCast(@alignCast(handle));
    info.deinit();
    global_allocator.destroy(info);
}

/// Get FFmpeg version
export fn ffmpeg_version() [*:0]const u8 {
    return c.av_version_info();
}

// =============================================================================
// Tests
// =============================================================================

test "version returns non-empty string" {
    const ver = version();
    try std.testing.expect(ver.len > 0);
}
