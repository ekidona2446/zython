//! os — аналог Modules/posixmodule.c (достаточное подмножество).
//! Все операции — через std.Io (мультиплатформенно, posix+windows).

const std = @import("std");
const builtin = @import("builtin");
const object = @import("../object/object.zig");
const runtime_mod = @import("../runtime/runtime.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const bltn = @import("../runtime/builtins.zig");
const import_mod = @import("../runtime/import.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;
const Dict = object.Dict;
const KwArgs = object.KwArgs;

fn mset(vm: *VM, m: Obj, name: []const u8, val: Obj) !void {
    try ops.dictSetStr(m.v.module.dict, vm, name, val);
}

fn freg(vm: *VM, m: Obj, name: []const u8, comptime f: anytype) !void {
    try mset(vm, m, name, try vm.rt.newBuiltin(name, object.wrapBuiltin(f)));
}

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("os");

    // environ
    {
        const env = rt.py_environ orelse try rt.newDict();
        rt.py_environ = env;
        const env_obj = try rt.mkObj(rt.dict_t, .{ .dict = env });
        try mset(vm, m, "environ", env_obj);
        try mset(vm, m, "environb", env_obj);
    }
    try mset(vm, m, "name", try rt.newStr(if (builtin.os.tag == .windows) "nt" else "posix"));
    try mset(vm, m, "sep", try rt.newStr(if (builtin.os.tag == .windows) "\\" else "/"));
    try mset(vm, m, "pathsep", try rt.newStr(if (builtin.os.tag == .windows) ";" else ":"));
    try mset(vm, m, "linesep", try rt.newStr(if (builtin.os.tag == .windows) "\r\n" else "\n"));
    try mset(vm, m, "defpath", try rt.newStr(":/bin:/usr/bin"));

    try freg(vm, m, "getcwd", os_getcwd);
    try freg(vm, m, "getcwdb", os_getcwdb);
    try freg(vm, m, "urandom", os_urandom);
    try freg(vm, m, "getenv", os_getenv);
    try freg(vm, m, "putenv", os_putenv);
    try freg(vm, m, "unsetenv", os_unsetenv);
    try freg(vm, m, "listdir", os_listdir);
    try freg(vm, m, "mkdir", os_mkdir);
    try freg(vm, m, "makedirs", os_makedirs);
    try freg(vm, m, "rmdir", os_rmdir);
    try freg(vm, m, "remove", os_remove);
    try freg(vm, m, "unlink", os_remove);
    try freg(vm, m, "rename", os_rename);
    try freg(vm, m, "replace", os_rename);
    try freg(vm, m, "stat", os_stat);
    try freg(vm, m, "lstat", os_stat);
    try freg(vm, m, "fspath", os_fspath);
    try freg(vm, m, "getpid", os_getpid);
    try freg(vm, m, "getppid", os_getpid);
    try freg(vm, m, "strerror", os_strerror);
    try freg(vm, m, "system", os_system);
    try freg(vm, m, "cpu_count", os_cpu_count);
    try freg(vm, m, "chdir", os_chdir);

    // os.path — подмодуль с pure-path функциями
    {
        const pm = try rt.newModuleObj("os.path");
        try freg(vm, pm, "exists", path_exists);
        try freg(vm, pm, "isfile", path_isfile);
        try freg(vm, pm, "isdir", path_isdir);
        try freg(vm, pm, "isabs", path_isabs);
        try freg(vm, pm, "join", path_join);
        try freg(vm, pm, "split", path_split);
        try freg(vm, pm, "dirname", path_dirname);
        try freg(vm, pm, "basename", path_basename);
        try freg(vm, pm, "splitext", path_splitext);
        try freg(vm, pm, "abspath", path_abspath);
        try freg(vm, pm, "normpath", path_normpath);
        try freg(vm, pm, "getsize", path_getsize);
        try mset(vm, m, "path", pm);
        // sys.modules["os.path"]
        const kobj = try rt.newStr("os.path");
        const h = try vm.pyHash(kobj);
        try rt.modules.setWithHash(vm, kobj, pm, h);
        // атрибуты posixpath-подобные
        try mset(vm, pm, "sep", try rt.newStr(if (builtin.os.tag == .windows) "\\" else "/"));
    }
    return m;
}

fn ioOf(vm: *VM) !std.Io {
    if (vm.rt.io) |io| return io;
    try vm.raiseStr("RuntimeError", "io subsystem is not initialized");
    return error.PyExc;
}

fn strPath(vm: *VM, o: Obj) ![]const u8 {
    if (o.v == .str) return o.v.str.bytes;
    if (o.v == .bytes) return o.v.bytes.data;
    // __fspath__
    if (ops.lookupSpecial(vm, o, "__fspath__")) |m| {
        const r = try vm.pyCall(m, &.{o}, null);
        return strPath(vm, r);
    }
    try vm.raiseFmt("TypeError", "expected str, bytes or os.PathLike object, not {s}", .{o.ty.name});
    return error.PyExc;
}

fn os_getcwd(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    const io = try ioOf(v);
    var buf: [4096]u8 = undefined;
    const n = std.Io.Dir.cwd().realPath(io, &buf) catch |e| return bltn.ioErr(vm, e, null);
    return v.rt.newStr(buf[0..n]);
}

fn os_getcwdb(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    const io = try ioOf(v);
    var buf: [4096]u8 = undefined;
    const n = std.Io.Dir.cwd().realPath(io, &buf) catch |e| return bltn.ioErr(vm, e, null);
    return v.rt.newBytes(buf[0..n]);
}

fn os_urandom(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const n = try bltn.indexLike(v, args[0]);
    if (n < 0) {
        try v.raiseStr("ValueError", "negative argument not allowed");
        return error.PyExc;
    }
    const out = try v.rt.gpa.alloc(u8, @intCast(n));
    v.rt.io.?.random(out);
    return v.rt.newBytesOwned(out);
}

fn os_getenv(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const key_s = try strPath(v, args[0]);
    if (v.rt.py_environ) |env| {
        var it = env.iterAlive();
        while (it.next()) |e| {
            if (e.key.?.v == .str and std.mem.eql(u8, e.key.?.v.str.bytes, key_s)) {
                return e.val.?;
            }
        }
    }
    if (args.len >= 2) return args[1];
    return v.rt.newNone();
}

fn os_putenv(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const key_s = try strPath(v, args[0]);
    const val_s = try strPath(v, args[1]);
    if (v.rt.py_environ) |env| {
        const kobj = try v.rt.newStr(key_s);
        const h = try vm.pyHash(kobj);
        try env.setWithHash(vm, kobj, try v.rt.newStr(val_s), h);
    }
    return v.rt.newNone();
}

fn os_unsetenv(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const key_s = try strPath(v, args[0]);
    if (v.rt.py_environ) |env| {
        const kobj = try v.rt.newStr(key_s);
        const h = try vm.pyHash(kobj);
        _ = try env.delWithHash(vm, kobj, h);
    }
    return v.rt.newNone();
}

fn os_listdir(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const path: []const u8 = if (args.len >= 1) try strPath(v, args[0]) else ".";
    const io = try ioOf(v);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e| {
        return bltn.ioErr(v, e, path);
    };
    defer dir.close(io);
    const out = try v.rt.newList();
    var it = dir.iterate();
    while (it.next(io) catch |e| return bltn.ioErr(v, e, path)) |entry| {
        try out.v.list.items.append(v.rt.gpa, try v.rt.newStr(entry.name));
    }
    return out;
}

fn os_mkdir(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const path = try strPath(v, args[0]);
    const io = try ioOf(v);
    std.Io.Dir.cwd().createDir(io, path, .default_dir) catch |e| {
        return bltn.ioErr(v, e, path);
    };
    return v.rt.newNone();
}

fn os_makedirs(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const path = try strPath(v, args[0]);
    const io = try ioOf(v);
    const exist_ok = args.len >= 3 and args[2].isTruthy();
    std.Io.Dir.cwd().createDirPath(io, path) catch |e| {
        return bltn.ioErr(v, e, path);
    };
    _ = exist_ok;
    return v.rt.newNone();
}

fn os_rmdir(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const path = try strPath(v, args[0]);
    const io = try ioOf(v);
    std.Io.Dir.cwd().deleteDir(io, path) catch |e| {
        return bltn.ioErr(v, e, path);
    };
    return v.rt.newNone();
}

fn os_remove(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const path = try strPath(v, args[0]);
    const io = try ioOf(v);
    std.Io.Dir.cwd().deleteFile(io, path) catch |e| {
        return bltn.ioErr(v, e, path);
    };
    return v.rt.newNone();
}

fn os_rename(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const src = try strPath(v, args[0]);
    const dst = try strPath(v, args[1]);
    const io = try ioOf(v);
    std.Io.Dir.rename(std.Io.Dir.cwd(), src, std.Io.Dir.cwd(), dst, io) catch |e| {
        return bltn.ioErr(v, e, src);
    };
    return v.rt.newNone();
}

fn os_stat(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const path = try strPath(v, args[0]);
    const io = try ioOf(v);
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch |e| {
        return bltn.ioErr(v, e, path);
    };
    // stat_result: упрощённый tuple (mode, ino, dev, nlink, uid, gid, size, atime, mtime, ctime)
    const rt = v.rt;
    const mode: i64 = switch (st.kind) {
        .directory => 0o40755,
        .file => 0o100644,
        .sym_link => 0o120777,
        else => 0o100644,
    };
    return rt.newTuple(&.{
        try rt.newInt(mode),
        try rt.newInt(@intCast(st.inode)),
        try rt.newInt(0),
        try rt.newInt(@intCast(st.nlink)),
        try rt.newInt(0),
        try rt.newInt(0),
        try rt.newInt(@intCast(st.size)),
        try rt.newInt(0),
        try rt.newInt(0),
        try rt.newInt(0),
    });
}

fn os_fspath(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    _ = try strPath(vm, args[0]);
    return args[0];
}

fn os_getpid(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    const pid: i64 = switch (builtin.os.tag) {
        .windows => 0, // TODO: GetCurrentProcessId через std.os.windows
        else => std.os.linux.getpid(),
    };
    return v.rt.newInt(pid);
}

fn os_strerror(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    _ = args;
    return v.rt.newStr("Error");
}

fn os_system(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    _ = args;
    // TODO: spawn через std.process.Child (std.Io) — следующий этап
    return v.rt.newInt(0);
}

fn os_cpu_count(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    const n = std.Thread.getCpuCount() catch 1;
    return v.rt.newInt(@intCast(n));
}

fn os_chdir(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const path = try strPath(v, args[0]);
    const io = try ioOf(v);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch |e| {
        return bltn.ioErr(v, e, path);
    };
    dir.close(io);
    // std.Io не держит глобальный cwd-стейт в 0.16 интерфейсе: реальный chdir
    // — posix-syscall (linux) / SetCurrentDirectory (windows)
    switch (builtin.os.tag) {
        .windows => {},
        else => {
            var pbuf: [4096]u8 = undefined;
            if (path.len >= pbuf.len) return bltn.ioErr(v, error.NameTooLong, path);
            @memcpy(pbuf[0..path.len], path);
            pbuf[path.len] = 0;
            const rc = std.os.linux.chdir(pbuf[0..path.len :0]);
            if (std.os.linux.errno(rc) != .SUCCESS) {
                return bltn.ioErr(v, error.AccessDenied, path);
            }
        },
    }
    return v.rt.newNone();
}

// ============================================================
// os.path
// ============================================================

fn path_exists(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const path = try strPath(v, args[0]);
    const io = try ioOf(v);
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        return v.rt.false_obj;
    };
    return v.rt.true_obj;
}

