//! Zython CLI — аналог Programs/python.c и Modules/main.c
//! Точка входа интерпретатора
//! Zig 0.16.0 — использует std.process.Init API

const std = @import("std");
const builtin = @import("builtin");
const zython = @import("zython");
const xev = @import("xev");

const version_string = zython.version.version_string;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    var args_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (args_list.items) |a| allocator.free(a);
        args_list.deinit(allocator);
    }

    while (args_iter.next()) |arg| {
        const duped = try allocator.dupe(u8, arg);
        try args_list.append(allocator, duped);
    }

    const args = args_list.items;

    if (args.len <= 1) {
        try runRepl(allocator, io);
        return;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            const zver = builtin.zig_version;
            std.debug.print("Zython {s}\n", .{version_string});
            std.debug.print("Zig {d}.{d}.{d} + libxev async runtime ({s} backend)\n", .{
                zver.major,
                zver.minor,
                zver.patch,
                @tagName(xev.backend),
            });
            std.debug.print("Compatible with Python 3.13+\n", .{});
            std.debug.print("Platform: {s}-{s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Argument expected for -c option\n", .{});
                return error.InvalidArgs;
            }
            const code = args[i];
            try runCodeString(allocator, io, code);
            return;
        } else if (std.mem.eql(u8, arg, "--dis")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("File expected for --dis\n", .{});
                return;
            }
            try disassembleFile(allocator, io, args[i]);
            return;
        } else if (std.mem.eql(u8, arg, "--ast")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("File expected for --ast\n", .{});
                return;
            }
            try dumpAst(allocator, io, args[i]);
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printHelp();
            return;
        } else {
            try runFile(allocator, io, arg);
            return;
        }
    }
}

fn printHelp() void {
    std.debug.print(
        \\Zython - Python implementation in Zig with libxev async
        \\Usage: zython [option] ... [-c cmd | -m mod | file | - ] [arg] ...
        \\Options:
        \\  -h, --help     Show this help
        \\  -V, --version  Show version
        \\  -c cmd         Program passed as string
        \\  --dis file     Disassemble Python file to bytecode
        \\  --ast file     Dump AST of Python file
        \\
        \\Zython features:
        \\  - Compatible with Python 3.13+ syntax
        \\  - Built-in async via libxev (io_uring, kqueue, IOCP)
        \\  - No GIL needed (libxev thread pool)
        \\  - Zig standard library accessible via `from zython import std`
        \\  - Cross-platform: Linux, macOS, Windows, FreeBSD
        \\
        \\Examples:
        \\  zython script.py
        \\  zython -c "print('hello Zython')"
        \\  zython --version
        \\
    , .{});
}

