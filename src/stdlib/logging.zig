//! logging — аналог Lib/logging/__init__.py (минимальный: логгирование подавлено).
//! Достаточно для urllib3/requests: getLogger, Logger.{debug,warning,...}, NullHandler.

const std = @import("std");
const object = @import("../object/object.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const compiler = @import("../compiler/compiler.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;

const PY_SRC =
    \\CRITICAL = 50
    \\FATAL = CRITICAL
    \\ERROR = 40
    \\WARNING = 30
    \\WARN = WARNING
    \\INFO = 20
    \\DEBUG = 10
    \\NOTSET = 0
    \\
    \\_nameToLevel = {'CRITICAL':50,'FATAL':50,'ERROR':40,'WARNING':30,'WARN':30,
    \\                'INFO':20,'DEBUG':10,'NOTSET':0}
    \\_levelToName = {50:'CRITICAL',40:'ERROR',30:'WARNING',20:'INFO',10:'DEBUG',0:'NOTSET'}
    \\
    \\def getLevelName(level):
    \\    if level in _levelToName:
    \\        return _levelToName[level]
    \\    if level in _nameToLevel:
    \\        return _nameToLevel[level]
    \\    return 'Level %s' % level
    \\
    \\def addLevelName(level, levelName):
    \\    _nameToLevel[levelName] = level
    \\    _levelToName[level] = levelName
    \\
    \\class Filterer:
    \\    def __init__(self):
    \\        self.filters = []
    \\    def addFilter(self, f): self.filters.append(f)
    \\    def removeFilter(self, f):
    \\        if f in self.filters: self.filters.remove(f)
    \\    def filter(self, record): return True
    \\
    \\class Filter:
    \\    def __init__(self, name=''):
    \\        self.name = name
    \\    def filter(self, record): return True
    \\
    \\class Handler(Filterer):
    \\    def __init__(self, level=NOTSET):
    \\        Filterer.__init__(self)
    \\        self.level = level
    \\        self.formatter = None
    \\        self.lock = None
    \\    def setLevel(self, level): self.level = level
    \\    def setFormatter(self, fmt): self.formatter = fmt
    \\    def createLock(self): self.lock = None
    \\    def acquire(self): pass
    \\    def release(self): pass
    \\    def handle(self, record): pass
    \\    def emit(self, record): pass
    \\    def flush(self): pass
    \\    def close(self): pass
    \\    def format(self, record): return ''
    \\
    \\class NullHandler(Handler):
    \\    def handle(self, record): pass
    \\    def emit(self, record): pass
    \\    def createLock(self): self.lock = None
    \\
    \\class StreamHandler(Handler):
    \\    def emit(self, record): pass
    \\
    \\class FileHandler(Handler):
    \\    def __init__(self, filename, mode='a', encoding=None, delay=False, errors=None):
    \\        Handler.__init__(self)
    \\        self.baseFilename = filename
    \\
    \\class Formatter:
    \\    def __init__(self, fmt=None, datefmt=None, style='%', validate=True, defaults=None):
    \\        self._fmt = fmt or '%(message)s'
    \\        self.datefmt = datefmt
    \\    def format(self, record):
    \\        return getattr(record, 'msg', '')
    \\    def formatTime(self, record, datefmt=None): return ''
    \\
    \\class LogRecord:
    \\    def __init__(self, name, level, pathname, lineno, msg, args, exc_info, func=None, sinfo=None):
    \\        self.name = name
    \\        self.levelno = level
    \\        self.levelname = getLevelName(level)
    \\        self.pathname = pathname
    \\        self.lineno = lineno
    \\        self.msg = msg
    \\        self.args = args
    \\        self.exc_info = exc_info
    \\        self.funcName = func
    \\    def getMessage(self):
    \\        msg = str(self.msg)
    \\        if self.args:
    \\            msg = msg % self.args
    \\        return msg
    \\
    \\class Logger(Filterer):
    \\    def __init__(self, name, level=NOTSET):
    \\        Filterer.__init__(self)
    \\        self.name = name
    \\        self.level = level
    \\        self.parent = None
    \\        self.handlers = []
    \\        self.disabled = False
    \\        self.propagate = True
    \\    def setLevel(self, level):
    \\        if isinstance(level, str):
    \\            level = _nameToLevel.get(level, NOTSET)
    \\        self.level = level
    \\    def getEffectiveLevel(self):
    \\        return self.level or WARNING
    \\    def isEnabledFor(self, level):
    \\        return level >= self.getEffectiveLevel()
    \\    def addHandler(self, h):
    \\        if h not in self.handlers: self.handlers.append(h)
    \\    def removeHandler(self, h):
    \\        if h in self.handlers: self.handlers.remove(h)
    \\    def hasHandlers(self):
    \\        return len(self.handlers) > 0
    \\    def handle(self, record): pass
    \\    def callHandlers(self, record): pass
    \\    def makeRecord(self, name, level, fn, lno, msg, args, exc_info, func=None, extra=None, sinfo=None):
    \\        return LogRecord(name, level, fn, lno, msg, args, exc_info, func)
    \\    def findCaller(self, stack_info=False, stacklevel=1):
    \\        return ('<string>', 0, '', None)
    \\    def _log(self, level, msg, args, exc_info=None, extra=None, stack_info=False, stacklevel=1):
    \\        pass
    \\    def debug(self, msg, *args, **kwargs): pass
    \\    def info(self, msg, *args, **kwargs): pass
    \\    def warning(self, msg, *args, **kwargs): pass
    \\    def warn(self, msg, *args, **kwargs): pass
    \\    def error(self, msg, *args, **kwargs): pass
    \\    def exception(self, msg, *args, exc_info=True, **kwargs): pass
    \\    def critical(self, msg, *args, **kwargs): pass
    \\    def fatal(self, msg, *args, **kwargs): pass
    \\    def log(self, level, msg, *args, **kwargs): pass
    \\
    \\root = Logger('root', WARNING)
    \\root.addHandler(NullHandler())
    \\_loggers = {}
    \\
    \\class Manager:
    \\    def __init__(self, rootnode):
    \\        self.root = rootnode
    \\        self.loggerDict = {}
    \\    def getLogger(self, name):
    \\        return _loggers.get(name) or self._make(name)
    \\    def _make(self, name):
    \\        lg = Logger(name, WARNING)
    \\        _loggers[name] = lg
    \\        return lg
    \\
    \\manager = Manager(root)
    \\
    \\def getLogger(name=None):
    \\    if name is None:
    \\        return root
    \\    return manager.getLogger(name)
    \\
    \\def getLogRecordFactory(): return LogRecord
    \\def setLogRecordFactory(f): pass
    \\def basicConfig(**kwargs):
    \\    if len(root.handlers) == 0:
    \\        root.addHandler(NullHandler())
    \\def debug(msg, *args, **kwargs): pass
    \\def info(msg, *args, **kwargs): pass
    \\def warning(msg, *args, **kwargs): pass
    \\def warn(msg, *args, **kwargs): pass
    \\def error(msg, *args, **kwargs): pass
    \\def critical(msg, *args, **kwargs): pass
    \\def exception(msg, *args, exc_info=True, **kwargs): pass
    \\def log(level, msg, *args, **kwargs): pass
    \\def disable(level=CRITICAL): pass
    \\def shutdown(): pass
    \\
    \\class LoggerAdapter:
    \\    def __init__(self, logger, extra=None, merge_extra=False):
    \\        self.logger = logger
    \\        self.extra = extra or {}
    \\    def debug(self, msg, *a, **k): self.logger.debug(msg, *a, **k)
    \\    def info(self, msg, *a, **k): self.logger.info(msg, *a, **k)
    \\    def warning(self, msg, *a, **k): self.logger.warning(msg, *a, **k)
    \\    def error(self, msg, *a, **k): self.logger.error(msg, *a, **k)
    \\    def critical(self, msg, *a, **k): self.logger.critical(msg, *a, **k)
    \\    def log(self, lvl, msg, *a, **k): self.logger.log(lvl, msg, *a, **k)
    \\    def isEnabledFor(self, lvl): return self.logger.isEnabledFor(lvl)
    \\    def setLevel(self, lvl): self.logger.setLevel(lvl)
;

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("logging");
    const md = m.v.module;
    try ops.dictSetStr(md.dict, vm, "__name__", try rt.newStr("logging"));
    try ops.dictSetStr(md.dict, vm, "__builtins__", try rt.mkObj(rt.dict_t, .{ .dict = rt.builtins_dict }));

    const code = compiler.compileSource(vm, "<logging>", PY_SRC, .exec) catch |e| return e;
    vm.runNameScope(code, md.dict, null) catch |e| return e;
    return m;
}
