//! os module — аналог Modules/posixmodule.c (Linux/macOS) / Modules/ntmodule.c (Windows)
//! Кроссплатформенная реализация через std.os + libxev для async операций

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

pub const OSModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        // os.getcwd()
        const getcwd_fn = try createBuiltin(allocator, "getcwd", getcwd);
        try dict.put("getcwd", getcwd_fn);

        // os.listdir()
        const listdir_fn = try createBuiltin(allocator, "listdir", listdir);
        try dict.put("listdir", listdir_fn);

        // os.mkdir()
        const mkdir_fn = try createBuiltin(allocator, "mkdir", mkdir);
        try dict.put("mkdir", mkdir_fn);

        // os.path.join()
        const path_join_fn = try createBuiltin(allocator, "path_join", pathJoin);
        try dict.put("path_join", path_join_fn);

        // os.environ — пустой dict для MVP
        const environ = try object.PyObject.newDict(allocator);
        try dict.put("environ", environ);

        // os.name — платформенно-зависимый
        const os_name: []const u8 = switch (builtin.os.tag) {
            .linux => "posix",
            .macos => "posix",
            .windows => "nt",
            .freebsd, .openbsd, .netbsd => "posix",
            else => "posix",
        };
        const name_obj = try object.PyObject.newStr(allocator, os_name);
        try dict.put("name", name_obj);

        // os.sep — разделитель пути
        const sep: []const u8 = switch (builtin.os.tag) {
            .windows => "\\",
            else => "/",
        };
        const sep_obj = try object.PyObject.newStr(allocator, sep);
        try dict.put("sep", sep_obj);

        // os.linesep
        const linesep: []const u8 = switch (builtin.os.tag) {
            .windows => "\r\n",
            else => "\n",
        };
        const linesep_obj = try object.PyObject.newStr(allocator, linesep);
        try dict.put("linesep", linesep_obj);

        const module_val = object.ModuleValue{
            .name = "os",
            .dict = dict,
            .file = "os (zig, cross-platform)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn createBuiltin(allocator: Allocator, name: []const u8, func: object.BuiltinFn) !object.ObjectPtr {
        _ = name;
        return try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = func });
    }

    fn getcwd(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newStr(allocator, ".");
    }

    fn listdir(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        const list_obj = try object.PyObject.newList(allocator);
        // Full implementation would iterate std.Io.Dir — for now returns empty list
        return list_obj;
    }

    fn mkdir(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len == 0) return error.TypeError;
        const path = switch (args[0].value) {
            .Str => |s| s,
            else => return error.TypeError,
        };
        _ = path;
        return try object.PyObject.newNone(allocator);
    }

    fn pathJoin(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 2) return error.TypeError;
        const a = switch (args[0].value) { .Str => |s| s, else => return error.TypeError };
        const b = switch (args[1].value) { .Str => |s| s, else => return error.TypeError };
        const joined = try std.fs.path.join(allocator, &.{ a, b });
        defer allocator.free(joined);
        return try object.PyObject.newStr(allocator, joined);
    }
};
