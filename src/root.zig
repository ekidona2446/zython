//! Zython — Python интерпретатор на Zig с libxev async

const std = @import("std");
const builtin = @import("builtin");
pub const object = @import("object/object.zig");
pub const opcode = @import("vm/opcode.zig");
pub const vm = @import("vm/vm.zig");
pub const lexer = @import("parser/lexer.zig");
pub const ast = @import("parser/ast.zig");
pub const parser = @import("parser/parser.zig");
pub const compiler = @import("compiler/compiler.zig");
pub const runtime_loop = @import("runtime/loop.zig");
pub const gc = @import("runtime/gc.zig");
pub const import_system = @import("runtime/import.zig");
pub const builtins = @import("runtime/builtins.zig");
pub const stdlib_os = @import("stdlib/os.zig");
pub const stdlib_sys = @import("stdlib/sys.zig");
pub const stdlib_asyncio = @import("stdlib/asyncio.zig");
pub const stdlib_socket = @import("stdlib/socket.zig");
pub const stdlib_uvicorn = @import("stdlib/uvicorn.zig");
pub const stdlib_json = @import("stdlib/json.zig");
pub const stdlib_datetime = @import("stdlib/datetime.zig");
pub const stdlib_math = @import("stdlib/math.zig");
pub const stdlib_zycorn = @import("stdlib/zycorn.zig");

pub const xev = @import("xev");

/// Автоматически определяем версию Zig через builtin вместо хардкода
const zig_version = builtin.zig_version;

pub const version = struct {
    pub const major: u8 = 3;
    pub const minor: u8 = 13;
    pub const micro: u8 = 0;
    pub const release_level: []const u8 = "alpha";
    pub const serial: u8 = 0;

    /// Формируем строку версии динамически из builtin.zig_version
    pub fn zigVersionString(buf: []u8) []const u8 {
        const zmajor = zig_version.major;
        const zminor = zig_version.minor;
        const zpatch = zig_version.patch;
        return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ zmajor, zminor, zpatch }) catch "0.16.0";
    }

    // Pre-computed version string (static, for compile-time usage)
    pub const version_string = "3.13.0a0 Zython/0.1.0 (Zig " ++
        std.fmt.comptimePrint("{d}.{d}.{d}", .{
        zig_version.major,
        zig_version.minor,
        zig_version.patch,
    }) ++ " + libxev)";
};

pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    vm: vm.VM,
    import_sys: import_system.ImportSystem,
    gc: gc.GC,
    loop: runtime_loop.ZythonLoop,
    initialized: bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Interpreter {
        var xev_loop = try runtime_loop.ZythonLoop.init(allocator);
        errdefer xev_loop.deinit();

        var vm_instance = try vm.VM.init(allocator, &xev_loop.xev_loop);
        errdefer vm_instance.deinit();

        var import_sys = try import_system.ImportSystem.initWithIo(allocator, io);
        errdefer import_sys.deinit();

        const gc_instance = gc.GC.init(allocator);

        for (builtins.Builtins.getBuiltins()) |b| {
            const builtin_obj = try allocator.create(object.PyObject);
            builtin_obj.* = .{
                .refcnt = 1,
                .type_ptr = &object.FunctionType,
                .value = .{ .BuiltinFunction = b.func },
                .allocator = allocator,
            };
            try vm_instance.builtins.put(b.name, builtin_obj);
            try vm_instance.globals.put(b.name, builtin_obj);
        }

        // Register stdlib modules as builtin (for compatibility)
        // These are Zig implementations of CPython's C modules using libxev
        try import_sys.registerBuiltin("os", struct {
            fn init(alloc: std.mem.Allocator) anyerror!object.ObjectPtr {
                return try stdlib_os.OSModule.init(alloc);
            }
        }.init);
        try import_sys.registerBuiltin("sys", struct {
            fn init(alloc: std.mem.Allocator) anyerror!object.ObjectPtr {
                return try stdlib_sys.SysModule.init(alloc);
            }
        }.init);
        try import_sys.registerBuiltin("asyncio", struct {
            fn init(alloc: std.mem.Allocator) anyerror!object.ObjectPtr {
                return try stdlib_asyncio.AsyncioModule.init(alloc);
            }
        }.init);
        try import_sys.registerBuiltin("socket", struct {
            fn init(alloc: std.mem.Allocator) anyerror!object.ObjectPtr {
                return try stdlib_socket.SocketModule.init(alloc);
            }
        }.init);
        try import_sys.registerBuiltin("uvicorn", struct {
            fn init(alloc: std.mem.Allocator) anyerror!object.ObjectPtr {
                return try stdlib_uvicorn.UvicornModule.init(alloc);
            }
        }.init);
        try import_sys.registerBuiltin("json", struct {
            fn init(alloc: std.mem.Allocator) anyerror!object.ObjectPtr {
                return try stdlib_json.JsonModule.init(alloc);
            }
        }.init);
        try import_sys.registerBuiltin("datetime", struct {
            fn init(alloc: std.mem.Allocator) anyerror!object.ObjectPtr {
                return try stdlib_datetime.DatetimeModule.init(alloc);
            }
        }.init);
        try import_sys.registerBuiltin("math", struct {
            fn init(alloc: std.mem.Allocator) anyerror!object.ObjectPtr {
                return try stdlib_math.MathModule.init(alloc);
            }
        }.init);
        try import_sys.registerBuiltin("zycorn", struct {
            fn init(alloc: std.mem.Allocator) anyerror!object.ObjectPtr {
                return try stdlib_zycorn.ZycornModule.init(alloc);
            }
        }.init);

        // Register "zython" module — exposes Zig standard library and runtime info
        // Previously was "_zython" (with underscore) — now available as "zython"
        // Also keep "_zython" as alias for backward compat
        const zython_init = struct {
            fn init(alloc: std.mem.Allocator) anyerror!object.ObjectPtr {
                return try createZythonModule(alloc);
            }
        }.init;
        try import_sys.registerBuiltin("zython", zython_init);
        try import_sys.registerBuiltin("_zython", zython_init); // backward compat

        // Register Zig standard library modules accessible via `from zython import std`
        try import_sys.registerBuiltin("zython.std", struct {
            fn init(alloc: std.mem.Allocator) anyerror!object.ObjectPtr {
                return try createZigStdModule(alloc);
            }
        }.init);

        return .{
            .allocator = allocator,
            .io = io,
            .vm = vm_instance,
            .import_sys = import_sys,
            .gc = gc_instance,
            .loop = xev_loop,
            .initialized = true,
        };
    }

    pub fn deinit(self: *Interpreter) void {
        self.vm.deinit();
        self.import_sys.deinit();
        self.gc.deinit();
        self.loop.deinit();
    }

    pub fn execString(self: *Interpreter, source: []const u8, filename: []const u8) !object.ObjectPtr {
        var lex = lexer.Lexer.init(self.allocator, source);
        defer lex.deinit();

        var tokens: std.ArrayList(lexer.Token) = .empty;
        defer tokens.deinit(self.allocator);

        while (true) {
            const tok = try lex.nextToken();
            const is_end = tok.type == .ENDMARKER;
            try tokens.append(self.allocator, tok);
            if (is_end) break;
        }

        var pars = parser.Parser.init(self.allocator, source, tokens.items);
        defer pars.deinit();

        const mod = try pars.parseModule();

        var comp = compiler.Compiler.init(self.allocator, filename, "<module>");
        defer comp.deinit();

        const code_obj = try comp.compileModule(mod);
        const result = try self.vm.evalCode(code_obj);
        return result;
    }

    pub fn execFile(self: *Interpreter, path: []const u8) !object.ObjectPtr {
        const source = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(10 * 1024 * 1024));
        defer self.allocator.free(source);
        return try self.execString(source, path);
    }

    pub fn runEventLoop(self: *Interpreter) !void {
        try self.loop.run(.until_done);
    }
};

/// Создаёт модуль `zython` — точка доступа к возможностям Zython из Python
/// import zython  /  from zython import backend, zig_version, std
fn createZythonModule(allocator: std.mem.Allocator) !object.ObjectPtr {
    var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

    const backend = try object.PyObject.newStr(allocator, @tagName(builtin.os.tag));
    try dict.put("backend", backend);

    const zig_ver = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
        zig_version.major,
        zig_version.minor,
        zig_version.patch,
    });
    const zig_ver_obj = try object.PyObject.newStr(allocator, zig_ver);
    allocator.free(zig_ver);
    try dict.put("zig_version", zig_ver_obj);

    const xev_backend = try object.PyObject.newStr(allocator, @tagName(@import("xev").backend));
    try dict.put("xev_backend", xev_backend);

    const zython_ver = try object.PyObject.newStr(allocator, version.version_string);
    try dict.put("__version__", zython_ver);

    const no_gil = try object.PyObject.newBool(allocator, true);
    try dict.put("no_gil", no_gil);

    // Методы для доступа к Zig функциям
    const zig_bridge_fn = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = zigBridgeCall });
    try dict.put("call_zig", zig_bridge_fn);

    const mod_val = object.ModuleValue{
        .name = "zython",
        .dict = dict,
        .file = null,
    };
    return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = mod_val });
}

