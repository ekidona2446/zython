//! re — аналог Lib/re + Modules/_sre, на чистом Zig (regex_engine), без C.
//! API: compile/match/search/findall/finditer/sub/subn/split/fullmatch/escape,
//!      Pattern/Match объекты, флаги, error.

const std = @import("std");
const object = @import("../object/object.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const regex = @import("regex_engine.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;
const KwArgs = object.KwArgs;

// Флаги re (значения CPython)
const RE_IGNORECASE: u32 = 2;
const RE_LOCALE: u32 = 4;
const RE_MULTILINE: u32 = 8;
const RE_DOTALL: u32 = 16;
const RE_UNICODE: u32 = 32;
const RE_VERBOSE: u32 = 64;
const RE_ASCII: u32 = 256;

fn mset(vm: *VM, m: Obj, name: []const u8, val: Obj) !void {
    try ops.dictSetStr(m.v.module.dict, vm, name, val);
}
fn mfun(vm: *VM, m: Obj, name: []const u8, comptime f: anytype) !void {
    try mset(vm, m, name, try vm.rt.newBuiltin(name, object.wrapBuiltin(f)));
}
fn tdef(vm: *VM, ty: *object.Type, name: []const u8, comptime f: anytype) !void {
    try ops.dictSetStr(ty.dict, vm, name, try vm.rt.newBuiltin(name, object.wrapBuiltin(f)));
}

fn flagsFromInt(f: u32) regex.Flags {
    return .{
        .ignorecase = (f & RE_IGNORECASE) != 0,
        .multiline = (f & RE_MULTILINE) != 0,
        .dotall = (f & RE_DOTALL) != 0,
        .verbose = (f & RE_VERBOSE) != 0,
        .ascii = (f & RE_ASCII) != 0,
    };
}

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("re");

    try mset(vm, m, "IGNORECASE", try rt.newInt(RE_IGNORECASE));
    try mset(vm, m, "I", try rt.newInt(RE_IGNORECASE));
    try mset(vm, m, "LOCALE", try rt.newInt(RE_LOCALE));
    try mset(vm, m, "L", try rt.newInt(RE_LOCALE));
    try mset(vm, m, "MULTILINE", try rt.newInt(RE_MULTILINE));
    try mset(vm, m, "M", try rt.newInt(RE_MULTILINE));
    try mset(vm, m, "DOTALL", try rt.newInt(RE_DOTALL));
    try mset(vm, m, "S", try rt.newInt(RE_DOTALL));
    try mset(vm, m, "UNICODE", try rt.newInt(RE_UNICODE));
    try mset(vm, m, "U", try rt.newInt(RE_UNICODE));
    try mset(vm, m, "VERBOSE", try rt.newInt(RE_VERBOSE));
    try mset(vm, m, "X", try rt.newInt(RE_VERBOSE));
    try mset(vm, m, "ASCII", try rt.newInt(RE_ASCII));
    try mset(vm, m, "A", try rt.newInt(RE_ASCII));

    // re.error = PatternError (подкласс Exception)
    const exc_t = vm.excType("Exception");
    var err_t = rt.exc_types.get("PatternError") orelse blk: {
        const t = try rt.mkType("PatternError", exc_t);
        t.flags.exc = true;
        t.module = "re";
        try rt.exc_types.put("PatternError", t);
        break :blk t;
    };
    err_t.module = "re";
    try mset(vm, m, "error", try rt.mkObj(rt.type_t, .{ .type_ = err_t }));
    try mset(vm, m, "PatternError", try rt.mkObj(rt.type_t, .{ .type_ = err_t }));

    // функции модуля
    try mfun(vm, m, "compile", re_compile);
    try mfun(vm, m, "match", re_match);
    try mfun(vm, m, "search", re_search);
    try mfun(vm, m, "fullmatch", re_fullmatch);
    try mfun(vm, m, "findall", re_findall);
    try mfun(vm, m, "finditer", re_finditer);
    try mfun(vm, m, "sub", re_sub);
    try mfun(vm, m, "subn", re_subn);
    try mfun(vm, m, "split", re_split);
    try mfun(vm, m, "escape", re_escape);
    try mfun(vm, m, "purge", re_purge);

    // методы Pattern
    try tdef(vm, rt.pattern_t, "match", pat_match);
    try tdef(vm, rt.pattern_t, "search", pat_search);
    try tdef(vm, rt.pattern_t, "fullmatch", pat_fullmatch);
    try tdef(vm, rt.pattern_t, "findall", pat_findall);
    try tdef(vm, rt.pattern_t, "finditer", pat_finditer);
    try tdef(vm, rt.pattern_t, "sub", pat_sub);
    try tdef(vm, rt.pattern_t, "subn", pat_subn);
    try tdef(vm, rt.pattern_t, "split", pat_split);
    try tdef(vm, rt.pattern_t, "__repr__", pat_repr);

    // методы Match
    try tdef(vm, rt.match_t, "group", match_group);
    try tdef(vm, rt.match_t, "groups", match_groups);
    try tdef(vm, rt.match_t, "groupdict", match_groupdict);
    try tdef(vm, rt.match_t, "start", match_start);
    try tdef(vm, rt.match_t, "end", match_end);
    try tdef(vm, rt.match_t, "span", match_span);
    try tdef(vm, rt.match_t, "__getitem__", match_group);

    return m;
}

