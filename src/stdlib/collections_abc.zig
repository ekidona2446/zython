//! collections.abc — Abstract Base Classes для коллекций
//! Аналог Lib/_collections_abc.py
//! Critical для typing module и совместимости с modern Python

const std = @import("std");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

// === ABC Meta classes ===

pub const ABCMeta = struct {
    name: []const u8,
    abcs: std.StringHashMap(object.ObjectPtr),

    pub fn init(allocator: Allocator) !ABCMeta {
        return .{
            .name = "ABCMeta",
            .abcs = std.StringHashMap(object.ObjectPtr).init(allocator),
        };
    }

    pub fn register(self: *ABCMeta, cls: object.ObjectPtr, subclass: object.ObjectPtr) !void {
        try self.abcs.put("registered", cls);
        _ = subclass;
    }

    pub fn registerSubclass(self: *ABCMeta, base: []const u8, sub: object.ObjectPtr) !void {
        _ = base;
        try self.abcs.put("subclass", sub);
    }
};

// === Hashable ===

pub const Hashable = struct {
    pub const __name__ = "Hashable";
    pub const __doc__ = "Abstract base class for hashable objects.";
    
    pub fn __hash__(self: *const Hashable) ?u64 {
        _ = self;
        return null; // Subclasses must implement
    }

    pub fn isinstance(obj: object.ObjectPtr) bool {
        // All immutable types are hashable
        return switch (obj.value) {
            .None, .Bool, .Int, .Float, .Str, .Tuple, .Bytes => true,
            else => false,
        };
    }
};

// === Iterable ===

pub const Iterable = struct {
    pub const __name__ = "Iterable";
    pub const __doc__ = "Abstract base class for iterable objects.";

    pub fn __iter__(self: *const Iterable) object.ObjectPtr {
        _ = self;
        unreachable; // Subclasses must implement
    }

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .Str, .List, .Tuple, .Dict, .Set => true,
            else => false,
        };
    }
};

// === Iterator ===

pub const Iterator = struct {
    pub const __name__ = "Iterator";
    pub const __doc__ = "Abstract base class for iterator objects.";
    
    // Iterator needs to track iteration state
    index: usize,
    source: object.ObjectPtr,

    pub fn init(source: object.ObjectPtr) Iterator {
        return .{
            .index = 0,
            .source = source,
        };
    }

    pub fn __iter__(self: *Iterator) object.ObjectPtr {
        return self.source;
    }

    pub fn __next__(self: *Iterator, allocator: Allocator) !?object.ObjectPtr {
        switch (self.source.value) {
            .List => |list| {
                if (self.index < list.items.items.len) {
                    const item = list.items.items[self.index];
                    self.index += 1;
                    return item;
                }
                return null;
            },
            .Tuple => |tuple| {
                if (self.index < tuple.len) {
                    const item = tuple[self.index];
                    self.index += 1;
                    return item;
                }
                return null;
            },
            .Str => |s| {
                if (self.index < s.len) {
                    const char = s[self.index];
                    self.index += 1;
                    // Return single-char string
                    var buf: [1]u8 = undefined;
                    buf[0] = char;
                    return try object.PyObject.newStr(allocator, &buf);
                }
                return null;
            },
            .Dict => |dict| {
                if (self.index < dict.count()) {
                    var it = dict.iterator();
                    var i: usize = 0;
                    while (it.next()) |entry| {
                        if (i == self.index) {
                            self.index += 1;
                            return entry.key_ptr.*;
                        }
                        i += 1;
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    pub fn isinstance(obj: object.ObjectPtr) bool {
        // Check if object has __iter__ and __next__
        return Iterable.isinstance(obj);
    }
};

// === Reversible ===

pub const Reversible = struct {
    pub const __name__ = "Reversible";
    pub const __doc__ = "Abstract base class for reversible iterable objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .List, .Tuple, .Str => true,
            else => false,
        };
    }
};

// === Collection ===

pub const Collection = struct {
    pub const __name__ = "Collection";
    pub const __doc__ = "Abstract base class for sized iterable containers.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return Iterable.isinstance(obj);
    }
};

// === Sequence ===

pub const Sequence = struct {
    pub const __name__ = "Sequence";
    pub const __doc__ = "Abstract base class for sequence objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .List, .Tuple, .Str, .Bytes => true,
            else => false,
        };
    }

    pub fn __getitem__(obj: object.ObjectPtr, index: i64, allocator: Allocator) !object.ObjectPtr {
        const len: i64 = switch (obj.value) {
            .List => |l| @intCast(l.items.items.len),
            .Tuple => |t| @intCast(t.len),
            .Str => |s| @intCast(s.len),
            .Bytes => |b| @intCast(b.len),
            else => return error.TypeError,
        };

        var idx = index;
        if (idx < 0) idx = len + idx;
        if (idx < 0 or idx >= len) return error.IndexError;

        switch (obj.value) {
            .List => |list| return list.items.items[@intCast(idx)],
            .Tuple => |tuple| return tuple[@intCast(idx)],
            .Str => |s| {
                const char = s[@intCast(idx)];
                var buf: [1]u8 = undefined;
                buf[0] = char;
                return try object.PyObject.newStr(allocator, &buf);
            },
            .Bytes => |b| {
                return try object.PyObject.newInt(allocator, b[@intCast(idx)]);
            },
            else => unreachable,
        }
    }

    pub fn __len__(obj: object.ObjectPtr) usize {
        return switch (obj.value) {
            .List => |l| l.items.items.len,
            .Tuple => |t| t.len,
            .Str => |s| s.len,
            .Bytes => |b| b.len,
            else => 0,
        };
    }

    pub fn __contains__(obj: object.ObjectPtr, item: object.ObjectPtr) bool {
        switch (obj.value) {
            .List => |list| {
                for (list.items.items) |i| {
                    if (object.equals(i, item)) return true;
                }
            },
            .Tuple => |tuple| {
                for (tuple) |i| {
                    if (object.equals(i, item)) return true;
                }
            },
            .Str => |s| {
                if (item.value == .Str) {
                    return std.mem.indexOf(u8, s, item.value.Str) != null;
                }
            },
            else => {},
        }
        return false;
    }
};

