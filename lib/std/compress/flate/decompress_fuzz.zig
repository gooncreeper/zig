const std = @import("../../std.zig");
const assert = std.debug.assert;
const mem = std.mem;
const math = std.math;
const Io = std.Io;
const flate = std.compress.flate;
const Token = @import("Token.zig");
const testing = std.testing;

const BitWriter = struct {
    writer: *Io.Writer,
    buffered_n: math.Log2Int(usize),
    buffered: usize,

    pub fn init(w: *Io.Writer) BitWriter {
        return .{
            .writer = w,
            .buffered_n = 0,
            .buffered = 0,
        };
    }

    fn drain(w: *BitWriter) Io.Writer.Error!void {
        var bytes: [@bitSizeOf(usize) / 8]u8 = undefined;
        mem.writeInt(usize, &bytes, w.buffered, .little);
        const n = w.buffered_n / 8;
        try w.writer.writeAll(bytes[0..n]);
        w.buffered_n -= n * 8;
        w.buffered >>= n * 8;
    }

    /// `bits` must be zero-extended
    pub fn write(w: *BitWriter, bits: u16, n: u4) Io.Writer.Error!void {
        assert(bits >> n == 0);
        if (@as(usize, w.buffered_n) + n >= @bitSizeOf(usize)) {
            try w.drain();
        }
        w.buffered |= @as(usize, bits) << w.buffered_n;
        w.buffered_n += n;
    }

    pub fn writeSplat(w: *BitWriter, bits: u16, n: u4, splat_: usize) Io.Writer.Error!void {
        var splat = splat_;
        if (n == 0) return;
        if (splat == 1) return w.write(bits, n);

        // Expand bits to over a byte
        var bit_pattern = bits;
        var bit_pattern_n = n;
        var writes_per_bit_pattern: u4 = 1;
        while (bit_pattern_n < 8) {
            bit_pattern |= bit_pattern << bit_pattern_n;
            bit_pattern_n <<= 1;
            writes_per_bit_pattern <<= 1;
        }

        if (splat <= writes_per_bit_pattern) {
            const splat4: u4 = @intCast(splat);
            return w.write(bit_pattern >> (bit_pattern_n - n * splat4), n * splat4);
        }

        // Clear all unrelated buffered bits
        try w.write(bit_pattern, bit_pattern_n);
        splat -= writes_per_bit_pattern;
        try w.drain();

        // Expand the pattern to full bytes to send to underlying writer
        const real_writer = w.writer;
        errdefer w.writer = real_writer;
        var pattern_buf: [15]u8 = undefined;
        var pattern_w: Io.Writer = .fixed(&pattern_buf);
        w.writer = &pattern_w;

        const pattern_bitstart: u3 = @truncate(w.buffered_n);
        var writes_per_pattern: usize = 0;
        while (true) {
            w.write(bit_pattern, bit_pattern_n) catch unreachable;
            writes_per_pattern += writes_per_bit_pattern;
            if (w.buffered_n % 8 == pattern_bitstart)
                break;
        }
        w.drain() catch unreachable;

        const pattern = w.writer.buffered();

        // Write full patterns
        try real_writer.splatBytesAll(pattern, splat / writes_per_pattern);
        splat %= writes_per_pattern;

        // Write remaining
        w.writer = real_writer;
        while (splat >= writes_per_bit_pattern) {
            try w.write(bit_pattern, bit_pattern_n);
            splat -= writes_per_bit_pattern;
        }
        const splat4: u4 = @intCast(splat);
        return w.write(bit_pattern >> (bit_pattern_n - n * splat4), n * splat4);
    }

    pub fn byteAlign(w: *BitWriter) Io.Writer.Error!void {
        try w.write(0, 0 -% @as(u3, @truncate(w.buffered_n)));
    }

    /// Additionally byte aligns
    pub fn flush(w: *BitWriter) Io.Writer.Error!void {
        try w.byteAlign();
        try w.drain();
        assert(w.buffered_n == 0);
    }

    test writeSplat {
        var expect_buf: [1024]u8 = undefined;
        var actual_buf: [1024]u8 = undefined;
        var prng: std.Random.DefaultPrng = .init(0);
        const rng = prng.random();

        for (0..16) |n_usize| {
            const n: u4 = @intCast(n_usize);
            for (0..512) |splat| {
                const starting_n = rng.int(u4);
                const starting_bits = std.math.shr(u16, rng.int(u16), @as(u5, 16) - starting_n);
                const bits = std.math.shr(u16, rng.int(u16), @as(u5, 16) - n);

                var expect_w: Io.Writer = .fixed(&expect_buf);
                var expect_bw: BitWriter = .init(&expect_w);
                try expect_bw.write(starting_bits, starting_n);
                for (0..splat) |_| {
                    try expect_bw.write(bits, n);
                }
                try expect_bw.flush();

                var actual_w: Io.Writer = .fixed(&actual_buf);
                var actual_bw: BitWriter = .init(&actual_w);
                try actual_bw.write(starting_bits, starting_n);
                try actual_bw.writeSplat(bits, n, splat);
                try actual_bw.flush();

                try testing.expectEqualSlices(u8, expect_w.buffered(), actual_w.buffered());
            }
        }
    }
};

