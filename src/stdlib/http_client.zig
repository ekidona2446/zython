//! http.client — HTTP protocol client
//! Аналог Lib/http/client.py
//! Critical для requests, httpx, aiohttp

const std = @import("std");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

// === HTTP status codes ===
pub const HTTPStatus = enum(i32) {
    // 1xx Informational
    CONTINUE = 100,
    SWITCHING_PROTOCOLS = 101,
    PROCESSING = 102,
    EARLY_HINTS = 103,

    // 2xx Success
    OK = 200,
    CREATED = 201,
    ACCEPTED = 202,
    NON_AUTHORITATIVE_INFORMATION = 203,
    NO_CONTENT = 204,
    RESET_CONTENT = 205,
    PARTIAL_CONTENT = 206,
    MULTI_STATUS = 207,
    ALREADY_REPORTED = 208,
    IM_USED = 226,

    // 3xx Redirection
    MULTIPLE_CHOICES = 300,
    MOVED_PERMANENTLY = 301,
    FOUND = 302,
    SEE_OTHER = 303,
    NOT_MODIFIED = 304,
    USE_PROXY = 305,
    TEMPORARY_REDIRECT = 307,
    PERMANENT_REDIRECT = 308,

    // 4xx Client Errors
    BAD_REQUEST = 400,
    UNAUTHORIZED = 401,
    PAYMENT_REQUIRED = 402,
    FORBIDDEN = 403,
    NOT_FOUND = 404,
    METHOD_NOT_ALLOWED = 405,
    NOT_ACCEPTABLE = 406,
    PROXY_AUTHENTICATION_REQUIRED = 407,
    REQUEST_TIMEOUT = 408,
    CONFLICT = 409,
    GONE = 410,
    LENGTH_REQUIRED = 411,
    PRECONDITION_FAILED = 412,
    REQUEST_ENTITY_TOO_LARGE = 413,
    REQUEST_URI_TOO_LONG = 414,
    UNSUPPORTED_MEDIA_TYPE = 415,
    RANGE_NOT_SATISFIABLE = 416,
    EXPECTATION_FAILED = 417,
    IM_A_TEAPOT = 418,
    MISDIRECTED_REQUEST = 421,
    UNPROCESSABLE_ENTITY = 422,
    LOCKED = 423,
    FAILED_DEPENDENCY = 424,
    UPGRADE_REQUIRED = 426,
    PRECONDITION_REQUIRED = 428,
    TOO_MANY_REQUESTS = 429,

    // 5xx Server Errors
    INTERNAL_SERVER_ERROR = 500,
    NOT_IMPLEMENTED = 501,
    BAD_GATEWAY = 502,
    SERVICE_UNAVAILABLE = 503,
    GATEWAY_TIMEOUT = 504,
    HTTP_VERSION_NOT_SUPPORTED = 505,
    VARIANT_ALSO_NEGOTIATES = 506,
    INSUFFICIENT_STORAGE = 507,
    LOOP_DETECTED = 508,
    NOT_EXTENDED = 510,
    NETWORK_AUTHENTICATION_REQUIRED = 511,
};

pub const HTTP_VERSION = "HTTP/1.1";

/// HTTP response class
pub const HTTPResponse = struct {
    _version: []const u8,
    _status: i32,
    _reason: []const u8,
    _headers: std.StringHashMap([]const u8),
    _body: []u8,
    _closed: bool,

    pub fn init(allocator: Allocator) !*HTTPResponse {
        const self = try allocator.create(HTTPResponse);
        self.* = .{
            ._version = HTTP_VERSION,
            ._status = 200,
            ._reason = "OK",
            ._headers = std.StringHashMap([]const u8).init(allocator),
            ._body = &.{},
            ._closed = false,
        };
        return self;
    }

    pub fn getStatus(self: *const HTTPResponse) i32 {
        return self._status;
    }

    pub fn getReason(self: *const HTTPResponse) []const u8 {
        return self._reason;
    }

    pub fn read(self: *HTTPResponse, allocator: Allocator, size: ?usize) ![]u8 {
        if (self._closed) return error.BadStatusLine;
        if (size) |n| {
            return self._body[0..@min(n, self._body.len)];
        }
        return self._body;
    }

    pub fn getheader(self: *const HTTPResponse, name: []const u8) ?[]const u8 {
        return self._headers.get(name);
    }

    pub fn getheaders(self: *const HTTPResponse) []const u8 {
        _ = self;
        return "";
    }

    pub fn close(self: *HTTPResponse) void {
        self._closed = true;
    }
};

