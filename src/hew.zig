fn usage(io: std.Io) !void {
    var stderr_buf: [1000]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    stderr.interface.print(
        \\Usage: hew COMMAND [OPTIONS] ARGS...
        \\Version: {[version]s}
        \\Commands:
        \\--------------------------------------------------------------------------------
        \\  install PKGs...           | Install the given PKGs.
        \\  new-bin-path PATH         | Set path cli exes are installed to.
        \\
        \\Install options:
        \\  --app-data PATH           | Override app data directory.
        \\  --non-interactive         | Don't prompt for input.
        \\  --keep-archives           | Keep downloaded archives after install.
        \\  --allow-overwrite         | Overwrite existing executables without prompting.
        \\
        \\
    ,
        .{
            .version = @embedFile("version"),
        },
    ) catch return stderr.err.?;
    stderr.interface.flush() catch return stderr.err.?;
}

/// Process-wide resources and settings derived from the environment at startup.
const ProcessEnv = struct {
    io: std.Io,
    environ: std.process.Environ,
    /// The directory for temporary files, with no trailing separator.
    tmp_dir: []const u8,
};

// On windows wintrace reports panics, unhandled exceptions and errors returned
// from main as small traces that need no debug info at run time.
pub const panic = if (builtin.os.tag == .windows) wintrace.panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const wintrace_options: wintrace.Options = .{ .mode = .small };

pub fn main(init: std.process.Init.Minimal) !u8 {
    if (builtin.os.tag == .windows) {
        if (wintrace.SetUnhandledExceptionFilter(&wintrace.unhandledExceptionFilter) != null) unreachable;
        var guarantee: u32 = wintrace.stack_guarantee;
        if (wintrace.SetThreadStackGuarantee(&guarantee) == 0) std.debug.panic(
            "SetThreadStackGuarantee failed, error={d}",
            .{@backingInt(std.os.windows.GetLastError())},
        );
    }
    return run(init) catch |err| {
        if (builtin.os.tag == .windows) wintrace.exitWithErrorTrace(err, @errorReturnTrace());
        return err;
    };
}

fn run(init: std.process.Init.Minimal) !u8 {
    // Not global_single_threaded: its failing allocator can't spawn processes on
    // windows and its environment is empty on posix (used to spawn processes).
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{ .environ = init.environ });
    const io = threaded.io();
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();

    const ctx: ProcessEnv = .{
        .io = io,
        .environ = init.environ,
        .tmp_dir = allocTmpDir(arena, init.environ),
    };

    var arg_it = try init.args.iterateAllocator(arena);
    _ = arg_it.next();
    const cmd = blk: {
        while (arg_it.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) break :blk arg;
            errExit("unknown option '{s}'", .{arg});
        }
        try usage(io);
        return 0xff;
    };
    if (std.mem.eql(u8, cmd, "install") or std.mem.eql(u8, cmd, "i")) return try install(arena, &ctx, &arg_it);
    if (std.mem.eql(u8, cmd, "new-bin-path")) return try setBinPath(arena, &ctx, &arg_it, .require_new);
    if (std.mem.eql(u8, cmd, "version")) {
        var writer = std.Io.File.stdout().writer(io, &.{});
        writer.interface.writeAll(@embedFile("version") ++ "\n") catch return writer.err.?;
        return 0;
    }
    log.err("unknown command '{s}'", .{cmd});
    return 0xff;
}

fn install(arena: std.mem.Allocator, ctx: *const ProcessEnv, arg_it: *std.process.Args.Iterator) !u8 {
    const Config = struct {
        pkgs: []const Pkg,
        interactive: bool,
        keep_archives: bool,
        allow_overwrite: bool,
        allow_shadow: bool,
        maybe_app_data: ?[:0]const u8,
    };
    const config: Config = blk_config: {
        var pkgs: std.ArrayList(Pkg) = .empty;
        var interactive: bool = true;
        var keep_archives: bool = false;
        var allow_overwrite: bool = false;
        var allow_shadow: bool = false;
        var maybe_app_data: ?[:0]const u8 = null;
        while (arg_it.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                switch (Pkg.parse(arg)) {
                    .ok => |pkg| try pkgs.append(arena, pkg),
                    .err => |e| errExit("invalid package '{s}': {f}", .{ arg, e }),
                }
            } else if (std.mem.eql(u8, arg, "--non-interactive")) {
                interactive = false;
            } else if (std.mem.eql(u8, arg, "--keep-archives")) {
                keep_archives = true;
            } else if (std.mem.eql(u8, arg, "--allow-overwrite")) {
                allow_overwrite = true;
            } else if (std.mem.eql(u8, arg, "--allow-shadow")) {
                allow_shadow = true;
            } else if (std.mem.eql(u8, arg, "--app-data")) {
                const val = arg_it.next();
                if (val == null or std.mem.startsWith(u8, val.?, "-"))
                    errExit("--app-data requires a path argument", .{});
                maybe_app_data = val.?;
            } else errExit("unknown cmdline argument '{s}'", .{arg});
        }

        break :blk_config .{
            .pkgs = pkgs.toOwnedSlice(arena) catch |e| oom(e),
            .interactive = interactive,
            .keep_archives = keep_archives,
            .allow_overwrite = allow_overwrite,
            .allow_shadow = allow_shadow,
            .maybe_app_data = maybe_app_data,
        };
    };

    if (config.pkgs.len == 0) errExit("no packages given to install", .{});

    const app_data_path = config.maybe_app_data orelse allocAppDataPath(arena, ctx.environ);
    std.debug.assert(std.fs.path.isAbsolute(app_data_path));
    var scratch: Scratch = .init(std.heap.page_allocator);
    var git_auth: GitAuth = .init(ctx.environ);
    const install_config: InstallConfig = .{
        .ctx = ctx,
        .git_auth = &git_auth,
        .interactive = config.interactive,
        .keep_archives = config.keep_archives,
        .allow_overwrite = config.allow_overwrite,
        .allow_shadow = config.allow_shadow,
        .app_data_path = app_data_path,
        .cache_path = allocCachePath(arena, ctx.environ, app_data_path),
        .bin_path = try allocBinPath(arena, ctx, &scratch, config.interactive, app_data_path),
    };
    std.debug.assert(std.fs.path.isAbsolute(install_config.cache_path));
    std.debug.assert(std.fs.path.isAbsolute(install_config.bin_path));

    for (config.pkgs) |pkg| {
        try installPkg(&scratch, &install_config, pkg);
    }
    return 0;
}

fn binPathEql(a: []const u8, b: []const u8) bool {
    if (builtin.os.tag == .windows) {
        if (a.len != b.len) return false;
        for (a, b) |ac, bc| {
            const an: u8 = if (ac == '/') '\\' else ac;
            const bn: u8 = if (bc == '/') '\\' else bc;
            if (an != bn) return false;
        }
        return true;
    }
    return std.mem.eql(u8, a, b);
}

const BinFileKind = enum { exe, pdb };
fn binFileKind(name: []const u8) ?BinFileKind {
    // if (std.ascii.endsWithIgnoreCase(name, ".zip")) return .data;
    if (builtin.os.tag == .windows) {
        if (std.ascii.endsWithIgnoreCase(name, ".exe")) return .exe;
        if (std.ascii.endsWithIgnoreCase(name, ".pdb")) return .pdb;
        return null;
    }
    return .exe;
}

fn isBinPathNormalized(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        return std.mem.indexOfScalar(u8, path, '/') == null;
    }
    return true;
}

fn normalizeBinPath(arena: std.mem.Allocator, path: [:0]const u8) [:0]const u8 {
    if (isBinPathNormalized(path)) return path;
    const duped = arena.dupeSentinel(u8, path, 0) catch |e| oom(e);
    std.mem.replaceScalar(u8, duped, '/', '\\');
    // sanity check that isBinPathNormalized wasn't lying
    std.debug.assert(isBinPathNormalized(duped));
    std.debug.assert(!std.mem.eql(u8, path, duped));
    std.debug.assert(binPathEql(path, duped));
    return duped;
}

fn setBinPath(arena: std.mem.Allocator, ctx: *const ProcessEnv, arg_it: *std.process.Args.Iterator, mode: enum { require_new, update }) !u8 {
    var maybe_app_data: ?[:0]const u8 = null;
    const bin_path = blk: {
        while (arg_it.next()) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                if (arg_it.next() != null) errExit("too many cmdline args", .{});
                break :blk normalizeBinPath(arena, arg);
            }
            if (std.mem.eql(u8, arg, "--app-data")) {
                const val = arg_it.next();
                if (val == null or std.mem.startsWith(u8, val.?, "-"))
                    errExit("--app-data requires a path argument", .{});
                maybe_app_data = val.?;
            } else errExit("unknown option '{s}'", .{arg});
        }
        errExit("new-bin-path requires a PATH argument", .{});
    };

    const app_data_path = maybe_app_data orelse allocAppDataPath(arena, ctx.environ);

    var bin_setting_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bin_setting_path = std.fmt.bufPrint(
        &bin_setting_path_buf,
        "{s}{c}{s}",
        .{ app_data_path, std.fs.path.sep, "binpath" },
    ) catch @panic("app data path too long");

    switch (mode) {
        .update => @panic("todo"),
        .require_new => {
            var val_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (try readBinPath(ctx.io, bin_setting_path, &val_buf)) |stored| {
                if (std.mem.eql(u8, stored, bin_path)) {
                    log.info("bin path is already set to '{s}'", .{bin_path});
                    return 0;
                }
                std.debug.assert(!binPathEql(stored, bin_path));
                errExit("bin path is already configured as '{s}' in '{s}'", .{ stored, bin_setting_path });
            }
        },
    }

    const path_env = allocPathEnv(arena, ctx.environ) orelse errExit("PATH environment variable not found", .{});

    const in_path = blk_in_path: {
        var it = std.mem.tokenizeScalar(u8, path_env, path_env_sep);
        while (it.next()) |entry| {
            const expanded = try pathenv.expand(arena, ctx.environ, entry);
            if (binPathEql(expanded, bin_path)) break :blk_in_path true;
        }
        break :blk_in_path false;
    };
    if (!in_path) errExit("'{s}' is not in the PATH environment variable", .{bin_path});

    // Validate the path is writable.
    switch (try checkBinPath(ctx.io, bin_path)) {
        .ok => {},
        .bad => |reason| errExit("'{s}' is not a valid bin path: {t}", .{ bin_path, reason }),
    }

    try writeBinPath(ctx.io, bin_setting_path, bin_path);
    log.info("bin path set to '{s}'", .{bin_path});
    return 0;
}

const InstallConfig = struct {
    ctx: *const ProcessEnv,
    git_auth: *GitAuth,
    interactive: bool,
    keep_archives: bool,
    allow_overwrite: bool,
    allow_shadow: bool,
    app_data_path: [:0]const u8,
    cache_path: [:0]const u8,
    bin_path: [:0]const u8,
};

fn installPkg(scratch: *Scratch, config: *const InstallConfig, pkg: Pkg) !void {
    const scratch_pos = scratch.position();
    defer scratch.restorePosition(scratch_pos);
    switch (pkg) {
        .git => |p| try installPkgGit(scratch, config, p),
        .path => |p| try installPkgPath(scratch, config, @panic("todo: manifest path"), p, .installed_from_path),
    }
}

const anyzig_version: *const [11]u8 = "v2026_11_12";

fn allocAnyzigPath(allocator: std.mem.Allocator, app_data_path: []const u8, version: *const [11]u8) error{OutOfMemory}![]u8 {
    const ext = if (builtin.os.tag == .windows) ".exe" else "";
    return std.fmt.allocPrint(
        allocator,
        "{s}{c}anyzig-{s}{s}",
        .{
            app_data_path,
            std.fs.path.sep,
            version,
            ext,
        },
    );
}

fn fileExistsAbsolute(io: std.Io, path: []const u8) !bool {
    return if (std.Io.Dir.accessAbsolute(io, path, .{})) true else |err| switch (err) {
        error.FileNotFound => false,
        else => |e| e,
    };
}

fn versionFromAnyzigExe(anyzig_exe: []const u8) [11]u8 {
    const basename = std.fs.path.basename(anyzig_exe);
    const anyzig_prefix = "anyzig-";
    std.debug.assert(std.mem.startsWith(u8, basename, anyzig_prefix));
    const no_prefix = basename[anyzig_prefix.len..];
    const v = blk: {
        if (builtin.os.tag == .windows) {
            std.debug.assert(std.mem.endsWith(u8, no_prefix, ".exe"));
            break :blk no_prefix[0 .. no_prefix.len - 4];
        }
        break :blk no_prefix;
    };
    std.debug.assert(v.len == 11);
    return v[0..11].*;
}

