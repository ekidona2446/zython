//! socket — аналог Modules/socketmodule.c. Реальный blocking-сокет через libc (std.c).
//! DNS — через getaddrinfo. Для синхронного Python-кода (requests/urllib3).
//! libxev (io_uring) — для asyncio-этапа.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const object = @import("../object/object.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;
const KwArgs = object.KwArgs;

var socket_type: *object.Type = undefined;

fn mset(vm: *VM, m: Obj, name: []const u8, val: Obj) !void {
    try ops.dictSetStr(m.v.module.dict, vm, name, val);
}
fn mfun(vm: *VM, m: Obj, name: []const u8, comptime f: anytype) !void {
    try mset(vm, m, name, try vm.rt.newBuiltin(name, object.wrapBuiltin(f)));
}
fn tdef(vm: *VM, ty: *object.Type, name: []const u8, comptime f: anytype) !void {
    const b = try vm.rt.newBuiltin(name, object.wrapBuiltin(f));
    try ops.dictSetStr(ty.dict, vm, name, b);
}

fn raiseOSError(vm: *VM, comptime ty: []const u8, comptime fmt: []const u8, args: anytype) anyerror {
    vm.raiseFmt(ty, fmt, args) catch {};
    return error.PyExc;
}

fn getFd(vm: *VM, self: Obj) anyerror!i32 {
    const d = ops.instanceDict(self) orelse return raiseOSError(vm, "OSError", "invalid socket", .{});
    const v = (try ops.dictGetStr(d, vm, "_fd")) orelse return raiseOSError(vm, "OSError", "socket closed", .{});
    if (v.v != .int) return raiseOSError(vm, "OSError", "invalid socket fd", .{});
    return @intCast(v.v.int);
}
fn setInt(vm: *VM, self: Obj, name: []const u8, val: i64) !void {
    const d = ops.instanceDict(self) orelse return;
    try ops.dictSetStr(d, vm, name, try vm.rt.newInt(val));
}
fn getInt(vm: *VM, self: Obj, name: []const u8) ?i64 {
    const d = ops.instanceDict(self) orelse return null;
    const v = (ops.dictGetStr(d, vm, name) catch null) orelse return null;
    return if (v.v == .int) v.v.int else null;
}

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("socket");

    try mset(vm, m, "AF_INET", try rt.newInt(posix.AF.INET));
    try mset(vm, m, "AF_INET6", try rt.newInt(posix.AF.INET6));
    try mset(vm, m, "AF_UNIX", try rt.newInt(posix.AF.UNIX));
    try mset(vm, m, "AF_UNSPEC", try rt.newInt(0));
    try mset(vm, m, "SOCK_STREAM", try rt.newInt(posix.SOCK.STREAM));
    try mset(vm, m, "SOCK_DGRAM", try rt.newInt(posix.SOCK.DGRAM));
    try mset(vm, m, "SOCK_RAW", try rt.newInt(posix.SOCK.RAW));
    try mset(vm, m, "SOCK_SEQPACKET", try rt.newInt(posix.SOCK.SEQPACKET));
    try mset(vm, m, "IPPROTO_TCP", try rt.newInt(6));
    try mset(vm, m, "IPPROTO_UDP", try rt.newInt(17));
    try mset(vm, m, "IPPROTO_IP", try rt.newInt(0));
    try mset(vm, m, "SOL_SOCKET", try rt.newInt(posix.SOL.SOCKET));
    try mset(vm, m, "SO_REUSEADDR", try rt.newInt(posix.SO.REUSEADDR));
    try mset(vm, m, "SO_ERROR", try rt.newInt(posix.SO.ERROR));
    try mset(vm, m, "SO_KEEPALIVE", try rt.newInt(posix.SO.KEEPALIVE));
    try mset(vm, m, "SO_BROADCAST", try rt.newInt(posix.SO.BROADCAST));
    try mset(vm, m, "SO_RCVTIMEO", try rt.newInt(posix.SO.RCVTIMEO));
    try mset(vm, m, "SO_SNDTIMEO", try rt.newInt(posix.SO.SNDTIMEO));
    try mset(vm, m, "TCP_NODELAY", try rt.newInt(1));
    try mset(vm, m, "MSG_PEEK", try rt.newInt(0x02));
    try mset(vm, m, "MSG_WAITALL", try rt.newInt(0x100));
    try mset(vm, m, "MSG_DONTWAIT", try rt.newInt(0x40));
    try mset(vm, m, "SHUT_RD", try rt.newInt(0));
    try mset(vm, m, "SHUT_WR", try rt.newInt(1));
    try mset(vm, m, "SHUT_RDWR", try rt.newInt(2));
    try mset(vm, m, "AI_PASSIVE", try rt.newInt(1));
    try mset(vm, m, "AI_CANONNAME", try rt.newInt(2));
    try mset(vm, m, "AI_NUMERICHOST", try rt.newInt(4));
    try mset(vm, m, "NI_MAXHOST", try rt.newInt(1025));
    try mset(vm, m, "INET_ADDRSTRLEN", try rt.newInt(16));
    try mset(vm, m, "INET6_ADDRSTRLEN", try rt.newInt(46));
    try mset(vm, m, "has_ipv6", rt.newBool(true));
    try mset(vm, m, "has_dualstack_ipv6", rt.newBool(false));
    try mset(vm, m, "SOCK_CLOEXEC", try rt.newInt(0));
    try mset(vm, m, "SOMAXCONN", try rt.newInt(4096));

    const oe = vm.excType("OSError");
    for ([_][]const u8{ "gaierror", "herror" }) |nm| {
        var t = rt.exc_types.get(nm) orelse blk: {
            const tt = try rt.mkType(nm, oe);
            tt.flags.exc = true;
            tt.module = "socket";
            try rt.exc_types.put(nm, tt);
            break :blk tt;
        };
        t.module = "socket";
        try mset(vm, m, nm, try rt.mkObj(rt.type_t, .{ .type_ = t }));
    }
    try mset(vm, m, "error", try rt.mkObj(rt.type_t, .{ .type_ = oe }));
    try mset(vm, m, "timeout", try rt.mkObj(rt.type_t, .{ .type_ = vm.excType("TimeoutError") }));

    socket_type = try rt.mkType("socket", rt.object_t);
    socket_type.module = "socket";
    try tdef(vm, socket_type, "__init__", sock_init);
    try tdef(vm, socket_type, "connect", sock_connect);
    try tdef(vm, socket_type, "connect_ex", sock_connect_ex);
    try tdef(vm, socket_type, "send", sock_send);
    try tdef(vm, socket_type, "sendall", sock_sendall);
    try tdef(vm, socket_type, "recv", sock_recv);
    try tdef(vm, socket_type, "recv_into", sock_recv);
    try tdef(vm, socket_type, "close", sock_close);
    try tdef(vm, socket_type, "shutdown", sock_shutdown);
    try tdef(vm, socket_type, "settimeout", sock_settimeout);
    try tdef(vm, socket_type, "gettimeout", sock_gettimeout);
    try tdef(vm, socket_type, "setblocking", sock_setblocking);
    try tdef(vm, socket_type, "fileno", sock_fileno);
    try tdef(vm, socket_type, "setsockopt", sock_setsockopt);
    try tdef(vm, socket_type, "getsockopt", sock_getsockopt);
    try tdef(vm, socket_type, "bind", sock_bind);
    try tdef(vm, socket_type, "listen", sock_listen);
    try tdef(vm, socket_type, "accept", sock_accept);
    try tdef(vm, socket_type, "getpeername", sock_getpeername);
    try tdef(vm, socket_type, "getsockname", sock_getsockname);
    try tdef(vm, socket_type, "makefile", sock_makefile);
    try tdef(vm, socket_type, "dup", sock_dup);
    try mset(vm, m, "socket", try rt.mkObj(rt.type_t, .{ .type_ = socket_type }));
    try mset(vm, m, "SocketType", try rt.mkObj(rt.type_t, .{ .type_ = socket_type }));

    try mfun(vm, m, "create_connection", mod_create_connection);
    try mfun(vm, m, "getaddrinfo", mod_getaddrinfo);
    try mfun(vm, m, "gethostbyname", mod_gethostbyname);
    try mfun(vm, m, "gethostname", mod_gethostname);
    try mfun(vm, m, "getfqdn", mod_gethostbyname);
    try mfun(vm, m, "gethostbyaddr", mod_gethostbyaddr);
    try mfun(vm, m, "htonl", mod_htonl);
    try mfun(vm, m, "htons", mod_htons);
    try mfun(vm, m, "ntohl", mod_ntohl);
    try mfun(vm, m, "ntohs", mod_ntohs);
    try mfun(vm, m, "inet_aton", mod_inet_aton);
    try mfun(vm, m, "inet_ntoa", mod_inet_ntoa);
    try mfun(vm, m, "inet_pton", mod_inet_pton);
    try mfun(vm, m, "inet_ntop", mod_inet_ntop);
    try mfun(vm, m, "socketpair", mod_socketpair);
    try mfun(vm, m, "getdefaulttimeout", mod_getdefaulttimeout);
    try mfun(vm, m, "setdefaulttimeout", mod_setdefaulttimeout);
    return m;
}

