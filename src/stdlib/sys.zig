//! sys — аналог Python/sysmodule.c (нативные части).

const std = @import("std");
const builtin = @import("builtin");
const object = @import("../object/object.zig");
const runtime_mod = @import("../runtime/runtime.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;
const Dict = object.Dict;
const KwArgs = object.KwArgs;

fn mset(vm: *VM, m: Obj, name: []const u8, val: Obj) !void {
    try ops.dictSetStr(m.v.module.dict, vm, name, val);
}

fn mfun(vm: *VM, m: Obj, name: []const u8, comptime f: anytype) !void {
    try mset(vm, m, name, try vm.rt.newBuiltin(name, object.wrapBuiltin(f)));
}

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("sys");

    // argv
    {
        const lst = try rt.newList();
        for (rt.argv) |a| try lst.v.list.items.append(rt.gpa, try rt.newStr(a));
        try mset(vm, m, "argv", lst);
        try mset(vm, m, "orig_argv", lst);
    }
    // path
    try mset(vm, m, "path", try rt.mkObj(rt.list_t, .{ .list = rt.sys_path }));
    // modules
    try mset(vm, m, "modules", try rt.mkObj(rt.dict_t, .{ .dict = rt.modules }));
    // version
    try mset(vm, m, "version", try rt.newStr("3.14.6 (zython, Zig 0.16.0)")); // change to dynamic Zig version
    {
        const vi = try rt.newTuple(&.{
            try rt.newInt(3),
            try rt.newInt(14),
            try rt.newInt(6),
            try rt.newStr("final"),
            try rt.newInt(0),
        });
        try mset(vm, m, "version_info", vi);
    }
    try mset(vm, m, "hexversion", try rt.newInt(0x030E06F0));
    try mset(vm, m, "platform", try rt.newStr(platformStr()));
    try mset(vm, m, "maxsize", try rt.newInt(std.math.maxInt(i64)));
    try mset(vm, m, "byteorder", try rt.newStr(if (builtin.cpu.arch.endian() == .little) "little" else "big"));
    try mset(vm, m, "copyright", try rt.newStr("Zython"));
    try mset(vm, m, "implementation", try rt.newStr("zython"));

    // stdin/stdout/stderr — файловые объекты над std-потоками
    try mset(vm, m, "stdin", try makeStdFile(vm, .stdin));
    try mset(vm, m, "stdout", try makeStdFile(vm, .stdout));
    try mset(vm, m, "stderr", try makeStdFile(vm, .stderr));
    try mset(vm, m, "__stdin__", try makeStdFile(vm, .stdin));
    try mset(vm, m, "__stdout__", try makeStdFile(vm, .stdout));
    try mset(vm, m, "__stderr__", try makeStdFile(vm, .stderr));

    try mfun(vm, m, "exit", sys_exit);
    try mfun(vm, m, "exc_info", sys_exc_info);
    try mfun(vm, m, "getrecursionlimit", sys_getrecursionlimit);
    try mfun(vm, m, "setrecursionlimit", sys_setrecursionlimit);
    try mfun(vm, m, "intern", sys_intern);
    try mfun(vm, m, "getsizeof", sys_getsizeof);
    try mfun(vm, m, "getrefcount", sys_getrefcount);

    // builtins module object
    {
        const bm = try rt.newModuleObj("builtins");
        bm.v.module.dict = rt.builtins_dict;
        try mset(vm, m, "builtin_module_names", try rt.newTuple(&.{}));
        const bmo = bm;
        // sys.modules['builtins']
        const bkey = try rt.newStr("builtins");
        const bh = try vm.pyHash(bkey);
        try rt.modules.setWithHash(vm, bkey, bmo, bh);
    }
    return m;
}

fn platformStr() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux",
        .windows => "win32",
        .macos => "darwin",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        .netbsd => "netbsd",
        .wasi => "wasi",
        else => @tagName(builtin.os.tag),
    };
}

fn makeStdFile(vm: *VM, which: object.File.StdFd) anyerror!Obj {
    const rt = vm.rt;
    const f = try rt.gpa.create(object.File);
    f.* = .{
        .f = null,
        .std_fd = which,
        .readable = which == .stdin,
        .writable = which != .stdin,
        .binary = false,
        .close_fd = false,
        .name = switch (which) {
            .stdin => "<stdin>",
            .stdout => "<stdout>",
            .stderr => "<stderr>",
        },
    };
    return rt.mkObj(rt.file_t, .{ .file = f });
}

fn sys_exit(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const ty = v.excType("SystemExit");
    const eo = try v.mkExc(ty, args);
    try v.raiseObj(eo);
    return error.PyExc;
}

fn sys_exc_info(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    const none = v.rt.newNone();
    if (v.currentHandledExc()) |e| {
        const tobj = try v.rt.mkObj(v.rt.type_t, .{ .type_ = e.ty });
        return v.rt.newTuple(&.{ tobj, e, none });
    }
    return v.rt.newTuple(&.{ none, none, none });
}

fn sys_getrecursionlimit(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    return v.rt.newInt(@intCast(vm_mod.MAX_RECURSION));
}

fn sys_setrecursionlimit(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    return vm.rt.newNone();
}

fn sys_intern(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    _ = vm;
    return args[0];
}

fn sys_getsizeof(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    _ = args;
    return v.rt.newInt(56);
}

fn sys_getrefcount(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    _ = args;
    return v.rt.newInt(123456);
}
