const std = @import("std");
const confzig = @import("confzig");

const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 3000,
    database_url: []const u8,
    debug: bool = false,
    log_level: enum { debug, info, warn, err } = .info,
    timeout_ms: ?u32 = null,

    db: struct {
        host: []const u8 = "localhost",
        port: u16 = 5432,
    } = .{},

    redis: ?struct {
        url: []const u8,
    } = null,

    secret: []const u8 = "",
    internal_counter: u32 = 0,

    pub const confzig_options = .{
        .secret = .{ .key = "APP_SECRET_KEY" },
        .internal_counter = "-",
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var result = confzig.load(Config, allocator, .{
        .env_files = &.{ ".env", ".env.local" },
        .prefix = "APP_",
    }) catch |err| {
        std.debug.print("Failed to load config: {}\n", .{err});
        return err;
    };
    defer result.deinit();

    const config = result.value;

    std.debug.print(
        \\
        \\── Config loaded ──
        \\  host:         {s}
        \\  port:         {d}
        \\  database_url: {s}
        \\  debug:        {}
        \\  log_level:    {s}
        \\  timeout_ms:   {?d}
        \\  db.host:      {s}
        \\  db.port:      {d}
        \\  redis:        {s}
        \\  secret:       {s}
        \\
    , .{
        config.host,
        config.port,
        config.database_url,
        config.debug,
        @tagName(config.log_level),
        config.timeout_ms,
        config.db.host,
        config.db.port,
        if (config.redis) |r| r.url else "(null)",
        if (config.secret.len > 0) "***" else "(empty)",
    });
}