// ============================================================
// Резолвинг через getaddrinfo + connect
// ============================================================

const Resolved = struct { fd: i32, family: i32, stype: i32 };

fn doConnect(v: *VM, host: []const u8, port: u16) anyerror!Resolved {
    const g = v.rt.gpa;
    const host_z = try g.dupeZ(u8, host);
    var pbuf: [8]u8 = undefined;
    const port_z = std.fmt.bufPrintZ(&pbuf, "{d}", .{port}) catch "0";
    var hints = std.mem.zeroes(c.addrinfo);
    hints.family = posix.AF.UNSPEC;
    hints.socktype = posix.SOCK.STREAM;
    var res: ?*c.addrinfo = null;
    const rc = c.getaddrinfo(host_z, port_z, &hints, &res);
    if (@intFromEnum(rc) != 0 or res == null) {
        try v.raiseFmt("gaierror", "Name or service not known: '{s}' (code {d})", .{ host, @intFromEnum(rc) });
        return error.PyExc;
    }
    defer c.freeaddrinfo(res.?);
    var ai: ?*c.addrinfo = res;
    var last_err: []const u8 = "connect failed";
    while (ai) |a| : (ai = a.next) {
        const fd = c.socket(@intCast(a.family), @intCast(a.socktype), @intCast(a.protocol));
        if (fd < 0) continue;
        if (a.addr) |addr| {
            const crc = c.connect(fd, addr, a.addrlen);
            if (crc == 0) {
                return Resolved{ .fd = @intCast(fd), .family = a.family, .stype = a.socktype };
            }
            last_err = "connection refused";
        }
        _ = c.close(fd);
    }
    try v.raiseFmt("ConnectionError", "{s}: '{s}:{d}'", .{ last_err, host, port });
    return error.PyExc;
}

