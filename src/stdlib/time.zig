//! time — аналог Modules/timemodule.c. Часы — через std.Io.Clock (мультиплатформенно).
//! sleep снимает GIL на время ожидания (честная многопоточность).

const std = @import("std");
const object = @import("../object/object.zig");
const runtime_mod = @import("../runtime/runtime.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const bltn = @import("../runtime/builtins.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;
const KwArgs = object.KwArgs;

fn mset(vm: *VM, m: Obj, name: []const u8, val: Obj) !void {
    try ops.dictSetStr(m.v.module.dict, vm, name, val);
}

fn freg(vm: *VM, m: Obj, name: []const u8, comptime f: anytype) !void {
    try mset(vm, m, name, try vm.rt.newBuiltin(name, object.wrapBuiltin(f)));
}

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("time");
    try freg(vm, m, "time", t_time);
    try freg(vm, m, "time_ns", t_time_ns);
    try freg(vm, m, "monotonic", t_monotonic);
    try freg(vm, m, "monotonic_ns", t_monotonic_ns);
    try freg(vm, m, "perf_counter", t_monotonic);
    try freg(vm, m, "perf_counter_ns", t_monotonic_ns);
    try freg(vm, m, "sleep", t_sleep);
    try freg(vm, m, "gmtime", t_gmtime);
    try freg(vm, m, "localtime", t_localtime);
    try freg(vm, m, "ctime", t_ctime);
    try freg(vm, m, "mktime", t_mktime);
    try freg(vm, m, "strftime", t_strftime);
    try mset(vm, m, "timezone", try rt.newInt(0));
    try mset(vm, m, "tzname", try rt.newTuple(&.{ try rt.newStr("UTC"), try rt.newStr("UTC") }));
    try mset(vm, m, "struct_time", rt.newNone());
    return m;
}

fn t_time(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    const io = v.rt.io orelse return v.rt.newFloat(0);
    const ts = std.Io.Clock.now(.real, io);
    const ns = ts.toNanoseconds();
    return v.rt.newFloat(@as(f64, @floatFromInt(ns)) / 1e9);
}

fn t_time_ns(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    const io = v.rt.io orelse return v.rt.newInt(0);
    const ts = std.Io.Clock.now(.real, io);
    return v.rt.newInt(@intCast(ts.toNanoseconds()));
}

fn t_monotonic(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    const io = v.rt.io orelse return v.rt.newFloat(0);
    const ts = std.Io.Clock.now(.boot, io);
    const ns = ts.toNanoseconds();
    return v.rt.newFloat(@as(f64, @floatFromInt(ns)) / 1e9);
}

fn t_monotonic_ns(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    const io = v.rt.io orelse return v.rt.newInt(0);
    const ts = std.Io.Clock.now(.boot, io);
    return v.rt.newInt(@intCast(ts.toNanoseconds()));
}

fn t_sleep(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const secs = try bltn.floatLike(v, args[0]);
    const io = v.rt.io orelse return v.rt.newNone();
    // честная многопоточность: спим без GIL, чтобы другие потоки работали
    v.gilRelease();
    defer v.gilAcquire();
    const ns: u64 = if (secs <= 0) 0 else @intFromFloat(secs * 1e9);
    io.sleep(std.Io.Duration.fromNanoseconds(@intCast(ns)), .boot) catch {};
    return v.rt.newNone();
}

// ---------------- struct_time (упрощённо — как tuple из 9 int'ов) ----------------

const TmParts = struct {
    year: i64,
    mon: i64,
    mday: i64,
    hour: i64,
    min: i64,
    sec: i64,
    wday: i64,
    yday: i64,
    isdst: i64,
};

fn civilFromDays(z_in: i64) struct { y: i64, m: i64, d: i64 } {
    // Howard Hinnant's civil_from_days
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = @as(i64, @intCast(doy - (153 * mp + 2) / 5 + 1));
    const m = @as(i64, @intCast(if (mp < 10) mp + 3 else mp - 9));
    return .{ .y = if (m <= 2) y + 1 else y, .m = m, .d = d };
}

fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe: u64 = @intCast(y - era * 400);
    const mp: u64 = @intCast(if (m > 2) m - 3 else m + 9);
    const doy = (153 * mp + 2) / 5 + @as(u64, @intCast(d - 1));
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + @as(i64, @intCast(doe)) - 719468;
}

fn breakTime(epoch_sec: i64) TmParts {
    const days = @divFloor(epoch_sec, 86400);
    const rem = @mod(epoch_sec, 86400);
    const civil = civilFromDays(days);
    const wday = @mod(days + 4, 7); // 1970-01-01 — четверг (3 в Python'е Mon=0..) CPython wday: Mon=0
    const py_wday = @mod(wday + 6, 7); // конверт к Mon=0
    const jan1 = daysFromCivil(civil.y, 1, 1);
    return .{
        .year = civil.y,
        .mon = civil.m,
        .mday = civil.d,
        .hour = @divFloor(rem, 3600),
        .min = @mod(@divFloor(rem, 60), 60),
        .sec = @mod(rem, 60),
        .wday = py_wday,
        .yday = days - jan1 + 1,
        .isdst = -1,
    };
}