// Download anyzig if not already present. Uses a lock file to prevent races.
fn ensureAnyzig(
    scratch: *Scratch,
    config: *const InstallConfig,
    anyzig_exe: []const u8,
) !void {
    const io = config.ctx.io;
    const version = versionFromAnyzigExe(anyzig_exe);
    if (try fileExistsAbsolute(io, anyzig_exe)) {
        log.info("using existing anyzig at {s}", .{anyzig_exe});
        return;
    }

    const scratch_pos = scratch.position();
    defer scratch.restorePosition(scratch_pos);

    const lock_path = std.fmt.allocPrint(scratch.allocator(), "{s}.lock", .{anyzig_exe}) catch |e| oom(e);
    defer scratch.free(lock_path);

    var lock_file = LockFile.lock(
        io,
        lock_path,
    ) catch |err| return reportError("lock '{s}' failed with {t}", .{ lock_path, err });
    defer lock_file.unlock(io);

    // Re-check after acquiring lock (another process may have completed)
    if (try fileExistsAbsolute(io, anyzig_exe)) {
        log.info("using existing anyzig at {s}", .{anyzig_exe});
        return;
    }
    errdefer std.Io.Dir.deleteFileAbsolute(io, anyzig_exe) catch |err| switch (err) {
        error.FileNotFound => {},
        else => log.err("clean up '{s}' failed with {t}", .{ anyzig_exe, err }),
    };

    const arch = @tagName(builtin.cpu.arch);
    const os = switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => @compileError("unsupported OS for anyzig"),
    };
    const ext = if (builtin.os.tag == .windows) ".zip" else ".tar.gz";

    const asset_url = std.fmt.allocPrint(
        scratch.allocator(),
        "https://github.com/marler8997/anyzig/releases/download/{s}/anyzig-{s}-{s}{s}",
        .{ version, arch, os, ext },
    ) catch |e| oom(e);
    defer scratch.free(asset_url);

    const pkg_cache_path = std.fmt.allocPrint(
        scratch.allocator(),
        "{s}{c}anyzig-{s}-{s}-{s}",
        .{ config.cache_path, std.fs.path.sep, version, arch, os },
    ) catch |e| oom(e);
    defer scratch.free(pkg_cache_path);

    var client: std.http.Client = .{ .allocator = scratch.allocator(), .io = io };
    defer client.deinit();

    try downloadToCache(scratch, .{ .ctx = config.ctx, .client = &client, .git_auth = config.git_auth }, asset_url, pkg_cache_path);

    const cwd = std.Io.Dir.cwd();
    const dest_dir_path = std.fs.path.dirname(anyzig_exe) orelse ".";
    cwd.createDirPath(io, dest_dir_path) catch |err| return reportError(
        "create directory '{s}' failed with {t}",
        .{ dest_dir_path, err },
    );

    const extract_dir_path = allocTmpPath(scratch.allocator(), config.ctx.tmp_dir, "hew-anyzig-{s}", .{version});
    defer scratch.free(extract_dir_path);

    cwd.deleteTree(io, extract_dir_path) catch |err|
        return reportError("deleteTree '{s}' failed with {t}", .{ extract_dir_path, err });
    cwd.createDirPath(io, extract_dir_path) catch |err| return reportError(
        "create directory '{s}' failed with {t}",
        .{ extract_dir_path, err },
    );

    {
        var extract_dir = std.Io.Dir.openDirAbsolute(io, extract_dir_path, .{}) catch |err| return reportError(
            "open '{s}' failed with {t}",
            .{ extract_dir_path, err },
        );
        defer extract_dir.close(io);

        const archive_file = cwd.openFile(io, pkg_cache_path, .{}) catch |err| return reportError(
            "open '{s}' failed with {t}",
            .{ pkg_cache_path, err },
        );
        defer archive_file.close(io);
        var archive_read_buf: [4096]u8 = undefined;
        var archive_reader = archive_file.reader(io, &archive_read_buf);

        if (builtin.os.tag == .windows) {
            var diagnostics: std.zip.Diagnostics = .{ .allocator = scratch.allocator() };
            defer diagnostics.deinit();
            std.zip.extract(extract_dir, &archive_reader, .{ .diagnostics = &diagnostics }) catch |err| return reportError(
                "extract anyzig zip failed with {t}",
                .{err},
            );
            if (diagnostics.root_dir.len > 0) {
                extract_dir.close(io);
                extract_dir = extract_dir.openDir(io, diagnostics.root_dir, .{}) catch |err| return reportError(
                    "open extracted root dir failed with {t}",
                    .{err},
                );
            }
        } else {
            var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
            var decompressor: std.compress.flate.Decompress = .init(&archive_reader.interface, .gzip, &decompress_buf);
            std.tar.extract(io, extract_dir, &decompressor.reader, .{}) catch |err| return reportError(
                "extract anyzig failed with {t}",
                .{err},
            );
        }

        var dest_dir = std.Io.Dir.openDirAbsolute(io, dest_dir_path, .{}) catch |err| return reportError(
            "open '{s}' failed with {t}",
            .{ dest_dir_path, err },
        );
        defer dest_dir.close(io);
        const zig_name = if (builtin.os.tag == .windows) "zig.exe" else "zig";
        const anyzig_basename = std.fs.path.basename(anyzig_exe);
        extract_dir.copyFile(zig_name, dest_dir, anyzig_basename, io, .{}) catch |err| return reportError(
            "copy anyzig to '{s}' failed with {t}",
            .{ anyzig_exe, err },
        );
        std.debug.assert(try fileExistsAbsolute(io, anyzig_exe));
    }

    log.info("installed anyzig to {s}", .{anyzig_exe});
    log.info("clean source: rm -rf {s}", .{extract_dir_path});
    cwd.deleteTree(io, extract_dir_path) catch |err|
        return reportError("deleteTree '{s}' failed with {t}", .{ extract_dir_path, err });
    log.info("clean archive: rm {s}", .{pkg_cache_path});
    std.Io.Dir.deleteFileAbsolute(io, pkg_cache_path) catch |err|
        return reportError("delete '{s}' failed with {t}", .{ pkg_cache_path, err });
}

const GitArchive = union(enum) {
    rev: struct {
        json: std.ArrayList(u8),
        rev_name: []const u8,
        tarball_url: []const u8,
    },
    tip: struct {
        json: std.ArrayList(u8),
        sha: GitSha,
        tarball_url: []const u8,
    },
    pub fn deinit(archive: *GitArchive, allocator: std.mem.Allocator) void {
        switch (archive.*) {
            .rev => |*r| r.json.deinit(allocator),
            .tip => |*t| {
                allocator.free(t.tarball_url);
                t.json.deinit(allocator);
            },
        }
        archive.* = undefined;
    }

    pub fn url(archive: *const GitArchive) []const u8 {
        return switch (archive.*) {
            .rev => |*r| r.tarball_url,
            .tip => |*t| t.tarball_url,
        };
    }
    pub fn allocRevision(archive: *const GitArchive, allocator: std.mem.Allocator) []u8 {
        return switch (archive.*) {
            .rev => |*r| allocator.dupe(u8, r.rev_name) catch |e| oom(e),
            .tip => |*t| std.fmt.allocPrint(allocator, "{f}", .{t.sha}) catch |e| oom(e),
        };
    }
    pub fn fmtUniqueName(archive: *const GitArchive) FmtUniqueName {
        return FmtUniqueName{ .archive = archive };
    }
    const FmtUniqueName = struct {
        archive: *const GitArchive,
        pub fn format(n: FmtUniqueName, w: *std.Io.Writer) error{WriteFailed}!void {
            switch (n.archive.*) {
                .rev => |*r| try w.writeAll(r.rev_name),
                .tip => |*t| try t.sha.format(w),
            }
        }
    };
};

/// Writes the API URL of the package's repository, e.g. https://api.github.com/repos/OWNER/REPO.
fn fmtRepoApi(pkg: *const PkgGit) FmtRepoApi {
    return .{ .pkg = pkg };
}
const FmtRepoApi = struct {
    pkg: *const PkgGit,
    pub fn format(f: FmtRepoApi, w: *std.Io.Writer) error{WriteFailed}!void {
        const pkg = f.pkg;
        switch (pkg.forge) {
            .github => if (std.ascii.eqlIgnoreCase(pkg.host, "github.com"))
                try w.print("https://api.github.com/repos/{s}", .{pkg.path})
            else
                // GitHub Enterprise
                try w.print("https://{s}/api/v3/repos/{s}", .{ pkg.host, pkg.path }),
            .gitlab => {
                // the project ID is its path with each '/' encoded
                try w.print("https://{s}/api/v4/projects/", .{pkg.host});
                for (pkg.path) |c| {
                    if (c == '/') try w.writeAll("%2F") else try w.writeByte(c);
                }
            },
            .forgejo => try w.print("https://{s}/api/v1/repos/{s}", .{ pkg.host, pkg.path }),
            // sourcehut's API needs a token, its lookups use the repo's web root
            .srht => try w.print("https://{s}/{s}", .{ pkg.host, pkg.path }),
        }
    }
};

fn allocRepoApiUrl(allocator: std.mem.Allocator, pkg: *const PkgGit, comptime suffix_fmt: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(allocator, "{f}" ++ suffix_fmt, .{fmtRepoApi(pkg)} ++ args) catch |e| oom(e);
}

fn allocUrlTarball(allocator: std.mem.Allocator, pkg: *const PkgGit, rev: []const u8) []u8 {
    return switch (pkg.forge) {
        .github => allocRepoApiUrl(allocator, pkg, "/tarball/{s}", .{rev}),
        .gitlab => allocRepoApiUrl(allocator, pkg, "/repository/archive.tar.gz?sha={s}", .{rev}),
        .forgejo, .srht => allocRepoApiUrl(allocator, pkg, "/archive/{s}.tar.gz", .{rev}),
    };
}

fn getLatestRelease(scratch: *Scratch, http: Http, pkg: *const PkgGit) GitArchive {
    log.info("fetching latest release for {f}...", .{pkg.*});
    const release_url = switch (pkg.forge) {
        .github, .forgejo => allocRepoApiUrl(scratch.allocator(), pkg, "/releases/latest", .{}),
        .gitlab => allocRepoApiUrl(scratch.allocator(), pkg, "/releases/permalink/latest", .{}),
        .srht => unreachable, // getLatestTagSrht
    };
    defer scratch.allocator().free(release_url);
    var timer: Timer = .init(http.ctx.io);
    var fetch_result = fetchGitJson(release_url, http, scratch.allocator());
    errdefer fetch_result.body.deinit(scratch.allocator());
    if (fetch_result.status == .ok) {
        const elapsed = timer.seconds();
        log.info("fetched latest release JSON in {d:.2} seconds", .{elapsed});
        const release = blk_release: {
            var err: ParseJsonError = undefined;
            break :blk_release switch (pkg.forge) {
                .github, .forgejo => parseReleaseGithub(fetch_result.body.items, &err),
                .gitlab => parseReleaseGitlab(fetch_result.body.items, &err),
                .srht => unreachable,
            } catch jsonErrorExit(scratch, http.ctx, release_url, fetch_result.body.items, &err);
        };
        checkTagName(pkg, release.tag_name);
        log.info("latest release is tag {s}", .{release.tag_name});
        return .{ .rev = .{
            .json = fetch_result.body,
            .rev_name = release.tag_name,
            .tarball_url = release.tarball_url,
        } };
    }
    {
        // Only fall back to tags if the releases endpoint says there's no release.
        // Other 404s (e.g. repo doesn't exist) should still be fatal. On forgejo a
        // missing repo under an existing owner gets the same message, but then the
        // tags request below fails with its own 404.
        const no_release_message = switch (pkg.forge) {
            .github => "Not Found",
            .gitlab => "404 Not Found",
            .forgejo => "The target couldn't be found.",
            .srht => unreachable,
        };
        const is_no_releases = fetch_result.status == .not_found and blk_msg: {
            var err: ParseJsonError = undefined;
            const msg = parseMessage(fetch_result.body.items, &err) catch
                jsonErrorExit(scratch, http.ctx, release_url, fetch_result.body.items, &err);
            break :blk_msg std.mem.eql(u8, msg, no_release_message);
        };
        if (!is_no_releases)
            fetchErrExit(release_url, fetch_result);
    }
    fetch_result.body.deinit(scratch.allocator());

    // No releases found, fall back to latest tag.
    log.info("no releases found, fetching latest tag for {f}...", .{pkg.*});
    const tags_url = switch (pkg.forge) {
        .github => allocRepoApiUrl(scratch.allocator(), pkg, "/tags?per_page=1", .{}),
        .gitlab => allocRepoApiUrl(scratch.allocator(), pkg, "/repository/tags?per_page=1", .{}),
        .forgejo => allocRepoApiUrl(scratch.allocator(), pkg, "/tags?limit=1", .{}),
        .srht => unreachable,
    };
    defer scratch.allocator().free(tags_url);
    timer = .init(http.ctx.io);
    var tags_result = fetchGitJson(tags_url, http, scratch.allocator());
    errdefer tags_result.body.deinit(scratch.allocator());
    if (tags_result.status != .ok)
        fetchErrExit(tags_url, tags_result);
    const tags_elapsed = timer.seconds();
    log.info("fetched latest tag JSON in {d:.2} seconds", .{tags_elapsed});
    const tag_name = blk_tag: {
        var err: ParseJsonError = undefined;
        break :blk_tag (parseLatestTag(tags_result.body.items, &err) catch |e| switch (e) {
            error.ParseJson => jsonErrorExit(scratch, http.ctx, tags_url, tags_result.body.items, &err),
        }) orelse {
            log.info("no tags found either, falling back to tip for {f}...", .{pkg.*});
            tags_result.body.deinit(scratch.allocator());
            const tip_archive = fetchTip(scratch, scratch.allocator(), pkg, http);
            log.info("tip is commit {f}", .{&tip_archive.tip.sha});
            return tip_archive;
        };
    };
    checkTagName(pkg, tag_name);
    log.info("latest tag is {s}", .{tag_name});
    return .{ .rev = .{
        .json = tags_result.body,
        .rev_name = tag_name,
        .tarball_url = allocUrlTarball(scratch.allocator(), pkg, tag_name),
    } };
}

/// Exits if a tag name from the package's forge isn't safe to use in URLs and file names.
fn checkTagName(pkg: *const PkgGit, tag_name: []const u8) void {
    if (!isSafeRev(tag_name)) errExit(
        "{f}: unsupported tag name \"{f}\", tag names may only contain letters, digits, '.', '_' and '-'",
        .{ pkg.*, std.zig.fmtString(tag_name) },
    );
}

fn fetchTip(scratch: *Scratch, allocator: std.mem.Allocator, pkg: *const PkgGit, http: Http) GitArchive {
    log.info("fetching tip commit for {f}...", .{pkg.*});
    const commit_url = switch (pkg.forge) {
        .github => allocRepoApiUrl(scratch.allocator(), pkg, "/commits/HEAD", .{}),
        .gitlab => allocRepoApiUrl(scratch.allocator(), pkg, "/repository/commits/HEAD", .{}),
        .forgejo => allocRepoApiUrl(scratch.allocator(), pkg, "/git/commits/HEAD", .{}),
        .srht => unreachable, // fetchTipSrht
    };
    defer scratch.allocator().free(commit_url);
    var timer: Timer = .init(http.ctx.io);
    const commit_result = fetchGitJson(commit_url, http, allocator);
    if (commit_result.status != .ok)
        fetchErrExit(commit_url, commit_result);
    const elapsed = timer.seconds();
    log.info("fetched tip commit JSON in {d:.2} seconds", .{elapsed});
    const sha = blk: {
        var err: ParseJsonError = undefined;
        break :blk parseSha(commit_result.body.items, &err, switch (pkg.forge) {
            .github, .forgejo => "sha",
            .gitlab => "id",
            .srht => unreachable,
        }) catch jsonErrorExit(scratch, http.ctx, commit_url, commit_result.body.items, &err);
    };
    const sha_hex = sha.hex();
    const tarball_url = allocUrlTarball(allocator, pkg, &sha_hex);
    errdefer allocator.free(tarball_url);
    return .{ .tip = .{
        .json = commit_result.body,
        .sha = sha,
        .tarball_url = tarball_url,
    } };
}

