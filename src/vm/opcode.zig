//! Байт-коды Python - аналог Include/opcode.h и Python/ceval.c
//! Совместимость с CPython 3.12+ opcodes
//! Zython использует тот же набор опкодов для совместимости, но с оптимизациями через Zig
//! Все значения уникальны (исправлено для Zig 0.16 - enum не допускает дубликатов)

pub const Opcode = enum(u8) {
    CACHE = 0,
    POP_TOP = 1,
    PUSH_NULL = 2,
    NOP = 9,
    UNARY_POSITIVE = 10,
    UNARY_NEGATIVE = 11,
    UNARY_NOT = 12,
    UNARY_INVERT = 15,
    BINARY_SUBSCR = 25,
    BINARY_SLICE = 26,
    STORE_SLICE = 27,
    GET_LEN = 30,
    MATCH_MAPPING = 31,
    MATCH_SEQUENCE = 32,
    MATCH_KEYS = 33,
    PUSH_EXC_INFO = 35,
    CHECK_EXC_MATCH = 36,
    CHECK_EG_MATCH = 37,

    // MVP core - совместимость с Python 3.12 wordcode
    RETURN_VALUE = 83,
    IMPORT_STAR = 84,
    YIELD_VALUE = 86,
    POP_JUMP_IF_FALSE = 114,
    POP_JUMP_IF_TRUE = 115,
    LOAD_GLOBAL = 116,
    LOAD_FAST = 124,
    STORE_FAST = 125,
    DELETE_FAST = 126,
    LOAD_CONST = 100,
    LOAD_NAME = 101,
    BUILD_TUPLE = 102,
    BUILD_LIST = 103,
    BUILD_SET = 104,
    BUILD_MAP = 105,
    LOAD_ATTR = 106,
    COMPARE_OP = 107,
    IMPORT_NAME = 108,
    IMPORT_FROM = 109,
    JUMP_FORWARD = 110,
    JUMP_IF_FALSE_OR_POP = 111,
    JUMP_IF_TRUE_OR_POP = 112,
    JUMP_ABSOLUTE = 113,
    STORE_NAME = 90,
    STORE_GLOBAL = 97,
    DELETE_NAME = 91,
    STORE_ATTR = 95,
    LOAD_METHOD = 160,
    CALL = 171,
    CALL_FUNCTION = 131,
    CALL_METHOD = 161,
    GET_ITER = 68,
    FOR_ITER = 93,
    LIST_APPEND = 145,
    BUILD_SLICE = 133,
    BUILD_STRING = 157,
    IS_OP = 117,
    CONTAINS_OP = 118,
    RAISE_VARARGS = 130,
    MAKE_FUNCTION = 132,
    MAKE_CLOSURE = 134,
    LOAD_CLOSURE = 135,
    LOAD_DEREF = 136,
    STORE_DEREF = 137,
    DELETE_DEREF = 138,
    LOAD_CLASSDEREF = 148,
    EXTENDED_ARG = 144,
    YIELD_FROM = 72,
    GET_YIELD_FROM_ITER = 69,
    PRINT_EXPR = 70,
    AWAIT = 73,
    GET_AWAITABLE = 74,
    GET_AITER = 76,
    GET_ANEXT = 77,
    END_ASYNC_FOR = 78,
    BEFORE_ASYNC_WITH = 81,
    SETUP_ASYNC_WITH = 154,
    FORMAT_VALUE = 155,

    BINARY_OP = 122,

    // Zython-specific async opcodes leveraging libxev
    ZYTHON_AWAIT_IO = 240,
    ZYTHON_ASYNC_CALL = 241,
    ZYTHON_YIELD_XEV = 242,

    _,

    pub fn hasArg(self: Opcode) bool {
        return @intFromEnum(self) >= 90;
    }

    pub fn toString(self: Opcode) []const u8 {
        return switch (self) {
            .POP_TOP => "POP_TOP",
            .PUSH_NULL => "PUSH_NULL",
            .NOP => "NOP",
            .LOAD_CONST => "LOAD_CONST",
            .LOAD_NAME => "LOAD_NAME",
            .LOAD_GLOBAL => "LOAD_GLOBAL",
            .LOAD_FAST => "LOAD_FAST",
            .STORE_NAME => "STORE_NAME",
            .STORE_FAST => "STORE_FAST",
            .LOAD_ATTR => "LOAD_ATTR",
            .STORE_ATTR => "STORE_ATTR",
            .CALL => "CALL",
            .CALL_FUNCTION => "CALL_FUNCTION",
            .RETURN_VALUE => "RETURN_VALUE",
            .POP_JUMP_IF_FALSE => "POP_JUMP_IF_FALSE",
            .POP_JUMP_IF_TRUE => "POP_JUMP_IF_TRUE",
            .JUMP_FORWARD => "JUMP_FORWARD",
            .JUMP_ABSOLUTE => "JUMP_ABSOLUTE",
            .GET_ITER => "GET_ITER",
            .FOR_ITER => "FOR_ITER",
            .BUILD_LIST => "BUILD_LIST",
            .BUILD_TUPLE => "BUILD_TUPLE",
            .BUILD_MAP => "BUILD_MAP",
            .COMPARE_OP => "COMPARE_OP",
            .IMPORT_NAME => "IMPORT_NAME",
            .MAKE_FUNCTION => "MAKE_FUNCTION",
            .YIELD_VALUE => "YIELD_VALUE",
            .ZYTHON_AWAIT_IO => "ZYTHON_AWAIT_IO",
            .ZYTHON_ASYNC_CALL => "ZYTHON_ASYNC_CALL",
            else => "UNKNOWN_OPCODE",
        };
    }
};

pub const CompareOp = enum(u8) {
    LT = 0,
    LE = 1,
    EQ = 2,
    NE = 3,
    GT = 4,
    GE = 5,
    IN = 6,
    NOT_IN = 7,
    IS = 8,
    IS_NOT = 9,
    EXC_MATCH = 10,
    BAD = 11,
};

pub const BinaryOp = enum(u8) {
    ADD = 0,
    AND = 1,
    FLOOR_DIVIDE = 2,
    LSHIFT = 3,
    MATRIX_MULT = 4,
    MULTIPLY = 5,
    REMAINDER = 6,
    OR = 7,
    POWER = 8,
    RSHIFT = 9,
    SUBTRACT = 10,
    TRUE_DIVIDE = 11,
    XOR = 12,
    INPLACE_ADD = 13,
    INPLACE_AND = 14,
    INPLACE_FLOOR_DIVIDE = 15,
    INPLACE_LSHIFT = 16,
    INPLACE_MATRIX_MULT = 17,
    INPLACE_MULTIPLY = 18,
    INPLACE_REMAINDER = 19,
    INPLACE_OR = 20,
    INPLACE_POWER = 21,
    INPLACE_RSHIFT = 22,
    INPLACE_SUBTRACT = 23,
    INPLACE_TRUE_DIVIDE = 24,
    INPLACE_XOR = 25,
};

pub const Instruction = struct {
    opcode: Opcode,
    arg: u32,
    offset: usize,
    lineno: ?usize = null,
};

pub fn disassemble(code: []const u8, allocator: std.mem.Allocator) ![]Instruction {
    _ = allocator;
    _ = code;
    return &.{};
}

const std = @import("std");
