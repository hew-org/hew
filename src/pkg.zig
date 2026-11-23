pub const Pkg = union(enum) {
    git: PkgGit,
    path: []const u8,

    pub const ParseError = union(enum) {
        msg: []const u8,
        unknown_scheme: []const u8,
        unknown_option: []const u8,
        option_conflict: struct { []const u8, []const u8 },
        /// A removed `github:owner/repo` style scheme, has the host to use instead.
        host_scheme: []const u8,
        unknown_host: []const u8,
        /// A forge option for a host whose forge is known and the same.
        redundant_forge: struct { host: []const u8, forge: Forge },
        /// A forge option for a host whose forge is known and different.
        conflicting_forge: struct { host: []const u8, known: Forge, option: Forge },
        bad_path: struct { host: []const u8, forge: Forge, reason: []const u8 },
        /// A character that isn't allowed in a host, path or rev (see isHostChar and isNameChar).
        invalid_char: struct { what: []const u8, value: []const u8, char: u8 },
        uppercase_host: []const u8,
        /// `host:port`
        host_port: []const u8,
        pub fn format(e: ParseError, writer: *std.Io.Writer) error{WriteFailed}!void {
            switch (e) {
                .msg => |m| try writer.writeAll(m),
                .unknown_scheme => |s| try writer.print("unknown scheme '{s}:'", .{s}),
                .unknown_option => |o| try writer.print("unknown option '{s}'", .{o}),
                .option_conflict => |o| try writer.print("conflicting options '{s}' and '{s}'", .{ o[0], o[1] }),
                .host_scheme => |host| try writer.print("use '{s}/owner/repo' instead of '{s}:owner/repo'", .{
                    host, host[0..std.mem.indexOfScalar(u8, host, '.').?],
                }),
                .unknown_host => |host| try writer.print(
                    "unknown host '{s}', add its forge as an option: ',github', ',gitlab', ',forgejo' or ',srht'",
                    .{host},
                ),
                .redundant_forge => |r| try writer.print("remove the redundant ',{t}', '{s}' is always {t}", .{ r.forge, r.host, r.forge }),
                .conflicting_forge => |c| try writer.print("the forge of '{s}' is {t}, not {t}", .{ c.host, c.known, c.option }),
                .bad_path => |b| try writer.print("{s}, must be of the form '{s}/{s}[,options]'", .{
                    b.reason, b.host, switch (b.forge) {
                        .github, .forgejo => "owner/repo",
                        .gitlab => "group[/subgroup...]/repo",
                        .srht => "~owner/repo",
                    },
                }),
                .invalid_char => |i| try writer.print("invalid character {f} in {s} \"{f}\"", .{
                    fmtChar(i.char), i.what, std.zig.fmtString(i.value),
                }),
                .uppercase_host => |host| try writer.print("host '{s}' must be lowercase", .{host}),
                .host_port => |host| try writer.print("ports aren't supported, remove the ':' from '{s}'", .{host}),
            }
        }
    };
    pub const ParseResult = union(enum) { ok: Pkg, err: ParseError };

    pub fn parse(s: []const u8) ParseResult {
        for ([_][]const u8{ "https://", "http://" }) |url_scheme| {
            if (std.mem.startsWith(u8, s, url_scheme)) return .{ .err = .{
                .msg = "remove the 'https://' (or 'http://'), a package starts with its host, i.e. 'github.com/owner/repo'",
            } };
        }
        // A ':' before the first '/' is a scheme (path:PATH), otherwise the package
        // starts with its host (github.com/owner/repo).
        const scheme_end = std.mem.indexOfScalar(u8, s, ':') orelse return parseGit(s);
        if (std.mem.indexOfScalar(u8, s[0..scheme_end], '/') != null) return parseGit(s);
        const scheme = s[0..scheme_end];
        const value = s[scheme_end + 1 ..];

        // host:port[/...]
        const port = value[0 .. std.mem.indexOfScalar(u8, value, '/') orelse value.len];
        if (std.mem.indexOfScalar(u8, scheme, '.') != null and port.len > 0 and
            for (port) |c| {
                if (!std.ascii.isDigit(c)) break false;
            } else true)
            return .{ .err = .{ .host_port = s[0 .. scheme_end + 1 + port.len] } };

        for ([_][]const u8{ "github.com", "gitlab.com", "codeberg.org" }) |host| {
            if (std.mem.eql(u8, scheme, host[0..std.mem.indexOfScalar(u8, host, '.').?]))
                return .{ .err = .{ .host_scheme = host } };
        }
        if (std.mem.eql(u8, scheme, "path")) {
            if (value.len == 0) return .{ .err = .{ .msg = "path package must be in 'path:PATH' format" } };
            return .{ .ok = .{ .path = value } };
        }
        return .{ .err = .{ .unknown_scheme = scheme } };
    }

    /// Parses `HOST/path[/][,options]`.
    fn parseGit(s: []const u8) ParseResult {
        var iter = std.mem.splitScalar(u8, s, ',');
        const url = iter.first();
        const host_end = std.mem.indexOfScalar(u8, url, '/') orelse url.len;
        const host = url[0..host_end];
        for (host) |c| {
            if (std.ascii.isUpper(c)) return .{ .err = .{ .uppercase_host = host } };
            if (!isHostChar(c)) return .{ .err = .{ .invalid_char = .{ .what = "host", .value = host, .char = c } } };
        }
        if (std.mem.indexOfScalar(u8, host, '.') == null) return .{ .err = .{
            .msg = "expected a package of the form 'HOST/REPO_PATH', i.e. 'github.com/owner/repo'",
        } };

        var commit: PkgGit.Commit = .latest_release;
        var forge_option: ?Forge = null;
        while (iter.next()) |option| {
            if (std.mem.eql(u8, option, "tip")) {
                if (commit != .latest_release) return .{ .err = .{ .option_conflict = .{ "tip", @tagName(commit) } } };
                commit = .tip;
            } else if (std.mem.startsWith(u8, option, "rev=")) {
                if (commit != .latest_release) return .{ .err = .{ .option_conflict = .{ "rev", @tagName(commit) } } };
                const rev = option["rev=".len..];
                if (rev.len == 0) return .{ .err = .{ .msg = "rev= requires a rev name" } };
                for (rev) |c| {
                    if (!isNameChar(c)) return .{ .err = .{ .invalid_char = .{ .what = "rev", .value = rev, .char = c } } };
                }
                if (isDotName(rev)) return .{ .err = .{ .msg = "rev can't be '.' or '..'" } };
                commit = .{ .rev = rev };
            } else if (std.meta.stringToEnum(Forge, option)) |forge| {
                if (forge_option) |k| return .{ .err = .{ .option_conflict = .{ @tagName(k), option } } };
                forge_option = forge;
            } else return .{ .err = .{ .unknown_option = option } };
        }

        const forge: Forge = if (forgeOf(host)) |known| blk: {
            if (forge_option) |option| return .{ .err = if (option == known)
                .{ .redundant_forge = .{ .host = host, .forge = option } }
            else
                .{ .conflicting_forge = .{ .host = host, .known = known, .option = option } } };
            break :blk known;
        } else forge_option orelse return .{ .err = .{ .unknown_host = host } };

        const path = blk: {
            if (host_end == url.len) break :blk "";
            const path = url[host_end + 1 ..];
            break :blk if (std.mem.endsWith(u8, path, "/")) path[0 .. path.len - 1] else path;
        };
        if (std.mem.indexOfAny(u8, path, "?#") != null) return badPath(host, forge, "unexpected query or fragment");
        if (std.mem.endsWith(u8, path, ".git")) return badPath(host, forge, "unexpected '.git' suffix");
        // sourcehut owners start with '~', which is the only place it's allowed
        const check_start: usize = if (forge == .srht) blk: {
            if (!std.mem.startsWith(u8, path, "~")) return badPath(host, forge, "missing '~' before the owner");
            break :blk 1;
        } else 0;
        for (path[check_start..]) |c| {
            if (c != '/' and !isNameChar(c)) return .{ .err = .{ .invalid_char = .{ .what = "path", .value = path, .char = c } } };
        }
        var segment_count: usize = 0;
        var segment_it = std.mem.splitScalar(u8, path, '/');
        while (segment_it.next()) |segment| : (segment_count += 1) {
            if (segment.len == 0 or (forge == .srht and segment_count == 0 and segment.len == 1))
                return badPath(host, forge, if (path.len == 0) "missing path" else "empty path segment");
            if (isDotName(segment)) return badPath(host, forge, "unexpected '.' or '..' path segment");
        }
        switch (forge) {
            .github, .forgejo, .srht => if (segment_count != 2) return badPath(
                host,
                forge,
                if (segment_count < 2) "missing owner/repo" else "unexpected path after owner/repo",
            ),
            .gitlab => if (segment_count < 2) return badPath(host, forge, "missing group/repo"),
        }
        return .{ .ok = .{ .git = .{ .host = host, .forge = forge, .path = path, .commit = commit } } };
    }

    fn badPath(host: []const u8, forge: Forge, reason: []const u8) ParseResult {
        return .{ .err = .{ .bad_path = .{ .host = host, .forge = forge, .reason = reason } } };
    }

    fn fmtChar(c: u8) FmtChar {
        return .{ .c = c };
    }
    const FmtChar = struct {
        c: u8,
        pub fn format(f: FmtChar, writer: *std.Io.Writer) error{WriteFailed}!void {
            if (std.ascii.isPrint(f.c) and f.c != ' ') try writer.print("'{c}'", .{f.c}) else try writer.print("0x{x:0>2}", .{f.c});
        }
    };

    pub fn format(pkg: Pkg, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (pkg) {
            .git => |*g| try g.format(writer),
            .path => |p| try writer.print("path:{s}", .{p}),
        }
    }
};