// ============================================================
// компиляция / создание объектов
// ============================================================

fn compilePattern(vm: *VM, pattern: []const u8, flags: u32) anyerror!Obj {
    const fl = flagsFromInt(flags);
    const re = regex.Regex.compile(vm.rt.gpa, pattern, fl) catch {
        try vm.raiseFmt("PatternError", "invalid pattern: '{s}'", .{pattern});
        return error.PyExc;
    };
    const pat = try vm.rt.gpa.create(object.Pattern);
    pat.* = .{ .re = re, .flags = flags, .pattern_str = pattern };
    return vm.rt.mkObj(vm.rt.pattern_t, .{ .pattern = pat });
}

fn getPattern(vm: *VM, obj: Obj) anyerror!*object.Pattern {
    if (obj.v == .pattern) return obj.v.pattern;
    // строка → скомпилировать на лету
    if (obj.v == .str) {
        const po = try compilePattern(vm, obj.v.str.bytes, 0);
        return po.v.pattern;
    }
    try vm.raiseStr("TypeError", "expected str or re.Pattern");
    return error.PyExc;
}

fn mkMatch(vm: *VM, pat: *object.Pattern, input: []const u8, caps: []regex.Capture) anyerror!Obj {
    const mt = try vm.rt.gpa.create(object.Match);
    const caps_dup = try vm.rt.gpa.dupe(regex.Capture, caps);
    mt.* = .{ .re = pat.re, .input = input, .caps = caps_dup, .gpa = vm.rt.gpa };
    return vm.rt.mkObj(vm.rt.match_t, .{ .match = mt });
}

fn strArg(vm: *VM, o: Obj) anyerror![]const u8 {
    if (o.v == .str) return o.v.str.bytes;
    const s = try ops.pyStr(vm, o);
    return s.v.str.bytes;
}

// ============================================================
// функции модуля
// ============================================================

fn re_compile(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 1) return v.rt.newNone();
    if (args[0].v == .pattern) return args[0];
    const pat = try strArg(v, args[0]);
    var flags: u32 = 0;
    if (args.len > 1 and args[1].v == .int) flags = @intCast(args[1].v.int);
    if (kw) |k| if (k.get("flags")) |f| if (f.v == .int) flags = @intCast(f.v.int);
    return compilePattern(v, pat, flags);
}

