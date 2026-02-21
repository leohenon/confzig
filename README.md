# confzig

Load typed config from `.env` files and environment variables.

```zig
const Config = struct {
    host: []const u8 = "0.0.0.0",
    port: u16 = 3000,
    database_url: []const u8,
    debug: bool = false,
};

var result = try confzig.load(Config, allocator, .{
    .env_files = &.{ ".env", ".env.local" },
    .prefix = "APP_",
});
defer result.deinit();

std.debug.print("listening on {s}:{d}\n", .{ result.value.host, result.value.port });
```

## Install

```
zig fetch --save git+https://github.com/leohenon/confzig
```

Or manually in `build.zig.zon`:

```zig
.dependencies = .{
    .confzig = .{
        .url = "git+https://github.com/leohenon/confzig",
        .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const confzig = b.dependency("confzig", .{});
exe.root_module.addImport("confzig", confzig.module("confzig"));
```

## How it works

Fields are uppercased to env var names: `database_url` → `DATABASE_URL`, prefixed if set (`APP_DATABASE_URL`).

Precedence: **struct defaults → .env files (in order) → env vars**

All errors are logged at once via `std.log.scoped(.confzig)`, then `error.ValidationFailed` is returned. `result.deinit()` frees everything.

## Types

`[]const u8`, integers, floats, bools (`true`/`false`/`1`/`0`/`yes`/`no`), enums, optionals, nested structs

## Nested structs

Flattened with `_`:

```zig
const Config = struct {
    db: struct {
        host: []const u8 = "localhost",
        port: u16 = 5432,
    } = .{},
};
```

`db.host` → `DB_HOST` (or `APP_DB_HOST` with prefix).

Optional nested structs are `null` unless at least one env var matches:

```zig
redis: ?struct {
    url: []const u8,
} = null,
```

## Per-field options

`pub const confzig_options` overrides how fields are loaded:

```zig
const Config = struct {
    secret: []const u8,
    internal_counter: u32 = 0,
    port: u16 = 3000,

    pub const confzig_options = .{
        .secret = .{ .key = "SECRET_KEY" },
        .internal_counter = "-",
        .port = .{
            .parser = struct {
                fn parse(raw: []const u8, _: std.mem.Allocator) anyerror!u16 {
                    const val = try std.fmt.parseInt(u16, raw, 10);
                    if (val == 0) return error.InvalidPort;
                    return val;
                }
            }.parse,
        },
    };
};
```

`confzig.validator()` parses normally then validates:

```zig
pub const confzig_options = .{
    .port = .{
        .parser = confzig.validator(u16, struct {
            fn validate(port: u16) !void {
                if (port < 1024) return error.PrivilegedPort;
            }
        }.validate),
    },
};
```

## .env syntax

```bash
KEY=value
QUOTED="hello\nworld"
SINGLE='raw string'
export EXPORTED=works
```

## Options

```zig
confzig.load(Config, allocator, .{
    .env_files = &.{ ".env", ".env.local" },
    .prefix = "APP_",
    .max_file_size = 1024 * 1024,
});
```

## License

[MIT](LICENSE)
