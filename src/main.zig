//! Zython CLI — аналог Programs/python.c / Modules/main.c.
//! zig 0.16: точка входа через std.process.Init.

const std = @import("std");
const builtin = @import("builtin");
const zython = @import("zython");
const xev = @import("xev");

const object = zython.object;
const VM = zython.vm_mod.VM;
const Obj = object.Obj;

var exit_code: u8 = 0;

pub fn main(init: std.process.Init) !void {
    // Backing-аллокатор интерпретатора. В Debug init.gpa — DebugAllocator с отчётами
    // об утечках; интерпретатор освобождает память оптом (арена в Runtime), поэтому
    // используем c_allocator (у нас всегда link_libc: см. build.zig).
    const allocator: std.mem.Allocator = if (builtin.link_libc) std.heap.c_allocator else init.gpa;
    const io = init.io;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();
    var args_list: std.ArrayList([]const u8) = .empty;
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, try allocator.dupe(u8, arg));
    }
    const args = args_list.items;

    const interp = try zython.Interpreter.init(allocator, io);

    var i: usize = 1;
    var script: ?[]const u8 = null;
    var cmd: ?[]const u8 = null;
    var module: ?[]const u8 = null;
    var dump_src: ?[]const u8 = null;
    var quiet = false;
    var inspect_after = false;
    var version_level: u8 = 0;

    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-c")) {
            i += 1;
            if (i >= args.len) fatal("Argument expected for the -c option", .{});
            cmd = args[i];
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "-d")) {
            i += 1;
            if (i >= args.len) fatal("Argument expected for the -d option", .{});
            dump_src = args[i];
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "-m")) {
            i += 1;
            if (i >= args.len) fatal("Argument expected for the -m option", .{});
            module = args[i];
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "-?") or std.mem.eql(u8, a, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, a, "--help-env")) {
            printHelpEnv();
            return;
        } else if (std.mem.eql(u8, a, "--help-xoptions")) {
            printHelpXOptions();
            return;
        } else if (std.mem.eql(u8, a, "--help-all")) {
            printHelp();
            printHelpEnv();
            printHelpXOptions();
            return;
        } else if (std.mem.eql(u8, a, "-V") or std.mem.eql(u8, a, "--version")) {
            version_level = @max(version_level, 1);
        } else if (std.mem.eql(u8, a, "-VV")) {
            version_level = @max(version_level, 2);
        } else if (std.mem.eql(u8, a, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "-i")) {
            inspect_after = true;
        } else if (std.mem.eql(u8, a, "-b") or std.mem.eql(u8, a, "-bb") or
            std.mem.eql(u8, a, "-B") or std.mem.eql(u8, a, "-E") or
            std.mem.eql(u8, a, "-I") or std.mem.eql(u8, a, "-P") or
            std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "-S") or
            std.mem.eql(u8, a, "-u") or std.mem.eql(u8, a, "-v") or
            std.mem.eql(u8, a, "-vv") or std.mem.eql(u8, a, "-O") or
            std.mem.eql(u8, a, "-OO") or std.mem.eql(u8, a, "-x")) {
        } else if (std.mem.eql(u8, a, "-W") or std.mem.eql(u8, a, "-X")) {
            i += 1;
            if (i >= args.len) fatal("Argument expected for option {s}", .{a});
        } else if (a.len > 0 and a[0] == '-') {
            fatal("Unknown option: {s}", .{a});
        } else {
            script = a;
            i += 1;
            break;
        }
    }

    if (version_level != 0) {
        printVersion(version_level >= 2);
        return;
    }

    // sys.argv = остаток
    interp.rt.argv = args[i..];
    if (script) |s| {
        interp.rt.argv = blk: {
            var av: std.ArrayList([]const u8) = .empty;
            try av.append(allocator, s);
            try av.appendSlice(allocator, args[i..]);
            break :blk av.items;
        };
    }

    if (dump_src != null) {
        dumpGuarded(interp, dump_src.?);
    } else if (cmd) |c| {
        runGuarded(interp, c, "<string>");
        if (inspect_after and exit_code == 0) try repl(interp, io, quiet);
    } else if (module) |m| {
        const import_mod = zython.import_mod;
        _ = import_mod.loadModule(interp.vmm, m) catch |e| {
            handleError(interp.vmm, e);
        };
        if (inspect_after and exit_code == 0) try repl(interp, io, quiet);
    } else if (script) |s| {
        interp.runFile(s) catch |e| {
            handleError(interp.vmm, e);
        };
        if (inspect_after and exit_code == 0) try repl(interp, io, quiet);
    } else {
        try repl(interp, io, quiet);
    }
    interp.rt.outFlush();
    std.process.exit(exit_code);
}

