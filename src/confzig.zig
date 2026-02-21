//! confzig — typed config from .env files + environment variables.
//!
//! Precedence (last wins): struct defaults < .env files (in order) < env vars
//! Supported types: []const u8, integers, floats, bools, enums, optionals, nested structs

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.confzig);

pub const LoadOptions = struct {
    env_files: []const []const u8 = &.{".env"},
    prefix: []const u8 = "",
    max_file_size: usize = 1024 * 1024,
};

pub const LoadError = error{
    ValidationFailed,
    OutOfMemory,
};

pub fn ParserFn(comptime T: type) type {
    return *const fn ([]const u8, Allocator) anyerror!T;
}

pub fn Result(comptime T: type) type {
    return struct {
        value: T,
        arena: *std.heap.ArenaAllocator,

        pub fn deinit(self: @This()) void {
            const child = self.arena.child_allocator;
            self.arena.deinit();
            child.destroy(self.arena);
        }
    };
}

pub fn load(comptime T: type, allocator: Allocator, options: LoadOptions) LoadError!Result(T) {
    const arena = allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const arena_alloc = arena.allocator();

    const map = buildEnvMap(arena_alloc, options) catch return error.OutOfMemory;
    const value = try loadFromMapWithPrefix(T, map, arena_alloc, options.prefix);

    return .{ .value = value, .arena = arena };
}

pub fn validator(comptime T: type, comptime validateFn: anytype) ParserFn(T) {
    return struct {
        fn parse(raw: []const u8, alloc: Allocator) anyerror!T {
            const val = try parseValue(T, raw, alloc);
            try validateFn(val);
            return val;
        }
    }.parse;
}

fn parseEnvLine(allocator: Allocator, raw_line: []const u8) !?struct { []const u8, []const u8 } {
    const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);

    if (line.len == 0 or line[0] == '#') return null;

    const stripped = if (line.len > 6 and std.mem.eql(u8, line[0..6], "export") and (line[6] == ' ' or line[6] == '\t'))
        std.mem.trimLeft(u8, line[7..], &std.ascii.whitespace)
    else
        line;

    const eq_pos = std.mem.indexOfScalar(u8, stripped, '=') orelse return null;

    const key = std.mem.trim(u8, stripped[0..eq_pos], &std.ascii.whitespace);
    if (key.len == 0) return null;

    const value = try unquoteValue(allocator, stripped[eq_pos + 1 ..]);

    return .{ key, value };
}

fn unquoteValue(allocator: Allocator, raw: []const u8) ![]const u8 {
    const leading_ws = raw.len - std.mem.trimLeft(u8, raw, &std.ascii.whitespace).len;
    const start = raw[leading_ws..];
    if (start.len == 0) return start;

    if (start[0] == '\'') {
        if (std.mem.indexOfScalarPos(u8, start, 1, '\'')) |close| {
            return start[1..close];
        }
    }

    if (start[0] == '"') {
        var i: usize = 1;
        while (i < start.len) : (i += 1) {
            if (start[i] == '\\' and i + 1 < start.len) {
                i += 1;
            } else if (start[i] == '"') {
                const inner = start[1..i];
                var result: std.ArrayListUnmanaged(u8) = .{};
                var j: usize = 0;
                while (j < inner.len) {
                    if (inner[j] == '\\' and j + 1 < inner.len) {
                        switch (inner[j + 1]) {
                            'n' => try result.append(allocator, '\n'),
                            't' => try result.append(allocator, '\t'),
                            'r' => try result.append(allocator, '\r'),
                            '\\' => try result.append(allocator, '\\'),
                            '"' => try result.append(allocator, '"'),
                            else => {
                                try result.append(allocator, '\\');
                                try result.append(allocator, inner[j + 1]);
                            },
                        }
                        j += 2;
                    } else {
                        try result.append(allocator, inner[j]);
                        j += 1;
                    }
                }
                return result.toOwnedSlice(allocator);
            }
        }
    }

    if (start[0] == '#' and leading_ws > 0) return start[0..0];

    const val = std.mem.trimRight(u8, start, &std.ascii.whitespace);
    if (val.len == 0) return val;

    var pos: usize = 1;
    while (pos < val.len) : (pos += 1) {
        if (val[pos] == '#' and (val[pos - 1] == ' ' or val[pos - 1] == '\t')) {
            return std.mem.trimRight(u8, val[0 .. pos - 1], &std.ascii.whitespace);
        }
    }

    return val;
}

fn ParseError(comptime T: type) type {
    const info = @typeInfo(T);
    return switch (info) {
        .int => std.fmt.ParseIntError || error{InvalidCharacter},
        .float => std.fmt.ParseFloatError,
        .bool => error{ InvalidBool, InvalidCharacter },
        .@"enum" => error{InvalidEnumValue},
        .optional => ParseError(info.optional.child),
        // Structs are handled by loadFromMapWithPrefix directly, not parseValue.
        // This arm exists so ParseError(T) doesn't @compileError for struct types
        // when the compiler evaluates generic type signatures.
        .@"struct" => error{},
        else => if (T == []const u8) error{} else @compileError("unsupported type: " ++ @typeName(T)),
    };
}