fn hostPort(v: *VM, address: Obj) anyerror!struct { []const u8, u16 } {
    if (address.v != .tuple or address.v.tuple.len < 2) {
        return raiseOSError(v, "TypeError", "address must be (host, port) tuple", .{});
    }
    const t = address.v.tuple;
    var host: []const u8 = "";
    if (t[0].v == .str) host = t[0].v.str.bytes;
    var port: u16 = 0;
    if (t[1].v == .int) port = @intCast(t[1].v.int);
    return .{ host, port };
}

fn mkSocketObj(v: *VM, fd: i32, family: i32, stype: i32) anyerror!Obj {
    const inst = try v.rt.newInstance(socket_type);
    try setInt(v, inst, "_fd", fd);
    try setInt(v, inst, "_family", family);
    try setInt(v, inst, "_type", stype);
    try setInt(v, inst, "_closed", 0);
    return inst;
}

// ============================================================
// socket методы
// ============================================================

fn sock_init(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    if (args.len < 1) return raiseOSError(v, "TypeError", "socket() needs self", .{});
    const self = args[0];
    var family: i32 = posix.AF.INET;
    var stype: i32 = posix.SOCK.STREAM;
    var proto: i32 = 0;
    if (args.len > 1 and args[1].v == .int) family = @intCast(args[1].v.int);
    if (args.len > 2 and args[2].v == .int) stype = @intCast(args[2].v.int);
    if (args.len > 3 and args[3].v == .int) proto = @intCast(args[3].v.int);
    if (kw) |k| {
        if (k.get("family")) |o| {
            if (o.v == .int) family = @intCast(o.v.int);
        }
        if (k.get("type")) |o| {
            if (o.v == .int) stype = @intCast(o.v.int);
        }
        if (k.get("proto")) |o| {
            if (o.v == .int) proto = @intCast(o.v.int);
        }
    }
    const fd = c.socket(@intCast(family), @intCast(stype), @intCast(proto));
    if (fd < 0) return raiseOSError(v, "OSError", "socket() failed (errno)", .{});
    try setInt(v, self, "_fd", fd);
    try setInt(v, self, "_family", family);
    try setInt(v, self, "_type", stype);
    try setInt(v, self, "_closed", 0);
    return v.rt.newNone();
}

