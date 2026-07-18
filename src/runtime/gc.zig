//! Garbage Collector - аналог Python/gc.c и Objects/obmalloc.c
//! CPython использует reference counting + generational GC для циклов
//! Zython: используем refcount как основной, и дополнительно cycle GC поверх tri-color
//! + интеграция с Zig Allocator

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("../object/object.zig");

pub const GC = struct {
    allocator: Allocator,
    generations: [3]Generation,
    tracked_objects: std.ArrayList(object.ObjectPtr),
    stats: GCStats,

    pub const Generation = struct {
        objects: std.ArrayList(object.ObjectPtr),
        threshold: usize,
        count: usize,
    };

    pub const GCStats = struct {
        collections: usize = 0,
        collected: usize = 0,
        uncollectable: usize = 0,
    };

    pub fn init(allocator: Allocator) GC {
        return .{
            .allocator = allocator,
            .generations = .{
                .{ .objects = std.ArrayList(object.ObjectPtr).empty, .threshold = 700, .count = 0 },
                .{ .objects = std.ArrayList(object.ObjectPtr).empty, .threshold = 10, .count = 0 },
                .{ .objects = std.ArrayList(object.ObjectPtr).empty, .threshold = 10, .count = 0 },
            },
            .tracked_objects = std.ArrayList(object.ObjectPtr).empty,
            .stats = .{},
        };
    }

    pub fn deinit(self: *GC) void {
        for (&self.generations) |*gen| {
            gen.objects.deinit(self.allocator);
        }
        self.tracked_objects.deinit(self.allocator);
    }

    /// Track object - аналог PyObject_GC_Track
    pub fn track(self: *GC, obj: object.ObjectPtr) !void {
        if (obj.gc_tracked) return;
        obj.gc_tracked = true;
        try self.tracked_objects.append(self.allocator, obj);
        try self.generations[0].objects.append(self.allocator, obj);
    }

    /// Untrack - аналог PyObject_GC_UnTrack
    pub fn untrack(self: *GC, obj: object.ObjectPtr) void {
        obj.gc_tracked = false;
        for (&self.generations) |*gen| {
            for (gen.objects.items, 0..) |o, idx| {
                if (o == obj) {
                    _ = gen.objects.orderedRemove(idx);
                    break;
                }
            }
        }
    }

    /// Collect generation - аналог collect_generations()
    pub fn collect(self: *GC, generation: usize) usize {
        if (generation > 2) return 0;
        self.stats.collections += 1;

        var gen = &self.generations[generation];
        const reachable = self.markAndSweep(gen);

        // Перемещаем выжившие в следующее поколение (как в CPython generational GC)
        if (generation < 2) {
            var next_gen = &self.generations[generation + 1];
            for (reachable) |obj| {
                next_gen.objects.append(self.allocator, obj) catch {};
            }
        }

        gen.objects.clearRetainingCapacity();
        gen.count = 0;

        return gen.objects.items.len;
    }

    fn markAndSweep(self: *GC, gen: *Generation) []object.ObjectPtr {
        _ = self;
        _ = gen;
        // TODO: реализуем traverse для каждого типа (tp_traverse в CPython)
        // Для MVP возвращаем пусто
        return &.{};
    }

    /// Включает/выключает GC - аналог gc.enable(), gc.disable()
    pub fn enable(self: *GC) void {
        _ = self;
    }

    pub fn disable(self: *GC) void {
        _ = self;
    }

    pub fn isEnabled(self: *GC) bool {
        _ = self;
        return true;
    }
};

/// Object allocator - аналог Objects/obmalloc.c (pymalloc)
/// Используем Zig GPA + arena для маленьких объектов
pub const PyMemAllocator = struct {
    gpa: std.heap.DebugAllocator(.{}),
    arena: std.heap.ArenaAllocator,

    pub fn init() PyMemAllocator {
        var gpa = std.heap.DebugAllocator(.{}){};
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa.allocator()),
        };
    }

    pub fn allocator(self: *PyMemAllocator) Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *PyMemAllocator) void {
        self.arena.deinit();
        _ = self.gpa.deinit();
    }
};