// === MutableSequence ===

pub const MutableSequence = struct {
    pub const __name__ = "MutableSequence";
    pub const __doc__ = "Abstract base class for mutable sequence objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .List => true,
            else => false,
        };
    }
};

// === ByteString ===

pub const ByteString = struct {
    pub const __name__ = "ByteString";
    pub const __doc__ = "Abstract base class for bytes and bytearray objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .Bytes => true,
            else => false,
        };
    }
};

// === Set ===

pub const Set = struct {
    pub const __name__ = "Set";
    pub const __doc__ = "Abstract base class for set objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .Set => true,
            else => false,
        };
    }
};

// === MutableSet ===

pub const MutableSet = struct {
    pub const __name__ = "MutableSet";
    pub const __doc__ = "Abstract base class for mutable set objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .Set => true, // In reality, only mutable sets
            else => false,
        };
    }
};

// === Mapping ===

pub const Mapping = struct {
    pub const __name__ = "Mapping";
    pub const __doc__ = "Abstract base class for mapping objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .Dict => true,
            else => false,
        };
    }

    pub fn __getitem__(obj: object.ObjectPtr, key: object.ObjectPtr, allocator: Allocator) !object.ObjectPtr {
        if (obj.value != .Dict) return error.TypeError;
        const dict = &obj.value.Dict;
        
        if (dict.getEntry(key.value.Str)) |entry| {
            return entry.value_ptr.*;
        }
        return error.KeyError;
    }

    pub fn __len__(obj: object.ObjectPtr) usize {
        if (obj.value != .Dict) return 0;
        return obj.value.Dict.count();
    }

    pub fn keys(obj: object.ObjectPtr, allocator: Allocator) !object.ObjectPtr {
        if (obj.value != .Dict) return error.TypeError;
        const list = try object.PyObject.newList(allocator);
        var it = obj.value.Dict.iterator();
        while (it.next()) |entry| {
            try list.value.List.items.append(allocator, entry.key_ptr.*);
        }
        return list;
    }

    pub fn values(obj: object.ObjectPtr, allocator: Allocator) !object.ObjectPtr {
        if (obj.value != .Dict) return error.TypeError;
        const list = try object.PyObject.newList(allocator);
        var it = obj.value.Dict.iterator();
        while (it.next()) |entry| {
            try list.value.List.items.append(allocator, entry.value_ptr.*);
        }
        return list;
    }

    pub fn items(obj: object.ObjectPtr, allocator: Allocator) !object.ObjectPtr {
        if (obj.value != .Dict) return error.TypeError;
        const list = try object.PyObject.newList(allocator);
        var it = obj.value.Dict.iterator();
        while (it.next()) |entry| {
            const tuple = try object.PyObject.newTuple(allocator, &.{entry.key_ptr.*, entry.value_ptr.*});
            try list.value.List.items.append(allocator, tuple);
        }
        return list;
    }
};

// === MutableMapping ===

pub const MutableMapping = struct {
    pub const __name__ = "MutableMapping";
    pub const __doc__ = "Abstract base class for mutable mapping objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .Dict => true,
            else => false,
        };
    }
};

// === Callable ===

pub const Callable = struct {
    pub const __name__ = "Callable";
    pub const __doc__ = "Abstract base class for callable objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .Function, .BuiltinFunction => true,
            else => false,
        };
    }
};

// === Awaitable, Coroutine ===

pub const Awaitable = struct {
    pub const __name__ = "Awaitable";
    pub const __doc__ = "Abstract base class for awaitable objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .Coroutine, .Generator => true,
            else => false,
        };
    }
};