fn parseValue(comptime T: type, raw: []const u8, allocator: Allocator) (ParseError(T) || Allocator.Error)!T {
    const info = @typeInfo(T);

    if (comptime T == []const u8) {
        return try allocator.dupe(u8, raw);
    }

    switch (info) {
        .int => return try std.fmt.parseInt(T, raw, 10),
        .float => return try std.fmt.parseFloat(T, raw),
        .bool => {
            const lower = blk: {
                var buf: [8]u8 = undefined;
                if (raw.len > buf.len) return error.InvalidBool;
                for (raw, 0..) |c, i| {
                    buf[i] = std.ascii.toLower(c);
                }
                break :blk buf[0..raw.len];
            };
            if (std.mem.eql(u8, lower, "true") or
                std.mem.eql(u8, lower, "1") or
                std.mem.eql(u8, lower, "yes"))
                return true;
            if (std.mem.eql(u8, lower, "false") or
                std.mem.eql(u8, lower, "0") or
                std.mem.eql(u8, lower, "no"))
                return false;
            return error.InvalidBool;
        },
        .@"enum" => {
            return std.meta.stringToEnum(T, raw) orelse return error.InvalidEnumValue;
        },
        .optional => {
            return try parseValue(info.optional.child, raw, allocator);
        },
        else => @compileError("unsupported type for confzig: " ++ @typeName(T)),
    }
}

fn fieldToEnvName(allocator: Allocator, comptime field_name: []const u8, prefix: []const u8, comptime sep: []const u8) Allocator.Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    try buf.appendSlice(allocator, prefix);
    for (field_name) |c| {
        try buf.append(allocator, std.ascii.toUpper(c));
    }
    try buf.appendSlice(allocator, sep);
    return buf.toOwnedSlice(allocator);
}

fn isNestedStruct(comptime T: type) bool {
    if (T == []const u8) return false;
    return @typeInfo(T) == .@"struct";
}

fn isOptionalStruct(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .optional) return false;
    return isNestedStruct(info.optional.child);
}

fn isFieldSkipped(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "confzig_options")) return false;
    const Overrides = @TypeOf(T.confzig_options);
    if (!@hasField(Overrides, field_name)) return false;
    const entry = @field(T.confzig_options, field_name);
    const info = @typeInfo(@TypeOf(entry));
    if (info == .pointer) {
        const str: []const u8 = entry;
        return std.mem.eql(u8, str, "-");
    }
    return false;
}

fn resolveEnvKey(comptime T: type, comptime field_name: []const u8, allocator: Allocator, prefix: []const u8) Allocator.Error!?[]const u8 {
    if (@hasDecl(T, "confzig_options")) {
        const Overrides = @TypeOf(T.confzig_options);
        if (@hasField(Overrides, field_name)) {
            const entry = @field(T.confzig_options, field_name);
            const EntryType = @TypeOf(entry);
            const info = @typeInfo(EntryType);
            if (info == .pointer) {
                const str: []const u8 = entry;
                if (std.mem.eql(u8, str, "-")) return null;
                return str;
            }
            if (info == .@"struct") {
                if (@hasField(EntryType, "key")) {
                    return @as([]const u8, @field(entry, "key"));
                }
            }
        }
    }
    return try fieldToEnvName(allocator, field_name, prefix, "");
}

fn hasFieldParser(comptime T: type, comptime field_name: []const u8) bool {
    if (!@hasDecl(T, "confzig_options")) return false;
    const Overrides = @TypeOf(T.confzig_options);
    if (!@hasField(Overrides, field_name)) return false;
    const EntryType = @TypeOf(@field(T.confzig_options, field_name));
    if (@typeInfo(EntryType) != .@"struct") return false;
    return @hasField(EntryType, "parser");
}

fn hasAnyFieldInMap(comptime T: type, map: std.StringHashMap([]const u8), allocator: Allocator, prefix: []const u8) Allocator.Error!bool {
    inline for (std.meta.fields(T)) |field| {
        if (comptime isFieldSkipped(T, field.name)) {
            continue;
        } else if (comptime isNestedStruct(field.type)) {
            const sub_prefix = try fieldToEnvName(allocator, field.name, prefix, "_");
            if (try hasAnyFieldInMap(field.type, map, allocator, sub_prefix)) return true;
        } else if (comptime isOptionalStruct(field.type)) {
            const Child = @typeInfo(field.type).optional.child;
            const sub_prefix = try fieldToEnvName(allocator, field.name, prefix, "_");
            if (try hasAnyFieldInMap(Child, map, allocator, sub_prefix)) return true;
        } else {
            const maybe_key = try resolveEnvKey(T, field.name, allocator, prefix);
            if (maybe_key) |key| {
                if (map.get(key) != null) return true;
            }
        }
    }
    return false;
}

