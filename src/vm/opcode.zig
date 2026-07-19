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
    LOAD_NONE,
    LOAD_TRUE,
    LOAD_FALSE,
    LOAD_ELLIPSIS,

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
    BUILD_CONST_KEY_MAP, // arg: count, keys — кортеж-константа ниже значений
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
    UNARY_OP, // arg: UnaryOp
    COMPARE_OP, // arg: CompareOp
    CONTAINS_OP, // arg: 0 in / 1 not in
    IS_OP, // arg: 0 is / 1 is not

    // --- Атрибуты/подписки ---
    LOAD_ATTR, // arg → co_names
    STORE_ATTR,
    DELETE_ATTR,
    LOAD_SUBSCR,
    STORE_SUBSCR,
    DELETE_SUBSCR,

    // --- Итерация ---
    GET_ITER, // TOS → iterator
    GET_LEN, // push len(TOS) (не совсем CPython… оставим только нужные)
    FOR_ITER, // arg: rel jump (от след. инструкции) если исчерпан
    GET_YIELD_FROM_ITER, // iter для yield from

    // --- Прыжки ---
    JUMP_FORWARD, // arg: rel offset от конца инструкции
    JUMP_ABSOLUTE, // arg: абсолютный pc
    JUMP_BACKWARD, // arg: назад (GIL checkpoint)
    POP_JUMP_IF_FALSE, // arg: absolute
    POP_JUMP_IF_TRUE,
    JUMP_IF_FALSE_OR_POP,
    JUMP_IF_TRUE_OR_POP,
    JUMP_IF_NOT_EXC_MATCH, // arg: absolute; pops (exc, match)

    // --- Вызовы ---
    CALL, // arg: nargs (младший байт) + nkw (старший байт); до него может быть KW_NAMES
    KW_NAMES, // arg: const-idx кортежа имён kwargs (устанавливает frame.kwnames)
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
    RAISE, // arg: 0|1|2 (raise / raise from)
    RAISE_AGAIN, // повторная размотка текущего handled-exc
    END_FINALLY, // конец finally: если был pending exc — продолжить размотку
    PUSH_EXC_INFO, // сохранить текущее исключение на стек (для except as)
    CHECK_EXC_MATCH, // TOS=exc types, TOS-1=exc → bool (exc_info match)

    // --- Импорт ---
    IMPORT_NAME, // arg → co_names; TOS: level int, fromlist
    IMPORT_FROM, // arg → co_names; push attr модуля (модуль остаётся ниже)
    IMPORT_STAR,

    // --- Функциональное ---
    RETURN_VALUE,
    YIELD_VALUE, // TOS — значение; push sent value
    YIELD_FROM, // arg: rel target при завершении делегации; TOS-1: iter, TOS: sent
    RESUME, // точка входа (GIL checkpoint)
    FORMAT_VALUE, // arg: 0/1/2/3 conv flag; TOS: value или (fmt_spec, value)
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
            .NOP, .POP_TOP, .DUP_TOP, .DUP_TOP_TWO, .ROT_TWO, .ROT_THREE, .LOAD_NONE, .LOAD_TRUE, .LOAD_FALSE, .LOAD_ELLIPSIS, .POP_BLOCK, .POP_EXCEPT, .RAISE_AGAIN, .END_FINALLY, .GET_ITER, .GET_YIELD_FROM_ITER, .RETURN_VALUE, .YIELD_VALUE, .RESUME, .LOAD_BUILD_CLASS, .PUSH_EXC_INFO, .IMPORT_STAR, .CALL_FUNCTION_EX, .LOAD_ASSERTION_ERROR, .END, .CACHE, .LIST_EXTEND, .SET_UPDATE, .DICT_UPDATE, .DICT_MERGE, .GET_LEN => false,
            else => true,
        };
    }
};

pub const BinaryOp = enum(u8) {
    add,
    sub,
    mul,
    matmul,
    truediv,
    floordiv,
    mod,
    pow,
    lshift,
    rshift,
    bit_and,
    bit_or,
    bit_xor,
    // in-place variants (последние 13)
    iadd,
    isub,
    imul,
    imatmul,
    itruediv,
    ifloordiv,
    imod,
    ipow,
    ilshift,
    irshift,
    ibit_and,
    ibit_or,
    ibit_xor,
};

pub const UnaryOp = enum(u8) { pos, neg, not, invert };

pub const CompareOp = enum(u8) { lt, le, eq, ne, gt, ge };

pub const FORMAT_VALUE_WITH_SPEC: u8 = 0x04;
