//! The engines provided here should be initialized from an external source.
//! All functions are endian agnostic to the reader and here are no
//! requirements on the buffer size of the reader.
//! For a thread-local cryptographically secure pseudo random number generator,
//! use `std.crypto.random`.
//! Be sure to use a CSPRNG when required, otherwise using a normal PRNG will
//! be faster.

const std = @import("std.zig");
const math = std.math;
const mem = std.mem;
const assert = std.debug.assert;
const maxInt = std.math.maxInt;
const Reader = std.Io.Reader;

/// Fast unbiased random numbers.
pub const DefaultPrng = VectorizedXoshiro256;

///// Cryptographically secure random numbers.
pub const DefaultCsprng = ChaCha;

//pub const Ascon = @import("random/Ascon.zig");
pub const ChaCha = @import("random/ChaCha.zig");
//
//pub const Isaac64 = @import("random/Isaac64.zig");
//pub const Pcg = @import("random/Pcg.zig");
//pub const Xoroshiro128 = @import("random/Xoroshiro128.zig");
pub const Xoshiro256 = @import("random/Xoshiro256.zig");
pub const VectorizedXoshiro256 = @import("random/VectorizedXoshiro256.zig");
//pub const Sfc64 = @import("random/Sfc64.zig");
//pub const RomuTrio = @import("random/RomuTrio.zig");
pub const SplitMix64 = @import("random/SplitMix64.zig");
pub const ziggurat = @import("random/ziggurat.zig");

pub fn boolean(r: *Reader) Reader.Error!bool {
    return try int(r, u1) != 0;
}

/// Returns a random value from an enum, evenly distributed.
///
/// Note that this will not yield consistent results across all targets
/// due to dependence on the representation of `usize` as an index.
/// See `enumValueWithIndex` for further commentary.
pub inline fn enumValue(r: *Reader, comptime EnumType: type) Reader.Error!EnumType {
    return enumValueWithIndex(r, EnumType, usize);
}

/// Returns a random value from an enum, evenly distributed.
///
/// An index into an array of all named values is generated using the
/// specified `Index` type to determine the return value.
/// This allows for results to be independent of `usize` representation.
///
/// Prefer `enumValue` if this isn't important.
///
/// See `uintLessThan`, which this function uses in most cases,
/// for commentary on the runtime of this function.
pub fn enumValueWithIndex(r: *Reader, comptime EnumType: type, comptime Index: type) Reader.Error!EnumType {
    comptime assert(@typeInfo(EnumType) == .@"enum");

    // We won't use int -> enum casting because enum elements can have
    //  arbitrary values.  Instead we'll randomly pick one of the type's values.
    const values = comptime std.enums.values(EnumType);
    comptime assert(values.len > 0); // can't return anything
    comptime assert(maxInt(Index) >= values.len - 1); // can't access all values
    if (values.len == 1) return values[0];

    const index = if (comptime values.len - 1 == maxInt(Index))
        try int(r, Index)
    else
        try uintLessThan(r, Index, values.len);

    const MinInt = MinArrayIndex(Index);
    return values[@as(MinInt, @intCast(index))];
}

/// Returns a random int `i` such that `minInt(T) <= i <= maxInt(T)`.
/// `i` is evenly distributed.
pub fn int(r: *Reader, comptime T: type) Reader.Error!T {
    const Backing = std.meta.Int(.unsigned, @bitSizeOf(T));
    const Bytes = std.meta.Int(.unsigned, std.mem.Alignment.forward(.@"8", @bitSizeOf(T)));
    return @bitCast(@as(Backing, @truncate(try r.takeInt(Bytes, .little))));
    //var bytes: [@sizeOf(Bytes)]u8 = undefined;
    //// take* is not possible since we place no requirement on the reader's buffer.
    //try r.readSliceAll(&bytes);
    //return @bitCast(@as(Backing, @truncate(std.mem.readInt(Bytes, &bytes, .little))));
}

/// Constant-time implementation off `uintLessThan`.
/// The results of this function may be biased.
pub fn uintLessThanBiased(r: *Reader, comptime T: type, less_than: T) Reader.Error!T {
    comptime assert(@typeInfo(T).int.signedness == .unsigned);
    assert(0 < less_than);
    return limitRangeBiased(T, try int(r, T), less_than);
}