/// The software a git host runs, which determines its API.
pub const Forge = enum {
    github,
    gitlab,
    /// Forgejo and Gitea, which share an API
    forgejo,
    /// sourcehut, which has no releases
    srht,
};

/// Hosts whose forge is known, packages on other hosts specify it as an option.
pub const known_hosts = [_]struct { host: []const u8, forge: Forge }{
    .{ .host = "github.com", .forge = .github },
    .{ .host = "gitlab.com", .forge = .gitlab },
    .{ .host = "codeberg.org", .forge = .forgejo },
    .{ .host = "git.sr.ht", .forge = .srht },
};

/// Hosts are limited to these characters. Uppercase is rejected so each host has
/// one spelling, it's part of the package's file names.
fn isHostChar(c: u8) bool {
    return std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '.' or c == '-';
}

/// Path segments and revs are limited to these characters since they're used in
/// URLs and file names. '+' is excluded, it separates the parts of file names.
fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
}

fn isDotName(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

/// Whether a rev name (i.e. a tag name from a forge) is safe to use in URLs and file names.
pub fn isSafeRev(name: []const u8) bool {
    if (name.len == 0 or isDotName(name)) return false;
    for (name) |c| {
        if (!isNameChar(c)) return false;
    }
    return true;
}

pub fn forgeOf(host: []const u8) ?Forge {
    for (known_hosts) |known| {
        if (std.mem.eql(u8, host, known.host)) return known.forge;
    }
    return null;
}

pub const PkgGit = struct {
    host: []const u8,
    forge: Forge,
    /// owner/repo, group[/subgroup...]/repo for gitlab or ~owner/repo for sourcehut
    path: []const u8,
    commit: Commit,

    pub const Commit = union(enum) {
        latest_release,
        rev: []const u8,
        tip,
    };

    pub fn repo(p: *const PkgGit) []const u8 {
        return p.path[std.mem.lastIndexOfScalar(u8, p.path, '/').? + 1 ..];
    }

    pub fn format(pkg: PkgGit, writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.print("{s}/{s}", .{ pkg.host, pkg.path });
        if (forgeOf(pkg.host) == null) try writer.print(",{t}", .{pkg.forge});
    }

    /// A name for the package's files (manifests, archives), unique per host and path:
    /// the host and each path segment separated by '+', which none of them can contain.
    pub fn fmtFileName(pkg: *const PkgGit) FmtFileName {
        return .{ .pkg = pkg };
    }
    pub const FmtFileName = struct {
        pkg: *const PkgGit,
        pub fn format(f: FmtFileName, writer: *std.Io.Writer) error{WriteFailed}!void {
            try writer.print("{s}+", .{f.pkg.host});
            for (f.pkg.path) |c| try writer.writeByte(if (c == '/') '+' else c);
        }
    };
};

fn expectGit(s: []const u8, host: []const u8, forge: Forge, path: []const u8, commit: PkgGit.Commit) !void {
    const pkg = switch (Pkg.parse(s)) {
        .ok => |p| p,
        .err => |e| {
            std.debug.print("parse '{s}' failed: {f}\n", .{ s, e });
            return error.TestUnexpectedResult;
        },
    };
    try std.testing.expectEqualStrings(host, pkg.git.host);
    try std.testing.expectEqual(forge, pkg.git.forge);
    try std.testing.expectEqualStrings(path, pkg.git.path);
    switch (commit) {
        .latest_release, .tip => try std.testing.expectEqual(std.meta.activeTag(commit), std.meta.activeTag(pkg.git.commit)),
        .rev => |rev| try std.testing.expectEqualStrings(rev, pkg.git.commit.rev),
    }
}

fn expectErr(s: []const u8, expected: []const u8) !void {
    switch (Pkg.parse(s)) {
        .ok => {
            std.debug.print("parse '{s}' should have failed\n", .{s});
            return error.TestUnexpectedResult;
        },
        .err => |e| {
            var buf: [200]u8 = undefined;
            try std.testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buf, "{f}", .{e}));
        },
    }
}