fn sock_connect(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 2) return raiseOSError(v, "TypeError", "connect() needs address", .{});
    const fd = try getFd(v, args[0]);
    const hp = try hostPort(v, args[1]);
    // резолвим и коннектим существующий fd к первому адресу
    const g = v.rt.gpa;
    const host_z = try g.dupeZ(u8, hp[0]);
    var pbuf: [8]u8 = undefined;
    const port_z = std.fmt.bufPrintZ(&pbuf, "{d}", .{hp[1]}) catch "0";
    var hints = std.mem.zeroes(c.addrinfo);
    hints.family = posix.AF.UNSPEC;
    hints.socktype = posix.SOCK.STREAM;
    var res: ?*c.addrinfo = null;
    const rc = c.getaddrinfo(host_z, port_z, &hints, &res);
    if (@intFromEnum(rc) != 0 or res == null) {
        try v.raiseFmt("gaierror", "Name or service not known: '{s}'", .{hp[0]});
        return error.PyExc;
    }
    defer c.freeaddrinfo(res.?);
    const a = res.?;
    if (a.addr) |addr| {
        const crc = c.connect(fd, addr, a.addrlen);
        if (crc != 0) return raiseOSError(v, "ConnectionError", "connect to '{s}:{d}' failed", .{ hp[0], hp[1] });
    }
    return v.rt.newNone();
}

fn sock_connect_ex(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    const v: *VM = vm;
    _ = sock_connect(v, args, kw) catch {
        v.currentTS().cur_exc = null;
        return v.rt.newInt(115);
    };
    return v.rt.newInt(0);
}

fn sock_send(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const fd = try getFd(v, args[0]);
    var data: []const u8 = "";
    if (args.len > 1) {
        switch (args[1].v) {
            .bytes => |b| data = b.data,
            .bytearray => |b| data = b.data.items,
            .str => |s| data = s.bytes,
            else => return raiseOSError(v, "TypeError", "send() needs bytes", .{}),
        }
    }
    const n = c.send(fd, data.ptr, data.len, 0);
    if (n < 0) return raiseOSError(v, "OSError", "send failed", .{});
    return v.rt.newInt(@intCast(n));
}

fn sock_sendall(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const fd = try getFd(v, args[0]);
    var data: []const u8 = "";
    if (args.len > 1) {
        switch (args[1].v) {
            .bytes => |b| data = b.data,
            .bytearray => |b| data = b.data.items,
            .str => |s| data = s.bytes,
            else => return raiseOSError(v, "TypeError", "sendall() needs bytes", .{}),
        }
    }
    var off: usize = 0;
    while (off < data.len) {
        const n = c.send(fd, data.ptr + off, data.len - off, 0);
        if (n < 0) return raiseOSError(v, "OSError", "sendall failed", .{});
        if (n == 0) break;
        off += @intCast(n);
    }
    return v.rt.newNone();
}

fn sock_recv(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const fd = try getFd(v, args[0]);
    var bufsize: usize = 8192;
    if (args.len > 1 and args[1].v == .int) bufsize = @intCast(args[1].v.int);
    if (bufsize == 0) bufsize = 8192;
    const buf = try v.rt.gpa.alloc(u8, bufsize);
    const n = c.recv(fd, buf.ptr, buf.len, 0);
    if (n < 0) return raiseOSError(v, "OSError", "recv failed", .{});
    return v.rt.newBytes(buf[0..@intCast(n)]);
}

fn sock_close(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (ops.instanceDict(args[0])) |d| {
        if (try ops.dictGetStr(d, v, "_fd")) |f| {
            if (f.v == .int and f.v.int >= 0) {
                _ = c.close(@intCast(f.v.int));
            }
        }
        try ops.dictSetStr(d, v, "_fd", try v.rt.newInt(-1));
        try ops.dictSetStr(d, v, "_closed", try v.rt.newInt(1));
    }
    return v.rt.newNone();
}

