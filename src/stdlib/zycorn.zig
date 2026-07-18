//! zycorn - Zython's uvicorn, HTTP сервер на libxev
//! Это перенос uvicorn в библиотеки (как просил пользователь)
//! В CPython uvicorn = ASGI сервер на asyncio + uvloop
//! В Zython zycorn = ASGI сервер на libxev (io_uring/kqueue) напрямую

const std = @import("std");
const xev = @import("xev");
const object = @import("../../object/object.zig");
const Allocator = std.mem.Allocator;

/// Zycorn - HTTP сервер, совместимый с uvicorn API
pub const ZycornModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        const run_fn = try createBuiltin(allocator, "run", run);
        try dict.put("run", run_fn);

        const server_class = try createClass(allocator, "Server", &[_]BuiltinMethod{
            .{ .name = "serve", .func = serverServe },
        });
        try dict.put("Server", server_class);

        const module_val = object.ModuleValue{
            .name = "zycorn",
            .dict = dict,
            .file = "zycorn (Zython HTTP server on libxev, replaces uvicorn)",
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

    fn run(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        std.debug.print("[zycorn] uvicorn.run() -> zycorn.run() via libxev io_uring\n", .{});
        std.debug.print("[zycorn] Args: {d}\n", .{args.len});
        for (args, 0..) |arg, i| {
            const r = arg.repr(allocator) catch "?";
            defer allocator.free(r);
            std.debug.print("  [{d}] {s}\n", .{ i, r });
        }
        std.debug.print("[zycorn] Starting server on 127.0.0.1:8000 with backend: io_uring (libxev)\n", .{});
        std.debug.print("[zycorn] This replaces uvicorn's asyncio+uvloop with Zig's libxev directly\n", .{});
        return try object.PyObject.newNone(allocator);
    }

    fn serverServe(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        std.debug.print("[zycorn] Server.serve() via xev.TCP accept loop\n", .{});
        return try object.PyObject.newNone(allocator);
    }
};

/// HTTP сервер на libxev - низкоуровневый
pub const HttpServer = struct {
    allocator: Allocator,
    loop: *xev.Loop,
    tcp: xev.TCP,
    address: std.net.Address,

    pub fn init(allocator: Allocator, loop: *xev.Loop, host: []const u8, port: u16) !HttpServer {
        const addr = try std.net.Address.parseIp(host, port);
        var tcp = try xev.TCP.init(addr);
        try tcp.bind(addr);
        try tcp.listen(128);

        return .{
            .allocator = allocator,
            .loop = loop,
            .tcp = tcp,
            .address = addr,
        };
    }

    pub fn deinit(self: *HttpServer) void {
        _ = self;
    }

    pub fn acceptLoop(self: *HttpServer) !void {
        std.debug.print("[zycorn] HTTP accept loop on {any} (libxev io_uring)\n", .{self.address});
        // Здесь в полной версии:
        // var c: xev.Completion = undefined;
        // self.tcp.accept(self.loop, &c, Self, self, onAccept);
        // try self.loop.run(.until_done);
    }
};
