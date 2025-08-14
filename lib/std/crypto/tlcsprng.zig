//! Thread-local cryptographically secure pseudo-random number generator.
//! This file has public declarations that are intended to be used internally
//! by the standard library; this namespace is not intended to be exposed
//! directly to standard library users.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const mem = std.mem;
const native_os = builtin.os.tag;
const posix = std.posix;

const options = std.options.tlcsprng;
const os_has_fork = @TypeOf(posix.fork) != void;
const os_has_arc4random = builtin.link_libc and (@TypeOf(std.c.arc4random_buf) != void);
const use_own_csprng = !options.getrandom_only and !os_has_arc4random;
const want_fork_safety = options.fork_safety and os_has_fork;
const maybe_have_wipe_on_fork = builtin.os.isAtLeast(.linux, .{
    .major = 4,
    .minor = 14,
    .patch = 0,
}) orelse true;
const extern_vtable = if (!options.getrandom_only and os_has_arc4random)
    arc4random
else
    options.get_random;

const Context = struct {
    const Rng = if (use_own_csprng) std.random.DefaultCsprng else void;
    rng: Rng,
    // Kept relatively small to fit in a single page and use less TLS space
    buf: [1024 - @sizeOf(Rng)]u8,

    pub const use_tls = !want_fork_safety or !maybe_have_wipe_on_fork;
    pub threadlocal var tls: if (use_tls) Context else unreachable = undefined;
};

pub const Error = options.GetRandomError;
pub threadlocal var random: struct {
    reader: Io.Reader,
    err: ?Error,
    ctx: ?*Context,
} = .{
    // @constCast is safe here since there is no buffer and we only replace
    .reader = .{
        .vtable = &setupVTable(setupUninitialized),
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    },
    .err = null,
    .ctx = null,
};

fn setupVTable(f: fn () Io.Reader.Error!void) Io.Reader.VTable {
    const fns = struct {
        fn stream(_: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
            try f();
            return 0;
        }
        fn discard(_: *Io.Reader, _: Io.Limit) Io.Reader.Error!usize {
            try f();
            return 0;
        }
        fn readVec(_: *Io.Reader, _: [][]u8) Io.Reader.Error!usize {
            try f();
            return 0;
        }
    };
    return .{
        .stream = fns.stream,
        .discard = fns.discard,
        .readVec = fns.readVec,
    };
}

fn setupUninitialized() Io.Reader.Error!void {
    if (Context.use_tls) {
        random.ctx = &Context.tls;
    }

    forksafe: {
        if (!want_fork_safety) break :forksafe;
        buffered: {
            wof: {
                if (!maybe_have_wipe_on_fork) break :wof;

                const mapping = posix.mmap(
                    null,
                    @sizeOf(Context),
                    posix.PROT.READ | posix.PROT.WRITE,
                    .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                    -1,
                    0,
                ) catch break :buffered; // no tls since maybe_have_wipe_on_fork
                random.ctx = @ptrCast(mapping);

                // Qemu user-mode emulation ignores any valid/invalid madvise
                // hint and returns success. Check if this is the case by
                // passing bogus parameters, we expect EINVAL as result.
                if (posix.madvise(mapping.ptr, 0, 0xffffffff)) |_| {
                    break :wof;
                } else |_| {}

                if (posix.madvise(mapping.ptr, mapping.len, posix.MADV.WIPEONFORK)) |_| {
                    break :forksafe;
                } else |_| {}
            }
            pt: {
                if (!std.Thread.use_pthreads) break :pt;
                install_atfork_handler.call();
                if (AtforkHandler.success)
                    break :forksafe;
            }
        }

        random.reader.vtable = extern_vtable;
        return;
    }

    random.reader.buffer = &random.ctx.?.buf;
    if (!use_own_csprng) {
        random.reader.vtable = extern_vtable;
        return;
    }

    // setupUnseeded may fail so the vtable needs updated to allow it to be retried
    random.reader.vtable = &setupVTable(setupUnseeded);
    return setupUnseeded();
}

fn setupUnseeded() Io.Reader.Error!void {
    var r: Io.Reader = .{
        .vtable = options.get_random,
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    };
    var seed: [Context.Rng.secret_seed_length]u8 = undefined;
    try r.readSliceAll(&seed);
    random.ctx.?.rng = .init(&random.ctx.?.buf, seed);
    random.reader.vtable = &.{
        .stream = csprngStream,
        .discard = csprngDiscard,
        .readVec = csprngReadVec,
    };
}

fn csprngStream(_: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    return random.ctx.?.rng.reader.stream(w, limit);
}

fn csprngDiscard(_: *Io.Reader, limit: Io.Limit) Io.Reader.Error!usize {
    return random.ctx.?.rng.reader.discard(limit);
}

fn csprngReadVec(_: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    return random.ctx.?.rng.reader.readVec(data);
}

pub const DefaultGetRandomError = posix.GetRandomError;
pub const default_get_random: *const Io.Reader.VTable = &.{ .stream = defaultStream };

pub fn defaultStream(_: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const buf = limit.slice(try w.writableSliceGreedy(1));
    posix.getrandom(buf) catch |e| {
        random.err = e;
        return error.ReadFailed;
    };
    return buf.len;
}

const arc4random: *const Io.Reader.VTable = &.{ .stream = arc4randomStream };

fn arc4randomStream(_: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const buf = limit.slice(try w.writableSliceGreedy(1));
    std.c.arc4random_buf(buf.ptr, buf.len);
    return buf.len;
}

const AtforkHandler = struct {
    success: bool,

    pub fn install() void {
        AtforkHandler.success = std.c.pthread_atfork(null, null, childAtForkHandler);
    }
};

/// Ensure the global handler is only added once since it
/// is shared by threads and fork()-ed processes.
var install_atfork_handler = std.once(AtforkHandler.install);

fn childAtForkHandler() callconv(.c) void {
    // The atfork handler is global, this function may be called after
    // fork()-ing threads that never initialized the CSPRNG context.
    if (random.ctx) |ctx| {
        std.crypto.secureZero(u8, std.mem.asBytes(ctx));
    }
}