test {
    _ = &BitWriter;
}

test BitWriter {
    var expected: u256 = 0;
    var expected_bits: u8 = 0;

    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw: BitWriter = .init(&w);

    for (0..15) |i| {
        const n: u4 = @intCast(i);
        const bits = (@as(u16, math.maxInt(u15)) >> ~n) * (n & 1);
        expected |= @as(u256, bits) << expected_bits;
        expected_bits += n;

        try bw.write(bits, n);
        if (n % 3 == 0) {
            expected_bits = mem.alignForward(u8, expected_bits, 8);
            try bw.byteAlign();
        }
    }
    try bw.flush();
    expected_bits = mem.alignForward(u8, expected_bits, 8);

    var expected_buf: [32]u8 = undefined;
    mem.writeInt(u256, &expected_buf, expected, .little);
    try testing.expectEqualSlices(u8, expected_buf[0..@divExact(expected_bits, 8)], w.buffered());
}

test "fuzz inflate" {
    try testing.fuzz({}, tryFuzzedInput, .{
        .corpus = &.{"\x00\xfa\xff\xffw\xda\xf4s\xa2\x9a\xdfO`\xfa\xff\xffw\x00Z\x88\x89@ \n\x00\x00\"\x00 s\xa2\x9a\xdfO"},
    });
}

fn tryFuzzedInput(_: void, input: []const u8) !void {
    // 128 * 1024 = 4 history lengths
    var buf_compressed: [128 * 1024]u8 = undefined;
    var buf_expected: [128 * 1024]u8 = undefined;
    var buf_indirect: [flate.max_window_len]u8 = undefined;
    var buf_streaming: [65536]u8 = undefined;

    var r: Io.Reader = .fixed(input);
    var compressed_w: Io.Writer = .fixed(&buf_compressed);
    var expected_w: Io.Writer = .fixed(&buf_expected);
    tryFuzzedInputInner(
        &r,
        &compressed_w,
        &expected_w,
        &buf_indirect,
        &buf_streaming,
    ) catch |e| switch (e) {
        error.WriteFailed => {},
        else => return e,
    };
}

