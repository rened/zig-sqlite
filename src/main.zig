const std = @import("std");
const build_options = @import("build_options");
const debug = std.debug;
const mem = std.mem;
const testing = std.testing;

const c = @cImport({
    @cInclude("sqlite3.h");
});

const logger = std.log.scoped(.sqlite);

/// Db is a wrapper around a SQLite database, providing high-level functions for executing queries.
/// A Db can be opened with a file database or a in-memory database:
///
///     // File database
///     var db: sqlite.Db = undefined;
///     try db.init(allocator, .{ .mode = { .File = "/tmp/data.db" } });
///
///     // In memory database
///     var db: sqlite.Db = undefined;
///     try db.init(allocator, .{ .mode = { .Memory = {} } });
///
pub const Db = struct {
    const Self = @This();

    allocator: *mem.Allocator,
    db: *c.sqlite3,

    /// Mode determines how the database will be opened.
    pub const Mode = union(enum) {
        File: []const u8,
        Memory,
    };

    /// init creates a database with the provided `mode`.
    pub fn init(self: *Self, allocator: *mem.Allocator, options: anytype) !void {
        self.allocator = allocator;

        const mode = if (@hasField(@TypeOf(options), "mode")) options.mode else .Memory;

        switch (mode) {
            .File => |path| {
                logger.info("opening {}", .{path});

                // Need a null-terminated string here.
                const pathZ = try allocator.dupeZ(u8, path);
                defer allocator.free(pathZ);

                var db: ?*c.sqlite3 = undefined;
                const result = c.sqlite3_open_v2(
                    pathZ,
                    &db,
                    c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
                    null,
                );
                if (result != c.SQLITE_OK or db == null) {
                    logger.warn("unable to open database, result: {}", .{result});
                    return error.CannotOpenDatabase;
                }

                self.db = db.?;
            },
            .Memory => {
                logger.info("opening in memory", .{});

                var db: ?*c.sqlite3 = undefined;
                const result = c.sqlite3_open_v2(
                    ":memory:",
                    &db,
                    c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_MEMORY,
                    null,
                );
                if (result != c.SQLITE_OK or db == null) {
                    logger.warn("unable to open database, result: {}", .{result});
                    return error.CannotOpenDatabase;
                }

                self.db = db.?;
            },
        }
    }

    /// deinit closes the database.
    pub fn deinit(self: *Self) void {
        _ = c.sqlite3_close(self.db);
    }

    /// exec is a convenience function which prepares a statement and executes it directly.
    pub fn exec(self: *Self, comptime query: []const u8, values: anytype) !void {
        var stmt = try self.prepare(query, values);
        defer stmt.deinit();
        try stmt.exec();
    }

    /// prepare prepares a statement for the `query` provided.
    ///
    /// The query is analysed at comptime to search for bind markers.
    /// prepare enforces having as much fields in the `values` tuple as there are bind markers.
    ///
    /// Example usage:
    ///
    ///     var stmt = try db.prepare("INSERT INTO foo(id, name) VALUES(?, ?)", .{
    ///         .id = 3540,
    ///         .name = "Eminem",
    ///     });
    ///     defer stmt.deinit();
    ///
    /// Note that the name of the fields in the tuple are irrelevant, only the types are.
    pub fn prepare(self: *Self, comptime query: []const u8, values: anytype) !Statement {
        return Statement.prepare(self, 0, query, values);
    }

    /// rowsAffected returns the number of rows affected by the last statement executed.
    pub fn rowsAffected(self: *Self) usize {
        return @intCast(usize, c.sqlite3_changes(self.db));
    }
};

