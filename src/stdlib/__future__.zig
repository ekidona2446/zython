//! __future__ — аналог Lib/__future__.py. Флаги-заглушки (annotations и пр.).
//! `from __future__ import annotations` — no-op (аннотации и так ленивые в 3.14).

const std = @import("std");
const object = @import("../object/object.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const compiler = @import("../compiler/compiler.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;

const PY_SRC =
    \\class _Feature:
    \\    def __init__(self, optionalRelease, mandatoryRelease, compiler_flag):
    \\        self.optional = optionalRelease
    \\        self.mandatory = mandatoryRelease
    \\        self.compiler_flag = compiler_flag
    \\    def getOptionalRelease(self):
    \\        return self.optional
    \\    def getMandatoryRelease(self):
    \\        return self.mandatory
    \\    def __repr__(self):
    \\        return '_Feature' + repr(self.optional)
    \\
    \\nested_scopes = _Feature((2,1,0,'beta',1),(2,2,0,'alpha',0),0x10)
    \\generators = _Feature((2,2,0,'alpha',1),(2,3,0,'final',0),0x1000)
    \\division = _Feature((2,2,0,'alpha',2),(3,0,0,'alpha',0),0x2000)
    \\absolute_import = _Feature((2,5,0,'alpha',1),(3,0,0,'alpha',0),0x4000)
    \\with_statement = _Feature((2,5,0,'alpha',1),(2,6,0,'alpha',0),0x8000)
    \\print_function = _Feature((2,6,0,'alpha',2),(3,0,0,'alpha',0),0x10000)
    \\unicode_literals = _Feature((2,6,0,'alpha',2),(3,0,0,'alpha',0),0x20000)
    \\barry_as_FLUFL = _Feature((3,1,0,'alpha',2),(4,0,0,'alpha',0),0x40000)
    \\generator_stop = _Feature((3,5,0,'beta',1),(3,7,0,'alpha',0),0x80000)
    \\annotations = _Feature((3,7,0,'beta',1),(4,0,0,'alpha',0),0x100000)
    \\
    \\all_feature_names = ['nested_scopes','generators','division','absolute_import',
    \\    'with_statement','print_function','unicode_literals','barry_as_FLUFL',
    \\    'generator_stop','annotations']
;

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("__future__");
    const md = m.v.module;
    try ops.dictSetStr(md.dict, vm, "__name__", try rt.newStr("__future__"));
    try ops.dictSetStr(md.dict, vm, "__builtins__", try rt.mkObj(rt.dict_t, .{ .dict = rt.builtins_dict }));

    const code = compiler.compileSource(vm, "<__future__>", PY_SRC, .exec) catch |e| return e;
    vm.runNameScope(code, md.dict, null) catch |e| return e;
    return m;
}
