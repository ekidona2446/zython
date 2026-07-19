//! warnings — аналог Lib/warnings.py (минимальная, достаточная для requests/urllib3).
//! warn() — no-op (предупреждения подавляются), catch_warnings — контекстный менеджер.

const std = @import("std");
const object = @import("../object/object.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const compiler = @import("../compiler/compiler.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;

const PY_SRC =
    \\# Категории предупреждений — из builtins (иерархия исключений)
    \\Warning = Warning
    \\UserWarning = UserWarning
    \\DeprecationWarning = DeprecationWarning
    \\PendingDeprecationWarning = PendingDeprecationWarning
    \\SyntaxWarning = SyntaxWarning
    \\RuntimeWarning = RuntimeWarning
    \\FutureWarning = FutureWarning
    \\ImportWarning = ImportWarning
    \\UnicodeWarning = UnicodeWarning
    \\BytesWarning = BytesWarning
    \\ResourceWarning = ResourceWarning
    \\
    \\_filters_mutated_count = 0
    \\filters = []
    \\defaultaction = 'default'
    \\onceregistry = {}
    \\
    \\def warn(message, category=UserWarning, stacklevel=1, source=None, skip_file_prefixes=None):
    \\    # Минимальная реализация: предупреждения подавляются (как при -W ignore).
    \\    pass
    \\
    \\def warn_explicit(message, category, filename, lineno, module=None, registry=None, module_globals=None, source=None):
    \\    pass
    \\
    \\def filterwarnings(action, message='', category=Warning, module='', lineno=0, append=False):
    \\    global _filters_mutated_count
    \\    _filters_mutated_count += 1
    \\
    \\def simplefilter(action, category=Warning, lineno=0, append=False):
    \\    global _filters_mutated_count
    \\    _filters_mutated_count += 1
    \\
    \\def resetwarnings():
    \\    global _filters_mutated_count
    \\    _filters_mutated_count += 1
    \\
    \\def _filters_mutated():
    \\    return _filters_mutated_count
    \\
    \\class catch_warnings(object):
    \\    def __init__(self, *, record=False, module=None, action=None, category=Warning, lineno=0, append=False, simple=None):
    \\        self._record = record
    \\        self._module = module
    \\        self._entered = False
    \\        self._filters = None
    \\        self.log = []
    \\    def __repr__(self):
    \\        return '<catch_warnings>'
    \\    def __enter__(self):
    \\        self._entered = True
    \\        if self._record:
    \\            return self.log
    \\        return None
    \\    def __exit__(self, *exc_info):
    \\        return False
    \\
    \\def _is_internal_filename(filename):
    \\    return 'importlib' in filename and '_bootstrap' in filename
    \\
    \\__all__ = ['warn', 'warn_explicit', 'filterwarnings', 'simplefilter',
    \\           'resetwarnings', 'catch_warnings', 'Warning', 'UserWarning',
    \\           'DeprecationWarning', 'RuntimeWarning', 'FutureWarning']
;

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("warnings");
    const md = m.v.module;
    try ops.dictSetStr(md.dict, vm, "__name__", try rt.newStr("warnings"));
    try ops.dictSetStr(md.dict, vm, "__builtins__", try rt.mkObj(rt.dict_t, .{ .dict = rt.builtins_dict }));

    const code = compiler.compileSource(vm, "<warnings>", PY_SRC, .exec) catch |e| return e;
    vm.runNameScope(code, md.dict, null) catch |e| return e;
    return m;
}
