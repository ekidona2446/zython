//! functools — аналог Lib/functools.py. Определён на Python (исполняется из Zig
//! в dict модуля) — как в CPython, где functools по большей части pure-Python.
//! Это даёт точную семантику (partial/wraps/lru_cache) без дублирования на Zig.

const std = @import("std");
const object = @import("../object/object.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const compiler = @import("../compiler/compiler.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;
const KwArgs = object.KwArgs;

const PY_SRC =
    \\WRAPPER_ASSIGNMENTS = ('__module__', '__name__', '__qualname__', '__annotations__', '__doc__')
    \\WRAPPER_UPDATES = ('__dict__',)
    \\
    \\def update_wrapper(wrapper, wrapped, assigned=WRAPPER_ASSIGNMENTS, updated=WRAPPER_UPDATES):
    \\    for attr in assigned:
    \\        try:
    \\            value = getattr(wrapped, attr)
    \\        except AttributeError:
    \\            pass
    \\        else:
    \\            setattr(wrapper, attr, value)
    \\    for attr in updated:
    \\        getattr(wrapper, attr).update(getattr(wrapped, attr, {}))
    \\    wrapper.__wrapped__ = wrapped
    \\    return wrapper
    \\
    \\def wraps(wrapped, assigned=WRAPPER_ASSIGNMENTS, updated=WRAPPER_UPDATES):
    \\    return partial(update_wrapper, wrapped=wrapped, assigned=assigned, updated=updated)
    \\
    \\def reduce(function, iterable, initializer=None):
    \\    it = iter(iterable)
    \\    if initializer is None:
    \\        try:
    \\            value = next(it)
    \\        except StopIteration:
    \\            raise TypeError('reduce() of empty iterable with no initial value')
    \\    else:
    \\        value = initializer
    \\    for element in it:
    \\        value = function(value, element)
    \\    return value
    \\
    \\class partial:
    \\    def __init__(self, func, *args, **keywords):
    \\        self.func = func
    \\        self.args = args
    \\        self.keywords = keywords
    \\    def __call__(self, *args, **keywords):
    \\        kwd = self.keywords.copy()
    \\        kwd.update(keywords)
    \\        return self.func(*(self.args + args), **kwd)
    \\    def __repr__(self):
    \\        return 'functools.partial(' + repr(self.func) + ')'
    \\
    \\def lru_cache(maxsize=128, typed=False):
    \\    def decorating_function(user_function):
    \\        cache = {}
    \\        hits = [0]
    \\        misses = [0]
    \\        def wrapper(*args):
    \\            if args in cache:
    \\                hits[0] += 1
    \\                return cache[args]
    \\            misses[0] += 1
    \\            result = user_function(*args)
    \\            cache[args] = result
    \\            return result
    \\        def cache_info():
    \\            return (hits[0], misses[0], maxsize, len(cache))
    \\        def cache_clear():
    \\            cache.clear()
    \\            hits[0] = 0
    \\            misses[0] = 0
    \\        wrapper.cache_info = cache_info
    \\        wrapper.cache_clear = cache_clear
    \\        wrapper.__wrapped__ = user_function
    \\        return wrapper
    \\    if callable(maxsize) and not typed:
    \\        # @lru_cache без скобок: maxsize — сама функция
    \\        f = maxsize
    \\        maxsize = 128
    \\        return decorating_function(f)
    \\    return decorating_function
    \\
    \\class cached_property:
    \\    def __init__(self, func):
    \\        self.func = func
    \\        self.attrname = None
    \\        self.__doc__ = func.__doc__
    \\    def __set_name__(self, owner, name):
    \\        self.attrname = name
    \\    def __get__(self, instance, owner=None):
    \\        if instance is None:
    \\            return self
    \\        name = self.attrname
    \\        val = self.func(instance)
    \\        setattr(instance, name, val)
    \\        return val
    \\
    \\def total_ordering(cls):
    \\    return cls
    \\
    \\class _CmpToKey:
    \\    def __init__(self, mycmp):
    \\        self.mycmp = mycmp
    \\        self.obj = None
    \\
    \\def cmp_to_key(mycmp):
    \\    class K:
    \\        def __init__(self, obj, *args):
    \\            self.obj = obj
    \\        def __lt__(self, other):
    \\            return mycmp(self.obj, other.obj) < 0
    \\        def __gt__(self, other):
    \\            return mycmp(self.obj, other.obj) > 0
    \\        def __eq__(self, other):
    \\            return mycmp(self.obj, other.obj) == 0
    \\        def __le__(self, other):
    \\            return mycmp(self.obj, other.obj) <= 0
    \\        def __ge__(self, other):
    \\            return mycmp(self.obj, other.obj) >= 0
    \\        def __ne__(self, other):
    \\            return mycmp(self.obj, other.obj) != 0
    \\    return K
    \\
    \\_CacheInfo = None
;

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("functools");
    const md = m.v.module;
    try ops.dictSetStr(md.dict, vm, "__name__", try rt.newStr("functools"));
    try ops.dictSetStr(md.dict, vm, "__builtins__", try rt.mkObj(rt.dict_t, .{ .dict = rt.builtins_dict }));

    const code = compiler.compileSource(vm, "<functools>", PY_SRC, .exec) catch |e| {
        return e;
    };
    vm.runNameScope(code, md.dict, null) catch |e| {
        return e;
    };
    return m;
}