fn path_isfile(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const path = try strPath(v, args[0]);
    const io = try ioOf(v);
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        return v.rt.false_obj;
    };
    return v.rt.newBool(st.kind == .file);
}

fn path_isdir(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const path = try strPath(v, args[0]);
    const io = try ioOf(v);
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
        return v.rt.false_obj;
    };
    return v.rt.newBool(st.kind == .directory);
}

fn path_isabs(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const path = try strPath(v, args[0]);
    return v.rt.newBool(std.Io.Dir.path.isAbsolute(path));
}

const pathSep: u8 = if (builtin.os.tag == .windows) '\\' else '/';

fn path_join(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    var out: std.ArrayList(u8) = .empty;
    for (args) |a| {
        const p = try strPath(v, a);
        if (p.len == 0) continue;
        if (std.Io.Dir.path.isAbsolute(p)) {
            out.clearRetainingCapacity();
            try out.appendSlice(v.rt.gpa, p);
        } else {
            if (out.items.len > 0 and out.items[out.items.len - 1] != pathSep) {
                try out.append(v.rt.gpa, pathSep);
            }
            try out.appendSlice(v.rt.gpa, p);
        }
    }
    return v.rt.newStrOwned(try out.toOwnedSlice(v.rt.gpa));
}

fn splitPath(p: []const u8) struct { dir: []const u8, base: []const u8 } {
    var end = p.len;
    while (end > 0 and p[end - 1] == pathSep) end -= 1;
    const q = p[0..end];
    if (std.mem.lastIndexOfScalar(u8, q, pathSep)) |idx| {
        return .{ .dir = if (idx == 0) "/" else q[0..idx], .base = q[idx + 1 ..] };
    }
    return .{ .dir = "", .base = q };
}

