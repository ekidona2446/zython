//! zython / zython.std / zython.std.io
//! Тонкий мост к возможностям Zig std.Io для экспериментов из Python-кода.

const std = @import("std");
const xev = @import("xev");
const object = @import("../object/object.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;
const KwArgs = object.KwArgs;

fn mset(vm: *VM, m: Obj, name: []const u8, val: Obj) !void {
    try ops.dictSetStr(m.v.module.dict, vm, name, val);
}

fn mfun(vm: *VM, m: Obj, name: []const u8, comptime f: anytype) !void {
    try mset(vm, m, name, try vm.rt.newBuiltin(name, object.wrapBuiltin(f)));
}

pub fn initPackage(vm: *VM) anyerror!Obj {
    const m = try vm.rt.newModuleObj("zython");
    const path = try vm.rt.newList();
    try path.v.list.items.append(vm.rt.gpa, try vm.rt.newStr("<zython>"));
    try ops.dictSetStr(m.v.module.dict, vm, "__name__", try vm.rt.newStr("zython"));
    try ops.dictSetStr(m.v.module.dict, vm, "__package__", try vm.rt.newStr("zython"));
    try ops.dictSetStr(m.v.module.dict, vm, "__path__", path);
    try ops.dictSetStr(m.v.module.dict, vm, "__builtins__", try vm.rt.mkObj(vm.rt.dict_t, .{ .dict = vm.rt.builtins_dict }));
    return m;
}

pub fn initStdPackage(vm: *VM) anyerror!Obj {
    const m = try vm.rt.newModuleObj("zython.std");
    const path = try vm.rt.newList();
    try path.v.list.items.append(vm.rt.gpa, try vm.rt.newStr("<zython.std>"));
    try ops.dictSetStr(m.v.module.dict, vm, "__name__", try vm.rt.newStr("zython.std"));
    try ops.dictSetStr(m.v.module.dict, vm, "__package__", try vm.rt.newStr("zython.std"));
    try ops.dictSetStr(m.v.module.dict, vm, "__path__", path);
    try ops.dictSetStr(m.v.module.dict, vm, "__builtins__", try vm.rt.mkObj(vm.rt.dict_t, .{ .dict = vm.rt.builtins_dict }));
    return m;
}

pub fn initIoModule(vm: *VM) anyerror!Obj {
    const m = try vm.rt.newModuleObj("zython.std.io");
    try ops.dictSetStr(m.v.module.dict, vm, "__name__", try vm.rt.newStr("zython.std.io"));
    try ops.dictSetStr(m.v.module.dict, vm, "__package__", try vm.rt.newStr("zython.std"));
    try ops.dictSetStr(m.v.module.dict, vm, "__builtins__", try vm.rt.mkObj(vm.rt.dict_t, .{ .dict = vm.rt.builtins_dict }));
    try mfun(vm, m, "backend", io_backend);
    try mfun(vm, m, "stdout_write", io_stdout_write);
    try mfun(vm, m, "stderr_write", io_stderr_write);
    try mfun(vm, m, "stdout_flush", io_stdout_flush);
    try mfun(vm, m, "stderr_flush", io_stderr_flush);
    try mfun(vm, m, "stdin_readline", io_stdin_readline);
    try mfun(vm, m, "zig_version", io_zig_version);
    try mfun(vm, m, "platform", io_platform);
    return m;
}

fn argStr(vm: *VM, o: Obj) anyerror![]const u8 {
    if (o.v == .str) return o.v.str.bytes;
    const s = try ops.pyStr(vm, o);
    return s.v.str.bytes;
}

fn io_backend(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    return vm.rt.newStr(@tagName(xev.backend));
}

fn io_zig_version(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "{d}.{d}.{d}", .{
        @import("builtin").zig_version.major,
        @import("builtin").zig_version.minor,
        @import("builtin").zig_version.patch,
    }));
}

fn io_platform(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const builtin = @import("builtin");
    return vm.rt.newStr(try std.fmt.allocPrint(vm.rt.gpa, "{s}-{s}", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    }));
}

fn io_stdout_write(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 1) return v.rt.newInt(0);
    const s = try argStr(v, args[0]);
    v.rt.outWrite(s);
    return v.rt.newInt(@intCast(s.len));
}

fn io_stderr_write(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 1) return v.rt.newInt(0);
    const s = try argStr(v, args[0]);
    v.rt.errWrite(s);
    return v.rt.newInt(@intCast(s.len));
}

fn io_stdout_flush(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    vm.rt.outFlush();
    return vm.rt.newNone();
}

fn io_stderr_flush(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    if (vm.rt.err_w) |w| w.interface.flush() catch {};
    return vm.rt.newNone();
}

fn io_stdin_readline(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    return vm.rt.newStr(try vm.rt.inReadLine());
}