/// Returns an evenly distributed random unsigned integer `0 <= i < less_than`.
/// This function assumes that the underlying `fillFn` produces evenly distributed values.
/// Within this assumption, the runtime of this function is exponentially distributed.
/// If `fillFn` were backed by a true random generator,
/// the runtime of this function would technically be unbounded.
/// However, if `fillFn` is backed by any evenly distributed pseudo random number generator,
/// this function is guaranteed to return.
/// If you need deterministic runtime bounds, use `uintLessThanBiased`.
pub fn uintLessThan(r: *Reader, comptime T: type, less_than: T) Reader.Error!T {
    comptime assert(@typeInfo(T).int.signedness == .unsigned);
    const bits = @typeInfo(T).int.bits;
    assert(0 < less_than);

    // adapted from:
    //   http://www.pcg-random.org/posts/bounded-rands.html
    //   "Lemire's (with an extra tweak from me)"
    var x = try int(r, T);
    var m = math.mulWide(T, x, less_than);
    var l: T = @truncate(m);
    if (l < less_than) {
        var t = -%less_than;

        if (t >= less_than) {
            t -= less_than;
            if (t >= less_than) {
                t %= less_than;
            }
        }
        while (l < t) {
            x = try int(r, T);
            m = math.mulWide(T, x, less_than);
            l = @truncate(m);
        }
    }
    return @intCast(m >> bits);
}

/// Constant-time implementation off `uintAtMost`.
/// The results of this function may be biased.
pub fn uintAtMostBiased(r: *Reader, comptime T: type, at_most: T) Reader.Error!T {
    assert(@typeInfo(T).int.signedness == .unsigned);
    if (at_most == maxInt(T)) {
        // have the full range
        return int(r, T);
    }
    return uintLessThanBiased(r, T, at_most + 1);
}

/// Returns an evenly distributed random unsigned integer `0 <= i <= at_most`.
/// See `uintLessThan`, which this function uses in most cases,
/// for commentary on the runtime of this function.
pub fn uintAtMost(r: *Reader, comptime T: type, at_most: T) Reader.Error!T {
    assert(@typeInfo(T).int.signedness == .unsigned);
    if (at_most == maxInt(T)) {
        // have the full range
        return int(r, T);
    }
    return uintLessThan(r, T, at_most + 1);
}

/// Constant-time implementation off `intRangeLessThan`.
/// The results of this function may be biased.
pub fn intRangeLessThanBiased(r: *Reader, comptime T: type, at_least: T, less_than: T) Reader.Error!T {
    assert(at_least < less_than);
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        // Two's complement makes this math pretty easy.
        const UnsignedT = std.meta.Int(.unsigned, info.bits);
        const lo: UnsignedT = @bitCast(at_least);
        const hi: UnsignedT = @bitCast(less_than);
        const result = lo +% try uintLessThanBiased(r, UnsignedT, hi -% lo);
        return @bitCast(result);
    } else {
        // The signed implementation would work fine, but we can use stricter arithmetic operators here.
        return at_least + try uintLessThanBiased(r, T, less_than - at_least);
    }
}

/// Returns an evenly distributed random integer `at_least <= i < less_than`.
/// See `uintLessThan`, which this function uses in most cases,
/// for commentary on the runtime of this function.
pub fn intRangeLessThan(r: *Reader, comptime T: type, at_least: T, less_than: T) Reader.Error!T {
    assert(at_least < less_than);
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        // Two's complement makes this math pretty easy.
        const UnsignedT = std.meta.Int(.unsigned, info.bits);
        const lo: UnsignedT = @bitCast(at_least);
        const hi: UnsignedT = @bitCast(less_than);
        const result = lo +% try uintLessThan(r, UnsignedT, hi -% lo);
        return @bitCast(result);
    } else {
        // The signed implementation would work fine, but we can use stricter arithmetic operators here.
        return at_least + try uintLessThan(r, T, less_than - at_least);
    }
}