fn printVersion(verbose: bool) void {
    std.debug.print("Zython {s} (compatible with Python 3.14.6)\n", .{zython.version_string});
    if (verbose) {
        std.debug.print("build: Zig {d}.{d}.{d}, libxev backend: {s}, os: {s}, arch: {s}\n", .{
            builtin.zig_version.major,
            builtin.zig_version.minor,
            builtin.zig_version.patch,
            @tagName(xev.backend),
            @tagName(builtin.os.tag),
            @tagName(builtin.cpu.arch),
        });
    }
}

fn printHelp() void {
    const help =
        \\usage: zython [option] ... [-c cmd | -m mod | file | -] [arg] ...
        \\
        \\Options (CPython-compatible CLI surface, semantics still being filled in):
        \\ -b     : issue warnings about str(bytes_instance), str(bytearray_instance)
        \\          and comparing bytes/bytearray with str; -bb turns warnings into errors
        \\ -B     : don't write .pyc files on import
        \\ -c cmd : program passed in as string (terminates option list)
        \\ -d     : dump compiled bytecode for given source snippet (Zython extension)
        \\ -E     : ignore PYTHON* environment variables
        \\ -h     : print this help message and exit (also -? or --help)
        \\ -i     : inspect interactively after running script
        \\ -I     : isolate from the user's environment (implies -E, -P and -s in CPython)
        \\ -m mod : run library module as a script (terminates option list)
        \\ -O     : optimization level 1
        \\ -OO    : optimization level 2
        \\ -P     : don't prepend a potentially unsafe path to sys.path
        \\ -q     : don't print version/copyright banner on interactive startup
        \\ -s     : don't add user site directory to sys.path
        \\ -S     : don't imply 'import site' on initialization
        \\ -u     : force stdout and stderr streams to be unbuffered
        \\ -v     : verbose import tracing; can be supplied more than once
        \\ -V     : print the version number and exit (also --version)
        \\ -VV    : print extended build information and exit
        \\ -W arg : warning control
        \\ -x     : skip first line of source
        \\ -X opt : set implementation-specific option
        \\ --check-hash-based-pycs always|default|never
        \\ --help-env      : print help about Python environment variables and exit
        \\ --help-xoptions : print help about implementation-specific -X options and exit
        \\ --help-all      : print complete help information and exit
        \\
        \\Arguments:
        \\ file   : program read from script file
        \\ -      : program read from stdin
        \\ arg ...: arguments passed to program in sys.argv[1:]
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn printHelpEnv() void {
    const help =
        \\Environment variables (subset documented for CPython-compatible CLI):
        \\ PYTHONPATH              : module search path prefix
        \\ PYTHONHOME              : alternate <prefix> directory
        \\ PYTHONINSPECT           : enter interactive mode after running a script
        \\ PYTHONDONTWRITEBYTECODE : disable .pyc writes
        \\ PYTHONUNBUFFERED        : unbuffer stdout/stderr
        \\ PYTHONVERBOSE           : verbose import tracing
        \\ PYTHONWARNINGS          : warning filter configuration
        \\ PYTHONOPTIMIZE          : optimization level
        \\ PYTHONSAFEPATH          : safe-path mode
        \\ PYTHONNOUSERSITE        : disable user site-packages
        \\ PYTHONDEVMODE           : development mode
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn printHelpXOptions() void {
    const help =
        \\Implementation-specific -X options accepted or planned for CPython compatibility:
        \\ -X dev
        \\ -X utf8[=0|1]
        \\ -X importtime
        \\ -X pycache_prefix=PATH
        \\ -X warn_default_encoding
        \\ -X no_debug_ranges
        \\ -X frozen_modules=[on|off]
        \\ -X perf
        \\ -X perf_jit
        \\
        \\Zython note: parsing compatibility comes first; semantics are being implemented incrementally.
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn fatal(comptime fmt: []const u8, a: anytype) noreturn {
    std.debug.print("zython: " ++ fmt ++ "\n", a);
    std.process.exit(2);
}

fn runGuarded(interp: *zython.Interpreter, src: []const u8, filename: []const u8) void {
    interp.runSource(src, filename) catch |e| {
        handleError(interp.vmm, e);
    };
}

fn handleError(v: *VM, e: anyerror) void {
    if (e != error.PyExc) {
        std.debug.print("zython internal error: {s}\n", .{@errorName(e)});
        exit_code = 1;
        return;
    }
    printUncaught(v);
}

/// Печать необработанного исключения (analog Python/pythonrun.c:PyErr_PrintEx).
pub fn printUncaught(v: *VM) void {
    const ts = v.currentTS();
    const exc = ts.cur_exc orelse {
        std.debug.print("(unprintable error)\n", .{});
        exit_code = 1;
        return;
    };
    ts.cur_exc = null;
    v.rt.outFlush();

    // SystemExit — особый случай: код выхода, без traceback
    {
        const se_t = v.excType("SystemExit");
        if (zython.ops.isSubclass(exc.ty, se_t)) {
            const e = exc.v.exc;
            if (e.args.len == 0) {
                std.process.exit(0);
            }
            const a = e.args[0];
            if (a.v == .int) {
                std.process.exit(@intCast(@as(u32, @truncate(@as(u64, @bitCast(a.v.int)))) & 0xff));
            }
            if (a.v != .none) {
                const s = zython.ops.pyStr(v, a) catch return;
                v.rt.errWrite(s.v.str.bytes);
                v.rt.errWrite("\n");
                std.process.exit(1);
            }
            std.process.exit(0);
        }
    }

    var buf: std.ArrayList(u8) = .empty;
    const g = v.rt.gpa;
    buf.appendSlice(g, "Traceback (most recent call last):\n") catch {};
    if (exc.v == .exc) {
        const e = exc.v.exc;
        for (e.tb.items) |frame| {
            buf.print(g, "  File \"{s}\", line {d}, in {s}\n", .{ frame.filename, frame.lineno, frame.name }) catch {};
        }
        // Type: message
        buf.appendSlice(g, exc.ty.name) catch {};
        const msg = zython.ops.pyStr(v, exc) catch blk: {
            break :blk v.rt.newStr("") catch return;
        };
        if (msg.v.str.bytes.len > 0) {
            buf.appendSlice(g, ": ") catch {};
            buf.appendSlice(g, msg.v.str.bytes) catch {};
        }
        buf.appendSlice(g, "\n") catch {};
        // cause / context
        if (e.cause) |cause| {
            buf.appendSlice(g, "\nThe above exception was the direct cause of the following exception:\n\n") catch {};
            _ = cause;
        }
    } else {
        buf.print(g, "{s}\n", .{exc.ty.name}) catch {};
    }
    v.rt.errWrite(buf.items);
    exit_code = 1;
}

// ============================================================
// REPL
// ============================================================

fn repl(interp: *zython.Interpreter, io: std.Io, quiet: bool) !void {
    _ = io;
    const rt = interp.rt;
    const v = interp.vmm;
    if (!quiet) {
        rt.outWrite("Zython ");
        rt.outWrite(zython.version_string);
        rt.outWrite(" on ");
        rt.outWrite(@tagName(builtin.os.tag));
        rt.outWrite("\nType \"help\", \"copyright\", \"credits\" or \"license\" for more information.\n");
        rt.outFlush();
    }
    // общие globals для сессии
    const main_mod = try rt.newModuleObj("__main__");
    try zython.import_mod.sysModulesPut(v, "__main__", main_mod);
    const md = main_mod.v.module;
    try zython.ops.dictSetStr(md.dict, v, "__name__", try rt.newStr("__main__"));
    try zython.ops.dictSetStr(md.dict, v, "__builtins__", try rt.mkObj(rt.dict_t, .{ .dict = rt.builtins_dict }));
    while (true) {
        rt.outWrite(">>> ");
        rt.outFlush();
        const line = try rt.inReadLine();
        if (line.len == 0) break; // EOF
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        // сначала — как выражение (печать результата как в CPython REPL)
        const code_e = zython.compiler.compileSource(v, "<stdin>", trimmed, .eval) catch null;
        if (code_e) |code| {
            const fnobj = try rt.newFunction("<module>", "<module>", code, md.dict, &.{}, &.{}, null);
            const frame = try v.makeFrame(fnobj.v.function, &.{}, null);
            frame.locals_dict = md.dict;
            const ts = v.currentTS();
            const mark = ts.frames.items.len;
            try ts.frames.append(v.gpa, frame);
            v.runUntil(ts, mark) catch |e| {
                handleError(v, e);
                continue;
            };
            const rv = ts.return_value orelse rt.newNone();
            ts.return_value = null;
            if (rv.v != .none) {
                const r = try zython.ops.pyRepr(v, rv);
                rt.outWrite(r.v.str.bytes);
                rt.outWrite("\n");
                rt.outFlush();
            }
            continue;
        }
        v.currentTS().cur_exc = null;
        // иначе — как стейтмент(ы)
        interp.runSource(trimmed, "<stdin>") catch |e| {
            handleError(v, e);
        };
    }
    rt.outWrite("\n");
}

// ============================================================
// Дизассемблер для отладки компилятора (-d "code")
// ============================================================

fn dumpGuarded(interp: *zython.Interpreter, src: []const u8) void {
    dumpSource(interp, src) catch |e| {
        handleError(interp.vmm, e);
    };
}

fn dumpSource(interp: *zython.Interpreter, src: []const u8) !void {
    const v = interp.vmm;
    const code = try zython.compiler.compileSource(v, "<dump>", src, .exec);
    var out: std.ArrayList(u8) = .empty;
    try dumpCode(interp, code, 0, &out);
    interp.rt.outWrite(out.items);
    interp.rt.outFlush();
}

fn dumpCode(interp: *zython.Interpreter, code: *object.Code, depth: usize, out: *std.ArrayList(u8)) anyerror!void {
    const g = interp.rt.gpa;
    var d: usize = 0;
    while (d < depth) : (d += 1) try out.appendSlice(g, "  ");
    try out.print(g, "== {s} (line {d}, locals={d}, stack={d}) ==\n", .{ code.qualname, code.firstlineno, code.nlocals, code.stacksize });
    var pc: usize = 0;
    while (pc < code.code.len) {
        const op: zython.opcode.Opcode = @enumFromInt(code.code[pc]);
        const arg: u16 = @as(u16, code.code[pc + 1]) | (@as(u16, code.code[pc + 2]) << 8);
        d = 0;
        while (d < depth) : (d += 1) try out.appendSlice(g, "  ");
        try out.print(g, "{d:4}: {s:32} {d}\n", .{ pc, @tagName(op), arg });
        pc += 3;
    }
    try out.appendSlice(g, "  consts:");
    for (code.consts) |c| {
        switch (c.v) {
            .code => try out.appendSlice(g, " <code>"),
            .int => |iv| try out.print(g, " {d}", .{iv}),
            .str => |s| try out.print(g, " '{s}'", .{s.bytes}),
            .tuple => try out.appendSlice(g, " <tuple>"),
            .none => try out.appendSlice(g, " None"),
            .bool_ => |b| try out.print(g, " {}", .{b}),
            else => try out.appendSlice(g, " ?"),
        }
    }
    try out.appendSlice(g, "\n");
    for (code.consts) |c| {
        if (c.v == .code) try dumpCode(interp, c.v.code, depth + 1, out);
    }
}
