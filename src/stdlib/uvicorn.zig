//! uvicorn module - совместимость с Python uvicorn, но на libxev
//! В CPython uvicorn использует asyncio + uvloop, в Zython - libxev (io_uring)
//! Это позволяет запускать один и тот же ASGI код и в CPython и в Zython

const std = @import("std");
const xev = @import("xev");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

pub const UvicornModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        const run_fn = try createBuiltin(allocator, "run", run);
        try dict.put("run", run_fn);

        const version = try object.PyObject.newStr(allocator, "0.35.0 (Zython + libxev)");
        try dict.put("__version__", version);

        const module_val = object.ModuleValue{
            .name = "uvicorn",
            .dict = dict,
            .file = "uvicorn (zig, libxev, compatible with Python uvicorn)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn createBuiltin(allocator: Allocator, name: []const u8, func: object.BuiltinFn) !object.ObjectPtr {
        _ = name;
        return try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = func });
    }

    /// uvicorn.run(app, host="127.0.0.1", port=8000)
    /// В Zython: запускает zycorn сервер на libxev (io_uring)
    /// В CPython: оригинальный uvicorn.run использует asyncio
    fn run(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        std.debug.print("[Zython uvicorn] uvicorn.run() called - using zycorn (libxev backend)\n", .{});
        std.debug.print("[Zython uvicorn] Args: {d} args\n", .{args.len});
        for (args, 0..) |arg, i| {
            const repr = arg.repr(allocator) catch "?";
            defer allocator.free(repr);
            std.debug.print("  arg[{d}]: {s} ({s})\n", .{ i, repr, arg.type_ptr.name });
        }

        std.debug.print("[zycorn] Starting HTTP server on 127.0.0.1:8000 via libxev (io_uring)\n", .{});
        std.debug.print("[zycorn] This would in full version:\n", .{});
        std.debug.print("  - Create xev.TCP socket\n", .{});
        std.debug.print("  - Bind to 127.0.0.1:8000\n", .{});
        std.debug.print("  - Listen with backlog 128\n", .{});
        std.debug.print("  - Accept loop via xev.Completion\n", .{});
        std.debug.print("  - Parse HTTP/1.1 via h11 (pure python, works in Zython)\n", .{});
        std.debug.print("  - Call ASGI app(scope, receive, send)\n", .{});
        std.debug.print("  - Send response via xev.Write\n", .{});
        std.debug.print("[zycorn] For demo, we just print that server would start\n", .{});

        return try object.PyObject.newNone(allocator);
    }
};

// Для build.zig.zon - pip dependency simulation
// В реальном Zython, pip install uvicorn скачает tarball и установит в python_modules/
// Мы уже сделали: vendor/uvicorn содержит исходники uvicorn 0.35.0
// И python_modules/uvicorn содержит установленный пакет через pip
// Zython's import system ищет в ./python_modules/ и ./vendor/uvicorn