/// Finds the latest version of a sourcehut package, which has no releases: the
/// newest tag from the repo's refs feed, otherwise its tip.
fn getLatestTagSrht(scratch: *Scratch, http: Http, pkg: *const PkgGit) GitArchive {
    log.info("fetching latest tag for {f}...", .{pkg.*});
    const refs_url = allocRepoApiUrl(scratch.allocator(), pkg, "/refs/rss.xml", .{});
    defer scratch.allocator().free(refs_url);
    const timer: Timer = .init(http.ctx.io);
    var refs_result = fetchGitJson(refs_url, http, scratch.allocator());
    errdefer refs_result.body.deinit(scratch.allocator());
    if (refs_result.status != .ok)
        fetchErrExit(refs_url, refs_result);
    log.info("fetched refs feed in {d:.2} seconds", .{timer.seconds()});
    const tag_name = (parseLatestTagSrht(refs_result.body.items) catch |err| errExit(
        "parse refs feed from '{s}' failed with {t}",
        .{ refs_url, err },
    )) orelse {
        log.info("no tags found, falling back to tip for {f}...", .{pkg.*});
        refs_result.body.deinit(scratch.allocator());
        const tip_archive = fetchTipSrht(scratch, scratch.allocator(), pkg, http);
        log.info("tip is commit {f}", .{&tip_archive.tip.sha});
        return tip_archive;
    };
    checkTagName(pkg, tag_name);
    log.info("latest tag is {s}", .{tag_name});
    return .{ .rev = .{
        .json = refs_result.body,
        .rev_name = tag_name,
        .tarball_url = allocUrlTarball(scratch.allocator(), pkg, tag_name),
    } };
}

/// Returns the first tag in a sourcehut refs feed (newest first), the title of its
/// first item, or null if it has no items.
fn parseLatestTagSrht(rss: []const u8) error{MalformedRefsFeed}!?[]const u8 {
    const item_start = std.mem.indexOf(u8, rss, "<item>") orelse return null;
    const title_open = "<title>";
    const title_start = (std.mem.indexOfPos(u8, rss, item_start, title_open) orelse
        return error.MalformedRefsFeed) + title_open.len;
    const title_end = std.mem.indexOfPos(u8, rss, title_start, "</title>") orelse
        return error.MalformedRefsFeed;
    return rss[title_start..title_end];
}

test parseLatestTagSrht {
    try std.testing.expectEqualStrings("v0.2.0", (try parseLatestTagSrht(
        "<rss version=\"2.0\"><channel><title>~u/r refs</title><item><title>v0.2.0</title>" ++
            "<description /></item><item><title>v0.1.8</title></item></channel></rss>",
    )).?);
    try std.testing.expectEqual(null, try parseLatestTagSrht("<rss><channel><title>~u/r refs</title></channel></rss>"));
    try std.testing.expectError(error.MalformedRefsFeed, parseLatestTagSrht("<rss><channel><item><description /></item>"));
}

/// Finds a sourcehut package's tip, its HEAD commit, from git's smart HTTP ref
/// advertisement since sourcehut's API needs a token.
fn fetchTipSrht(scratch: *Scratch, allocator: std.mem.Allocator, pkg: *const PkgGit, http: Http) GitArchive {
    log.info("fetching tip commit for {f}...", .{pkg.*});
    const refs_url = allocRepoApiUrl(scratch.allocator(), pkg, "/info/refs?service=git-upload-pack", .{});
    defer scratch.allocator().free(refs_url);
    const timer: Timer = .init(http.ctx.io);
    const refs_result = fetchGitJson(refs_url, http, allocator);
    if (refs_result.status != .ok)
        fetchErrExit(refs_url, refs_result);
    log.info("fetched refs in {d:.2} seconds", .{timer.seconds()});
    const sha = (parseUploadPackHead(refs_result.body.items) catch |err| errExit(
        "parse git refs from '{s}' failed with {t}",
        .{ refs_url, err },
    )) orelse errExit("{f} has no commits (no HEAD in '{s}')", .{ pkg.*, refs_url });
    return .{ .tip = .{
        .json = refs_result.body,
        .sha = sha,
        .tarball_url = allocUrlTarball(allocator, pkg, &sha.hex()),
    } };
}

/// Returns HEAD's commit from a git-upload-pack ref advertisement (pkt-lines: the
/// service line, a flush, then refs with HEAD first), or null for an empty repo.
fn parseUploadPackHead(text: []const u8) error{MalformedGitRefs}!?GitSha {
    var index: usize = 0;
    const service = try nextPktLine(text, &index) orelse return error.MalformedGitRefs;
    if (!std.mem.startsWith(u8, service, "# service=git-upload-pack")) return error.MalformedGitRefs;
    if (try nextPktLine(text, &index) != null) return error.MalformedGitRefs; // expected a flush
    // An empty repo has no refs, only the flush.
    const first_ref = try nextPktLine(text, &index) orelse return null;
    // "<sha> HEAD\x00<capabilities>"
    if (first_ref.len < 40 + " HEAD".len) return error.MalformedGitRefs;
    const name_end = std.mem.indexOfScalarPos(u8, first_ref, 41, 0) orelse
        std.mem.indexOfScalarPos(u8, first_ref, 41, '\n') orelse first_ref.len;
    if (first_ref[40] != ' ' or !std.mem.eql(u8, first_ref[41..name_end], "HEAD")) return null;
    return GitSha.fromHex(first_ref[0..40]) orelse error.MalformedGitRefs;
}

/// Returns the next pkt-line's payload, or null for a flush packet ("0000").
fn nextPktLine(text: []const u8, index: *usize) error{MalformedGitRefs}!?[]const u8 {
    if (text.len - index.* < 4) return error.MalformedGitRefs;
    const len = std.fmt.parseInt(u16, text[index.*..][0..4], 16) catch return error.MalformedGitRefs;
    if (len == 0) {
        index.* += 4;
        return null;
    }
    if (len < 4 or len > text.len - index.*) return error.MalformedGitRefs;
    const payload = text[index.* + 4 .. index.* + len];
    index.* += len;
    return payload;
}

/// A pkt-line: the payload prefixed with its length (including the prefix) in hex.
fn testPkt(comptime payload: []const u8) []const u8 {
    return comptime std.fmt.comptimePrint("{x:0>4}", .{payload.len + 4}) ++ payload;
}

test parseUploadPackHead {
    const sha = "128ec0df11d2ed37477a4f6b8e9958b9feb6c09d";
    const refs = comptime testPkt("# service=git-upload-pack\n") ++ "0000" ++
        testPkt(sha ++ " HEAD\x00multi_ack thin-pack side-band-64k ofs-delta symref=HEAD:refs/heads/main\n") ++
        testPkt(sha ++ " refs/heads/main\n") ++ "0000";
    // the bytes git.sr.ht's response starts with
    try std.testing.expect(std.mem.startsWith(u8, refs, "001e# service=git-upload-pack\n0000"));
    try std.testing.expectEqualStrings(sha, &(try parseUploadPackHead(refs)).?.hex());
    // an empty repo
    try std.testing.expectEqual(null, try parseUploadPackHead("001e# service=git-upload-pack\n00000000"));
    try std.testing.expectError(error.MalformedGitRefs, parseUploadPackHead("<html>not git</html>"));
    try std.testing.expectError(error.MalformedGitRefs, parseUploadPackHead("001e# service=git-upload-pack\n00ff"));
}

fn installPkgGit(scratch: *Scratch, config: *const InstallConfig, pkg: PkgGit) !void {
    const scratch_pos = scratch.position();
    defer scratch.restorePosition(scratch_pos);
    const io = config.ctx.io;
    var client: std.http.Client = .{ .allocator = scratch.allocator(), .io = io };
    defer client.deinit();
    const http: Http = .{ .ctx = config.ctx, .client = &client, .git_auth = config.git_auth };

    var archive: GitArchive = switch (pkg.commit) {
        .latest_release => switch (pkg.forge) {
            .github, .gitlab, .forgejo => getLatestRelease(scratch, http, &pkg),
            .srht => getLatestTagSrht(scratch, http, &pkg),
        },
        .rev => |rev| .{ .rev = .{
            .json = .empty,
            .rev_name = rev,
            .tarball_url = allocUrlTarball(scratch.allocator(), &pkg, rev),
        } },
        .tip => switch (pkg.forge) {
            .github, .gitlab, .forgejo => fetchTip(scratch, scratch.allocator(), &pkg, http),
            .srht => fetchTipSrht(scratch, scratch.allocator(), &pkg, http),
        },
    };
    defer archive.deinit(scratch.allocator());

    const manifest_path = std.fmt.allocPrint(
        scratch.allocator(),
        "{s}{c}manifests{1c}{f}+{f}",
        .{ config.app_data_path, std.fs.path.sep, pkg.fmtFileName(), archive.fmtUniqueName() },
    ) catch |e| oom(e);
    defer scratch.allocator().free(manifest_path);
    if (std.Io.Dir.cwd().readFileAlloc(io, manifest_path, scratch.allocator(), .unlimited)) |manifest| {
        defer scratch.freeLifo(manifest);
        var line_it = std.mem.tokenizeScalar(u8, manifest, '\n');

        var installed: bool = true;
        while (line_it.next()) |line| {
            switch (parseManifestLine(line)) {
                .bin => |bin| if (!try binInstalled(scratch, config, bin.name, bin.sha256, bin.pdb_sha256)) {
                    installed = false;
                },
            }
        }
        if (installed) {
            std.log.info("{f}: already installed", .{pkg});
            return;
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return reportError("read '{s}' failed with {t}", .{ manifest_path, err }),
    }

    const pkg_cache_path = std.fmt.allocPrint(
        scratch.allocator(),
        "{s}{c}{f}+{f}.tar.gz",
        .{ config.cache_path, std.fs.path.sep, pkg.fmtFileName(), archive.fmtUniqueName() },
    ) catch |e| oom(e);
    defer scratch.free(pkg_cache_path);

    try downloadToCache(scratch, http, archive.url(), pkg_cache_path);

    const extract_dir_path = allocTmpPath(
        scratch.allocator(),
        config.ctx.tmp_dir,
        "hew-{f}+{f}",
        .{ pkg.fmtFileName(), archive.fmtUniqueName() },
    );
    defer scratch.free(extract_dir_path);

    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, extract_dir_path) catch |err|
        return reportError("deleteTree '{s}' failed with {t}", .{ extract_dir_path, err });
    std.Io.Dir.createDirAbsolute(io, extract_dir_path, .default_dir) catch |err| return reportError(
        "create '{s}' failed with {t}",
        .{ extract_dir_path, err },
    );
    {
        var extract_dir = std.Io.Dir.openDirAbsolute(io, extract_dir_path, .{}) catch |err| return reportError(
            "open '{s}' failed with {t}",
            .{ extract_dir_path, err },
        );
        defer extract_dir.close(io);

        const tarball_file = cwd.openFile(io, pkg_cache_path, .{}) catch |err| return reportError(
            "open '{s}' failed with {t}",
            .{ pkg_cache_path, err },
        );
        defer tarball_file.close(io);
        var tarball_read_buf: [4096]u8 = undefined;
        var tarball_reader = tarball_file.reader(io, &tarball_read_buf);
        var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
        var decompressor: std.compress.flate.Decompress = .init(&tarball_reader.interface, .gzip, &decompress_buf);

        std.tar.extract(
            io,
            extract_dir,
            &decompressor.reader,
            .{ .strip_components = 1 },
        ) catch |err| return reportError("extract tarball failed with {t}", .{err});
        log.info("extracted to {s}", .{extract_dir_path});
        const revision = archive.allocRevision(scratch.allocator());
        defer scratch.free(revision);
        try installPkgPath(scratch, config, manifest_path, extract_dir_path, .{ .revision = revision });
    }
    log.info("clean source: rm -rf {s}", .{extract_dir_path});
    cwd.deleteTree(io, extract_dir_path) catch |err|
        return reportError("deleteTree '{s}' failed with {t}", .{ extract_dir_path, err });
    if (config.keep_archives) {
        log.info("keeping archive: {s}", .{pkg_cache_path});
    } else {
        log.info("clean archive: rm {s}", .{pkg_cache_path});
        std.Io.Dir.deleteFileAbsolute(io, pkg_cache_path) catch |err|
            return reportError("delete '{s}' failed with {t}", .{ pkg_cache_path, err });
    }
}

fn binInstalled(
    scratch: *Scratch,
    config: *const InstallConfig,
    name: []const u8,
    sha256: *const [32]u8,
    pdb_sha256: ?*const [32]u8,
) !bool {
    const expected = std.fmt.allocPrint(
        scratch.allocator(),
        "{s}{c}{s}",
        .{ config.bin_path, std.fs.path.sep, name },
    ) catch |e| oom(e);
    defer scratch.freeLifo(expected);
    const io = config.ctx.io;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var which_it = which.Iterator.fromEnv(io, config.ctx.environ, &path_buf);
    while (try which_it.next(name)) |which_path| {
        if (std.mem.eql(u8, which_path, expected))
            break;
        if (!config.allow_shadow) return reportError(
            "{s} is shadowed by {s} (use --allow-shadow to allow this)",
            .{ expected, which_path },
        );
        std.log.info("{s} is shadowed by {s}", .{ expected, which_path });
    } else {
        std.log.info("{s}: not installed", .{name});
        return false;
    }
    const which_sha256 = try hashFile(io, std.Io.Dir.cwd(), expected);
    if (!std.mem.eql(u8, &which_sha256, sha256)) {
        std.log.info("{s}: installed but with different hash", .{name});
        return false;
    }
    if (pdb_sha256) |expected_pdb| {
        if (!std.ascii.endsWithIgnoreCase(name, ".exe"))
            return reportError("manifest has pdb hash for non-.exe file '{s}'", .{name});
        const stem = name[0 .. name.len - 4];
        const pdb_path = std.fmt.allocPrint(
            scratch.allocator(),
            "{s}{c}{s}.pdb",
            .{ config.bin_path, std.fs.path.sep, stem },
        ) catch |e| oom(e);
        defer scratch.freeLifo(pdb_path);
        const actual_pdb = hashFile(io, std.Io.Dir.cwd(), pdb_path) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.info("{s}: pdb not installed", .{pdb_path});
                return false;
            },
            else => return reportError("hash '{s}' failed with {t}", .{ pdb_path, err }),
        };
        if (!std.mem.eql(u8, &actual_pdb, expected_pdb)) {
            std.log.info("{s}: installed but with different hash", .{pdb_path});
            return false;
        }
    }
    return true;
}

fn hashFile(io: std.Io, dir: std.Io.Dir, name: []const u8) ![32]u8 {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    var hasher = Sha256.init(.{});
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return reader.err.?,
        };
        hasher.update(chunk);
        reader.interface.toss(chunk.len);
    }
    return hasher.finalResult();
}

