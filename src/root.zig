//! Zython — Python-интерпретатор на Zig 0.16 (+ libxev для async-этапа).
//! root.zig — сборка интерпретатора (аналог Python/pylifecycle.c).

pub const object = @import("object/object.zig");
pub const opcode = @import("vm/opcode.zig");
pub const ops = @import("vm/ops.zig");
pub const vm_mod = @import("vm/vm.zig");
pub const lexer = @import("parser/lexer.zig");
pub const ast = @import("parser/ast.zig");
pub const parser = @import("parser/parser.zig");
pub const compiler = @import("compiler/compiler.zig");
pub const runtime_mod = @import("runtime/runtime.zig");
pub const builtins = @import("runtime/builtins.zig");
pub const import_mod = @import("runtime/import.zig");

const std = @import("std");
const Runtime = runtime_mod.Runtime;
const VM = vm_mod.VM;

pub const version_string = "3.14.6";

pub const Interpreter = struct {
    rt: *Runtime,
    vmm: *VM,

    pub fn init(backing: std.mem.Allocator, io: std.Io) !*Interpreter {
        const rt = try Runtime.init(backing, io);
        try rt.setupIo(io);
        try builtins.registerAll(rt);
        // нативные модули stdlib
        const sys_mod = @import("stdlib/sys.zig");
        const math_mod = @import("stdlib/math.zig");
        const time_mod = @import("stdlib/time.zig");
        const errno_mod = @import("stdlib/errno.zig");
        const os_mod = @import("stdlib/os.zig");
        const io_mod = @import("stdlib/io.zig");
        const json_mod = @import("stdlib/json.zig");
        const functools_mod = @import("stdlib/functools.zig");
        const warnings_mod = @import("stdlib/warnings.zig");
        const future_mod = @import("stdlib/__future__.zig");
        const logging_mod = @import("stdlib/logging.zig");
        const typing_mod = @import("stdlib/typing.zig");
        const socket_mod = @import("stdlib/socket.zig");
        const email_mod = @import("stdlib/email.zig");
        const httpclient_mod = @import("stdlib/http_client.zig");
        const zython_std_mod = @import("stdlib/zython_std.zig");
        import_mod.native_modules = &.{
            .{ .name = "sys", .init = sys_mod.initModule },
            .{ .name = "math", .init = math_mod.initModule },
            .{ .name = "time", .init = time_mod.initModule },
            .{ .name = "errno", .init = errno_mod.initModule },
            .{ .name = "os", .init = os_mod.initModule },
            .{ .name = "io", .init = io_mod.initModule },
            .{ .name = "json", .init = json_mod.initModule },
            .{ .name = "functools", .init = functools_mod.initModule },
            .{ .name = "warnings", .init = warnings_mod.initModule },
            .{ .name = "__future__", .init = future_mod.initModule },
            .{ .name = "logging", .init = logging_mod.initModule },
            .{ .name = "typing", .init = typing_mod.initModule },
            .{ .name = "socket", .init = socket_mod.initModule },
            .{ .name = "email", .init = email_mod.initModule },
            .{ .name = "email.errors", .init = email_mod.initErrors },
            .{ .name = "email.utils", .init = email_mod.initUtils },
            .{ .name = "http", .init = httpclient_mod.initPackage },
            .{ .name = "http.client", .init = httpclient_mod.initModule },
            .{ .name = "zython", .init = zython_std_mod.initPackage },
            .{ .name = "zython.std", .init = zython_std_mod.initStdPackage },
            .{ .name = "zython.std.io", .init = zython_std_mod.initIoModule },
        };
        // lib-директория (vendored stdlib): <dir-of-exe>/lib/python3.14
        rt.lib_dir = findLibDir(rt) catch null;
        const vmm = try VM.init(rt);
        vmm.gilAcquire();
        const self = try rt.gpa.create(Interpreter);
        self.* = .{ .rt = rt, .vmm = vmm };
        return self;
    }

    /// Выполнить исходник как модуль __main__.
    pub fn runSource(self: *Interpreter, source: []const u8, filename: []const u8) !void {
        const v = self.vmm;
        const code = compiler.compileSource(v, filename, source, .exec) catch |e| {
            return e;
        };
        const main_mod = try v.rt.newModuleObj("__main__");
        const import_zig = @import("runtime/import.zig");
        try import_zig.sysModulesPut(v, "__main__", main_mod);
        const md = main_mod.v.module;
        try ops.dictSetStr(md.dict, v, "__name__", try v.rt.newStr("__main__"));
        try ops.dictSetStr(md.dict, v, "__builtins__", try v.rt.mkObj(v.rt.dict_t, .{ .dict = v.rt.builtins_dict }));
        try ops.dictSetStr(md.dict, v, "__package__", v.rt.newNone());
        try v.runNameScope(code, md.dict, null);
    }

    pub fn runFile(self: *Interpreter, path: []const u8) !void {
        const v = self.vmm;
        const src = try import_mod.readFileAlloc(v, path);
        try self.runSource(src, path);
    }

    fn findLibDir(rt: *Runtime) !?[]const u8 {
        // рядом с бинарём: <exe_dir>/lib/python3.14
        // полный путь себя — через std.Io.selfExePath не существует; используем /proc/self/exe на posix,
        // на windows — GetModuleFileName. std.Io 0.16: std.Io.Dir.selfExePath? Нет — используем
        // относительный lib/python3.14 от cwd как fallback.
        _ = rt;
        return "lib/python3.14";
    }
};
