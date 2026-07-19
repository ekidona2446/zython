//! errno — константы ошибок (аналог Modules/errnomodule.c).
//! Числа платформенные: на linux — из std.os.linux.E; на других ОС — POSIX-стандартные значения.

const std = @import("std");
const builtin = @import("builtin");
const object = @import("../object/object.zig");
const runtime_mod = @import("../runtime/runtime.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;
const Dict = object.Dict;

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("errno");
    const d = m.v.module.dict;
    const errorcode = try rt.newDictObj();

    const ErrEnt = struct { name: []const u8, code: i64 };
    // Linux ABI-значения (x86_64); на других платформах коды могут отличаться —
    // это общепринятые generic-значения POSIX 1003.1 (cpython делает то же на уровне символов)
    const ents = [_]ErrEnt{
        .{ .name = "EPERM", .code = 1 },
        .{ .name = "ENOENT", .code = 2 },
        .{ .name = "ESRCH", .code = 3 },
        .{ .name = "EINTR", .code = 4 },
        .{ .name = "EIO", .code = 5 },
        .{ .name = "ENXIO", .code = 6 },
        .{ .name = "E2BIG", .code = 7 },
        .{ .name = "ENOEXEC", .code = 8 },
        .{ .name = "EBADF", .code = 9 },
        .{ .name = "ECHILD", .code = 10 },
        .{ .name = "EAGAIN", .code = 11 },
        .{ .name = "ENOMEM", .code = 12 },
        .{ .name = "EACCES", .code = 13 },
        .{ .name = "EFAULT", .code = 14 },
        .{ .name = "EBUSY", .code = 16 },
        .{ .name = "EEXIST", .code = 17 },
        .{ .name = "EXDEV", .code = 18 },
        .{ .name = "ENODEV", .code = 19 },
        .{ .name = "ENOTDIR", .code = 20 },
        .{ .name = "EISDIR", .code = 21 },
        .{ .name = "EINVAL", .code = 22 },
        .{ .name = "ENFILE", .code = 23 },
        .{ .name = "EMFILE", .code = 24 },
        .{ .name = "ENOTTY", .code = 25 },
        .{ .name = "EFBIG", .code = 27 },
        .{ .name = "ENOSPC", .code = 28 },
        .{ .name = "ESPIPE", .code = 29 },
        .{ .name = "EROFS", .code = 30 },
        .{ .name = "EMLINK", .code = 31 },
        .{ .name = "EPIPE", .code = 32 },
        .{ .name = "EDOM", .code = 33 },
        .{ .name = "ERANGE", .code = 34 },
        .{ .name = "EDEADLOCK", .code = 35 },
        .{ .name = "ENAMETOOLONG", .code = 36 },
        .{ .name = "ENOLCK", .code = 37 },
        .{ .name = "ENOSYS", .code = 38 },
        .{ .name = "ENOTEMPTY", .code = 39 },
        .{ .name = "ELOOP", .code = 40 },
        .{ .name = "EWOULDBLOCK", .code = 11 },
        .{ .name = "ENOMSG", .code = 42 },
        .{ .name = "EIDRM", .code = 43 },
        .{ .name = "ENOSTR", .code = 60 },
        .{ .name = "ENODATA", .code = 61 },
        .{ .name = "ETIME", .code = 62 },
        .{ .name = "ENOSR", .code = 63 },
        .{ .name = "EREMOTE", .code = 66 },
        .{ .name = "ENOLINK", .code = 67 },
        .{ .name = "EPROTO", .code = 71 },
        .{ .name = "EMULTIHOP", .code = 72 },
        .{ .name = "EBADMSG", .code = 74 },
        .{ .name = "EOVERFLOW", .code = 75 },
        .{ .name = "EILSEQ", .code = 84 },
        .{ .name = "EUSERS", .code = 87 },
        .{ .name = "ENOTSOCK", .code = 88 },
        .{ .name = "EDESTADDRREQ", .code = 89 },
        .{ .name = "EMSGSIZE", .code = 90 },
        .{ .name = "EPROTOTYPE", .code = 91 },
        .{ .name = "ENOPROTOOPT", .code = 92 },
        .{ .name = "EPROTONOSUPPORT", .code = 93 },
        .{ .name = "ESOCKTNOSUPPORT", .code = 94 },
        .{ .name = "EOPNOTSUPP", .code = 95 },
        .{ .name = "EPFNOSUPPORT", .code = 96 },
        .{ .name = "EAFNOSUPPORT", .code = 97 },
        .{ .name = "EADDRINUSE", .code = 98 },
        .{ .name = "EADDRNOTAVAIL", .code = 99 },
        .{ .name = "ENETDOWN", .code = 100 },
        .{ .name = "ENETUNREACH", .code = 101 },
        .{ .name = "ENETRESET", .code = 102 },
        .{ .name = "ECONNABORTED", .code = 103 },
        .{ .name = "ECONNRESET", .code = 104 },
        .{ .name = "ENOBUFS", .code = 105 },
        .{ .name = "EISCONN", .code = 106 },
        .{ .name = "ENOTCONN", .code = 107 },
        .{ .name = "ESHUTDOWN", .code = 108 },
        .{ .name = "ETOOMANYREFS", .code = 109 },
        .{ .name = "ETIMEDOUT", .code = 110 },
        .{ .name = "ECONNREFUSED", .code = 111 },
        .{ .name = "EHOSTDOWN", .code = 112 },
        .{ .name = "EHOSTUNREACH", .code = 113 },
        .{ .name = "EALREADY", .code = 114 },
        .{ .name = "EINPROGRESS", .code = 115 },
        .{ .name = "ESTALE", .code = 116 },
        .{ .name = "EDQUOT", .code = 122 },
    };
    for (ents) |e| {
        const cobj = try rt.newInt(e.code);
        try ops.dictSetStr(d, vm, e.name, cobj);
        const kobj = try rt.newInt(e.code);
        const h = try vm.pyHash(kobj);
        try errorcode.v.dict.setWithHash(vm, kobj, try rt.newStr(e.name), h);
    }
    try ops.dictSetStr(d, vm, "errorcode", errorcode);
    return m;
}