fn runZigBuild(
    io: std.Io,
    zig_path: []const u8,
    path: []const u8,
    dir: std.Io.Dir,
    environ_map: *const std.process.Environ.Map,
    mode: enum { fetch, build },
) error{Reported}!void {
    const optimize = "-Doptimize=ReleaseFast";
    const argv: []const []const u8 = switch (mode) {
        .fetch => &.{ zig_path, "build", "install", optimize, "--fetch" },
        .build => &.{ zig_path, "build", "install", optimize },
    };
    const label: []const u8 = switch (mode) {
        .fetch => "zig build install --fetch",
        .build => "zig build install",
    };
    log.info(
        "cd {s} && {s} build install {s}{s}",
        .{ path, zig_path, optimize, switch (mode) {
            .fetch => " --fetch",
            .build => "",
        } },
    );

    const timer: Timer = .init(io);
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .environ_map = environ_map,
    }) catch |err| return reportError("run {s} failed with {t}", .{ label, err });
    const term = child.wait(io) catch |err| return reportError("{s} wait failed with {t}", .{ label, err });
    log.info("{s} completed in {d:.2} seconds", .{ label, timer.seconds() });
    switch (term) {
        .exited => |code| if (code != 0) {
            errExit("{s} exited with code {d}", .{ label, code });
        },
        .signal => |sig| errExit("{s} killed by signal {t}", .{ label, sig }),
        .stopped => |sig| errExit("{s} stopped by signal {t}", .{ label, sig }),
        .unknown => |val| errExit("{s} terminated with unknown status {d}", .{ label, val }),
    }
}

fn writeManifest(io: std.Io, scratch: *Scratch, manifest_path: []const u8, source_dir: std.Io.Dir) !void {
    var zig_out = source_dir.openDir(io, "zig-out", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => errExit("zig build did not install any files to zig-out", .{}),
        else => return reportError("open zig-out failed with {t}", .{err}),
    };
    defer zig_out.close(io);

    // Verify only bin/ exists in zig-out
    var zig_out_it = zig_out.iterate();
    while (zig_out_it.next(io) catch |err| return reportError(
        "iterate zig-out failed with {t}",
        .{err},
    )) |entry| {
        if (std.mem.eql(u8, entry.name, "bin")) {
            if (entry.kind != .directory) return reportError("zig-out/bin is not a directory", .{});
        } else {
            errExit("unexpected entry in zig-out: '{s}' - only bin/ is currently supported", .{entry.name});
        }
    }

    var bin_dir = zig_out.openDir(io, "bin", .{ .iterate = true }) catch |err|
        return reportError("open zig-out/bin failed with {t}", .{err});
    defer bin_dir.close(io);

    const manifest_dir_path = std.fs.path.dirname(manifest_path) orelse ".";
    std.Io.Dir.createDirAbsolute(io, manifest_dir_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return reportError("create '{s}' failed with {t}", .{ manifest_dir_path, err }),
    };
    var manifest_dir = std.Io.Dir.openDirAbsolute(io, manifest_dir_path, .{}) catch |err|
        return reportError("open '{s}' failed with {t}", .{ manifest_dir_path, err });
    defer manifest_dir.close(io);

    const manifest_name = std.fs.path.basename(manifest_path);
    const tmp_name = std.fmt.allocPrint(scratch.allocator(), "{s}.tmp", .{manifest_name}) catch |e| oom(e);
    defer scratch.freeLifo(tmp_name);
    const file = manifest_dir.createFile(io, tmp_name, .{}) catch |err|
        return reportError("create '{s}/{s}' failed with {t}", .{ manifest_dir_path, tmp_name, err });
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);

    var bin_count: usize = 0;
    var bin_it = bin_dir.iterate();
    while (bin_it.next(io) catch |err| return reportError(
        "iterate zig-out/bin failed with {t}",
        .{err},
    )) |entry| {
        if (entry.kind != .file) continue;
        // PDB files are written as options on their .exe line
        if (std.ascii.endsWithIgnoreCase(entry.name, ".pdb")) continue;
        const hash = hashFile(io, bin_dir, entry.name) catch |err|
            return reportError("hash zig-out/bin/{s} failed with {t}", .{ entry.name, err });
        writer.interface.print("bin/{s} {x}", .{ entry.name, hash }) catch return writer.err.?;
        if (builtin.os.tag == .windows and std.ascii.endsWithIgnoreCase(entry.name, ".exe")) {
            const stem = entry.name[0 .. entry.name.len - 4];
            var pdb_name_buf: [std.fs.max_name_bytes]u8 = undefined;
            const pdb_name = std.fmt.bufPrint(&pdb_name_buf, "{s}.pdb", .{stem}) catch
                errExit("binary name too long: '{s}'", .{entry.name});
            if (hashFile(io, bin_dir, pdb_name)) |pdb_hash| {
                writer.interface.print(" pdb={x}", .{pdb_hash}) catch return writer.err.?;
            } else |err| return reportError(
                "hash zig-out/bin/{s} failed with {t}",
                .{ pdb_name, err },
            );
        }
        writer.interface.print("\n", .{}) catch return writer.err.?;
        bin_count += 1;
    }
    writer.interface.flush() catch return writer.err.?;
    if (bin_count == 0) {
        errExit("zig build produced no binaries in zig-out/bin/", .{});
    }

    manifest_dir.rename(tmp_name, manifest_dir, manifest_name, io) catch |err|
        return reportError("rename '{s}' to '{s}' failed with {t}", .{ tmp_name, manifest_name, err });
}

const BuildRevision = union(enum) {
    installed_from_path,
    revision: []const u8,
};

fn installPkgPath(
    scratch: *Scratch,
    config: *const InstallConfig,
    manifest_path: []const u8,
    path: []const u8,
    revision: BuildRevision,
) !void {
    const scratch_pos = scratch.position();
    defer scratch.restorePosition(scratch_pos);
    const io = config.ctx.io;

    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch |err| return reportError(
        "open '{s}' failed with {t}",
        .{ path, err },
    );
    defer dir.close(io);

    dir.access(io, "build.zig", .{}) catch |err| switch (err) {
        error.FileNotFound => errExit("package at '{s}' has no build.zig", .{path}),
        else => return reportError(
            "access build.zig in '{s}' failed with {t}",
            .{ path, err },
        ),
    };

    const zig_path = allocAnyzigPath(
        scratch.allocator(),
        config.app_data_path,
        anyzig_version,
    ) catch |e| oom(e);
    defer scratch.free(zig_path);
    try ensureAnyzig(scratch, config, zig_path);

    var environ_map = config.ctx.environ.createMap(scratch.allocator()) catch |err| switch (err) {
        error.OutOfMemory => |e| oom(e),
        else => |e| return reportError("get environment failed with {t}", .{e}),
    };
    defer environ_map.deinit();
    switch (revision) {
        .installed_from_path => {},
        .revision => |r| environ_map.put("HEW_BUILD_REVISION", r) catch |e| oom(e),
    }

    try runZigBuild(io, zig_path, path, dir, &environ_map, .fetch);
    try runZigBuild(io, zig_path, path, dir, &environ_map, .build);

    try writeManifest(io, scratch, manifest_path, dir);
    std.log.info("wrote manifest to '{s}'", .{manifest_path});

    {
        const manifest = try std.Io.Dir.cwd().readFileAlloc(
            io,
            manifest_path,
            scratch.allocator(),
            .unlimited,
        );
        defer scratch.freeLifo(manifest);
        var line_it = std.mem.tokenizeScalar(u8, manifest, '\n');
        while (line_it.next()) |line| {
            switch (parseManifestLine(line)) {
                .bin => {},
            }
        }
    }

    std.Io.Dir.createDirAbsolute(io, config.bin_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return reportError("create '{s}' failed with {t}", .{ config.bin_path, err }),
    };

    // Copy executables from zig-out/bin/ to bin_path
    var zig_out_bin = dir.openDir(io, "zig-out/bin", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            log.warn("zig build produced no binaries in zig-out/bin/", .{});
            return;
        },
        else => return reportError("open zig-out/bin failed with {t}", .{err}),
    };
    defer zig_out_bin.close(io);

    var dest_dir = std.Io.Dir.openDirAbsolute(io, config.bin_path, .{}) catch |err| return reportError(
        "open '{s}' failed with {t}",
        .{ config.bin_path, err },
    );
    defer dest_dir.close(io);

    var it = zig_out_bin.iterate();
    var install_bin_count: usize = 0;
    while (it.next(io) catch |err| return reportError(
        "iterate zig-out/bin failed with {t}",
        .{err},
    )) |entry| {
        if (entry.kind != .file) return reportError(
            "unexpected {t} at zig-out/bin/{s}",
            .{ entry.kind, entry.name },
        );
        const kind = binFileKind(entry.name) orelse return reportError(
            "unexpected file '{s}' in zig-out/bin/",
            .{entry.name},
        );
        const kind2: enum { exe } = blk: switch (kind) {
            .pdb => continue, // handled alongside the .exe below
            .exe => break :blk .exe,
            // .data => break :blk .data,
        };

        if (!config.allow_overwrite) {
            const exists: bool = if (dest_dir.access(io, entry.name, .{})) true else |err| switch (err) {
                error.FileNotFound => false,
                else => return reportError(
                    "access '{s}{c}{s}' failed with {t}",
                    .{ config.bin_path, std.fs.path.sep, entry.name, err },
                ),
            };
            if (exists) {
                if (!config.interactive) return reportError(
                    "'{s}{c}{s}' already exists (use --allow-overwrite or invoke hew interactively)",
                    .{ config.bin_path, std.fs.path.sep, entry.name },
                );
                var stderr_buf: [4096]u8 = undefined;
                var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
                const overwrite = promptYesNo(
                    io,
                    &stderr.interface,
                    "'{s}{c}{s}' already exists. Overwrite?",
                    .{ config.bin_path, std.fs.path.sep, entry.name },
                ) catch |err| switch (err) {
                    error.WriteFailed => return stderr.err.?,
                    else => |e| return e,
                };
                if (!overwrite) {
                    log.info("skipping {s}", .{entry.name});
                    continue;
                }
            }
        }

        copyOverwriteMaybeRunning(io, scratch, config.ctx.tmp_dir, config.interactive, zig_out_bin, entry.name, dest_dir, config.bin_path, entry.name) catch |err| return reportError(
            "copy '{s}' to '{s}' failed with {t}",
            .{ entry.name, config.bin_path, err },
        );
        log.info("installed {s}{c}{s}", .{ config.bin_path, std.fs.path.sep, entry.name });
        install_bin_count += 1;

        // Handle the pdb alongside its exe
        if (builtin.os.tag == .windows and std.ascii.endsWithIgnoreCase(entry.name, ".exe")) {
            const stem = entry.name[0 .. entry.name.len - 4];
            var pdb_name_buf: [std.fs.max_name_bytes]u8 = undefined;
            const pdb_name = std.fmt.bufPrint(&pdb_name_buf, "{s}.pdb", .{stem}) catch errExit(
                "binary name too long: '{s}'",
                .{entry.name},
            );
            if (zig_out_bin.access(io, pdb_name, .{})) {
                copyOverwriteMaybeRunning(io, scratch, config.ctx.tmp_dir, config.interactive, zig_out_bin, pdb_name, dest_dir, config.bin_path, pdb_name) catch |err| return reportError(
                    "copy '{s}' to '{s}' failed with {t}",
                    .{ pdb_name, config.bin_path, err },
                );
                log.info("installed {s}{c}{s}", .{ config.bin_path, std.fs.path.sep, pdb_name });
                install_bin_count += 1;
            } else |_| {
                // No pdb in source — delete stale pdb in dest if present
                dest_dir.deleteFile(io, pdb_name) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return reportError(
                        "delete '{s}{c}{s}' failed with {t}",
                        .{ config.bin_path, std.fs.path.sep, pdb_name, err },
                    ),
                };
            }
        }

        switch (kind2) {
            // .data => {},
            .exe => {
                const expected = std.fmt.allocPrint(
                    scratch.allocator(),
                    "{s}{c}{s}",
                    .{ config.bin_path, std.fs.path.sep, entry.name },
                ) catch |e| oom(e);
                defer scratch.freeLifo(expected);
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                var which_it = which.Iterator.fromEnv(io, config.ctx.environ, &path_buf);
                while (try which_it.next(entry.name)) |which_path| {
                    if (std.mem.eql(u8, which_path, expected))
                        break;
                    if (!config.allow_shadow) return reportError(
                        "{s} is shadowed by {s} (use --allow-shadow to allow this)",
                        .{ expected, which_path },
                    );
                    std.log.info("{s} is shadowed by {s}", .{ expected, which_path });
                } else return reportError(
                    "installed {s} to {s} but it is not in PATH",
                    .{ entry.name, config.bin_path },
                );
            },
        }
    }
    std.log.info("installed {} file{s} to {s}", .{
        install_bin_count,
        @as([]const u8, if (install_bin_count == 1) "" else "s"),
        config.bin_path,
    });
}

// On Windows you cannot overwrite a file while it's open for execution. If the
// target is our own running executable, try to rename it out of the way
// automatically (TMPDIR first, then same-dir); otherwise prompt the user.
fn copyOverwriteMaybeRunning(
    io: std.Io,
    scratch: *Scratch,
    tmp_dir: []const u8,
    interactive: bool,
    src_dir: std.Io.Dir,
    src_name: []const u8,
    dest_dir: std.Io.Dir,
    dest_dir_path: []const u8,
    dest_name: []const u8,
) !void {
    while (true) {
        src_dir.copyFile(src_name, dest_dir, dest_name, io, .{}) catch |err| switch (err) {
            error.AccessDenied => |copy_file_error| if (builtin.os.tag != .windows) return err else {
                const scratch_pos = scratch.position();
                defer scratch.restorePosition(scratch_pos);
                const abs_dest_path = std.fmt.allocPrint(
                    scratch.allocator(),
                    "{s}{c}{s}",
                    .{ dest_dir_path, std.fs.path.sep, dest_name },
                ) catch |e| oom(e);
                if (try isSelfExe(io, abs_dest_path)) {
                    if (try tryRenameOutOfWay(io, scratch, tmp_dir, dest_dir, abs_dest_path, dest_dir_path, dest_name)) continue;
                    // Auto-fallback exhausted; fall through to prompt.
                }
                if (!interactive) return copy_file_error;
                switch (try promptRunningFileConflict(io, dest_dir_path, dest_name)) {
                    .cancel => errExit("install cancelled", .{}),
                    .rename => {
                        var backup_buf: [std.fs.max_name_bytes]u8 = undefined;
                        const backup_name = std.fmt.bufPrint(&backup_buf, "{s}.deleteme", .{dest_name}) catch
                            errExit("name too long: '{s}.deleteme'", .{dest_name});
                        dest_dir.deleteFile(io, backup_name) catch |e| switch (e) {
                            error.FileNotFound => {},
                            error.AccessDenied => {
                                log.err("delete existing '{s}{c}{s}' failed with {t}", .{ dest_dir_path, std.fs.path.sep, backup_name, e });
                                continue;
                            },
                            else => return e,
                        };
                        renameMaybeRunning(io, dest_dir, dest_name, dest_dir, backup_name) catch |e| switch (e) {
                            error.AccessDenied,
                            error.SharingViolation,
                            error.DeletePending,
                            => {
                                log.err("rename '{s}' to '{s}' in directory '{s}' failed with {t}", .{ dest_name, backup_name, dest_dir_path, e });
                                continue;
                            },
                            else => return e,
                        };
                        continue;
                    },
                    .retry => continue,
                }
            },
            else => return err,
        };
        return;
    }
}