fn doSearch(v: *VM, pat: *object.Pattern, input: []const u8, anchored: bool, full: bool) anyerror!?Obj {
    var start: usize = 0;
    _ = start;
    const caps = pat.re.searchFrom(input, 0, anchored);
    if (caps) |c| {
        if (full and c[0].end != input.len) return null;
        return try mkMatch(v, pat, input, c);
    }
    return null;
}

fn re_search(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 2) return v.rt.newNone();
    const pat = try getPattern(v, args[0]);
    const input = try strArg(v, args[1]);
    _ = kw;
    return (try doSearch(v, pat, input, false, false)) orelse v.rt.newNone();
}

fn re_match(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 2) return v.rt.newNone();
    const pat = try getPattern(v, args[0]);
    const input = try strArg(v, args[1]);
    _ = kw;
    return (try doSearch(v, pat, input, true, false)) orelse v.rt.newNone();
}

fn re_fullmatch(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 2) return v.rt.newNone();
    const pat = try getPattern(v, args[0]);
    const input = try strArg(v, args[1]);
    _ = kw;
    return (try doSearch(v, pat, input, true, true)) orelse v.rt.newNone();
}

fn re_findall(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 2) return v.rt.newList();
    const pat = try getPattern(v, args[0]);
    const input = try strArg(v, args[1]);
    _ = kw;
    return findAll(v, pat, input);
}

fn re_finditer(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 2) return v.rt.newList();
    const pat = try getPattern(v, args[0]);
    const input = try strArg(v, args[1]);
    _ = kw;
    const lst = try findAllMatches(v, pat, input);
    return v.pyIter(lst);
}

fn re_sub(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const r = try doSub(v, args, kw, false);
    return r;
}
fn re_subn(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    return doSub(v, args, kw, true);
}

fn re_split(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 2) return v.rt.newList();
    const pat = try getPattern(v, args[0]);
    const input = try strArg(v, args[1]);
    var maxsplit: usize = 0;
    if (args.len > 2 and args[2].v == .int) maxsplit = @intCast(args[2].v.int);
    _ = kw;
    return doSplit(v, pat, input, maxsplit);
}

fn re_escape(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 1) return v.rt.newStr("");
    const s = try strArg(v, args[0]);
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c)) out.append(v.rt.gpa, '\\') catch {};
        out.append(v.rt.gpa, c) catch {};
    }
    return v.rt.newStr(out.items);
}

fn re_purge(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    return vm.rt.newNone();
}

// ============================================================
// Pattern методы (args[0] = pattern obj)
// ============================================================

fn pat_search(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const pat = args[0].v.pattern;
    const input = try strArg(v, args[1]);
    _ = kw;
    return (try doSearch(v, pat, input, false, false)) orelse v.rt.newNone();
}
fn pat_match(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const pat = args[0].v.pattern;
    const input = try strArg(v, args[1]);
    _ = kw;
    return (try doSearch(v, pat, input, true, false)) orelse v.rt.newNone();
}
fn pat_fullmatch(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const pat = args[0].v.pattern;
    const input = try strArg(v, args[1]);
    _ = kw;
    return (try doSearch(v, pat, input, true, true)) orelse v.rt.newNone();
}
fn pat_findall(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const pat = args[0].v.pattern;
    const input = try strArg(v, args[1]);
    _ = kw;
    return findAll(v, pat, input);
}
fn pat_finditer(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const pat = args[0].v.pattern;
    const input = try strArg(v, args[1]);
    _ = kw;
    const lst = try findAllMatches(v, pat, input);
    return v.pyIter(lst);
}
fn pat_sub(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    // pat.sub(repl, string, count=0)
    var na = std.ArrayList(Obj).init(v.rt.gpa);
    try na.append(args[0]); // pattern
    for (args[1..]) |a| try na.append(a);
    return doSub(v, na.items, kw, false);
}
fn pat_subn(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    var na = std.ArrayList(Obj).init(v.rt.gpa);
    try na.append(args[0]);
    for (args[1..]) |a| try na.append(a);
    return doSub(v, na.items, kw, true);
}
fn pat_split(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const pat = args[0].v.pattern;
    const input = try strArg(v, args[1]);
    var maxsplit: usize = 0;
    if (args.len > 2 and args[2].v == .int) maxsplit = @intCast(args[2].v.int);
    _ = kw;
    return doSplit(v, pat, input, maxsplit);
}
fn pat_repr(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const pat = args[0].v.pattern;
    const s = try std.fmt.allocPrint(v.rt.gpa, "re.compile('{s}')", .{pat.pattern_str});
    return v.rt.newStr(s);
}