/// HTTP request class
pub const HTTPRequest = struct {
    _method: []const u8,
    _url: []const u8,
    _headers: std.StringHashMap([]const u8),
    _host: []const u8,
    _port: u16,
    _selector: []const u8,

    pub fn init(allocator: Allocator, method: []const u8, url: []const u8, host: []const u8, port: u16) !*HTTPRequest {
        const self = try allocator.create(HTTPRequest);
        self.* = .{
            ._method = method,
            ._url = url,
            ._headers = std.StringHashMap([]const u8).init(allocator),
            ._host = host,
            ._port = port,
            ._selector = url,
        };
        return self;
    }
};

/// HTTPConnection base class
pub const HTTPConnection = struct {
    _host: []const u8,
    _port: u16,
    _timeout: ?u32,
    _source_address: ?[]const u8,
    _blocksize: u32,
    _response: ?*HTTPResponse,
    _connection: ?object.ObjectPtr, // socket
    _closed: bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator, host: []const u8, port: ?u16, timeout: ?u32) !*HTTPConnection {
        const self = try allocator.create(HTTPConnection);
        self.* = .{
            ._host = host,
            ._port = port orelse 80,
            ._timeout = timeout,
            ._source_address = null,
            ._blocksize = 8192,
            ._response = null,
            ._connection = null,
            ._closed = false,
            .allocator = allocator,
        };
        return self;
    }

    pub fn request(self: *HTTPConnection, method: []const u8, selector: []const u8, body: ?[]const u8, headers: ?object.ObjectPtr) !*HTTPResponse {
        std.debug.print("[http.client] {s} {s} -> {s}:{d}\n", .{
            method, selector, self._host, self._port
        });
        
        const response = try HTTPResponse.init(self.allocator);
        response._status = 200;
        response._reason = "OK";
        
        self._response = response;
        return response;
    }

    pub fn getresponse(self: *HTTPConnection) !*HTTPResponse {
        return self._response orelse error.ResponseNotReady;
    }

    pub fn close(self: *HTTPConnection) void {
        self._closed = true;
        if (self._connection) |conn| {
            _ = conn;
        }
    }

    pub fn connect(self: *HTTPConnection) !void {
        std.debug.print("[http.client] Connecting to {s}:{d}\n", .{self._host, self._port});
        // In real implementation, would create socket connection
    }
};

/// HTTPSConnection
pub const HTTPSConnection = struct {
    parent: HTTPConnection,
    _key_file: ?[]const u8,
    _cert_file: ?[]const u8,
    _context: ?object.ObjectPtr,

    pub fn init(allocator: Allocator, host: []const u8, port: ?u16, timeout: ?u32) !*HTTPSConnection {
        const self = try allocator.create(HTTPSConnection);
        self.* = .{
            .parent = (try HTTPConnection.init(allocator, host, port, timeout)).*,
            ._key_file = null,
            ._cert_file = null,
            ._context = null,
        };
        return self;
    }
};

/// HTTPConnectionPool (for connection reuse)
pub const HTTPConnectionPool = struct {
    _host: []const u8,
    _port: u16,
    _scheme: []const u8,

    pub fn init(allocator: Allocator, host: []const u8, port: ?u16, scheme: []const u8) !*HTTPConnectionPool {
        const self = try allocator.create(HTTPConnectionPool);
        self.* = .{
            ._host = host,
            ._port = port orelse 80,
            ._scheme = scheme,
        };
        return self;
    }

    pub fn urlopen(self: *HTTPConnectionPool, method: []const u8, url: []const u8) !*HTTPResponse {
        _ = self;
        _ = method;
        _ = url;
        return error.NotImplemented;
    }
};

// === BadStatusLine exception ===
pub const BadStatusLine = struct {
    line: []const u8,

    pub fn init(line: []const u8) BadStatusLine {
        return .{ .line = line };
    }
};

// === HTTP client module ===