fn isSelfExe(io: std.Io, abs_target_path: []const u8) !bool {
    var self_raw_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_raw = self_raw_buf[0..try std.process.executablePath(io, &self_raw_buf)];
    var self_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_real = self_real_buf[0..try std.Io.Dir.realPathFileAbsolute(io, self_raw, &self_real_buf)];

    var target_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_real = target_real_buf[0 .. std.Io.Dir.realPathFileAbsolute(io, abs_target_path, &target_real_buf) catch |err| switch (err) {
        // Target vanished between copy attempt and now — definitely not us.
        error.FileNotFound => return false,
        else => |e| return e,
    }];

    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(self_real, target_real);
    return std.mem.eql(u8, self_real, target_real);
}

// `std.fs` rename (posix.renameatW) opens the source with GENERIC_WRITE, which
// Windows refuses for a running executable. Win32 MoveFileEx renames in-use exes
// fine because it opens the source needing only DELETE access — so do the same:
// open with DELETE, then NtSetInformationFile with FileRenameInformation.
fn renameMaybeRunning(
    io: std.Io,
    old_dir: std.Io.Dir,
    old_name: []const u8,
    new_dir: std.Io.Dir,
    new_name: []const u8,
) !void {
    if (builtin.os.tag != .windows) return old_dir.rename(old_name, new_dir, new_name, io);

    const w = std.os.windows;
    const old_path = try std.Io.Threaded.sliceToPrefixedFileW(old_dir.handle, old_name, .{});
    const new_path = try std.Io.Threaded.sliceToPrefixedFileW(new_dir.handle, new_name, .{});
    const old_w = old_path.span();
    const new_w = new_path.span();

    // std.Io.Threaded has the same NtCreateFile call (OpenFile) but it's private.
    var src_fd: w.HANDLE = undefined;
    var create_io_status: w.IO_STATUS_BLOCK = undefined;
    switch (w.ntdll.NtCreateFile(
        &src_fd,
        .{ .STANDARD = .{ .RIGHTS = .{ .DELETE = true }, .SYNCHRONIZE = true } },
        &.{
            .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(old_w)) null else old_dir.handle,
            .Attributes = .{},
            .ObjectName = @constCast(&w.UNICODE_STRING.init(old_w)),
            .SecurityDescriptor = null,
        },
        &create_io_status,
        null,
        .{ .NORMAL = true },
        .VALID_FLAGS,
        .OPEN,
        .{ .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = true },
        null,
        0,
    )) {
        .SUCCESS => {},
        .ACCESS_DENIED => return error.AccessDenied,
        .SHARING_VIOLATION => return error.SharingViolation,
        .DELETE_PENDING => return error.DeletePending,
        .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
        .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        else => |rc| return unexpectedNtstatus("NtCreateFile", rc),
    }
    defer w.CloseHandle(src_fd);

    var rename_info: w.FILE.RENAME_INFORMATION = .init(.{
        .Flags = .{ .REPLACE_IF_EXISTS = true }, // matching std.Io.Dir.rename
        .RootDirectory = if (std.fs.path.isAbsoluteWindowsWtf16(new_w)) null else new_dir.handle,
        .FileName = new_w,
    });
    const rename_info_buf = rename_info.toBuffer();
    var io_status: w.IO_STATUS_BLOCK = undefined;
    switch (w.ntdll.NtSetInformationFile(src_fd, &io_status, rename_info_buf.ptr, @intCast(rename_info_buf.len), .Rename)) {
        .SUCCESS => {},
        .INVALID_HANDLE => unreachable,
        .INVALID_PARAMETER => unreachable,
        .OBJECT_PATH_SYNTAX_BAD => unreachable,
        .ACCESS_DENIED => return error.AccessDenied,
        .SHARING_VIOLATION => return error.SharingViolation,
        .DELETE_PENDING => return error.DeletePending,
        .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
        .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
        .NOT_SAME_DEVICE => return error.CrossDevice,
        .OBJECT_NAME_COLLISION => return error.PathAlreadyExists,
        else => |rc| return unexpectedNtstatus("NtSetInformationFile(Rename)", rc),
    }
}

/// Logs an unexpected NTSTATUS as a number. Never print a windows error code as
/// a tag name: that links in the names of every code.
fn unexpectedNtstatus(what: []const u8, status: std.os.windows.NTSTATUS) error{Unexpected} {
    log.err("{s} failed, NTSTATUS 0x{x}", .{ what, @backingInt(status) });
    return error.Unexpected;
}

/// Try TMPDIR rename, then same-dir `.deleteme` rename. Returns true if the
/// file was moved out of the way (caller should retry the copy).
fn tryRenameOutOfWay(
    io: std.Io,
    scratch: *Scratch,
    tmp_dir_path: []const u8,
    dest_dir: std.Io.Dir,
    abs_src_path: []const u8,
    dest_dir_path: []const u8,
    dest_name: []const u8,
) !bool {
    const tmp_path = allocTmpPath(scratch.allocator(), tmp_dir_path, "hew-{s}.deleteme", .{dest_name});
    const tmp_name = std.fs.path.basename(tmp_path);
    if (std.Io.Dir.openDirAbsolute(io, tmp_dir_path, .{})) |opened| {
        var tmp_dir = opened;
        defer tmp_dir.close(io);
        tmp_dir.deleteFile(io, tmp_name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {}, // stale copy still locked; rename below will replace it or fail
        };
        if (renameMaybeRunning(io, dest_dir, dest_name, tmp_dir, tmp_name)) {
            log.info("renamed '{s}' to '{s}'", .{ abs_src_path, tmp_path });
            return true;
        } else |err| switch (err) {
            error.CrossDevice => {}, // fall through to same-dir
            else => return err,
        }
    } else |_| {} // can't open TMPDIR; fall through to same-dir

    var backup_buf: [std.fs.max_name_bytes]u8 = undefined;
    const backup_name = std.fmt.bufPrint(&backup_buf, "{s}.deleteme", .{dest_name}) catch
        errExit("name too long: '{s}.deleteme'", .{dest_name});
    dest_dir.deleteFile(io, backup_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return false, // existing backup can't be cleared; let prompt handle it
    };
    renameMaybeRunning(io, dest_dir, dest_name, dest_dir, backup_name) catch return false;
    log.info("renamed '{s}' to '{s}{c}{s}'", .{ abs_src_path, dest_dir_path, std.fs.path.sep, backup_name });
    return true;
}

const RunningFileChoice = enum { cancel, rename, retry };

fn promptRunningFileConflict(io: std.Io, dest_dir_path: []const u8, dest_name: []const u8) !RunningFileChoice {
    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    const w = &stderr.interface;
    w.print(
        \\'{s}{c}{s}' cannot be overwritten (file is in use, e.g. a running executable).
        \\  0) cancel
        \\  1) rename existing file to '{s}.deleteme' and install new file
        \\  2) retry (choose after you've removed/stopped the blocker yourself)
        \\
    , .{ dest_dir_path, std.fs.path.sep, dest_name, dest_name }) catch |err| switch (err) {
        error.WriteFailed => return stderr.err.?,
    };
    const choice = promptNumber(io, w, "choose", 2) catch |err| switch (err) {
        error.WriteFailed => return stderr.err.?,
        else => |e| return e,
    };
    return switch (choice) {
        0 => .cancel,
        1 => .rename,
        2 => .retry,
        else => unreachable,
    };
}

