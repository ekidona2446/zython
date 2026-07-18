//! Компилятор Python - аналог Python/compile.c, Python/codegen.c, Python/flowgraph.c
//! Преобразует AST в CodeObject (байт-код)
//! Для совместимости с CPython PyCodeObject структура сохраняется, но генерация на Zig

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
    // Для отслеживания локалов
    filename: []const u8,
    name: []const u8,
    first_lineno: usize,

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
        // CPython wordcode: 2 bytes per instruction (opcode, arg) для Python 3.11+, но здесь упрощенно 1+2
        // Используем формат: opcode + uint16 arg (little endian) для MVP совместимости
        const arg_u16: u16 = @truncate(arg);
        try self.code.append(self.allocator, @truncate(arg_u16 & 0xFF));
        try self.code.append(self.allocator, @truncate((arg_u16 >> 8) & 0xFF));
    }

    fn addConst(self: *Compiler, obj: object.ObjectPtr) !u16 {
        // Проверка дубликатов для оптимизации (как в CPython)
        for (self.consts.items, 0..) |c, idx| {
            // упрощенная проверка по значению для int/str
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

        // В конце модуля RETURN None (как в CPython)
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
            .stacksize = 20, // оценка
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
                // Поддержка только Name targets для MVP
                for (assign.targets) |target| {
                    switch (target.node) {
                        .Name => |name| {
                            // Сохраняем как STORE_NAME или STORE_FAST в зависимости от контекста
                            // Для модуля - STORE_NAME, для функции - STORE_FAST
                            const idx = try self.addName(name.id);
                            try self.emit(.STORE_NAME, idx);
                        },
                        else => {
                            // TODO: attribute, subscript store
                            try self.emit(.POP_TOP, 0);
                        },
                    }
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
            .Pass => {},
            .Break => {}, // TODO: jump handling
            .Continue => {},
            else => {
                // Не реализовано для MVP
            },
        }
    }

    fn compileFunctionDef(self: *Compiler, func: ast.FunctionDef, is_async: bool) !void {
        _ = is_async;
        // Компилируем тело функции в отдельный CodeObject (как в CPython)
        var func_compiler = Compiler.init(self.allocator, self.filename, func.name);
        defer func_compiler.deinit();

        // Добавляем аргументы как varnames
        for (func.args.args) |arg| {
            _ = try func_compiler.addVarName(arg.arg);
        }

        for (func.body) |stmt| {
            try func_compiler.compileStmt(stmt);
        }

        // Implicit return None if not present
        const none_obj = try object.PyObject.newNone(self.allocator);
        const const_idx = try func_compiler.addConst(none_obj);
        try func_compiler.emit(.LOAD_CONST, const_idx);
        try func_compiler.emit(.RETURN_VALUE, 0);

        const func_code = try func_compiler.compileModule(.{ .body = func.body });

        // Создаем CodeObject как константу
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
        _ = self;
        _ = class;
        // TODO
    }

    fn compileIf(self: *Compiler, if_node: ast.If) !void {
        try self.compileExpr(if_node.test_expr.*);

        const jump_if_false_pos = self.code.items.len;
        try self.emit(.POP_JUMP_IF_FALSE, 0); // placeholder

        for (if_node.body) |stmt| {
            try self.compileStmt(stmt);
        }

        const jump_forward_pos = self.code.items.len;
        try self.emit(.JUMP_FORWARD, 0);

        // Patch POP_JUMP_IF_FALSE to jump to else
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
        try self.emit(.FOR_ITER, 0); // placeholder to exit

        // Target assignment
        switch (for_node.target.node) {
            .Name => |name| {
                const idx = try self.addName(name.id);
                try self.emit(.STORE_NAME, idx);
            },
            else => {},
        }

        for (for_node.body) |stmt| {
            try self.compileStmt(stmt);
        }

        try self.emit(.JUMP_ABSOLUTE, @truncate(loop_start));

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

        try self.emit(.JUMP_ABSOLUTE, @truncate(loop_start));

        const loop_end = self.code.items.len;
        self.patchJump(jump_pos, loop_end);

        for (while_node.else_body) |stmt| {
            try self.compileStmt(stmt);
        }
    }

    fn patchJump(self: *Compiler, jump_instr_pos: usize, target: usize) void {
        // jump_instr_pos указывает на начало инструкции (opcode)
        // arg находится в следующих 2 байтах
        // Вычисляем delta (как в CPython)
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
                // Проверяем varnames сначала (для функций)
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
                    else => 0,
                };
                try self.emit(.BINARY_OP, op_val);
            },
            .UnaryOp => |unary| {
                try self.compileExpr(unary.operand.*);
                const op: opcode.Opcode = switch (unary.op) {
                    .USub => .UNARY_NEGATIVE,
                    .UAdd => .UNARY_POSITIVE,
                    .Not => .UNARY_NOT,
                    .Invert => .UNARY_INVERT,
                };
                try self.emit(op, 0);
            },
            .Call => |call| {
                // Для простоты: LOAD func + args + CALL
                try self.compileExpr(call.func.*);
                for (call.args) |arg| {
                    try self.compileExpr(arg);
                }
                try self.emit(.CALL_FUNCTION, @truncate(call.args.len));
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
            .Attribute => |attr| {
                try self.compileExpr(attr.value.*);
                const idx = try self.addName(attr.attr);
                try self.emit(.LOAD_ATTR, idx);
            },
            .Subscript => |sub| {
                try self.compileExpr(sub.value.*);
                try self.compileExpr(sub.slice.*);
                try self.emit(.BINARY_SUBSCR, 0);
            },
            .Await => |awaited| {
                try self.compileExpr(awaited.*);
                // В Zython await мапится на ZYTHON_AWAIT_IO (libxev)
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
            else => {
                // TODO: остальные типы выражений
                const none_obj = try object.PyObject.newNone(self.allocator);
                const idx = try self.addConst(none_obj);
                try self.emit(.LOAD_CONST, idx);
            },
        }
    }
};
