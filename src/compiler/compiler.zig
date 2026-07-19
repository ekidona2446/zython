//! Компилятор Python — аналог Python/compile.c
//! Преобразует AST в CodeObject (байт-код)
//! Использует CPython 3.13 opcode numbering

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../parser/ast.zig");
const opcode = @import("../vm/opcode.zig");
const object = @import("../object/object.zig");

pub const Compiler = struct {
    allocator: Allocator,
    consts: std.ArrayList(object.ObjectPtr),
    names: std.ArrayList([]const u8),
    varnames: std.ArrayList([]const u8),
    code: std.ArrayList(u8),
    lnotab: std.ArrayList(u8),
    filename: []const u8,
    name: []const u8,
    first_lineno: usize,
    in_function: bool, // track if we're inside a function for STORE_FAST vs STORE_NAME

    pub fn init(allocator: Allocator, filename: []const u8, name: []const u8) Compiler {
        return .{
            .allocator = allocator,
            .consts = std.ArrayList(object.ObjectPtr).empty,
            .names = std.ArrayList([]const u8).empty,
            .varnames = std.ArrayList([]const u8).empty,
            .code = std.ArrayList(u8).empty,
            .lnotab = std.ArrayList(u8).empty,
            .filename = filename,
            .name = name,
            .first_lineno = 1,
            .in_function = false,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.consts.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.varnames.deinit(self.allocator);
        self.code.deinit(self.allocator);
        self.lnotab.deinit(self.allocator);
    }

    fn emit(self: *Compiler, op: opcode.Opcode, arg: u32) !void {
        try self.code.append(self.allocator, @intFromEnum(op));
        const arg_u16: u16 = @truncate(arg);
        try self.code.append(self.allocator, @truncate(arg_u16 & 0xFF));
        try self.code.append(self.allocator, @truncate((arg_u16 >> 8) & 0xFF));
    }

    fn addConst(self: *Compiler, obj: object.ObjectPtr) !u16 {
        for (self.consts.items, 0..) |c, idx| {
            if (c.type_ptr.type_id == obj.type_ptr.type_id) {
                switch (c.value) {
                    .Int => |iv1| switch (iv1) {
                        .Small => |v1| switch (obj.value) {
                            .Int => |iv2| switch (iv2) {
                                .Small => |v2| if (v1 == v2) return @truncate(idx),
                                else => {},
                            },
                            else => {},
                        },
                        else => {},
                    },
                    .Bool => |b1| switch (obj.value) {
                        .Bool => |b2| if (b1 == b2) return @truncate(idx),
                        else => {},
                    },
                    else => {},
                }
            }
        }
        try self.consts.append(self.allocator, obj);
        return @truncate(self.consts.items.len - 1);
    }

    fn addName(self: *Compiler, name: []const u8) !u16 {
        for (self.names.items, 0..) |n, idx| {
            if (std.mem.eql(u8, n, name)) return @truncate(idx);
        }
        const duped = try self.allocator.dupe(u8, name);
        try self.names.append(self.allocator, duped);
        return @truncate(self.names.items.len - 1);
    }

    fn addVarName(self: *Compiler, name: []const u8) !u16 {
        for (self.varnames.items, 0..) |n, idx| {
            if (std.mem.eql(u8, n, name)) return @truncate(idx);
        }
        const duped = try self.allocator.dupe(u8, name);
        try self.varnames.append(self.allocator, duped);
        return @truncate(self.varnames.items.len - 1);
    }

    pub fn compileModule(self: *Compiler, mod: ast.Module) !*object.CodeObject {
        self.first_lineno = if (mod.body.len > 0) mod.body[0].lineno else 1;

        for (mod.body) |stmt| {
            try self.compileStmt(stmt);
        }

        const none_obj = try object.PyObject.newNone(self.allocator);
        const const_idx = try self.addConst(none_obj);
        try self.emit(.LOAD_CONST, const_idx);
        try self.emit(.RETURN_VALUE, 0);

        const code_obj = try self.allocator.create(object.CodeObject);
        code_obj.* = .{
            .filename = self.filename,
            .name = self.name,
            .first_lineno = self.first_lineno,
            .argcount = 0,
            .kwonlyargcount = 0,
            .nlocals = @truncate(self.varnames.items.len),
            .stacksize = 20,
            .flags = .{},
            .code = try self.allocator.dupe(u8, self.code.items),
            .consts = try self.allocator.dupe(object.ObjectPtr, self.consts.items),
            .names = try self.allocator.dupe([]const u8, self.names.items),
            .varnames = try self.allocator.dupe([]const u8, self.varnames.items),
        };

        return code_obj;
    }

    fn compileStmt(self: *Compiler, stmt: ast.Stmt) anyerror!void {
        switch (stmt.node) {
            .FunctionDef => |func| try self.compileFunctionDef(func, false),
            .AsyncFunctionDef => |func| try self.compileFunctionDef(func, true),
            .ClassDef => |class| try self.compileClassDef(class),
            .Return => |ret_opt| {
                if (ret_opt) |ret| {
                    try self.compileExpr(ret.*);
                } else {
                    const none_obj = try object.PyObject.newNone(self.allocator);
                    const idx = try self.addConst(none_obj);
                    try self.emit(.LOAD_CONST, idx);
                }
                try self.emit(.RETURN_VALUE, 0);
            },
            .Assign => |assign| {
                try self.compileExpr(assign.value.*);
                for (assign.targets) |target| {
                    switch (target.node) {
                        .Name => |name| {
                            if (self.in_function) {
                                const idx = try self.addVarName(name.id);
                                try self.emit(.STORE_FAST, idx);
                            } else {
                                const idx = try self.addName(name.id);
                                try self.emit(.STORE_NAME, idx);
                            }
                        },
                        .Attribute => |attr| {
                            const idx = try self.addName(attr.attr);
                            try self.emit(.STORE_ATTR, idx);
                        },
                        .Subscript => |sub| {
                            try self.compileExpr(sub.slice.*);
                            try self.emit(.STORE_SUBSCR, 0);
                        },
                        else => {
                            try self.emit(.POP_TOP, 0);
                        },
                    }
                }
            },
            .AugAssign => |aug| {
                // x += 1  =>  load x, load 1, BINARY_OP(INPLACE_ADD), store x
                try self.compileExpr(aug.target.*);
                try self.compileExpr(aug.value.*);
                const op_val: u8 = switch (aug.op) {
                    .Add => 13, // INPLACE_ADD
                    .Sub => 23, // INPLACE_SUBTRACT
                    .Mult => 18, // INPLACE_MULTIPLY
                    .Div => 24, // INPLACE_TRUE_DIVIDE
                    .Mod => 19, // INPLACE_REMAINDER
                    .Pow => 21, // INPLACE_POWER
                    .FloorDiv => 15, // INPLACE_FLOOR_DIVIDE
                    else => 0,
                };
                try self.emit(.BINARY_OP, op_val);
                switch (aug.target.node) {
                    .Name => |name| {
                        if (self.in_function) {
                            const idx = try self.addVarName(name.id);
                            try self.emit(.STORE_FAST, idx);
                        } else {
                            const idx = try self.addName(name.id);
                            try self.emit(.STORE_NAME, idx);
                        }
                    },
                    else => try self.emit(.POP_TOP, 0),
                }
            },
            .Expr => |expr| {
                try self.compileExpr(expr);
                try self.emit(.POP_TOP, 0);
            },
            .If => |if_node| try self.compileIf(if_node),
            .For => |for_node| try self.compileFor(for_node),
            .While => |while_node| try self.compileWhile(while_node),
            .Import => |aliases| {
                for (aliases) |alias| {
                    const name_idx = try self.addName(alias.name);
                    try self.emit(.LOAD_CONST, 0); // level
                    try self.emit(.LOAD_CONST, 0); // fromlist
                    try self.emit(.IMPORT_NAME, name_idx);
                    const store_idx = try self.addName(alias.asname orelse alias.name);
                    try self.emit(.STORE_NAME, store_idx);
                }
            },
            .ImportFrom => |imp| {
                const mod_idx = try self.addName(imp.module_name orelse "");
                try self.emit(.LOAD_CONST, @truncate(imp.level));
                const fromlist_none = try object.PyObject.newNone(self.allocator);
                const fromlist_idx = try self.addConst(fromlist_none);
                try self.emit(.LOAD_CONST, fromlist_idx);
                try self.emit(.IMPORT_NAME, mod_idx);
                for (imp.names) |alias| {
                    const attr_idx = try self.addName(alias.name);
                    try self.emit(.IMPORT_FROM, attr_idx);
                    const store_idx = try self.addName(alias.asname orelse alias.name);
                    try self.emit(.STORE_NAME, store_idx);
                }
                try self.emit(.POP_TOP, 0); // pop the module
            },
            .Pass => {},
            .Break => {
                // Simplified: JUMP_FORWARD to loop end (would need block_stack for proper impl)
            },
            .Continue => {
                // Simplified: JUMP_ABSOLUTE to loop start
            },
            .Try => |try_node| try self.compileTry(try_node),
            .Raise => |raise_opt| {
                if (raise_opt) |raise| {
                    if (raise.exc) |exc_ptr| {
                        try self.compileExpr(exc_ptr.*);
                    } else {
                        const none_obj = try object.PyObject.newNone(self.allocator);
                        const idx = try self.addConst(none_obj);
                        try self.emit(.LOAD_CONST, idx);
                    }
                    try self.emit(.RAISE_VARARGS, 1);
                } else {
                    try self.emit(.RAISE_VARARGS, 0);
                }
            },
            .Assert => |assert_stmt| {
                try self.compileExpr(assert_stmt.test_expr.*);
                const jump_pos = self.code.items.len;
                try self.emit(.POP_JUMP_IF_TRUE, 0); // if truthy, skip
                // AssertionError
                if (assert_stmt.msg) |msg| {
                    try self.compileExpr(msg.*);
                    try self.emit(.RAISE_VARARGS, 1);
                } else {
                    try self.emit(.RAISE_VARARGS, 1);
                }
                self.patchJump(jump_pos, self.code.items.len);
            },
            .Global => {},
            .Nonlocal => {},
            .Delete => |targets| {
                for (targets) |target| {
                    switch (target.node) {
                        .Name => |name| {
                            const idx = try self.addName(name.id);
                            try self.emit(.DELETE_FAST, idx); // simplified
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    fn compileFunctionDef(self: *Compiler, func: ast.FunctionDef, is_async: bool) !void {
        _ = is_async;
        var func_compiler = Compiler.init(self.allocator, self.filename, func.name);
        defer func_compiler.deinit();
        func_compiler.in_function = true;

        for (func.args.args) |arg| {
            _ = try func_compiler.addVarName(arg.arg);
        }

        for (func.body) |stmt| {
            try func_compiler.compileStmt(stmt);
        }

        const none_obj = try object.PyObject.newNone(self.allocator);
        const const_idx = try func_compiler.addConst(none_obj);
        try func_compiler.emit(.LOAD_CONST, const_idx);
        try func_compiler.emit(.RETURN_VALUE, 0);

        const func_code = try func_compiler.compileModule(.{ .body = func.body });

        const code_obj_wrapper = try self.allocator.create(object.PyObject);
        code_obj_wrapper.* = .{
            .refcnt = 1,
            .type_ptr = &object.CodeType,
            .value = .{ .Code = func_code },
            .allocator = self.allocator,
        };

        const code_const_idx = try self.addConst(code_obj_wrapper);
        try self.emit(.LOAD_CONST, code_const_idx);
        try self.emit(.LOAD_CONST, code_const_idx); // qualname placeholder
        try self.emit(.MAKE_FUNCTION, 0);

        const name_idx = try self.addName(func.name);
        try self.emit(.STORE_NAME, name_idx);
    }

    fn compileClassDef(self: *Compiler, class: ast.ClassDef) !void {
        // Load __build_class__ helper
        const build_class_idx = try self.addName("__build_class__");
        try self.emit(.LOAD_NAME, build_class_idx);

        // Compile class body as a function
        var class_compiler = Compiler.init(self.allocator, self.filename, class.name);
        defer class_compiler.deinit();
        class_compiler.in_function = true;

        for (class.body) |stmt| {
            try class_compiler.compileStmt(stmt);
        }

        const none_obj = try object.PyObject.newNone(self.allocator);
        const const_idx = try class_compiler.addConst(none_obj);
        try class_compiler.emit(.LOAD_CONST, const_idx);
        try class_compiler.emit(.RETURN_VALUE, 0);

        const class_code = try class_compiler.compileModule(.{ .body = class.body });
        const code_wrapper = try self.allocator.create(object.PyObject);
        code_wrapper.* = .{
            .refcnt = 1,
            .type_ptr = &object.CodeType,
            .value = .{ .Code = class_code },
            .allocator = self.allocator,
        };

        const code_idx = try self.addConst(code_wrapper);
        try self.emit(.LOAD_CONST, code_idx);
        try self.emit(.LOAD_CONST, code_idx); // qualname
        try self.emit(.MAKE_FUNCTION, 0);

        // Class name
        const name_obj = try object.PyObject.newStr(self.allocator, class.name);
        const name_const_idx = try self.addConst(name_obj);
        try self.emit(.LOAD_CONST, name_const_idx);

        // Call __build_class__(func, name, *bases)
        const total_args = 2 + class.bases.len;
        try self.emit(.CALL_FUNCTION, @truncate(total_args));

        const store_idx = try self.addName(class.name);
        try self.emit(.STORE_NAME, store_idx);
    }

    fn compileIf(self: *Compiler, if_node: ast.If) !void {
        try self.compileExpr(if_node.test_expr.*);

        const jump_if_false_pos = self.code.items.len;
        try self.emit(.POP_JUMP_IF_FALSE, 0);

        for (if_node.body) |stmt| {
            try self.compileStmt(stmt);
        }

        const jump_forward_pos = self.code.items.len;
        try self.emit(.JUMP_FORWARD, 0);

        const else_start = self.code.items.len;
        self.patchJump(jump_if_false_pos, else_start);

        for (if_node.else_body) |stmt| {
            try self.compileStmt(stmt);
        }

        const end_pos = self.code.items.len;
        self.patchJump(jump_forward_pos, end_pos);
    }

    fn compileFor(self: *Compiler, for_node: ast.For) !void {
        try self.compileExpr(for_node.iter.*);
        try self.emit(.GET_ITER, 0);

        const loop_start = self.code.items.len;

        const for_iter_pos = self.code.items.len;
        try self.emit(.FOR_ITER, 0);

        switch (for_node.target.node) {
            .Name => |name| {
                if (self.in_function) {
                    const idx = try self.addVarName(name.id);
                    try self.emit(.STORE_FAST, idx);
                } else {
                    const idx = try self.addName(name.id);
                    try self.emit(.STORE_NAME, idx);
                }
            },
            else => {},
        }

        for (for_node.body) |stmt| {
            try self.compileStmt(stmt);
        }

        try self.emit(.JUMP_BACKWARD, @truncate(loop_start));

        const loop_end = self.code.items.len;
        self.patchJump(for_iter_pos, loop_end);

        for (for_node.else_body) |stmt| {
            try self.compileStmt(stmt);
        }
    }

    fn compileWhile(self: *Compiler, while_node: ast.While) !void {
        const loop_start = self.code.items.len;

        try self.compileExpr(while_node.test_expr.*);
        const jump_pos = self.code.items.len;
        try self.emit(.POP_JUMP_IF_FALSE, 0);

        for (while_node.body) |stmt| {
            try self.compileStmt(stmt);
        }

        try self.emit(.JUMP_BACKWARD, @truncate(loop_start));

        const loop_end = self.code.items.len;
        self.patchJump(jump_pos, loop_end);

        for (while_node.else_body) |stmt| {
            try self.compileStmt(stmt);
        }
    }

    fn compileTry(self: *Compiler, try_node: ast.Try) !void {
        // Compile try body
        for (try_node.body) |stmt| {
            try self.compileStmt(stmt);
        }

        // Jump over except handlers
        const jump_over_except_pos = self.code.items.len;
        try self.emit(.JUMP_FORWARD, 0);

        // Compile except handlers
        for (try_node.handlers) |handler| {
            if (handler.type_expr) |exc_type| {
                try self.compileExpr(exc_type.*);
                try self.emit(.COMPARE_OP, @intFromEnum(opcode.CompareOp.EXC_MATCH));
                const check_pos = self.code.items.len;
                try self.emit(.POP_JUMP_IF_FALSE, 0);
                for (handler.body) |stmt| {
                    try self.compileStmt(stmt);
                }
                try self.emit(.POP_EXCEPT, 0);
                const after_handler = self.code.items.len;
                self.patchJump(check_pos, after_handler);
            } else {
                for (handler.body) |stmt| {
                    try self.compileStmt(stmt);
                }
                try self.emit(.POP_EXCEPT, 0);
            }
        }

        const after_all = self.code.items.len;
        self.patchJump(jump_over_except_pos, after_all);

        // else body
        for (try_node.else_body) |stmt| {
            try self.compileStmt(stmt);
        }

        // finally body
        for (try_node.finalbody) |stmt| {
            try self.compileStmt(stmt);
        }
    }

    fn patchJump(self: *Compiler, jump_instr_pos: usize, target: usize) void {
        const arg_pos = jump_instr_pos + 1;
        if (arg_pos + 1 >= self.code.items.len) return;
        const delta: u16 = @truncate(target);
        self.code.items[arg_pos] = @truncate(delta & 0xFF);
        self.code.items[arg_pos + 1] = @truncate((delta >> 8) & 0xFF);
    }

    fn compileExpr(self: *Compiler, expr: ast.Expr) anyerror!void {
        switch (expr.node) {
            .Constant => |c| {
                const obj = switch (c) {
                    .None => try object.PyObject.newNone(self.allocator),
                    .Bool => |b| try object.PyObject.newBool(self.allocator, b),
                    .Int => |int_str| blk: {
                        const v = std.fmt.parseInt(i64, int_str, 10) catch 0;
                        break :blk try object.PyObject.newInt(self.allocator, v);
                    },
                    .Float => |f| try object.PyObject.newFloat(self.allocator, f),
                    .Str => |s| try object.PyObject.newStr(self.allocator, s),
                    .Ellipsis => try object.PyObject.newNone(self.allocator),
                    else => try object.PyObject.newNone(self.allocator),
                };
                const idx = try self.addConst(obj);
                try self.emit(.LOAD_CONST, idx);
            },
            .Name => |name| {
                for (self.varnames.items, 0..) |vn, i| {
                    if (std.mem.eql(u8, vn, name.id)) {
                        try self.emit(.LOAD_FAST, @truncate(i));
                        return;
                    }
                }
                const idx = try self.addName(name.id);
                try self.emit(.LOAD_NAME, idx);
            },
            .BinOp => |binop| {
                try self.compileExpr(binop.left.*);
                try self.compileExpr(binop.right.*);
                const op_val: u8 = switch (binop.op) {
                    .Add => 0,
                    .Sub => 10,
                    .Mult => 5,
                    .Div => 11,
                    .Mod => 6,
                    .Pow => 8,
                    .FloorDiv => 2,
                    .BitOr => 7,
                    .BitAnd => 1,
                    .BitXor => 12,
                    .LShift => 3,
                    .RShift => 9,
                    .MatMult => 4,
                };
                try self.emit(.BINARY_OP, op_val);
            },
            .UnaryOp => |unary| {
                try self.compileExpr(unary.operand.*);
                const op: opcode.Opcode = switch (unary.op) {
                    .USub => .UNARY_NEGATIVE,
                    .UAdd => .NOP, // positive is a no-op
                    .Not => .UNARY_NOT,
                    .Invert => .UNARY_INVERT,
                };
                try self.emit(op, 0);
            },
            .Call => |call| {
                // CPython 3.13: PUSH_NULL + LOAD func + args + CALL
                try self.emit(.PUSH_NULL, 0);
                try self.compileExpr(call.func.*);
                for (call.args) |call_arg| {
                    try self.compileExpr(call_arg);
                }
                try self.emit(.CALL, @truncate(call.args.len));
            },
            .List => |items| {
                for (items) |item| {
                    try self.compileExpr(item);
                }
                try self.emit(.BUILD_LIST, @truncate(items.len));
            },
            .Tuple => |items| {
                for (items) |item| {
                    try self.compileExpr(item);
                }
                try self.emit(.BUILD_TUPLE, @truncate(items.len));
            },
            .Dict => |dict_node| {
                // Key-value pairs on stack
                var i: usize = 0;
                while (i < dict_node.keys.len and i < dict_node.values.len) : (i += 1) {
                    if (dict_node.keys[i]) |key| {
                        try self.compileExpr(key);
                    } else {
                        const none = try object.PyObject.newNone(self.allocator);
                        const idx = try self.addConst(none);
                        try self.emit(.LOAD_CONST, idx);
                    }
                    try self.compileExpr(dict_node.values[i]);
                }
                try self.emit(.BUILD_MAP, @truncate(i));
            },
            .Attribute => |attr| {
                try self.compileExpr(attr.value.*);
                const idx = try self.addName(attr.attr);
                try self.emit(.LOAD_ATTR, idx);
            },
            .Subscript => |sub| {
                try self.compileExpr(sub.value.*);
                try self.compileExpr(sub.slice.*);
                try self.emit(.BINARY_SLICE, 0);
            },
            .Await => |awaited| {
                try self.compileExpr(awaited.*);
                try self.emit(.ZYTHON_AWAIT_IO, 0);
            },
            .Yield => |val_opt| {
                if (val_opt) |v| {
                    try self.compileExpr(v.*);
                } else {
                    const none_obj = try object.PyObject.newNone(self.allocator);
                    const idx = try self.addConst(none_obj);
                    try self.emit(.LOAD_CONST, idx);
                }
                try self.emit(.YIELD_VALUE, 0);
            },
            .Compare => |cmp| {
                try self.compileExpr(cmp.left.*);
                for (cmp.comparators, 0..) |comp, i| {
                    try self.compileExpr(comp);
                    const cmp_op: u8 = switch (cmp.ops[i]) {
                        .Eq => 2,
                        .NotEq => 3,
                        .Lt => 0,
                        .LtE => 1,
                        .Gt => 4,
                        .GtE => 5,
                        .In => 6,
                        .NotIn => 7,
                        .Is => 8,
                        .IsNot => 9,
                    };
                    try self.emit(.COMPARE_OP, cmp_op);
                }
            },
            .BoolOp => |boolop| {
                const jump_op: opcode.Opcode = switch (boolop.op) {
                    .And => .POP_JUMP_IF_FALSE,
                    .Or => .POP_JUMP_IF_TRUE,
                };
                // Evaluate first value
                if (boolop.values.len > 0) {
                    try self.compileExpr(boolop.values[0]);
                    for (boolop.values[1..]) |val| {
                        // Copy current value (will be consumed by jump or left on stack)
                        try self.emit(.COPY, 0);
                        const jump_pos = self.code.items.len;
                        try self.emit(jump_op, 0);
                        // Pop the old value, push new one
                        try self.emit(.POP_TOP, 0);
                        try self.compileExpr(val);
                        self.patchJump(jump_pos, self.code.items.len);
                    }
                }
            },
            .IfExp => |ifexp| {
                try self.compileExpr(ifexp.test_expr.*);
                const jump_false = self.code.items.len;
                try self.emit(.POP_JUMP_IF_FALSE, 0);
                try self.compileExpr(ifexp.body.*);
                const jump_end = self.code.items.len;
                try self.emit(.JUMP_FORWARD, 0);
                self.patchJump(jump_false, self.code.items.len);
                try self.compileExpr(ifexp.else_expr.*);
                self.patchJump(jump_end, self.code.items.len);
            },
            else => {
                const none_obj = try object.PyObject.newNone(self.allocator);
                const idx = try self.addConst(none_obj);
                try self.emit(.LOAD_CONST, idx);
            },
        }
    }
};
