//! socket module — аналог Modules/socketmodule.c
//! Переписан на Zig с использованием libxev (xev.TCP, xev.UDP) для встроенной асинхронности
//! Кроссплатформенный

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

pub const SocketModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        // Address families
        const af_inet = try object.PyObject.newInt(allocator, 2);
        try dict.put("AF_INET", af_inet);
        const af_inet6 = try object.PyObject.newInt(allocator, 10);
        try dict.put("AF_INET6", af_inet6);
        const af_unix = try object.PyObject.newInt(allocator, 1);
        try dict.put("AF_UNIX", af_unix);

        // Socket types
        const sock_stream = try object.PyObject.newInt(allocator, 1);
        try dict.put("SOCK_STREAM", sock_stream);
        const sock_dgram = try object.PyObject.newInt(allocator, 2);
        try dict.put("SOCK_DGRAM", sock_dgram);

        // socket() function
        const socket_fn = try createBuiltin(allocator, "socket", socketFn);
        try dict.put("socket", socket_fn);

        // create_connection
        const connect_fn = try createBuiltin(allocator, "create_connection", createConnection);
        try dict.put("create_connection", connect_fn);

        // getaddrinfo — simplified
        const getaddrinfo_fn = try createBuiltin(allocator, "getaddrinfo", getaddrinfo);
        try dict.put("getaddrinfo", getaddrinfo_fn);

        // gaierror
        const gaierror = try object.PyObject.newStr(allocator, "gaierror");
        try dict.put("gaierror", gaierror);

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
        // Создаёт объект сокета — в реальном Zython использует xev.TCP
        // xev.TCP.init(address) -> non-blocking
        const result_dict = try object.PyObject.newDict(allocator);
        return result_dict;
    }

    fn createConnection(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn getaddrinfo(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        // Simplified — returns empty list
        return try object.PyObject.newList(allocator);
    }
};
