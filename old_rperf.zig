const std = @import("std");
const Random = std.Random;
const Bits = usize;

pub fn main() void {
    var prng: Random.DefaultPrng = .init(0);
    const random = prng.random();
    for (1..1 << 20) |n| {
        _ = random.uintLessThan(Bits, @intCast(n));
        var buf: [12]u8 = undefined;
        const len = random.uintAtMostBiased(Bits, buf.len);
        if (!random.boolean()) {
            random.bytes(buf[0..len]);
        } else {
            for (buf[0..len]) |*c| {
                c.* = random.intRangeAtMost(u8, '0', '9');
            }
        }
    }
}
