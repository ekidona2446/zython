//! io — BytesIO / StringIO (memory-backed файлы) + константы seek.
//! Аналог Modules/_io — здесь только то, что нужно живому коду (requests, urllib3).

const std = @import("std");
const object = @import("../object/object.zig");
const runtime_mod = @import("../runtime/runtime.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const bltn = @import("../runtime/builtins.zig");

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
    const m = try rt.newModuleObj("io");
    try mset(vm, m, "BytesIO", try vm.rt.newBuiltin("BytesIO", object.wrapBuiltin(io_bytesio)));
    try mset(vm, m, "StringIO", try vm.rt.newBuiltin("StringIO", object.wrapBuiltin(io_stringio)));
    try mset(vm, m, "SEEK_SET", try rt.newInt(0));
    try mset(vm, m, "SEEK_CUR", try rt.newInt(1));
    try mset(vm, m, "SEEK_END", try rt.newInt(2));
    try mset(vm, m, "DEFAULT_BUFFER_SIZE", try rt.newInt(8192));
    return m;
}

fn isFileObj(vm: *VM, o: Obj) bool {
    _ = vm;
    return o.v == .file;
}

fn io_bytesio(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const buf = try v.rt.gpa.create(std.ArrayList(u8));
    buf.* = .empty;
    if (args.len >= 1) {
        if (args[0].v == .bytes) {
            try buf.appendSlice(v.rt.gpa, args[0].v.bytes.data);
        } else if (args[0].v == .bytearray) {
            try buf.appendSlice(v.rt.gpa, args[0].v.bytearray.data.items);
        }
    }
    const f = try v.rt.gpa.create(object.File);
    f.* = .{
        .f = null,
        .std_fd = null,
        .mem_buf = buf,
        .readable = true,
        .writable = true,
        .binary = true,
        .close_fd = false,
        .name = "<BytesIO>",
    };
    return v.rt.mkObj(v.rt.file_t, .{ .file = f });
}

fn io_stringio(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const buf = try v.rt.gpa.create(std.ArrayList(u8));
    buf.* = .empty;
    if (args.len >= 1 and args[0].v == .str) {
        try buf.appendSlice(v.rt.gpa, args[0].v.str.bytes);
    }
    const f = try v.rt.gpa.create(object.File);
    f.* = .{
        .f = null,
        .std_fd = null,
        .mem_buf = buf,
        .readable = true,
        .writable = true,
        .binary = false,
        .close_fd = false,
        .name = "<StringIO>",
    };
    return v.rt.mkObj(v.rt.file_t, .{ .file = f });
}
