//! Xoshiro256++ - http://xoroshiro.di.unimi.it/
//!
//! PRNG

const std = @import("std");
const Io = std.Io;
const math = std.math;
const Xoshiro256 = @This();

s: [4]u64,
/// This reader will never fail
reader: std.Io.Reader,

pub fn init(buf: []u8, seed: u64) Xoshiro256 {
    var x: Xoshiro256 = .{
        .s = undefined,
        .reader = .{
            .vtable = &.{
                .stream = stream,
                .readVec = readVec,
            },
            .buffer = buf,
            .seek = 0,
            .end = 0,
        },
    };

    var state: std.random.SplitMix64 = .init(seed);
    x.s[0] = state.next();
    x.s[1] = state.next();
    x.s[2] = state.next();
    x.s[3] = state.next();
    return x;
}

pub fn next(x: *Xoshiro256) u64 {
    const r = math.rotl(u64, x.s[0] +% x.s[3], 23) +% x.s[0];
    const t = x.s[1] << 17;

    x.s[2] ^= x.s[0];
    x.s[3] ^= x.s[1];
    x.s[1] ^= x.s[2];
    x.s[0] ^= x.s[3];

    x.s[2] ^= t;
    x.s[3] = math.rotl(u64, x.s[3], 45);
    return r;
}

// Skip 2^128 places ahead in the sequence
pub fn jump(x: *Xoshiro256) void {
    var s: u256 = 0;

    var table: u256 = 0x39abdc4529b1661ca9582618e03fc9aad5a61266f0c9392c180ec6d33cfd0aba;

    while (table != 0) : (table >>= 1) {
        if (@as(u1, @truncate(table)) != 0) {
            s ^= @as(u256, @bitCast(x.s));
        }
        _ = x.next();
    }

    x.s = @as([4]u64, @bitCast(s));
}

fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const x: *Xoshiro256 = @fieldParentPtr("reader", r);
    var buf = limit.slice(try w.writableSliceGreedy(8));
    const n = buf.len / 8 * 8;
    for (std.mem.bytesAsSlice([8]u8, buf[0..n])) |*o| {
        std.mem.writeInt(u64, o, x.next(), .little);
    }
    w.advance(n);
    return n;
}

fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    r.defaultRebase(8) catch unreachable;
    return r.defaultReadVec(data);
}

test "sequence" {
    if (@import("builtin").zig_backend == .stage2_c) return error.SkipZigTest;

    var buf: [8]u8 = undefined;
    var x: Xoshiro256 = .init(&buf, 0);

    for ([_]u64{
        0x53175d61490b23df,
        0x61da6f3dc380d507,
        0x5c0fdf91ec9a7bfc,
        0x02eebf8c3bbe5e1a,
        0x7eca04ebaf4a5eea,
        0x0543c37757f08d9a,
    }) |s| {
        try std.testing.expectEqual(s, x.next());
    }

    x.jump();

    for ([_]u64{
        0xae1db5c5e27807be,
        0xb584c6a7fd8709fe,
        0x0c46a0ee9330fb6e,
        0xdc0c9606f49ed76e,
        0x1f5bb6540f6651fb,
        0x72fa2ca734601488,
    }) |s| {
        try std.testing.expectEqual(s, x.next());
    }
}

test stream {
    var buf: [11]u8 = undefined;
    var x = Xoshiro256.init(&buf, 0);

    const expected = comptime blk: {
        const seq = [_]u64{
            0x53175d61490b23df,
            0x61da6f3dc380d507,
            0x5c0fdf91ec9a7bfc,
            0x02eebf8c3bbe5e1a,
            0x7eca04ebaf4a5eea,
            0x0543c37757f08d9a,
        };
        var bytes: [8 * seq.len]u8 = undefined;
        for (0.., seq) |i, s| {
            std.mem.writeInt(u64, bytes[i * 8 ..][0..8], s, .little);
        }
        break :blk bytes;
    };

    for (expected) |b| {
        try std.testing.expectEqual(b, x.reader.takeByte());
    }
}