fn validateConfzigDecl(comptime T: type) void {
    if (!@hasDecl(T, "confzig_options")) return;
    const Overrides = @TypeOf(T.confzig_options);
    for (std.meta.fields(Overrides)) |override_field| {
        if (!@hasField(T, override_field.name)) {
            @compileError("pub const confzig_options: '" ++ override_field.name ++ "' does not match any field in " ++ @typeName(T));
        }
        const EntryType = @TypeOf(@field(T.confzig_options, override_field.name));
        const info = @typeInfo(EntryType);
        if (info != .pointer and info != .@"struct") {
            @compileError("pub const confzig_options: '" ++ override_field.name ++ "' must be a string or .{ .key = ..., .parser = ... }");
        }
        if (info == .@"struct") {
            if (!@hasField(EntryType, "key") and !@hasField(EntryType, "parser")) {
                @compileError("pub const confzig_options: '" ++ override_field.name ++ "' struct must have 'key' and/or 'parser' fields");
            }
            for (std.meta.fields(EntryType)) |f| {
                if (!std.mem.eql(u8, f.name, "key") and !std.mem.eql(u8, f.name, "parser")) {
                    @compileError("pub const confzig_options: '" ++ override_field.name ++ "' has unknown field '" ++ f.name ++ "' (expected 'key' and/or 'parser')");
                }
            }
        }
    }
}

fn buildEnvMap(allocator: Allocator, options: LoadOptions) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    for (options.env_files) |env_file| {
        const contents = std.fs.cwd().readFileAlloc(allocator, env_file, options.max_file_size) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    log.debug("env file not found, skipping: {s}", .{env_file});
                    continue;
                },
                else => {
                    log.warn("failed to read env file '{s}': {}", .{ env_file, err });
                    continue;
                },
            }
        };

        const stripped = if (contents.len >= 3 and contents[0] == 0xEF and contents[1] == 0xBB and contents[2] == 0xBF)
            contents[3..]
        else
            contents;
        var lines = std.mem.splitScalar(u8, stripped, '\n');
        while (lines.next()) |raw_line| {
            const entry = try parseEnvLine(allocator, raw_line) orelse continue;
            const key = try allocator.dupe(u8, entry[0]);
            const value = try allocator.dupe(u8, entry[1]);
            try map.put(key, value);
        }
    }

    var env_map = std.process.getEnvMap(allocator) catch |err| {
        log.warn("failed to read process environment: {}", .{err});
        return map;
    };
    defer env_map.deinit();

    var it = env_map.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const value = try allocator.dupe(u8, entry.value_ptr.*);
        try map.put(key, value);
    }

    return map;
}

fn loadFromMapWithPrefix(comptime T: type, map: std.StringHashMap([]const u8), allocator: Allocator, prefix: []const u8) LoadError!T {
    comptime validateConfzigDecl(T);

    var result: T = undefined;
    var errors: u32 = 0;

    inline for (std.meta.fields(T)) |field| {
        if (comptime isFieldSkipped(T, field.name)) {
            if (field.default_value_ptr) |default_ptr| {
                const typed: *const field.type = @ptrCast(@alignCast(default_ptr));
                @field(result, field.name) = typed.*;
            } else {
                log.warn("skipped field '{s}' has no default value", .{field.name});
                errors += 1;
            }
        } else if (comptime isNestedStruct(field.type)) {
            const nested_prefix = fieldToEnvName(allocator, field.name, prefix, "_") catch return error.OutOfMemory;
            const any_found = hasAnyFieldInMap(field.type, map, allocator, nested_prefix) catch return error.OutOfMemory;
            if (!any_found and field.default_value_ptr != null) {
                const typed: *const field.type = @ptrCast(@alignCast(field.default_value_ptr.?));
                @field(result, field.name) = typed.*;
            } else {
                if (loadFromMapWithPrefix(field.type, map, allocator, nested_prefix)) |nested| {
                    @field(result, field.name) = nested;
                } else |_| {
                    errors += 1;
                }
            }
        } else if (comptime isOptionalStruct(field.type)) {
            const Child = @typeInfo(field.type).optional.child;
            const nested_prefix = fieldToEnvName(allocator, field.name, prefix, "_") catch return error.OutOfMemory;
            const any_found = hasAnyFieldInMap(Child, map, allocator, nested_prefix) catch return error.OutOfMemory;
            if (any_found) {
                if (loadFromMapWithPrefix(Child, map, allocator, nested_prefix)) |nested| {
                    @field(result, field.name) = nested;
                } else |_| {
                    errors += 1;
                }
            } else if (field.default_value_ptr) |default_ptr| {
                const typed: *const field.type = @ptrCast(@alignCast(default_ptr));
                @field(result, field.name) = typed.*;
            } else {
                @field(result, field.name) = null;
            }
        } else {
            const env_name = resolveEnvKey(T, field.name, allocator, prefix) catch return error.OutOfMemory;
            if (env_name) |key| {
                if (map.get(key)) |raw_value| {
                    if (comptime hasFieldParser(T, field.name)) {
                        const parser = @field(T.confzig_options, field.name).parser;
                        if (parser(raw_value, allocator)) |parsed| {
                            @field(result, field.name) = parsed;
                        } else |err| {
                            log.warn("custom parser failed for {s} (env {s}): '{s}' — {}", .{
                                field.name,
                                key,
                                raw_value,
                                err,
                            });
                            errors += 1;
                        }
                    } else {
                        if (parseValue(field.type, raw_value, allocator)) |parsed| {
                            @field(result, field.name) = parsed;
                        } else |err| {
                            log.warn("invalid value for {s} (env {s}): '{s}' — {}", .{
                                field.name,
                                key,
                                raw_value,
                                err,
                            });
                            errors += 1;
                        }
                    }
                } else if (field.default_value_ptr) |default_ptr| {
                    const typed: *const field.type = @ptrCast(@alignCast(default_ptr));
                    @field(result, field.name) = typed.*;
                } else {
                    log.warn("missing required config: {s} (env {s})", .{ field.name, key });
                    errors += 1;
                }
            } else {
                unreachable;
            }
        }
    }

    if (errors > 0) {
        log.warn("{d} configuration error(s)", .{errors});
        return error.ValidationFailed;
    }

    return result;
}