pub const HTTPClientModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        // Connection classes
        try dict.put("HTTPConnection", try createClass(allocator, "HTTPConnection"));
        try dict.put("HTTPSConnection", try createClass(allocator, "HTTPSConnection"));
        try dict.put("HTTPConnectionPool", try createClass(allocator, "HTTPConnectionPool"));
        try dict.put("HTTPResponse", try createClass(allocator, "HTTPResponse"));
        try dict.put("HTTPRequest", try createClass(allocator, "HTTPRequest"));

        // Exceptions
        try dict.put("HTTPException", try createClass(allocator, "HTTPException"));
        try dict.put("BadStatusLine", try createClass(allocator, "BadStatusLine"));
        try dict.put("RemoteDisconnected", try createClass(allocator, "RemoteDisconnected"));
        try dict.put("NotConnected", try createClass(allocator, "NotConnected"));
        try dict.put("InvalidURL", try createClass(allocator, "InvalidURL"));
        try dict.put("CannotSendRequest", try createClass(allocator, "CannotSendRequest"));
        try dict.put("CannotSendHeader", try createClass(allocator, "CannotSendHeader"));
        try dict.put("ResponseNotReady", try createClass(allocator, "ResponseNotReady"));
        try dict.put("LineTooLong", try createClass(allocator, "LineTooLong"));
        try dict.put("ImproperConnectionState", try createClass(allocator, "ImproperConnectionState"));

        // Constants
        try dict.put("HTTP_PORT", try object.PyObject.newInt(allocator, 80));
        try dict.put("HTTPS_PORT", try object.PyObject.newInt(allocator, 443));
        try dict.put("CONTINUE", try object.PyObject.newInt(allocator, 100));
        try dict.put("OK", try object.PyObject.newInt(allocator, 200));
        try dict.put("CREATED", try object.PyObject.newInt(allocator, 201));
        try dict.put("ACCEPTED", try object.PyObject.newInt(allocator, 202));
        try dict.put("MOVED_PERMANENTLY", try object.PyObject.newInt(allocator, 301));
        try dict.put("FOUND", try object.PyObject.newInt(allocator, 302));
        try dict.put("NOT_MODIFIED", try object.PyObject.newInt(allocator, 304));
        try dict.put("BAD_REQUEST", try object.PyObject.newInt(allocator, 400));
        try dict.put("UNAUTHORIZED", try object.PyObject.newInt(allocator, 401));
        try dict.put("FORBIDDEN", try object.PyObject.newInt(allocator, 403));
        try dict.put("NOT_FOUND", try object.PyObject.newInt(allocator, 404));
        try dict.put("INTERNAL_SERVER_ERROR", try object.PyObject.newInt(allocator, 500));
        try dict.put("NOT_IMPLEMENTED", try object.PyObject.newInt(allocator, 501));
        try dict.put("BAD_GATEWAY", try object.PyObject.newInt(allocator, 502));
        try dict.put("SERVICE_UNAVAILABLE", try object.PyObject.newInt(allocator, 503));

        const module_val = object.ModuleValue{
            .name = "http.client",
            .dict = dict,
            .file = "http.client (Zig)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn createClass(allocator: Allocator, name: []const u8) !object.ObjectPtr {
        var class_dict = std.StringHashMap(object.ObjectPtr).init(allocator);
        
        // Add common methods for connection classes
        if (std.mem.eql(u8, name, "HTTPConnection") or std.mem.eql(u8, name, "HTTPSConnection")) {
            try class_dict.put("request", try createBuiltin(allocator, "request", connRequest));
            try class_dict.put("getresponse", try createBuiltin(allocator, "getresponse", connGetResponse));
            try class_dict.put("close", try createBuiltin(allocator, "close", connClose));
            try class_dict.put("connect", try createBuiltin(allocator, "connect", connConnect));
            try class_dict.put("set_tunnel", try createBuiltin(allocator, "set_tunnel", connSetTunnel));
            try class_dict.put("putrequest", try createBuiltin(allocator, "putrequest", connPutRequest));
            try class_dict.put("putheader", try createBuiltin(allocator, "putheader", connPutHeader));
            try class_dict.put("endheaders", try createBuiltin(allocator, "endheaders", connEndHeaders));
            try class_dict.put("send", try createBuiltin(allocator, "send", connSend));
        }
        
        // Add common methods for response
        if (std.mem.eql(u8, name, "HTTPResponse")) {
            try class_dict.put("read", try createBuiltin(allocator, "read", responseRead));
            try class_dict.put("getheader", try createBuiltin(allocator, "getheader", responseGetHeader));
            try class_dict.put("getheaders", try createBuiltin(allocator, "getheaders", responseGetHeaders));
            try class_dict.put("close", try createBuiltin(allocator, "close", responseClose));
            try class_dict.put("readable", try createBuiltin(allocator, "readable", responseReadable));
        }

        const class_val = object.ModuleValue{ .name = name, .dict = class_dict, .file = null };
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = class_val });
    }

    fn createBuiltin(allocator: Allocator, name: []const u8, func: object.BuiltinFn) !object.ObjectPtr {
        _ = name;
        return try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = func });
    }

    // Connection methods
    fn connRequest(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        std.debug.print("[http.client] HTTPConnection.request()\n", .{});
        return try object.PyObject.newNone(allocator);
    }

    fn connGetResponse(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try createClass(allocator, "HTTPResponse");
    }

    fn connClose(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn connConnect(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        std.debug.print("[http.client] Connecting...\n", .{});
        return try object.PyObject.newNone(allocator);
    }

    fn connSetTunnel(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn connPutRequest(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn connPutHeader(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn connEndHeaders(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn connSend(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    // Response methods
    fn responseRead(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newBytes(allocator, &[_]u8{});
    }

    fn responseGetHeader(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn responseGetHeaders(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn responseClose(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn responseReadable(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newBool(allocator, true);
    }
};