fn tryFuzzedInputInner(
    r: *Io.Reader,
    compressed_w: *Io.Writer,
    expected_w: *Io.Writer,
    indirect_buf: *[flate.max_window_len]u8,
    streaming_buf: *[65536]u8,
) !void {
    var bw: BitWriter = .init(compressed_w);
    var expected_error = try buildFlateStream(r, compressed_w, &bw, expected_w);
    if (!@import("builtin").fuzz) std.debug.print("{?t}\n", .{expected_error});
    try bw.flush();

    const inflate_flags: packed struct(u21) {
        stream_only: bool,
        eof_trim: u20,
    } = @bitCast(r.takeLeb128(u21) catch 0);

    if (expected_error == null) blk: {
        if (inflate_flags.eof_trim == 0 or inflate_flags.eof_trim > compressed_w.end) break :blk;
        compressed_w.end -= inflate_flags.eof_trim;
        expected_error = error.EndOfStream;
    }

    var compressed_r: Io.Reader = .fixed(compressed_w.buffered());
    var expected_r: Io.Reader = .fixed(expected_w.buffered());
    const indirect_rbuf: []u8 = if (inflate_flags.stream_only) &.{} else indirect_buf;
    var inflate: flate.Decompress = .init(&compressed_r, .raw, indirect_rbuf);
    var stream_w: Io.Writer = .fixed(streaming_buf);

    const actual_error: ?flate.Decompress.Error = while (true) {
        const read_flags: packed struct(u21) {
            kind: enum(u2) { read, read2, discard, stream },
            limit: u16,
            _: u3,
        } = @bitCast(r.takeLeb128(u21) catch 0);
        if (!@import("builtin").fuzz) std.debug.print("{}\n", .{read_flags});
        const kind = if (!inflate_flags.stream_only) read_flags.kind else .stream;
        // -% 1 for 0 -> max, while keeping small limits small
        const limit: Io.Limit = .limited(read_flags.limit -% 1);
        switch (kind) {
            .read, .read2 => {
                const actual = inflate.reader.peekGreedy(1) catch |e| break switch (e) {
                    error.ReadFailed => inflate.err.?,
                    error.EndOfStream => null,
                };
                inflate.reader.toss(actual.len);
                const expect = expected_r.take(@min(actual.len, expected_r.bufferedLen())) catch unreachable;
                try testing.expectEqualSlices(u8, expect, actual);
            },
            .discard => {
                const n = inflate.reader.discard(limit) catch |e| break switch (e) {
                    error.ReadFailed => inflate.err.?,
                    error.EndOfStream => null,
                };
                if (n > @intFromEnum(limit)) return error.LimitExceeded;
                expected_r.discardAll(n) catch |e| switch (e) {
                    error.ReadFailed => unreachable,
                    error.EndOfStream => return error.TestExpectedEqual,
                };
            },
            .stream => {
                const stream_limit = limit.min(.limited(stream_w.unusedCapacityLen()));
                const start = stream_w.end;
                const n = inflate.reader.stream(&stream_w, stream_limit) catch |e| break switch (e) {
                    error.ReadFailed => inflate.err.?,
                    error.EndOfStream => null,
                    error.WriteFailed => return error.LimitExceeded,
                };
                if (n > @intFromEnum(limit)) return error.LimitExceeded;
                if (stream_w.end - start != n) return error.WrongStreamedAmount;

                const actual = stream_w.buffered()[start..];
                const expect = expected_r.take(@min(actual.len, expected_r.bufferedLen())) catch unreachable;
                try testing.expectEqualSlices(u8, expect, actual);

                if (!inflate_flags.stream_only) {
                    stream_w.end = 0;
                } else {
                    const preserve_n = flate.history_len;
                    const buffered = stream_w.buffered();
                    const preserve = buffered[buffered.len -| preserve_n..];
                    @memmove(buffered[0..preserve.len], preserve);
                    stream_w.end = preserve.len;
                }
            },
        }
    };

    try testing.expectEqual(expected_error, actual_error);
    if (actual_error == null) {
        try testing.expectEqualSlices(u8, expected_r.peekGreedy(0) catch &.{}, &.{});
    }
}