fn TestResult(comptime T: type) type {
    return struct {
        value: T,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

fn testLoadFromMap(comptime T: type, entries: []const struct { []const u8, []const u8 }, prefix: []const u8) LoadError!TestResult(T) {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    const alloc = arena.allocator();
    var map = std.StringHashMap([]const u8).init(alloc);
    for (entries) |e| {
        map.put(e[0], e[1]) catch return error.OutOfMemory;
    }
    const value = try loadFromMapWithPrefix(T, map, alloc, prefix);
    return .{ .value = value, .arena = arena };
}

const IntegrationDir = struct {
    dir: std.fs.Dir,
    old_cwd: std.fs.Dir,
    path: []const u8,

    fn init(alloc: Allocator) !IntegrationDir {
        const path = try std.fmt.allocPrint(alloc, "/tmp/confzig_test_{d}", .{std.Thread.getCurrentId()});
        std.fs.makeDirAbsolute(path) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        const dir = try std.fs.openDirAbsolute(path, .{});
        const old_cwd = std.fs.cwd();
        try dir.setAsCwd();
        return .{ .dir = dir, .old_cwd = old_cwd, .path = path };
    }

    fn writeFile(self: IntegrationDir, name: []const u8, contents: []const u8) !void {
        const f = try self.dir.createFile(name, .{});
        defer f.close();
        try f.writeAll(contents);
    }

    fn deinit(self: *IntegrationDir, alloc: Allocator) void {
        self.old_cwd.setAsCwd() catch {};
        self.dir.close();
        std.fs.deleteTreeAbsolute(self.path) catch {};
        alloc.free(self.path);
    }
};


test "parseEnvLine: basic" {
    const entry = (try parseEnvLine(std.testing.allocator, "FOO=bar")).?;
    try std.testing.expectEqualStrings("FOO", entry[0]);
    try std.testing.expectEqualStrings("bar", entry[1]);
}

test "parseEnvLine: comments and blanks" {
    try std.testing.expect((try parseEnvLine(std.testing.allocator, "# comment")) == null);
    try std.testing.expect((try parseEnvLine(std.testing.allocator, "")) == null);
    try std.testing.expect((try parseEnvLine(std.testing.allocator, "   ")) == null);
}

test "parseEnvLine: whitespace trimming" {
    const entry = (try parseEnvLine(std.testing.allocator, "  KEY  =  value  ")).?;
    try std.testing.expectEqualStrings("KEY", entry[0]);
    try std.testing.expectEqualStrings("value", entry[1]);
}

test "parseEnvLine: double quoted escapes" {
    const entry = (try parseEnvLine(std.testing.allocator, "KEY=\"hello\\nworld\"")).?;
    defer std.testing.allocator.free(entry[1]);
    try std.testing.expectEqualStrings("hello\nworld", entry[1]);
}

test "parseEnvLine: single quoted" {
    const entry = (try parseEnvLine(std.testing.allocator, "KEY='hello\\nworld'")).?;
    try std.testing.expectEqualStrings("hello\\nworld", entry[1]);
}

test "parseEnvLine: inline comment" {
    const entry = (try parseEnvLine(std.testing.allocator, "KEY=value # this is a comment")).?;
    try std.testing.expectEqualStrings("value", entry[1]);
}

test "parseEnvLine: no equals sign" {
    try std.testing.expect((try parseEnvLine(std.testing.allocator, "NOEQUALS")) == null);
}

test "parseEnvLine: export prefix stripped" {
    const entry = (try parseEnvLine(std.testing.allocator, "export FOO=bar")).?;
    try std.testing.expectEqualStrings("FOO", entry[0]);
    try std.testing.expectEqualStrings("bar", entry[1]);
}

test "parseEnvLine: export with extra whitespace" {
    const entry = (try parseEnvLine(std.testing.allocator, "export   KEY=value")).?;
    try std.testing.expectEqualStrings("KEY", entry[0]);
    try std.testing.expectEqualStrings("value", entry[1]);
}

test "parseEnvLine: \\r\\n line endings" {
    const entry = (try parseEnvLine(std.testing.allocator, "KEY=value\r")).?;
    try std.testing.expectEqualStrings("KEY", entry[0]);
    try std.testing.expectEqualStrings("value", entry[1]);
}

test "parseEnvLine: empty value with comment" {
    const entry = (try parseEnvLine(std.testing.allocator, "KEY= # comment")).?;
    try std.testing.expectEqualStrings("", entry[1]);
}

test "parseEnvLine: hash without space" {
    const entry = (try parseEnvLine(std.testing.allocator, "KEY=#not-a-comment")).?;
    try std.testing.expectEqualStrings("#not-a-comment", entry[1]);
}

test "parseEnvLine: multi-word inline comment" {
    const entry = (try parseEnvLine(std.testing.allocator, "KEY=hello world # comment")).?;
    try std.testing.expectEqualStrings("hello world", entry[1]);
}

test "parseEnvLine: export with tab" {
    const entry = (try parseEnvLine(std.testing.allocator, "export\tFOO=bar")).?;
    try std.testing.expectEqualStrings("FOO", entry[0]);
    try std.testing.expectEqualStrings("bar", entry[1]);
}

test "parseEnvLine: empty double quoted" {
    const entry = (try parseEnvLine(std.testing.allocator, "KEY=\"\"")).?;
    defer std.testing.allocator.free(entry[1]);
    try std.testing.expectEqualStrings("", entry[1]);
}

test "parseEnvLine: empty single quoted" {
    const entry = (try parseEnvLine(std.testing.allocator, "KEY=''")).?;
    try std.testing.expectEqualStrings("", entry[1]);
}

test "parseEnvLine: unicode value" {
    const entry = (try parseEnvLine(std.testing.allocator, "KEY=héllo wörld 🌍")).?;
    try std.testing.expectEqualStrings("héllo wörld 🌍", entry[1]);
}

test "parseEnvLine: duplicate keys last wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var map = std.StringHashMap([]const u8).init(alloc);

    const lines = [_][]const u8{ "KEY=first", "KEY=second" };
    for (&lines) |line| {
        const entry = (try parseEnvLine(alloc, line)).?;
        try map.put(entry[0], entry[1]);
    }
    try std.testing.expectEqualStrings("second", map.get("KEY").?);
}


test "unquoteValue: escape sequences" {
    const val = try unquoteValue(std.testing.allocator, "\"tab\\there\"");
    defer std.testing.allocator.free(val);
    try std.testing.expectEqualStrings("tab\there", val);
}

test "unquoteValue: escaped backslash" {
    const val = try unquoteValue(std.testing.allocator, "\"path\\\\to\"");
    defer std.testing.allocator.free(val);
    try std.testing.expectEqualStrings("path\\to", val);
}

test "unquoteValue: escaped quote" {
    const val = try unquoteValue(std.testing.allocator, "\"say\\\"hi\\\"\"");
    defer std.testing.allocator.free(val);
    try std.testing.expectEqualStrings("say\"hi\"", val);
}

test "unquoteValue: double quoted comment" {
    const val = try unquoteValue(std.testing.allocator, "\"hello world\" # comment");
    defer std.testing.allocator.free(val);
    try std.testing.expectEqualStrings("hello world", val);
}

test "unquoteValue: single quoted comment" {
    const val = try unquoteValue(std.testing.allocator, "'hello world' # comment");
    try std.testing.expectEqualStrings("hello world", val);
}


test "parseValue: integers" {
    try std.testing.expectEqual(@as(u16, 8080), try parseValue(u16, "8080", std.testing.allocator));
    try std.testing.expectEqual(@as(i32, -42), try parseValue(i32, "-42", std.testing.allocator));
    try std.testing.expectError(error.InvalidCharacter, parseValue(u16, "notanumber", std.testing.allocator));
}

test "parseValue: bools" {
    try std.testing.expect(try parseValue(bool, "true", std.testing.allocator));
    try std.testing.expect(try parseValue(bool, "1", std.testing.allocator));
    try std.testing.expect(try parseValue(bool, "yes", std.testing.allocator));
    try std.testing.expect(try parseValue(bool, "YES", std.testing.allocator));
    try std.testing.expect(!try parseValue(bool, "false", std.testing.allocator));
    try std.testing.expect(!try parseValue(bool, "0", std.testing.allocator));
    try std.testing.expect(!try parseValue(bool, "no", std.testing.allocator));
    try std.testing.expectError(error.InvalidBool, parseValue(bool, "maybe", std.testing.allocator));
}

test "parseValue: enums" {
    const Level = enum { debug, info, warn, err };
    try std.testing.expectEqual(Level.debug, try parseValue(Level, "debug", std.testing.allocator));
    try std.testing.expectEqual(Level.err, try parseValue(Level, "err", std.testing.allocator));
    try std.testing.expectError(error.InvalidEnumValue, parseValue(Level, "trace", std.testing.allocator));
}

test "parseValue: strings" {
    const result = try parseValue([]const u8, "hello", std.testing.allocator);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "parseValue: floats" {
    try std.testing.expectEqual(@as(f64, 3.14), try parseValue(f64, "3.14", std.testing.allocator));
    try std.testing.expectEqual(@as(f32, -0.5), try parseValue(f32, "-0.5", std.testing.allocator));
    try std.testing.expectError(error.InvalidCharacter, parseValue(f64, "notafloat", std.testing.allocator));
}

test "parseValue: optionals" {
    try std.testing.expectEqual(@as(?u32, 42), try parseValue(?u32, "42", std.testing.allocator));
}


test "fieldToEnvName: basic" {
    const name = try fieldToEnvName(std.testing.allocator, "database_url", "", "");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("DATABASE_URL", name);
}

test "fieldToEnvName: with prefix" {
    const name = try fieldToEnvName(std.testing.allocator, "port", "APP_", "");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("APP_PORT", name);
}


test "load: defaults" {
    const Config = struct {
        host: []const u8 = "0.0.0.0",
        port: u16 = 3000,
        debug: bool = false,
    };
    var r = try testLoadFromMap(Config, &.{}, "");
    defer r.deinit();
    try std.testing.expectEqualStrings("0.0.0.0", r.value.host);
    try std.testing.expectEqual(@as(u16, 3000), r.value.port);
    try std.testing.expect(!r.value.debug);
}

test "load: env overrides defaults" {
    const Config = struct {
        host: []const u8 = "0.0.0.0",
        port: u16 = 3000,
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "HOST", "127.0.0.1" },
        .{ "PORT", "8080" },
    }, "");
    defer r.deinit();
    try std.testing.expectEqualStrings("127.0.0.1", r.value.host);
    try std.testing.expectEqual(@as(u16, 8080), r.value.port);
}

