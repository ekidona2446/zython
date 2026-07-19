//! http.client — аналог Lib/http/client.py (рабочее подмножество для urllib3/requests).
//! HTTPConnection на реальном socket, HTTPResponse, HTTPSConnection (через ssl при наличии).

const std = @import("std");
const object = @import("../object/object.zig");
const ops = @import("../vm/ops.zig");
const vm_mod = @import("../vm/vm.zig");
const compiler = @import("../compiler/compiler.zig");

const VM = vm_mod.VM;
const Obj = object.Obj;

const PY_SRC =
    \\import socket as _socket
    \\
    \\# --- Исключения (аналог http.client) ---
    \\class HTTPException(Exception): pass
    \\class NotConnected(HTTPException): pass
    \\class InvalidURL(HTTPException): pass
    \\class UnknownProtocol(HTTPException):
    \\    def __init__(self, version): self.version = version
    \\class UnknownTransferEncoding(HTTPException): pass
    \\class UnimplementedFileMode(HTTPException): pass
    \\class IncompleteRead(HTTPException):
    \\    def __init__(self, partial, expected=None):
    \\        self.partial = partial
    \\        self.expected = expected
    \\        super().__init__(repr(partial), expected)
    \\class ImproperConnectionState(HTTPException): pass
    \\class CannotSendRequest(ImproperConnectionState): pass
    \\class CannotSendHeader(ImproperConnectionState): pass
    \\class ResponseNotReady(ImproperConnectionState): pass
    \\class BadStatusLine(HTTPException):
    \\    def __init__(self, line): self.line = line; super().__init__(line)
    \\class LineTooLong(HTTPException):
    \\    def __init__(self, line_type): super().__init__('got more than %d bytes when reading %s' % (65536, line_type))
    \\class RemoteDisconnected(ConnectionResetError, BadStatusLine):
    \\    def __init__(self, *a, **k):
    \\        BadStatusLine.__init__(self, '')
    \\        ConnectionResetError.__init__(self, *a)
    \\
    \\responses = {
    \\    100: 'Continue', 101: 'Switching Protocols',
    \\    200: 'OK', 201: 'Created', 202: 'Accepted', 203: 'Non-Authoritative Information',
    \\    204: 'No Content', 205: 'Reset Content', 206: 'Partial Content',
    \\    300: 'Multiple Choices', 301: 'Moved Permanently', 302: 'Found', 303: 'See Other',
    \\    304: 'Not Modified', 305: 'Use Proxy', 307: 'Temporary Redirect', 308: 'Permanent Redirect',
    \\    400: 'Bad Request', 401: 'Unauthorized', 402: 'Payment Required', 403: 'Forbidden',
    \\    404: 'Not Found', 405: 'Method Not Allowed', 406: 'Not Acceptable',
    \\    407: 'Proxy Authentication Required', 408: 'Request Timeout', 409: 'Conflict',
    \\    410: 'Gone', 411: 'Length Required', 412: 'Precondition Failed',
    \\    413: 'Request Entity Too Large', 414: 'Request-URI Too Long',
    \\    415: 'Unsupported Media Type', 416: 'Requested Range Not Satisfiable',
    \\    417: 'Expectation Failed', 429: 'Too Many Requests',
    \\    500: 'Internal Server Error', 501: 'Not Implemented', 502: 'Bad Gateway',
    \\    503: 'Service Unavailable', 504: 'Gateway Timeout', 505: 'HTTP Version Not Supported',
    \\}
    \\
    \\_CONTINUE = 100
    \\HTTP_PORT = 80
    \\HTTPS_PORT = 443
    \\_CS_IDLE = 'Idle'
    \\_CS_REQ_STARTED = 'Request-started'
    \\_CS_REQ_SENT = 'Request-sent'
    \\
    \\class HTTPResponse:
    \\    def __init__(self, sock, method='GET'):
    \\        self._sock = sock
    \\        self.method = method
    \\        self.version = 11
    \\        self.status = None
    \\        self.code = None
    \\        self.reason = None
    \\        self.headers = _Headers()
    \\        self.msg = None
    \\        self._body = b''
    \\        self._read_done = False
    \\        self.will_close = True
    \\        self.chunked = False
    \\        self.length = None
    \\        self.closed = False
    \\    def _parse_status(self, line):
    \\        parts = line.split(None, 2)
    \\        self.version = 11 if '1.1' in parts[0] else 10
    \\        self.status = int(parts[1])
    \\        self.code = self.status
    \\        self.reason = parts[2] if len(parts) > 2 else ''
    \\    def begin(self):
    \\        line = self._readline()
    \\        if not line:
    \\            raise RemoteDisconnected('Remote end closed connection without response')
    \\        if not line.startswith('HTTP/'):
    \\            raise BadStatusLine(line)
    \\        self._parse_status(line)
    \\        self.headers = _Headers()
    \\        while True:
    \\            h = self._readline()
    \\            if h in ('', '\r'):
    \\                break
    \\            h = h.rstrip('\r\n')
    \\            if ':' in h:
    \\                k, v = h.split(':', 1)
    \\                self.headers.add(k.strip(), v.strip())
    \\        te = self.headers.get('Transfer-Encoding', '').lower()
    \\        cl = self.headers.get('Content-Length')
    \\        if te == 'chunked':
    \\            self.chunked = True
    \\        elif cl is not None:
    \\            try: self.length = int(cl)
    \\            except Exception: self.length = None
    \\        self.msg = self.headers
    \\    def _readline(self):
    \\        buf = b''
    \\        while not buf.endswith(b'\n'):
    \\            c = self._sock.recv(1)
    \\            if not c:
    \\                break
    \\            buf += c
    \\            if len(buf) > 65536:
    \\                raise LineTooLong('header')
    \\        return buf.decode('iso-8859-1')
    \\    def _read_exact(self, n):
    \\        data = b''
    \\        while len(data) < n:
    \\            c = self._sock.recv(n - len(data))
    \\            if not c:
    \\                break
    \\            data += c
    \\        return data
    \\    def read(self, amt=None):
    \\        if self._read_done and amt is None:
    \\            return self._body
    \\        data = b''
    \\        if self.chunked:
    \\            data = self._read_chunked()
    \\        elif self.length is not None:
    \\            data = self._read_exact(self.length)
    \\            self.length = 0
    \\        else:
    \\            while True:
    \\                c = self._sock.recv(8192)
    \\                if not c:
    \\                    break
    \\                data += c
    \\        if self._body == b'':
    \\            self._body = data
    \\        self._read_done = True
    \\        if amt is not None:
    \\            return data[:amt]
    \\        return data
    \\    def _read_chunked(self):
    \\        data = b''
    \\        while True:
    \\            line = self._readline().strip()
    \\            if not line:
    \\                continue
    \\            size = int(line.split(b';')[0], 16)
    \\            if size == 0:
    \\                self._readline()
    \\                break
    \\            data += self._read_exact(size)
    \\            self._readline()
    \\        return data
    \\    def readinto(self, b):
    \\        data = self.read(len(b))
    \\        n = len(data)
    \\        b[:n] = data
    \\        return n
    \\    def isclosed(self):
    \\        return self._read_done
    \\    def close(self):
    \\        self.closed = True
    \\    def getheader(self, name, default=None):
    \\        return self.headers.get(name, default)
    \\    def getheaders(self):
    \\        return list(self.headers.items())
    \\    def info(self):
    \\        return self.headers
    \\    def fp(self):
    \\        return None
    \\    def readable(self):
    \\        return True
    \\    def peek(self, n=1):
    \\        return b''
    \\
    \\class _Headers:
    \\    def __init__(self):
    \\        self._items = []
    \\    def add(self, k, v):
    \\        self._items.append((k, v))
    \\    def get(self, name, default=None):
    \\        name = name.lower()
    \\        for k, v in self._items:
    \\            if k.lower() == name:
    \\                return v
    \\        return default
    \\    def get_all(self, name, default=None):
    \\        name = name.lower()
    \\        r = [v for k, v in self._items if k.lower() == name]
    \\        return r if r else default
    \\    def items(self):
    \\        return list(self._items)
    \\    def keys(self):
    \\        return [k for k, v in self._items]
    \\    def values(self):
    \\        return [v for k, v in self._items]
    \\    def __getitem__(self, name):
    \\        v = self.get(name)
    \\        if v is None:
    \\            raise KeyError(name)
    \\        return v
    \\    def __contains__(self, name):
    \\        return self.get(name) is not None
    \\    def __iter__(self):
    \\        return iter(self.keys())
    \\    def __len__(self):
    \\        return len(self._items)
    \\    def __repr__(self):
    \\        return '<_Headers %r>' % (self._items,)
    \\    def as_bytes(self):
    \\        return (''.join('%s: %s\r\n' % (k, v) for k, v in self._items)).encode('iso-8859-1')
    \\
    \\class HTTPConnection:
    \\    default_port = HTTP_PORT
    \\    auto_open = 1
    \\    debuglevel = 0
    \\    _http_vsn = 11
    \\    _http_vsn_str = 'HTTP/1.1'
    \\    response_class = HTTPResponse
    \\    protocol_version = 'HTTP/1.0'
    \\
    \\    def __init__(self, host, port=None, timeout=None, source_address=None, blocksize=8192):
    \\        self.host = host
    \\        self.port = port if port is not None else self.default_port
    \\        self.timeout = timeout
    \\        self.source_address = source_address
    \\        self.blocksize = blocksize
    \\        self.sock = None
    \\        self._buffer = []
    \\        self.__response = None
    \\        self.__state = _CS_IDLE
    \\        self._method = None
    \\        self._tunnel_host = None
    \\
    \\    def _new_conn(self):
    \\        sock = _socket.create_connection((self.host, self.port), self.timeout)
    \\        return sock
    \\
    \\    def connect(self):
    \\        self.sock = self._new_conn()
    \\        self.__state = _CS_IDLE
    \\
    \\    def set_debuglevel(self, level):
    \\        self.debuglevel = level
    \\
    \\    def set_tunnel(self, host, port=None, headers=None):
    \\        self._tunnel_host = host
    \\        self._tunnel_port = port
    \\        self._tunnel_headers = headers or {}
    \\
    \\    def send(self, data):
    \\        if self.sock is None:
    \\            if self.auto_open:
    \\                self.connect()
    \\            else:
    \\                raise NotConnected()
    \\        if hasattr(data, 'read'):
    \\            while True:
    \\                d = data.read(self.blocksize)
    \\                if not d:
    \\                    break
    \\                self.sock.sendall(d)
    \\        else:
    \\            if isinstance(data, str):
    \\                data = data.encode('iso-8859-1')
    \\            self.sock.sendall(data)
    \\
    \\    def putrequest(self, method, url, skip_host=False, skip_accept_encoding=False):
    \\        if self.sock is None:
    \\            self.connect()
    \\        self._method = method
    \\        self._buffer = []
    \\        request = '%s %s %s' % (method, url, self._http_vsn_str)
    \\        self._buffer.append((request + '\r\n').encode('iso-8859-1'))
    \\        if self.protocol_version == 'HTTP/1.1' and not skip_host:
    \\            netloc = self.host
    \\            if self.port and self.port != self.default_port:
    \\                netloc = '%s:%s' % (self.host, self.port)
    \\            self._buffer.append(('Host: %s\r\n' % netloc).encode('iso-8859-1'))
    \\        self.__state = _CS_REQ_STARTED
    \\
    \\    def putheader(self, header, *values):
    \\        v = '\r\n\t'.join(str(x) for x in values)
    \\        self._buffer.append(('%s: %s\r\n' % (header, v)).encode('iso-8859-1'))
    \\
    \\    def endheaders(self, message_body=None, encode_chunked=False):
    \\        if self.__state != _CS_REQ_STARTED:
    \\            raise CannotSendHeader()
    \\        self._buffer.append(b'\r\n')
    \\        msg = b''.join(self._buffer)
    \\        self._buffer = []
    \\        self.send(msg)
    \\        if message_body is not None:
    \\            self.send(message_body)
    \\        self.__state = _CS_REQ_SENT
    \\
    \\    def request(self, method, url, body=None, headers=None, encode_chunked=False):
    \\        headers = headers or {}
    \\        self.putrequest(method, url)
    \\        if body is not None:
    \\            if isinstance(body, str):
    \\                body = body.encode('iso-8859-1')
    \\            if 'Content-Length' not in headers and 'Transfer-Encoding' not in headers:
    \\                headers['Content-Length'] = str(len(body))
    \\        for k, v in headers.items():
    \\            self.putheader(k, v)
    \\        self.endheaders(body)
    \\
    \\    def getresponse(self):
    \\        if self.sock is None:
    \\            raise ResponseNotReady()
    \\        resp = self.response_class(self.sock, self._method or 'GET')
    \\        resp.begin()
    \\        self.__response = resp
    \\        self.__state = _CS_IDLE
    \\        if resp.will_close:
    \\            self.sock = None
    \\        return resp
    \\
    \\    def close(self):
    \\        if self.sock is not None:
    \\            self.sock.close()
    \\            self.sock = None
    \\        self.__state = _CS_IDLE
    \\
    \\    def __enter__(self):
    \\        return self
    \\    def __exit__(self, *a):
    \\        self.close()
    \\        return False
    \\
    \\class HTTPSConnection(HTTPConnection):
    \\    default_port = HTTPS_PORT
    \\    def __init__(self, host, port=None, key_file=None, cert_file=None,
    \\                 timeout=None, source_address=None, context=None,
    \\                 check_hostname=None, blocksize=8192, **kw):
    \\        super().__init__(host, port, timeout, source_address, blocksize)
    \\        self.key_file = key_file
    \\        self.cert_file = cert_file
    \\        self._context = context
    \\        self._check_hostname = check_hostname
    \\    def connect(self):
    \\        sock = self._new_conn()
    \\        try:
    \\            import ssl
    \\            ctx = self._context or ssl.create_default_context()
    \\            self.sock = ctx.wrap_socket(sock, server_hostname=self.host)
    \\        except ImportError:
    \\            self.sock = sock
    \\
    \\class HTTP:
    \\    def __init__(self, host='', port=None, **kw):
    \\        self._conn = HTTPConnection(host, port)
    \\class HTTPS:
    \\    def __init__(self, host='', port=None, **kw):
    \\        self._conn = HTTPSConnection(host, port)
;

pub fn initPackage(vm: *VM) anyerror!Obj {
    const m = try vm.rt.newModuleObj("http");
    const path = try vm.rt.newList();
    try path.v.list.items.append(vm.rt.gpa, try vm.rt.newStr("<http>"));
    try ops.dictSetStr(m.v.module.dict, vm, "__path__", path);
    try ops.dictSetStr(m.v.module.dict, vm, "__builtins__", try vm.rt.mkObj(vm.rt.dict_t, .{ .dict = vm.rt.builtins_dict }));
    return m;
}

pub fn initModule(vm: *VM) anyerror!Obj {
    const rt = vm.rt;
    const m = try rt.newModuleObj("http.client");
    const md = m.v.module;
    try ops.dictSetStr(md.dict, vm, "__name__", try rt.newStr("http.client"));
    try ops.dictSetStr(md.dict, vm, "__builtins__", try rt.mkObj(rt.dict_t, .{ .dict = rt.builtins_dict }));
    const code = compiler.compileSource(vm, "<http.client>", PY_SRC, .exec) catch |e| return e;
    vm.runNameScope(code, md.dict, null) catch |e| return e;
    return m;
}