fn buildFlateStream(
    r: *Io.Reader,
    compressed_w: *Io.Writer,
    bw: *BitWriter,
    expected_w: *Io.Writer,
) error{WriteFailed}!?flate.Decompress.Error {
    var final_block: bool = false;
    var dynamic_lit_table: [286]u16 = undefined;
    var dynamic_dist_table: [30]u16 = undefined;
    var dynamic_combined_table_bits: [286 + 30]u4 = undefined;
    // is undefined if all codes are valid
    // is 256 (end_of_block) if there is none
    var min_byte_lit: u9 = undefined;
    // is undefined if all codes are valid
    // is 256 (end_of_block) if there is none
    var min_len_lit: u9 = undefined;
    // is undefined if all codes are valid or min_len_lit == 256 (end_of_block)
    // is 31 (invalid) if there is none
    var min_dist: u5 = undefined;
    var lit_table: *const [286]u16 = undefined;
    var lit_table_bits: *const [286]u4 = undefined;
    var dist_table: *const [30]u16 = undefined;
    var dist_table_bits: *const [30]u4 = undefined;
    var invalid_lit_table: [2]u16 = undefined;
    var invalid_lit_table_bits: [2]u4 = undefined; // all are either zero or non-zero
    var invalid_dist_table: [2]u16 = undefined;
    var invalid_dist_table_bits: [2]u4 = undefined; // all are either zero or non-zero

    sw: switch (enum {
        block_header,
        huffman_block,
    }.block_header) {
        .block_header => {
            if (final_block) return null;

            const block: packed struct(u8) {
                final: bool,
                type: enum(u2) {
                    store,
                    fixed,
                    dynamic,
                    invalid,
                },
                info: packed union {
                    store: packed struct {
                        override_nlen: bool,
                    },
                    fixed: void,
                    dynamic: packed struct {
                        custom_cl: bool,
                        allow_invalid_hlit: bool,
                        allow_invalid_hdist: bool,
                        allow_table_overflow: bool,
                    },
                    pad: u5,
                },
            } = @bitCast(r.takeByte() catch |e| switch (e) {
                error.ReadFailed => unreachable,
                error.EndOfStream => 1,
            });
            if (!@import("builtin").fuzz) std.debug.print("{}\n", .{block});
            try bw.write(@as(u3, @truncate(@as(u8, @bitCast(block)))), 3);
            final_block = block.final;

            switch (block.type) {
                .store => {
                    try bw.flush();
                    const len_ptr = try compressed_w.writableArray(2);
                    const nlen_ptr = try compressed_w.writableArray(2);

                    var len: u16 = 0;
                    while (true) {
                        const data: packed struct(u28) {
                            byte: u8,
                            /// byte is actually zero, not end_of_block
                            zero: bool,
                            splat: u15,
                            _: u4,
                        } = @bitCast(r.takeLeb128(u28) catch |e| switch (e) {
                            error.ReadFailed => unreachable,
                            error.Overflow, error.EndOfStream => 0,
                        });
                        if (data.byte != 0 or data.zero) {
                            const splat = @min(@max(1, data.splat), ~len);
                            try compressed_w.splatByteAll(data.byte, splat);
                            try expected_w.splatByteAll(data.byte, splat);
                            len += splat;
                            if (len != math.maxInt(u16)) continue;
                        }

                        const override = block.info.store.override_nlen;
                        const nlen = if (!override) ~len else r.takeInt(u16, .little) catch |e| switch (e) {
                            error.ReadFailed => unreachable,
                            error.EndOfStream => 0,
                        };

                        mem.writeInt(u16, len_ptr, len, .little);
                        mem.writeInt(u16, nlen_ptr, nlen, .little);
                        if (~len != nlen)
                            return flateErr(error.WrongStoredBlockNlen);
                        continue :sw .block_header;
                    }
                },
                .fixed => {
                    lit_table = fixed_lit_table[0..286];
                    lit_table_bits = fixed_lit_table_bits[0..286];
                    dist_table = fixed_dist_table[0..30];
                    dist_table_bits = fixed_dist_table_bits[0..30];
                    invalid_lit_table = fixed_lit_table[286..].*;
                    invalid_lit_table_bits = fixed_lit_table_bits[286..].*;
                    invalid_dist_table = fixed_dist_table[30..].*;
                    invalid_dist_table_bits = fixed_dist_table_bits[30..].*;
                    min_byte_lit = undefined;
                    min_len_lit = undefined;
                    min_dist = undefined;
                    continue :sw .huffman_block;
                },
                .dynamic => {
                    const cl_order: [19]u5 = .{
                        16, 17, 18,
                        0, 8, //
                        7, 9,
                        6, 10,
                        5, 11,
                        4, 12,
                        3, 13,
                        2, 14,
                        1, 15,
                    };

                    var nclen: u5 = undefined;
                    // 31 if these is none
                    var max_cl: u5 = undefined; // max to prioritize repeating codes
                    var cl_table: [19]u16 = undefined;
                    var cl_table_bits: [19]u4 = undefined;
                    if (!block.info.dynamic.custom_cl) {
                        cl_table_bits[0..16].* = @splat(5);
                        cl_table_bits[16] = 3;
                        cl_table_bits[17] = 3;
                        cl_table_bits[18] = 2;
                        for (cl_table[0..16], 0b10000..) |*c, v| {
                            c.* = @bitReverse(@as(u5, @intCast(v)));
                        }
                        cl_table[16] = @bitReverse(@as(u3, 0b010));
                        cl_table[17] = @bitReverse(@as(u3, 0b011));
                        cl_table[18] = @bitReverse(@as(u2, 0b00));
                        nclen = 19;
                        max_cl = 18;
                    } else {
                        nclen = 0;
                        max_cl = 0;
                        cl_table_bits = @splat(0);
                        while (true) {
                            const lens: packed struct(u8) {
                                one: u3,
                                finish_after_one: bool,
                                finish_after_two: bool,
                                two: u3,
                            } = @bitCast(r.takeByte() catch |e| switch (e) {
                                error.ReadFailed => unreachable,
                                error.EndOfStream => 0,
                            });
                            if (!@import("builtin").fuzz) std.debug.print("{}\n", .{lens});

                            cl_table_bits[cl_order[nclen]] = lens.one;
                            max_cl = if (cl_order[nclen] > max_cl and
                                lens.one != 0) cl_order[nclen] else max_cl;
                            nclen += 1;
                            if (nclen == 19 or (lens.finish_after_one and nclen >= 4))
                                break;

                            cl_table_bits[cl_order[nclen]] = lens.two;
                            max_cl = if (cl_order[nclen] > max_cl and
                                lens.two != 0) cl_order[nclen] else max_cl;
                            nclen += 1;
                            if (lens.finish_after_two and nclen >= 4)
                                break;
                        }
                    }

                    var h: packed struct(u14) {
                        lit: u5,
                        dist: u5,
                        _: u4,
                    } = @bitCast(r.takeLeb128(u14) catch |e| switch (e) {
                        error.ReadFailed => unreachable,
                        error.EndOfStream, error.Overflow => math.maxInt(u10),
                    });
                    if (!@import("builtin").fuzz) std.debug.print("{}\n", .{h});
                    const max_hlit = 286 - 257;
                    const max_hdist = 30 - 1;
                    if (h.lit > max_hlit and !block.info.dynamic.allow_invalid_hlit) {
                        h.lit = max_hlit;
                    }
                    if (h.dist > max_hdist and !block.info.dynamic.allow_invalid_hdist) {
                        h.dist = max_hdist;
                    }

                    try bw.write(h.lit, 5);
                    try bw.write(h.dist, 5);
                    try bw.write(nclen - 4, 4);

                    if (h.lit > max_hlit or h.dist > max_hdist)
                        return flateErr(error.InvalidDynamicBlockHeader);

                    for (cl_order[0..nclen]) |n| {
                        try bw.write(cl_table_bits[n], 3);
                    }
                    if (block.info.dynamic.custom_cl) {
                        const invalid_cl_table, const invalid_cl_table_bits = buildHuffmanTable(
                            &cl_table,
                            &cl_table_bits,
                        ) catch |e| return flateErr(e);
                        if (max_cl == 0 and cl_table_bits[0] == 0) {
                            // Can only emit invalid codes
                            const n: u1 = @truncate(r.takeByte() catch 0);
                            assert(invalid_cl_table_bits[n] != 0);
                            try bw.write(invalid_cl_table[n], invalid_cl_table_bits[n]);
                            return flateErr(error.InvalidCode);
                        }
                        if (invalid_cl_table_bits[0] != 0)
                            // Codgen tree must be complete
                            return flateErr(error.IncompleteHuffmanTree);
                    } // it's pre-built otherwise

                    const nlit = @as(u9, h.lit) + 257;
                    // cannot overflow since max returns error.InvalidDynamicBlockHeader
                    const ndist = h.dist + 1;
                    var remaining = dynamic_combined_table_bits[0 .. nlit + ndist];
                    var previous: ?u4 = null;
                    while (remaining.len != 0) {
                        const code: packed struct(u8) {
                            not_repeat: bool, // not_ so a null byte will be repeat
                            u: packed union {
                                repeat: u7,
                                other: packed struct {
                                    kind: enum(u2) {
                                        regular,
                                        copy,
                                        repeat,
                                        repeat2,
                                    },
                                    u: packed union {
                                        regular: u4,
                                        copy: u2,
                                        repeat: u3,
                                    },
                                },
                            },
                        } = @bitCast(r.takeByte() catch |e| switch (e) {
                            error.ReadFailed => unreachable,
                            error.EndOfStream => 0,
                        });
                        if (!@import("builtin").fuzz) std.debug.print("{}\n", .{code});

                        var cl: u5 = if (!code.not_repeat) 18 else switch (code.u.other.kind) {
                            .regular => code.u.other.u.regular,
                            .copy => 16,
                            .repeat, .repeat2 => 17,
                        };
                        cl = if (cl_table_bits[cl] != 0) cl else max_cl;
                        try bw.write(cl_table[cl], cl_table_bits[cl]);
                        switch (cl) {
                            0...15 => {
                                previous = @intCast(cl);
                                remaining[0] = @intCast(cl);
                                remaining = remaining[1..];
                            },
                            16 => {
                                var n = 3 + @as(u3, code.u.other.u.copy);
                                if (n > remaining.len and remaining.len >= 3 and
                                    !block.info.dynamic.allow_table_overflow)
                                {
                                    n = @intCast(remaining.len);
                                }
                                try bw.write(n - 3, 2);
                                if (previous == null or n > remaining.len)
                                    return flateErr(error.InvalidDynamicBlockHeader);
                                @memset(remaining[0..n], previous.?);
                                remaining = remaining[n..];
                            },
                            17, 18 => {
                                var n: u8, const n_bits: u4, const n_base: u4 = switch (cl) {
                                    17 => .{ code.u.other.u.repeat, 3, 3 },
                                    18 => .{ code.u.repeat, 7, 11 },
                                    else => unreachable,
                                };
                                n += n_base;
                                if (n > remaining.len and remaining.len >= n_base and
                                    !block.info.dynamic.allow_table_overflow)
                                {
                                    n = @intCast(@max(n_base, remaining.len));
                                }
                                try bw.write(n - n_base, n_bits);
                                if (n > remaining.len)
                                    return flateErr(error.InvalidDynamicBlockHeader);
                                previous = 0;
                                @memset(remaining[0..n], 0);
                                remaining = remaining[n..];
                            },
                            else => unreachable,
                        }
                    }

                    const lit_bits = dynamic_combined_table_bits[0..286];
                    const dist_bits = dynamic_combined_table_bits[286..][0..30];
                    @memmove(dist_bits[0..ndist], dynamic_combined_table_bits[nlit..][0..ndist]);
                    @memset(lit_bits[nlit..], 0);
                    @memset(dist_bits[ndist..], 0);

                    if (lit_bits[256] == 0)
                        return flateErr(error.MissingEndOfBlockCode);

                    lit_table_bits = lit_bits;
                    invalid_lit_table, invalid_lit_table_bits = buildHuffmanTable(
                        dynamic_lit_table[0..nlit],
                        lit_table_bits[0..nlit],
                    ) catch |e| return flateErr(e);
                    lit_table = &dynamic_lit_table;
                    min_byte_lit = for (0.., lit_bits[0..256]) |c, b| {
                        if (b != 0) break @intCast(c);
                    } else 256;
                    min_len_lit = for (257.., lit_bits[257..]) |c, b| {
                        if (b != 0) break @intCast(c);
                    } else 256;

                    dist_table_bits = dist_bits;
                    invalid_dist_table, invalid_dist_table_bits = buildHuffmanTable(
                        dynamic_dist_table[0..ndist],
                        dist_table_bits[0..ndist],
                    ) catch |e| return flateErr(e);
                    dist_table = &dynamic_dist_table;
                    min_dist = for (0.., dist_table_bits) |c, b| {
                        if (b != 0) break @intCast(c);
                    } else 31;

                    continue :sw .huffman_block;
                },
                .invalid => return flateErr(error.InvalidBlockType),
            }
        },
        .huffman_block => {
            const lit: packed struct(u28) {
                match: bool,
                info: packed union {
                    regular: packed struct {
                        byte: u8,
                        /// byte is actually zero, not end_of_block
                        zero: bool,
                        splat: u15,
                    },
                    match: packed struct {
                        len: u8,
                        dist: u15,
                        invalid: enum(u2) {
                            len_code,
                            dist_code,
                            _,
                        },
                    },
                },
                _: u2,
            } = @bitCast(r.takeLeb128(u28) catch |e| switch (e) {
                error.ReadFailed => unreachable,
                error.Overflow, error.EndOfStream => 0,
            });
            if (!@import("builtin").fuzz) std.debug.print("{}\n", .{lit});

            if (!lit.match) {
                const byte = lit.info.regular.byte;
                if (byte != 0 or lit.info.regular.zero) blk: {
                    const lit_code = if (lit_table_bits[byte] != 0) byte else min_byte_lit;
                    if (lit_code == 256) break :blk;
                    const splat = @max(1, lit.info.regular.splat);
                    try expected_w.splatByteAll(@intCast(lit_code), splat);
                    try bw.writeSplat(lit_table[lit_code], lit_table_bits[lit_code], splat);
                    continue :sw .huffman_block;
                }
            } else blk: {
                if (min_len_lit == 256) break :blk;

                if (lit.info.match.invalid == .len_code and invalid_lit_table_bits[0] != 0) {
                    const n: u1 = @truncate(lit.info.match.len);
                    try bw.write(invalid_lit_table[n], invalid_lit_table_bits[n]);
                    return flateErr(error.InvalidCode);
                }

                const maybe_len_lit = lit: {
                    const len = lit.info.match.len;
                    break :lit if (len != 255) @as(u9, 257) + LenCode.fromVal(len).toInt() else 285;
                };
                const len_code_int = if (lit_table_bits[maybe_len_lit] != 0) maybe_len_lit else min_len_lit;
                const len_code: LenCode = .fromInt(@intCast(len_code_int - 257));

                const len_extra_bits = if (len_code_int != 285) len_code.extraBits() else 0;
                const len_extra_mask = @shlExact(@as(u8, 1), len_extra_bits) - 1;
                const len_extra = lit.info.match.len & len_extra_mask;
                const len = if (len_code_int != 285) len_code.base() | len_extra else 255;

                try bw.write(lit_table[len_code_int], lit_table_bits[len_code_int]);
                try bw.write(len_extra, len_extra_bits);

                if (lit.info.match.invalid == .dist_code and invalid_dist_table_bits[0] != 0 or
                    min_dist == 31)
                {
                    const n: u1 = @truncate(lit.info.match.dist);
                    try bw.write(invalid_dist_table[n], invalid_dist_table_bits[n]);
                    return flateErr(error.InvalidCode);
                }

                const maybe_dist_code = DstCode.fromVal(lit.info.match.dist).toInt();
                const dist_code_int = if (dist_table_bits[maybe_dist_code] != 0) maybe_dist_code else min_dist;
                const dist_code: DstCode = .fromInt(dist_code_int);

                const dist_extra_bits = dist_code.extraBits();
                const dist_extra_mask = @shlExact(@as(u15, 1), dist_extra_bits) - 1;
                const dist_extra = lit.info.match.dist & dist_extra_mask;
                const dist = dist_code.base() | dist_extra;

                try bw.write(dist_table[dist_code_int], dist_table_bits[dist_code_int]);
                try bw.write(dist_extra, dist_extra_bits);

                const actual_len = @as(u9, len) + 3;
                const actual_dist = @as(u16, dist) + 1;

                if (actual_dist > expected_w.buffered().len)
                    return flateErr(error.InvalidMatch);
                const start = expected_w.end - actual_dist;
                const to = try expected_w.writableSlice(actual_len);
                const from = expected_w.buffer[start..][0..actual_len];
                for (from, to) |i, *o| o.* = i;

                continue :sw .huffman_block;
            }

            try bw.write(lit_table[256], lit_table_bits[256]);
            continue :sw .block_header;
        },
    }
}