test "load: prefix" {
    const Config = struct {
        port: u16 = 3000,
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "APP_PORT", "9090" },
    }, "APP_");
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 9090), r.value.port);
}

test "load: missing required field" {
    const Config = struct {
        database_url: []const u8,
    };
    try std.testing.expectError(
        error.ValidationFailed,
        testLoadFromMap(Config, &.{}, ""),
    );
}

test "load: optional null" {
    const Config = struct {
        timeout_ms: ?u32 = null,
    };
    var r = try testLoadFromMap(Config, &.{}, "");
    defer r.deinit();
    try std.testing.expect(r.value.timeout_ms == null);
}

test "load: optional set" {
    const Config = struct {
        timeout_ms: ?u32 = null,
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "TIMEOUT_MS", "5000" },
    }, "");
    defer r.deinit();
    try std.testing.expectEqual(@as(?u32, 5000), r.value.timeout_ms);
}

test "load: invalid value" {
    const Config = struct {
        port: u16 = 3000,
    };
    try std.testing.expectError(
        error.ValidationFailed,
        testLoadFromMap(Config, &.{
            .{ "PORT", "notanumber" },
        }, ""),
    );
}

test "load: multiple errors" {
    const Config = struct {
        port: u16,
        database_url: []const u8,
    };
    try std.testing.expectError(
        error.ValidationFailed,
        testLoadFromMap(Config, &.{}, ""),
    );
}