/// Constant-time implementation off `intRangeAtMostBiased`.
/// The results of this function may be biased.
pub fn intRangeAtMostBiased(r: *Reader, comptime T: type, at_least: T, at_most: T) Reader.Error!T {
    assert(at_least <= at_most);
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        // Two's complement makes this math pretty easy.
        const UnsignedT = std.meta.Int(.unsigned, info.bits);
        const lo: UnsignedT = @bitCast(at_least);
        const hi: UnsignedT = @bitCast(at_most);
        const result = lo +% try uintAtMostBiased(r, UnsignedT, hi -% lo);
        return @bitCast(result);
    } else {
        // The signed implementation would work fine, but we can use stricter arithmetic operators here.
        return at_least + try uintAtMostBiased(r, T, at_most - at_least);
    }
}

/// Returns an evenly distributed random integer `at_least <= i <= at_most`.
/// See `uintLessThan`, which this function uses in most cases,
/// for commentary on the runtime of this function.
pub fn intRangeAtMost(r: *Reader, comptime T: type, at_least: T, at_most: T) Reader.Error!T {
    assert(at_least <= at_most);
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        // Two's complement makes this math pretty easy.
        const UnsignedT = std.meta.Int(.unsigned, info.bits);
        const lo: UnsignedT = @bitCast(at_least);
        const hi: UnsignedT = @bitCast(at_most);
        const result = lo +% try uintAtMost(r, UnsignedT, hi -% lo);
        return @bitCast(result);
    } else {
        // The signed implementation would work fine, but we can use stricter arithmetic operators here.
        return at_least + try uintAtMost(r, T, at_most - at_least);
    }
}

/// Return a floating point value evenly distributed in the range [0, 1).
pub fn float(r: *Reader, comptime T: type) Reader.Error!T {
    // Generate a uniformly random value for the mantissa.
    // Then generate an exponentially biased random value for the exponent.
    // This covers every possible value in the range.
    switch (T) {
        f32 => {
            // Use 23 random bits for the mantissa, and the rest for the exponent.
            // If all 41 bits are zero, generate additional random bits, until a
            // set bit is found, or 126 bits have been generated.
            const rand = try int(r, u64);
            var rand_lz = @clz(rand);
            if (rand_lz >= 41) {
                @branchHint(.unlikely);
                rand_lz = 41 + @clz(try int(r, u64));
                if (rand_lz == 41 + 64) {
                    @branchHint(.unlikely);
                    // It is astronomically unlikely to reach this point.
                    rand_lz += @clz(try int(r, u32) | 0x7FF);
                }
            }
            const mantissa: u23 = @truncate(rand);
            const exponent = @as(u32, 126 - rand_lz) << 23;
            return @bitCast(exponent | mantissa);
        },
        f64 => {
            // Use 52 random bits for the mantissa, and the rest for the exponent.
            // If all 12 bits are zero, generate additional random bits, until a
            // set bit is found, or 1022 bits have been generated.
            const rand = try int(r, u64);
            var rand_lz: u64 = @clz(rand);
            if (rand_lz >= 12) {
                rand_lz = 12;
                while (true) {
                    // It is astronomically unlikely for this loop to execute more than once.
                    const addl_rand_lz = @clz(try int(r, u64));
                    rand_lz += addl_rand_lz;
                    if (addl_rand_lz != 64) {
                        @branchHint(.likely);
                        break;
                    }
                    if (rand_lz >= 1022) {
                        rand_lz = 1022;
                        break;
                    }
                }
            }
            const mantissa = rand & 0xFFFFFFFFFFFFF;
            const exponent = (1022 - rand_lz) << 52;
            return @bitCast(exponent | mantissa);
        },
        else => @compileError("unknown floating point type"),
    }
}

/// Return a floating point value normally distributed with mean = 0, stddev = 1.
///
/// To use different parameters, use: floatNorm(...) * desiredStddev + desiredMean.
pub fn floatNorm(r: *Reader, comptime T: type) Reader.Error!T {
    const value = try ziggurat.next_f64(r, ziggurat.NormDist);
    switch (T) {
        f32 => return @floatCast(value),
        f64 => return value,
        else => @compileError("unknown floating point type"),
    }
}

