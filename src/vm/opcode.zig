//! Набор байткод-опкодов Zython (аналог Include/opcode.h, но собственный).
//! Традиционная стек-машина: 1 байт op + 2 байта аргумент (little endian).

pub const Opcode = enum(u8) {
    NOP = 0,
    POP_TOP, // pop and discard
    DUP_TOP,
    DUP_TOP_TWO, // продублировать пару: […,a,b] -> […,a,b,a,b]
    ROT_TWO, // swap top two
    ROT_THREE, // TOS <-> third

    // --- Константы ---
    LOAD_CONST, // arg → co_consts[arg]

    // --- Имена / переменные ---
    LOAD_NAME, // arg → co_names[arg]: locals→globals→builtins
    STORE_NAME,
    DELETE_NAME,
    LOAD_FAST, // arg → индекс locals
    STORE_FAST,
    DELETE_FAST,
    LOAD_DEREF, // arg → cells[arg]
    STORE_DEREF,
    DELETE_DEREF,
    LOAD_CLASSDEREF, // arg → cells[arg], with unbound→NameError
    LOAD_GLOBAL, // arg → co_names → globals→builtins
    STORE_GLOBAL,
    DELETE_GLOBAL,
    MAKE_CELL, // arg: locals index → превратить в ячейку (closure)
    COPY_FREE_VARS, // arg: число freevars, копируем из function-объекта
    LOAD_CLOSURE, // arg: индекс cell → push Cell-объект frame.cells[arg] (создание вложенного замыкания)

    // --- Контейнеры-литералы ---
    BUILD_TUPLE, // arg: count
    BUILD_LIST, // arg: count
    BUILD_SET, // arg: count
    BUILD_MAP, // arg: count (key,value pairs on stack)
    MAP_ADD, // dict at TOS[-2] += (k,v) top two — для dictcomp
    SET_ADD, // set at TOS[-1]  += top
    LIST_APPEND, // list at TOS[-1] += top  (для comprehensions)
    BUILD_STRING, // arg: count строк → concat
    BUILD_SLICE, // arg: 2|3
    UNPACK_SEQUENCE, // arg: count
    UNPACK_EX, // arg: (before) | (after << 8) — starred assign
    LIST_EXTEND, // list[TOS-1] += TOS (star в литерале)
    SET_UPDATE, // set[TOS-1] |= TOS
    DICT_UPDATE, // dict[TOS-1] |= TOS (** в литерале/вызове)
    DICT_MERGE, // как DICT_UPDATE но TypeError на не-mapping в вызове

    // --- Арифметика/сравнения ---
    BINARY_OP, // arg: BinaryOp
    CALL_INTRINSIC_1, // arg: intrinsic1 id (CPython-compatible subset)
    UNARY_INVERT,
    UNARY_NEGATIVE,
    UNARY_NOT,
    TO_BOOL,
    COMPARE_OP, // arg: CompareOp
    CONTAINS_OP, // arg: 0 in / 1 not in
    IS_OP, // arg: 0 is / 1 is not

    // --- Атрибуты/подписки ---
    LOAD_ATTR, // arg → co_names
    STORE_ATTR,
    DELETE_ATTR,
    STORE_SUBSCR,
    DELETE_SUBSCR,

    // --- Итерация ---
    GET_ITER, // TOS → iterator
    GET_LEN, // push len(TOS) (не совсем CPython… оставим только нужные)
    FOR_ITER, // arg: rel jump (от след. инструкции) если исчерпан
    GET_YIELD_FROM_ITER, // iter для yield from

    // --- Прыжки ---
    JUMP_FORWARD, // arg: rel offset от конца инструкции
    JUMP_BACKWARD, // arg: назад (GIL checkpoint)
    POP_JUMP_IF_FALSE, // arg: rel forward
    POP_JUMP_IF_TRUE,

    // --- Вызовы ---
    CALL, // arg: nargs
    CALL_KW, // arg: total positional+keyword values; tuple keyword names лежит на вершине стека
    CALL_FUNCTION_EX, // TOS: kwargs dict или None, TOS-1: args tuple, TOS-2: func
    MAKE_FUNCTION, // arg flags: 0x01 defaults 0x02 kwdefaults 0x04 closure 0x08 annotations
    LOAD_METHOD_OPT, // (зарезервировано)
    CALL_METHOD_OPT, // (зарезервировано)

    // --- Классы ---
    LOAD_BUILD_CLASS, // pushes builtins.__build_class__

    // --- Исключения / блоки ---
    SETUP_EXCEPT, // arg: rel target handler (Except block)
    SETUP_FINALLY, // arg: rel target handler (Finally block)
    SETUP_WITH, // arg: rel target; до этого вызван __enter__
    POP_BLOCK, // снять блок
    POP_EXCEPT, // выйти из except-обработчика (восстановить exc state)
    RAISE_VARARGS, // arg: 0|1|2 (raise / raise from)
    RERAISE, // повторная размотка текущего handled-exc
    END_FINALLY, // конец finally: если был pending exc — продолжить размотку
    PUSH_EXC_INFO, // сохранить текущее исключение на стек (для except as)
    CHECK_EXC_MATCH, // TOS=exc types, TOS-1=exc → bool (exc_info match)

    // --- Импорт ---
    IMPORT_NAME, // arg → co_names; TOS: level int, fromlist
    IMPORT_FROM, // arg → co_names; push attr модуля (модуль остаётся ниже)

    // --- Функциональное ---
    RETURN_VALUE,
    YIELD_VALUE, // TOS — значение; push sent value
    YIELD_FROM, // arg: rel target при завершении делегации; TOS-1: iter, TOS: sent
    RESUME, // точка входа (GIL checkpoint)
    CONVERT_VALUE, // arg: FVC_*
    FORMAT_SIMPLE,
    FORMAT_WITH_SPEC,
    LOAD_ASSERTION_ERROR,

    // --- Аннотации (упрощённо) ---
    STORE_ANNOTATION, // arg → co_names; store TOS в __annotations__[name]

    // --- Замыкания класса ---
    LOAD_BUILD_CLASS_DONE_PLACEHOLDER, // (зарезервировано)

    // --- Стековые для comprehension/генераторов живут внутри своих фреймов ---

    CACHE, // inline-кэш (зарезервировано, no-op)
    END, // конец кода (страховка)
    pub fn hasArg(op: Opcode) bool {
        return switch (op) {
            .NOP, .POP_TOP, .DUP_TOP, .DUP_TOP_TWO, .ROT_TWO, .ROT_THREE, .UNARY_INVERT, .UNARY_NEGATIVE, .UNARY_NOT, .TO_BOOL, .POP_BLOCK, .POP_EXCEPT, .RERAISE, .END_FINALLY, .GET_ITER, .GET_YIELD_FROM_ITER, .RETURN_VALUE, .YIELD_VALUE, .RESUME, .LOAD_BUILD_CLASS, .PUSH_EXC_INFO, .CALL_FUNCTION_EX, .LOAD_ASSERTION_ERROR, .END, .CACHE, .LIST_EXTEND, .SET_UPDATE, .DICT_UPDATE, .DICT_MERGE, .GET_LEN, .FORMAT_SIMPLE, .FORMAT_WITH_SPEC => false,
            else => true,
        };
    }
};