fn path_split(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const p = try strPath(v, args[0]);
    const s = splitPath(p);
    return v.rt.newTuple(&.{ try v.rt.newStr(s.dir), try v.rt.newStr(s.base) });
}

fn path_dirname(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const p = try strPath(v, args[0]);
    return v.rt.newStr(splitPath(p).dir);
}

fn path_basename(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const p = try strPath(v, args[0]);
    return v.rt.newStr(splitPath(p).base);
}

fn path_splitext(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const p = try strPath(v, args[0]);
    const base = splitPath(p).base;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |idx| {
        if (idx > 0) {
            const root_len = p.len - base.len + idx;
            return v.rt.newTuple(&.{ try v.rt.newStr(p[0..root_len]), try v.rt.newStr(base[idx..]) });
        }
    }
    return v.rt.newTuple(&.{ try v.rt.newStr(p), try v.rt.newStr("") });
}

fn path_abspath(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const p = try strPath(v, args[0]);
    const io = try ioOf(v);
    var buf: [4096]u8 = undefined;
    if (std.Io.Dir.path.isAbsolute(p)) {
        return normalizeInto(v, p);
    }
    const n = std.Io.Dir.cwd().realPathFile(io, p, &buf) catch |e| {
        return bltn.ioErr(v, e, p);
    };
    return v.rt.newStr(buf[0..n]);
}

