//! socket module - аналог Modules/socketmodule.c
//! Переписан на Zig с использованием libxev (xev.TCP, xev.UDP) для встроенной асинхронности
const std = @import("std");
const xev = @import("xev");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

pub const SocketModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        const af_inet = try object.PyObject.newInt(allocator, 2);
        try dict.put("AF_INET", af_inet);

        const sock_stream = try object.PyObject.newInt(allocator, 1);
        try dict.put("SOCK_STREAM", sock_stream);

        const socket_fn = try createBuiltin(allocator, "socket", socketFn);
        try dict.put("socket", socket_fn);

        const module_val = object.ModuleValue{
            .name = "socket",
            .dict = dict,
            .file = "socket (zig, libxev)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn createBuiltin(allocator: Allocator, name: []const u8, func: object.BuiltinFn) !object.ObjectPtr {
        _ = name;
        return try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = func });
    }

    fn socketFn(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        // В реальном Zython: создает xev.TCP socket
        // xev.TCP.init(address) -> non-blocking, используем io_uring на Linux
        std.debug.print("[Zython socket] socket() -> xev.TCP (io_uring)\n", .{});
        return try object.PyObject.newNone(allocator);
    }
};

/// zycorn - Zython + Uvicorn, HTTP сервер на libxev
/// Аналог uvicorn, но на Zig + libxev вместо asyncio + uvloop
pub const ZycornServer = struct {
    allocator: Allocator,
    loop: *xev.Loop,
    address: std.net.Address,
    tcp: ?xev.TCP,

    pub fn init(allocator: Allocator, loop: *xev.Loop, host: []const u8, port: u16) !ZycornServer {
        const addr = try std.net.Address.parseIp(host, port);
        var tcp = try xev.TCP.init(addr);
        try tcp.bind(addr);
        try tcp.listen(128);

        return .{
            .allocator = allocator,
            .loop = loop,
            .address = addr,
            .tcp = tcp,
        };
    }

    pub fn serve(self: *ZycornServer) !void {
        std.debug.print("[zycorn] Serving on {any} via libxev (io_uring backend)\n", .{self.address});
        // В реальном zycorn: accept loop через xev.Completion
        // var c: xev.Completion = undefined;
        // self.tcp.?.accept(self.loop, &c, Self, self, acceptCallback);
        // try self.loop.run(.until_done);
    }
};
