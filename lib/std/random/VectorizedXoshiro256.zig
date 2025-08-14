//! VectorizedXoshiro256++ - http://xoroshiro.di.unimi.it/
//!
//! PRNG

const std = @import("std");
const Io = std.Io;
const math = std.math;
const VectorizedXoshiro256 = @This();
const vec_size = std.simd.suggestVectorLength(u64) orelse 1;
const block_size = vec_size * 8;

s: [4]@Vector(vec_size, u64),
/// This reader will never fail
reader: std.Io.Reader,

pub fn init(buf: []u8, seed: u64) VectorizedXoshiro256 {
    var x: VectorizedXoshiro256 = .{
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
    for (0..vec_size) |i| {
        x.s[0][i] = state.next();
        x.s[1][i] = state.next();
        x.s[2][i] = state.next();
        x.s[3][i] = state.next();
    }
    return x;
}

pub fn next(x: *VectorizedXoshiro256) @Vector(vec_size, u64) {
    const r = math.rotl(@Vector(vec_size, u64), x.s[0] +% x.s[3], 23) +% x.s[0];
    const t = x.s[1] << @as(@Vector(vec_size, u6), @splat(17));

    x.s[2] ^= x.s[0];
    x.s[3] ^= x.s[1];
    x.s[1] ^= x.s[2];
    x.s[0] ^= x.s[3];

    x.s[2] ^= t;
    x.s[3] = math.rotl(@Vector(vec_size, u64), x.s[3], 45);
    return r;
}

//// Skip 2^128 places ahead in the sequence
//pub fn jump(x: *VectorizedXoshiro256) void {
//    var s: u256 = 0;
//
//    var table: u256 = 0x39abdc4529b1661ca9582618e03fc9aad5a61266f0c9392c180ec6d33cfd0aba;
//
//    while (table != 0) : (table >>= 1) {
//        if (@as(u1, @truncate(table)) != 0) {
//            s ^= @as(u256, @bitCast(x.s));
//        }
//        _ = x.next();
//    }
//
//    x.s = @as([4]u64, @bitCast(s));
//}

fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const x: *VectorizedXoshiro256 = @alignCast(@fieldParentPtr("reader", r));
    var buf = limit.slice(try w.writableSliceGreedy(block_size));
    const n = buf.len / block_size * block_size;
    for (std.mem.bytesAsSlice([vec_size][8]u8, buf[0..n])) |*ov| {
        const vv: [vec_size]u64 = x.next();
        inline for (ov, vv) |*o, v| {
            std.mem.writeInt(u64, o, v, .little);
        }
    }
    w.advance(n);
    return n;
}

fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    r.defaultRebase(block_size) catch unreachable;
    return r.defaultReadVec(data);
}