fn runRepl(allocator: std.mem.Allocator, io: std.Io) !void {
    std.debug.print("Zython {s} on {s}-{s}\n", .{ version_string, @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    std.debug.print("Type \"help\", \"copyright\", \"credits\" or \"license\" for more information.\n", .{});
    std.debug.print(">>> libxev backend: {s}, no GIL\n", .{@tagName(xev.backend)});

    var interp = try zython.Interpreter.init(allocator, io);
    defer interp.deinit();

    var buf: [4096]u8 = undefined;
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var stdin_interface = &stdin_reader.interface;

    while (true) {
        std.debug.print(">>> ", .{});
        const line = stdin_interface.takeDelimiterInclusive('\n') catch {
            std.debug.print("\n", .{});
            break;
        };

        const len = @min(line.len, buf.len - 1);
        @memcpy(buf[0..len], line[0..len]);
        const trimmed = std.mem.trim(u8, buf[0..len], " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "exit()") or std.mem.eql(u8, trimmed, "quit()") or std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
            break;
        }

        const result = interp.execString(trimmed, "<stdin>") catch |err| {
            std.debug.print("Error: {any}\n", .{err});
            continue;
        };
        defer result.decref();

        if (result.value != .None) {
            const repr = result.repr(allocator) catch continue;
            defer allocator.free(repr);
            std.debug.print("{s}\n", .{repr});
        }
    }
}

fn runFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    std.debug.print("[Zython] Executing file: {s}\n", .{path});

    var interp = try zython.Interpreter.init(allocator, io);
    defer interp.deinit();

    std.debug.print("[Zython] libxev backend: {s}\n", .{@tagName(xev.backend)});

    const result = interp.execFile(path) catch |err| {
        std.debug.print("[Zython] Runtime error: {any}\n", .{err});
        if (interp.vm.last_exception) |exc| {
            const repr = exc.repr(allocator) catch "unknown";
            defer allocator.free(repr);
            std.debug.print("Exception: {s}\n", .{repr});
        }
        return err;
    };
    defer result.decref();

    std.debug.print("[Zython] Execution completed\n", .{});

    if (interp.loop.task_queue.items.len > 0) {
        std.debug.print("[Zython] Running pending async tasks via libxev ({d} tasks)\n", .{interp.loop.task_queue.items.len});
        try interp.runEventLoop();
    }

    if (result.value != .None) {
        const repr = result.repr(allocator) catch "None";
        defer allocator.free(repr);
        std.debug.print("Result: {s}\n", .{repr});
    }
}

fn runCodeString(allocator: std.mem.Allocator, io: std.Io, code: []const u8) !void {
    std.debug.print("[Zython] Executing: {s}\n", .{code});

    var interp = try zython.Interpreter.init(allocator, io);
    defer interp.deinit();

    const result = try interp.execString(code, "<string>");
    defer result.decref();

    if (result.value != .None) {
        const repr = try result.repr(allocator);
        defer allocator.free(repr);
        std.debug.print("{s}\n", .{repr});
    }
}

fn disassembleFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const file_content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(file_content);

    var lex = zython.lexer.Lexer.init(allocator, file_content);
    defer lex.deinit();

    var tokens: std.ArrayList(zython.lexer.Token) = .empty;
    defer tokens.deinit(allocator);

    while (true) {
        const tok = try lex.nextToken();
        const is_end = tok.type == .ENDMARKER;
        try tokens.append(allocator, tok);
        if (is_end) break;
    }

    var pars = zython.parser.Parser.init(allocator, file_content, tokens.items);
    defer pars.deinit();

    const mod = try pars.parseModule();

    var comp = zython.compiler.Compiler.init(allocator, path, "<module>");
    defer comp.deinit();

    const code_obj = try comp.compileModule(mod);

    std.debug.print("Disassembly of {s}:\n", .{path});
    std.debug.print("File: {s}, Name: {s}\n", .{ code_obj.filename, code_obj.name });
    std.debug.print("Consts: {d}, Names: {d}, Varnames: {d}\n", .{ code_obj.consts.len, code_obj.names.len, code_obj.varnames.len });

    for (code_obj.consts, 0..) |c, idx| {
        const r = try c.repr(allocator);
        defer allocator.free(r);
        std.debug.print("  const {d}: {s} ({s})\n", .{ idx, r, c.type_ptr.name });
    }

    std.debug.print("\nBytecode ({d} bytes):\n", .{code_obj.code.len});
    var pc: usize = 0;
    while (pc + 2 < code_obj.code.len) {
        const op_byte = code_obj.code[pc];
        const op: zython.opcode.Opcode = @enumFromInt(op_byte);
        const arg_lo = code_obj.code[pc + 1];
        const arg_hi = code_obj.code[pc + 2];
        const arg = @as(u16, arg_lo) | (@as(u16, arg_hi) << 8);
        std.debug.print("  {d:4}: {s:30} {d}", .{ pc, op.toString(), arg });

        if (op == .LOAD_CONST and arg < code_obj.consts.len) {
            const r = try code_obj.consts[arg].repr(allocator);
            defer allocator.free(r);
            std.debug.print(" ({s})", .{r});
        } else if ((op == .LOAD_NAME or op == .STORE_NAME or op == .LOAD_GLOBAL) and arg < code_obj.names.len) {
            std.debug.print(" ({s})", .{code_obj.names[arg]});
        }

        std.debug.print("\n", .{});
        pc += 3;
    }
}

fn dumpAst(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(source);

    var lex = zython.lexer.Lexer.init(allocator, source);
    defer lex.deinit();

    var tokens: std.ArrayList(zython.lexer.Token) = .empty;
    defer tokens.deinit(allocator);

    std.debug.print("Tokens for {s}:\n", .{path});
    while (true) {
        const tok = try lex.nextToken();
        std.debug.print("  {s}: '{s}' at {d}:{d}\n", .{ @tagName(tok.type), tok.string, tok.start.lineno, tok.start.col });
        const is_end = tok.type == .ENDMARKER;
        try tokens.append(allocator, tok);
        if (is_end) break;
    }

    var pars = zython.parser.Parser.init(allocator, source, tokens.items);
    defer pars.deinit();

    const mod = pars.parseModule() catch |err| {
        std.debug.print("Parse error: {any}\n", .{err});
        return;
    };

    std.debug.print("\nAST ({d} statements):\n", .{mod.body.len});
    for (mod.body, 0..) |stmt, idx| {
        std.debug.print("  stmt {d}: {s} at line {d}\n", .{ idx, @tagName(stmt.node), stmt.lineno });
    }
}
