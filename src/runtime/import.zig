//! Система импорта — аналог Python/import.c
//! Кроссплатформенная: пути поиска зависят от ОС

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const object = @import("../object/object.zig");

pub const ImportSystem = struct {
    allocator: Allocator,
    io: std.Io,
    modules: std.StringHashMap(object.ObjectPtr),
    search_paths: std.ArrayList([]const u8),
    builtin_modules: std.StringHashMap(BuiltinInitFn),

    pub const BuiltinInitFn = *const fn (allocator: Allocator) anyerror!object.ObjectPtr;

    pub fn init(allocator: Allocator) !ImportSystem {
        const io = std.testing.io;
        return try initWithIo(allocator, io);
    }

    pub fn initWithIo(allocator: Allocator, io: std.Io) !ImportSystem {
        var search_paths: std.ArrayList([]const u8) = .empty;
        // Dupe all paths so we can safely free them in deinit
        try search_paths.append(allocator, try allocator.dupe(u8, "."));
        try search_paths.append(allocator, try allocator.dupe(u8, "./Lib"));
        try search_paths.append(allocator, try allocator.dupe(u8, "./python_modules"));

        // Platform-specific standard library paths
        const os_tag = builtin.os.tag;
        const lib_suffix = switch (os_tag) {
            .linux => "/lib/python3.13",
            .macos => "/lib/python3.13",
            .windows => "\\Lib",
            .freebsd, .openbsd, .netbsd => "/lib/python3.13",
            else => "/lib/python3.13",
        };

        const prefix_paths = switch (os_tag) {
            .linux => &[_][]const u8{ "/usr", "/usr/local" },
            .macos => &[_][]const u8{ "/usr/local", "/opt/homebrew" },
            else => &[_][]const u8{ "/usr/local" },
        };

        for (prefix_paths) |prefix| {
            const path = try std.fs.path.join(allocator, &.{ prefix, lib_suffix });
            try search_paths.append(allocator, path);
        }

        return .{
            .allocator = allocator,
            .io = io,
            .modules = std.StringHashMap(object.ObjectPtr).init(allocator),
            .search_paths = search_paths,
            .builtin_modules = std.StringHashMap(BuiltinInitFn).init(allocator),
        };
    }

    pub fn deinit(self: *ImportSystem) void {
        self.modules.deinit();
        for (self.search_paths.items) |p| {
            self.allocator.free(p);
        }
        self.search_paths.deinit(self.allocator);
        self.builtin_modules.deinit();
    }

    pub fn findModuleFile(self: *ImportSystem, name: []const u8) !?[]const u8 {
        const file_name = try std.mem.concat(self.allocator, u8, &.{ name, ".py" });
        defer self.allocator.free(file_name);

        const package_path = try std.mem.replaceOwned(u8, self.allocator, name, ".", "/");
        defer self.allocator.free(package_path);

        const paths_to_try = [_][]const u8{
            file_name,
            try std.mem.concat(self.allocator, u8, &.{ package_path, ".py" }),
            try std.mem.concat(self.allocator, u8, &.{ package_path, "/__init__.py" }),
        };
        defer for (paths_to_try) |p| self.allocator.free(p);

        for (self.search_paths.items) |search_path| {
            for (paths_to_try) |rel_path| {
                const full_path = try std.fs.path.join(self.allocator, &.{ search_path, rel_path });
                defer self.allocator.free(full_path);

                std.Io.Dir.cwd().access(self.io, full_path, .{}) catch continue;
                return try self.allocator.dupe(u8, full_path);
            }
        }
        return null;
    }

    pub fn importModule(self: *ImportSystem, name: []const u8) !object.ObjectPtr {
        if (self.modules.get(name)) |mod| {
            mod.incref();
            return mod;
        }

        if (self.builtin_modules.get(name)) |init_fn| {
            const mod = try init_fn(self.allocator);
            try self.modules.put(name, mod);
            return mod;
        }

        const file_path_opt = try self.findModuleFile(name);
        if (file_path_opt) |file_path| {
            defer self.allocator.free(file_path);
            const source = try std.Io.Dir.cwd().readFileAlloc(self.io, file_path, self.allocator, .limited(10 * 1024 * 1024));
            defer self.allocator.free(source);

            const module_val = object.ModuleValue.init(self.allocator, name);
            var mod_val_mut = module_val;
            mod_val_mut.file = try self.allocator.dupe(u8, file_path);

            const mod_obj = try object.PyObject.create(self.allocator, &object.ModuleType, .{ .Module = mod_val_mut });
            try self.modules.put(try self.allocator.dupe(u8, name), mod_obj);
            mod_obj.incref();
            return mod_obj;
        }

        return error.ModuleNotFound;
    }

    pub fn registerBuiltin(self: *ImportSystem, name: []const u8, init_fn: BuiltinInitFn) !void {
        try self.builtin_modules.put(name, init_fn);
    }
};

test "import system init" {
    var import_sys = try ImportSystem.init(std.testing.allocator);
    defer import_sys.deinit();
    try std.testing.expect(import_sys.search_paths.items.len > 0);
}
