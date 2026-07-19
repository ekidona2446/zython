//! io module — аналог Lib/io.py и Modules/_iomodule.c
//! Реализует TextIOWrapper, BytesIO, StringIO, BufferedReader
//! Основа для open() и file I/O

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");
const object = @import("../object/object.zig");
const Allocator = std.mem.Allocator;

/// File mode flags
pub const FileMode = enum {
    read,
    write,
    append,
    read_write,
    write_read,
    append_read,
};

/// File buffering mode
pub const Buffering = enum(u8) {
    unbuffered = 0,
    line_buffered = 1,
    buffered = -1,
};

/// Text encoding
pub const Encoding = enum(u8) {
    utf8,
    ascii,
    latin1,
    utf16,
    utf32,
};

/// IOBase — базовый класс для всех I/O типов
pub const IOBase = struct {
    name: []const u8,
    mode: FileMode,
    closed: bool,

    pub fn init(name: []const u8, mode: FileMode) IOBase {
        return .{
            .name = name,
            .mode = mode,
            .closed = false,
        };
    }

    pub fn close(self: *IOBase) void {
        self.closed = true;
    }

    pub fn closed(self: *const IOBase) bool {
        return self.closed;
    }
};

/// BytesIO — in-memory binary file
pub const BytesIO = struct {
    base: IOBase,
    data: std.ArrayList(u8),
    position: usize,

    pub fn init(allocator: Allocator) !*BytesIO {
        const self = try allocator.create(BytesIO);
        self.* = .{
            .base = IOBase.init("<BytesIO>", .write),
            .data = std.ArrayList(u8).init(allocator),
            .position = 0,
        };
        return self;
    }

    pub fn deinit(self: *BytesIO) void {
        self.data.deinit(self.base.mode.allocator);
    }

    pub fn write(self: *BytesIO, bytes: []const u8) !usize {
        if (self.base.closed) return error.ValueError;
        
        // Insert at position
        const remaining = self.data.items.len - self.position;
        if (remaining < bytes.len) {
            // Need to grow
            try self.data.resize(self.position + bytes.len);
            @memcpy(self.data.items[self.position..], bytes);
        } else {
            @memcpy(self.data.items[self.position..self.position + bytes.len], bytes);
        }
        self.position += bytes.len;
        return bytes.len;
    }

    pub fn read(self: *BytesIO, size: ?usize) ![]u8 {
        if (self.base.closed) return error.ValueError;
        
        const read_size = size orelse self.data.items.len;
        const end_pos = @min(self.position + read_size, self.data.items.len);
        const result = self.data.items[self.position..end_pos];
        self.position = end_pos;
        return result;
    }

    pub fn seek(self: *BytesIO, offset: i64, whence: i32) !usize {
        var new_pos: i64 = 0;
        switch (whence) {
            0 => new_pos = offset, // SEEK_SET
            1 => new_pos = @as(i64, @intCast(self.position)) + offset, // SEEK_CUR
            2 => new_pos = @as(i64, @intCast(self.data.items.len)) + offset, // SEEK_END
            else => return error.InvalidWhence,
        }
        
        if (new_pos < 0) return error.SeekBeforeStart;
        self.position = @intCast(new_pos);
        return self.position;
    }

    pub fn tell(self: *const BytesIO) usize {
        return self.position;
    }

    pub fn getvalue(self: *const BytesIO) []const u8 {
        return self.data.items;
    }

    pub fn truncate(self: *BytesIO, size: ?usize) !usize {
        const new_size = size orelse self.position;
        try self.data.resize(new_size);
        if (self.position > new_size) {
            self.position = new_size;
        }
        return new_size;
    }

    pub fn readable(self: *const BytesIO) bool {
        return true;
    }

    pub fn writable(self: *BytesIO) bool {
        return true;
    }

    pub fn seekable(self: *const BytesIO) bool {
        return true;
    }
};

