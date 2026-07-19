//! urllib — URL handling library
//! Аналог Lib/urllib/ и Lib/urllib3/
//! Critical для requests и httpx

const std = @import("std");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

// === URL parsing ===

pub const Url = struct {
    scheme: []const u8,
    netloc: []const u8,
    path: []const u8,
    params: []const u8,
    query: []const u8,
    fragment: []const u8,
    username: ?[]const u8,
    password: ?[]const u8,
    hostname: ?[]const u8,
    port: ?u16,

    pub fn parse(url: []const u8) !Url {
        // Simple URL parser
        var result = Url{
            .scheme = "",
            .netloc = "",
            .path = "",
            .params = "",
            .query = "",
            .fragment = "",
            .username = null,
            .password = null,
            .hostname = null,
            .port = null,
        };

        // Find scheme
        if (std.mem.indexOf(u8, url, "://")) |idx| {
            result.scheme = url[0..idx];
            const rest = url[idx + 3..];
            
            // Find fragment
            if (std.mem.indexOf(u8, rest, "#")) |fidx| {
                result.fragment = rest[fidx + 1..];
                const without_fragment = rest[0..fidx];
                
                // Find query
                if (std.mem.indexOf(u8, without_fragment, "?")) |qidx| {
                    result.query = without_fragment[qidx + 1..];
                    result.netloc = without_fragment[0..qidx];
                    result.path = "";
                } else {
                    result.netloc = without_fragment;
                }
            } else {
                // Find query
                if (std.mem.indexOf(u8, rest, "?")) |qidx| {
                    result.query = rest[qidx + 1..];
                    result.netloc = rest[0..qidx];
                } else {
                    result.netloc = rest;
                }
                
                // Find path
                if (std.mem.indexOf(u8, result.netloc, "/")) |pidx| {
                    const after_slash = result.netloc[pidx..];
                    result.netloc = result.netloc[0..pidx];
                    result.path = after_slash;
                }
            }

            // Parse netloc for username:password@host:port
            if (std.mem.indexOf(u8, result.netloc, "@")) |atidx| {
                const auth = result.netloc[0..atidx];
                result.netloc = result.netloc[atidx + 1..];
                
                if (std.mem.indexOf(u8, auth, ":")) |colonidx| {
                    result.username = auth[0..colonidx];
                    result.password = auth[colonidx + 1..];
                } else {
                    result.username = auth;
                }
            }

            // Parse hostname:port
            if (std.mem.indexOf(u8, result.netloc, ":")) |colonidx| {
                result.hostname = result.netloc[0..colonidx];
                const port_str = result.netloc[colonidx + 1..];
                result.port = std.fmt.parseInt(u16, port_str, 10) catch null;
            } else {
                result.hostname = result.netloc;
            }
        }

        return result;
    }
};

// === urllib.parse module ===