fn expectFormat(s: []const u8, expected: []const u8, expected_file_name: []const u8) !void {
    const pkg = Pkg.parse(s).ok;
    var buf: [100]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try std.fmt.bufPrint(&buf, "{f}", .{pkg}));
    try std.testing.expectEqualStrings(expected_file_name, try std.fmt.bufPrint(&buf, "{f}", .{pkg.git.fmtFileName()}));
}

test "known host packages" {
    try expectGit("github.com/marler8997/msi", "github.com", .github, "marler8997/msi", .latest_release);
    try expectGit("github.com/marler8997/msi/", "github.com", .github, "marler8997/msi", .latest_release);
    try expectGit("gitlab.com/dasimmet/zig-container", "gitlab.com", .gitlab, "dasimmet/zig-container", .latest_release);
    try expectGit("gitlab.com/group/sub/repo", "gitlab.com", .gitlab, "group/sub/repo", .latest_release);
    try expectGit("codeberg.org/marler/hew-test-tag", "codeberg.org", .forgejo, "marler/hew-test-tag", .latest_release);
    try expectGit("github.com/marler8997/msi,rev=v1.0", "github.com", .github, "marler8997/msi", .{ .rev = "v1.0" });
    try expectGit("github.com/marler8997/msi/,tip", "github.com", .github, "marler8997/msi", .tip);
}