pub const Coroutine = struct {
    pub const __name__ = "Coroutine";
    pub const __doc__ = "Abstract base class for coroutine objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .Coroutine => true,
            else => false,
        };
    }
};

// === AsyncIterator, AsyncIterable ===

pub const AsyncIterable = struct {
    pub const __name__ = "AsyncIterable";
    pub const __doc__ = "Abstract base class for async iterable objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        _ = obj;
        return false; // Not yet implemented
    }
};

pub const AsyncIterator = struct {
    pub const __name__ = "AsyncIterator";
    pub const __doc__ = "Abstract base class for async iterator objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        _ = obj;
        return false;
    }
};

// === Generator ===

pub const Generator = struct {
    pub const __name__ = "Generator";
    pub const __doc__ = "Abstract base class for generator objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        return switch (obj.value) {
            .Generator => true,
            else => false,
        };
    }
};

// === Buffer ===

pub const Buffer = struct {
    pub const __name__ = "Buffer";
    pub const __doc__ = "Abstract base class for buffer objects.";

    pub fn isinstance(obj: object.ObjectPtr) bool {
        _ = obj;
        return false;
    }
};

// === CollectionsABC Module ===

pub const CollectionsABCModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        // Hashable
        const hashable = try createClass(allocator, "Hashable", &[_]object.BuiltinFn{});
        try dict.put("Hashable", hashable);

        // Iterable
        const iterable = try createClass(allocator, "Iterable", &[_]object.BuiltinFn{});
        try dict.put("Iterable", iterable);

        // Iterator
        const iterator = try createClass(allocator, "Iterator", &[_]object.BuiltinFn{});
        try dict.put("Iterator", iterator);

        // Reversible
        const reversible = try createClass(allocator, "Reversible", &[_]object.BuiltinFn{});
        try dict.put("Reversible", reversible);

        // Collection
        const collection = try createClass(allocator, "Collection", &[_]object.BuiltinFn{});
        try dict.put("Collection", collection);

        // Sequence types
        const sequence = try createClass(allocator, "Sequence", &[_]object.BuiltinFn{});
        try dict.put("Sequence", sequence);

        const mutable_sequence = try createClass(allocator, "MutableSequence", &[_]object.BuiltinFn{});
        try dict.put("MutableSequence", mutable_sequence);

        // ByteString
        const bytestring = try createClass(allocator, "ByteString", &[_]object.BuiltinFn{});
        try dict.put("ByteString", bytestring);

        // Set types
        const set = try createClass(allocator, "Set", &[_]object.BuiltinFn{});
        try dict.put("Set", set);

        const mutable_set = try createClass(allocator, "MutableSet", &[_]object.BuiltinFn{});
        try dict.put("MutableSet", mutable_set);

        // Mapping types
        const mapping = try createClass(allocator, "Mapping", &[_]object.BuiltinFn{});
        try dict.put("Mapping", mapping);

        const mutable_mapping = try createClass(allocator, "MutableMapping", &[_]object.BuiltinFn{});
        try dict.put("MutableMapping", mutable_mapping);

        // Callable
        const callable = try createClass(allocator, "Callable", &[_]object.BuiltinFn{});
        try dict.put("Callable", callable);

        // Async types
        const awaitable = try createClass(allocator, "Awaitable", &[_]object.BuiltinFn{});
        try dict.put("Awaitable", awaitable);

        const coroutine = try createClass(allocator, "Coroutine", &[_]object.BuiltinFn{});
        try dict.put("Coroutine", coroutine);

        const async_iterable = try createClass(allocator, "AsyncIterable", &[_]object.BuiltinFn{});
        try dict.put("AsyncIterable", async_iterable);

        const async_iterator = try createClass(allocator, "AsyncIterator", &[_]object.BuiltinFn{});
        try dict.put("AsyncIterator", async_iterator);

        const async_generator = try createClass(allocator, "AsyncGenerator", &[_]object.BuiltinFn{});
        try dict.put("AsyncGenerator", async_generator);

        // Generator
        const generator = try createClass(allocator, "Generator", &[_]object.BuiltinFn{});
        try dict.put("Generator", generator);

        // Buffer
        const buffer = try createClass(allocator, "Buffer", &[_]object.BuiltinFn{});
        try dict.put("Buffer", buffer);

        // Generator ABC (alias)
        try dict.put("GeneratorABC", generator);

        const module_val = object.ModuleValue{
            .name = "collections.abc",
            .dict = dict,
            .file = "collections.abc (Zig)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn createClass(allocator: Allocator, name: []const u8, methods: []const object.BuiltinFn) !object.ObjectPtr {
        _ = methods;
        var class_dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        const class_val = object.ModuleValue{
            .name = name,
            .dict = class_dict,
            .file = null,
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = class_val });
    }
};
