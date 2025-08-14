const std = @import("../std.zig");
const math = std.math;
const random = std.random;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const DefaultPrng = random.DefaultPrng;
const SplitMix64 = random.SplitMix64;
const DefaultCsprng = random.DefaultCsprng;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const SequentialPrng = struct {
    const Self = @This();
    reader: std.Io.Reader,
    next_value: u8,

    pub fn init(buf: []u8) Self {
        return .{
            .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = &buf,
                .seek = 0,
                .end = 0,
            },
            .next_value = 0,
        };
    }

    pub fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        var p: *SequentialPrng = @fieldParentPtr(r, "reader");
        const buf = limit.slice(try w.writableSliceGreedy(1));
        for (buf) |*b| {
            b.* = p.next_value;
            p.next_value +%= 1;
        }
        w.advance(buf.len);
        return buf.len;
    }
};

/// Do not use this PRNG! It is meant to be predictable, for the purposes of test reproducibility and coverage.
/// Its output is just a repeat of a user-specified byte pattern.
/// Name is a reference to this comic: https://dilbert.com/strip/2001-10-25
const Dilbert = struct {
    reader: std.Io.Reader,
    pattern: []const u8,
    curr_idx: usize,

    pub fn init(buf: []u8, pattern: []const u8) Dilbert {
        std.debug.assert(pattern.len != 0);
        return .{
            .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = buf,
                .seek = 0,
                .end = 0,
            },
            .pattern = pattern,
            .curr_index = 0,
        };
    }

    pub fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        var d: *Dilbert = @fieldParentPtr(r, "reader");
        const buf = limit.slice(try w.writableSliceGreedy(1));
        for (buf) |*byte| {
            byte.* = d.pattern[d.curr_idx];
            d.curr_idx = (d.curr_idx + 1) % d.pattern.len;
        }
        w.advance(buf.len);
        return buf.len;
    }

    test "Dilbert fill" {
        var buf: [9]u8 = undefined;
        var r: Dilbert = try .init(&buf, "9nine");

        const seq = [_][8]u8{
            "9nine9ni".*,
            "ne9nine9".*,
            "nine9nin".*,
            "e9nine9n".*,
            "ine9nine".*,
        };

        for (seq) |s| {
            try std.testing.expectEqual(u8, s, try r.reader.takeArray(8).*);
        }
    }
};

test "Random int" {
    try testRandomInt();
    try comptime testRandomInt();
}
fn testRandomInt() !void {
    var r: Reader = .fixed(&.{
        0, 1, 2, 3, 4,
        0xff, // 1
        0x11, // 2
        0xff, 0xff, 0xff, 0xff, // 3
        0x11, 0x11, 0x11, 0x11, // 4
        0xff, 0xff, 0xff, 0xff, // 5
        0x11, 0x11, 0x11, 0x11, // 6
        0xff, // 7
        0x11, // 8
        0xff, 0xff, 0xff, 0xff, 0xff, // 9
        0xff, // 10
        0xff, // 11
        0xff, 0xff, 0xff, 0xff, 0xff, // 12
    });

    try expectEqual(0, random.int(&r, u0));
    try expectEqual(0, random.int(&r, u1));
    try expectEqual(1, random.int(&r, u1));
    try expectEqual(2, random.int(&r, u2));
    try expectEqual(3, random.int(&r, u2));
    try expectEqual(0, random.int(&r, u2));

    try expectEqual(0xff, random.int(&r, u8)); // 1
    try expectEqual(0x11, random.int(&r, u8)); // 2

    try expectEqual(0xffffffff, random.int(&r, u32)); // 3
    try expectEqual(0x11111111, random.int(&r, u32)); // 4

    try expectEqual(-1, random.int(&r, i32)); // 5
    try expectEqual(0x11111111, random.int(&r, i32)); // 6

    try expectEqual(-1, random.int(&r, i8)); // 7
    try expectEqual(0x11, random.int(&r, i8)); // 8

    try expectEqual(0x1ffffffff, random.int(&r, u33)); // 9
    try expectEqual(-1, random.int(&r, i1)); // 10
    try expectEqual(-1, random.int(&r, i2)); // 11
    try expectEqual(-1, random.int(&r, i33)); // 12
}

test "Random boolean" {
    try testRandomBoolean();
    try comptime testRandomBoolean();
}
fn testRandomBoolean() !void {
    var buf: [1]u8 = undefined;
    var rng: SequentialPrng = .init(&buf);

    try expectEqual(false, random.boolean(&rng.reader));
    try expectEqual(true, random.boolean(&rng.reader));
    try expectEqual(false, random.boolean(&rng.reader));
    try expectEqual(true, random.boolean(&rng.reader));
}

