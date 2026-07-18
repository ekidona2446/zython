//! os module - аналог Modules/posixmodule.c
//! Реализует os.* через std.Io.Dir + libxev для async операций
const std = @import("std");
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

        // os.path - создается как submodule
        // Для MVP: os.environ, os.name

        const name_obj = try object.PyObject.newStr(allocator, "posix");
        try dict.put("name", name_obj);

        const module_val = object.ModuleValue{
            .name = "os",
            .dict = dict,
            .file = "os.py (zig)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn createBuiltin(allocator: Allocator, name: []const u8, func: object.BuiltinFn) !object.ObjectPtr {
        _ = name;
        return try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = func });
    }

    fn getcwd(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        // Zig 0.16: use Io.Dir.cwd().currentPathAlloc
        // For MVP, return "."
        return try object.PyObject.newStr(allocator, ".");
    }

    fn listdir(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        // MVP: возвращает пустой список, в полной версии - через Io.Dir
        return try object.PyObject.newList(allocator);
    }
};
