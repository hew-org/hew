//! Checks whether exes contain the names of std's windows codes (Win32Error and
//! NTSTATUS). Printing one of those codes as a tag name (e.g. with "{t}" or
//! std.enums.tagName) links in the name of every code, tens of KiB.
//!
//! hew's windows release builds must contain none of the markers below ("absent").
//! win_code_names_control.zig prints the names, so it must contain all of them
//! ("present"); that proves the markers still match std's names.
//!
//! usage: check_win_code_names absent|present EXE...

/// Names that only appear in one of the two enums, and nowhere else.
const markers = [_][]const u8{
    // NTSTATUS
    "DS_SHUTTING_DOWN",
    "CTX_WINSTATION_NAME_INVALID",
    "GRAPHICS_OPM_INVALID_HANDLE",
    // Win32Error
    "INVALID_EA_HANDLE",
    "NO_SITENAME",
    "DNS_ERROR_NOT_ALLOWED_ON_SIGNED_ZONE",
};

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.log.err("usage: check_win_code_names absent|present EXE...", .{});
        return 0xff;
    }
    const expect_present = if (std.mem.eql(u8, args[1], "present"))
        true
    else if (std.mem.eql(u8, args[1], "absent"))
        false
    else {
        std.log.err("expected 'absent' or 'present' but got '{s}'", .{args[1]});
        return 0xff;
    };

    var failed = false;
    for (args[2..]) |exe_path| {
        const exe = std.Io.Dir.cwd().readFileAlloc(init.io, exe_path, init.gpa, .unlimited) catch |err| {
            std.log.err("read '{s}' failed with {t}", .{ exe_path, err });
            return 0xff;
        };
        defer init.gpa.free(exe);
        for (markers) |marker| {
            const present = std.mem.indexOf(u8, exe, marker) != null;
            if (present == expect_present) continue;
            failed = true;
            if (expect_present) {
                std.log.err("'{s}' should contain the windows code name '{s}' but doesn't, so the markers no longer match std's names", .{ exe_path, marker });
            } else {
                std.log.err("'{s}' contains the windows code name '{s}': something prints a windows code as a tag name, print its number instead", .{ exe_path, marker });
            }
        }
    }
    return if (failed) 1 else 0;
}

const std = @import("std");
