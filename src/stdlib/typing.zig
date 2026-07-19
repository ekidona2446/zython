//! typing — аналог Lib/typing.py (рабочее подмножество для urllib3/requests/httpx).
//! Subscriptable _GenericAlias/_SpecialForm, cast, TypeVar, NamedTuple, Generic, Protocol.

const std = @import("std");
const object = @import("../object/object.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const compiler = @import("../compiler/compiler.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;

const PY_SRC =
    \\TYPE_CHECKING = False
    \\
    \\class _GenericAlias:
    \\    def __init__(self, origin, args=()):
    \\        self.__origin__ = origin
    \\        self.__args__ = args if isinstance(args, tuple) else (args,)
    \\    def __getitem__(self, item):
    \\        return _GenericAlias(self.__origin__, item)
    \\    def __call__(self, *args, **kwargs):
    \\        if isinstance(self.__origin__, type):
    \\            return self.__origin__(*args, **kwargs)
    \\        raise TypeError('cannot instantiate ' + repr(self.__origin__))
    \\    def __repr__(self):
    \\        o = self.__origin__
    \\        n = getattr(o, '_name', None) or getattr(o, '__name__', repr(o))
    \\        return 'typing.' + str(n)
    \\    def __eq__(self, other):
    \\        if isinstance(other, _GenericAlias):
    \\            return self.__origin__ == other.__origin__
    \\        return NotImplemented
    \\    def __hash__(self):
    \\        return hash(repr(self.__origin__))
    \\    def copy_with(self, params):
    \\        return _GenericAlias(self.__origin__, params)
    \\
    \\class _SpecialForm:
    \\    def __init__(self, name):
    \\        self._name = name
    \\        self.__origin__ = None
    \\    def __getitem__(self, item):
    \\        return _GenericAlias(self, item)
    \\    def __call__(self, *args, **kwargs):
    \\        raise TypeError(self._name + ' is not subscriptable in runtime call')
    \\    def __repr__(self):
    \\        return 'typing.' + self._name
    \\    def __mro_entries__(self, bases):
    \\        return ()
    \\
    \\Any = _SpecialForm('Any')
    \\Union = _SpecialForm('Union')
    \\Optional = _SpecialForm('Optional')
    \\Literal = _SpecialForm('Literal')
    \\Annotated = _SpecialForm('Annotated')
    \\TypeAlias = _SpecialForm('TypeAlias')
    \\TypeGuard = _SpecialForm('TypeGuard')
    \\Unpack = _SpecialForm('Unpack')
    \\Required = _SpecialForm('Required')
    \\NotRequired = _SpecialForm('NotRequired')
    \\Concatenate = _SpecialForm('Concatenate')
    \\ClassVar = _SpecialForm('ClassVar')
    \\Final = _SpecialForm('Final')
    \\
    \\Callable = _GenericAlias('Callable', ())
    \\Tuple = _GenericAlias(tuple, ())
    \\List = _GenericAlias(list, ())
    \\Dict = _GenericAlias(dict, ())
    \\Set = _GenericAlias(set, ())
    \\FrozenSet = _GenericAlias(frozenset, ())
    \\Type = _GenericAlias(type, ())
    \\Sequence = _GenericAlias('Sequence', ())
    \\MutableSequence = _GenericAlias('MutableSequence', ())
    \\Mapping = _GenericAlias('Mapping', ())
    \\MutableMapping = _GenericAlias('MutableMapping', ())
    \\Iterable = _GenericAlias('Iterable', ())
    \\Iterator = _GenericAlias('Iterator', ())
    \\Generator = _GenericAlias('Generator', ())
    \\Awaitable = _GenericAlias('Awaitable', ())
    \\Coroutine = _GenericAlias('Coroutine', ())
    \\AsyncIterator = _GenericAlias('AsyncIterator', ())
    \\AsyncIterable = _GenericAlias('AsyncIterable', ())
    \\AsyncGenerator = _GenericAlias('AsyncGenerator', ())
    \\Collection = _GenericAlias('Collection', ())
    \\Container = _GenericAlias('Container', ())
    \\Reversible = _GenericAlias('Reversible', ())
    \\AbstractSet = _GenericAlias('AbstractSet', ())
    \\MutableSet = _GenericAlias('MutableSet', ())
    \\KeysView = _GenericAlias('KeysView', ())
    \\ItemsView = _GenericAlias('ItemsView', ())
    \\ValuesView = _GenericAlias('ValuesView', ())
    \\ContextManager = _GenericAlias('ContextManager', ())
    \\AsyncContextManager = _GenericAlias('AsyncContextManager', ())
    \\Pattern = _GenericAlias('Pattern', ())
    \\Match = _GenericAlias('Match', ())
    \\IO = _GenericAlias('IO', ())
    \\TextIO = _GenericAlias('TextIO', ())
    \\BinaryIO = _GenericAlias('BinaryIO', ())
    \\
    \\NoReturn = _SpecialForm('NoReturn')
    \\Never = _SpecialForm('Never')
    \\Self = _SpecialForm('Self')
    \\LiteralString = _SpecialForm('LiteralString')
    \\
    \\def cast(typ, val):
    \\    return val
    \\
    \\def overload(func):
    \\    return func
    \\
    \\def final(func):
    \\    return func
    \\
    \\def no_type_check(arg):
    \\    return arg
    \\
    \\def runtime_checkable(cls):
    \\    return cls
    \\
    \\def final_decorator(func):
    \\    return func
    \\
    \\class _TypeVar:
    \\    def __init__(self, name, *constraints, bound=None, covariant=False, contravariant=False, infer_variance=False, default=None):
    \\        self.__name__ = name
    \\        self.__bound__ = bound
    \\        self.__constraints__ = constraints
    \\        self.__covariant__ = covariant
    \\        self.__contravariant__ = contravariant
    \\    def __repr__(self):
    \\        return '~' + self.__name__
    \\    def __mro_entries__(self, bases):
    \\        return ()
    \\
    \\def TypeVar(name, *constraints, **kwargs):
    \\    return _TypeVar(name, *constraints, **kwargs)
    \\
    \\class ParamSpec(_TypeVar):
    \\    pass
    \\
    \\class TypeVarTuple(_TypeVar):
    \\    pass
    \\
    \\class Generic:
    \\    def __class_getitem__(cls, item):
    \\        return _GenericAlias(cls, item)
    \\    def __mro_entries__(self, bases):
    \\        return ()
    \\
    \\class Protocol:
    \\    def __class_getitem__(cls, item):
    \\        return _GenericAlias(cls, item)
    \\    def __mro_entries__(self, bases):
    \\        return ()
    \\
    \\def NewType(name, tp):
    \\    def identity(x):
    \\        return x
    \\    identity.__name__ = name
    \\    identity.__supertype__ = tp
    \\    return identity
    \\
    \\def NamedTuple(typename, fields=None, **kwargs):
    \\    if fields is None:
    \\        fields = list(kwargs.items())
    \\    field_names = [f[0] for f in fields]
    \\    cls = type(typename, (tuple,), {'__slots__': ()})
    \\    cls._fields = field_names
    \\    return cls
    \\
    \\def TypedDict(typename, fields=None, *, total=True, **kwargs):
    \\    return dict
    \\
    \\class _NamedTuple:
    \\    def __class_getitem__(cls, item):
    \\        return _GenericAlias(cls, item)
    \\
    \\def get_type_hints(obj, globalns=None, localns=None, include_extras=False):
    \\    return {}
    \\
    \\def get_origin(tp):
    \\    return getattr(tp, '__origin__', None)
    \\
    \\def get_args(tp):
    \\    return getattr(tp, '__args__', ())
    \\
    \\def is_typeddict(tp):
    \\    return False
    \\
    \\def assert_type(val, typ):
    \\    return val
    \\
    \\def assert_never(arg):
    \\    raise AssertionError('assert_never')
    \\
    \\def reveal_type(obj):
    \\    return obj
    \\
    \\def get_overloads(func):
    \\    return []
    \\
    \\def clear_overloads():
    \\    pass
    \\
    \\def final_type():
    \\    return None
    \\
    \\def _collect_type_vars(types_):
    \\    return ()
    \\
    \\class ForwardRef:
    \\    def __init__(self, arg, is_argument=True, module=None):
    \\        self.__forward_arg__ = arg
    \\    def __repr__(self):
    \\        return 'ForwardRef(' + repr(self.__forward_arg__) + ')'
    \\
    \\def _type_check(arg, msg):
    \\    return arg
;

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("typing");
    const md = m.v.module;
    try ops.dictSetStr(md.dict, vm, "__name__", try rt.newStr("typing"));
    try ops.dictSetStr(md.dict, vm, "__builtins__", try rt.mkObj(rt.dict_t, .{ .dict = rt.builtins_dict }));

    const code = compiler.compileSource(vm, "<typing>", PY_SRC, .exec) catch |e| return e;
    vm.runNameScope(code, md.dict, null) catch |e| return e;
    return m;
}
