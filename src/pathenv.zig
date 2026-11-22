/// Allocate and return a fully expanded copy of `path`.
/// Caller owns the returned slice.
pub fn expand(allocator: std.mem.Allocator, environ: Environ, path: []const u8) error{OutOfMemory}![]const u8 {
    const len = expandLen(environ, path);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    expandInto(environ, path, buf);
    return buf;
}

/// Returns the length of `path` after all expansions are applied.
pub fn expandLen(environ: Environ, path: []const u8) usize {
    return if (builtin.os.tag == .windows)
        expandLenWindows(environ, path)
    else
        expandLenPosix(environ, path);
}

/// Writes the expanded form of `path` into `out_buf`.
/// `out_buf` must `expandLen(path)` bytes long.
/// No allocation is performed.
pub fn expandInto(environ: Environ, path: []const u8, out_buf: []u8) void {
    if (builtin.os.tag == .windows)
        expandIntoWindows(environ, path, out_buf)
    else
        expandIntoPosix(environ, path, out_buf);
}

fn expandLenPosix(environ: Environ, path: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    if (i < path.len and path[i] == '~') {
        len += if (environ.getPosix("HOME")) |h| h.len else 0;
        i += 1;
    }
    while (i < path.len) {
        if (path[i] == '$') {
            i += 1;
            const name, const after = parseName(path, i);
            len += if (environ.getPosix(name)) |v| v.len else 1 + name.len;
            i = after;
        } else {
            len += 1;
            i += 1;
        }
    }
    return len;
}

fn expandIntoPosix(environ: Environ, path: []const u8, out_buf: []u8) void {
    std.debug.assert(expandLenPosix(environ, path) == out_buf.len);
    var out: usize = 0;
    var i: usize = 0;

    if (i < path.len and path[i] == '~') {
        if (environ.getPosix("HOME")) |home| {
            @memcpy(out_buf[out..][0..home.len], home);
            out += home.len;
        }
        i += 1;
    }

    while (i < path.len) {
        if (path[i] == '$') {
            i += 1;
            const name, const after = parseName(path, i);
            if (environ.getPosix(name)) |value| {
                @memcpy(out_buf[out..][0..value.len], value);
                out += value.len;
            } else {
                out_buf[out] = '$';
                out += 1;
                @memcpy(out_buf[out..][0..name.len], name);
                out += name.len;
            }
            i = after;
        } else {
            out_buf[out] = path[i];
            out += 1;
            i += 1;
        }
    }
}

fn expandLenWindows(environ: Environ, path: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;

    while (i < path.len) {
        if (path[i] == '%') {
            const start = i + 1;
            if (std.mem.indexOfScalarPos(u8, path, start, '%')) |end| {
                const name = path[start..end];
                if (windowsGetenv(environ, name)) |v16| {
                    len += std.unicode.calcWtf8Len(v16);
                } else {
                    len += end + 1 - i; // keep literal %VAR%
                }
                i = end + 1;
                continue;
            }
        }
        len += 1;
        i += 1;
    }

    return len;
}

fn expandIntoWindows(environ: Environ, path: []const u8, out_buf: []u8) void {
    std.debug.assert(expandLenWindows(environ, path) == out_buf.len);
    var out: usize = 0;
    var i: usize = 0;

    while (i < path.len) {
        if (path[i] == '%') {
            const start = i + 1;
            if (std.mem.indexOfScalarPos(u8, path, start, '%')) |end| {
                const name = path[start..end];
                if (windowsGetenv(environ, name)) |v16| {
                    out += std.unicode.wtf16LeToWtf8(out_buf[out..], v16);
                } else {
                    const lit = path[i .. end + 1];
                    @memcpy(out_buf[out..][0..lit.len], lit);
                    out += lit.len;
                }
                i = end + 1;
                continue;
            }
        }
        out_buf[out] = path[i];
        out += 1;
        i += 1;
    }
}

/// Parse a variable name starting at `i` in `path`.
/// Handles both `${VAR}` and `$VAR` forms.
/// Returns .{ name_slice, index_after }.
fn parseName(path: []const u8, i: usize) struct { []const u8, usize } {
    if (i < path.len and path[i] == '{') {
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, path, start, '}') orelse
            return .{ path[start..], path.len }; // malformed: consume to end
        return .{ path[start..end], end + 1 };
    }
    const start = i;
    var j = start;
    while (j < path.len and (std.ascii.isAlphanumeric(path[j]) or path[j] == '_')) : (j += 1) {}
    return .{ path[start..j], j };
}

/// Zero-allocation env lookup for Windows, returning a WTF-16LE slice.
/// Names longer than 1024 chars return null.
fn windowsGetenv(environ: Environ, name: []const u8) ?[]const u16 {
    comptime std.debug.assert(builtin.os.tag == .windows);
    const max_name = 1024;
    var name16_buf: [max_name + 1]u16 = undefined;
    // name.len is an upper bound on the WTF-16 output length, so this
    // guarantees wtf8ToWtf16Le won't write more than max_name code units.
    if (name.len > max_name) return null;
    const len = std.unicode.wtf8ToWtf16Le(&name16_buf, name) catch return null;
    name16_buf[len] = 0;
    return environ.getWindows(name16_buf[0..len :0]);
}

// ── tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A fixed POSIX environment so tests don't depend on the real one.
const test_posix_block = [_:null]?[*:0]const u8{ "HOME=/home/u", "TOOLS=/opt/tools" };
fn testPosixEnviron() Environ {
    return .{ .block = .{ .slice = &test_posix_block } };
}
/// Windows can only read the real process environment through Environ.
const test_windows_environ: Environ = .{ .block = .global };

/// Expand path and compare to expected, checking expandLen agrees with expandInto.
fn expectExpanded(environ: Environ, path: []const u8, expected: []const u8) !void {
    const len = expandLen(environ, path);
    try testing.expectEqual(expected.len, len);
    var buf: [4096]u8 = undefined;
    expandInto(environ, path, buf[0..len]);
    try testing.expectEqualStrings(expected, buf[0..len]);
}

// ── plain paths (no expansion) ────────────────────────────────────────────────

test "plain path is returned unchanged" {
    const environ = if (builtin.os.tag == .windows) test_windows_environ else testPosixEnviron();
    try expectExpanded(environ, "/usr/local/bin", "/usr/local/bin");
}

test "empty string" {
    const environ = if (builtin.os.tag == .windows) test_windows_environ else testPosixEnviron();
    try expectExpanded(environ, "", "");
}

// ── tilde (POSIX only) ────────────────────────────────────────────────────────

test "bare tilde expands to HOME" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded(testPosixEnviron(), "~", "/home/u");
}

test "tilde followed by path segment" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded(testPosixEnviron(), "~/bin", "/home/u/bin");
}

test "tilde with HOME unset expands to nothing" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded(.{ .block = .empty }, "~/bin", "/bin");
}

test "tilde only expands at position 0" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded(testPosixEnviron(), "/foo/~/bar", "/foo/~/bar");
}

// ── $VAR / ${VAR} (POSIX) ─────────────────────────────────────────────────────

test "$VAR expands to its value" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded(testPosixEnviron(), "$HOME/bin", "/home/u/bin");
}

test "${VAR} expands to its value" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded(testPosixEnviron(), "${HOME}/bin", "/home/u/bin");
}

test "unknown $VAR is kept literal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded(testPosixEnviron(), "$UNSET", "$UNSET");
}

test "unknown ${VAR} is kept literal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded(testPosixEnviron(), "${UNSET}/bin", "$UNSET/bin");
}

test "bare $ with no name is kept literal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded(testPosixEnviron(), "$", "$");
}

test "$ followed by non-identifier chars is kept literal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded(testPosixEnviron(), "$!/bin", "$!/bin");
}

test "multiple $VAR expansions in one path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded(testPosixEnviron(), "$HOME:$TOOLS", "/home/u:/opt/tools");
}

test "adjacent $VAR expansions" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try expectExpanded(testPosixEnviron(), "$HOME$TOOLS", "/home/u/opt/tools");
}

test "malformed ${VAR without closing brace does not crash" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const path = "${UNCLOSED";
    const len = expandLen(testPosixEnviron(), path);
    var buf: [4096]u8 = undefined;
    expandInto(testPosixEnviron(), path, buf[0..len]);
}

// ── %VAR% (Windows) ───────────────────────────────────────────────────────────

fn testGetenvWindows(name: []const u8, buf: []u8) ?[]const u8 {
    const v16 = windowsGetenv(test_windows_environ, name) orelse return null;
    return buf[0..std.unicode.wtf16LeToWtf8(buf, v16)];
}

test "%VAR% expands to its value on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var profile_buf: [4096]u8 = undefined;
    const profile = testGetenvWindows("USERPROFILE", &profile_buf) orelse return error.SkipZigTest;
    var expected_buf: [4096]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s}\\bin", .{profile});
    try expectExpanded(test_windows_environ, "%USERPROFILE%\\bin", expected);
}

test "variable names are case-insensitive on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var profile_buf: [4096]u8 = undefined;
    const profile = testGetenvWindows("USERPROFILE", &profile_buf) orelse return error.SkipZigTest;
    try expectExpanded(test_windows_environ, "%userprofile%", profile);
}

test "unknown %VAR% is kept literal on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectExpanded(test_windows_environ, "%_DEFINITELY_NOT_SET_XYZ%", "%_DEFINITELY_NOT_SET_XYZ%");
}

test "lone % with no closing % is kept literal on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try expectExpanded(test_windows_environ, "%NOCLOSE", "%NOCLOSE");
}

test "multiple %VAR% expansions in one path on Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var pb: [4096]u8 = undefined;
    var sb: [4096]u8 = undefined;
    const profile = testGetenvWindows("USERPROFILE", &pb) orelse return error.SkipZigTest;
    const sys = testGetenvWindows("SystemRoot", &sb) orelse return error.SkipZigTest;
    var expected_buf: [4096]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{s};{s}", .{ profile, sys });
    try expectExpanded(test_windows_environ, "%USERPROFILE%;%SystemRoot%", expected);
}

const builtin = @import("builtin");
const std = @import("std");
const Environ = std.process.Environ;