fn sock_shutdown(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const fd = try getFd(v, args[0]);
    var how: i32 = 2;
    if (args.len > 1 and args[1].v == .int) how = @intCast(args[1].v.int);
    _ = c.shutdown(fd, how);
    return v.rt.newNone();
}

fn sock_settimeout(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    var t: f64 = -1;
    if (args.len > 1) {
        if (args[1].v == .int) t = @floatFromInt(args[1].v.int) else if (args[1].v == .float) t = args[1].v.float;
    }
    try setInt(v, args[0], "_timeout_ms", if (t < 0) -1 else @intFromFloat(t * 1000));
    return v.rt.newNone();
}

fn sock_gettimeout(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const ms = getInt(v, args[0], "_timeout_ms") orelse return v.rt.newNone();
    if (ms < 0) return v.rt.newNone();
    return v.rt.newFloat(@as(f64, @floatFromInt(ms)) / 1000.0);
}

fn sock_setblocking(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    var flag = true;
    if (args.len > 1) flag = v.pyTruthy(args[1]) catch true;
    try setInt(v, args[0], "_timeout_ms", if (flag) -1 else 0);
    return v.rt.newNone();
}

fn sock_fileno(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    return v.rt.newInt(try getFd(v, args[0]));
}

fn sock_setsockopt(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const fd = try getFd(v, args[0]);
    if (args.len >= 4 and args[1].v == .int and args[2].v == .int and args[3].v == .int) {
        const level: i32 = @intCast(args[1].v.int);
        const opt: u32 = @intCast(args[2].v.int);
        var val: c_int = @intCast(args[3].v.int);
        _ = c.setsockopt(fd, level, opt, &val, @sizeOf(c_int));
    }
    return v.rt.newNone();
}

fn sock_getsockopt(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const fd = try getFd(v, args[0]);
    if (args.len >= 3 and args[1].v == .int and args[2].v == .int) {
        var val: c_int = 0;
        var len: c.socklen_t = @sizeOf(c_int);
        _ = c.getsockopt(fd, @intCast(args[1].v.int), @intCast(args[2].v.int), &val, &len);
        return v.rt.newInt(val);
    }
    return v.rt.newInt(0);
}

fn sock_bind(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const fd = try getFd(v, args[0]);
    const hp = try hostPort(v, args[1]);
    var sa = std.mem.zeroes(c.sockaddr.in);
    sa.family = posix.AF.INET;
    sa.port = std.mem.nativeToBig(u16, hp[1]);
    _ = c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in));
    return v.rt.newNone();
}

fn sock_listen(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const fd = try getFd(v, args[0]);
    var backlog: c_uint = 128;
    if (args.len > 1 and args[1].v == .int) backlog = @intCast(args[1].v.int);
    _ = c.listen(fd, backlog);
    return v.rt.newNone();
}

fn sock_accept(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const fd = try getFd(v, args[0]);
    var sa: c.sockaddr = undefined;
    var len: c.socklen_t = @sizeOf(c.sockaddr);
    const nfd = c.accept(fd, &sa, &len);
    if (nfd < 0) return raiseOSError(v, "OSError", "accept failed", .{});
    const newsock = try mkSocketObj(v, @intCast(nfd), posix.AF.INET, posix.SOCK.STREAM);
    const addr_t = try v.rt.newTuple(&.{ try v.rt.newStr("0.0.0.0"), try v.rt.newInt(0) });
    return v.rt.newTuple(&.{ newsock, addr_t });
}

fn sock_getpeername(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    _ = try getFd(v, args[0]);
    return v.rt.newTuple(&.{ try v.rt.newStr("0.0.0.0"), try v.rt.newInt(0) });
}

fn sock_getsockname(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    _ = try getFd(v, args[0]);
    return v.rt.newTuple(&.{ try v.rt.newStr("0.0.0.0"), try v.rt.newInt(0) });
}

fn sock_makefile(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    const f = try v.rt.gpa.create(object.File);
    f.* = .{ .f = null, .std_fd = null, .readable = true, .writable = true, .binary = true, .close_fd = false, .name = "<socket>" };
    return v.rt.mkObj(v.rt.file_t, .{ .file = f });
}

