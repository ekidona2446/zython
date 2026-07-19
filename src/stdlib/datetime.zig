//! datetime module — аналог Lib/datetime.py + Modules/_datetimemodule.c
//! Возвращает реальное время через std.os.clock_gettime

const std = @import("std");
const builtin = @import("builtin");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

pub const DatetimeModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict: std.StringHashMap(object.ObjectPtr) = undefined;
        dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        const datetime_class = try createClass(allocator, "datetime", &[_]BuiltinMethod{
            .{ .name = "now", .func = datetimeNow },
            .{ .name = "utcnow", .func = datetimeUtcNow },
            .{ .name = "fromtimestamp", .func = datetimeFromTimestamp },
        });
        try dict.put("datetime", datetime_class);

        const date_class = try createClass(allocator, "date", &[_]BuiltinMethod{
            .{ .name = "today", .func = dateToday },
        });
        try dict.put("date", date_class);

        const timedelta_class = try createClass(allocator, "timedelta", &[_]BuiltinMethod{
            .{ .name = "total_seconds", .func = timedeltaTotalSeconds },
        });
        try dict.put("timedelta", timedelta_class);

        const timezone_class = try createClass(allocator, "timezone", &[_]BuiltinMethod{});
        try dict.put("timezone", timezone_class);

        const module_val = object.ModuleValue{
            .name = "datetime",
            .dict = dict,
            .file = "datetime (zig, std.os + libxev)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    const BuiltinMethod = struct {
        name: []const u8,
        func: object.BuiltinFn,
    };

    fn createClass(allocator: Allocator, name: []const u8, methods: []const BuiltinMethod) !object.ObjectPtr {
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);
        for (methods) |m| {
            const fn_obj = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = m.func });
            try dict.put(m.name, fn_obj);
        }
        const mod_val = object.ModuleValue{
            .name = name,
            .dict = dict,
            .file = null,
        };
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = mod_val });
    }

    /// Получает текущее время в секундах с эпохи через std.posix + libc
    fn getTimestampSeconds() i64 {
        // Use Linux syscall directly for clock_gettime
        var ts: std.posix.timespec = undefined;
        const rc = std.posix.system.clock_gettime(std.posix.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
        return @as(i64, @intCast(ts.sec));
    }

    fn formatEpochSeconds(epoch_secs: i64, allocator: Allocator) ![]u8 {
        const epoch_days = @divFloor(epoch_secs, 86400);
        var remaining_days = epoch_days;
        var year: i64 = 1970;
        while (true) {
            const days_in_year: i64 = if (std.time.epoch.isLeapYear(@intCast(year))) 366 else 365;
            if (remaining_days < days_in_year) break;
            remaining_days -= days_in_year;
            year += 1;
        }
        const month_days = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        const is_leap = std.time.epoch.isLeapYear(@intCast(year));
        const leap_feb: i64 = if (is_leap) 29 else 28;
        var month: usize = 0;
        var day: i64 = remaining_days + 1;
        for (month_days, 0..) |md, m| {
            const actual_days: i64 = if (m == 1) leap_feb else md;
            if (day <= actual_days) {
                month = m + 1;
                break;
            }
            day -= actual_days;
            if (m == 11) {
                month = 12;
            }
        }
        if (month == 0) month = 1;
        if (day < 1) day = 1;
        const secs_of_day = @mod(epoch_secs, 86400);
        const hour = @divFloor(secs_of_day, 3600);
        const minute = @divFloor(@mod(secs_of_day, 3600), 60);
        const second = @mod(secs_of_day, 60);

        return try std.fmt.allocPrint(allocator, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            @as(u64, @intCast(year)),
            @as(u64, @intCast(month)),
            @as(u64, @intCast(day)),
            @as(u64, @intCast(hour)),
            @as(u64, @intCast(minute)),
            @as(u64, @intCast(second)),
        });
    }

    fn datetimeNow(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        const ts = getTimestampSeconds();
        const result_str = try formatEpochSeconds(ts, allocator);
        defer allocator.free(result_str);
        return try object.PyObject.newStr(allocator, result_str);
    }

    fn datetimeUtcNow(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        const ts = getTimestampSeconds();
        const result_str = try formatEpochSeconds(ts, allocator);
        defer allocator.free(result_str);
        const with_utc = try std.fmt.allocPrint(allocator, "{s} UTC", .{result_str});
        defer allocator.free(with_utc);
        return try object.PyObject.newStr(allocator, with_utc);
    }

    fn datetimeFromTimestamp(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len == 0) return error.TypeError;
        const ts = switch (args[0].value) {
            .Float => |f| @as(i64, @intFromFloat(f)),
            .Int => |iv| switch (iv) {
                .Small => |v| v,
                .Big => 0,
            },
            else => return error.TypeError,
        };
        const result_str = try formatEpochSeconds(ts, allocator);
        defer allocator.free(result_str);
        return try object.PyObject.newStr(allocator, result_str);
    }

    fn dateToday(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        const ts = getTimestampSeconds();
        const result_str = try formatEpochSeconds(ts, allocator);
        defer allocator.free(result_str);
        const date_only = if (result_str.len >= 10) result_str[0..10] else result_str;
        return try object.PyObject.newStr(allocator, date_only);
    }

    fn timedeltaTotalSeconds(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newFloat(allocator, 0.0);
    }
};

pub const ZigFFI = struct {
    pub fn registerZigFunction(allocator: Allocator, module_dict: *std.StringHashMap(object.ObjectPtr), name: []const u8, zig_fn: object.BuiltinFn) !void {
        const fn_obj = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = zig_fn });
        try module_dict.put(name, fn_obj);
    }

    pub fn zigAdd(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 2) return error.TypeError;
        const a = switch (args[0].value) { .Int => |iv| switch (iv) { .Small => |v| v, .Big => 0 }, else => return error.TypeError };
        const b = switch (args[1].value) { .Int => |iv| switch (iv) { .Small => |v| v, .Big => 0 }, else => return error.TypeError };
        return try object.PyObject.newInt(allocator, a + b);
    }

    pub fn zigVersion(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        const zver = builtin.zig_version;
        const ver = try std.fmt.allocPrint(allocator, "Zig {d}.{d}.{d} + libxev, called from Python via zython", .{
            zver.major,
            zver.minor,
            zver.patch,
        });
        defer allocator.free(ver);
        return try object.PyObject.newStr(allocator, ver);
    }
};