/// Oparg для BINARY_OP в совместимом с CPython 3.14 порядке.
/// См. Include/opcode.h (NB_*). Благодаря этому дизассемблерные дампы и
/// сравнение с CPython больше не зависят от произвольного локального порядка.
pub const BinaryOp = enum(u8) {
    add = 0,         // NB_ADD
    bit_and = 1,     // NB_AND
    floordiv = 2,    // NB_FLOOR_DIVIDE
    lshift = 3,      // NB_LSHIFT
    matmul = 4,      // NB_MATRIX_MULTIPLY
    mul = 5,         // NB_MULTIPLY
    mod = 6,         // NB_REMAINDER
    bit_or = 7,      // NB_OR
    pow = 8,         // NB_POWER
    rshift = 9,      // NB_RSHIFT
    sub = 10,        // NB_SUBTRACT
    truediv = 11,    // NB_TRUE_DIVIDE
    bit_xor = 12,    // NB_XOR

    // in-place variants — тоже в CPython-порядке NB_INPLACE_*
    iadd = 13,
    ibit_and = 14,
    ifloordiv = 15,
    ilshift = 16,
    imatmul = 17,
    imul = 18,
    imod = 19,
    ibit_or = 20,
    ipow = 21,
    irshift = 22,
    isub = 23,
    itruediv = 24,
    ibit_xor = 25,

    // Python 3.14: подписка живёт в BINARY_OP (NB_SUBSCR), а не в отдельном opcode.
    subscr = 26,
};

pub const CompareOp = enum(u8) { lt, le, eq, ne, gt, ge };

pub const INTRINSIC_1_INVALID: u8 = 0;
pub const INTRINSIC_PRINT: u8 = 1;
pub const INTRINSIC_IMPORT_STAR: u8 = 2;
pub const INTRINSIC_STOPITERATION_ERROR: u8 = 3;
pub const INTRINSIC_ASYNC_GEN_WRAP: u8 = 4;
pub const INTRINSIC_UNARY_POSITIVE: u8 = 5;
pub const INTRINSIC_LIST_TO_TUPLE: u8 = 6;
pub const INTRINSIC_TYPEVAR: u8 = 7;
pub const INTRINSIC_PARAMSPEC: u8 = 8;
pub const INTRINSIC_TYPEVARTUPLE: u8 = 9;
pub const INTRINSIC_SUBSCRIPT_GENERIC: u8 = 10;
pub const INTRINSIC_TYPEALIAS: u8 = 11;

pub const FVC_NONE: u8 = 0;
pub const FVC_STR: u8 = 1;
pub const FVC_REPR: u8 = 2;
pub const FVC_ASCII: u8 = 3;