test "sourcehut packages" {
    try expectGit("git.sr.ht/~asibahi/3sl", "git.sr.ht", .srht, "~asibahi/3sl", .latest_release);
    try expectGit("git.sr.ht/~asibahi/3sl/,rev=v0.2.0", "git.sr.ht", .srht, "~asibahi/3sl", .{ .rev = "v0.2.0" });
    try expectGit("sr.example.com/~user/repo,srht", "sr.example.com", .srht, "~user/repo", .latest_release);
    try expectFormat("git.sr.ht/~asibahi/3sl", "git.sr.ht/~asibahi/3sl", "git.sr.ht+~asibahi+3sl");
    try expectErr("git.sr.ht/asibahi/3sl", "missing '~' before the owner, must be of the form 'git.sr.ht/~owner/repo[,options]'");
    try expectErr("git.sr.ht/~/3sl", "empty path segment, must be of the form 'git.sr.ht/~owner/repo[,options]'");
    try expectErr("git.sr.ht/~asibahi/~3sl", "invalid character '~' in path \"~asibahi/~3sl\"");
    try expectErr("git.sr.ht/~asibahi", "missing owner/repo, must be of the form 'git.sr.ht/~owner/repo[,options]'");
    try expectErr("git.sr.ht/~asibahi/3sl/tree", "unexpected path after owner/repo, must be of the form 'git.sr.ht/~owner/repo[,options]'");
    try expectErr("github.com/~asibahi/3sl", "invalid character '~' in path \"~asibahi/3sl\"");
    try expectErr("git.sr.ht/~asibahi/3sl,srht", "remove the redundant ',srht', 'git.sr.ht' is always srht");
    // git: was never a scheme
    try expectErr("git:asibahi/3sl", "unknown scheme 'git:'");
}