const fixed_lit_table = fixed_lit_table_full[0];
const fixed_lit_table_bits = fixed_lit_table_full[1];
const fixed_lit_table_full = blk: {
    var table: [288]u16 = undefined;
    var table_bits: [288]u4 = undefined;

    for (0..143 + 1, 0b00110000..0b10111111 + 1) |i, v| {
        table[i] = @bitReverse(@as(u8, v));
        table_bits[i] = 8;
    }
    for (144..255 + 1, 0b110010000..0b111111111 + 1) |i, v| {
        table[i] = @bitReverse(@as(u9, v));
        table_bits[i] = 9;
    }
    for (256..279 + 1, 0b0000000..0b0010111 + 1) |i, v| {
        table[i] = @bitReverse(@as(u7, v));
        table_bits[i] = 7;
    }
    for (280..287 + 1, 0b11000000..0b11000111 + 1) |i, v| {
        table[i] = @bitReverse(@as(u8, v));
        table_bits[i] = 8;
    }
    break :blk .{ table, table_bits };
};
const fixed_dist_table = fixed_dist_table_full[0];
const fixed_dist_table_bits = fixed_dist_table_full[1];
const fixed_dist_table_full = blk: {
    var table: [32]u16 = undefined;
    const table_bits: [32]u4 = @splat(5);

    for (0..32) |i| {
        table[i] = @bitReverse(@as(u5, i));
    }
    break :blk .{ table, table_bits };
};