/// Return an exponentially distributed float with a rate parameter of 1.
///
/// To use a different rate parameter, use: floatExp(...) / desiredRate.
pub fn floatExp(r: *Reader, comptime T: type) Reader.Error!T {
    const value = try ziggurat.next_f64(r, ziggurat.ExpDist);
    switch (T) {
        f32 => return @floatCast(value),
        f64 => return value,
        else => @compileError("unknown floating point type"),
    }
}

/// Shuffle a slice into a random order.
/// Note that this will not yield consistent results across all targets
/// due to dependence on the representation of `usize` as an index.
/// See `shuffleWithIndex` for further commentary.
pub inline fn shuffle(r: *Reader, comptime T: type, buf: []T) Reader.Error!void {
    return shuffleWithIndex(r, T, buf, usize);
}

/// Shuffle a slice into a random order, using an index of a
/// specified type to maintain distribution across targets.
/// Asserts the index type can represent `buf.len`.
///
/// Indexes into the slice are generated using the specified `Index`
/// type, which determines distribution properties. This allows for
/// results to be independent of `usize` representation.
///
/// Prefer `shuffle` if this isn't important.
///
/// See `intRangeLessThan`, which this function uses,
/// for commentary on the runtime of this function.
pub fn shuffleWithIndex(r: *Reader, comptime T: type, buf: []T, comptime Index: type) Reader.Error!void {
    const MinInt = MinArrayIndex(Index);
    if (buf.len < 2) {
        return;
    }

    // `i <= j < max <= maxInt(MinInt)`
    const max: MinInt = @intCast(buf.len);
    var i: MinInt = 0;
    while (i < max - 1) : (i += 1) {
        const j: MinInt = @intCast(try intRangeLessThan(r, Index, i, max));
        mem.swap(T, &buf[i], &buf[j]);
    }
}

/// Randomly selects an index into `proportions`, where the likelihood of each
/// index is weighted by that proportion.
/// It is more likely for the index of the last proportion to be returned
/// than the index of the first proportion in the slice, and vice versa.
///
/// This is useful for selecting an item from a slice where weights are not equal.
/// `T` must be a numeric type capable of holding the sum of `proportions`.
pub fn weightedIndex(r: *Reader, comptime T: type, proportions: []const T) Reader.Error!usize {
    // This implementation works by summing the proportions and picking a
    // random point in [0, sum).  We then loop over the proportions,
    // accumulating until our accumulator is greater than the random point.

    const sum = s: {
        var sum: T = 0;
        for (proportions) |v| sum += v;
        break :s sum;
    };

    const point = switch (@typeInfo(T)) {
        .int => |int_info| switch (int_info.signedness) {
            .signed => try intRangeLessThan(r, T, 0, sum),
            .unsigned => try uintLessThan(r, T, sum),
        },
        // take care that imprecision doesn't lead to a value slightly greater than sum
        .float => @min(try float(r, T) * sum, sum - std.math.floatEps(T)),
        else => @compileError("weightedIndex does not support proportions of type " ++
            @typeName(T)),
    };

    assert(point < sum);

    var accumulator: T = 0;
    for (proportions, 0..) |p, index| {
        accumulator += p;
        if (point < accumulator) return index;
    } else unreachable;
}

/// Convert a random integer 0 <= random_int <= maxValue(T),
/// into an integer 0 <= result < less_than.
/// This function introduces a minor bias.
pub fn limitRangeBiased(comptime T: type, random_int: T, less_than: T) T {
    comptime assert(@typeInfo(T).int.signedness == .unsigned);
    const bits = @typeInfo(T).int.bits;

    // adapted from:
    //   http://www.pcg-random.org/posts/bounded-rands.html
    //   "Integer Multiplication (Biased)"
    const m = math.mulWide(T, random_int, less_than);
    return @intCast(m >> bits);
}

/// Returns the smallest of `Index` and `usize`.
fn MinArrayIndex(comptime Index: type) type {
    const index_info = @typeInfo(Index).int;
    assert(index_info.signedness == .unsigned);
    return if (index_info.bits >= @typeInfo(usize).int.bits) usize else Index;
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("random/test.zig");
}