test "custom host packages" {
    try expectGit("git.example.com/team/tool,github", "git.example.com", .github, "team/tool", .latest_release);
    try expectGit("git.example.com/a/b/c,gitlab,tip", "git.example.com", .gitlab, "a/b/c", .tip);
    try expectGit("code.forgejo.org/forgejo/runner,rev=v1,forgejo", "code.forgejo.org", .forgejo, "forgejo/runner", .{ .rev = "v1" });
}

test "packages format in their parsed form" {
    try expectFormat("gitlab.com/dasimmet/zig-container/,tip", "gitlab.com/dasimmet/zig-container", "gitlab.com+dasimmet+zig-container");
    try expectFormat("git.example.com/a/b/c,gitlab", "git.example.com/a/b/c,gitlab", "git.example.com+a+b+c");
}

test "file names don't collide" {
    // these all mapped to gitlab.com-a-b-c when '/' became '-'
    try expectFormat("gitlab.com/a/b-c", "gitlab.com/a/b-c", "gitlab.com+a+b-c");
    try expectFormat("gitlab.com/a-b/c", "gitlab.com/a-b/c", "gitlab.com+a-b+c");
    try expectFormat("gitlab.com/a/b/c", "gitlab.com/a/b/c", "gitlab.com+a+b+c");
}

test "unsafe characters" {
    try expectErr("a.b\\..\\..\\c/o/r,forgejo", "invalid character '\\' in host \"a.b\\\\..\\\\..\\\\c\"");
    try expectErr("github.com/o/r\\..\\..\\x", "invalid character '\\' in path \"o/r\\\\..\\\\..\\\\x\"");
    try expectErr("github.com/o/r:stream", "invalid character ':' in path \"o/r:stream\"");
    try expectErr("evil.com?.github.com/o/r,github", "invalid character '?' in host \"evil.com?.github.com\"");
    try expectErr("evil.com#.github.com/o/r,github", "invalid character '#' in host \"evil.com#.github.com\"");
    try expectErr("github.com@evil.com/o/r,github", "invalid character '@' in host \"github.com@evil.com\"");
    try expectErr("github.com/../..", "unexpected '.' or '..' path segment, must be of the form 'github.com/owner/repo[,options]'");
    try expectErr("github.com/o/..", "unexpected '.' or '..' path segment, must be of the form 'github.com/owner/repo[,options]'");
    try expectErr("gitlab.com/a/../../b", "unexpected '.' or '..' path segment, must be of the form 'gitlab.com/group[/subgroup...]/repo[,options]'");
    try expectErr("github.com/o/r x", "invalid character 0x20 in path \"o/r x\"");
    try expectErr("github.com/o/r%2F..%2Fx", "invalid character '%' in path \"o/r%2F..%2Fx\"");
    try expectErr("github.com/o/r\r\nX-Injected: 1", "invalid character 0x0d in path \"o/r\\r\\nX-Injected: 1\"");
    try expectErr("github.com/o/r,rev=../../x", "invalid character '/' in rev \"../../x\"");
    try expectErr("github.com/o/r,rev=..", "rev can't be '.' or '..'");
    // a ':' in an option is part of it, not a scheme
    try expectErr("github.com/o/r,rev=a:b", "invalid character ':' in rev \"a:b\"");
    try expectErr("github.com/o/r,rev=v1+build", "invalid character '+' in rev \"v1+build\"");
    try expectErr("GitHub.com/o/r", "host 'GitHub.com' must be lowercase");
    try expectErr("GitLab.com/o/r", "host 'GitLab.com' must be lowercase");
    try expectErr("git.example.com:8443/o/r,gitlab", "ports aren't supported, remove the ':' from 'git.example.com:8443'");
    try expectErr("git.example.com:8443", "ports aren't supported, remove the ':' from 'git.example.com:8443'");
}