fn normalizeInto(vm: *VM, p: []const u8) anyerror!Obj {
    // абсолютный — нормализуем точки
    var out: std.ArrayList(u8) = .empty;
    var comps: std.ArrayList([]const u8) = .empty;
    const abs = p.len > 0 and p[0] == pathSep;
    var it = std.mem.splitScalar(u8, p, pathSep);
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) {
            if (comps.items.len > 0) _ = comps.pop();
        } else {
            try comps.append(vm.rt.gpa, c);
        }
    }
    if (abs) try out.append(vm.rt.gpa, pathSep);
    for (comps.items, 0..) |c, i| {
        if (i > 0) try out.append(vm.rt.gpa, pathSep);
        try out.appendSlice(vm.rt.gpa, c);
    }
    if (out.items.len == 0) try out.append(vm.rt.gpa, if (abs) pathSep else '.');
    return vm.rt.newStrOwned(try out.toOwnedSlice(vm.rt.gpa));
}

fn path_normpath(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const p = try strPath(v, args[0]);
    return normalizeInto(v, p);
}

fn path_getsize(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const p = try strPath(v, args[0]);
    const io = try ioOf(v);
    const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch |e| {
        return bltn.ioErr(v, e, p);
    };
    return v.rt.newInt(@intCast(st.size));
}
