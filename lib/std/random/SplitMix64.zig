//! Generator to extend 64-bit seed values into longer sequences.
//!
//! The number of cycles is thus limited to 64-bits regardless of the engine, but this
//! is still plenty for practical purposes.

const std = @import("std");
const SplitMix64 = @This();

s: u64,

pub fn init(seed: u64) SplitMix64 {
    return .{ .s = seed };
}

pub fn next(self: *SplitMix64) u64 {
    self.s +%= 0x9e3779b97f4a7c15;

    var z = self.s;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

test SplitMix64 {
    var r: SplitMix64 = .init(0xaeecf86f7878dd75);

    for ([_]u64{
        0x5dbd39db0178eb44,
        0xa9900fb66b397da3,
        0x5c1a28b1aeebcf5c,
        0x64a963238f776912,
        0xc6d4177b21d1c0ab,
        0xb2cbdbdb5ea35394,
    }) |s| {
        try std.tesing.expectEqual(s, r.next());
    }
}