test "Random enum" {
    try testRandomEnumValue();
    try comptime testRandomEnumValue();
}
fn testRandomEnumValue() !void {
    const TestEnum = enum(u2) {
        First,
        Second,
        Third,
    };
    var r: Reader = .fixed(&.{ 0, 1, 2, 3, 2 });
    try expectEqual(TestEnum.First, random.enumValueWithIndex(&r, TestEnum, u2));
    try expectEqual(TestEnum.Second, random.enumValueWithIndex(&r, TestEnum, u2));
    try expectEqual(TestEnum.Third, random.enumValueWithIndex(&r, TestEnum, u2));
    try expectEqual(TestEnum.Second, random.enumValueWithIndex(&r, TestEnum, u2)); // skips biased 3
}

test "Random intLessThan" {
    @setEvalBranchQuota(10000);
    try testRandomIntLessThan();
    try comptime testRandomIntLessThan();
}
fn testRandomIntLessThan() !void {
    var r: Reader = .fixed(&.{
        0xff, // 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 2
        0x00, // 3
        0x00, 0x01, // 4
        0xff, // 5
        0xff, // 6
        0xff, // 7
        0xff, // 8
        0xff, // 9
        0xff, // 10
        0xff, // 11
    });

    try expect(random.uintLessThan(&r, u8, 4) == 3); // 1
    try expect(r.seek == 0);
    try expect(random.uintLessThan(&r, u8, 4) == 0); // 2
    try expect(r.seek == 1);

    try expect(random.uintLessThan(&r, u64, 32) == 0); // 3

    // trigger the bias rejection code path
    const seek_before = r.seek;
    try expect(random.uintLessThan(&r, u8, 3) == 0); // 4
    // verify we incremented twice
    try expect(r.seek - seek_before == 2);

    try expect(random.intRangeLessThan(&r, u8, 0, 0x80) == 0x7f); // 5
    try expect(random.intRangeLessThan(&r, u8, 0x7f, 0xff) == 0xfe); // 6

    try expect(random.intRangeLessThan(&r, i8, 0, 0x40) == 0x3f); // 7
    try expect(random.intRangeLessThan(&r, i8, -0x40, 0x40) == 0x3f); // 8
    try expect(random.intRangeLessThan(&r, i8, -0x80, 0) == -1); // 9

    try expect(random.intRangeLessThan(&r, i3, -4, 0) == -1); // 10
    try expect(random.intRangeLessThan(&r, i3, -2, 2) == 1); // 11
}

test "Random intAtMost" {
    @setEvalBranchQuota(10000);
    try testRandomIntAtMost();
    try comptime testRandomIntAtMost();
}
fn testRandomIntAtMost() !void {
    var r: Reader = .fixed(&.{
        0xff, // 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 2
        0x00, // 3
        0x00, 0x01, // 4
        0xff, // 5
        0xff, // 6
        0xff, // 7
        0xff, // 8
        0xff, // 9
        0xff, // 10
        0xff, // 11
    });

    try expect(random.uintAtMost(&r, u8, 3) == 3); // 1
    try expect(r.seek == 0);
    try expect(random.uintAtMost(&r, u8, 3) == 0); // 2
    try expect(r.seek == 1);

    // trigger the bias rejection code path
    const seek_before = r.seek;
    try expect(random.uintAtMost(&r, u8, 2) == 0); // 3
    // verify we incremented twice
    try expect(r.seek - seek_before == 2);

    try expect(random.intRangeAtMost(&r, u8, 0, 0x7f) == 0x7f); // 4
    try expect(random.intRangeAtMost(&r, u8, 0x7f, 0xfe) == 0xfe); // 5

    try expect(random.intRangeAtMost(&r, i8, 0, 0x3f) == 0x3f); // 6
    try expect(random.intRangeAtMost(&r, i8, -0x40, 0x3f) == 0x3f); // 7
    try expect(random.intRangeAtMost(&r, i8, -0x80, -1) == -1); // 8

    try expect(random.intRangeAtMost(&r, i3, -4, -1) == -1); // 9
    try expect(random.intRangeAtMost(&r, i3, -2, 1) == 1); // 10

    try expect(random.uintAtMost(&r, u0, 0) == 0); // 11
}

