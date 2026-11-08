//! Running other programs, with a deadline so a stuck one can't freeze the reader.
const std = @import("std");
const linux = std.os.linux;
const os = @import("os.zig");
const failed = os.failed;

pub const Child = struct { pid: i32, out: i32 };

/// Starts a program with its output on a pipe, in a process group of its own so
/// everything it starts can be killed together.
pub fn spawn(argv: [*:null]const ?[*:0]const u8) ?Child {
    var fds: [2]i32 = undefined;
    // Close-on-exec, so later children don't inherit this pipe. dup2 below clears it on
    // the child's own stdout.
    if (failed(linux.pipe2(&fds, .{ .CLOEXEC = true }))) return null;
    const pid = linux.fork();
    if (failed(pid)) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = linux.setpgid(0, 0);
        _ = linux.dup2(fds[1], 1);
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        const envp = [_:null]?[*:0]const u8{};
        _ = linux.execve(argv[0].?, argv, &envp);
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    return .{ .pid = @intCast(pid), .out = fds[0] };
}

/// Longest any command may take. A stuck lipc or sqlite call must not freeze the reader.
const command_timeout_ms = 15_000;

/// Runs a command, collecting what it prints. Null when it can't start or runs too long,
/// in which case it is killed.
pub fn run(argv: [*:null]const ?[*:0]const u8, out: []u8) ?usize {
    return runUntil(argv, out, os.nowUs() + command_timeout_ms * 1000);
}

/// Like `run`, but must be done by `deadline` (microseconds on the monotonic clock).
pub fn runUntil(argv: [*:null]const ?[*:0]const u8, out: []u8, deadline: u64) ?usize {
    if (os.nowUs() >= deadline) return null;
    const child = spawn(argv) orelse return null;
    var total: usize = 0;
    while (total < out.len) {
        const now = os.nowUs();
        if (now >= deadline) break;
        var ready = [_]linux.pollfd{.{ .fd = child.out, .events = linux.POLL.IN, .revents = 0 }};
        const waited = linux.poll(&ready, 1, @intCast((deadline - now) / 1000 + 1));
        if (failed(waited)) continue; // Interrupted by a signal
        if (waited == 0) break;
        const n = linux.read(child.out, out[total..].ptr, out.len - total);
        if (failed(n) or n == 0) break;
        total += n;
    }
    // Closing first means a child with more to say gets SIGPIPE instead of blocking.
    _ = linux.close(child.out);
    if (!reap(child.pid, deadline)) {
        std.debug.print("command timed out: {s}\n", .{std.mem.sliceTo(argv[0].?, 0)});
        return null;
    }
    return total;
}

/// Waits for a child to exit until `deadline`, then kills its whole group. For
/// `sh -c`, the stuck program is the shell's child. True when it exited in time.
fn reap(pid: i32, deadline: u64) bool {
    var status: i32 = 0;
    while (true) {
        if (linux.waitpid(pid, &status, linux.W.NOHANG) != 0) return true;
        if (os.nowUs() >= deadline) break;
        os.sleepMs(5);
    }
    _ = linux.kill(-pid, linux.SIG.KILL);
    _ = linux.waitpid(pid, &status, 0);
    return false;
}