// ============================================================
// Match методы (args[0] = match obj)
// ============================================================

fn groupIndex(m: *object.Match, arg: Obj) ?usize {
    if (arg.v == .int) {
        const i = arg.v.int;
        if (i >= 0 and i < m.caps.len) return @intCast(i);
        return null;
    }
    if (arg.v == .str) {
        const name = arg.v.str.bytes;
        if (m.re.group_names.get(name)) |gi| {
            if (gi < m.caps.len) return gi;
        }
        return null;
    }
    return null;
}

fn match_group(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const m = args[0].v.match;
    _ = kw;
    if (args.len <= 1) {
        // group() → группа 0
        const c = m.caps[0];
        return v.rt.newStr(m.input[c.start..c.end]);
    }
    if (args.len == 2) {
        const gi = groupIndex(m, args[1]) orelse {
            try v.raiseStr("IndexError", "no such group");
            return error.PyExc;
        };
        const c = m.caps[gi];
        if (!c.matched) return v.rt.newNone();
        return v.rt.newStr(m.input[c.start..c.end]);
    }
    // несколько групп → tuple
    var out: std.ArrayList(Obj) = .empty;
    for (args[1..]) |a| {
        const gi = groupIndex(m, a) orelse {
            try v.raiseStr("IndexError", "no such group");
            return error.PyExc;
        };
        const c = m.caps[gi];
        try out.append(v.rt.gpa, if (c.matched) try v.rt.newStr(m.input[c.start..c.end]) else v.rt.newNone());
    }
    return v.rt.newTupleOwned(out.items);
}

fn match_groups(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const m = args[0].v.match;
    var default = v.rt.newNone();
    if (args.len > 1) default = args[1];
    _ = kw;
    var out: std.ArrayList(Obj) = .empty;
    var i: usize = 1;
    while (i < m.caps.len) : (i += 1) {
        const c = m.caps[i];
        try out.append(v.rt.gpa, if (c.matched) try v.rt.newStr(m.input[c.start..c.end]) else default);
    }
    return v.rt.newTupleOwned(out.items);
}

fn match_groupdict(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const m = args[0].v.match;
    _ = kw;
    const d = try v.rt.newDictObj();
    var it = m.re.group_names.iterator();
    while (it.next()) |e| {
        const gi = e.value_ptr.*;
        var val = v.rt.newNone();
        if (gi < m.caps.len and m.caps[gi].matched) {
            const c = m.caps[gi];
            val = try v.rt.newStr(m.input[c.start..c.end]);
        }
        try ops.dictSetStr(d.v.dict, v, e.key_ptr.*, val);
    }
    return d;
}