//test "Random Biased" {
//    var prng = DefaultPrng.init(0);
//    const random = prng.random();
//    // Not thoroughly checking the logic here.
//    // Just want to execute all the paths with different types.
//
//    try expect(random.uintLessThanBiased(u1, 1) == 0);
//    try expect(random.uintLessThanBiased(u32, 10) < 10);
//    try expect(random.uintLessThanBiased(u64, 20) < 20);
//
//    try expect(random.uintAtMostBiased(u0, 0) == 0);
//    try expect(random.uintAtMostBiased(u1, 0) <= 0);
//    try expect(random.uintAtMostBiased(u32, 10) <= 10);
//    try expect(random.uintAtMostBiased(u64, 20) <= 20);
//
//    try expect(random.intRangeLessThanBiased(u1, 0, 1) == 0);
//    try expect(random.intRangeLessThanBiased(i1, -1, 0) == -1);
//    try expect(random.intRangeLessThanBiased(u32, 10, 20) >= 10);
//    try expect(random.intRangeLessThanBiased(i32, 10, 20) >= 10);
//    try expect(random.intRangeLessThanBiased(u64, 20, 40) >= 20);
//    try expect(random.intRangeLessThanBiased(i64, 20, 40) >= 20);
//
//    // uncomment for broken module error:
//    //expect(random.intRangeAtMostBiased(u0, 0, 0) == 0);
//    try expect(random.intRangeAtMostBiased(u1, 0, 1) >= 0);
//    try expect(random.intRangeAtMostBiased(i1, -1, 0) >= -1);
//    try expect(random.intRangeAtMostBiased(u32, 10, 20) >= 10);
//    try expect(random.intRangeAtMostBiased(i32, 10, 20) >= 10);
//    try expect(random.intRangeAtMostBiased(u64, 20, 40) >= 20);
//    try expect(random.intRangeAtMostBiased(i64, 20, 40) >= 20);
//}
//
//// Actual Random helper function tests, pcg engine is assumed correct.
//test "Random float correctness" {
//    var prng = DefaultPrng.init(0);
//    const random = prng.random();
//
//    var i: usize = 0;
//    while (i < 1000) : (i += 1) {
//        const val1 = random.float(f32);
//        try expect(val1 >= 0.0);
//        try expect(val1 < 1.0);
//
//        const val2 = random.float(f64);
//        try expect(val2 >= 0.0);
//        try expect(val2 < 1.0);
//    }
//}

// Check the "astronomically unlikely" code paths.
test "Random float coverage" {
    var buf: [16]u8 = undefined;
    var prng: Dilbert = try .init(&buf, &.{0});

    const rand_f64 = random.float(&prng.reader, f64);
    const rand_f32 = random.float(&prng.reader, f32);

    try expect(rand_f32 == 0.0);
    try expect(rand_f64 == 0.0);
}

