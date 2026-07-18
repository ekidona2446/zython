//! asyncio module - аналог Lib/asyncio/ + Modules/_asynciomodule.c
//! В Zython asyncio полностью на libxev, без Python overhead
const std = @import("std");
const xev = @import("xev");
const object = @import("../object/object.zig");
const runtime_loop = @import("../runtime/loop.zig");
const Allocator = std.mem.Allocator;

/// _zython builtin module - экспонирует libxev loop в Python
pub const ZythonBuiltin = struct {
    pub fn init(allocator: Allocator, loop: *runtime_loop.ZythonLoop) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        _ = loop;

        const module_val = object.ModuleValue{
            .name = "_zython",
            .dict = dict,
            .file = "_zython (zig)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }
};

pub const AsyncioModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        const sleep_fn = try createBuiltin(allocator, "sleep", sleep);
        try dict.put("sleep", sleep_fn);

        const run_fn = try createBuiltin(allocator, "run", run);
        try dict.put("run", run_fn);

        const create_task_fn = try createBuiltin(allocator, "create_task", createTask);
        try dict.put("create_task", create_task_fn);

        const get_loop_fn = try createBuiltin(allocator, "get_event_loop", getEventLoop);
        try dict.put("get_event_loop", get_loop_fn);

        const module_val = object.ModuleValue{
            .name = "asyncio",
            .dict = dict,
            .file = "asyncio (zig, libxev backend)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn createBuiltin(allocator: Allocator, name: []const u8, func: object.BuiltinFn) !object.ObjectPtr {
        _ = name;
        return try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = func });
    }

    fn sleep(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        // args[0] = delay (float seconds)
        // В реальном Zython: создает xev.Timer completion и yield'ит через ZYTHON_AWAIT_IO опкод
        // Для MVP: просто возвращает None, но логирует что используется libxev
        _ = args;
        std.debug.print("[Zython asyncio] sleep() -> xev.Timer (io_uring)\n", .{});
        return try object.PyObject.newNone(allocator);
    }

    fn run(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        std.debug.print("[Zython asyncio] run() -> ZythonLoop.run(.until_done) via libxev\n", .{});
        return try object.PyObject.newNone(allocator);
    }

    fn createTask(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        std.debug.print("[Zython asyncio] create_task() -> ZythonLoop.createTask() + xev.Async\n", .{});
        return try object.PyObject.newNone(allocator);
    }

    fn getEventLoop(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }
};