fn sock_dup(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const fd = try getFd(v, args[0]);
    const family = getInt(v, args[0], "_family") orelse posix.AF.INET;
    const stype = getInt(v, args[0], "_type") orelse posix.SOCK.STREAM;
    const nfd = c.dup(fd); // кроссплатформенный libc dup
    const real_fd: i32 = if (nfd < 0) fd else @intCast(nfd);
    return mkSocketObj(v, real_fd, @intCast(family), @intCast(stype));
}

// ============================================================
// функции модуля
// ============================================================

fn mod_create_connection(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len < 1) return raiseOSError(v, "TypeError", "create_connection() needs address", .{});
    const hp = try hostPort(v, args[0]);
    const r = try doConnect(v, hp[0], hp[1]);
    return mkSocketObj(v, r.fd, r.family, r.stype);
}

fn addrInfoToEntry(v: *VM, a: *c.addrinfo, port: u16) anyerror!Obj {
    var host_s: []const u8 = "0.0.0.0";
    var buf: [64]u8 = undefined;
    if (a.addr) |addr| {
        if (a.family == posix.AF.INET) {
            const sin = @as(*align(1) const c.sockaddr.in, @ptrCast(addr));
            const ipb = std.mem.asBytes(&sin.addr);
            host_s = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ ipb[0], ipb[1], ipb[2], ipb[3] }) catch "0.0.0.0";
        }
    }
    const sockaddr_t = try v.rt.newTuple(&.{ try v.rt.newStr(host_s), try v.rt.newInt(port) });
    return v.rt.newTuple(&.{
        try v.rt.newInt(a.family),
        try v.rt.newInt(a.socktype),
        try v.rt.newInt(a.protocol),
        try v.rt.newStr(""),
        sockaddr_t,
    });
}

fn mod_getaddrinfo(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    var host: []const u8 = "";
    var port: u16 = 0;
    if (args.len > 0 and args[0].v == .str) host = args[0].v.str.bytes;
    if (args.len > 1) {
        if (args[1].v == .int) port = @intCast(args[1].v.int) else if (args[1].v == .str) port = std.fmt.parseInt(u16, args[1].v.str.bytes, 10) catch 0;
    }
    const g = v.rt.gpa;
    const host_z = try g.dupeZ(u8, host);
    var pbuf: [8]u8 = undefined;
    const port_z = std.fmt.bufPrintZ(&pbuf, "{d}", .{port}) catch "0";
    var hints = std.mem.zeroes(c.addrinfo);
    hints.family = posix.AF.UNSPEC;
    hints.socktype = posix.SOCK.STREAM;
    var res: ?*c.addrinfo = null;
    const rc = c.getaddrinfo(host_z, port_z, &hints, &res);
    if (@intFromEnum(rc) != 0 or res == null) {
        try v.raiseFmt("gaierror", "Name or service not known: '{s}'", .{host});
        return error.PyExc;
    }
    defer c.freeaddrinfo(res.?);
    const out = try v.rt.newList();
    var ai: ?*c.addrinfo = res;
    var n: usize = 0;
    while (ai) |a| : (ai = a.next) {
        try out.v.list.items.append(g, try addrInfoToEntry(v, a, port));
        n += 1;
        if (n >= 8) break;
    }
    return out;
}

fn mod_gethostbyname(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    var host: []const u8 = "localhost";
    if (args.len > 0 and args[0].v == .str) host = args[0].v.str.bytes;
    const g = v.rt.gpa;
    const host_z = try g.dupeZ(u8, host);
    var hints = std.mem.zeroes(c.addrinfo);
    hints.family = posix.AF.INET;
    hints.socktype = posix.SOCK.STREAM;
    var res: ?*c.addrinfo = null;
    const rc = c.getaddrinfo(host_z, null, &hints, &res);
    if (@intFromEnum(rc) != 0 or res == null) {
        try v.raiseFmt("gaierror", "Name or service not known: '{s}'", .{host});
        return error.PyExc;
    }
    defer c.freeaddrinfo(res.?);
    const a = res.?;
    if (a.addr) |addr| {
        const sin = @as(*align(1) const c.sockaddr.in, @ptrCast(addr));
        const ipb = std.mem.asBytes(&sin.addr);
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ ipb[0], ipb[1], ipb[2], ipb[3] }) catch "";
        return v.rt.newStr(s);
    }
    return v.rt.newStr(host);
}