//test "Random float chi-square goodness of fit" {
//    const num_numbers = 100000;
//    const num_buckets = 1000;
//
//    var f32_hist = std.AutoHashMap(u32, u32).init(std.testing.allocator);
//    defer f32_hist.deinit();
//    var f64_hist = std.AutoHashMap(u64, u32).init(std.testing.allocator);
//    defer f64_hist.deinit();
//
//    var prng = DefaultPrng.init(0);
//    const random = prng.random();
//
//    var i: usize = 0;
//    while (i < num_numbers) : (i += 1) {
//        const rand_f32 = random.float(f32);
//        const rand_f64 = random.float(f64);
//        const f32_put = try f32_hist.getOrPut(@as(u32, @intFromFloat(rand_f32 * @as(f32, @floatFromInt(num_buckets)))));
//        if (f32_put.found_existing) {
//            f32_put.value_ptr.* += 1;
//        } else {
//            f32_put.value_ptr.* = 1;
//        }
//        const f64_put = try f64_hist.getOrPut(@as(u32, @intFromFloat(rand_f64 * @as(f64, @floatFromInt(num_buckets)))));
//        if (f64_put.found_existing) {
//            f64_put.value_ptr.* += 1;
//        } else {
//            f64_put.value_ptr.* = 1;
//        }
//    }
//
//    var f32_total_variance: f64 = 0;
//    var f64_total_variance: f64 = 0;
//
//    {
//        var j: u32 = 0;
//        while (j < num_buckets) : (j += 1) {
//            const count = @as(f64, @floatFromInt((if (f32_hist.get(j)) |v| v else 0)));
//            const expected = @as(f64, @floatFromInt(num_numbers)) / @as(f64, @floatFromInt(num_buckets));
//            const delta = count - expected;
//            const variance = (delta * delta) / expected;
//            f32_total_variance += variance;
//        }
//    }
//
//    {
//        var j: u64 = 0;
//        while (j < num_buckets) : (j += 1) {
//            const count = @as(f64, @floatFromInt((if (f64_hist.get(j)) |v| v else 0)));
//            const expected = @as(f64, @floatFromInt(num_numbers)) / @as(f64, @floatFromInt(num_buckets));
//            const delta = count - expected;
//            const variance = (delta * delta) / expected;
//            f64_total_variance += variance;
//        }
//    }
//
//    // Accept p-values >= 0.05.
//    // Critical value is calculated by opening a Python interpreter and running:
//    // scipy.stats.chi2.isf(0.05, num_buckets - 1)
//    const critical_value = 1073.6426506574246;
//    try expect(f32_total_variance < critical_value);
//    try expect(f64_total_variance < critical_value);
//}
//
//test "Random shuffle" {
//    var prng = DefaultPrng.init(0);
//    const random = prng.random();
//
//    var seq = [_]u8{ 0, 1, 2, 3, 4 };
//    var seen = [_]bool{false} ** 5;
//
//    var i: usize = 0;
//    while (i < 1000) : (i += 1) {
//        random.shuffle(u8, seq[0..]);
//        seen[seq[0]] = true;
//        try expect(sumArray(seq[0..]) == 10);
//    }
//
//    // we should see every entry at the head at least once
//    for (seen) |e| {
//        try expect(e == true);
//    }
//}
//
//fn sumArray(s: []const u8) u32 {
//    var r: u32 = 0;
//    for (s) |e|
//        r += e;
//    return r;
//}
//
//test "Random range" {
//    var prng = DefaultPrng.init(0);
//    const random = prng.random();
//
//    try testRange(random, -4, 3);
//    try testRange(random, -4, -1);
//    try testRange(random, 10, 14);
//    try testRange(random, -0x80, 0x7f);
//}
//
//fn testRange(r: Random, start: i8, end: i8) !void {
//    try testRangeBias(r, start, end, true);
//    try testRangeBias(r, start, end, false);
//}
//fn testRangeBias(r: Random, start: i8, end: i8, biased: bool) !void {
//    const count = @as(usize, @intCast(@as(i32, end) - @as(i32, start)));
//    var values_buffer = [_]bool{false} ** 0x100;
//    const values = values_buffer[0..count];
//    var i: usize = 0;
//    while (i < count) {
//        const value: i32 = if (biased) r.intRangeLessThanBiased(i8, start, end) else r.intRangeLessThan(i8, start, end);
//        const index = @as(usize, @intCast(value - start));
//        if (!values[index]) {
//            i += 1;
//            values[index] = true;
//        }
//    }
//}
//
//test "CSPRNG" {
//    var secret_seed: [DefaultCsprng.secret_seed_length]u8 = undefined;
//    std.crypto.random.bytes(&secret_seed);
//    var csprng = DefaultCsprng.init(secret_seed);
//    const random = csprng.random();
//    const a = random.int(u64);
//    const b = random.int(u64);
//    const c = random.int(u64);
//    try expect(a ^ b ^ c != 0);
//}
//
//test "Random weightedIndex" {
//    // Make sure weightedIndex works for various integers and floats
//    inline for (.{ u64, i4, f32, f64 }) |T| {
//        var prng = DefaultPrng.init(0);
//        const random = prng.random();
//
//        const proportions = [_]T{ 2, 1, 1, 2 };
//        var counts = [_]f64{ 0, 0, 0, 0 };
//
//        const n_trials: u64 = 10_000;
//        var i: usize = 0;
//        while (i < n_trials) : (i += 1) {
//            const pick = random.weightedIndex(T, &proportions);
//            counts[pick] += 1;
//        }
//
//        // We expect the first and last counts to be roughly 2x the second and third
//        const approxEqRel = std.math.approxEqRel;
//        // Define "roughly" to be within 10%
//        const tolerance = 0.1;
//        try std.testing.expect(approxEqRel(f64, counts[0], counts[1] * 2, tolerance));
//        try std.testing.expect(approxEqRel(f64, counts[1], counts[2], tolerance));
//        try std.testing.expect(approxEqRel(f64, counts[2] * 2, counts[3], tolerance));
//    }
//}
