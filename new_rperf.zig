const std = @import("std");
const random = std.random;
const Bits = usize;

pub fn main() void {
    var buf: [65536]u8 = undefined;
    var rng: random.DefaultPrng = .init(&buf, 0);
    inner(&rng.reader) catch unreachable;
}

pub fn inner(rng: *std.Io.Reader) std.Io.Reader.Error!void {
    for (1..1 << 20) |n| {
        _ = try random.uintLessThan(rng, Bits, @intCast(n));
        var buf: [12]u8 = undefined;
        const len = try random.uintAtMostBiased(rng, Bits, buf.len);
        if (!try random.boolean(rng)) {
            try rng.readSliceAll(buf[0..len]);
        } else {
            for (buf[0..len]) |*c| {
                c.* = try random.intRangeAtMost(rng, u8, '0', '9');
            }
        }
    }
}
