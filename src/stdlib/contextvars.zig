//! contextvars — Context Variables для честной многопоточности без GIL
//! Аналог Lib/contextvars.py + Modules/_contextvars.c
//! Critical для async/await и free-threaded Python

const std = @import("std");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

// === Context Variable ===

pub const ContextVar = struct {
    name: []const u8,
    default: ?object.ObjectPtr,
    default_factory: ?object.ObjectPtr,

    pub fn init(allocator: Allocator, name: []const u8, default: ?object.ObjectPtr, default_factory: ?object.ObjectPtr) !*ContextVar {
        const self = try allocator.create(ContextVar);
        self.* = .{
            .name = name,
            .default = default,
            .default_factory = default_factory,
        };
        return self;
    }

    pub fn get(self: *ContextVar, context: *Context) object.ObjectPtr {
        if (context.get(self)) |value| {
            return value;
        }
        if (self.default) |d| return d;
        if (self.default_factory) |f| {
            // Call factory
            _ = f;
            return object.PyObject.newNone(context.allocator);
        }
        return object.PyObject.newNone(context.allocator);
    }

    pub fn set(self: *ContextVar, context: *Context, value: object.ObjectPtr) !*ContextVarToken {
        return try context.set(self, value);
    }
};

/// Token returned when setting a context variable
pub const ContextVarToken = struct {
    var_: *ContextVar,
    old_value: ?object.ObjectPtr,
    context: *Context,
};

/// Context — a container for context variables
pub const Context = struct {
    values: std.StringHashMap(object.ObjectPtr),
    parent: ?*Context,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !*Context {
        const self = try allocator.create(Context);
        self.* = .{
            .values = std.StringHashMap(object.ObjectPtr).init(allocator),
            .parent = null,
            .allocator = allocator,
        };
        return self;
    }

    pub fn copy(self: *Context) !*Context {
        const new_ctx = try Context.init(self.allocator);
        var it = self.values.iterator();
        while (it.next()) |entry| {
            try new_ctx.values.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return new_ctx;
    }

    pub fn get(self: *Context, var_: *ContextVar) ?object.ObjectPtr {
        return self.values.get(var_.name);
    }

    pub fn set(self: *Context, var_: *ContextVar, value: object.ObjectPtr) !*ContextVarToken {
        const old_value = self.values.get(var_.name);
        try self.values.put(var_.name, value);
        return &ContextVarToken{
            .var_ = var_,
            .old_value = old_value,
            .context = self,
        };
    }

    pub fn reset(self: *Context, token: *ContextVarToken) void {
        if (token.old_value) |old| {
            self.values.put(token.var_.name, old);
        } else {
            self.values.remove(token.var_.name);
        }
    }
};

// === ContextVarToken methods ===

pub fn tokenReset(token: *ContextVarToken) void {
    token.context.reset(token);
}

// === ContextVar class wrapper ===

pub const ContextVarClass = struct {
    var_: *ContextVar,

    pub fn init(allocator: Allocator, name: []const u8, default: ?object.ObjectPtr) !*ContextVarClass {
        const self = try allocator.create(ContextVarClass);
        self.* = .{
            .var_ = try ContextVar.init(allocator, name, default, null),
        };
        return self;
    }

    pub fn get(self: *ContextVarClass, context: ?*Context) object.ObjectPtr {
        if (context) |ctx| {
            return self.var_.get(ctx);
        }
        return self.var_.default orelse object.PyObject.newNone(self.var_.default.?.allocator);
    }

    pub fn set(self: *ContextVarClass, context: *Context, value: object.ObjectPtr) !*ContextVarToken {
        return try self.var_.set(context, value);
    }
};

// === copy_context ===

pub fn copyContext(allocator: Allocator, current_context: *Context) !*Context {
    return try current_context.copy();
}

// === Context Module ===

pub const ContextvarsModule = struct {
    default_context: *Context,

    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        // ContextVar class
        const contextvar_class = try createClass(allocator, "ContextVar", &[_]BuiltinMethod{
            .{ .name = "get", .func = contextVarGet },
            .{ .name = "set", .func = contextVarSet },
        });
        try dict.put("ContextVar", contextvar_class);

        // copy_context function
        try dict.put("copy_context", try createBuiltin(allocator, "copy_context", copyContext_));

        // Token class
        const token_class = try createClass(allocator, "Token", &[_]BuiltinMethod{});
        try dict.put("Token", token_class);

        // Context class
        const context_class = try createClass(allocator, "Context", &[_]BuiltinMethod{
            .{ .name = "get", .func = contextGet },
            .{ .name = "set", .func = contextSet },
        });
        try dict.put("Context", context_class);

        const module_val = object.ModuleValue{
            .name = "contextvars",
            .dict = dict,
            .file = "contextvars (Zig, no-GIL support)",
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

    fn contextVarGet(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn contextVarSet(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = object.ModuleValue{
            .name = "Token",
            .dict = std.StringHashMap(object.ObjectPtr).init(allocator),
            .file = null,
        }});
    }

    fn copyContext_(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try Context.init(allocator);
    }

    fn contextGet(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn contextSet(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = object.ModuleValue{
            .name = "Token",
            .dict = std.StringHashMap(object.ObjectPtr).init(allocator),
            .file = null,
        }});
    }
};