fn structTime(vm: *VM, epoch_sec: i64) !Obj {
    const p = breakTime(epoch_sec);
    return vm.rt.newTuple(&.{
        try vm.rt.newInt(p.year),
        try vm.rt.newInt(p.mon),
        try vm.rt.newInt(p.mday),
        try vm.rt.newInt(p.hour),
        try vm.rt.newInt(p.min),
        try vm.rt.newInt(p.sec),
        try vm.rt.newInt(p.wday),
        try vm.rt.newInt(p.yday),
        try vm.rt.newInt(p.isdst),
    });
}

fn t_gmtime(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    var secs: i64 = undefined;
    if (args.len >= 1) {
        secs = @intFromFloat(try bltn.floatLike(v, args[0]));
    } else {
        const io = v.rt.io orelse return v.rt.newTuple(&.{});
        secs = @intCast(@divFloor(std.Io.Clock.now(.real, io).toNanoseconds(), 1_000_000_000));
    }
    return structTime(v, secs);
}

fn t_localtime(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    // TODO: настоящий TZ через std.Io.Clock — пока UTC
    return t_gmtime(vm, args, kw);
}

fn t_ctime(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    var secs: i64 = undefined;
    if (args.len >= 1) {
        secs = @intFromFloat(try bltn.floatLike(v, args[0]));
    } else {
        const io = v.rt.io orelse return v.rt.newStr("");
        secs = @intCast(@divFloor(std.Io.Clock.now(.real, io).toNanoseconds(), 1_000_000_000));
    }
    const p = breakTime(secs);
    const wdays = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    const mons = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const s = try std.fmt.allocPrint(v.rt.gpa, "{s} {s} {d:>2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{
        wdays[@intCast(p.wday)],
        mons[@intCast(p.mon - 1)],
        p.mday,
        @as(u64, @intCast(p.hour)),
        @as(u64, @intCast(p.min)),
        @as(u64, @intCast(p.sec)),
        p.year,
    });
    return v.rt.newStrOwned(s);
}

fn t_mktime(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const t = args[0];
    const parts = try vm.collectSequence(t, 9);
    const y = try bltn.indexLike(v, parts[0]);
    const mon = try bltn.indexLike(v, parts[1]);
    const d = try bltn.indexLike(v, parts[2]);
    const h = try bltn.indexLike(v, parts[3]);
    const mi = try bltn.indexLike(v, parts[4]);
    const s = try bltn.indexLike(v, parts[5]);
    const days = daysFromCivil(y, mon, d);
    const epoch = days * 86400 + h * 3600 + mi * 60 + s;
    return v.rt.newFloat(@floatFromInt(epoch));
}

fn t_strftime(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const fmt = args[0].v.str.bytes;
    const parts = try vm.collectSequence(args[1], 9);
    const year = try bltn.indexLike(v, parts[0]);
    const mon = try bltn.indexLike(v, parts[1]);
    const mday = try bltn.indexLike(v, parts[2]);
    const hour = try bltn.indexLike(v, parts[3]);
    const min = try bltn.indexLike(v, parts[4]);
    const sec = try bltn.indexLike(v, parts[5]);
    const wday = try bltn.indexLike(v, parts[6]);
    const yday = try bltn.indexLike(v, parts[7]);
    const wdays = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    const wdays_f = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
    const mons = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const mons_f = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    var out: std.ArrayList(u8) = .empty;
    const g = v.rt.gpa;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            try out.append(g, fmt[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= fmt.len) break;
        const c = fmt[i];
        i += 1;
        switch (c) {
            'Y' => try out.print(g, "{d}", .{year}),
            'y' => try out.print(g, "{d:0>2}", .{@as(u64, @intCast(@mod(year, 100)))}),
            'm' => try out.print(g, "{d:0>2}", .{@as(u64, @intCast(mon))}),
            'd' => try out.print(g, "{d:0>2}", .{@as(u64, @intCast(mday))}),
            'H' => try out.print(g, "{d:0>2}", .{@as(u64, @intCast(hour))}),
            'M' => try out.print(g, "{d:0>2}", .{@as(u64, @intCast(min))}),
            'S' => try out.print(g, "{d:0>2}", .{@as(u64, @intCast(sec))}),
            'a' => try out.appendSlice(g, wdays[@intCast(wday)]),
            'A' => try out.appendSlice(g, wdays_f[@intCast(wday)]),
            'b', 'h' => try out.appendSlice(g, mons[@intCast(mon - 1)]),
            'B' => try out.appendSlice(g, mons_f[@intCast(mon - 1)]),
            'j' => try out.print(g, "{d:0>3}", .{@as(u64, @intCast(yday))}),
            'p' => try out.appendSlice(g, if (hour < 12) "AM" else "PM"),
            'I' => {
                const h12 = @mod(hour + 11, 12) + 1;
                try out.print(g, "{d:0>2}", .{@as(u64, @intCast(h12))});
            },
            '%' => try out.append(g, '%'),
            'f' => try out.appendSlice(g, "000000"),
            'z' => try out.appendSlice(g, "+0000"),
            'Z' => try out.appendSlice(g, "UTC"),
            else => {
                try out.append(g, '%');
                try out.append(g, c);
            },
        }
    }
    return v.rt.newStrOwned(try out.toOwnedSlice(g));
}