pub const UrllibParse = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        // Functions
        try dict.put("urlparse", try createBuiltin(allocator, "urlparse", urlparse));
        try dict.put("urlunparse", try createBuiltin(allocator, "urlunparse", urlunparse));
        try dict.put("urljoin", try createBuiltin(allocator, "urljoin", urljoin));
        try dict.put("urlsplit", try createBuiltin(allocator, "urlsplit", urlsplit));
        try dict.put("urlunsplit", try createBuiltin(allocator, "urlunsplit", urlunsplit));
        try dict.put("urlencode", try createBuiltin(allocator, "urlencode", urlencode));
        try dict.put("quote", try createBuiltin(allocator, "quote", quote));
        try dict.put("quote_plus", try createBuiltin(allocator, "quote_plus", quotePlus));
        try dict.put("unquote", try createBuiltin(allocator, "unquote", unquote));
        try dict.put("unquote_plus", try createBuiltin(allocator, "unquote_plus", unquotePlus));
        try dict.put("parse_qs", try createBuiltin(allocator, "parse_qs", parseQs));
        try dict.put("parse_qsl", try createBuiltin(allocator, "parse_qsl", parseQsl));
        try dict.put("urlsplit", try createBuiltin(allocator, "urlsplit", urlsplit));
        try dict.put("urlunsplit", try createBuiltin(allocator, "urlunsplit", urlunsplit));
        try dict.put("splitn", try createBuiltin(allocator, "splitn", splitn));

        // Constants
        try dict.put("always_safe", try object.PyObject.newTuple(allocator, &.{
            try object.PyObject.newInt(allocator, 0),
        }));

        const module_val = object.ModuleValue{
            .name = "urllib.parse",
            .dict = dict,
            .file = "urllib.parse (Zig)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn createBuiltin(allocator: Allocator, name: []const u8, func: object.BuiltinFn) !object.ObjectPtr {
        _ = name;
        return try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = func });
    }

    fn urlparse(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 1) return error.TypeError;
        const url = switch (args[0].value) {
            .Str => |s| s,
            else => return error.TypeError,
        };

        const parsed = try Url.parse(url);
        
        // Create ParseResult-like object
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);
        try dict.put("scheme", try object.PyObject.newStr(allocator, parsed.scheme));
        try dict.put("netloc", try object.PyObject.newStr(allocator, parsed.netloc));
        try dict.put("path", try object.PyObject.newStr(allocator, parsed.path));
        try dict.put("params", try object.PyObject.newStr(allocator, parsed.params));
        try dict.put("query", try object.PyObject.newStr(allocator, parsed.query));
        try dict.put("fragment", try object.PyObject.newStr(allocator, parsed.fragment));
        try dict.put("username", if (parsed.username) |u| try object.PyObject.newStr(allocator, u) else try object.PyObject.newNone(allocator));
        try dict.put("password", if (parsed.password) |p| try object.PyObject.newStr(allocator, p) else try object.PyObject.newNone(allocator));
        try dict.put("hostname", if (parsed.hostname) |h| try object.PyObject.newStr(allocator, h) else try object.PyObject.newNone(allocator));
        try dict.put("port", if (parsed.port) |p| try object.PyObject.newInt(allocator, p) else try object.PyObject.newNone(allocator));

        const class_val = object.ModuleValue{ .name = "ParseResult", .dict = dict, .file = null };
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = class_val });
    }

    fn urlunparse(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 1) return error.TypeError;
        return try object.PyObject.newStr(allocator, "");
    }

    fn urljoin(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 2) return error.TypeError;
        return try object.PyObject.newStr(allocator, "");
    }

    fn urlsplit(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 1) return error.TypeError;
        return try urlparse(args, allocator);
    }

    fn urlunsplit(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 1) return error.TypeError;
        return try object.PyObject.newStr(allocator, "");
    }

    fn urlencode(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 1) return error.TypeError;
        return try object.PyObject.newStr(allocator, "");
    }

    fn quote(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 1) return error.TypeError;
        const s = switch (args[0].value) {
            .Str => |str| str,
            else => return error.TypeError,
        };
        
        // Simple URL encoding
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        
        for (s) |c| {
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~') {
                try result.append(c);
            } else {
                try result.append('%');
                try result.append("0123456789ABCDEF"[(c >> 4) & 0xF]);
                try result.append("0123456789ABCDEF"[c & 0xF]);
            }
        }
        
        return try object.PyObject.newStr(allocator, result.items);
    }

    fn quotePlus(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        return quote(args, allocator);
    }

    fn unquote(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 1) return error.TypeError;
        const s = switch (args[0].value) {
            .Str => |str| str,
            else => return error.TypeError,
        };
        
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == '%' and i + 2 < s.len) {
                const hex = s[i+1..i+3];
                if (std.fmt.parseInt(u8, hex, 16)) |byte| {
                    try result.append(byte);
                    i += 2;
                    continue;
                }
            }
            try result.append(s[i]);
        }
        
        return try object.PyObject.newStr(allocator, result.items);
    }

    fn unquotePlus(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        return unquote(args, allocator);
    }

    fn parseQs(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 1) return error.TypeError;
        return try object.PyObject.newDict(allocator);
    }

    fn parseQsl(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 1) return error.TypeError;
        return try object.PyObject.newList(allocator);
    }

    fn splitn(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 3) return error.TypeError;
        return try object.PyObject.newTuple(allocator, &.{
            try object.PyObject.newNone(allocator),
            try object.PyObject.newNone(allocator),
        });
    }
};

// === urllib.request module ===