const LenCode = ShortCode(u8, u2, u3);
const DstCode = ShortCode(u15, u1, u4);
/// For length and distance codes, they are formed as
///   packed struct {
///       /// Bits preceding high bit or start if none
///       high_bits: uX, // X = 1 for DIST and 2 for LEN
///       /// High bit, 0 means none, otherwise it is at bit `y + high_log2 - 1`
///       high_log2: uY, // Y = 4 for DIST and 3 for LEN
///   }
/// For example, length code 0b1101 (13 / 270) has high_bits=0b01 and high_log2=3
/// and is 1_01_xx (2 extra bits). It is then offsetted by the min length of 3.
///        ^ bit 4 = 2 + high_log2 - 1
///
/// The returned struct does not handle the special-cased len code for 255 bytes.
fn ShortCode(Value: type, HighBits: type, HighLog2: type) type {
    return packed struct(u5) {
        high_bits: HighBits,
        high_log2: HighLog2,

        pub fn fromVal(v: Value) @This() {
            const nhigh = @bitSizeOf(HighBits) + 1;
            const bits = @bitSizeOf(Value) - @clz(v);
            if (bits <= nhigh) return @bitCast(@as(u5, @intCast(v)));
            const high = v >> @intCast(bits - nhigh);
            return .{ .high_bits = @truncate(high), .high_log2 = @intCast(bits - nhigh + 1) };
        }

        /// `@ctz(return) >= valueExtraBits`
        pub fn base(c: @This()) Value {
            if (c.high_log2 <= 1) return @as(u5, @bitCast(c));
            const high_value = @as(Value, 1 << @bitSizeOf(HighBits)) | c.high_bits;
            const high_start = @as(math.Log2Int(Value), c.high_log2 - 1);
            return @shlExact(high_value, high_start);
        }

        const max_extra = @bitSizeOf(Value) - (1 + @bitSizeOf(HighLog2));
        pub fn extraBits(c: @This()) math.IntFittingRange(0, max_extra) {
            return @intCast(c.high_log2 -| 1);
        }

        pub fn toInt(c: @This()) u5 {
            return @bitCast(c);
        }

        pub fn fromInt(x: u5) @This() {
            return @bitCast(x);
        }
    };
}