test isSafeRev {
    try std.testing.expect(isSafeRev("v1.0.0"));
    try std.testing.expect(isSafeRev("release_2026-11-23"));
    try std.testing.expect(!isSafeRev(""));
    try std.testing.expect(!isSafeRev(".."));
    try std.testing.expect(!isSafeRev("../../x"));
    try std.testing.expect(!isSafeRev("release/1.0"));
    try std.testing.expect(!isSafeRev("v1\\..\\x"));
}

test "bad packages" {
    try expectErr("https://github.com/marler8997/msi", "remove the 'https://' (or 'http://'), a package starts with its host, i.e. 'github.com/owner/repo'");
    try expectErr("http://github.com/marler8997/msi", "remove the 'https://' (or 'http://'), a package starts with its host, i.e. 'github.com/owner/repo'");
    try expectErr("msi", "expected a package of the form 'HOST/REPO_PATH', i.e. 'github.com/owner/repo'");
    try expectErr("example.com/a/b", "unknown host 'example.com', add its forge as an option: ',github', ',gitlab', ',forgejo' or ',srht'");
    try expectErr("github.com/marler8997/msi,github", "remove the redundant ',github', 'github.com' is always github");
    try expectErr("github.com/marler8997/msi,gitlab", "the forge of 'github.com' is github, not gitlab");
    try expectErr("example.com/a/b,github,gitlab", "conflicting options 'github' and 'gitlab'");
    try expectErr("github.com", "missing path, must be of the form 'github.com/owner/repo[,options]'");
    try expectErr("github.com/marler8997", "missing owner/repo, must be of the form 'github.com/owner/repo[,options]'");
    try expectErr("gitlab.com/dasimmet", "missing group/repo, must be of the form 'gitlab.com/group[/subgroup...]/repo[,options]'");
    try expectErr("github.com//msi", "empty path segment, must be of the form 'github.com/owner/repo[,options]'");
    try expectErr("github.com/marler8997//", "empty path segment, must be of the form 'github.com/owner/repo[,options]'");
    try expectErr("github.com/marler8997/msi.git", "unexpected '.git' suffix, must be of the form 'github.com/owner/repo[,options]'");
    try expectErr("github.com/marler8997/msi/tree/main", "unexpected path after owner/repo, must be of the form 'github.com/owner/repo[,options]'");
    try expectErr("github.com/marler8997/msi?tab=readme", "unexpected query or fragment, must be of the form 'github.com/owner/repo[,options]'");
    try expectErr("github.com/marler8997/msi,tip,rev=v1", "conflicting options 'rev' and 'tip'");
    try expectErr("github.com/marler8997/msi,foo", "unknown option 'foo'");
    try expectErr("github.com:marler8997/msi", "unknown scheme 'github.com:'");
    try expectErr("github.com:/o/r", "unknown scheme 'github.com:'");
    try expectErr("github:marler8997/msi", "use 'github.com/owner/repo' instead of 'github:owner/repo'");
    try expectErr("codeberg:marler/hew-test-tag", "use 'codeberg.org/owner/repo' instead of 'codeberg:owner/repo'");
}

const std = @import("std");