const ManifestLine = union(enum) {
    bin: struct {
        name: []const u8,
        sha256: *const [32]u8,
        pdb_sha256: ?*const [32]u8,
    },
};
fn parseManifestLine(line: []const u8) ManifestLine {
    if (std.mem.startsWith(u8, line, "bin/")) {
        const rest = line["bin/".len..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse
            errExit("malformed manifest line, missing hash: '{s}'", .{line});
        const name = rest[0..space];
        const after_name = rest[space + 1 ..];

        // Parse the hex hash (64 hex chars = 32 bytes)
        if (after_name.len < 64)
            errExit("malformed manifest line, bad hash length: '{s}'", .{line});
        const hash_hex = after_name[0..64];
        const dest: *[32]u8 = @constCast(hash_hex[0..32]);
        _ = std.fmt.hexToBytes(dest, hash_hex) catch
            errExit("malformed manifest line, invalid hex: '{s}'", .{line});

        // Parse optional key=value pairs
        var pdb_sha256: ?*const [32]u8 = null;
        var opts = after_name[64..];
        while (opts.len > 0 and opts[0] == ' ') {
            opts = opts[1..];
            const eq = std.mem.indexOfScalar(u8, opts, '=') orelse
                errExit("malformed manifest option, missing '=': '{s}'", .{line});
            const key = opts[0..eq];
            const val_start = opts[eq + 1 ..];
            if (std.mem.eql(u8, key, "pdb")) {
                if (val_start.len < 64)
                    errExit("malformed manifest line, bad pdb hash length: '{s}'", .{line});
                const pdb_hex = val_start[0..64];
                const pdb_dest: *[32]u8 = @constCast(pdb_hex[0..32]);
                _ = std.fmt.hexToBytes(pdb_dest, pdb_hex) catch
                    errExit("malformed manifest line, invalid pdb hex: '{s}'", .{line});
                pdb_sha256 = pdb_dest;
                opts = val_start[64..];
            } else {
                errExit("unknown manifest option '{s}': '{s}'", .{ key, line });
            }
        }

        return .{ .bin = .{ .name = name, .sha256 = dest, .pdb_sha256 = pdb_sha256 } };
    }
    errExit("malformed manifest line: '{s}'", .{line});
}

const Release = struct {
    tag_name: []const u8,
    tarball_url: []const u8,
};

const bearer_prefix = "Bearer ";
// GitHub's Actions GITHUB_TOKEN grew to 377 bytes (Nov 2026).
const max_auth_token_len = 512;
const github_auth_buf_len = bearer_prefix.len + max_auth_token_len;

/// The hosts hew sends API tokens to (see token_env_names). Tokens go only to
/// these exact hosts, never to a custom host, whatever its kind.
const TokenHost = enum { github, gitlab, codeberg };

/// Returns which host's token to send to `url`, if any: only https URLs to the exact
/// hosts hew uses for github.com, gitlab.com and codeberg.org (not their subdomains,
/// which can be run by anyone).
fn tokenHostFromUrl(url: []const u8) ?TokenHost {
    const uri = std.Uri.parse(url) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return null;
    if (uri.user != null or uri.password != null) return null;
    const host = (uri.host orelse return null).percent_encoded;
    for ([_]struct { []const u8, TokenHost }{
        .{ "github.com", .github },
        .{ "api.github.com", .github },
        .{ "gitlab.com", .gitlab },
        .{ "codeberg.org", .codeberg },
    }) |entry| {
        if (std.ascii.eqlIgnoreCase(host, entry[0])) return entry[1];
    }
    return null;
}

test tokenHostFromUrl {
    try std.testing.expectEqual(TokenHost.github, tokenHostFromUrl("https://api.github.com/repos/o/r/tarball/v1").?);
    try std.testing.expectEqual(TokenHost.github, tokenHostFromUrl("https://github.com/o/r/releases/download/v1/x.zip").?);
    try std.testing.expectEqual(TokenHost.gitlab, tokenHostFromUrl("https://gitlab.com/api/v4/projects/a%2Fb").?);
    try std.testing.expectEqual(TokenHost.codeberg, tokenHostFromUrl("https://codeberg.org/api/v1/repos/o/r").?);
    // not https
    try std.testing.expectEqual(null, tokenHostFromUrl("http://api.github.com/repos/o/r/tarball/v1"));
    // subdomains anyone could run
    try std.testing.expectEqual(null, tokenHostFromUrl("https://forum.gitlab.com/api/v1/repos/o/r"));
    try std.testing.expectEqual(null, tokenHostFromUrl("https://shop.github.com/api/v3/repos/o/r"));
    // look-alikes and userinfo
    try std.testing.expectEqual(null, tokenHostFromUrl("https://evilgithub.com/o/r"));
    try std.testing.expectEqual(null, tokenHostFromUrl("https://github.com.evil.com/o/r"));
    try std.testing.expectEqual(null, tokenHostFromUrl("https://github.com@evil.com/o/r"));
    try std.testing.expectEqual(null, tokenHostFromUrl("https://user@github.com/o/r"));
}

/// The environment variables that hold each git host's API token, in priority order.
const token_env_names: std.enums.EnumArray(TokenHost, [2][]const u8) = .init(.{
    .github = .{ "GH_TOKEN", "GITHUB_TOKEN" },
    .gitlab = .{ "GITLAB_TOKEN", "GL_TOKEN" },
    .codeberg = .{ "CB_TOKEN", "CODEBERG_TOKEN" },
});

/// The API tokens for git hosts (see token_env_names). Derive once with init and
/// pass to whatever makes requests. On windows the tokens are void so we never
/// cache a pointer into the process environment block, which moves when any
/// variable is modified; read reads the variables when called instead.
const GitAuth = struct {
    tokens: switch (builtin.os.tag) {
        .windows => void,
        else => std.enums.EnumArray(TokenHost, ?Token),
    },
    /// Hosts whose token source has been logged.
    logged: std.enums.EnumSet(TokenHost) = .empty,

    const Token = struct {
        env_name: []const u8,
        value: []const u8,
    };

    pub fn init(environ: std.process.Environ) GitAuth {
        if (builtin.os.tag == .windows) return .{ .tokens = {} };
        var tokens: std.enums.EnumArray(TokenHost, ?Token) = .initFill(null);
        for (std.enums.values(TokenHost)) |host| {
            for (token_env_names.get(host)) |env_name| {
                if (environ.getPosix(env_name)) |value| {
                    tokens.set(host, .{ .env_name = env_name, .value = value });
                    break;
                }
            }
        }
        return .{ .tokens = tokens };
    }

    /// Copies the token for `host` into `buf` (as WTF-8 on windows). Returns the
    /// name of the variable it came from and its length, or null if none are set.
    fn read(auth: *const GitAuth, host: TokenHost, buf: []u8) ?struct { []const u8, usize } {
        if (builtin.os.tag == .windows) {
            const environ: std.process.Environ = .{ .block = .global };
            switch (host) {
                inline else => |h| inline for (comptime token_env_names.get(h)) |env_name| {
                    if (environ.getWindows(std.unicode.wtf8ToWtf16LeStringLiteral(env_name))) |value| {
                        const len = std.unicode.calcWtf8Len(value);
                        if (len > buf.len) errExit("{s} too long (cannot exceed {d} but is {d})", .{ env_name, buf.len, len });
                        return .{ env_name, std.unicode.wtf16LeToWtf8(buf, value) };
                    }
                },
            }
            return null;
        }
        const token = auth.tokens.get(host) orelse return null;
        if (token.value.len > buf.len) errExit("{s} too long (cannot exceed {d} but is {d})", .{ token.env_name, buf.len, token.value.len });
        @memcpy(buf[0..token.value.len], token.value);
        return .{ token.env_name, token.value.len };
    }
};

fn gitAuthHeader(git_auth: *GitAuth, buf: *[github_auth_buf_len]u8, url: []const u8) std.http.Client.Request.Headers.Value {
    const host = tokenHostFromUrl(url) orelse return .default;
    const env_name, const token_len = git_auth.read(host, buf[bearer_prefix.len..]) orelse .{ "none", 0 };
    if (!git_auth.logged.contains(host)) {
        git_auth.logged.insert(host);
        log.info("{t} auth: {s}", .{ host, env_name });
    }
    if (token_len == 0) return .default;
    @memcpy(buf[0..bearer_prefix.len], bearer_prefix);
    return .{ .override = buf[0 .. bearer_prefix.len + token_len] };
}

/// What's needed to make HTTP requests to git hosts.
const Http = struct {
    ctx: *const ProcessEnv,
    client: *std.http.Client,
    git_auth: *GitAuth,
};

const FetchResult = struct {
    status: std.http.Status,
    body: std.ArrayList(u8),
};

fn fetchGitJson(url: []const u8, http: Http, allocator: std.mem.Allocator) FetchResult {
    var github_auth_buf: [github_auth_buf_len]u8 = undefined;

    var attempt_counter: u8 = 0;
    while (true) : (attempt_counter += 1) {
        var response_body: std.Io.Writer.Allocating = .init(allocator);
        defer response_body.deinit();
        const result = http.client.fetch(.{
            .location = .{ .url = url },
            .headers = .{
                .user_agent = .{ .override = "hew/0.0.1" },
                .authorization = gitAuthHeader(http.git_auth, &github_auth_buf, url),
            },
            .response_writer = &response_body.writer,
        }) catch |err| {
            errExit("fetch '{s}' failed with {t}", .{ url, err });
        };
        if (result.status == .too_many_requests and attempt_counter < rate_limit_retries) {
            retryAfterRateLimit(http.ctx.io, url, attempt_counter);
            continue;
        }
        return .{ .status = result.status, .body = response_body.toArrayList() };
    }
}

const rate_limit_retries = 3;
const rate_limit_delays_s = [rate_limit_retries]i64{ 5, 30, 60 };

fn retryAfterRateLimit(io: std.Io, url: []const u8, attempt_counter: u8) void {
    const delay_s = rate_limit_delays_s[attempt_counter];
    log.warn("GET {s} returned 429 Too Many Requests, retrying in {d} seconds...", .{ url, delay_s });
    io.sleep(.fromSeconds(delay_s), .awake) catch |err| switch (err) {
        error.Canceled => errExit("canceled while waiting to retry GET {s}", .{url}),
    };
}

fn fetchErrExit(url: []const u8, result: FetchResult) noreturn {
    if (result.body.items.len > 0) {
        const dashes = "----------------------------------------";
        log.err("GET {s} returned status {d} and the following {d}-byte response:\n" ++ dashes ++ "\n{s}\n" ++ dashes, .{ url, @intFromEnum(result.status), result.body.items.len, result.body.items });
    } else {
        log.err("GET {s} returned status {d} with no response body", .{ url, @intFromEnum(result.status) });
    }
    std.process.exit(0xff);
}

const ParseJsonError = struct {
    at: usize,
    why: Why,
    const Why = union(enum) {
        unexpected_token: struct { expected: [:0]const u8, got: json.Token.Tag },
        invalid_value,
        invalid_git_sha: []const u8,
        missing_field: [:0]const u8,
    };

    pub fn set(err: *ParseJsonError, at: usize, why: Why) error{ParseJson} {
        err.* = .{ .at = at, .why = why };
        return error.ParseJson;
    }

    pub fn fmt(err: *const ParseJsonError, text: []const u8) Fmt {
        return .{ .err = err, .text = text };
    }
    pub const Fmt = struct {
        err: *const ParseJsonError,
        text: []const u8,
        pub fn format(f: Fmt, writer: *std.Io.Writer) error{WriteFailed}!void {
            const lc = getLineCol(f.text, f.err.at);
            try writer.print("{d}:{d}: ", .{ lc[0], lc[1] });
            switch (f.err.why) {
                .unexpected_token => |u| try writer.print("expected {s}, got {s}", .{ u.expected, u.got.desc() }),
                .invalid_value => try writer.writeAll("invalid JSON value"),
                .invalid_git_sha => |s| try writer.print("invalid git sha: \"{s}\"", .{s}),
                .missing_field => |name| try writer.print("missing required field \"{s}\"", .{name}),
            }
        }
    };
};

fn getLineCol(text: []const u8, offset: usize) struct { usize, usize } {
    std.debug.assert(offset <= text.len);
    var line: usize = 1;
    var col: usize = 1;
    for (text[0..offset]) |char| switch (char) {
        '\n' => {
            line += 1;
            col = 1;
        },
        else => col += 1,
    };
    return .{ line, col };
}

fn jsonErrorExit(
    scratch: *Scratch,
    ctx: *const ProcessEnv,
    url: []const u8,
    json_content: []const u8,
    err: *const ParseJsonError,
) noreturn {
    reportJsonError(scratch, ctx, url, json_content, err);
    std.process.exit(0xff);
}

fn reportJsonError(
    scratch: *Scratch,
    ctx: *const ProcessEnv,
    url: []const u8,
    json_content: []const u8,
    err: *const ParseJsonError,
) void {
    const position = scratch.position();
    defer std.debug.assert(position == scratch.position());

    log.err("parse JSON from '{s}' failed", .{url});

    const url_path = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else url;
    const ext = ".json";
    const tmp_path = allocTmpPath(scratch.allocator(), ctx.tmp_dir, "hew-{s}{s}", .{ url_path, ext });
    defer scratch.freeLifo(tmp_path);

    const name_start = tmp_path.len - ext.len - url_path.len;
    for (tmp_path[name_start..]) |*c| {
        switch (c.*) {
            '/', '?' => c.* = '-',
            else => {},
        }
    }

    const saved = blk: {
        if (std.fs.path.dirname(tmp_path)) |dir| {
            std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch |create_dir_error| {
                log.warn(
                    "create dir '{s}' (to save JSON response) failed with {t}",
                    .{ dir, create_dir_error },
                );
                break :blk false;
            };
        }
        const f = std.Io.Dir.createFileAbsolute(ctx.io, tmp_path, .{}) catch |save_err| {
            log.warn("save JSON to '{s}' failed with {t}", .{ tmp_path, save_err });
            break :blk false;
        };
        defer f.close(ctx.io);
        f.writeStreamingAll(ctx.io, json_content) catch |save_err| {
            log.warn("write JSON to '{s}' failed with {t}", .{ tmp_path, save_err });
            break :blk false;
        };
        break :blk true;
    };

    const file_path: []const u8 = if (saved) tmp_path else "";
    const file_sep: []const u8 = if (saved) ":" else "";
    var buffer: [200]u8 = undefined;
    const stderr = &std.debug.lockStderr(&buffer).file_writer.interface;
    defer std.debug.unlockStderr();
    stderr.print("{s}{s}{f}\n", .{ file_path, file_sep, err.fmt(json_content) }) catch @panic("print to stderr failed");
}

/// Parse the "message" field from a JSON object like {"message":"Not Found",...}
fn parseMessage(text: []const u8, err: *ParseJsonError) error{ParseJson}![]const u8 {
    var index = try parseJsonObjectStart(err, text, 0);
    var first_field = true;
    while (try parseJsonField(err, text, &first_field, &index)) |name| {
        if (std.mem.eql(u8, name, "message")) {
            const value, index = try parseJsonString(err, text, index);
            return value;
        }
        index = try scanJsonValue(err, text, index);
    }
    return err.set(0, .{ .missing_field = "message" });
}

fn parseJsonObjectStart(err: *ParseJsonError, text: []const u8, start: usize) error{ParseJson}!usize {
    const token = json.lex(text, start);
    if (token.tag != .@"{") return err.set(token.start, .{
        .unexpected_token = .{ .expected = "\"{\"", .got = token.tag },
    });
    return token.end;
}
fn parseJsonField(
    err: *ParseJsonError,
    text: []const u8,
    first_field_ref: *bool,
    index_ref: *usize,
) error{ParseJson}!?[]const u8 {
    const after_comma = blk: {
        if (first_field_ref.*) {
            const token = json.lex(text, index_ref.*);
            if (token.tag == .@"}") {
                index_ref.* = token.end;
                return null;
            }

            first_field_ref.* = false;
            break :blk index_ref.*;
        }
        const token = json.lex(text, index_ref.*);
        switch (token.tag) {
            .@"}" => {
                index_ref.* = token.end;
                return null;
            },
            .@"," => break :blk token.end,
            else => return err.set(token.start, .{ .unexpected_token = .{
                .expected = "\"}\" or another object field",
                .got = token.tag,
            } }),
        }
    };
    const key_token = json.lex(text, after_comma);
    if (key_token.tag != .string) return err.set(key_token.start, .{
        .unexpected_token = .{ .expected = "field key string", .got = key_token.tag },
    });
    const key = text[key_token.start + 1 .. key_token.end - 1];

    const colon = json.lex(text, key_token.end);
    if (colon.tag != .@":") return err.set(colon.start, .{
        .unexpected_token = .{ .expected = "\":\"", .got = colon.tag },
    });
    index_ref.* = colon.end;
    return key;
}

fn parseJsonArrayStart(err: *ParseJsonError, text: []const u8, start: usize) error{ParseJson}!usize {
    const token = json.lex(text, start);
    if (token.tag != .@"[") return err.set(token.start, .{
        .unexpected_token = .{ .expected = "\"[\"", .got = token.tag },
    });
    return token.end;
}
fn parseJsonArrayEndFirst(text: []const u8, index_ref: *usize) bool {
    const token = json.lex(text, index_ref.*);
    if (token.tag == .@"]") {
        index_ref.* = token.end;
        return true; // end of array
    }
    return false; // array is not ended
}
fn parseJsonArrayEnd(
    err: *ParseJsonError,
    text: []const u8,
    first_element_ref: *bool,
    index_ref: *usize,
) error{ParseJson}!bool {
    const token = json.lex(text, index_ref.*);
    if (first_element_ref.*) {
        if (token.tag == .@"]") {
            index_ref.* = token.end;
            return true; // end of array
        }
        first_element_ref.* = false;
        return false; // array is not ended
    }
    const end_of_array = switch (token.tag) {
        .@"]" => true,
        .@"," => false,
        else => return err.set(token.start, .{ .unexpected_token = .{
            .expected = "\"]\" or \",\" to end or delimit array elements",
            .got = token.tag,
        } }),
    };
    index_ref.* = token.end;
    return end_of_array;
}

fn parseJsonString(err: *ParseJsonError, text: []const u8, start: usize) error{ParseJson}!struct { []const u8, usize } {
    const token = json.lex(text, start);
    if (token.tag == .string) return .{ text[token.start + 1 .. token.end - 1], token.end };
    return err.set(token.start, .{ .unexpected_token = .{ .expected = "a string", .got = token.tag } });
}

fn scanJsonValue(err: *ParseJsonError, text: []const u8, start: usize) error{ParseJson}!usize {
    return json.skipValue(text, start) orelse return err.set(
        json.lex(text, start).start,
        .invalid_value,
    );
}

/// Parse the "name" field from the first element of a JSON array: [{"name":"tag",...},...]
/// Returns null if the array is empty (there are no tags).
fn parseLatestTag(text: []const u8, err: *ParseJsonError) error{ParseJson}!?[]const u8 {
    var index = try parseJsonArrayStart(err, text, 0);
    if (parseJsonArrayEndFirst(text, &index)) return null;

    const object_start_token = json.lex(text, index);
    index = try parseJsonObjectStart(err, text, object_start_token.start);
    var first_field: bool = true;
    while (try parseJsonField(err, text, &first_field, &index)) |name| {
        if (std.mem.eql(u8, name, "name")) {
            const value, index = try parseJsonString(err, text, index);
            return value;
        }
        index = try scanJsonValue(err, text, index);
    }

    return err.set(object_start_token.start, .{ .missing_field = "name" });
}


fn parseReleaseGithub(text: []const u8, err: *ParseJsonError) error{ParseJson}!Release {
    var index = try parseJsonObjectStart(err, text, 0);
    var first_field: bool = true;
    var tag_name: ?[]const u8 = null;
    var tarball_url: ?[]const u8 = null;
    while (try parseJsonField(err, text, &first_field, &index)) |name| {
        if (std.mem.eql(u8, name, "tag_name")) {
            tag_name, index = try parseJsonString(err, text, index);
        } else if (std.mem.eql(u8, name, "tarball_url")) {
            tarball_url, index = try parseJsonString(err, text, index);
        } else {
            index = try scanJsonValue(err, text, index);
        }
    }
    return .{
        .tag_name = tag_name orelse return err.set(0, .{ .missing_field = "tag_name" }),
        .tarball_url = tarball_url orelse return err.set(0, .{ .missing_field = "tarball_url" }),
    };
}

fn parseReleaseGitlab(text: []const u8, err: *ParseJsonError) error{ParseJson}!Release {
    var index = try parseJsonObjectStart(err, text, 0);
    var first_field: bool = true;

    var tag_name: ?[]const u8 = null;
    var tarball_url: ?[]const u8 = null;

    while (try parseJsonField(err, text, &first_field, &index)) |name| {
        if (std.mem.eql(u8, name, "tag_name")) {
            tag_name, index = try parseJsonString(err, text, index);
        } else if (std.mem.eql(u8, name, "assets")) {
            // walk assets object looking for "sources" array
            index = try parseJsonObjectStart(err, text, index);
            var first_assets_field: bool = true;
            while (try parseJsonField(err, text, &first_assets_field, &index)) |assets_field| {
                if (!std.mem.eql(u8, assets_field, "sources")) {
                    index = try scanJsonValue(err, text, index);
                    continue;
                }
                // walk sources array looking for the {format:"tar.gz"} element
                index = try parseJsonArrayStart(err, text, index);
                var first_source: bool = true;
                while (!try parseJsonArrayEnd(err, text, &first_source, &index)) {
                    index = try parseJsonObjectStart(err, text, index);
                    var first_source_field: bool = true;
                    var src_format: ?[]const u8 = null;
                    var src_url: ?[]const u8 = null;
                    while (try parseJsonField(err, text, &first_source_field, &index)) |sf| {
                        if (std.mem.eql(u8, sf, "format")) {
                            src_format, index = try parseJsonString(err, text, index);
                        } else if (std.mem.eql(u8, sf, "url")) {
                            src_url, index = try parseJsonString(err, text, index);
                        } else {
                            index = try scanJsonValue(err, text, index);
                        }
                    }
                    if (src_format) |f| if (std.mem.eql(u8, f, "tar.gz")) {
                        tarball_url = src_url;
                    };
                }
            }
        } else {
            index = try scanJsonValue(err, text, index);
        }
    }
    return .{
        .tag_name = tag_name orelse return err.set(0, .{ .missing_field = "tag_name" }),
        .tarball_url = tarball_url orelse return err.set(0, .{ .missing_field = "assets.sources[tar.gz]" }),
    };
}



fn parseSha(text: []const u8, err: *ParseJsonError, field_name: [:0]const u8) error{ParseJson}!GitSha {
    var index = try parseJsonObjectStart(err, text, 0);
    var first_field: bool = true;
    while (try parseJsonField(err, text, &first_field, &index)) |name| {
        if (std.mem.eql(u8, name, field_name)) {
            const value_first_token = json.lex(text, index);
            const hex, index = try parseJsonString(err, text, value_first_token.start);
            if (hex.len == 40) {
                if (GitSha.fromHex(hex[0..40])) |sha| return sha;
            }
            return err.set(value_first_token.start, .{ .invalid_git_sha = hex });
        }
        index = try scanJsonValue(err, text, index);
    }
    return err.set(0, .{ .missing_field = field_name });
}

fn downloadToCache(scratch: *Scratch, http: Http, url: []const u8, pkg_cache_path: []const u8) error{Reported}!void {
    const io = http.ctx.io;
    const lock_path = std.fmt.allocPrint(
        scratch.allocator(),
        "{s}.lock",
        .{pkg_cache_path},
    ) catch |e| oom(e);
    defer scratch.free(lock_path);

    var lock_file = LockFile.lock(io, lock_path) catch |err| return reportError(
        "lock '{s}' failed with {t}",
        .{ lock_path, err },
    );
    defer lock_file.unlock(io);

    const cached: bool = if (std.Io.Dir.accessAbsolute(io, pkg_cache_path, .{})) true else |err| switch (err) {
        error.FileNotFound => false,
        else => return reportError("access '{s}' failed with {t}", .{ pkg_cache_path, err }),
    };
    if (cached) {
        log.info("using cached {s}", .{pkg_cache_path});
    } else {
        log.info("downloading {s}...", .{url});
        const downloading_path = std.fmt.allocPrint(
            scratch.allocator(),
            "{s}.downloading",
            .{pkg_cache_path},
        ) catch |e| oom(e);
        defer scratch.free(downloading_path);

        errdefer std.Io.Dir.deleteFileAbsolute(io, downloading_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("clean up '{s}' failed with {t}", .{ downloading_path, err }),
        };
        {
            const download_file = std.Io.Dir.createFileAbsolute(io, downloading_path, .{}) catch |err| return reportError(
                "create '{s}' failed with {t}",
                .{ downloading_path, err },
            );
            var download_file_open = true;
            defer if (download_file_open) download_file.close(io);
            var download_buf: [4096]u8 = undefined;
            var file_writer = download_file.writer(io, &download_buf);
            var auth_buf: [github_auth_buf_len]u8 = undefined;
            const result = http.client.fetch(.{
                .location = .{ .url = url },
                .headers = .{
                    .user_agent = .{ .override = "hew/0.0.1" },
                    .authorization = gitAuthHeader(http.git_auth, &auth_buf, url),
                },
                .response_writer = &file_writer.interface,
            }) catch |err| switch (err) {
                error.WriteFailed => return reportError(
                    "write '{s}' failed with {t}",
                    .{ downloading_path, file_writer.err.? },
                ),
                else => errExit("download '{s}' failed with {t}", .{ url, err }),
            };
            file_writer.interface.flush() catch return reportError(
                "flush '{s}' failed with {t}",
                .{ downloading_path, file_writer.err.? },
            );
            if (result.status != .ok) {
                download_file.close(io);
                download_file_open = false;
                const body: ?[]const u8 = std.Io.Dir.cwd().readFileAlloc(
                    io,
                    downloading_path,
                    scratch.allocator(),
                    .limited(100 * 1024 * 1024),
                ) catch |err| blk: {
                    log.warn("failed to read error response file '{s}': {t}", .{ downloading_path, err });
                    break :blk null;
                };
                const dashes = "----------------------------------------";
                if (body) |b| {
                    log.err("GET {s} returned status {d} and the following {d}-byte response:\n" ++ dashes ++ "\n{s}\n" ++ dashes, .{ url, @intFromEnum(result.status), b.len, b });
                } else {
                    log.err("GET {s} returned status {d}", .{ url, @intFromEnum(result.status) });
                }
                std.process.exit(0xff);
            }
        }

        std.Io.Dir.renameAbsolute(downloading_path, pkg_cache_path, io) catch |err| return reportError(
            "rename '{s}' to '{s}' failed with {t}",
            .{ downloading_path, pkg_cache_path, err },
        );
        log.info("cached to {s}", .{pkg_cache_path});
    }
}

fn allocTmpPath(allocator: std.mem.Allocator, tmp_dir: []const u8, comptime sub_path_fmt: []const u8, sub_path_args: anytype) []u8 {
    return std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ sub_path_fmt, .{tmp_dir} ++ sub_path_args) catch |e| oom(e);
}