test LenCode {
    for (0.., Token.match_lengths[0 .. Token.match_lengths.len - 1]) |c_, len| {
        const c: u5 = @intCast(c_);
        const first = len.base_scaled;
        const final = first + (@shlExact(@as(u8, 1), @intCast(len.extra_bits)) -% 1);
        try testing.expectEqual(c, @as(u5, @bitCast(LenCode.fromVal(first))));
        try testing.expectEqual(c, @as(u5, @bitCast(LenCode.fromVal(final))));
        try testing.expectEqual(first, LenCode.base(@bitCast(c)));
        try testing.expectEqual(len.extra_bits, LenCode.extraBits(@bitCast(c)));
    }
}

test DstCode {
    for (0.., Token.match_distances) |c_, dist| {
        const c: u5 = @intCast(c_);
        const first: u15 = @intCast(dist.base_scaled);
        const final = first + (@shlExact(@as(u15, 1), dist.extra_bits) -% 1);
        try testing.expectEqual(c, @as(u5, @bitCast(DstCode.fromVal(first))));
        try testing.expectEqual(c, @as(u5, @bitCast(DstCode.fromVal(final))));
        try testing.expectEqual(first, DstCode.base(@bitCast(c)));
        try testing.expectEqual(dist.extra_bits, DstCode.extraBits(@bitCast(c)));
    }
}