test "load: enum" {
    const Config = struct {
        log_level: enum { debug, info, warn, err } = .info,
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "LOG_LEVEL", "debug" },
    }, "");
    defer r.deinit();
    try std.testing.expectEqual(.debug, r.value.log_level);
}


test "nested struct: prefix flattening" {
    const Config = struct {
        db: struct {
            host: []const u8 = "localhost",
            port: u16 = 5432,
        } = .{},
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "DB_HOST", "db.example.com" },
        .{ "DB_PORT", "3306" },
    }, "");
    defer r.deinit();
    try std.testing.expectEqualStrings("db.example.com", r.value.db.host);
    try std.testing.expectEqual(@as(u16, 3306), r.value.db.port);
}

test "nested struct: field default" {
    const Config = struct {
        db: struct {
            host: []const u8 = "localhost",
            port: u16 = 5432,
        } = .{},
    };
    var r = try testLoadFromMap(Config, &.{}, "");
    defer r.deinit();
    try std.testing.expectEqualStrings("localhost", r.value.db.host);
    try std.testing.expectEqual(@as(u16, 5432), r.value.db.port);
}

test "nested struct: parent prefix" {
    const Config = struct {
        db: struct {
            host: []const u8 = "localhost",
        } = .{},
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "APP_DB_HOST", "db.prod.com" },
    }, "APP_");
    defer r.deinit();
    try std.testing.expectEqualStrings("db.prod.com", r.value.db.host);
}