fn match_start(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const m = args[0].v.match;
    var gi: usize = 0;
    if (args.len > 1 and args[1].v == .int) gi = @intCast(args[1].v.int);
    _ = kw;
    if (gi >= m.caps.len or !m.caps[gi].matched) return v.rt.newInt(-1);
    return v.rt.newInt(@intCast(m.caps[gi].start));
}
fn match_end(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const m = args[0].v.match;
    var gi: usize = 0;
    if (args.len > 1 and args[1].v == .int) gi = @intCast(args[1].v.int);
    _ = kw;
    if (gi >= m.caps.len or !m.caps[gi].matched) return v.rt.newInt(-1);
    return v.rt.newInt(@intCast(m.caps[gi].end));
}
fn match_span(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    const m = args[0].v.match;
    var gi: usize = 0;
    if (args.len > 1 and args[1].v == .int) gi = @intCast(args[1].v.int);
    _ = kw;
    if (gi >= m.caps.len or !m.caps[gi].matched) {
        return v.rt.newTuple(&.{ try v.rt.newInt(-1), try v.rt.newInt(-1) });
    }
    return v.rt.newTuple(&.{ try v.rt.newInt(@intCast(m.caps[gi].start)), try v.rt.newInt(@intCast(m.caps[gi].end)) });
}

// ============================================================
// общие операции (findall/sub/split)
// ============================================================

fn findAllMatches(v: *VM, pat: *object.Pattern, input: []const u8) anyerror!Obj {
    const lst = try v.rt.newList();
    var pos: usize = 0;
    while (pos <= input.len) {
        const caps = pat.re.searchFrom(input, pos, false) orelse break;
        const mo = try mkMatch(v, pat, input, caps);
        try lst.v.list.items.append(v.rt.gpa, mo);
        if (caps[0].end == caps[0].start) {
            pos += 1;
        } else {
            pos = caps[0].end;
        }
    }
    return lst;
}

fn findAll(v: *VM, pat: *object.Pattern, input: []const u8) anyerror!Obj {
    const lst = try v.rt.newList();
    var pos: usize = 0;
    const ngroups = pat.re.num_groups;
    while (pos <= input.len) {
        const caps = pat.re.searchFrom(input, pos, false) orelse break;
        if (ngroups == 1) {
            const c = caps[0];
            try lst.v.list.items.append(v.rt.gpa, try v.rt.newStr(input[c.start..c.end]));
        } else if (ngroups == 2) {
            const c = caps[1];
            try lst.v.list.items.append(v.rt.gpa, if (c.matched) try v.rt.newStr(input[c.start..c.end]) else v.rt.newNone());
        } else {
            var tup: std.ArrayList(Obj) = .empty;
            var i: usize = 1;
            while (i < ngroups) : (i += 1) {
                const c = caps[i];
                try tup.append(v.rt.gpa, if (c.matched) try v.rt.newStr(input[c.start..c.end]) else v.rt.newNone());
            }
            try lst.v.list.items.append(v.rt.gpa, try v.rt.newTupleOwned(tup.items));
        }
        if (caps[0].end == caps[0].start) {
            pos += 1;
        } else {
            pos = caps[0].end;
        }
    }
    return lst;
}

fn expandRepl(v: *VM, repl: []const u8, m: *object.Match) anyerror![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < repl.len) {
        const c = repl[i];
        if (c == '\\' and i + 1 < repl.len) {
            const n = repl[i + 1];
            if (n >= '0' and n <= '9') {
                // \1 .. \99
                var gi: usize = n - '0';
                var j = i + 2;
                if (j < repl.len and repl[j] >= '0' and repl[j] <= '9') {
                    gi = gi * 10 + (repl[j] - '0');
                    j += 1;
                }
                if (gi < m.caps.len and m.caps[gi].matched) {
                    const cc = m.caps[gi];
                    out.appendSlice(v.rt.gpa, m.input[cc.start..cc.end]) catch {};
                }
                i = j;
                continue;
            } else if (n == 'g' and i + 2 < repl.len and repl[i + 2] == '<') {
                // \g<name> или \g<1>
                const end = std.mem.indexOfScalarPos(u8, repl, i + 3, '>') orelse repl.len;
                const ref = repl[i + 3 .. end];
                var val: ?[]const u8 = null;
                if (std.fmt.parseInt(usize, ref, 10)) |num| {
                    if (num < m.caps.len and m.caps[num].matched) val = m.input[m.caps[num].start..m.caps[num].end];
                } else |_| {
                    if (m.re.group_names.get(ref)) |gi| {
                        if (gi < m.caps.len and m.caps[gi].matched) val = m.input[m.caps[gi].start..m.caps[gi].end];
                    }
                }
                if (val) |vv| out.appendSlice(v.rt.gpa, vv) catch {};
                i = end + 1;
                continue;
            } else {
                out.append(v.rt.gpa, n) catch {};
                i += 2;
                continue;
            }
        }
        out.append(v.rt.gpa, c) catch {};
        i += 1;
    }
    return out.items;
}

