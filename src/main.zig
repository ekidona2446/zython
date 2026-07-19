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
    // разобрать опции
    var script: ?[]const u8 = null;
    var cmd: ?[]const u8 = null;
    var module: ?[]const u8 = null;
    var dump_src: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-V")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printHelp();
            return;
        } else if (a.len > 0 and a[0] == '-') {
            fatal("Unknown option: {s}", .{a});
        } else {
            script = a;
            i += 1;
            break;
        }
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
    } else if (module) |m| {
        const import_mod = zython.import_mod;
        _ = import_mod.loadModule(interp.vmm, m) catch |e| {
            handleError(interp.vmm, e);
        };
    } else if (script) |s| {
        interp.runFile(s) catch |e| {
            handleError(interp.vmm, e);
        };
    } else {
        try repl(interp, io);
    }
    interp.rt.outFlush();
    std.process.exit(exit_code);
}

fn printVersion() void {
    std.debug.print("Zython {s} (compatible with Python 3.14.6)\n", .{zython.version_string});
    std.debug.print("Zig {d}.{d}.{d}, libxev backend: {s}\n", .{
        builtin.zig_version.major,
        builtin.zig_version.minor,
        builtin.zig_version.patch,
        @tagName(xev.backend),
    });
}

fn printHelp() void {
    const help =
        \\usage: zython [option] ... [-c cmd | -m mod | file | -] [arg] ...
        \\Options:
        \\  -c cmd   : Program passed as string
        \\  -m mod   : Run module as __main__
        \\  -V, --version : Show version
        \\  -h, --help    : Show this help
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

fn repl(interp: *zython.Interpreter, io: std.Io) !void {
    _ = io;
    const rt = interp.rt;
    const v = interp.vmm;
    rt.outWrite("Zython ");
    rt.outWrite(zython.version_string);
    rt.outWrite(" on ");
    rt.outWrite(@tagName(builtin.os.tag));
    rt.outWrite("\nType \"help\", \"copyright\", \"credits\" or \"license\" for more information.\n");
    rt.outFlush();
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
