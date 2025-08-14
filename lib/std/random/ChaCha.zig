//! CSPRNG based on the ChaCha8 stream cipher, with forward security.
//!
//! References:
//! - Fast-key-erasure random-number generators https://blog.cr.yp.to/20170723-random.html

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const ChaCha = @This();
const Cipher = std.crypto.stream.chacha.ChaCha8IETF;

key: [Cipher.key_length]u8,
// max_key_blocks - 1 since the old key is used to generate the block to refresh the key
key_block: std.math.IntFittingRange(0, max_key_blocks - 1),
/// This reader will never fail
reader: Io.Reader,

const block_bytes = Cipher.block_length;
const partial_block_bytes = block_bytes - Cipher.key_length;
const nonce: [Cipher.nonce_length]u8 = @splat(0);

/// Max blocks a single key will be used to generate.
pub const max_key_blocks: u32 = 8;
pub const secret_seed_length = Cipher.key_length;

/// The seed must be uniform and secret.
pub fn init(buf: []u8, secret_seed: [secret_seed_length]u8) ChaCha {
    return .{
        .key = secret_seed,
        .key_block = 0,
        .reader = .{
            .vtable = &.{ .stream = stream },
            .buffer = buf,
            .seek = 0,
            .end = 0,
        },
    };
}

/// Inserts entropy to refresh the internal state.
///
/// Calling `reader.tossBuffered()` may be desirable after calling this.
pub fn addEntropy(self: *ChaCha, bytes: []const u8) void {
    var i: usize = 0;
    while (i + Cipher.key_length <= bytes.len) : (i += Cipher.key_length) {
        Cipher.xor(
            &self.key,
            &self.key,
            0,
            self.key,
            nonce,
        );
    }
    if (i < bytes.len) {
        var k = [_]u8{0} ** Cipher.key_length;
        const src = bytes[i..];
        @memcpy(k[0..src.len], src);
        Cipher.xor(
            &self.key,
            &self.key,
            0,
            k,
            nonce,
        );
    }
}

fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    var c: *ChaCha = @fieldParentPtr("reader", r);

    const max_full_blocks = (max_key_blocks - 1) - c.key_block;
    const min_write: usize = if (max_full_blocks == 0) partial_block_bytes else block_bytes;
    const max_write = block_bytes * max_full_blocks + partial_block_bytes;

    if (@intFromEnum(limit) < min_write) return 0;
    const out = limit.min(.limited(max_write)).slice(try w.writableSliceGreedy(min_write));

    const full_blocks = out.len / Cipher.block_length;
    const partial_offset = full_blocks * Cipher.block_length;
    assert(full_blocks <= max_full_blocks);
    if (full_blocks != 0) {
        assert(full_blocks != 0);
        Cipher.stream(out[0..partial_offset], c.key_block, c.key, nonce);
        c.key_block += @intCast(full_blocks);
    }

    var n = partial_offset;
    if (c.key_block == max_key_blocks - 1 and out[partial_offset..].len == partial_block_bytes) {
        var final_block: [Cipher.block_length]u8 = undefined;
        Cipher.stream(&final_block, c.key_block, c.key, nonce);

        c.key = final_block[0..c.key.len].*;
        c.key_block = 0;

        @memcpy(out[partial_offset..], final_block[c.key.len..]);
        n += final_block[c.key.len..].len;
    } else {
        assert(max_full_blocks != 0);
        assert(out[partial_offset..].len < partial_block_bytes);
    }

    w.advance(n);
    return n;
}