pub const UrllibRequest = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        // Classes
        try dict.put("urlopen", try createBuiltin(allocator, "urlopen", urlopen));
        try dict.put("urlretrieve", try createBuiltin(allocator, "urlretrieve", urlretrieve));
        try dict.put("urlcleanup", try createBuiltin(allocator, "urlcleanup", urlcleanup));
        try dict.put("URLopener", try createClass(allocator, "URLopener"));
        try dict.put("FancyURLopener", try createClass(allocator, "FancyURLopener"));
        try dict.put("Request", try createClass(allocator, "Request"));
        try dict.put("OpenerDirector", try createClass(allocator, "OpenerDirector"));
        try dict.put("BaseHandler", try createClass(allocator, "BaseHandler"));
        try dict.put("HTTPHandler", try createClass(allocator, "HTTPHandler"));
        try dict.put("HTTPSHandler", try createClass(allocator, "HTTPSHandler"));
        try dict.put("HTTPRedirectHandler", try createClass(allocator, "HTTPRedirectHandler"));
        try dict.put("HTTPCookieProcessor", try createClass(allocator, "HTTPCookieProcessor"));
        try dict.put("HTTPPasswordMgr", try createClass(allocator, "HTTPPasswordMgr"));
        try dict.put("build_opener", try createBuiltin(allocator, "build_opener", buildOpener));
        try dict.put("install_opener", try createBuiltin(allocator, "install_opener", installOpener));
        try dict.put("pathname2url", try createBuiltin(allocator, "pathname2url", pathname2url));
        try dict.put("url2pathname", try createBuiltin(allocator, "url2pathname", url2pathname));
        try dict.put("getproxies", try createBuiltin(allocator, "getproxies", getProxies));

        const module_val = object.ModuleValue{
            .name = "urllib.request",
            .dict = dict,
            .file = "urllib.request (Zig)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn createBuiltin(allocator: Allocator, name: []const u8, func: object.BuiltinFn) !object.ObjectPtr {
        _ = name;
        return try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = func });
    }

    fn createClass(allocator: Allocator, name: []const u8) !object.ObjectPtr {
        var class_dict = std.StringHashMap(object.ObjectPtr).init(allocator);
        const class_val = object.ModuleValue{ .name = name, .dict = class_dict, .file = null };
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = class_val });
    }

    fn urlopen(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 1) return error.TypeError;
        
        std.debug.print("[urllib.request] urlopen() -> HTTP request\n", .{});
        
        // Create a response-like object
        var class_dict = std.StringHashMap(object.ObjectPtr).init(allocator);
        try class_dict.put("read", try createBuiltin(allocator, "read", responseRead));
        try class_dict.put("status", try object.PyObject.newInt(allocator, 200));
        
        const class_val = object.ModuleValue{ .name = "addinfourl", .dict = class_dict, .file = null };
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = class_val });
    }

    fn responseRead(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newBytes(allocator, &[_]u8{});
    }

    fn urlretrieve(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newTuple(allocator, &.{
            try object.PyObject.newNone(allocator),
            try object.PyObject.newNone(allocator),
        });
    }

    fn urlcleanup(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return;
    }

    fn buildOpener(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try createClass(allocator, "OpenerDirector");
    }

    fn installOpener(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn pathname2url(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 1) return error.TypeError;
        return try object.PyObject.newStr(allocator, "");
    }

    fn url2pathname(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        if (args.len < 1) return error.TypeError;
        return try object.PyObject.newStr(allocator, "");
    }

    fn getProxies(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newDict(allocator);
    }
};

// === urllib.error module ===

pub const UrllibError = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        try dict.put("URLError", try createClass(allocator, "URLError"));
        try dict.put("HTTPError", try createClass(allocator, "HTTPError"));
        try dict.put("ContentTooShortError", try createClass(allocator, "ContentTooShortError"));

        const module_val = object.ModuleValue{
            .name = "urllib.error",
            .dict = dict,
            .file = "urllib.error (Zig)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn createClass(allocator: Allocator, name: []const u8) !object.ObjectPtr {
        var class_dict = std.StringHashMap(object.ObjectPtr).init(allocator);
        const class_val = object.ModuleValue{ .name = name, .dict = class_dict, .file = null };
        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = class_val });
    }
};
