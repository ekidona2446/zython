//! sys module - аналог Python/sysmodule.c
const std = @import("std");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

pub const SysModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        const version = try object.PyObject.newStr(allocator, "3.12.0 (Zython 0.1.0, Zig 0.16.0 + libxev)");
        try dict.put("version", version);

        const path_list = try object.PyObject.newList(allocator);
        const dot = try object.PyObject.newStr(allocator, ".");
        try path_list.value.List.items.append(allocator, dot);
        const lib = try object.PyObject.newStr(allocator, "./Lib");
        try path_list.value.List.items.append(allocator, lib);
        const py_mods = try object.PyObject.newStr(allocator, "./python_modules");
        try path_list.value.List.items.append(allocator, py_mods);
        try dict.put("path", path_list);

        const modules_dict = try object.PyObject.newDict(allocator);
        try dict.put("modules", modules_dict);

        const module_val = object.ModuleValue{
            .name = "sys",
            .dict = dict,
            .file = "sys.py (zig)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }
};