test "nested struct: inner defaults" {
    const Config = struct {
        db: struct {
            host: []const u8 = "localhost",
            port: u16 = 5432,
        },
    };
    var r = try testLoadFromMap(Config, &.{}, "");
    defer r.deinit();
    try std.testing.expectEqualStrings("localhost", r.value.db.host);
    try std.testing.expectEqual(@as(u16, 5432), r.value.db.port);
}

test "nested struct: missing required" {
    const Config = struct {
        db: struct {
            host: []const u8,
            port: u16,
        },
    };
    try std.testing.expectError(
        error.ValidationFailed,
        testLoadFromMap(Config, &.{
            .{ "DB_HOST", "localhost" },
        }, ""),
    );
}

test "nested struct: own confzig_options" {
    const Config = struct {
        db: struct {
            url: []const u8,
            pool_size: u16 = 5,

            pub const confzig_options = .{
                .url = "DATABASE_URL",
            };
        },
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "DATABASE_URL", "postgres://localhost/mydb" },
        .{ "DB_POOL_SIZE", "10" },
    }, "");
    defer r.deinit();
    try std.testing.expectEqualStrings("postgres://localhost/mydb", r.value.db.url);
    try std.testing.expectEqual(@as(u16, 10), r.value.db.pool_size);
}


test "optional nested struct: null" {
    const Config = struct {
        redis: ?struct {
            url: []const u8,
        } = null,
    };
    var r = try testLoadFromMap(Config, &.{}, "");
    defer r.deinit();
    try std.testing.expect(r.value.redis == null);
}

test "optional nested struct: populated" {
    const Config = struct {
        redis: ?struct {
            url: []const u8,
        } = null,
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "REDIS_URL", "redis://localhost:6379" },
    }, "");
    defer r.deinit();
    try std.testing.expect(r.value.redis != null);
    try std.testing.expectEqualStrings("redis://localhost:6379", r.value.redis.?.url);
}

test "optional nested struct: missing required" {
    const Config = struct {
        redis: ?struct {
            host: []const u8,
            port: u16,
        } = null,
    };
    try std.testing.expectError(
        error.ValidationFailed,
        testLoadFromMap(Config, &.{
            .{ "REDIS_HOST", "localhost" },
        }, ""),
    );
}


test "confzig_options: custom env key" {
    const Config = struct {
        secret: []const u8,

        pub const confzig_options = .{
            .secret = .{ .key = "SECRET_KEY" },
        };
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "SECRET_KEY", "my-secret" },
    }, "");
    defer r.deinit();
    try std.testing.expectEqualStrings("my-secret", r.value.secret);
}

test "confzig_options: custom key ignores prefix" {
    const Config = struct {
        secret: []const u8,

        pub const confzig_options = .{
            .secret = .{ .key = "SECRET_KEY" },
        };
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "SECRET_KEY", "my-secret" },
    }, "APP_");
    defer r.deinit();
    try std.testing.expectEqualStrings("my-secret", r.value.secret);
}

test "confzig_options: custom parser" {
    const Config = struct {
        value: u32 = 0,

        pub const confzig_options = .{
            .value = .{
                .parser = struct {
                    fn parse(raw: []const u8, _: Allocator) anyerror!u32 {
                        return try std.fmt.parseInt(u32, raw, 16);
                    }
                }.parse,
            },
        };
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "VALUE", "ff" },
    }, "");
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 255), r.value.value);
}

test "confzig_options: parser with key" {
    const Config = struct {
        value: u32 = 0,

        pub const confzig_options = .{
            .value = .{
                .key = "HEX_VALUE",
                .parser = struct {
                    fn parse(raw: []const u8, _: Allocator) anyerror!u32 {
                        return try std.fmt.parseInt(u32, raw, 16);
                    }
                }.parse,
            },
        };
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "HEX_VALUE", "1a" },
    }, "");
    defer r.deinit();
    try std.testing.expectEqual(@as(u32, 26), r.value.value);
}

test "confzig_options: field skip with dash" {
    const Config = struct {
        visible: u16 = 80,
        internal: u32 = 42,

        pub const confzig_options = .{
            .internal = "-",
        };
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "VISIBLE", "8080" },
        .{ "INTERNAL", "999" },
    }, "");
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 8080), r.value.visible);
    try std.testing.expectEqual(@as(u32, 42), r.value.internal);
}