/// Statement is a wrapper around a SQLite statement, providing high-level functions to execute
/// a statement and retrieve rows for SELECT queries.
///
/// The exec function can be used to execute a query which does not return rows:
///
///     var stmt = try db.prepare("UPDATE foo SET id = ? WHERE name = ?", .{
///         .id = 200,
///         .name = "José",
///     });
///     defer stmt.deinit();
///
/// The one function can be used to select a single row:
///
///     var stmt = try db.prepare("SELECT name FROM foo WHERE id = ?", .{ .id = 200 });
///     defer stmt.deinit();
///
///     const Row = struct { id: usize };
///     const row = try stmt.one(Row .{});
///
/// The all function can be used to select all rows:
///
///     var stmt = try db.prepare("SELECT name FROM foo", .{});
///     defer stmt.deinit();
///
///     const Row = struct { id: usize };
///     const rows = try stmt.all(Row .{});
///
/// Look at aach function for more complete documentation.
///
pub const Statement = struct {
    const Self = @This();

    stmt: *c.sqlite3_stmt,

    fn prepare(db: *Db, flags: c_uint, comptime query: []const u8, values: anytype) !Self {
        const StructType = @typeInfo(@TypeOf(values)).Struct;
        comptime {
            const bind_parameter_count = std.mem.count(u8, query, "?");
            if (bind_parameter_count != StructType.fields.len) {
                @compileError("bind parameter count != number of fields in tuple/struct");
            }
        }

        // prepare

        var stmt = blk: {
            var tmp: ?*c.sqlite3_stmt = undefined;
            const result = c.sqlite3_prepare_v3(
                db.db,
                query.ptr,
                @intCast(c_int, query.len),
                flags,
                &tmp,
                null,
            );
            if (result != c.SQLITE_OK) {
                logger.warn("unable to prepare statement, result: {}", .{result});
                return error.CannotPrepareStatement;
            }
            break :blk tmp.?;
        };

        // Bind

        inline for (StructType.fields) |struct_field, _i| {
            const i = @as(usize, _i);
            const field_type_info = @typeInfo(struct_field.field_type);
            const field_value = @field(values, struct_field.name);
            const column = i + 1;

            switch (struct_field.field_type) {
                []const u8, []u8 => {
                    _ = c.sqlite3_bind_text(stmt, column, field_value.ptr, @intCast(c_int, field_value.len), null);
                },
                else => switch (field_type_info) {
                    .Int, .ComptimeInt => _ = c.sqlite3_bind_int64(stmt, column, @intCast(c_longlong, field_value)),
                    .Float, .ComptimeFloat => _ = c.sqlite3_bind_double(stmt, column, field_value),
                    .Array => |arr| {
                        switch (arr.child) {
                            u8 => {
                                const data: []const u8 = field_value[0..field_value.len];

                                _ = c.sqlite3_bind_text(stmt, column, data.ptr, @intCast(c_int, data.len), null);
                            },
                            else => @compileError("cannot populate field " ++ field.name ++ " of type array of " ++ @typeName(arr.child)),
                        }
                    },
                    else => @compileError("cannot bind field " ++ struct_field.name ++ " of type " ++ @typeName(struct_field.field_type)),
                },
            }
        }

        return Self{
            .stmt = stmt,
        };
    }

    pub fn deinit(self: *Self) void {
        const result = c.sqlite3_finalize(self.stmt);
        if (result != c.SQLITE_OK) {
            logger.err("unable to finalize prepared statement, result: {}", .{result});
        }
    }

    pub fn exec(self: *Self) !void {
        const result = c.sqlite3_step(self.stmt);
        switch (result) {
            c.SQLITE_DONE => {},
            c.SQLITE_BUSY => return error.SQLiteBusy,
            else => std.debug.panic("invalid result {}", .{result}),
        }
    }

    /// one reads a single row from the result set of this statement.
    ///
    /// The data in the row is used to populate a value of the type `Type`.
    /// This means that `Type` must have as many fields as is returned in the query
    /// executed by this statement.
    /// This also means that the type of each field must be compatible with the SQLite type.
    ///
    /// Here is an example of how to use an anonymous struct type:
    ///
    ///     const row = try stmt.one(
    ///         struct {
    ///             id: usize,
    ///             name: []const u8,
    ///             age: usize,
    ///         },
    ///         .{ .allocator = allocator },
    ///     );
    ///
    /// The `options` tuple is used to provide additional state in some cases, for example
    /// an allocator used to read text and blobs.
    ///
    pub fn one(self: *Self, comptime Type: type, options: anytype) !?Type {
        const TypeInfo = @typeInfo(Type);

        var result = c.sqlite3_step(self.stmt);

        switch (TypeInfo) {
            .Int => return switch (result) {
                c.SQLITE_ROW => try self.readInt(Type, options),
                c.SQLITE_DONE => null,
                else => std.debug.panic("invalid result {}", .{result}),
            },
            .Struct => return switch (result) {
                c.SQLITE_ROW => try self.readStruct(Type, options),
                c.SQLITE_DONE => null,
                else => std.debug.panic("invalid result {}", .{result}),
            },
            else => @compileError("cannot read into type " ++ @typeName(Type)),
        }
    }

    /// all reads all rows from the result set of this statement.
    ///
    /// The data in each row is used to populate a value of the type `Type`.
    /// This means that `Type` must have as many fields as is returned in the query
    /// executed by this statement.
    /// This also means that the type of each field must be compatible with the SQLite type.
    ///
    /// Here is an example of how to use an anonymous struct type:
    ///
    ///     const rows = try stmt.all(
    ///         struct {
    ///             id: usize,
    ///             name: []const u8,
    ///             age: usize,
    ///         },
    ///         .{ .allocator = allocator },
    ///     );
    ///
    /// The `options` tuple is used to provide additional state in some cases.
    /// Note that for this function the allocator is mandatory.
    ///
    pub fn all(self: *Self, comptime Type: type, options: anytype) ![]Type {
        const TypeInfo = @typeInfo(Type);

        var rows = std.ArrayList(Type).init(options.allocator);

        var result = c.sqlite3_step(self.stmt);
        while (result == c.SQLITE_ROW) : (result = c.sqlite3_step(self.stmt)) {
            const columns = c.sqlite3_column_count(self.stmt);

            var value = switch (TypeInfo) {
                .Int => blk: {
                    debug.assert(columns == 1);
                    break :blk try self.readInt(Type, options);
                },
                .Struct => blk: {
                    std.debug.assert(columns == @typeInfo(Type).Struct.fields.len);
                    break :blk try self.readStruct(Type, options);
                },
                else => @compileError("cannot read into type " ++ @typeName(Type)),
            };

            try rows.append(value);
        }

        if (result != c.SQLITE_DONE) {
            logger.err("unable to iterate, result: {}", .{result});
            return error.SQLiteStepError;
        }

        return rows.span();
    }

    fn readInt(self: *Self, comptime Type: type, options: anytype) !Type {
        const n = c.sqlite3_column_int64(self.stmt, 0);
        return @intCast(Type, n);
    }

    fn readStruct(self: *Self, comptime Type: type, options: anytype) !Type {
        var value: Type = undefined;

        inline for (@typeInfo(Type).Struct.fields) |field, _i| {
            const i = @as(usize, _i);
            const field_type_info = @typeInfo(field.field_type);

            switch (field.field_type) {
                []const u8, []u8 => {
                    const data = c.sqlite3_column_blob(self.stmt, i);
                    if (data == null) {
                        @field(value, field.name) = "";
                    } else {
                        const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));

                        var tmp = try options.allocator.alloc(u8, size);
                        mem.copy(u8, tmp, @ptrCast([*c]const u8, data)[0..size]);

                        @field(value, field.name) = tmp;
                    }
                },
                else => switch (field_type_info) {
                    .Int => {
                        const n = c.sqlite3_column_int64(self.stmt, i);
                        @field(value, field.name) = @intCast(field.field_type, n);
                    },
                    .Float => {
                        const f = c.sqlite3_column_double(self.stmt, i);
                        @field(value, field.name) = f;
                    },
                    .Void => {
                        @field(value, field.name) = {};
                    },
                    .Array => |arr| {
                        switch (arr.child) {
                            u8 => {
                                const data = c.sqlite3_column_blob(self.stmt, i);
                                const size = @intCast(usize, c.sqlite3_column_bytes(self.stmt, i));

                                if (size > @as(usize, arr.len)) return error.ArrayTooSmall;

                                mem.copy(u8, @field(value, field.name)[0..], @ptrCast([*c]const u8, data)[0..size]);
                            },
                            else => @compileError("cannot populate field " ++ field.name ++ " of type array of " ++ @typeName(arr.child)),
                        }
                    },
                    else => @compileError("cannot populate field " ++ field.name ++ " of type " ++ @typeName(field.field_type)),
                },
            }
        }

        return value;
    }
};

