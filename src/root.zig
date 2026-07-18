//! Zython - Python интерпретатор на Zig с libxev async

const std = @import("std");
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
pub const stdlib_zycorn = @import("stdlib/http/zycorn.zig");

pub const xev = @import("xev");

pub const version = struct {
    pub const major: u8 = 3;
    pub const minor: u8 = 12;
    pub const micro: u8 = 0;
    pub const release_level: []const u8 = "alpha";
    pub const serial: u8 = 0;
    pub const version_string = "3.12.0a0 Zython/0.1.0 (Zig 0.16.0 + libxev)";
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
        // Also register _zython builtin
        try import_sys.registerBuiltin("_zython", struct {
            fn init(alloc: std.mem.Allocator) anyerror!object.ObjectPtr {
                var dict = std.StringHashMap(object.ObjectPtr).init(alloc);
                const ver = try object.PyObject.newStr(alloc, "Zython 0.1.0 + libxev io_uring");
                try dict.put("backend", ver);
                const mod_val = object.ModuleValue{
                    .name = "_zython",
                    .dict = dict,
                    .file = null,
                };
                return try object.PyObject.create(alloc, &object.ModuleType, .{ .Module = mod_val });
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
        // Zig 0.16: use Io.Dir.cwd().readFileAlloc
        const source = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(10 * 1024 * 1024));
        defer self.allocator.free(source);
        return try self.execString(source, path);
    }

    pub fn runEventLoop(self: *Interpreter) !void {
        try self.loop.run(.until_done);
    }
};

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