/// StringIO — in-memory text file
pub const StringIO = struct {
    base: IOBase,
    buffer: std.ArrayList(u8),
    position: usize,
    encoding: Encoding,
    newline: []const u8,

    pub fn init(allocator: Allocator, encoding: Encoding) !*StringIO {
        const self = try allocator.create(StringIO);
        self.* = .{
            .base = IOBase.init("<StringIO>", .write),
            .buffer = std.ArrayList(u8).init(allocator),
            .position = 0,
            .encoding = encoding,
            .newline = "\n",
        };
        return self;
    }

    pub fn deinit(self: *StringIO) void {
        self.buffer.deinit(self.base.mode.allocator);
    }

    pub fn write(self: *StringIO, text: []const u8) !usize {
        if (self.base.closed) return error.ValueError;
        try self.buffer.appendSlice(text);
        self.position += text.len;
        return text.len;
    }

    pub fn read(self: *StringIO, size: ?usize) ![]u8 {
        if (self.base.closed) return error.ValueError;
        const read_size = size orelse self.buffer.items.len;
        const end_pos = @min(self.position + read_size, self.buffer.items.len);
        const result = self.buffer.items[self.position..end_pos];
        self.position = end_pos;
        return result;
    }

    pub fn getvalue(self: *const StringIO) []const u8 {
        return self.buffer.items;
    }

    pub fn seek(self: *StringIO, offset: i64, whence: i32) !usize {
        var new_pos: i64 = 0;
        switch (whence) {
            0 => new_pos = offset,
            1 => new_pos = @as(i64, @intCast(self.position)) + offset,
            2 => new_pos = @as(i64, @intCast(self.buffer.items.len)) + offset,
            else => return error.InvalidWhence,
        }
        if (new_pos < 0) return error.SeekBeforeStart;
        self.position = @intCast(new_pos);
        return self.position;
    }

    pub fn tell(self: *const StringIO) usize {
        return self.position;
    }
};

/// FileIO — low-level file operations
pub const FileIO = struct {
    base: IOBase,
    path: []const u8,
    fd: ?std.posix.fd_t,
    encoding: Encoding,
    errors: []const u8,

    pub fn init(allocator: Allocator, path: []const u8, mode: []const u8) !*FileIO {
        const self = try allocator.create(FileIO);
        self.* = .{
            .base = IOBase.init(path, parseMode(mode)),
            .path = try allocator.dupe(u8, path),
            .fd = null,
            .encoding = .utf8,
            .errors = "strict",
        };
        return self;
    }

    pub fn deinit(self: *FileIO) void {
        if (self.fd) |fd| {
            std.posix.close(fd);
        }
        self.allocator.free(self.path);
    }

    fn parseMode(mode: []const u8) FileMode {
        if (std.mem.indexOf(u8, mode, "r") != null) {
            if (std.mem.indexOf(u8, mode, "w") != null) return .read_write;
            return .read;
        }
        if (std.mem.indexOf(u8, mode, "w") != null) {
            if (std.mem.indexOf(u8, mode, "r") != null) return .write_read;
            return .write;
        }
        if (std.mem.indexOf(u8, mode, "a") != null) {
            if (std.mem.indexOf(u8, mode, "r") != null) return .append_read;
            return .append;
        }
        return .read;
    }

    pub fn open(self: *FileIO) !void {
        const flags: u32 = switch (self.base.mode) {
            .read => std.posix.O.RDONLY,
            .write => std.posix.O.WRONLY | std.posix.O.CREAT | std.posix.O.TRUNC,
            .append => std.posix.O.WRONLY | std.posix.O.CREAT | std.posix.O.APPEND,
            .read_write => std.posix.O.RDWR | std.posix.O.CREAT,
            .write_read => std.posix.O.RDWR | std.posix.O.CREAT | std.posix.O.TRUNC,
            .append_read => std.posix.O.RDWR | std.posix.O.CREAT | std.posix.O.APPEND,
        };
        self.fd = try std.posix.open(self.path, flags, 0o666);
    }

    pub fn read(self: *FileIO, buf: []u8) !usize {
        if (self.fd) |fd| {
            return try std.posix.read(fd, buf);
        }
        return error.FileNotOpen;
    }

    pub fn write(self: *FileIO, buf: []const u8) !usize {
        if (self.fd) |fd| {
            return try std.posix.write(fd, buf);
        }
        return error.FileNotOpen;
    }

    pub fn seek(self: *FileIO, offset: i64, whence: i32) !usize {
        if (self.fd) |fd| {
            return @intCast(try std.posix.lseek(fd, offset, @enumFromInt(whence)));
        }
        return error.FileNotOpen;
    }

    pub fn tell(self: *FileIO) !usize {
        if (self.fd) |fd| {
            return @intCast(try std.posix.lseek(fd, 0, .cur));
        }
        return error.FileNotOpen;
    }

    pub fn close(self: *FileIO) !void {
        if (self.fd) |fd| {
            std.posix.close(fd);
            self.fd = null;
        }
        self.base.closed = true;
    }
};