test "sqlite: statement exec" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    var db: Db = undefined;
    try db.init(testing.allocator, .{ .mode = dbMode() });

    // Create the tables

    comptime const all_ddl = &[_][]const u8{
        \\CREATE TABLE user(
        \\ id integer PRIMARY KEY,
        \\ name text,
        \\ age integer
        \\)
        ,
        \\CREATE TABLE article(
        \\  id integer PRIMARY KEY,
        \\  author_id integer,
        \\  data text,
        \\  FOREIGN KEY(author_id) REFERENCES user(id)
        \\)
    };
    inline for (all_ddl) |ddl| {
        var stmt = try db.prepare(ddl, .{});
        defer stmt.deinit();
        try stmt.exec();
    }

    // Add data

    const User = struct {
        id: usize,
        name: []const u8,
        age: usize,
    };

    const users = &[_]User{
        .{ .id = 20, .name = "Vincent", .age = 33 },
        .{ .id = 40, .name = "Julien", .age = 35 },
        .{ .id = 60, .name = "José", .age = 40 },
    };

    for (users) |user| {
        try db.exec("INSERT INTO user(id, name, age) VALUES(?, ?, ?)", user);

        const rows_inserted = db.rowsAffected();
        testing.expectEqual(@as(usize, 1), rows_inserted);
    }

    // Read a single user

    {
        var stmt = try db.prepare("SELECT id, name, age FROM user WHERE id = ?", .{ .id = 20 });
        defer stmt.deinit();

        var rows = try stmt.all(User, .{ .allocator = allocator });
        for (rows) |row| {
            testing.expectEqual(users[0].id, row.id);
            testing.expectEqualStrings(users[0].name, row.name);
            testing.expectEqual(users[0].age, row.age);
        }
    }

    // Read all users

    {
        var stmt = try db.prepare("SELECT id, name, age FROM user", .{});
        defer stmt.deinit();

        var rows = try stmt.all(User, .{ .allocator = allocator });
        testing.expectEqual(@as(usize, 3), rows.len);
        for (rows) |row, i| {
            const exp = users[i];
            testing.expectEqual(exp.id, row.id);
            testing.expectEqualStrings(exp.name, row.name);
            testing.expectEqual(exp.age, row.age);
        }
    }

    // Test with anonymous structs

    {
        var stmt = try db.prepare("SELECT id, name, age FROM user WHERE id = ?", .{ .id = 20 });
        defer stmt.deinit();

        var row = try stmt.one(
            struct {
                id: usize,
                name: []const u8,
                age: usize,
            },
            .{ .allocator = allocator },
        );
        testing.expect(row != null);

        const exp = users[0];
        testing.expectEqual(exp.id, row.?.id);
        testing.expectEqualStrings(exp.name, row.?.name);
        testing.expectEqual(exp.age, row.?.age);
    }

    // Test with a single integer

    {
        var stmt = try db.prepare("SELECT age FROM user WHERE id = ?", .{ .id = 20 });
        defer stmt.deinit();

        var age = try stmt.one(usize, .{});
        testing.expect(age != null);

        testing.expectEqual(@as(usize, 33), age.?);
    }
}

pub fn dbMode() Db.Mode {
    return if (build_options.is_ci) blk: {
        break :blk .{ .Memory = {} };
    } else blk: {
        const path = "/tmp/zig-sqlite.db";
        std.fs.cwd().deleteFile(path) catch {};
        break :blk .{ .File = path };
    };
}