/// Populates `table`. Returns invalid codes for the tree.
fn buildHuffmanTable(table: []u16, bits: []const u4) error{
    OversubscribedHuffmanTree,
    IncompleteHuffmanTree,
}!struct { [2]u16, [2]u4 } {
    assert(table.len < (1 << 16));
    assert(table.len == bits.len);

    var count: [16]u16 = @splat(0);
    for (bits) |b| {
        count[b] += 1;
    }
    if (count[0] == bits.len)
        return .{ .{ 0b0, 0b1 }, @splat(1) };

    var code: u16 = 0;
    var base: [16]u16 = undefined;
    for (1.., count[1..], base[1..]) |n, c, *b| {
        b.* = code;
        code +%= c;
        if (code > @shlExact(@as(u16, 1), @intCast(n)))
            return error.OversubscribedHuffmanTree;
        code <<= 1;
    }

    const one_invalid = count[1] == 1 and code == 1 << 15;
    if (code != 0 and !one_invalid)
        return error.IncompleteHuffmanTree;

    for (table, bits) |*t, b| {
        t.* = @bitReverse(base[b]) >> (0 -% b);
        base[b] += 1;
    }
    return if (!one_invalid) .{ undefined, @splat(0) } else .{ @splat(0b1), @splat(1) };
}

fn flateErr(err: flate.Decompress.Error) ?flate.Decompress.Error {
    return err;
}

pub fn pubBuildFlateStream(r: *Io.Reader, compressed_w: *Io.Writer, expected_w: *Io.Writer) !void {
    var bw: BitWriter = .init(compressed_w);
    _ = try buildFlateStream(r, compressed_w, &bw, expected_w);
    try bw.flush();
}