/// Returns the directory for temporary files with any trailing separators removed.
fn allocTmpDir(allocator: std.mem.Allocator, environ: std.process.Environ) []const u8 {
    const dir = if (builtin.os.tag == .windows)
        getEnv(allocator, environ, "TEMP") orelse getEnv(allocator, environ, "TMP") orelse "C:\\Windows\\Temp"
    else
        environ.getPosix("TMPDIR") orelse "/tmp";
    var len = dir.len;
    while (len > 0 and std.fs.path.isSep(dir[len - 1])) len -= 1;
    return dir[0..len];
}

/// Returns the value of the environment variable `name` as WTF-8, or null if it's
/// not set. On windows the value is converted into memory owned by `allocator`,
/// elsewhere it points into the environment block and nothing is allocated.
fn getEnv(allocator: std.mem.Allocator, environ: std.process.Environ, comptime name: []const u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return environ.getPosix(name);
    const value = environ.getWindows(std.unicode.wtf8ToWtf16LeStringLiteral(name)) orelse return null;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, value) catch |e| oom(e);
}

const path_env_sep: u8 = if (builtin.os.tag == .windows) ';' else ':';

fn allocPathEnv(allocator: std.mem.Allocator, environ: std.process.Environ) ?[]const u8 {
    return getEnv(allocator, environ, "PATH");
}

/// A stack allocator for temporary memory. Allocations are bumped out of a list
/// of chunks. position() saves a restore point and restorePosition() releases
/// everything allocated after it while retaining capacity. free only reclaims
/// the most recent allocation.
///
/// When the top chunk is full it's first grown in place, otherwise the stack
/// moves to the next chunk kept from before a rewind if it fits, otherwise a new
/// chunk at least twice the size of the top one is inserted after it. Chunks are
/// never returned to the backing allocator; the process exit frees them.
///
/// Positions are offsets into one continuous space: each chunk starts where the
/// previous chunk's capacity ends, so positions only increase as the stack grows.
const Scratch = struct {
    backing: std.mem.Allocator,
    /// The chunk the next allocation comes from, null until the first allocation.
    top: ?*Chunk = null,
    /// Offset of the end of the most recent allocation in top's data.
    end: usize = 0,

    const min_chunk_len = 64 * 1024;

    const Chunk = struct {
        prev: ?*Chunk,
        /// A chunk kept from before a rewind, reused if big enough.
        next: ?*Chunk,
        /// Position of the start of this chunk's data. Only valid for top and
        /// the chunks before it; set when the stack moves into a chunk.
        base: usize,
        /// Capacity of this chunk's data, which follows the header in memory.
        len: usize,

        fn data(chunk: *Chunk) [*]u8 {
            return @as([*]u8, @ptrCast(chunk)) + @sizeOf(Chunk);
        }

        /// The memory allocated from the backing allocator for this chunk.
        fn allocation(chunk: *Chunk) []align(@alignOf(Chunk)) u8 {
            return @as([*]align(@alignOf(Chunk)) u8, @ptrCast(chunk))[0 .. @sizeOf(Chunk) + chunk.len];
        }
    };

    pub fn init(backing: std.mem.Allocator) Scratch {
        return .{ .backing = backing };
    }

    pub fn allocator(scratch: *Scratch) std.mem.Allocator {
        return .{ .ptr = scratch, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = freeFn,
        } };
    }

    pub fn position(scratch: *const Scratch) usize {
        const top = scratch.top orelse return 0;
        return top.base + scratch.end;
    }

    pub fn restorePosition(scratch: *Scratch, p: usize) void {
        std.debug.assert(p <= scratch.position());
        var top = scratch.top orelse return;
        while (p < top.base) top = top.prev.?;
        scratch.top = top;
        scratch.end = p - top.base;
    }

    pub fn freeLifo(scratch: *Scratch, memory: anytype) void {
        const p = scratch.position();
        scratch.allocator().free(memory);
        std.debug.assert(p != scratch.position());
    }
    pub fn free(scratch: *Scratch, memory: anytype) void {
        scratch.allocator().free(memory);
    }

    /// Returns the offset of `memory` in top's data if it's the most recent allocation.
    fn lastAllocationOffset(scratch: *const Scratch, memory: []u8) ?usize {
        const top = scratch.top orelse return null;
        const data_addr = @intFromPtr(top.data());
        const addr = @intFromPtr(memory.ptr);
        if (addr < data_addr or addr + memory.len != data_addr + scratch.end) return null;
        return addr - data_addr;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const scratch: *Scratch = @ptrCast(@alignCast(ctx));
        if (scratch.top) |top| {
            if (bump(top, scratch.end, len, alignment)) |start| {
                scratch.end = start + len;
                return top.data() + start;
            }
            // Grow the top chunk in place.
            const grown_len = @max(scratch.end + len + alignment.toByteUnits(), top.len * 2);
            if (scratch.backing.resize(top.allocation(), @sizeOf(Chunk) + grown_len)) {
                top.len = grown_len;
                const start = bump(top, scratch.end, len, alignment).?;
                scratch.end = start + len;
                return top.data() + start;
            }
            // Reuse the next chunk kept from before a rewind.
            if (top.next) |next| {
                if (bump(next, 0, len, alignment)) |start| {
                    next.base = top.base + top.len;
                    scratch.top = next;
                    scratch.end = start + len;
                    return next.data() + start;
                }
            }
        }
        const chunk = scratch.insertChunk(len + alignment.toByteUnits()) orelse return null;
        const start = bump(chunk, 0, len, alignment).?;
        scratch.top = chunk;
        scratch.end = start + len;
        return chunk.data() + start;
    }

    /// Returns where an allocation would start in `chunk` if it fits after `end`.
    fn bump(chunk: *Chunk, end: usize, len: usize, alignment: std.mem.Alignment) ?usize {
        const data_addr = @intFromPtr(chunk.data());
        const start = alignment.forward(data_addr + end) - data_addr;
        if (start + len > chunk.len) return null;
        return start;
    }

    /// Allocates a chunk with room for at least `min_len` bytes and at least
    /// twice the size of top, and inserts it after top ahead of any kept chunks.
    fn insertChunk(scratch: *Scratch, min_len: usize) ?*Chunk {
        const prev = scratch.top;
        const prev_len = if (prev) |p| p.len else 0;
        const len = @max(min_len, min_chunk_len, prev_len * 2);
        const memory = scratch.backing.alignedAlloc(u8, .of(Chunk), @sizeOf(Chunk) + len) catch return null;
        const chunk: *Chunk = @ptrCast(memory.ptr);
        chunk.* = .{
            .prev = prev,
            .next = if (prev) |p| p.next else null,
            .base = if (prev) |p| p.base + p.len else 0,
            .len = len,
        };
        if (chunk.next) |next| next.prev = chunk;
        if (prev) |p| p.next = chunk;
        return chunk;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = alignment;
        _ = ret_addr;
        const scratch: *Scratch = @ptrCast(@alignCast(ctx));
        const offset = scratch.lastAllocationOffset(memory) orelse return new_len <= memory.len;
        if (offset + new_len > scratch.top.?.len) return false;
        scratch.end = offset + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const scratch: *Scratch = @ptrCast(@alignCast(ctx));
        if (scratch.lastAllocationOffset(memory)) |offset| scratch.end = offset;
    }
};

/// Sums the capacity of every chunk, including those kept past top.
fn testScratchCapacity(scratch: *const Scratch) usize {
    var first = scratch.top orelse return 0;
    while (first.prev) |p| first = p;
    var total: usize = 0;
    var it: ?*Scratch.Chunk = first;
    while (it) |c| : (it = c.next) total += c.len;
    return total;
}

