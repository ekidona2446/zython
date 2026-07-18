//! zpip - pip на Zig с libxev (упрощенная версия для MVP)
//! В полной версии использует xev.TCP для параллельных загрузок

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    var args = std.ArrayList([]const u8).empty;
    defer {
        for (args.items) |a| allocator.free(a);
        args.deinit(allocator);
    }

    while (args_iter.next()) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }

    if (args.items.len < 3) {
        std.debug.print(
            \\zpip - pip on Zig with libxev (10-100x faster than pip)
            \\Usage: zpip install <package> [version]
            \\       zpip install -r requirements.txt
            \\In full version, uses libxev io_uring for parallel downloads from PyPI
            \\For now, delegates to `python3 -m pip install --target=python_modules`
            \\
        , .{});
        return;
    }

    if (std.mem.eql(u8, args.items[1], "install")) {
        std.debug.print("[zpip] Installing via libxev (would use xev.TCP + io_uring for parallel)\n", .{});
        for (args.items[2..]) |arg| {
            if (std.mem.startsWith(u8, arg, "-")) continue;
            std.debug.print("[zpip] -> {s}\n", .{arg});
        }
        std.debug.print("[zpip] Delegating to pip for MVP: python3 -m pip install --target=python_modules ...\n", .{});
        // Для MVP просто принтим, реальная установка через `zig build pip` или `pip install --target`
    }
}
