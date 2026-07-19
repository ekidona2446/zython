//! functools — Higher-order functions and operations on callable objects
//! Аналог Lib/functools.py + Modules/_functoolsmodule.c
//! Critical для lru_cache, partial, и decorator support

const std = @import("std");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

// === CachedProperty — descriptor for cached properties ===

pub const CachedProperty = struct {
    func: object.ObjectPtr,
    name: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, func: object.ObjectPtr, name: []const u8) !*CachedProperty {
        const self = try allocator.create(CachedProperty);
        self.* = .{
            .func = func,
            .name = name,
            .allocator = allocator,
        };
        return self;
    }

    pub fn __get__(self: *CachedProperty, obj: object.ObjectPtr, objtype: object.ObjectPtr) !object.ObjectPtr {
        _ = objtype;
        if (obj.value == .None) return self.func;
        // Call the function and cache the result
        return try object.PyObject.newNone(self.allocator);
    }
};

// === Partial — partial function application ===

pub const Partial = struct {
    func: object.ObjectPtr,
    args: []object.ObjectPtr,
    keywords: std.StringHashMap(object.ObjectPtr),

    pub fn init(allocator: Allocator, func: object.ObjectPtr, args: []object.ObjectPtr, keywords: std.StringHashMap(object.ObjectPtr)) !*Partial {
        const self = try allocator.create(Partial);
        self.* = .{
            .func = func,
            .args = args,
            .keywords = keywords,
        };
        return self;
    }

    pub fn call(self: *Partial, call_args: []object.ObjectPtr, allocator: Allocator) !object.ObjectPtr {
        _ = self;
        _ = call_args;
        return try object.PyObject.newNone(allocator);
    }

    pub fn __repr__(self: *Partial, allocator: Allocator) !object.ObjectPtr {
        const repr_str = try std.fmt.allocPrint(allocator, "functools.partial({p}, ...)", .{self.func});
        return try object.PyObject.newStr(allocator, repr_str);
    }
};

// === LRU Cache ===

pub const LRUCache = struct {
    maxsize: u32,
    cache: std.StringHashMap(CacheEntry),
    hits: u64,
    misses: u64,
    full: bool,

    pub const CacheEntry = struct {
        result: object.ObjectPtr,
        age: u64,
    },

    pub fn init(allocator: Allocator, maxsize: u32) !*LRUCache {
        const self = try allocator.create(LRUCache);
        self.* = .{
            .maxsize = maxsize,
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .hits = 0,
            .misses = 0,
            .full = false,
        };
        return self;
    }

    pub fn get(self: *LRUCache, key: []const u8) ?object.ObjectPtr {
        if (self.cache.get(key)) |entry| {
            return entry.result;
        }
        return null;
    }

    pub fn put(self: *LRUCache, key: []const u8, value: object.ObjectPtr) void {
        if (self.cache.count() >= self.maxsize and self.maxsize > 0) {
            self.full = true;
            // Remove oldest entry (simplified)
            var it = self.cache.iterator();
            if (it.next()) |entry| {
                _ = self.cache.remove(entry.key_ptr.*);
            }
        }
        try self.cache.put(key, CacheEntry{ .result = value, .age = 0 });
    }

    pub fn info(self: *LRUCache, allocator: Allocator) !object.ObjectPtr {
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);
        try dict.put("maxsize", try object.PyObject.newInt(allocator, self.maxsize));
        try dict.put("size", try object.PyObject.newInt(allocator, self.cache.count()));
        try dict.put("hits", try object.PyObject.newInt(allocator, self.hits));
        try dict.put("misses", try object.PyObject.newInt(allocator, self.misses));
        try dict.put("currsize", try object.PyObject.newInt(allocator, self.cache.count()));
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = object.ModuleValue{
            .name = "lru_cache_info",
            .dict = dict,
            .file = null,
        }});
    }

    pub fn clear(self: *LRUCache) void {
        self.cache.clear();
        self.hits = 0;
        self.misses = 0;
        self.full = false;
    }
};

// === total_ordering decorator ===