fn doSub(v: *VM, args: []const Obj, kw: ?KwArgs, want_n: bool) anyerror!Obj {
    // sub(pattern, repl, string, count=0)  или  pat.sub(repl, string, count=0)
    if (args.len < 3) {
        try v.raiseStr("TypeError", "sub() missing arguments");
        return error.PyExc;
    }
    const pat = try getPattern(v, args[0]);
    const repl_obj = args[1];
    const input = try strArg(v, args[2]);
    var count: usize = 0;
    if (args.len > 3 and args[3].v == .int) count = @intCast(args[3].v.int);
    if (kw) |k| if (k.get("count")) |co| if (co.v == .int) count = @intCast(co.v.int);

    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    var n: usize = 0;
    while (pos <= input.len) {
        if (count != 0 and n >= count) break;
        const caps = pat.re.searchFrom(input, pos, false) orelse break;
        const c = caps[0];
        out.appendSlice(v.rt.gpa, input[pos..c.start]) catch {};
        if (repl_obj.v == .str) {
            const m_obj = try mkMatch(v, pat, input, caps);
            const expanded = try expandRepl(v, repl_obj.v.str.bytes, m_obj.v.match);
            out.appendSlice(v.rt.gpa, expanded) catch {};
        } else {
            // callable repl
            const m_obj = try mkMatch(v, pat, input, caps);
            const r = try v.pyCall(repl_obj, &.{m_obj}, null);
            const rs = try strArg(v, r);
            out.appendSlice(v.rt.gpa, rs) catch {};
        }
        n += 1;
        if (c.end == c.start) {
            if (c.end < input.len) out.append(v.rt.gpa, input[c.end]) catch {};
            pos = c.end + 1;
        } else {
            pos = c.end;
        }
    }
    out.appendSlice(v.rt.gpa, input[pos..]) catch {};
    const res_str = try v.rt.newStr(out.items);
    if (want_n) {
        return v.rt.newTuple(&.{ res_str, try v.rt.newInt(@intCast(n)) });
    }
    return res_str;
}

fn doSplit(v: *VM, pat: *object.Pattern, input: []const u8, maxsplit: usize) anyerror!Obj {
    const lst = try v.rt.newList();
    var pos: usize = 0;
    var n: usize = 0;
    const ngroups = pat.re.num_groups;
    while (pos <= input.len) {
        if (maxsplit != 0 and n >= maxsplit) break;
        const caps = pat.re.searchFrom(input, pos, false) orelse break;
        const c = caps[0];
        if (c.end == c.start and c.start == pos) {
            // пустое совпадение в начале — сдвинуть
            if (pos < input.len) {
                pos += 1;
                continue;
            }
            break;
        }
        try lst.v.list.items.append(v.rt.gpa, try v.rt.newStr(input[pos..c.start]));
        // группы
        var i: usize = 1;
        while (i < ngroups) : (i += 1) {
            const cc = caps[i];
            try lst.v.list.items.append(v.rt.gpa, if (cc.matched) try v.rt.newStr(input[cc.start..cc.end]) else v.rt.newNone());
        }
        n += 1;
        pos = c.end;
    }
    try lst.v.list.items.append(v.rt.gpa, try v.rt.newStr(input[pos..]));
    return lst;
}