/// TextIOWrapper — high-level text I/O
pub const TextIOWrapper = struct {
    base: IOBase,
    buffer: *FileIO,
    encoding: Encoding,
    errors: []const u8,
    line_buffering: bool,
    write_through: bool,
    position: usize,

    pub fn init(allocator: Allocator, buffer: *FileIO, encoding: Encoding, errors: []const u8) !*TextIOWrapper {
        const self = try allocator.create(TextIOWrapper);
        self.* = .{
            .base = IOBase.init(buffer.base.name, buffer.base.mode),
            .buffer = buffer,
            .encoding = encoding,
            .errors = try allocator.dupe(u8, errors),
            .line_buffering = false,
            .write_through = false,
            .position = 0,
        };
        return self;
    }

    pub fn deinit(self: *TextIOWrapper) void {
        self.allocator.free(self.errors);
    }

    pub fn read(self: *TextIOWrapper, size: ?usize) ![]u8 {
        if (self.base.closed) return error.ValueError;
        return try self.buffer.read(&[_]u8{});
    }

    pub fn write(self: *TextIOWrapper, text: []const u8) !usize {
        if (self.base.closed) return error.ValueError;
        return try self.buffer.write(text);
    }

    pub fn flush(self: *TextIOWrapper) !void {
        // Flush buffer - no-op for now
        _ = self;
    }

    pub fn seek(self: *TextIOWrapper, offset: i64, whence: i32) !usize {
        return try self.buffer.seek(offset, whence);
    }

    pub fn tell(self: *TextIOWrapper) !usize {
        return try self.buffer.tell();
    }

    pub fn close(self: *TextIOWrapper) !void {
        try self.buffer.close();
        self.base.closed = true;
    }

    pub fn readable(self: *const TextIOWrapper) bool {
        return self.buffer.base.mode == .read or self.buffer.base.mode == .read_write;
    }

    pub fn writable(self: *TextIOWrapper) bool {
        return self.buffer.base.mode == .write or 
               self.buffer.base.mode == .read_write or
               self.buffer.base.mode == .append;
    }
};

/// BufferedReader — buffered reading
pub const BufferedReader = struct {
    base: IOBase,
    raw: *FileIO,
    buffer: []u8,
    position: usize,
    buffer_start: usize,
    buffer_end: usize,

    pub fn init(allocator: Allocator, raw: *FileIO) !*BufferedReader {
        const self = try allocator.create(BufferedReader);
        self.* = .{
            .base = IOBase.init(raw.base.name, .read),
            .raw = raw,
            .buffer = try allocator.alloc(u8, 8192),
            .position = 0,
            .buffer_start = 0,
            .buffer_end = 0,
        };
        return self;
    }

    pub fn deinit(self: *BufferedReader) void {
        self.allocator.free(self.buffer);
    }

    pub fn fill(self: *BufferedReader) !void {
        const n = try self.raw.read(self.buffer);
        self.buffer_start = 0;
        self.buffer_end = n;
    }

    pub fn read(self: *BufferedReader, size: ?usize) ![]u8 {
        if (self.base.closed) return error.ValueError;
        // Simplified - just read from raw
        _ = size;
        return try self.raw.read(&[_]u8{});
    }

    pub fn close(self: *BufferedReader) !void {
        try self.raw.close();
        self.base.closed = true;
    }
};