/// Модуль `zython.std` — доступ к встроенным библиотекам Zig
/// from zython import std
/// std.math.sqrt(4.0)
/// std.mem.eql("hello", "hello")
fn createZigStdModule(allocator: std.mem.Allocator) !object.ObjectPtr {
    var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

    // math submodule
    const math_mod = try createZigMathSubmodule(allocator);
    try dict.put("math", math_mod);

    // mem submodule
    const mem_mod = try createZigMemSubmodule(allocator);
    try dict.put("mem", mem_mod);

    // fs submodule
    const fs_mod = try createZigFsSubmodule(allocator);
    try dict.put("fs", fs_mod);

    const mod_val = object.ModuleValue{
        .name = "zython.std",
        .dict = dict,
        .file = null,
    };
    return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = mod_val });
}

fn createZigMathSubmodule(allocator: std.mem.Allocator) !object.ObjectPtr {
    var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

    const funcs = [_]struct { name: []const u8, func: object.BuiltinFn }{
        .{ .name = "sqrt", .func = zigStdSqrt },
        .{ .name = "sin", .func = zigStdSin },
        .{ .name = "cos", .func = zigStdCos },
        .{ .name = "abs", .func = zigStdAbs },
        .{ .name = "floor", .func = zigStdFloor },
        .{ .name = "ceil", .func = zigStdCeil },
        .{ .name = "log", .func = zigStdLog },
        .{ .name = "exp", .func = zigStdExp },
        .{ .name = "pow", .func = zigStdPow },
    };

    for (funcs) |f| {
        const fn_obj = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = f.func });
        try dict.put(f.name, fn_obj);
    }

    const pi = try object.PyObject.newFloat(allocator, std.math.pi);
    try dict.put("pi", pi);
    const e = try object.PyObject.newFloat(allocator, std.math.e);
    try dict.put("e", e);

    const mod_val = object.ModuleValue{ .name = "std.math", .dict = dict, .file = null };
    return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = mod_val });
}

fn createZigMemSubmodule(allocator: std.mem.Allocator) !object.ObjectPtr {
    var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

    const eql_fn = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = zigMemEql });
    try dict.put("eql", eql_fn);

    const mod_val = object.ModuleValue{ .name = "std.mem", .dict = dict, .file = null };
    return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = mod_val });
}

fn createZigFsSubmodule(allocator: std.mem.Allocator) !object.ObjectPtr {
    var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

    const read_dir_fn = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = zigFsReadDir });
    try dict.put("read_dir", read_dir_fn);

    const mod_val = object.ModuleValue{ .name = "std.fs", .dict = dict, .file = null };
    return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = mod_val });
}

// === Zig std bridge functions ===

fn zigBridgeCall(args: []*object.PyObject, allocator: std.mem.Allocator) anyerror!object.ObjectPtr {
    if (args.len == 0) return error.TypeError;
    const func_name = switch (args[0].value) {
        .Str => |s| s,
        else => return error.TypeError,
    };
    // Route to the appropriate Zig function by name
    if (std.mem.eql(u8, func_name, "version")) {
        const ver = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}", .{
            zig_version.major,
            zig_version.minor,
            zig_version.patch,
        });
        const result = try object.PyObject.newStr(allocator, ver);
        allocator.free(ver);
        return result;
    }
    return try object.PyObject.newNone(allocator);
}

fn zigStdSqrt(args: []*object.PyObject, allocator: std.mem.Allocator) anyerror!object.ObjectPtr {
    if (args.len == 0) return error.TypeError;
    const x = switch (args[0].value) {
        .Float => |f| f,
        .Int => |iv| switch (iv) { .Small => |v| @as(f64, @floatFromInt(v)), .Big => 0.0 },
        else => return error.TypeError,
    };
    return try object.PyObject.newFloat(allocator, @sqrt(x));
}

fn zigStdSin(args: []*object.PyObject, allocator: std.mem.Allocator) anyerror!object.ObjectPtr {
    if (args.len == 0) return error.TypeError;
    const x = switch (args[0].value) {
        .Float => |f| f,
        .Int => |iv| switch (iv) { .Small => |v| @as(f64, @floatFromInt(v)), .Big => 0.0 },
        else => return error.TypeError,
    };
    return try object.PyObject.newFloat(allocator, @sin(x));
}

