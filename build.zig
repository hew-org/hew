pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // This option exists to workaround zig issue #21525
    //     "Associate lazy dependencies with steps and only fetch them if those steps are built"
    const ci_option = b.option(bool, "ci", "Enable the CI build step") orelse false;

    const release_version = try makeCalVersion(b.graph.io);
    const dev_version = b.fmt("{s}-dev", .{release_version});
    const write_files_version = b.addWriteFiles();
    const release_version_file = write_files_version.add("version-release", &release_version);
    const release_version_embed = b.createModule(.{
        .root_source_file = release_version_file,
    });
    const dev_version_embed = b.createModule(.{
        .root_source_file = write_files_version.add("version-dev", dev_version),
    });

    const patched_std = b.dependency("patch", .{
        .std_patches = &[_]std.Build.LazyPath{
            b.dependency("staticio", .{}).namedLazyPath("std.patch"),
            b.path("src/std-path-space.patch"),
        },
    }).module("std");

    const hew_exe = addHewExe(b, patched_std, .{
        .target = target,
        .optimize = optimize,
        .version = if (b.graph.environ_map.get("HEW_BUILD_REVISION")) |r| b.createModule(.{
            .root_source_file = write_files_version.add("version-release-native", b.fmt("{s}-native", .{r})),
        }) else dev_version_embed,
    });
    const install_hew_exe = b.addInstallArtifact(hew_exe, .{});
    b.getInstallStep().dependOn(&install_hew_exe.step);

    {
        const run = b.addRunArtifact(hew_exe);
        run.step.dependOn(&install_hew_exe.step);
        run.addPassthruArgs();
        b.step("run", "").dependOn(&run.step);
    }

    const test_step = b.step("test", "");

    {
        const exe = b.addTest(.{
            .root_module = hew_exe.root_module,
        });
        const run = b.addRunArtifact(exe);
        test_step.dependOn(&run.step);
    }

    test_step.dependOn(addWinCodeNamesCheck(b, patched_std, dev_version_embed));

    {
        const test_app_data = rootPath(b, "test", "appdata");
        const test_bin_path = rootPath(b, "test", "bin");
        // The configure phase is cached so it can't create the bin dir; writing
        // a file into it during the make phase creates it.
        const make_test_bin = b.addUpdateSourceFiles();
        make_test_bin.addBytesToSource("", "test/bin/.keep");
        const configure_bin = b.addRunArtifact(hew_exe);
        configure_bin.step.dependOn(&make_test_bin.step);
        configure_bin.addArgs(&.{
            "new-bin-path",
            "--app-data",
            test_app_data,
            test_bin_path,
        });
        addPathDir(b, configure_bin, test_bin_path);

        const pkgs_txt_path = rootPath(b, "test", "pkgs.txt");
        b.dependOnFileContents(b.path("test/pkgs.txt"));
        const pkgs_txt = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, pkgs_txt_path, b.allocator, .limited(1024 * 100));
        var line_it = std.mem.tokenizeScalar(u8, pkgs_txt, '\n');
        var lineno: u32 = 0;
        while (line_it.next()) |line| {
            lineno += 1;
            if (std.mem.startsWith(u8, line, "#")) continue;
            const parsed = parsePkgsLine(pkgs_txt_path, lineno, line);
            if (parsed.skip) continue;
            const test_name = b.fmt("test-{f}", .{fmtTestName(parsed.pkg)});
            const test_pkg_step = addTestPkg(
                b,
                hew_exe,
                &install_hew_exe.step,
                test_app_data,
                test_bin_path,
                &configure_bin.step,
                parsed.pkg_str,
                test_name,
            );
            b.step(
                test_name,
                b.fmt("test hew pkg {s}", .{parsed.pkg_str}),
            ).dependOn(test_pkg_step);
            test_step.dependOn(test_pkg_step);
        }
    }

    const ci_step = b.step("ci", "The build/test step to run on the CI");
    ci_step.dependOn(b.getInstallStep());
    ci_step.dependOn(test_step);
    ci_step.dependOn(&b.addInstallFile(release_version_file, "version-release").step);
    try ci(b, ci_option, patched_std, release_version_embed, ci_step);
}

fn addTestPkg(
    b: *std.Build,
    hew_exe: *std.Build.Step.Compile,
    install_hew_exe: *std.Build.Step,
    test_app_data: []const u8,
    test_bin_path: []const u8,
    configure_bin: *std.Build.Step,
    pkg_str: []const u8,
    test_name: []const u8,
) *std.Build.Step {
    const run = b.addRunArtifact(hew_exe);
    run.step.dependOn(install_hew_exe);
    run.step.dependOn(configure_bin);
    run.step.name = test_name;
    addPathDir(b, run, test_bin_path);
    run.addArgs(&.{
        "install",
        "--non-interactive",
        "--keep-archives",
        "--allow-shadow",
        "--app-data",
        test_app_data,
        pkg_str,
    });
    run.expectExitCode(0);
    return &run.step;
}