fn mod_gethostbyaddr(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    var ip: []const u8 = "127.0.0.1";
    if (args.len > 0 and args[0].v == .str) ip = args[0].v.str.bytes;
    return v.rt.newTuple(&.{ try v.rt.newStr(ip), try v.rt.newList(), try v.rt.newListFrom(&.{try v.rt.newStr(ip)}) });
}

fn mod_gethostname(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    var buf: [256]u8 = undefined;
    const rc = c.gethostname(&buf, buf.len);
    if (rc != 0) return v.rt.newStr("localhost");
    const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
    return v.rt.newStr(buf[0..len]);
}

fn mod_htonl(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x: u32 = if (args.len > 0 and args[0].v == .int) @intCast(args[0].v.int) else 0;
    return v.rt.newInt(@intCast(std.mem.nativeToBig(u32, x)));
}
fn mod_htons(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x: u16 = if (args.len > 0 and args[0].v == .int) @intCast(args[0].v.int) else 0;
    return v.rt.newInt(std.mem.nativeToBig(u16, x));
}
fn mod_ntohl(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x: u32 = if (args.len > 0 and args[0].v == .int) @intCast(args[0].v.int) else 0;
    return v.rt.newInt(@intCast(std.mem.bigToNative(u32, x)));
}
fn mod_ntohs(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    const x: u16 = if (args.len > 0 and args[0].v == .int) @intCast(args[0].v.int) else 0;
    return v.rt.newInt(std.mem.bigToNative(u16, x));
}

fn parseIpv4(s: []const u8) ?u32 {
    var it = std.mem.splitScalar(u8, s, '.');
    var result: u32 = 0;
    var count: u8 = 0;
    while (it.next()) |part| {
        const b = std.fmt.parseInt(u8, part, 10) catch return null;
        result = (result << 8) | b;
        count += 1;
    }
    if (count != 4) return null;
    return result;
}

fn mod_inet_aton(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    var s: []const u8 = "0.0.0.0";
    if (args.len > 0 and args[0].v == .str) s = args[0].v.str.bytes;
    const ip = parseIpv4(s) orelse return raiseOSError(v, "OSError", "illegal IP address: '{s}'", .{s});
    return v.rt.newBytes(&.{
        @as(u8, @truncate(ip >> 24)), @as(u8, @truncate(ip >> 16)),
        @as(u8, @truncate(ip >> 8)),  @as(u8, @truncate(ip)),
    });
}

fn mod_inet_ntoa(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len > 0 and args[0].v == .bytes and args[0].v.bytes.data.len == 4) {
        const ip = args[0].v.bytes.data;
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch "";
        return v.rt.newStr(s);
    }
    return raiseOSError(v, "OSError", "packed IP wrong length", .{});
}

fn mod_inet_pton(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len >= 2 and args[0].v == .int and args[0].v.int == posix.AF.INET and args[1].v == .str) {
        return mod_inet_aton(v, args[1..2], null);
    }
    const zeros = [_]u8{0} ** 16;
    return v.rt.newBytes(&zeros);
}

fn mod_inet_ntop(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = kw;
    const v: *VM = vm;
    if (args.len >= 2 and args[1].v == .bytes and args[1].v.bytes.data.len == 4) {
        return mod_inet_ntoa(v, args[1..2], null);
    }
    return v.rt.newStr("::");
}

fn mod_socketpair(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    const v: *VM = vm;
    var fds: [2]c.fd_t = undefined;
    const rc = c.socketpair(@intCast(posix.AF.UNIX), @intCast(posix.SOCK.STREAM), 0, &fds);
    if (rc != 0) return raiseOSError(v, "OSError", "socketpair failed", .{});
    const a = try mkSocketObj(v, @intCast(fds[0]), posix.AF.UNIX, posix.SOCK.STREAM);
    const b = try mkSocketObj(v, @intCast(fds[1]), posix.AF.UNIX, posix.SOCK.STREAM);
    return v.rt.newTuple(&.{ a, b });
}

fn mod_getdefaulttimeout(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    return vm.rt.newNone();
}
fn mod_setdefaulttimeout(vm: anytype, args: []const Obj, kw: ?KwArgs) anyerror!Obj {
    _ = args;
    _ = kw;
    return vm.rt.newNone();
}