test "confzig_options: parser uses default key" {
    const Config = struct {
        port: u16 = 3000,

        pub const confzig_options = .{
            .port = .{
                .parser = struct {
                    fn parse(raw: []const u8, _: Allocator) anyerror!u16 {
                        const val = try std.fmt.parseInt(u16, raw, 10);
                        if (val == 0) return error.InvalidPort;
                        return val;
                    }
                }.parse,
            },
        };
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "PORT", "8080" },
    }, "");
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 8080), r.value.port);
}

test "confzig_options: direct string key" {
    const Config = struct {
        db_url: []const u8,

        pub const confzig_options = .{
            .db_url = "DATABASE_URL",
        };
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "DATABASE_URL", "postgres://localhost/mydb" },
    }, "");
    defer r.deinit();
    try std.testing.expectEqualStrings("postgres://localhost/mydb", r.value.db_url);
}


test "validator: valid" {
    const Config = struct {
        port: u16 = 3000,

        pub const confzig_options = .{
            .port = .{
                .parser = validator(u16, struct {
                    fn validate(port: u16) !void {
                        if (port == 0) return error.InvalidPort;
                    }
                }.validate),
            },
        };
    };
    var r = try testLoadFromMap(Config, &.{
        .{ "PORT", "8080" },
    }, "");
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 8080), r.value.port);
}

test "validator: invalid" {
    const Config = struct {
        port: u16 = 3000,

        pub const confzig_options = .{
            .port = .{
                .parser = validator(u16, struct {
                    fn validate(port: u16) !void {
                        if (port == 0) return error.InvalidPort;
                    }
                }.validate),
            },
        };
    };
    try std.testing.expectError(
        error.ValidationFailed,
        testLoadFromMap(Config, &.{
            .{ "PORT", "0" },
        }, ""),
    );
}


test "load: reads .env file" {
    var env = try IntegrationDir.init(std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try env.writeFile(".env", "CONFZIG_TEST_PORT=9090\nCONFZIG_TEST_HOST=example.com\n");

    const Config = struct {
        port: u16 = 3000,
        host: []const u8 = "localhost",
    };
    var result = try load(Config, std.testing.allocator, .{ .prefix = "CONFZIG_TEST_" });
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 9090), result.value.port);
    try std.testing.expectEqualStrings("example.com", result.value.host);
}

test "load: file precedence (last wins)" {
    var env = try IntegrationDir.init(std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try env.writeFile(".env", "CONFZIG_TEST_PORT=1111\nCONFZIG_TEST_HOST=first.com\n");
    try env.writeFile(".env.local", "CONFZIG_TEST_PORT=2222\n");

    const Config = struct {
        port: u16,
        host: []const u8,
    };
    var result = try load(Config, std.testing.allocator, .{
        .prefix = "CONFZIG_TEST_",
        .env_files = &.{ ".env", ".env.local" },
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 2222), result.value.port);
    try std.testing.expectEqualStrings("first.com", result.value.host);
}

test "load: missing .env file skipped" {
    var env = try IntegrationDir.init(std.testing.allocator);
    defer env.deinit(std.testing.allocator);

    const Config = struct {
        port: u16 = 3000,
    };
    var result = try load(Config, std.testing.allocator, .{
        .prefix = "CONFZIG_TEST_",
        .env_files = &.{"nonexistent.env"},
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 3000), result.value.port);
}

test "load: \\r\\n file content" {
    var env = try IntegrationDir.init(std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try env.writeFile(".env", "CONFZIG_TEST_PORT=4040\r\nCONFZIG_TEST_HOST=crlf.com\r\n");

    const Config = struct {
        port: u16,
        host: []const u8,
    };
    var result = try load(Config, std.testing.allocator, .{ .prefix = "CONFZIG_TEST_" });
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 4040), result.value.port);
    try std.testing.expectEqualStrings("crlf.com", result.value.host);
}

test "load: BOM stripped from .env file" {
    var env = try IntegrationDir.init(std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try env.writeFile(".env", "\xEF\xBB\xBFCONFZIG_TEST_PORT=7070\n");

    const Config = struct {
        port: u16 = 3000,
    };
    var result = try load(Config, std.testing.allocator, .{ .prefix = "CONFZIG_TEST_" });
    defer result.deinit();
    try std.testing.expectEqual(@as(u16, 7070), result.value.port);
}

test "load: Result.deinit frees all memory" {
    var env = try IntegrationDir.init(std.testing.allocator);
    defer env.deinit(std.testing.allocator);
    try env.writeFile(".env", "CONFZIG_TEST_URL=postgres://localhost/db\n");

    const Config = struct {
        url: []const u8,
    };
    var result = try load(Config, std.testing.allocator, .{ .prefix = "CONFZIG_TEST_" });
    result.deinit();
}