test "Scratch rewinds across chunks and retains capacity" {
    var scratch: Scratch = .init(std.testing.allocator);
    defer {
        // Scratch never frees chunks, so free them here for the leak checker.
        if (scratch.top) |top| {
            var first = top;
            while (first.prev) |p| first = p;
            var it: ?*Scratch.Chunk = first;
            while (it) |c| {
                it = c.next;
                std.testing.allocator.free(c.allocation());
            }
        }
    }
    const a = scratch.allocator();

    try std.testing.expectEqual(0, scratch.position());
    const small = try a.alloc(u8, 10);
    try std.testing.expectEqual(10, scratch.position());

    // A LIFO free reclaims; a resize of the last allocation grows in place.
    scratch.freeLifo(small);
    try std.testing.expectEqual(0, scratch.position());
    var grow = try a.alloc(u8, 10);
    try std.testing.expect(a.resize(grow, 100));
    grow = grow.ptr[0..100];
    try std.testing.expectEqual(100, scratch.position());

    // Overflow the first chunk (grown in place or spilled into a new one), then
    // rewind to before it: positions rewind and capacity is retained.
    const saved = scratch.position();
    const big = try a.alloc(u8, Scratch.min_chunk_len * 3);
    @memset(big, 0xaa);
    try std.testing.expect(scratch.position() >= saved + big.len);
    const capacity = testScratchCapacity(&scratch);
    scratch.restorePosition(saved);
    try std.testing.expectEqual(saved, scratch.position());
    try std.testing.expectEqual(capacity, testScratchCapacity(&scratch));

    // Allocating the same amount again needs no new capacity.
    @memset(try a.alloc(u8, Scratch.min_chunk_len * 3), 0xbb);
    try std.testing.expectEqual(capacity, testScratchCapacity(&scratch));

    // Rewinding to the start keeps everything too.
    scratch.restorePosition(0);
    try std.testing.expectEqual(0, scratch.position());
    try std.testing.expectEqual(capacity, testScratchCapacity(&scratch));

    // Aligned allocations are aligned.
    const aligned = try a.alignedAlloc(u8, .@"64", 1);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(aligned.ptr), 64));
}

fn allocAppDataPath(allocator: std.mem.Allocator, environ: std.process.Environ) [:0]const u8 {
    switch (builtin.os.tag) {
        .macos => {
            const home_dir = environ.getPosix("HOME") orelse errExit("no HOME", .{});
            return std.fs.path.joinZ(
                allocator,
                &[_][]const u8{ home_dir, "Library", "Application Support", "hew" },
            ) catch |e| oom(e);
        },
        .linux, .freebsd, .netbsd, .dragonfly, .openbsd, .illumos, .serenity => {
            if (environ.getPosix("XDG_DATA_HOME")) |xdg| {
                if (xdg.len > 0) return std.fs.path.joinZ(allocator, &.{ xdg, "hew" }) catch |e| oom(e);
            }
            if (environ.getPosix("HOME")) |home| return std.fs.path.joinZ(
                allocator,
                &.{ home, ".local", "share", "hew" },
            ) catch |e| oom(e);
            errExit("no HOME nor XDG_DATA_HOME", .{});
        },
        .windows => {
            const app_data = getEnv(allocator, environ, "LOCALAPPDATA") orelse errExit("missing LOCALAPPDATA environment variable", .{});
            var trimmed = app_data.len;
            while (trimmed > 0 and std.fs.path.isSep(app_data[trimmed - 1])) {
                trimmed -= 1;
            }
            return std.mem.concatWithSentinel(
                allocator,
                u8,
                &.{ app_data[0..trimmed], "\\hew" },
                0,
            ) catch |e| oom(e);
        },
        else => |os| @compileError("unsupported os " ++ @tagName(os)),
    }
}

fn allocCachePath(allocator: std.mem.Allocator, environ: std.process.Environ, app_data_path: [:0]const u8) [:0]const u8 {
    if (builtin.os.tag == .windows) {
        return std.fs.path.joinZ(allocator, &.{ app_data_path, "cache", "p" }) catch |e| oom(e);
    }
    if (environ.getPosix("XDG_CACHE_HOME")) |xdg| {
        return std.fmt.allocPrintSentinel(allocator, "{s}/hew/p", .{xdg}, 0) catch |e| oom(e);
    }
    if (environ.getPosix("HOME")) |home| {
        return std.fmt.allocPrintSentinel(allocator, "{s}/.cache/hew/p", .{home}, 0) catch |e| oom(e);
    }
    errExit("neither XDG_CACHE_HOME nor HOME is set", .{});
}

fn allocBinPath(
    allocator: std.mem.Allocator,
    ctx: *const ProcessEnv,
    scratch: *Scratch,
    interactive: bool,
    app_data_path: []const u8,
) ![:0]const u8 {
    const scratch_pos = scratch.position();
    defer std.debug.assert(scratch_pos == scratch.position());

    var bin_setting_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bin_setting_path = std.fmt.bufPrint(
        &bin_setting_path_buf,
        "{s}{c}{s}",
        .{ app_data_path, std.fs.path.sep, "binpath" },
    ) catch @panic("app data path too long");

    var bin_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (try readBinPath(ctx.io, bin_setting_path, &bin_path_buf)) |stored|
        return allocator.dupeSentinel(u8, stored, 0) catch |e| oom(e);

    if (!interactive) errExit("install bin path is not configured and --non-interactive has been set", .{});

    const path_env = allocPathEnv(allocator, ctx.environ) orelse errExit("no valid install directory (PATH is empty)", .{});

    const path_env_count = blk: {
        var count: usize = 0;
        var it = std.mem.tokenizeScalar(u8, path_env, path_env_sep);
        while (it.next()) |_| {
            count += 1;
        }
        break :blk count;
    };

    if (path_env_count == 0) errExit("no valid install directory (PATH is empty)", .{});

    var entries: std.ArrayList([]const u8) = .empty;
    defer {
        var it = std.mem.reverseIterator(entries.items);
        while (it.next()) |entry| {
            scratch.freeLifo(entry);
        }
        entries.deinit(scratch.allocator());
    }
    try entries.ensureTotalCapacity(scratch.allocator(), path_env_count);

    var stderr_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(ctx.io, &stderr_buf);
    const w = &stderr.interface;

    w.print("checking PATH for potential install directories...\n", .{}) catch return stderr.err.?;

    {
        var it = std.mem.tokenizeScalar(u8, path_env, path_env_sep);
        while (it.next()) |entry| {
            const expanded = try pathenv.expand(scratch.allocator(), ctx.environ, entry);
            var expanded_owned = true;
            defer if (expanded_owned) scratch.allocator().free(expanded);

            const is_duplicate = blk: {
                for (entries.items) |existing| {
                    if (std.mem.eql(u8, existing, expanded)) break :blk true;
                }
                break :blk false;
            };
            if (is_duplicate) continue;

            switch (try checkBinPath(ctx.io, expanded)) {
                .ok => {
                    entries.appendAssumeCapacity(expanded);
                    expanded_owned = false;
                },
                .bad => |reason| w.print("ignoring '{s}'{f} ({t})\n", .{
                    expanded, fmtExpanded(entry, expanded), reason,
                }) catch return stderr.err.?,
            }
        }
    }

    if (entries.items.len == 0) errExit("none of the directories in PATH can be used to install hew cli tools.  Add one and try again.", .{});

    w.writeAll("0: [cancel]\n") catch return stderr.err.?;
    for (entries.items, 0..) |entry, i| {
        w.print("{d}: {s}\n", .{ i + 1, entry }) catch return stderr.err.?;
    }
    const selection = promptNumber(
        ctx.io,
        &stderr.interface,
        "Where should hew install cli tools?",
        entries.items.len,
    ) catch |err| switch (err) {
        error.WriteFailed => return stderr.err.?,
        else => |e| return e,
    };
    if (selection == 0) errExit("user cancelled", .{});
    const selected_path = entries.items[selection - 1];

    try writeBinPath(ctx.io, bin_setting_path, selected_path);

    {
        // Read it back to verify.
        var verify_buf: [std.fs.max_path_bytes]u8 = undefined;
        const readback = (try readBinPath(ctx.io, bin_setting_path, &verify_buf)) orelse
            return reportError("verification failed: bin setting file '{s}' not found after writing", .{bin_setting_path});
        if (!std.mem.eql(u8, readback, selected_path))
            return reportError("verification failed: wrote '{s}' but read back '{s}'", .{ selected_path, readback });
    }

    return allocator.dupeSentinel(u8, selected_path, 0) catch |e| oom(e);
}

fn readBinPath(io: std.Io, bin_setting_path: []const u8, buf: *[std.fs.max_path_bytes]u8) error{Reported}!?[:0]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, bin_setting_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return reportError("open '{s}' failed with {t}", .{ bin_setting_path, e }),
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const len = reader.interface.readSliceShort(buf) catch return reportError(
        "read '{s}' failed with {t}",
        .{ bin_setting_path, reader.err.? },
    );
    if (len == 0) return reportError("bin setting file '{s}' is empty", .{bin_setting_path});
    if (len >= buf.len) return reportError("bin path in '{s}' is too long", .{bin_setting_path});
    buf[len] = 0;
    const stored = buf[0..len :0];
    if (!isBinPathNormalized(stored))
        return reportError("stored bin path '{s}' in '{s}' contains forward slashes", .{ stored, bin_setting_path });
    return stored;
}

fn writeBinPath(io: std.Io, bin_setting_path: []const u8, bin_path: []const u8) error{Reported}!void {
    if (std.fs.path.dirname(bin_setting_path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch |e| return reportError(
        "make path '{s}' failed with {t}",
        .{ d, e },
    );
    // TODO: should we write it to a temp file first and then rename?
    const file = std.Io.Dir.createFileAbsolute(io, bin_setting_path, .{}) catch |e| return reportError(
        "create '{s}' failed with {t}",
        .{ bin_setting_path, e },
    );
    defer file.close(io);
    file.writeStreamingAll(io, bin_path) catch |e| return reportError(
        "write {} bytes '{s}' to '{s}' failed with {t}",
        .{ bin_path.len, bin_path, bin_setting_path, e },
    );
}

fn fmtExpanded(original: []const u8, expanded: []const u8) FmtExpanded {
    return FmtExpanded{ .original = original, .expanded = expanded };
}
const FmtExpanded = struct {
    original: []const u8,
    expanded: []const u8,
    pub fn format(f: FmtExpanded, writer: *std.Io.Writer) error{WriteFailed}!void {
        if (std.mem.eql(u8, f.original, f.expanded)) return;
        try writer.print(" (expanded from '{s}')", .{f.original});
    }
};

fn promptYesNo(io: std.Io, w: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !bool {
    var read_buf: [100]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &read_buf);
    try w.print(fmt ++ " [y/n]: ", args);
    try w.flush();
    while (true) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => errExit("input too long", .{}),
        } orelse errExit("unexpected end of stdin", .{});
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "Y")) return true;
        if (std.mem.eql(u8, trimmed, "n") or std.mem.eql(u8, trimmed, "N")) return false;
        try w.print("please enter 'y' or 'n': ", .{});
        try w.flush();
    }
}

fn promptNumber(io: std.Io, w: *std.Io.Writer, str: []const u8, max: usize) !usize {
    var read_buf: [100]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &read_buf);
    while (true) {
        try w.print("{s} [0-{d}]: ", .{ str, max });
        try w.flush();

        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => errExit("input too long", .{}),
        } orelse errExit("unexpected end of stdin", .{});
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (std.fmt.parseInt(usize, trimmed, 10)) |i| {
            if (i <= max) return i;
        } else |_| {}
        try w.print("\nerror: invalid response '{f}'\n", .{std.zig.fmtString(trimmed)});
    }
}

const BadBinPath = enum {
    @"not an absolute path",
    @"open dir access denied",
    @"open dir permission denied",
    @"read only file system",
    @"not found",
    @"not a directory",
    @"symlink loop",
    @"bad path name",
    @"write file access denied",
    @"write file permission denied",
};
const BinPath = union(enum) {
    ok,
    bad: BadBinPath,
};
fn checkBinPath(io: std.Io, path: []const u8) error{Reported}!BinPath {
    if (!std.fs.path.isAbsolute(path)) return .{ .bad = .@"not an absolute path" };
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch |err| return switch (err) {
        error.AccessDenied => .{ .bad = .@"open dir access denied" },
        error.PermissionDenied => .{ .bad = .@"open dir permission denied" },
        error.NotDir => .{ .bad = .@"not a directory" },
        error.SymLinkLoop => .{ .bad = .@"symlink loop" },
        error.BadPathName => .{ .bad = .@"bad path name" },
        error.FileNotFound => .{ .bad = .@"not found" },
        else => |e| return reportError("open dir '{s}' failed with {t}", .{ path, e }),
    };
    defer dir.close(io);

    var test_name_buf: [64]u8 = undefined;
    const test_name = std.fmt.bufPrint(&test_name_buf, "hew-bin-test-{d}", .{LockFile.getPid()}) catch unreachable;
    const test_file = dir.createFile(io, test_name, .{ .permissions = .executable_file }) catch |err| return switch (err) {
        error.AccessDenied => .{ .bad = .@"write file access denied" },
        error.PermissionDenied => .{ .bad = .@"write file permission denied" },
        // workaround issue on macos, fix at codeberg pull #31615
        error.Unexpected => if (builtin.os.tag == .macos) {
            std.log.warn("workaround macos not handling errno 30 EROFS", .{});
            return .{ .bad = .@"read only file system" };
        } else return reportError("create bin test file in '{s}' failed with unexpected error", .{path}),
        else => |e| return reportError("create bin test file in '{s}' failed with {t}", .{ path, e }),
    };
    test_file.close(io);
    dir.deleteFile(io, test_name) catch |e| return reportError("delete bin test file '{s}' failed with {t}", .{ path, e });
    return .ok;
}

const Timer = struct {
    io: std.Io,
    start: std.Io.Timestamp,

    fn init(io: std.Io) Timer {
        return .{ .io = io, .start = .now(io, .awake) };
    }

    fn seconds(t: Timer) f64 {
        const ns = t.start.untilNow(t.io, .awake).toNanoseconds();
        return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
    }
};

fn reportError(comptime fmt: []const u8, args: anytype) error{Reported} {
    log.err(fmt, args);
    return error.Reported;
}
fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(0xff);
}
fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

comptime {
    _ = @import("pathenv.zig");
    _ = @import("pkg.zig");
}

const log = std.log.scoped(.hew);

pub const std_options: std.Options = .{
    // Dispatch std.Io statically to std.Io.Threaded (see zig-staticio in build.zig).
    .io_vtable = .threaded,
    // wintrace reports crashes on windows instead of std, keeping std's stack
    // tracing (and its PDB reader) out of release builds.
    .enable_segfault_handler = if (builtin.os.tag == .windows) false else std.debug.default_enable_segfault_handler,
    .allow_stack_tracing = if (builtin.os.tag == .windows) builtin.mode == .debug else !builtin.strip_debug_info,
};

const builtin = @import("builtin");
const std = @import("std");
const json = @import("json.zig");
const pathenv = @import("pathenv.zig");
const which = @import("which.zig");
const wintrace = @import("wintrace");
const GitSha = @import("GitSha.zig");
const LockFile = @import("LockFile.zig");
const Pkg = @import("pkg.zig").Pkg;
const PkgGit = @import("pkg.zig").PkgGit;
const isSafeRev = @import("pkg.zig").isSafeRev;
const Sha256 = std.crypto.hash.sha2.Sha256;
