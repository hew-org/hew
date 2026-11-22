//! Prints a runtime windows code's Win32Error and NTSTATUS names, the way std's
//! Debug-only error reporting does. check_win_code_names expects this exe to contain
//! the names, proving its markers match std. Built, never run.

/// Read through a volatile pointer so the code isn't known at compile time.
var code: u32 = 0;

pub fn main() void {
    const c = @as(*volatile u32, &code).*;
    std.debug.print("{s} {s}\n", .{
        std.enums.tagName(std.os.windows.Win32Error, @enumFromInt(c)) orelse "<unnamed>",
        std.enums.tagName(std.os.windows.NTSTATUS, @enumFromInt(c)) orelse "<unnamed>",
    });
}

const std = @import("std");