fn fmtTestName(pkg: Pkg) FmtTestName {
    return FmtTestName{ .pkg = pkg };
}
const FmtTestName = struct {
    pkg: Pkg,
    pub fn format(f: FmtTestName, w: *std.Io.Writer) error{WriteFailed}!void {
        switch (f.pkg) {
            .git => |g| try w.writeAll(g.repo()),
            .path => @panic("path packages not supported"),
        }
    }
};

const PkgsLine = struct {
    pkg: Pkg,
    pkg_str: []const u8,
    skip: bool,
};

fn parsePkgsLine(pkgs_txt_path: []const u8, lineno: u32, line: []const u8) PkgsLine {
    const pkg_end = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    const pkg_str = line[0..pkg_end];
    const pkg = switch (Pkg.parse(pkg_str)) {
        .ok => |p| p,
        .err => |e| std.debug.panic("{s}:{d} invalid package '{s}': {f}", .{ pkgs_txt_path, lineno, pkg_str, e }),
    };

    var skip = false;
    var opts = std.mem.tokenizeScalar(u8, line[pkg_end..], ' ');
    while (opts.next()) |opt| {
        if (std.mem.eql(u8, opt, "--disable-windows")) {
            if (builtin.os.tag == .windows) skip = true;
        } else if (std.mem.eql(u8, opt, "--disable-macos")) {
            if (builtin.os.tag == .macos) skip = true;
        } else if (std.mem.eql(u8, opt, "--disable-linux")) {
            if (builtin.os.tag == .linux) skip = true;
        } else {
            std.debug.panic("{s}:{d} unknown option '{s}'", .{ pkgs_txt_path, lineno, opt });
        }
    }

    return .{ .pkg = pkg, .pkg_str = pkg_str, .skip = skip };
}

fn ci(
    b: *std.Build,
    ci_option: bool,
    patched_std: *std.Build.Module,
    release_version_embed: *std.Build.Module,
    ci_step: *std.Build.Step,
) !void {
    const maybe_zip_exe: ?*std.Build.Step.Compile = blk: {
        if (!ci_option) break :blk null;
        const zipcmdline = b.lazyDependency("zipcmdline", .{
            .target = b.graph.host,
            .optimize = .Debug,
        }) orelse break :blk null;
        break :blk zipcmdline.artifact("zip");
    };

    const ci_targets = [_][]const u8{
        "aarch64-linux",
        "aarch64-macos",
        "aarch64-windows",
        "arm-linux",
        "powerpc64le-linux",
        "riscv64-linux",
        "s390x-linux",
        "x86-linux",
        "x86-windows",
        "x86_64-linux",
        "x86_64-macos",
        "x86_64-windows",
    };

    const make_archive_step = b.step("archive", "Create CI archives");
    if (builtin.os.tag == .linux and builtin.cpu.arch == .x86_64) {
        ci_step.dependOn(make_archive_step);
    }

    for (ci_targets) |ci_target_str| {
        const target = b.resolveTargetQuery(try std.Target.Query.parse(
            .{ .arch_os_abi = ci_target_str },
        ));
        const optimize: std.builtin.OptimizeMode = .ReleaseSmall;
        const target_dest_dir: std.Build.InstallDir = .{ .custom = ci_target_str };
        const install_exes = b.step(b.fmt("install-{s}", .{ci_target_str}), "");
        ci_step.dependOn(install_exes);
        const hew_exe = addHewExe(b, patched_std, .{
            .target = target,
            .optimize = optimize,
            // Unstripped, a windows exe has the PDB identity wintrace's traces
            // are matched to its PDB with (ReleaseSmall strips by default).
            .strip = if (target.result.os.tag == .windows) false else null,
            .version = release_version_embed,
        });
        install_exes.dependOn(
            &b.addInstallArtifact(hew_exe, .{
                .dest_dir = .{ .override = target_dest_dir },
            }).step,
        );
        // const target_test_step = b.step(b.fmt("test-{s}", .{ci_target_str}), "");
        // addTests(b, hew_exe, target_test_step);
        // const os_compatible = (builtin.os.tag == target.result.os.tag);
        // const arch_compatible = (builtin.cpu.arch == target.result.cpu.arch);
        // if (os_compatible and arch_compatible) {
        //     ci_step.dependOn(target_test_step);
        // }

        make_archive_step.dependOn(makeCiArchiveStep(
            b,
            maybe_zip_exe,
            ci_target_str,
            target.result,
            target_dest_dir,
            install_exes,
            // host_zip_exe,
        ));
    }
}