fn zigStdCos(args: []*object.PyObject, allocator: std.mem.Allocator) anyerror!object.ObjectPtr {
    if (args.len == 0) return error.TypeError;
    const x = switch (args[0].value) {
        .Float => |f| f,
        .Int => |iv| switch (iv) { .Small => |v| @as(f64, @floatFromInt(v)), .Big => 0.0 },
        else => return error.TypeError,
    };
    return try object.PyObject.newFloat(allocator, @cos(x));
}

fn zigStdAbs(args: []*object.PyObject, allocator: std.mem.Allocator) anyerror!object.ObjectPtr {
    if (args.len == 0) return error.TypeError;
    return switch (args[0].value) {
        .Float => |f| try object.PyObject.newFloat(allocator, @abs(f)),
        .Int => |iv| switch (iv) {
            .Small => |v| try object.PyObject.newInt(allocator, if (v < 0) -v else v),
            .Big => try object.PyObject.newInt(allocator, 0),
        },
        else => error.TypeError,
    };
}

fn zigStdFloor(args: []*object.PyObject, allocator: std.mem.Allocator) anyerror!object.ObjectPtr {
    if (args.len == 0) return error.TypeError;
    const x = switch (args[0].value) {
        .Float => |f| f,
        .Int => |iv| switch (iv) { .Small => |v| @as(f64, @floatFromInt(v)), .Big => 0.0 },
        else => return error.TypeError,
    };
    return try object.PyObject.newFloat(allocator, @floor(x));
}

fn zigStdCeil(args: []*object.PyObject, allocator: std.mem.Allocator) anyerror!object.ObjectPtr {
    if (args.len == 0) return error.TypeError;
    const x = switch (args[0].value) {
        .Float => |f| f,
        .Int => |iv| switch (iv) { .Small => |v| @as(f64, @floatFromInt(v)), .Big => 0.0 },
        else => return error.TypeError,
    };
    return try object.PyObject.newFloat(allocator, @ceil(x));
}

fn zigStdLog(args: []*object.PyObject, allocator: std.mem.Allocator) anyerror!object.ObjectPtr {
    if (args.len == 0) return error.TypeError;
    const x = switch (args[0].value) {
        .Float => |f| f,
        .Int => |iv| switch (iv) { .Small => |v| @as(f64, @floatFromInt(v)), .Big => 0.0 },
        else => return error.TypeError,
    };
    return try object.PyObject.newFloat(allocator, @log(x));
}

fn zigStdExp(args: []*object.PyObject, allocator: std.mem.Allocator) anyerror!object.ObjectPtr {
    if (args.len == 0) return error.TypeError;
    const x = switch (args[0].value) {
        .Float => |f| f,
        .Int => |iv| switch (iv) { .Small => |v| @as(f64, @floatFromInt(v)), .Big => 0.0 },
        else => return error.TypeError,
    };
    return try object.PyObject.newFloat(allocator, @exp(x));
}

fn zigStdPow(args: []*object.PyObject, allocator: std.mem.Allocator) anyerror!object.ObjectPtr {
    if (args.len < 2) return error.TypeError;
    const x = switch (args[0].value) {
        .Float => |f| f,
        .Int => |iv| switch (iv) { .Small => |v| @as(f64, @floatFromInt(v)), .Big => 0.0 },
        else => return error.TypeError,
    };
    const y = switch (args[1].value) {
        .Float => |f| f,
        .Int => |iv| switch (iv) { .Small => |v| @as(f64, @floatFromInt(v)), .Big => 0.0 },
        else => return error.TypeError,
    };
    return try object.PyObject.newFloat(allocator, std.math.pow(f64, x, y));
}

fn zigMemEql(args: []*object.PyObject, allocator: std.mem.Allocator) anyerror!object.ObjectPtr {
    if (args.len < 2) return error.TypeError;
    const a = switch (args[0].value) { .Str => |s| s, else => return error.TypeError };
    const b = switch (args[1].value) { .Str => |s| s, else => return error.TypeError };
    return try object.PyObject.newBool(allocator, std.mem.eql(u8, a, b));
}

fn zigFsReadDir(args: []*object.PyObject, allocator: std.mem.Allocator) anyerror!object.ObjectPtr {
    _ = args;
    // Returns a list of entries (simplified — returns empty list for now)
    return try object.PyObject.newList(allocator);
}

test "interpreter init" {
    var interp = try Interpreter.init(std.testing.allocator, std.testing.io);
    defer interp.deinit();
    try std.testing.expect(interp.initialized);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(object);
    std.testing.refAllDecls(lexer);
    std.testing.refAllDecls(compiler);
    std.testing.refAllDecls(vm);
    std.testing.refAllDecls(runtime_loop);
}