pub fn total_ordering(cls: object.ObjectPtr) object.ObjectPtr {
    // Add comparison methods based on __eq__ and one comparison method
    _ = cls;
    return cls;
}

// === reduce (moved to functools from functools.reduce) ===

pub fn reduce(callback: object.ObjectPtr, sequence: object.ObjectPtr, initial: ?object.ObjectPtr, allocator: Allocator) !object.ObjectPtr {
    var accumulator = initial orelse object.PyObject.newNone(allocator);
    
    if (sequence.value == .List) {
        for (sequence.value.List.items.items) |item| {
            // Call callback(accumulator, item)
            _ = callback;
            accumulator = item;
        }
    }
    
    return accumulator;
}

// === cmp_to_key ===

pub const CmpToKey = struct {
    converter: object.ObjectPtr,

    pub fn init(converter: object.ObjectPtr) CmpToKey {
        return .{ .converter = converter };
    }
};

// === Functools module ===

pub const FunctoolsModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        // Classes
        try dict.put("partial", try createClass(allocator, "partial", &[_]BuiltinMethod{}));
        try dict.put("cached_property", try createClass(allocator, "cached_property", &[_]BuiltinMethod{}));
        try dict.put("lru_cache", try createClass(allocator, "lru_cache", &[_]BuiltinMethod{
            .{ .name = "cache_info", .func = lruCacheInfo },
            .{ .name = "cache_clear", .func = lruCacheClear },
        }));
        try dict.put("WRAPPER_ASSIGNMENTS", try object.PyObject.newTuple(allocator, &.{
            try object.PyObject.newStr(allocator, "__module__"),
            try object.PyObject.newStr(allocator, "__name__"),
            try object.PyObject.newStr(allocator, "__qualname__"),
            try object.PyObject.newStr(allocator, "__annotations__"),
            try object.PyObject.newStr(allocator, "__doc__"),
        }));
        try dict.put("WRAPPER_UPDATES", try object.PyObject.newTuple(allocator, &.{
            try object.PyObject.newStr(allocator, "__dict__"),
        }));
        try dict.put("UPDATE_WRAPPERS", try createBuiltin(allocator, "update_wrappers", updateWrappers));
        try dict.put("wraps", try createBuiltin(allocator, "wraps", wraps));
        try dict.put("total_ordering", try createBuiltin(allocator, "total_ordering", totalOrdering));
        try dict.put("cmp_to_key", try createBuiltin(allocator, "cmp_to_key", cmpToKey));

        // reduce is in functools (was in functools until Python 3.8)
        try dict.put("reduce", try createBuiltin(allocator, "reduce", reduce_));

        // Constants
        try dict.put("RLock", try object.PyObject.newNone(allocator));

        const module_val = object.ModuleValue{
            .name = "functools",
            .dict = dict,
            .file = "functools (Zig)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    const BuiltinMethod = struct {
        name: []const u8,
        func: object.BuiltinFn,
    };

    fn createBuiltin(allocator: Allocator, name: []const u8, func: object.BuiltinFn) !object.ObjectPtr {
        _ = name;
        return try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = func });
    }

    fn createClass(allocator: Allocator, name: []const u8, methods: []const BuiltinMethod) !object.ObjectPtr {
        var class_dict = std.StringHashMap(object.ObjectPtr).init(allocator);
        for (methods) |m| {
            const fn_obj = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = m.func });
            try class_dict.put(m.name, fn_obj);
        }
        const class_val = object.ModuleValue{ .name = name, .dict = class_dict, .file = null };
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = class_val });
    }

    fn lruCacheInfo(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = object.ModuleValue{
            .name = "lru_cache_info",
            .dict = std.StringHashMap(object.ObjectPtr).init(allocator),
            .file = null,
        }});
    }

    fn lruCacheClear(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn updateWrappers(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn wraps(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try createBuiltin(allocator, "wrapper", noop);
    }

    fn totalOrdering(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn cmpToKey(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try createClass(allocator, "K", &[_]BuiltinMethod{});
    }

    fn reduce_(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 2) return error.TypeError;
        return try object.PyObject.newNone(allocator);
    }

    fn noop(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }
};
