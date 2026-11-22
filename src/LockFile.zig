/// A file-based locking mechanism for synchronizing operations between multiple processes
pub const LockFile = @This();

const builtin = @import("builtin");
const std = @import("std");

path: []const u8,
file: std.Io.File,

pub fn lock(io: std.Io, path: []const u8) !LockFile {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| {
        try cwd.createDirPath(io, dir);
    }
    const file = try cwd.createFile(io, path, .{ .lock = .exclusive });
    errdefer {
        file.close(io);
        cwd.deleteFile(io, path) catch {};
    }

    // Write the current process ID to the lock file
    // This is helpful for debugging and allows other processes to detect stale locks
    var pid_buffer: [40]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&pid_buffer, "{d}", .{getPid()}) catch unreachable;
    try file.writeStreamingAll(io, pid_text);
    try file.sync(io);

    return LockFile{
        .file = file,
        .path = path,
    };
}

pub fn unlock(self: *LockFile, io: std.Io) void {
    self.file.unlock(io);
    self.file.close(io);
    std.Io.Dir.cwd().deleteFile(io, self.path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| std.debug.panic("delete lock file '{s}' failed with {t}", .{ self.path, e }),
    };
}

pub fn getPid() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        .macos => @intCast(std.c.getpid()),
        else => |os| @compileError("unsupported os: " ++ @tagName(os)),
    };
}
