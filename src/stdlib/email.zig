//! email — аналог Lib/email/ (минимально: email.errors + email.utils для urllib3).
//! Три native-модуля: email, email.errors, email.utils.

const std = @import("std");
const object = @import("../object/object.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const compiler = @import("../compiler/compiler.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;

fn execPy(vm: *VM, m: Obj, name: []const u8, src: []const u8) anyerror!void {
    const rt = vm.rt;
    const md = m.v.module;
    try ops.dictSetStr(md.dict, vm, "__name__", try rt.newStr(name));
    try ops.dictSetStr(md.dict, vm, "__builtins__", try rt.mkObj(rt.dict_t, .{ .dict = rt.builtins_dict }));
    const code = compiler.compileSource(vm, name, src, .exec) catch |e| return e;
    vm.runNameScope(code, md.dict, null) catch |e| return e;
}

const ERRORS_SRC =
    \\class MessageDefect(Exception):
    \\    def __init__(self, line=None):
    \\        self.line = line
    \\        super().__init__(line)
    \\class NoBoundaryInMultipartDefect(MessageDefect): pass
    \\class StartBoundaryNotFoundDefect(MessageDefect): pass
    \\class CloseBoundaryNotFoundDefect(MessageDefect): pass
    \\class FirstHeaderLineIsContinuationDefect(MessageDefect): pass
    \\class MisplacedEnvelopeHeaderDefect(MessageDefect): pass
    \\class MissingHeaderBodySeparatorDefect(MessageDefect): pass
    \\class MultipartInvariantViolationDefect(MessageDefect): pass
    \\class InvalidMultipartContentTransferEncodingDefect(MessageDefect): pass
    \\class UndecodableBytesDefect(MessageDefect): pass
    \\class InvalidBase64PaddingDefect(MessageDefect): pass
    \\class InvalidBase64CharactersDefect(MessageDefect): pass
    \\class InvalidBase64LengthDefect(MessageDefect): pass
    \\class InvalidDateDefect(MessageDefect): pass
    \\class HeaderWriteError(MessageDefect): pass
    \\class MessageError(Exception): pass
    \\class MessageParseError(MessageError): pass
    \\class HeaderParseError(MessageParseError): pass
    \\class BoundaryError(MessageParseError): pass
    \\class MultipartConversionError(MessageError): pass
    \\class CharsetError(MessageError): pass
;

const UTILS_SRC =
    \\import time as _time
    \\
    \\def encode_rfc2231(s, charset=None, language=None):
    \\    if charset is None and language is None:
    \\        return s
    \\    if language is None:
    \\        language = ''
    \\    if charset is None:
    \\        charset = ''
    \\    return "%s'%s'%s" % (charset, language, s)
    \\
    \\def decode_rfc2231(s):
    \\    parts = s.split("'", 2)
    \\    if len(parts) <= 2:
    \\        return (None, None, s)
    \\    return (parts[0] or None, parts[1] or None, parts[2])
    \\
    \\_monthnames = ['jan','feb','mar','apr','may','jun','jul','aug','sep','oct','nov','dec']
    \\_daynames = ['mon','tue','wed','thu','fri','sat','sun']
    \\
    \\def parsedate_tz(data):
    \\    if not data:
    \\        return None
    \\    data = data.strip()
    \\    parts = data.split()
    \\    if len(parts) < 5:
    \\        return None
    \\    idx = 0
    \\    p0 = parts[0].rstrip(',').lower()
    \\    if p0.isalpha() and (p0 in _daynames or len(p0) <= 4):
    \\        idx = 1
    \\    try:
    \\        day = int(parts[idx].rstrip(','))
    \\        mon = _monthnames.index(parts[idx+1].lower()[:3]) + 1
    \\        year = int(parts[idx+2])
    \\        if year < 100:
    \\            year += 2000 if year < 70 else 1900
    \\        hms = parts[idx+3].split(':')
    \\        hh = int(hms[0]); mm = int(hms[1])
    \\        ss = int(hms[2]) if len(hms) > 2 else 0
    \\        tz = 0
    \\        if len(parts) > idx+4:
    \\            tzs = parts[idx+4]
    \\            if tzs[0] in '+-' and len(tzs) == 5:
    \\                sign = -1 if tzs[0] == '-' else 1
    \\                tz = sign * (int(tzs[1:3])*3600 + int(tzs[3:5])*60)
    \\        return (year, mon, day, hh, mm, ss, 0, 1, 0, tz)
    \\    except Exception:
    \\        return None
    \\
    \\def parsedate(data):
    \\    t = parsedate_tz(data)
    \\    if t is None:
    \\        return None
    \\    return t[:9]
    \\
    \\def mktime_tz(data):
    \\    try:
    \\        days = _days_before_year(data[0]) + data[2] - 1
    \\        secs = data[3]*3600 + data[4]*60 + data[5]
    \\        epoch = (days - 719163) * 86400 + secs
    \\        return epoch - data[9]
    \\    except Exception:
    \\        return _time.time()
    \\
    \\def _is_leap(y):
    \\    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)
    \\
    \\def _days_before_year(y):
    \\    y -= 1
    \\    return y*365 + y//4 - y//100 + y//400
    \\
    \\def formatdate(timeval=None, localtime=False, usegmt=False):
    \\    if timeval is None:
    \\        timeval = _time.time()
    \\    return _time.strftime('%a, %d %b %Y %H:%M:%S GMT', _time.gmtime(timeval))
    \\
    \\def formataddr(pair, charset='utf-8'):
    \\    name, address = pair
    \\    if name:
    \\        return '%s <%s>' % (name, address)
    \\    return address
    \\
    \\def parseaddr(addr):
    \\    if '<' in addr and addr.rstrip().endswith('>'):
    \\        i = addr.index('<')
    \\        return (addr[:i].strip(), addr[i+1:-1].strip())
    \\    return ('', addr.strip())
    \\
    \\def getaddresses(fieldvalues):
    \\    return [parseaddr(v) for v in fieldvalues]
    \\
    \\def quote(s):
    \\    return s.replace('\\', '\\\\').replace('"', '\\"')
    \\
    \\def unquote(s):
    \\    return s.replace('\\"', '"').replace('\\\\', '\\')
    \\
    \\def make_msgid(idstring=None, domain=None):
    \\    return '<%s@%s>' % (idstring or 'msg', domain or 'localhost')
    \\
    \\def collapse_rfc2231_value(value):
    \\    return value
    \\
    \\def sanitize_address(addr, encoding='utf-8'):
    \\    return addr
;

const EMAIL_SRC =
    \\def message_from_string(s, *args, **kwargs):
    \\    return None
    \\def message_from_bytes(b, *args, **kwargs):
    \\    return None
    \\def message_from_file(fp, *args, **kwargs):
    \\    return None
    \\def message_from_binary_file(fp, *args, **kwargs):
    \\    return None
;

pub fn initModule(vm: *VM) anyerror!Obj {
    const m = try vm.rt.newModuleObj("email");
    // пакет: __path__
    const path = try vm.rt.newList();
    try path.v.list.items.append(vm.rt.gpa, try vm.rt.newStr("<email>"));
    try ops.dictSetStr(m.v.module.dict, vm, "__path__", path);
    try execPy(vm, m, "email", EMAIL_SRC);
    return m;
}

pub fn initErrors(vm: *VM) anyerror!Obj {
    const m = try vm.rt.newModuleObj("email.errors");
    try execPy(vm, m, "email.errors", ERRORS_SRC);
    return m;
}

pub fn initUtils(vm: *VM) anyerror!Obj {
    const m = try vm.rt.newModuleObj("email.utils");
    try execPy(vm, m, "email.utils", UTILS_SRC);
    return m;
}