fn makeCiArchiveStep(
    b: *std.Build,
    maybe_zip_exe: ?*std.Build.Step.Compile,
    ci_target_str: []const u8,
    target: std.Target,
    target_install_dir: std.Build.InstallDir,
    install_exes: *std.Build.Step,
) *std.Build.Step {
    // The archive is created in the cache, then installed to the prefix.
    const target_install_path: std.Build.LazyPath = .{ .relative = .{
        .base = .install_prefix,
        .sub_path = target_install_dir.custom,
    } };

    if (target.os.tag == .windows) {
        const zip_exe = maybe_zip_exe orelse
            return &b.addFail("the ci step (more specifically the 'archive' step) requires the -Dci build option").step;
        const zip_name = b.fmt("hew-{s}.zip", .{ci_target_str});
        const zip = b.addRunArtifact(zip_exe);
        const out_zip_file = zip.addOutputFileArg(zip_name);
        zip.addArg("hew.exe");
        zip.addArg("hew.pdb");
        zip.cwd = target_install_path;
        zip.step.dependOn(install_exes);
        return &b.addInstallFile(out_zip_file, zip_name).step;
    }

    const targz_name = b.fmt("hew-{s}.tar.gz", .{ci_target_str});
    const tar = b.addSystemCommand(&.{ "tar", "-czf" });
    const targz = tar.addOutputFileArg(targz_name);
    tar.addArg("hew");
    tar.cwd = target_install_path;
    tar.step.dependOn(install_exes);
    return &b.addInstallFile(targz, targz_name).step;
}

fn makeCalVersion(io: std.Io) ![11]u8 {
    const now = std.time.epoch.EpochSeconds{ .secs = @intCast(std.Io.Clock.real.now(io).toSeconds()) };
    const day = now.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var buf: [11]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "v{d}_{d:0>2}_{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
    });
    std.debug.assert(formatted.len == buf.len);
    return buf;
}

const builtin = @import("builtin");
const std = @import("std");
const Pkg = @import("src/pkg.zig").Pkg;

const HewExeOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: ?bool = null,
    version: *std.Build.Module,
};

fn addHewExe(b: *std.Build, patched_std: *std.Build.Module, options: HewExeOptions) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("src/hew.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip,
        .single_threaded = true,
        .imports = &.{
            .{ .name = "std", .module = patched_std },
            .{ .name = "version", .module = options.version },
        },
    });
    // On windows wintrace reports hew's crashes (see panic and main in src/hew.zig).
    if (options.target.result.os.tag == .windows) {
        if (b.lazyDependency("wintrace", .{})) |dep| module.addImport("wintrace", dep.module("wintrace"));
    }
    return b.addExecutable(.{ .name = "hew", .root_module = module });
}

/// Checks hew's windows release builds never print a windows code as a tag name,
/// and that the check still detects one (see test/check_win_code_names.zig).
/// Cross-compiles, so it runs on any host.
fn addWinCodeNamesCheck(b: *std.Build, patched_std: *std.Build.Module, version: *std.Build.Module) *std.Build.Step {
    const step = b.step("check-win-code-names", "Check hew's windows release builds don't contain windows code names");
    const checker = b.addExecutable(.{
        .name = "check_win_code_names",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/check_win_code_names.zig"),
            .target = b.graph.host,
        }),
    });
    const windows = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows });

    const control = b.addExecutable(.{
        .name = "win_code_names_control",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/win_code_names_control.zig"),
            .target = windows,
            .optimize = .ReleaseSmall,
        }),
    });
    const check_control = b.addRunArtifact(checker);
    check_control.addArg("present");
    check_control.addFileArg(control.getEmittedBin());
    step.dependOn(&check_control.step);

    for ([_]std.builtin.OptimizeMode{ .ReleaseSmall, .ReleaseFast }) |optimize| {
        const exe = addHewExe(b, patched_std, .{ .target = windows, .optimize = optimize, .version = version });
        const check = b.addRunArtifact(checker);
        check.addArg("absent");
        check.addFileArg(exe.getEmittedBin());
        step.dependOn(&check.step);
    }
    return step;
}

/// Prepends `dir` to the PATH environment variable of `run`.
fn addPathDir(b: *std.Build, run: *std.Build.Step.Run, dir: []const u8) void {
    const sep = if (builtin.os.tag == .windows) ";" else ":";
    run.setEnvironmentVariable("PATH", if (b.graph.environ_map.get("PATH")) |path|
        b.fmt("{s}{s}{s}", .{ dir, sep, path })
    else
        dir);
}

/// Joins `dir` and `name` onto the build root with native path separators. hew
/// compares installed paths byte-for-byte with PATH entries derived from these.
fn rootPath(b: *std.Build, dir: []const u8, name: []const u8) []const u8 {
    const root = b.root.root_dir.path orelse @panic("build root has no path");
    return b.pathJoin(&.{ root, b.root.sub_path, dir, name });
}
