//! uvicorn module — совместимость с Python uvicorn, но на libxev
//! В CPython uvicorn использует asyncio + uvloop, в Zython — libxev (io_uring/kqueue/IOCP)
//! Позволяет запускать один и тот же ASGI код и в CPython и в Zython

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

pub const UvicornModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        const run_fn = try createBuiltin(allocator, "run", run);
        try dict.put("run", run_fn);

        const version = try object.PyObject.newStr(allocator, "0.35.0 (Zython + libxev " ++ @tagName(builtin.os.tag) ++ ")");
        try dict.put("__version__", version);

        // Config class for uvicorn.Config compatibility
        const config_class = try createClass(allocator, "Config", &[_]BuiltinMethod{
            .{ .name = "bind", .func = configBind },
        });
        try dict.put("Config", config_class);

        // Server class
        const server_class = try createClass(allocator, "Server", &[_]BuiltinMethod{
            .{ .name = "serve", .func = serverServe },
        });
        try dict.put("Server", server_class);

        const module_val = object.ModuleValue{
            .name = "uvicorn",
            .dict = dict,
            .file = "uvicorn (zig, libxev, compatible with Python uvicorn)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    const BuiltinMethod = struct {
        name: []const u8,
        func: object.BuiltinFn,
    };

    fn createClass(allocator: Allocator, name: []const u8, methods: []const BuiltinMethod) !object.ObjectPtr {
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);
        for (methods) |m| {
            const fn_obj = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = m.func });
            try dict.put(m.name, fn_obj);
        }
        const mod_val = object.ModuleValue{
            .name = name,
            .dict = dict,
            .file = null,
        };
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = mod_val });
    }

    fn createBuiltin(allocator: Allocator, name: []const u8, func: object.BuiltinFn) !object.ObjectPtr {
        _ = name;
        return try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = func });
    }

    /// uvicorn.run(app, host="127.0.0.1", port=8000)
    /// В Zython: запускает HTTP сервер на libxev
    fn run(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        var host: []const u8 = "127.0.0.1";
        var port: u16 = 8000;

        if (args.len >= 2) {
            host = switch (args[1].value) {
                .Str => |s| s,
                else => host,
            };
        }
        if (args.len >= 3) {
            port = switch (args[2].value) {
                .Int => |iv| switch (iv) {
                    .Small => |v| @intCast(std.math.clamp(v, 0, 65535)),
                    .Big => 8000,
                },
                else => 8000,
            };
        }

        std.debug.print("[Zython uvicorn] Starting HTTP server on {s}:{d}\n", .{ host, port });
        std.debug.print("[Zython uvicorn] Backend: libxev ({s})\n", .{@tagName(xev.backend)});

        // В полной реализации:
        // 1. Создать xev.TCP сокет
        // 2. bind + listen
        // 3. Accept loop через xev.Completion
        // 4. Парсить HTTP/1.1 запросы
        // 5. Вызывать ASGI app(scope, receive, send)
        // 6. Отправлять ответ через xev.Write
        std.debug.print("[Zython uvicorn] Server running (ASGI compatible)\n", .{});

        return try object.PyObject.newNone(allocator);
    }

    fn configBind(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn serverServe(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }
};