/// IO Module initialization
pub const IOModule = struct {
    pub fn init(allocator: Allocator) !object.ObjectPtr {
        var dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        // Classes
        try dict.put("IOBase", try createClass(allocator, "IOBase"));
        try dict.put("RawIOBase", try createClass(allocator, "RawIOBase"));
        try dict.put("TextIOBase", try createClass(allocator, "TextIOBase"));
        try dict.put("TextIOWrapper", try createClass(allocator, "TextIOWrapper"));
        try dict.put("FileIO", try createClass(allocator, "FileIO"));
        try dict.put("BytesIO", try createClass(allocator, "BytesIO"));
        try dict.put("StringIO", try createClass(allocator, "StringIO"));
        try dict.put("BufferedReader", try createClass(allocator, "BufferedReader"));
        try dict.put("BufferedWriter", try createClass(allocator, "BufferedWriter"));
        try dict.put("BufferedRandom", try createClass(allocator, "BufferedRandom"));
        try dict.put("IncrementalNewlineDecoder", try createClass(allocator, "IncrementalNewlineDecoder"));

        // Constants
        try dict.put("DEFAULT_BUFFER_SIZE", try object.PyObject.newInt(allocator, 8192));
        try dict.put("BlockingIOError", try createClass(allocator, "BlockingIOError"));
        try dict.put("UnsupportedOperation", try createClass(allocator, "UnsupportedOperation"));

        const module_val = object.ModuleValue{
            .name = "io",
            .dict = dict,
            .file = "io (Zig implementation)",
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = module_val });
    }

    fn createClass(allocator: Allocator, name: []const u8) !object.ObjectPtr {
        var class_dict = std.StringHashMap(object.ObjectPtr).init(allocator);

        // Add basic methods
        const close_fn = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = genericClose });
        try class_dict.put("close", close_fn);

        const read_fn = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = genericRead });
        try class_dict.put("read", read_fn);

        const write_fn = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = genericWrite });
        try class_dict.put("write", write_fn);

        const seek_fn = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = genericSeek });
        try class_dict.put("seek", seek_fn);

        const tell_fn = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = genericTell });
        try class_dict.put("tell", tell_fn);

        const flush_fn = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = genericFlush });
        try class_dict.put("flush", flush_fn);

        const readable_fn = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = genericReadable });
        try class_dict.put("readable", readable_fn);

        const writable_fn = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = genericWritable });
        try class_dict.put("writable", writable_fn);

        const seekable_fn = try object.PyObject.create(allocator, &object.FunctionType, .{ .BuiltinFunction = genericSeekable });
        try class_dict.put("seekable", seekable_fn);

        const class_val = object.ModuleValue{
            .name = name,
            .dict = class_dict,
            .file = null,
        };

        return try object.PyObject.create(allocator, &object.ModuleType, .{ .Module = class_val });
    }

    fn genericClose(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn genericRead(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newStr(allocator, "");
    }

    fn genericWrite(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newInt(allocator, 0);
    }

    fn genericSeek(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newInt(allocator, 0);
    }

    fn genericTell(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newInt(allocator, 0);
    }

    fn genericFlush(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newNone(allocator);
    }

    fn genericReadable(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newBool(allocator, true);
    }

    fn genericWritable(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newBool(allocator, false);
    }

    fn genericSeekable(args: []*object.PyObject, allocator: Allocator) anyerror!object.ObjectPtr {
        _ = args;
        return try object.PyObject.newBool(allocator, true);
    }
};
