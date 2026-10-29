const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);

    if (args.len < 2) {
        try writeAll(init, "usage: dsh <subcommand> [args...]\n");
        return;
    }

    const subcommand = args[1];

    if (std.mem.eql(u8, subcommand, "conformance")) {
        try conformance(init, args);
    } else if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        try printHelp(init);
    } else {
        try writeAll(init, "dsh: unknown subcommand: ");
        try writeAll(init, subcommand);
        try writeAll(init, "\n");
    }
}

fn writeAll(init: std.process.Init, s: []const u8) !void {
    const file = std.Io.File.stdout();
    try std.Io.File.writeStreamingAll(file, init.io, s);
}

fn printHelp(init: std.process.Init) !void {
    const msg: []const u8 = "dsh (Zig port, dsh-v0.2.0-rc.2)\n" ++
        "Subcommands:\n" ++
        "  conformance <scenario-id> <input-json-file>  run one conformance scenario\n" ++
        "    help                                         show this help\n";
    try writeAll(init, msg);
}

// ============================================================================
// JSON parser (minimal, for conformance input files)
// ============================================================================

const JsonType = enum { null, bool, num, str, arr, obj };

const JsonField = struct {
    key: []const u8,
    val: JsonValue,
};

const JsonValue = struct {
    typ: JsonType,
    bool: bool = false,
    num: f64 = 0,
    str: []const u8 = "",
    arr: []const JsonValue = undefined,
    obj: []const JsonField = undefined,
};

const JsonParser = struct {
    s: []const u8,
    p: usize = 0,
    a: std.mem.Allocator,
};

const JsonError = error{
    UnexpectedEnd,
    InvalidLiteral,
    InvalidEscape,
    InvalidHex,
    ExpectedColon,
    ExpectedCommaOrBrace,
    ExpectedCommaOrBracket,
    ExpectedObject,
    MissingBase,
    MissingLayers,
    OutOfMemory,
    InvalidCharacter,
};

fn jsonParseValue(self: *JsonParser) JsonError!JsonValue {
    jsonSkipWs(self);
    if (self.p >= self.s.len) return error.UnexpectedEnd;
    const c = self.s[self.p];
    if (c == '{') return jsonParseObject(self);
    if (c == '[') return jsonParseArray(self);
    if (c == '"') {
        const str = try jsonParseString(self);
        return .{ .typ = .str, .str = str };
    }
    if (c == 't') return jsonParseTrue(self);
    if (c == 'f') return jsonParseFalse(self);
    if (c == 'n') return jsonParseNull(self);
    return jsonParseNumber(self);
}

fn jsonSkipWs(self: *JsonParser) void {
    while (self.p < self.s.len) {
        const c = self.s[self.p];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            self.p += 1;
        } else { break; }
    }
}

fn jsonParseObject(self: *JsonParser) JsonError!JsonValue {
    self.p += 1; // {
    jsonSkipWs(self);
    var fields = try std.ArrayList(JsonField).initCapacity(self.a, 4);
    defer fields.deinit(self.a);
    if (self.p < self.s.len and self.s[self.p] == '}') {
        self.p += 1;
        return .{ .typ = .obj, .obj = try fields.toOwnedSlice(self.a) };
    }
    while (true) {
        jsonSkipWs(self);
        if (self.p >= self.s.len) return error.UnexpectedEnd;
        if (self.s[self.p] == '}') { self.p += 1; break; }
        const key = try jsonParseString(self);
        jsonSkipWs(self);
        if (self.p >= self.s.len or self.s[self.p] != ':') return error.ExpectedColon;
        self.p += 1;
        const val = try jsonParseValue(self);
        try fields.append(self.a, .{ .key = key, .val = val });
        jsonSkipWs(self);
        if (self.p < self.s.len and self.s[self.p] == ',') { self.p += 1; continue; }
        if (self.p < self.s.len and self.s[self.p] == '}') { self.p += 1; break; }
        return error.ExpectedCommaOrBrace;
    }
    return .{ .typ = .obj, .obj = try fields.toOwnedSlice(self.a) };
}

fn jsonParseArray(self: *JsonParser) !JsonValue {
    self.p += 1; // [
    jsonSkipWs(self);
    var items = try std.ArrayList(JsonValue).initCapacity(self.a, 4);
    defer items.deinit(self.a);
    if (self.p < self.s.len and self.s[self.p] == ']') {
        self.p += 1;
        return .{ .typ = .arr, .arr = try items.toOwnedSlice(self.a) };
    }
    while (true) {
        jsonSkipWs(self);
        if (self.p >= self.s.len) return error.UnexpectedEnd;
        if (self.s[self.p] == ']') { self.p += 1; break; }
        const val = try jsonParseValue(self);
        try items.append(self.a, val);
        jsonSkipWs(self);
        if (self.p < self.s.len and self.s[self.p] == ',') { self.p += 1; continue; }
        if (self.p < self.s.len and self.s[self.p] == ']') { self.p += 1; break; }
        return error.ExpectedCommaOrBracket;
    }
    return .{ .typ = .arr, .arr = try items.toOwnedSlice(self.a) };
}

fn jsonParseString(self: *JsonParser) ![]const u8 {
    self.p += 1; // opening "
    var buf = try std.ArrayList(u8).initCapacity(self.a, 16);
    defer buf.deinit(self.a);
    while (true) {
        if (self.p >= self.s.len) return error.UnexpectedEnd;
        const c = self.s[self.p];
        self.p += 1;
        if (c == '"') break;
        if (c == '\\') {
            if (self.p >= self.s.len) return error.UnexpectedEnd;
            const esc = self.s[self.p];
            self.p += 1;
            switch (esc) {
                '"' => try buf.append(self.a, '"'),
                '\\' => try buf.append(self.a, '\\'),
                '/' => try buf.append(self.a, '/'),
                'b' => try buf.append(self.a, '\x08'),
                'f' => try buf.append(self.a, '\x0c'),
                'n' => try buf.append(self.a, '\n'),
                'r' => try buf.append(self.a, '\r'),
                't' => try buf.append(self.a, '\t'),
                'u' => {
                    var hex: [4]u8 = undefined;
                    for (0..4) |j| {
                        if (self.p + j >= self.s.len) return error.UnexpectedEnd;
                        hex[j] = self.s[self.p + j];
                    }
                    self.p += 4;
                    const code = try parseU16Hex(hex);
                    if (code < 0x80) {
                        try buf.append(self.a, @as(u8, @intCast(code)));
                    } else if (code < 0x800) {
                        try buf.append(self.a, @as(u8, @intCast(0xc0 | (code >> 6))));
                        try buf.append(self.a, @as(u8, @intCast(0x80 | (code & 0x3f))));
                    } else {
                        try buf.append(self.a, @as(u8, @intCast(0xe0 | (code >> 12))));
                        try buf.append(self.a, @as(u8, @intCast(0x80 | ((code >> 6) & 0x3f))));
                        try buf.append(self.a, @as(u8, @intCast(0x80 | (code & 0x3f))));
                    }
                },
                else => return error.InvalidEscape,
            }
        } else {
            try buf.append(self.a, c);
        }
    }
    return try buf.toOwnedSlice(self.a);
}

fn jsonParseTrue(self: *JsonParser) !JsonValue {
    if (self.p + 4 <= self.s.len and std.mem.eql(u8, self.s[self.p..self.p + 4], "true")) {
        self.p += 4;
        return .{ .typ = .bool, .bool = true };
    }
    return error.InvalidLiteral;
}

fn jsonParseFalse(self: *JsonParser) !JsonValue {
    if (self.p + 5 <= self.s.len and std.mem.eql(u8, self.s[self.p..self.p + 5], "false")) {
        self.p += 5;
        return .{ .typ = .bool, .bool = false };
    }
    return error.InvalidLiteral;
}

fn jsonParseNull(self: *JsonParser) !JsonValue {
    if (self.p + 4 <= self.s.len and std.mem.eql(u8, self.s[self.p..self.p + 4], "null")) {
        self.p += 4;
        return .{ .typ = .null };
    }
    return error.InvalidLiteral;
}

fn jsonParseNumber(self: *JsonParser) !JsonValue {
    const start = self.p;
    if (self.p < self.s.len and (self.s[self.p] == '-' or self.s[self.p] == '+')) self.p += 1;
    while (self.p < self.s.len and self.s[self.p] >= '0' and self.s[self.p] <= '9') self.p += 1;
    if (self.p < self.s.len and self.s[self.p] == '.') {
        self.p += 1;
        while (self.p < self.s.len and self.s[self.p] >= '0' and self.s[self.p] <= '9') self.p += 1;
    }
    if (self.p < self.s.len and (self.s[self.p] == 'e' or self.s[self.p] == 'E')) {
        self.p += 1;
        if (self.p < self.s.len and (self.s[self.p] == '+' or self.s[self.p] == '-')) self.p += 1;
        while (self.p < self.s.len and self.s[self.p] >= '0' and self.s[self.p] <= '9') self.p += 1;
    }
    const numStr = self.s[start..self.p];
    const f = try std.fmt.parseFloat(f64, numStr);
    return .{ .typ = .num, .num = f };
}

fn parseU16Hex(hex: [4]u8) !u16 {
    var v: u16 = 0;
    for (hex) |h| {
        v *= 16;
        if (h >= '0' and h <= '9') {
            v += @as(u16, @intCast(h)) - @as(u16, @intCast('0'));
        } else {
            if (h >= 'a' and h <= 'f') {
                v += @as(u16, @intCast(h)) - @as(u16, @intCast('a')) + 10;
            } else {
                if (h >= 'A' and h <= 'F') {
                    v += @as(u16, @intCast(h)) - @as(u16, @intCast('A')) + 10;
                } else {
                    return error.InvalidHex;
                }
            }
        }
    }
    return v;
}

fn jsonObjGet(obj: JsonValue, key: []const u8) ?JsonValue {
    if (obj.typ != .obj) return null;
    for (obj.obj) |f| {
        if (std.mem.eql(u8, f.key, key)) return f.val;
    }
    return null;
}

fn jsonToYaml(jv: JsonValue, a: std.mem.Allocator) !YamlValue.Value {
    switch (jv.typ) {
        .null => return YamlValue.Value.makeNull(),
        .bool => return YamlValue.Value.makeBool(jv.bool),
        .num => return YamlValue.Value.makeNum(jv.num),
        .str => return YamlValue.Value.makeStr(jv.str),
        .arr => {
            var items = try std.ArrayList(YamlValue.Value).initCapacity(a, jv.arr.len);
            defer items.deinit(a);
            for (jv.arr) |item| {
                try items.append(a, try jsonToYaml(item, a));
            }
            return YamlValue.Value.makeArr(try items.toOwnedSlice(a));
        },
        .obj => {
            var entries = try std.ArrayList(YamlValue.MapEntry).initCapacity(a, jv.obj.len);
            defer entries.deinit(a);
            for (jv.obj) |field| {
                try entries.append(a, .{
                    .key = field.key,
                    .val = try jsonToYaml(field.val, a),
                });
            }
            return YamlValue.Value.makeMap(try entries.toOwnedSlice(a));
        }
    }
}

// ============================================================================
// YAML value (with !!js / jsExpr support)
// ============================================================================

pub const YamlValue = enum(u8) {
    null,
    string,
    number,
    boolean,
    array,
    mapping,
    jsExpr,

    pub const Value = struct {
        typ: YamlValue,
        str: []const u8,
        num: f64,
        bool: bool,
        arr: []const Value,
        map: []const MapEntry,

        pub fn makeNull() Value {
            return .{ .typ = .null, .str = "", .num = 0, .bool = false, .arr = undefined, .map = undefined };
        }
        pub fn makeStr(s: []const u8) Value {
            return .{ .typ = .string, .str = s, .num = 0, .bool = false, .arr = undefined, .map = undefined };
        }
        pub fn makeNum(n: f64) Value {
            return .{ .typ = .number, .str = "", .num = n, .bool = false, .arr = undefined, .map = undefined };
        }
        pub fn makeBool(b: bool) Value {
            return .{ .typ = .boolean, .str = "", .num = 0, .bool = b, .arr = undefined, .map = undefined };
        }
        pub fn makeJsExpr(s: []const u8) Value {
            return .{ .typ = .jsExpr, .str = s, .num = 0, .bool = false, .arr = undefined, .map = undefined };
        }
        pub fn makeArr(v: []const Value) Value {
            return .{ .typ = .array, .str = "", .num = 0, .bool = false, .arr = v, .map = undefined };
        }
        pub fn makeMap(m: []const MapEntry) Value {
            return .{ .typ = .mapping, .str = "", .num = 0, .bool = false, .arr = undefined, .map = m };
        }
    };

    pub const MapEntry = struct {
        key: []const u8,
        val: Value,
    };
};

const YamlResult = std.mem.Allocator.Error!YamlValue.Value;

pub fn parseYaml(input: []const u8, allocator: std.mem.Allocator) YamlResult {
    var lines = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer lines.deinit(allocator);

    var lineStart: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\n') {
            try lines.append(allocator, input[lineStart..i]);
            lineStart = i + 1;
        }
        i += 1;
    }
    if (lineStart < input.len) {
        try lines.append(allocator, input[lineStart..i]);
    }

    const root = try parseBlock(lines.items, 0, allocator);
    return root;
}

fn parseBlock(
    lines: [][]const u8,
    startIndent: usize,
    allocator: std.mem.Allocator,
) YamlResult {
    var j: usize = 0;
    var firstLineIndex: ?usize = null;
    while (j < lines.len) {
        const line = lines[j];
        const trimmed = trimLeft(line);
        if (trimmed.len == 0 or trimmed[0] == '#') {
            j += 1;
            continue;
        }
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (indent < startIndent) {
            break;
        }
        firstLineIndex = j;
        break;
    }

    if (firstLineIndex == null) {
        return YamlValue.Value.makeNull();
    }

    const firstLine = lines[firstLineIndex.?];
    const flTrimmed = trimLeft(firstLine);

    if (flTrimmed[0] == '-') {
        return parseArrayBlock(lines, firstLineIndex.?, startIndent, allocator);
    } else {
        return parseMappingBlock(lines, firstLineIndex.?, startIndent, allocator);
    }
}

fn parseArrayBlock(
    lines: [][]const u8,
    start: usize,
    startIndent: usize,
    allocator: std.mem.Allocator,
) YamlResult {
    var arr = try std.ArrayList(YamlValue.Value).initCapacity(allocator, 4);
    defer arr.deinit(allocator);

    var k: usize = start;
    while (k < lines.len) {
        const line = lines[k];
        const trimmed = trimLeft(line);
        if (trimmed.len == 0 or trimmed[0] == '#') {
            k += 1;
            continue;
        }
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (indent < startIndent) break;
        if (indent > startIndent) { k += 1; continue; }
        if (trimmed[0] != '-') break;

        var itemText = trimmed[1..];
        itemText = trimLeft(itemText);
        if (itemText.len > 0) {
            // Check if the next line is indented more than startIndent, which means
            // this "- key: value" starts a block mapping, not an inline scalar/mapping.
            var nextNested = false;
            if (k + 1 < lines.len) {
                const nl = lines[k + 1];
                const nTrimmed = trimLeft(nl);
                if (nTrimmed.len > 0 and nTrimmed[0] != '#') {
                    var nIndent: usize = 0;
                    while (nIndent < nl.len and nl[nIndent] == ' ') nIndent += 1;
                    if (nIndent > startIndent) {
                        nextNested = true;
                    }
                }
            }
            if (!nextNested) {
                const colonIdx = std.mem.indexOf(u8, itemText, ":");
                if (colonIdx) |colonPos| {
                    // Inline mapping: "- id: shared" => {id: shared}
                    const key = trimLeftRight(itemText[0..colonPos]);
                    const valText = trimLeftRight(itemText[colonPos + 1..]);
                    const val = try parseScalar(valText, allocator);
                    var entries = try std.ArrayList(YamlValue.MapEntry).initCapacity(allocator, 1);
                    try entries.append(allocator, .{ .key = key, .val = val });
                    try arr.append(allocator, YamlValue.Value.makeMap(try entries.toOwnedSlice(allocator)));
                    entries.deinit(allocator);
                } else {
                    const scalar = try parseScalar(itemText, allocator);
                    try arr.append(allocator, scalar);
                }
            } else {
                // Block mapping: "- id: shared" followed by indented entries
                const itemIndent = startIndent + 2;
                var itemLines = try std.ArrayList([]const u8).initCapacity(allocator, 4);
                try itemLines.append(allocator, itemText);
                var k2 = k + 1;
                while (k2 < lines.len) {
                    const nl = lines[k2];
                    const nTrimmed = trimLeft(nl);
                    if (nTrimmed.len == 0 or nTrimmed[0] == '#') { k2 += 1; continue; }
                    var nIndent: usize = 0;
                    while (nIndent < nl.len and nl[nIndent] == ' ') nIndent += 1;
                    if (nIndent < itemIndent) break;
                    if (nIndent == itemIndent and (nTrimmed[0] == '-')) break;
                    try itemLines.append(allocator, nl);
                    k2 += 1;
                }
                // Normalize: strip itemIndent leading spaces so parseBlock sees
                // each line at its relative indent (starting from 0).
                var normLines = try std.ArrayList([]const u8).initCapacity(allocator, itemLines.items.len);
                for (itemLines.items) |il| {
                    var s: usize = 0;
                    while (s < itemIndent and s < il.len and il[s] == ' ') s += 1;
                    try normLines.append(allocator, il[s..]);
                }
                const value = try parseBlock(normLines.items, 0, allocator);
                try arr.append(allocator, value);
                k = k2;
                continue;
            }
            k += 1;
            continue;
        }

        const itemIndent = startIndent + 2;
        var itemLines = try std.ArrayList([]const u8).initCapacity(allocator, 4);
        var value: YamlValue.Value = YamlValue.Value.makeNull();
        var hasNested = false;
        var k2 = k + 1;
        while (k2 < lines.len) {
            const nl = lines[k2];
            const nTrimmed = trimLeft(nl);
            if (nTrimmed.len == 0 or nTrimmed[0] == '#') { k2 += 1; continue; }
            var nIndent: usize = 0;
            while (nIndent < nl.len and nl[nIndent] == ' ') nIndent += 1;
            if (nIndent < itemIndent) break;
            if (nIndent == itemIndent and (nTrimmed[0] == '-')) break;
            try itemLines.append(allocator, nl);
            hasNested = true;
            k2 += 1;
        }

        if (hasNested) {
            value = try parseBlock(itemLines.items, itemIndent, allocator);
        } else {
            value = YamlValue.Value.makeNull();
        }
        itemLines.deinit(allocator);

        try arr.append(allocator, value);
        k = k2;
    }

    const slice = try arr.toOwnedSlice(allocator);
    return YamlValue.Value.makeArr(slice);
}

fn parseMappingBlock(
    lines: [][]const u8,
    start: usize,
    startIndent: usize,
    allocator: std.mem.Allocator,
) YamlResult {
    var map = try std.ArrayList(YamlValue.MapEntry).initCapacity(allocator, 4);
    defer map.deinit(allocator);

    var k: usize = start;
    while (k < lines.len) {
        const line = lines[k];
        const trimmed = trimLeft(line);
        if (trimmed.len == 0 or trimmed[0] == '#') {
            k += 1;
            continue;
        }
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (indent < startIndent) break;
        if (indent > startIndent) { k += 1; continue; }

        const colonPos = std.mem.indexOf(u8, trimmed, ":");
        if (colonPos == null) { k += 1; continue; }

        const key = trimLeftRight(trimmed[0..colonPos.?]);
        const afterColon = trimmed[colonPos.? + 1..];
        const afterTrimmed = trimLeft(afterColon);

        if (afterTrimmed.len > 0) {
            const scalar = try parseScalar(afterTrimmed, allocator);
            try map.append(allocator, .{ .key = key, .val = scalar });
            k += 1;
            continue;
        }

        const nestedIndent = startIndent + 2;
        var nestedLines = try std.ArrayList([]const u8).initCapacity(allocator, 4);
        var k2 = k + 1;
        var hasNested = false;
        while (k2 < lines.len) {
            const nl = lines[k2];
            const nTrimmed = trimLeft(nl);
            if (nTrimmed.len == 0 or nTrimmed[0] == '#') { k2 += 1; continue; }
            var nIndent: usize = 0;
            while (nIndent < nl.len and nl[nIndent] == ' ') nIndent += 1;
            if (nIndent < nestedIndent) break;
            try nestedLines.append(allocator, nl);
            hasNested = true;
            k2 += 1;
        }

        var value: YamlValue.Value = YamlValue.Value.makeNull();
        if (hasNested) {
            value = try parseBlock(nestedLines.items, nestedIndent, allocator);
        }
        nestedLines.deinit(allocator);

        try map.append(allocator, .{ .key = key, .val = value });
        k = k2;
    }

    const slice = try map.toOwnedSlice(allocator);
    return YamlValue.Value.makeMap(slice);
}

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

fn trimLeftRight(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r')) end -= 1;
    return s[start..end];
}

fn parseScalar(text: []const u8, allocator: std.mem.Allocator) YamlResult {
    const trimmed = trimLeftRight(text);

    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return YamlValue.Value.makeStr(trimmed[1..trimmed.len - 1]);
    }
    if (trimmed.len >= 2 and trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') {
        return YamlValue.Value.makeStr(trimmed[1..trimmed.len - 1]);
    }

    // Flow mapping: { key: value, ... }
    if (trimmed.len >= 2 and trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        return parseFlowMapping(trimmed[1..trimmed.len - 1], allocator);
    }

    // Flow sequence: [item1, item2, ...]
    if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
        return parseFlowSequence(trimmed[1..trimmed.len - 1], allocator);
    }

    if (trimmed.len == 0) {
        return YamlValue.Value.makeNull();
    }

    if (std.mem.eql(u8, trimmed, "null") or std.mem.eql(u8, trimmed, "~")) {
        return YamlValue.Value.makeNull();
    }

    if (std.mem.eql(u8, trimmed, "true")) {
        return YamlValue.Value.makeBool(true);
    }
    if (std.mem.eql(u8, trimmed, "false")) {
        return YamlValue.Value.makeBool(false);
    }

    if (trimmed.len >= 5 and std.mem.eql(u8, trimmed[0..5], "!!js ")) {
        return YamlValue.Value.makeJsExpr(trimmed[5..]);
    }

    if (isNumber(trimmed)) {
        const f = std.fmt.parseFloat(f64, trimmed) catch return YamlValue.Value.makeStr(trimmed);
        return YamlValue.Value.makeNum(f);
    }

    return YamlValue.Value.makeStr(trimmed);
}

fn splitTopLevel(s: []const u8, sep: u8, allocator: std.mem.Allocator) ![][]const u8 {
    var parts = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    var start: usize = 0;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '{' or c == '[') {
            depth += 1;
        } else if (c == '}' or c == ']') {
            if (depth > 0) depth -= 1;
        } else if (c == sep and depth == 0) {
            try parts.append(allocator, s[start..i]);
            start = i + 1;
        }
        i += 1;
    }
    if (start < s.len) {
        try parts.append(allocator, s[start..]);
    }
    return try parts.toOwnedSlice(allocator);
}

fn parseFlowMapping(text: []const u8, allocator: std.mem.Allocator) YamlResult {
    const parts = try splitTopLevel(text, ',', allocator);
    var entries = try std.ArrayList(YamlValue.MapEntry).initCapacity(allocator, parts.len);
    defer entries.deinit(allocator);
    for (parts) |part| {
        const kv = trimLeftRight(part);
        const colonIdx = std.mem.indexOf(u8, kv, ":");
        if (colonIdx == null) continue;
        const key = trimLeftRight(kv[0..colonIdx.?]);
        const valText = trimLeftRight(kv[colonIdx.? + 1..]);
        const val = try parseScalar(valText, allocator);
        try entries.append(allocator, .{ .key = key, .val = val });
    }
    return YamlValue.Value.makeMap(try entries.toOwnedSlice(allocator));
}

fn parseFlowSequence(text: []const u8, allocator: std.mem.Allocator) YamlResult {
    if (text.len == 0) {
        return YamlValue.Value.makeArr(undefined);
    }
    const parts = try splitTopLevel(text, ',', allocator);
    var items = try std.ArrayList(YamlValue.Value).initCapacity(allocator, parts.len);
    defer items.deinit(allocator);
    for (parts) |part| {
        const itemText = trimLeftRight(part);
        const item = try parseScalar(itemText, allocator);
        try items.append(allocator, item);
    }
    return YamlValue.Value.makeArr(try items.toOwnedSlice(allocator));
}

fn isNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '-' or s[0] == '+') i += 1;
    var sawDigit = false;
    var sawDot = false;
    while (i < s.len) {
        if (s[i] >= '0' and s[i] <= '9') { sawDigit = true; }
        else if (s[i] == '.' and !sawDot) { sawDot = true; }
        else if (s[i] == 'e' or s[i] == 'E') {
            i += 1;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
            if (i < s.len and s[i] >= '0' and s[i] <= '9') { sawDigit = true; }
            else { return false; }
            while (i < s.len and s[i] >= '0' and s[i] <= '9') { i += 1; sawDigit = true; }
            break;
        }
        else { return false; }
        i += 1;
    }
    return sawDigit;
}

fn mapGet(val: YamlValue.Value, key: []const u8) ?YamlValue.Value {
    if (val.typ != .mapping) return null;
    var i: usize = 0;
    while (i < val.map.len) {
        if (std.mem.eql(u8, val.map[i].key, key)) return val.map[i].val;
        i += 1;
    }
    return null;
}

// ============================================================================
// Patch data structure
// ============================================================================

const Patch = struct {
    id: []const u8,
    has_id: bool,
    insert: []const YamlValue.Value,
    has_insert: bool,
    name: []const u8,
    has_name: bool,
    overrides: []const YamlValue.MapEntry,
};

const Origin = struct {
    origin: []const u8,
    patchedBy: []const []const u8,
};

// ============================================================================
// cloneYamlValue (deep clone)
// ============================================================================

fn cloneYamlValue(val: YamlValue.Value, a: std.mem.Allocator) !YamlValue.Value {
    switch (val.typ) {
        .null => return YamlValue.Value.makeNull(),
        .string => return YamlValue.Value.makeStr(val.str),
        .number => return YamlValue.Value.makeNum(val.num),
        .boolean => return YamlValue.Value.makeBool(val.bool),
        .jsExpr => return YamlValue.Value.makeJsExpr(val.str),
        .array => {
            var items = try std.ArrayList(YamlValue.Value).initCapacity(a, val.arr.len);
            defer items.deinit(a);
            for (val.arr) |item| {
                try items.append(a, try cloneYamlValue(item, a));
            }
            return YamlValue.Value.makeArr(try items.toOwnedSlice(a));
        },
        .mapping => {
            var entries = try std.ArrayList(YamlValue.MapEntry).initCapacity(a, val.map.len);
            defer entries.deinit(a);
            for (val.map) |entry| {
                try entries.append(a, .{
                    .key = entry.key,
                    .val = try cloneYamlValue(entry.val, a),
                });
            }
            return YamlValue.Value.makeMap(try entries.toOwnedSlice(a));
        }
    }
}

// ============================================================================
// applyEntryPatchesSimple: id-targeted config override + top-level insert
// ============================================================================

fn applyEntryPatchesSimple(
    entries: []const YamlValue.Value,
    patches: []const Patch,
    a: std.mem.Allocator,
) ![]const YamlValue.Value {
    var result = try std.ArrayList(YamlValue.Value).initCapacity(a, entries.len);
    defer result.deinit(a);
    for (entries) |e| {
        try result.append(a, try cloneYamlValue(e, a));
    }

    for (patches) |patch| {
        if (patch.has_insert and !patch.has_id) {
            for (patch.insert) |ins| {
                try result.append(a, try cloneYamlValue(ins, a));
            }
            continue;
        }
        if (!patch.has_id) continue;

        var found: ?usize = null;
        for (0..result.items.len) |i| {
            const e = result.items[i];
            if (e.typ == .mapping) {
                const idVal = mapGet(e, "id");
                if (idVal) |idv| {
                    if (idv.typ == .string and std.mem.eql(u8, idv.str, patch.id)) {
                        found = i;
                        break;
                    }
                }
            }
        }
        if (found == null) continue;

        const idx = found.?;
        var entry = result.items[idx];
        if (entry.typ == .mapping) {
            for (patch.overrides) |ov| {
                if (std.mem.eql(u8, ov.key, "id")) continue;
                var newEntries = try std.ArrayList(YamlValue.MapEntry).initCapacity(a, entry.map.len);
                defer newEntries.deinit(a);
                var replaced = false;
                for (entry.map) |me| {
                    if (std.mem.eql(u8, me.key, ov.key)) {
                        try newEntries.append(a, .{ .key = ov.key, .val = ov.val });
                        replaced = true;
                    } else {
                        try newEntries.append(a, me);
                    }
                }
                if (!replaced) {
                    try newEntries.append(a, .{ .key = ov.key, .val = ov.val });
                }
                const newMap = try newEntries.toOwnedSlice(a);
                entry = YamlValue.Value.makeMap(newMap);
                result.items[idx] = entry;
            }
        }
    }

    return try result.toOwnedSlice(a);
}

// ============================================================================
// Conformance input parsing
// ============================================================================

const ConformanceInput = struct {
    base: []const u8,
    layers: []const Layer,
};

const Layer = struct {
    label: []const u8,
    patches: []const Patch,
};

fn parseConformanceInput(input: []const u8, a: std.mem.Allocator) !ConformanceInput {
    var parser = JsonParser{ .s = input, .a = a };
    const jv = try jsonParseValue(&parser);
    if (jv.typ != .obj) return error.ExpectedObject;

    const baseJv = jsonObjGet(jv, "base") orelse return error.MissingBase;
    if (baseJv.typ != .str) return error.MissingBase;
    const base = baseJv.str;

    const layersJv = jsonObjGet(jv, "layers") orelse return error.MissingLayers;
    if (layersJv.typ != .arr) return error.MissingLayers;

    var layers = try std.ArrayList(Layer).initCapacity(a, layersJv.arr.len);
    defer layers.deinit(a);
    for (layersJv.arr) |layerJv| {
        if (layerJv.typ != .obj) continue;

        const labelJv = jsonObjGet(layerJv, "label") orelse continue;
        if (labelJv.typ != .str) continue;
        const label = labelJv.str;

        const patchesJv = jsonObjGet(layerJv, "patches") orelse continue;
        if (patchesJv.typ != .arr) continue;

        var patches = try std.ArrayList(Patch).initCapacity(a, patchesJv.arr.len);
        defer patches.deinit(a);
        for (patchesJv.arr) |patchJv| {
            if (patchJv.typ != .obj) continue;

            var patch = Patch{
                .id = "",
                .has_id = false,
                .insert = undefined,
                .has_insert = false,
                .name = "",
                .has_name = false,
                .overrides = undefined,
            };

            const idJv = jsonObjGet(patchJv, "id");
            if (idJv) |idv| {
                if (idv.typ == .str) {
                    patch.id = idv.str;
                    patch.has_id = true;
                }
            }

            const nameJv = jsonObjGet(patchJv, "name");
            if (nameJv) |namev| {
                if (namev.typ == .str) {
                    patch.name = namev.str;
                    patch.has_name = true;
                }
            }

            const insertJv = jsonObjGet(patchJv, "insert");
            if (insertJv) |insv| {
                if (insv.typ == .arr) {
                    var items = try std.ArrayList(YamlValue.Value).initCapacity(a, insv.arr.len);
                    defer items.deinit(a);
                    for (insv.arr) |itemJv| {
                        try items.append(a, try jsonToYaml(itemJv, a));
                    }
                    patch.insert = try items.toOwnedSlice(a);
                    patch.has_insert = true;
                }
            }

            var ovList = try std.ArrayList(YamlValue.MapEntry).initCapacity(a, 4);
            defer ovList.deinit(a);
            for (patchJv.obj) |field| {
                if (std.mem.eql(u8, field.key, "id") or
                    std.mem.eql(u8, field.key, "insert") or
                    std.mem.eql(u8, field.key, "name")) {
                    continue;
                }
                try ovList.append(a, .{
                    .key = field.key,
                    .val = try jsonToYaml(field.val, a),
                });
            }
            patch.overrides = try ovList.toOwnedSlice(a);

            try patches.append(a, patch);
        }

        try layers.append(a, Layer{
            .label = label,
            .patches = try patches.toOwnedSlice(a),
        });
    }

    return ConformanceInput{
        .base = base,
        .layers = try layers.toOwnedSlice(a),
    };
}

// ============================================================================
// YAML emitter
// ============================================================================

fn needsQuoting(s: []const u8) bool {
    if (s.len == 0) return true;
    const c = s[0];
    if (c == '-' or c == '?' or c == ':' or c == '&' or c == '*' or
        c == '!' or c == '|' or c == '>' or c == '%' or c == '@' or
        c == '`' or c == '#' or c == ',' or c == '[' or c == ']' or
        c == '{' or c == '}' or c == '"' or c == '\'') {
        return true;
    }
    if (std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "~") or
        std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) {
        return true;
    }
    if (isNumber(s)) return true;
    for (s) |ch| {
        if (ch == ':' or ch == '#' or ch == '[' or ch == ']' or
            ch == '{' or ch == '}' or ch == ',' or ch == '&' or
            ch == '*' or ch == '!' or ch == '|' or ch == '>' or
            ch == '%' or ch == '@' or ch == '`' or ch == '\n' or
            ch == '\r' or ch == '\t') {
            return true;
        }
    }
    return false;
}

fn emitString(s: []const u8, a: std.mem.Allocator) ![]const u8 {
    if (!needsQuoting(s)) {
        return s;
    }
    var buf = try std.ArrayList(u8).initCapacity(a, s.len + 4);
    defer buf.deinit(a);
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => if (c < 0x20) {
                const hi = "0123456789abcdef"[(c >> 4) & 0xf];
                const lo = "0123456789abcdef"[c & 0xf];
                try buf.appendSlice(a, "\\u00");
                try buf.appendSlice(a, &[_]u8{ hi, lo });
            } else {
                try buf.append(a, c);
            },
        }
    }
    try buf.append(a, '"');
    return try buf.toOwnedSlice(a);
}

fn emitNumber(n: f64, a: std.mem.Allocator) ![]const u8 {
    if (n == @trunc(n) and n >= -999999999 and n <= 999999999) {
        return try std.fmt.allocPrint(a, "{d}", .{@trunc(n)});
    }
    return try std.fmt.allocPrint(a, "{}", .{n});
}

fn spaces(n: usize, a: std.mem.Allocator) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(a, n);
    for (0..n) |_| { try buf.append(a, ' '); }
    return try buf.toOwnedSlice(a);
}

fn emitYamlValue(val: YamlValue.Value, a: std.mem.Allocator, indent: usize) ![]const u8 {
    switch (val.typ) {
        .null => return try std.fmt.allocPrint(a, "null", .{}),
        .boolean => if (val.bool) return try std.fmt.allocPrint(a, "true", .{}) else return try std.fmt.allocPrint(a, "false", .{}),
        .number => return emitNumber(val.num, a),
        .string => return emitString(val.str, a),
        .jsExpr => return try std.fmt.allocPrint(a, "!!js {s}", .{val.str}),
        .array => {
            var lines = try std.ArrayList([]const u8).initCapacity(a, val.arr.len);
            defer lines.deinit(a);
            for (val.arr) |item| {
                const itemYaml = try emitYamlValue(item, a, indent + 2);
                const formatted = try emitArrayItem(itemYaml, a, indent + 2);
                try lines.append(a, formatted);
            }
            return try std.mem.join(a, "\n", try lines.toOwnedSlice(a));
        },
        .mapping => {
            if (val.map.len == 1 and std.mem.eql(u8, val.map[0].key, "__jsExpr") and val.map[0].val.typ == .string) {
                return try std.fmt.allocPrint(a, "!!js {s}", .{val.map[0].val.str});
            }
            var lines = try std.ArrayList([]const u8).initCapacity(a, val.map.len);
            defer lines.deinit(a);
            for (val.map) |entry| {
                const valYaml = try emitYamlValue(entry.val, a, indent + 2);
                var buf = try std.ArrayList(u8).initCapacity(a, entry.key.len + valYaml.len + indent + 8);
                defer buf.deinit(a);
                try buf.appendSlice(a, try spaces(indent, a));
                try buf.appendSlice(a, entry.key);
                const isJsExpr = entry.val.typ == .mapping and entry.val.map.len == 1 and std.mem.eql(u8, entry.val.map[0].key, "__jsExpr") and entry.val.map[0].val.typ == .string;
                if (isJsExpr) {
                    try buf.appendSlice(a, ": !!js ");
                    try buf.appendSlice(a, entry.val.map[0].val.str);
                } else if (entry.val.typ == .mapping or entry.val.typ == .array) {
                    try buf.appendSlice(a, ":\n");
                    try buf.appendSlice(a, valYaml);
                } else {
                    try buf.appendSlice(a, ": ");
                    try buf.appendSlice(a, valYaml);
                }
                try lines.append(a, try buf.toOwnedSlice(a));
            }
            return try std.mem.join(a, "\n", try lines.toOwnedSlice(a));
        }
    }
}

fn emitYamlValueArr(items: []const YamlValue.Value, a: std.mem.Allocator) ![]const u8 {
    var lines = try std.ArrayList([]const u8).initCapacity(a, items.len);
    defer lines.deinit(a);
    for (items) |item| {
        const itemYaml = try emitYamlValue(item, a, 0);
        const formatted = try emitArrayItem(itemYaml, a, 0);
        try lines.append(a, formatted);
    }
    return try std.mem.join(a, "\n", try lines.toOwnedSlice(a));
}

// Strip `strip` leading spaces from each line of itemYaml, then prefix line 0 with "- "
// and continuation lines with "  " (2 spaces, matching the width of "- ").
fn emitArrayItem(itemYaml: []const u8, a: std.mem.Allocator, strip: usize) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(a, itemYaml.len + 16);
    var lineStart: usize = 0;
    var i: usize = 0;
    var lineIdx: usize = 0;
    while (i <= itemYaml.len) {
        if (i == itemYaml.len or itemYaml[i] == '\n') {
            const line = itemYaml[lineStart..i];
            // Strip up to `strip` leading spaces
            var s: usize = 0;
            while (s < strip and s < line.len and line[s] == ' ') s += 1;
            const content = line[s..];
            if (lineIdx == 0) {
                try out.appendSlice(a, "- ");
            } else {
                try out.appendSlice(a, "  ");
            }
            try out.appendSlice(a, content);
            if (i < itemYaml.len) {
                try out.appendSlice(a, "\n");
            }
            lineStart = i + 1;
            lineIdx += 1;
        }
        i += 1;
    }
    return try out.toOwnedSlice(a);
}

// ============================================================================
// Conformance subcommand
// ============================================================================

const ConformanceResult = struct {
    ok: bool,
    output: []const u8,
    err: []const u8,
    exitCode: usize,
    outputIsJson: bool = false,
    /// Force `exitCode` into the JSON even when 0 (cli.args error cases carry exit(0)).
    emitExitCode: bool = false,
};

fn conformance(init: std.process.Init, args: []const [:0]const u8) !void {
    if (args.len < 4) {
        try printResult(init, .{
            .ok = false,
            .err = "usage: dsh conformance <scenario-id> <input-json-file>",
            .exitCode = 2,
            .output = "",
        });
        return;
    }

    const scenarioId = args[2];
    const inputFile = args[3];

    var parts = try std.ArrayList([]const u8).initCapacity(init.gpa, 4);
    defer parts.deinit(init.gpa);
    {
        var start: usize = 0;
        var i: usize = 0;
        while (i < scenarioId.len) {
            if (scenarioId[i] == '.') {
                try parts.append(init.gpa, scenarioId[start..i]);
                start = i + 1;
            }
            i += 1;
        }
        try parts.append(init.gpa, scenarioId[start..]);
    }

    if (parts.items.len >= 3 and std.mem.eql(u8, parts.items[0], "config") and std.mem.eql(u8, parts.items[1], "patch-layering")) {
        try conformanceConfigPatchLayering(init, inputFile);
        return;
    }

    if (parts.items.len >= 3 and std.mem.eql(u8, parts.items[0], "config") and std.mem.eql(u8, parts.items[1], "slice1")) {
        try conformanceConfigPatchLayering(init, inputFile);
        return;
    }

    if (parts.items.len >= 3 and std.mem.eql(u8, parts.items[0], "session") and std.mem.eql(u8, parts.items[1], "jsonl")) {
        try conformanceSessionJsonl(init, inputFile);
        return;
    }

    if (parts.items.len >= 3 and std.mem.eql(u8, parts.items[0], "llm") and std.mem.eql(u8, parts.items[1], "sse")) {
        try conformanceLlmSse(init, inputFile);
        return;
    }

    if (parts.items.len >= 3 and std.mem.eql(u8, parts.items[0], "llm") and std.mem.eql(u8, parts.items[1], "retry")) {
        try conformanceLlmRetry(init, inputFile);
        return;
    }

    if (parts.items.len >= 3 and std.mem.eql(u8, parts.items[0], "tool") and std.mem.eql(u8, parts.items[1], "shell")) {
        try conformanceToolShell(init, inputFile);
        return;
    }

    if (parts.items.len >= 3 and std.mem.eql(u8, parts.items[0], "agent") and std.mem.eql(u8, parts.items[1], "tool-pairing")) {
        try conformanceAgentToolPairing(init, inputFile);
        return;
    }

    if (parts.items.len >= 3 and std.mem.eql(u8, parts.items[0], "cli") and std.mem.eql(u8, parts.items[1], "args")) {
        try conformanceCliArgs(init, inputFile);
        return;
    }

    if (parts.items.len >= 2 and std.mem.eql(u8, parts.items[0], "web")) {
        try conformanceWebServer(init, inputFile);
        return;
    }

    const unknownMsg = try std.fmt.allocPrint(init.gpa, "unknown scenario: {s}", .{scenarioId});
    defer init.gpa.free(unknownMsg);
    try printResult(init, .{
        .ok = false,
        .err = unknownMsg,
        .exitCode = 2,
        .output = "",
    });
}

fn conformanceConfigPatchLayering(init: std.process.Init, inputFile: [:0]const u8) !void {
    const cwd_dir = std.Io.Dir.cwd();
    const file = try cwd_dir.readFileAlloc(init.io, inputFile, init.gpa, .unlimited);
    defer init.gpa.free(file);

    const input = try parseConformanceInput(file, init.gpa);

    const baseYaml = try parseYaml(input.base, init.gpa);
    if (baseYaml.typ != .array) {
        try printResult(init, .{
            .ok = false,
            .err = "config must be a top-level YAML array of entries",
            .exitCode = 1,
            .output = "",
        });
        return;
    }

    const baseLabel = "base.yml";

    // Origins: for each entry in base, track origin label and which layers patched it
    var origins = try std.ArrayList(Origin).initCapacity(init.gpa, baseYaml.arr.len);
    for (baseYaml.arr) |_| {
        var empty = try std.ArrayList([]const u8).initCapacity(init.gpa, 0);
        try origins.append(init.gpa, .{
            .origin = baseLabel,
            .patchedBy = try empty.toOwnedSlice(init.gpa),
        });
        empty.deinit(init.gpa);
    }

    var previous = baseYaml.arr;

    for (0..input.layers.len) |count| {
        // Flatten patches from layers[0..count]
        var flatPatches = try std.ArrayList(Patch).initCapacity(init.gpa, 16);
        defer flatPatches.deinit(init.gpa);
        for (0..count + 1) |layerIdx| {
            for (input.layers[layerIdx].patches) |p| {
                try flatPatches.append(init.gpa, p);
            }
        }

        // Always compose from base (mirrors renderConfigDump's snapshot),
        // so inserts are applied exactly once per snapshot.
        const composed = try applyEntryPatchesSimple(
            baseYaml.arr,
            flatPatches.items,
            init.gpa,
        );

        // Recompute origins by comparing composed entries with previous entries
        var newOrigins = try std.ArrayList(Origin).initCapacity(init.gpa, composed.len);

        for (0..composed.len) |i| {
            const c = composed[i];
            if (i >= previous.len) {
                // New entry inserted by this layer
                var empty = try std.ArrayList([]const u8).initCapacity(init.gpa, 0);
                try newOrigins.append(init.gpa, .{
                    .origin = input.layers[count].label,
                    .patchedBy = try empty.toOwnedSlice(init.gpa),
                });
                empty.deinit(init.gpa);
            } else {
                const prevStr = try yamlToString(previous[i], init.gpa);
                const currStr = try yamlToString(c, init.gpa);
                init.gpa.free(prevStr);
                init.gpa.free(currStr);
                if (std.mem.eql(u8, prevStr, currStr)) {
                    try newOrigins.append(init.gpa, origins.items[i]);
                } else {
                    var patchedBy = try std.ArrayList([]const u8).initCapacity(init.gpa, origins.items[i].patchedBy.len + 1);
                    for (origins.items[i].patchedBy) |pb| {
                        try patchedBy.append(init.gpa, pb);
                    }
                    try patchedBy.append(init.gpa, input.layers[count].label);
                    try newOrigins.append(init.gpa, .{
                        .origin = origins.items[i].origin,
                        .patchedBy = try patchedBy.toOwnedSlice(init.gpa),
                    });
                    patchedBy.deinit(init.gpa);
                }
            }
        }

        origins.deinit(init.gpa);
        origins = newOrigins;
        previous = composed;
    }

    const dump = try groupedDump(previous, origins.items, init.gpa);
    defer init.gpa.free(dump);
    origins.deinit(init.gpa);

    try printResult(init, .{ .ok = true, .output = dump, .err = "", .exitCode = 0 });
}

fn conformanceSessionJsonl(init: std.process.Init, inputFile: [:0]const u8) !void {
    const cwd_dir = std.Io.Dir.cwd();
    const file = try cwd_dir.readFileAlloc(init.io, inputFile, init.gpa, .unlimited);
    defer init.gpa.free(file);

    var parser = JsonParser{ .s = file, .a = init.gpa };
    const input = try jsonParseValue(&parser);
    if (input.typ != .obj) return error.ExpectedObject;

    const headerJv = jsonObjGet(input, "header") orelse return error.MissingBase;
    if (headerJv.typ != .obj) return error.ExpectedObject;

    const isSeededJv = jsonObjGet(headerJv, "isSeeded") orelse return error.MissingBase;
    if (isSeededJv.typ != .bool) return error.ExpectedObject;
    const isSeeded = isSeededJv.bool;

    // inheritedEventCount is optional
    const inheritedCountJv = jsonObjGet(input, "inheritedEventCount");
    var inheritedCountF64: f64 = 0;
    var hasInheritedCount = false;
    if (inheritedCountJv) |ic| {
        if (ic.typ != .num) return error.ExpectedObject;
        inheritedCountF64 = ic.num;
        hasInheritedCount = true;
    }

    if (isSeeded and !hasInheritedCount) {
        const msg = try std.fmt.allocPrint(init.gpa, "seeded session header requires an inherited event count", .{});
        defer init.gpa.free(msg);
        try printResult(init, .{ .ok = false, .err = msg, .exitCode = 0, .output = "" });
        return;
    }
    if (!isSeeded and hasInheritedCount and inheritedCountF64 != 0) {
        const msg = try std.fmt.allocPrint(init.gpa, "unseeded session header inherited event count must be 0", .{});
        defer init.gpa.free(msg);
        try printResult(init, .{ .ok = false, .err = msg, .exitCode = 0, .output = "" });
        return;
    }

    const versionJv = jsonObjGet(headerJv, "version") orelse return error.MissingBase;
    if (versionJv.typ != .num) return error.ExpectedObject;
    const idJv = jsonObjGet(headerJv, "id") orelse return error.MissingBase;
    if (idJv.typ != .str) return error.ExpectedObject;
    const createdAtJv = jsonObjGet(headerJv, "createdAt") orelse return error.MissingBase;
    if (createdAtJv.typ != .num) return error.ExpectedObject;

    var delegationDepth: f64 = 0;
    const ddJv = jsonObjGet(headerJv, "delegationDepth");
    if (ddJv) |dd| { if (dd.typ == .num) delegationDepth = dd.num; }

    var out = try std.ArrayList(u8).initCapacity(init.gpa, 256);
    defer out.deinit(init.gpa);

    try out.appendSlice(init.gpa, "{\"type\":\"session\",\"version\":");
    try out.appendSlice(init.gpa, try emitNumber(versionJv.num, init.gpa));
    try out.appendSlice(init.gpa, ",\"id\":\"");
    try appendEscapedStr(init.gpa, &out, idJv.str);
    try out.appendSlice(init.gpa, "\",\"createdAt\":");
    try out.appendSlice(init.gpa, try emitNumber(createdAtJv.num, init.gpa));

    const cwdJv = jsonObjGet(headerJv, "cwd");
    if (cwdJv) |cw| {
        if (cw.typ == .str) {
            try out.appendSlice(init.gpa, ",\"cwd\":\"");
            try appendEscapedStr(init.gpa, &out, cw.str);
            try out.appendSlice(init.gpa, "\"");
        }
    }

    try out.appendSlice(init.gpa, ",\"isSeeded\":");
    if (isSeeded) { try out.appendSlice(init.gpa, "true"); } else { try out.appendSlice(init.gpa, "false"); }

    try out.appendSlice(init.gpa, ",\"delegationDepth\":");
    try out.appendSlice(init.gpa, try emitNumber(delegationDepth, init.gpa));

    try out.appendSlice(init.gpa, "}");

    const output = try out.toOwnedSlice(init.gpa);
    defer init.gpa.free(output);

    try printResult(init, .{ .ok = true, .output = output, .err = "", .exitCode = 0, .outputIsJson = true });
}

const LlmClassification = struct {
    message: []const u8,
    code: []const u8,
    status: ?usize,
};

fn classifyLlmError(raw: JsonValue, status: ?f64, a: std.mem.Allocator) !LlmClassification {
    var errorObj: ?JsonValue = null;
    if (raw.typ == .obj) {
        errorObj = jsonObjGet(raw, "error");
    }

    var message: []const u8 = "";
    var errType: []const u8 = "";

    if (errorObj) |eo| {
        if (eo.typ == .obj) {
            const msgJv = jsonObjGet(eo, "message");
            if (msgJv) |m| { if (m.typ == .str) message = m.str; }
            const typeJv = jsonObjGet(eo, "type");
            if (typeJv) |t| { if (t.typ == .str) errType = t.str; }
        }
    }

    if (message.len == 0) {
        if (status) |s| {
            message = try std.fmt.allocPrint(a, "DeepSeek Messages request failed ({d})", .{@trunc(s)});
        } else {
            message = try std.fmt.allocPrint(a, "DeepSeek Messages request failed (stream error)", .{});
        }
    }

    var statusUsize: ?usize = null;
    if (status) |s| {
        statusUsize = @trunc(s);
    }

    var code: []const u8 = "SERVER";
    const s = statusUsize;
    const su = if (statusUsize) |v| v else 0;
    if (s == 401 or s == 403 or std.mem.eql(u8, errType, "authentication_error") or std.mem.eql(u8, errType, "permission_error")) {
        code = "AUTH";
    } else if (s == 429 or std.mem.eql(u8, errType, "rate_limit_error")) {
        code = "RATE_LIMIT";
    } else if (s == 400 or s == 413 or std.mem.eql(u8, errType, "invalid_request_error")) {
        code = "INVALID_REQUEST";
    } else if (su >= 500 or std.mem.eql(u8, errType, "api_error") or std.mem.eql(u8, errType, "overloaded_error")) {
        code = "SERVER";
    } else if (s == null) {
        code = "SERVER";
    } else {
        code = try std.fmt.allocPrint(a, "HTTP_{d}", .{su});
    }

    return LlmClassification{ .message = message, .code = code, .status = statusUsize };
}

fn buildLlmErrorJson(classification: LlmClassification, a: std.mem.Allocator) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(a, 256);
    defer buf.deinit(a);

    try buf.appendSlice(a, "{\"code\":\"");
    try appendEscapedStr(a, &buf, classification.code);
    try buf.appendSlice(a, "\",\"name\":\"LlmError\",\"failure\":{\"message\":\"");
    try appendEscapedStr(a, &buf, classification.message);
    try buf.appendSlice(a, "\",\"code\":\"");
    try appendEscapedStr(a, &buf, classification.code);
    try buf.appendSlice(a, "\"");
    if (classification.status) |st| {
        try buf.appendSlice(a, ",\"status\":");
        try buf.appendSlice(a, try emitNumber(@floatFromInt(st), a));
    }
    try buf.appendSlice(a, "}}");

    return try buf.toOwnedSlice(a);
}

fn jsonValueToCompact(jv: JsonValue, a: std.mem.Allocator) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(a, 64);
    defer buf.deinit(a);
    try appendJsonCompact(&buf, jv, a);
    return try buf.toOwnedSlice(a);
}

fn appendJsonCompact(buf: *std.ArrayList(u8), jv: JsonValue, a: std.mem.Allocator) !void {
    switch (jv.typ) {
        .null => try buf.appendSlice(a, "null"),
        .bool => if (jv.bool) try buf.appendSlice(a, "true") else try buf.appendSlice(a, "false"),
        .num => {
            const s = try emitNumber(jv.num, a);
            try buf.appendSlice(a, s);
        },
        .str => {
            try buf.appendSlice(a, "\"");
            try appendEscapedStr(a, buf, jv.str);
            try buf.appendSlice(a, "\"");
        },
        .arr => {
            try buf.appendSlice(a, "[");
            for (0..jv.arr.len) |i| {
                if (i > 0) try buf.appendSlice(a, ",");
                try appendJsonCompact(buf, jv.arr[i], a);
            }
            try buf.appendSlice(a, "]");
        },
        .obj => {
            try buf.appendSlice(a, "{");
            for (0..jv.obj.len) |i| {
                const field = jv.obj[i];
                if (i > 0) try buf.appendSlice(a, ",");
                try buf.appendSlice(a, "\"");
                try appendEscapedStr(a, buf, field.key);
                try buf.appendSlice(a, "\":");
                try appendJsonCompact(buf, field.val, a);
            }
            try buf.appendSlice(a, "}");
        },
    }
}

fn conformanceLlmSse(init: std.process.Init, inputFile: [:0]const u8) !void {
    const cwd_dir = std.Io.Dir.cwd();
    const file = try cwd_dir.readFileAlloc(init.io, inputFile, init.gpa, .unlimited);
    defer init.gpa.free(file);

    var parser = JsonParser{ .s = file, .a = init.gpa };
    const input = try jsonParseValue(&parser);
    if (input.typ != .obj) return error.ExpectedObject;

    const framesJv = jsonObjGet(input, "frames") orelse return error.MissingBase;
    if (framesJv.typ != .arr) return error.ExpectedObject;

    const eventTypeJv = jsonObjGet(input, "eventType");
    var eventType: []const u8 = "";
    var hasEventType = false;
    if (eventTypeJv) |et| {
        if (et.typ == .str) {
            eventType = et.str;
            hasEventType = true;
        }
    }

    var events = try std.ArrayList([]const u8).initCapacity(init.gpa, framesJv.arr.len);
    defer events.deinit(init.gpa);

    for (framesJv.arr) |frameJv| {
        if (frameJv.typ != .str) continue;
        const frame = frameJv.str;

        if (frame.len > 0 and frame[0] == ':') {
            continue;
        }

        if (std.mem.startsWith(u8, frame, "data: ")) {
            const dataStr = frame[6..];
            var dataParser = JsonParser{ .s = dataStr, .a = init.gpa };
            const dataVal = jsonParseValue(&dataParser) catch {
                const msg = try std.fmt.allocPrint(init.gpa, "DeepSeek Messages SSE contains invalid JSON", .{});
                defer init.gpa.free(msg);
                try printResult(init, .{ .ok = false, .err = msg, .exitCode = 0, .output = "" });
                return;
            };

            if (dataVal.typ != .obj) {
                const msg = try std.fmt.allocPrint(init.gpa, "DeepSeek Messages expected a JSON object", .{});
                defer init.gpa.free(msg);
                try printResult(init, .{ .ok = false, .err = msg, .exitCode = 0, .output = "" });
                return;
            }

            const typeJv = jsonObjGet(dataVal, "type");
            if (typeJv) |tj| {
                if (tj.typ == .str and hasEventType and !std.mem.eql(u8, tj.str, eventType)) {
                    const msg = try std.fmt.allocPrint(init.gpa, "DeepSeek Messages SSE event type mismatch", .{});
                    defer init.gpa.free(msg);
                    try printResult(init, .{ .ok = false, .err = msg, .exitCode = 0, .output = "" });
                    return;
                }
                if (tj.typ == .str and std.mem.eql(u8, tj.str, "error")) {
                    const classification = try classifyLlmError(dataVal, null, init.gpa);
                    defer init.gpa.free(classification.message);
                    defer init.gpa.free(classification.code);
                    try printResult(init, .{ .ok = false, .err = classification.message, .exitCode = 0, .output = "" });
                    return;
                }
            }

            const eventJson = try jsonValueToCompact(dataVal, init.gpa);
            try events.append(init.gpa, eventJson);
        }
    }

    var out = try std.ArrayList(u8).initCapacity(init.gpa, 256);
    defer out.deinit(init.gpa);

    try out.appendSlice(init.gpa, "{\"events\":[");
    for (0..events.items.len) |i| {
        if (i > 0) try out.appendSlice(init.gpa, ",");
        try out.appendSlice(init.gpa, events.items[i]);
    }
    try out.appendSlice(init.gpa, "],\"activityCalls\":0}");

    const output = try out.toOwnedSlice(init.gpa);
    defer init.gpa.free(output);

    // Free the event JSON strings now that their contents are copied into `out`.
    for (events.items) |es| {
        init.gpa.free(es);
    }

    try printResult(init, .{ .ok = true, .output = output, .err = "", .exitCode = 0, .outputIsJson = true });
}

fn conformanceLlmRetry(init: std.process.Init, inputFile: [:0]const u8) !void {
    const cwd_dir = std.Io.Dir.cwd();
    const file = try cwd_dir.readFileAlloc(init.io, inputFile, init.gpa, .unlimited);
    defer init.gpa.free(file);

    var parser = JsonParser{ .s = file, .a = init.gpa };
    const input = try jsonParseValue(&parser);
    if (input.typ != .obj) return error.ExpectedObject;

    // Get status
    var status: ?f64 = null;
    const statusJv = jsonObjGet(input, "status");
    if (statusJv) |sj| { if (sj.typ == .num) status = sj.num; }

    // Get raw message and type from input.raw.error, or fall back to input.code/input.message
    var rawMsg: []const u8 = "";
    var rawType: []const u8 = "";

    const rawJv = jsonObjGet(input, "raw");
    if (rawJv) |rj| {
        if (rj.typ == .obj) {
            const errorJv = jsonObjGet(rj, "error") orelse null;
            if (errorJv) |ej| {
                if (ej.typ == .obj) {
                    const msgJv = jsonObjGet(ej, "message");
                    if (msgJv) |m| { if (m.typ == .str) rawMsg = m.str; }
                    const typeJv = jsonObjGet(ej, "type");
                    if (typeJv) |t| { if (t.typ == .str) rawType = t.str; }
                }
            }
        }
    } else {
        const msgJv = jsonObjGet(input, "message");
        if (msgJv) |m| { if (m.typ == .str) rawMsg = m.str; }
        const codeJv = jsonObjGet(input, "code");
        if (codeJv) |c| { if (c.typ == .str) rawType = c.str; }
    }

    // Build default message if none provided
    var message: []const u8 = rawMsg;
    if (message.len == 0) {
        if (status) |s| {
            message = try std.fmt.allocPrint(init.gpa, "DeepSeek Messages request failed ({d})", .{@trunc(s)});
        } else {
            message = try std.fmt.allocPrint(init.gpa, "DeepSeek Messages request failed (stream error)", .{});
        }
    }

    var statusUsize: ?usize = null;
    if (status) |s| {
        statusUsize = @trunc(s);
    }

    // Classify code (same logic as Node providerError)
    var code: []const u8 = "SERVER";
    const s = statusUsize;
    const su = if (statusUsize) |v| v else 0;
    if (s == 401 or s == 403 or std.mem.eql(u8, rawType, "authentication_error") or std.mem.eql(u8, rawType, "permission_error")) {
        code = "AUTH";
    } else if (s == 429 or std.mem.eql(u8, rawType, "rate_limit_error")) {
        code = "RATE_LIMIT";
    } else if (s == 400 or s == 413 or std.mem.eql(u8, rawType, "invalid_request_error")) {
        code = "INVALID_REQUEST";
    } else if (su >= 500 or std.mem.eql(u8, rawType, "api_error") or std.mem.eql(u8, rawType, "overloaded_error")) {
        code = "SERVER";
    } else if (s == null) {
        code = "SERVER";
    } else {
        code = try std.fmt.allocPrint(init.gpa, "HTTP_{d}", .{su});
    }

    // Build LlmError JSON output
    var buf = try std.ArrayList(u8).initCapacity(init.gpa, 256);
    defer buf.deinit(init.gpa);

    try buf.appendSlice(init.gpa, "{\"code\":\"");
    try appendEscapedStr(init.gpa, &buf, code);
    try buf.appendSlice(init.gpa, "\",\"name\":\"LlmError\",\"failure\":{\"message\":\"");
    try appendEscapedStr(init.gpa, &buf, message);
    try buf.appendSlice(init.gpa, "\",\"code\":\"");
    try appendEscapedStr(init.gpa, &buf, code);
    try buf.appendSlice(init.gpa, "\"");
    if (statusUsize) |st| {
        try buf.appendSlice(init.gpa, ",\"status\":");
        try buf.appendSlice(init.gpa, try emitNumber(@floatFromInt(st), init.gpa));
    }
    try buf.appendSlice(init.gpa, "}}");

    const output = try buf.toOwnedSlice(init.gpa);
    defer init.gpa.free(output);

    try printResult(init, .{ .ok = true, .output = output, .err = "", .exitCode = 0, .outputIsJson = true });
}

fn conformanceToolShell(init: std.process.Init, inputFile: [:0]const u8) !void {
    const cwd_dir = std.Io.Dir.cwd();
    const file = try cwd_dir.readFileAlloc(init.io, inputFile, init.gpa, .unlimited);
    defer init.gpa.free(file);

    var parser = JsonParser{ .s = file, .a = init.gpa };
    const input = try jsonParseValue(&parser);
    if (input.typ != .obj) return error.ExpectedObject;

    const argvJv = jsonObjGet(input, "argv") orelse return error.MissingArgv;
    if (argvJv.typ != .arr) return error.ExpectedArray;

    var argv = try std.ArrayList([]const u8).initCapacity(init.gpa, argvJv.arr.len);
    defer argv.deinit(init.gpa);
    for (argvJv.arr) |argJv| {
        if (argJv.typ != .str) continue;
        try argv.append(init.gpa, argJv.str);
    }
    if (argv.items.len == 0) {
        const msg = try std.fmt.allocPrint(init.gpa, "tool.shell: argv must be non-empty", .{});
        defer init.gpa.free(msg);
        try printResult(init, .{ .ok = false, .err = msg, .exitCode = 1, .output = "" });
        return;
    }

    var cwd: std.process.Child.Cwd = .inherit;
    const cwdJv = jsonObjGet(input, "cwd");
    if (cwdJv) |cwdVal| {
        if (cwdVal.typ == .str) {
            cwd = .{ .path = cwdVal.str };
        }
    }

    const argvSlice = try argv.toOwnedSlice(init.gpa);
    defer init.gpa.free(argvSlice);

    const runResult = try std.process.run(init.gpa, init.io, .{
        .argv = argvSlice,
        .cwd = cwd,
    });

    var out = try std.ArrayList(u8).initCapacity(init.gpa, 256);
    defer out.deinit(init.gpa);

    try out.appendSlice(init.gpa, "{\"stdout\":\"");
    try appendEscapedStr(init.gpa, &out, runResult.stdout);
    try out.appendSlice(init.gpa, "\",\"stderr\":\"");
    try appendEscapedStr(init.gpa, &out, runResult.stderr);
    try out.appendSlice(init.gpa, "\",\"exitCode\":");

    const exitCode: ?u8 = switch (runResult.term) {
        .exited => |code| code,
        else => null,
    };
    if (exitCode) |code| {
        const exitCodeStr = try std.fmt.allocPrint(init.gpa, "{d}", .{code});
        defer init.gpa.free(exitCodeStr);
        try out.appendSlice(init.gpa, exitCodeStr);
    } else {
        try out.appendSlice(init.gpa, "null");
    }
    try out.appendSlice(init.gpa, "}");

    const output = try out.toOwnedSlice(init.gpa);
    defer init.gpa.free(runResult.stdout);
    defer init.gpa.free(runResult.stderr);
    defer init.gpa.free(output);

    try printResult(init, .{ .ok = true, .output = output, .err = "", .exitCode = 0, .outputIsJson = true });
}

// ============================================================================
// Agent loop — tool-history pairing (turn boundaries for compaction safe cuts)
// Mirrors @deepseek-ai/dsh-compaction's toolPairingBalancedBefore/After.
// ============================================================================

fn eventDelta(ev: JsonValue) i32 {
    if (ev.typ != .obj) return 0;
    const typeJv = jsonObjGet(ev, "type");
    if (typeJv) |tj| {
        if (tj.typ == .str) {
            if (std.mem.eql(u8, tj.str, "assistant/message")) {
                var count: i32 = 0;
                const dataJv = jsonObjGet(ev, "data");
                if (dataJv) |dj| {
                    if (dj.typ == .obj) {
                        const msgJv = jsonObjGet(dj, "message");
                        if (msgJv) |mj| {
                            if (mj.typ == .obj) {
                                const contentJv = jsonObjGet(mj, "content");
                                if (contentJv) |cj| {
                                    if (cj.typ == .arr) {
                                        for (cj.arr) |block| {
                                            if (block.typ != .obj) continue;
                                            const bt = jsonObjGet(block, "type");
                                            if (bt) |bts| {
                                                if (bts.typ == .str and std.mem.eql(u8, bts.str, "tool-call")) {
                                                    count += 1;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                return count;
            }
            if (std.mem.eql(u8, tj.str, "tool/result")) {
                return -1;
            }
        }
    }
    return 0;
}

fn findSeqPosition(seqs: []const usize, seq: usize) ?usize {
    for (0..seqs.len) |i| {
        if (seqs[i] == seq) return i;
    }
    return null;
}

fn conformanceAgentToolPairing(init: std.process.Init, inputFile: [:0]const u8) !void {
    const cwd_dir = std.Io.Dir.cwd();
    const file = try cwd_dir.readFileAlloc(init.io, inputFile, init.gpa, .unlimited);
    defer init.gpa.free(file);

    var parser = JsonParser{ .s = file, .a = init.gpa };
    const input = try jsonParseValue(&parser);
    if (input.typ != .obj) return error.ExpectedObject;

    const surfaceNodesJv = jsonObjGet(input, "surfaceNodes") orelse return error.MissingArgv;
    const eventsJv = jsonObjGet(input, "events") orelse return error.MissingArgv;
    const queriesJv = jsonObjGet(input, "queries") orelse return error.MissingArgv;
    if (surfaceNodesJv.typ != .arr or eventsJv.typ != .arr or queriesJv.typ != .arr)
        return error.ExpectedArray;

    var surfaceSeqs = try std.ArrayList(usize).initCapacity(init.gpa, surfaceNodesJv.arr.len);
    defer surfaceSeqs.deinit(init.gpa);
    var surfaceEvents = try std.ArrayList(JsonValue).initCapacity(init.gpa, eventsJv.arr.len);
    defer surfaceEvents.deinit(init.gpa);

    for (surfaceNodesJv.arr) |sn| {
        if (sn.typ == .num) try surfaceSeqs.append(init.gpa, @as(usize, @intFromFloat(sn.num)));
    }
    for (eventsJv.arr) |ev| {
        try surfaceEvents.append(init.gpa, ev);
    }

    // Fold the surface: cutBalanced[k] = cut before surface position k is balanced.
    // cutBalanced[0] = true (cut before the first node, always balanced).
    var cutBalanced = try std.ArrayList(bool).initCapacity(init.gpa, surfaceSeqs.items.len + 1);
    defer cutBalanced.deinit(init.gpa);
    try cutBalanced.append(init.gpa, true);

    var foldErr: ?[]const u8 = null;
    var hasFoldErr = false;
    var inProgress: i32 = 0;
    for (0..surfaceSeqs.items.len) |i| {
        const seq = surfaceSeqs.items[i];
        const ev = surfaceEvents.items[i];
        const evSeqJv = jsonObjGet(ev, "seq");
        if (evSeqJv) |esj| {
            if (esj.typ == .num and @as(usize, @intFromFloat(esj.num)) != seq) {
                foldErr = try std.fmt.allocPrint(init.gpa, "tool-pairing balance: surface seq {d} has no matching session event", .{seq});
                hasFoldErr = true;
                break;
            }
        }
        inProgress += eventDelta(ev);
        if (inProgress < 0) {
            foldErr = try std.fmt.allocPrint(init.gpa, "tool-pairing balance: tool/result at surface seq {d} has no matching tool-call (corrupt surface)", .{seq});
            hasFoldErr = true;
            break;
        }
        try cutBalanced.append(init.gpa, inProgress == 0);
    }

    // Emit one result object per query. A fold error applies to every query.
    var out = try std.ArrayList(u8).initCapacity(init.gpa, 64 * queriesJv.arr.len);
    defer out.deinit(init.gpa);
    try out.appendSlice(init.gpa, "[");
    for (0..queriesJv.arr.len) |qi| {
        if (qi > 0) try out.appendSlice(init.gpa, ",");
        const q = queriesJv.arr[qi];
        if (hasFoldErr) {
            try out.appendSlice(init.gpa, "{\"error\":\"");
            try appendEscapedStr(init.gpa, &out, foldErr.?);
            try out.appendSlice(init.gpa, "\"}");
            continue;
        }
        if (q.typ != .obj) {
            try out.appendSlice(init.gpa, "{\"error\":\"malformed query\"}");
            continue;
        }
        const qseqJv = jsonObjGet(q, "seq");
        const qkindJv = jsonObjGet(q, "kind");
        var seq: ?usize = null;
        if (qseqJv) |sj| { if (sj.typ == .num) seq = @as(usize, @intFromFloat(sj.num)); }
        var kind: []const u8 = "";
        if (qkindJv) |kj| { if (kj.typ == .str) kind = kj.str; }

        if (seq) |s| {
            const pos = findSeqPosition(surfaceSeqs.items, s);
            if (pos) |p| {
                var balanced: bool = false;
                if (std.mem.eql(u8, kind, "before")) {
                    balanced = cutBalanced.items[p];
                } else if (std.mem.eql(u8, kind, "after")) {
                    balanced = cutBalanced.items[p + 1];
                }
                try out.appendSlice(init.gpa, "{\"balanced\":");
                if (balanced) {
                    try out.appendSlice(init.gpa, "true");
                } else {
                    try out.appendSlice(init.gpa, "false");
                }
                try out.appendSlice(init.gpa, "}");
            } else {
                const msg = try std.fmt.allocPrint(init.gpa, "tool-pairing balance: surface seq {d} not found", .{s});
                defer init.gpa.free(msg);
                try out.appendSlice(init.gpa, "{\"error\":\"");
                try appendEscapedStr(init.gpa, &out, msg);
                try out.appendSlice(init.gpa, "\"}");
            }
        } else {
            try out.appendSlice(init.gpa, "{\"error\":\"tool-pairing balance: missing seq\"}");
        }
    }
    try out.appendSlice(init.gpa, "]");
    if (foldErr) |feb| init.gpa.free(feb);

    const output = try out.toOwnedSlice(init.gpa);
    defer init.gpa.free(output);
    try printResult(init, .{ .ok = true, .output = output, .err = "", .exitCode = 0, .outputIsJson = true });
}

// ============================================================================
// CLI args — launcher flag parsing (mirrors apps/cli/src/args.ts parseDshArgs)
// Launcher flags come first and end at the first unrecognized token; everything
// after belongs to the booted app verbatim. Errors/help/version exit in-process.
// ============================================================================

const CliParse = struct {
    ok: bool,
    // success output JSON (compact), only valid when ok == true
    output: []const u8 = "",
    // exit code for help/version/error exits, only valid when ok == false
    exit_code: usize = 0,
};

fn cliExitResult(init: std.process.Init, code: usize) !void {
    const errStr = try std.fmt.allocPrint(init.gpa, "exit({d})", .{code});
    defer init.gpa.free(errStr);
    try printResult(init, .{ .ok = false, .err = errStr, .exitCode = code, .output = "", .emitExitCode = true });
}

fn cliEmitStrArray(a: std.mem.Allocator, buf: *std.ArrayList(u8), items: []const []const u8) !void {
    try buf.appendSlice(a, "[");
    for (0..items.len) |i| {
        if (i > 0) try buf.appendSlice(a, ",");
        try buf.appendSlice(a, "\"");
        try appendEscapedStr(a, buf, items[i]);
        try buf.appendSlice(a, "\"");
    }
    try buf.appendSlice(a, "]");
}

fn cliAppendStrField(a: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, val: []const u8) !void {
    try buf.appendSlice(a, "\"");
    try appendEscapedStr(a, buf, key);
    try buf.appendSlice(a, "\":\"");
    try appendEscapedStr(a, buf, val);
    try buf.appendSlice(a, "\"");
}

fn conformanceCliArgs(init: std.process.Init, inputFile: [:0]const u8) !void {
    const cwd_dir = std.Io.Dir.cwd();
    const file = try cwd_dir.readFileAlloc(init.io, inputFile, init.gpa, .unlimited);
    defer init.gpa.free(file);

    var parser = JsonParser{ .s = file, .a = init.gpa };
    const input = try jsonParseValue(&parser);
    if (input.typ != .obj) return error.ExpectedObject;

    const argvJv = jsonObjGet(input, "argv") orelse return error.MissingArgv;
    if (argvJv.typ != .arr) return error.ExpectedArray;

    var argv = try std.ArrayList([]const u8).initCapacity(init.gpa, argvJv.arr.len);
    defer argv.deinit(init.gpa);
    for (argvJv.arr) |item| {
        if (item.typ == .str) try argv.append(init.gpa, item.str);
    }
    const tokens = argv.items;

    // `dsh plugin ...` dispatches to the plugin subcommand.
    if (tokens.len > 0 and std.mem.eql(u8, tokens[0], "plugin")) {
        try cliParsePlugin(init, tokens[1..]);
        return;
    }

    // `dsh <name>` abbreviates `dsh --profile <name>`: a leading bare token that
    // is not an option and not "plugin" is expanded to --profile.
    var expanded = try std.ArrayList([]const u8).initCapacity(init.gpa, tokens.len + 1);
    defer expanded.deinit(init.gpa);
    if (tokens.len > 0 and tokens[0].len > 0 and tokens[0][0] != '-') {
        try expanded.append(init.gpa, "--profile");
        for (tokens) |t| try expanded.append(init.gpa, t);
    } else {
        for (tokens) |t| try expanded.append(init.gpa, t);
    }
    try cliParseMain(init, expanded.items);
}

fn cliParseMain(init: std.process.Init, tokens: []const []const u8) !void {
    var profile: ?[]const u8 = null;
    var fromDefault: ?[]const u8 = null;
    var patches = try std.ArrayList([]const u8).initCapacity(init.gpa, 4);
    defer patches.deinit(init.gpa);
    var dumpConfig = false;
    var dumpDefault = false;
    var dumpSchema = false;

    var args: []const []const u8 = &.{};
    var i: usize = 0;
    while (i < tokens.len) {
        const tok = tokens[i];
        if (std.mem.eql(u8, tok, "--profile")) {
            if (profile != null) return cliExitResult(init, 1); // select a profile only once
            if (i + 1 >= tokens.len) return cliExitResult(init, 1);
            profile = tokens[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, tok, "--from-default-profile")) {
            if (i + 1 >= tokens.len) return cliExitResult(init, 1);
            fromDefault = tokens[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, tok, "--patch")) {
            if (i + 1 >= tokens.len) return cliExitResult(init, 1);
            try patches.append(init.gpa, tokens[i + 1]);
            i += 2;
        } else if (std.mem.eql(u8, tok, "--dump-config")) {
            dumpConfig = true;
            i += 1;
        } else if (std.mem.eql(u8, tok, "--dump-default-config")) {
            dumpDefault = true;
            i += 1;
        } else if (std.mem.eql(u8, tok, "--dump-config-schema")) {
            dumpSchema = true;
            i += 1;
        } else if (std.mem.eql(u8, tok, "-V") or std.mem.eql(u8, tok, "--version")) {
            return cliExitResult(init, 0); // version prints and exits 0
        } else {
            // First unrecognized token: it and everything after belong to the app.
            args = tokens[i..];
            break;
        }
    }

    // action: no profile selected.
    if (profile == null) {
        for (args) |a| {
            if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) return cliExitResult(init, 0);
        }
        return cliExitResult(init, 1); // --profile <name> is required
    }
    const p = profile.?;
    if (p.len == 0) return cliExitResult(init, 1); // --profile needs a name
    if (std.ascii.eqlIgnoreCase(p, "desktop")) return cliExitResult(init, 1); // reserved for Electron

    // resolveBoot
    for (patches.items) |pt| {
        if (pt.len == 0) return cliExitResult(init, 1); // --patch needs a path
    }
    if (fromDefault) |fd| {
        if (fd.len == 0) return cliExitResult(init, 1); // --from-default-profile needs a name
    }
    var dumpCount: usize = 0;
    if (dumpConfig) dumpCount += 1;
    if (dumpDefault) dumpCount += 1;
    if (dumpSchema) dumpCount += 1;

    var out = try std.ArrayList(u8).initCapacity(init.gpa, 128);
    defer out.deinit(init.gpa);

    if (dumpCount == 0) {
        // profile mode
        try out.appendSlice(init.gpa, "{\"mode\":\"profile\",\"profile\":");
        try out.appendSlice(init.gpa, "\"");
        try appendEscapedStr(init.gpa, &out, p);
        try out.appendSlice(init.gpa, "\"");
        if (fromDefault) |fd| {
            try out.appendSlice(init.gpa, ",\"fromDefaultProfile\":\"");
            try appendEscapedStr(init.gpa, &out, fd);
            try out.appendSlice(init.gpa, "\"");
        }
        try out.appendSlice(init.gpa, ",\"patches\":");
        try cliEmitStrArray(init.gpa, &out, patches.items);
        try out.appendSlice(init.gpa, ",\"args\":");
        try cliEmitStrArray(init.gpa, &out, args);
        try out.appendSlice(init.gpa, "}");
    } else if (dumpCount > 1) {
        return cliExitResult(init, 1); // mutually exclusive dump flags
    } else {
        if (args.len > 0) return cliExitResult(init, 1); // config dumps take no app arguments
        if (dumpSchema) {
            try out.appendSlice(init.gpa, "{\"mode\":\"dump-config-schema\",\"profile\":\"");
            try appendEscapedStr(init.gpa, &out, p);
            try out.appendSlice(init.gpa, "\"");
            if (fromDefault) |fd| {
                try out.appendSlice(init.gpa, ",\"fromDefaultProfile\":\"");
                try appendEscapedStr(init.gpa, &out, fd);
                try out.appendSlice(init.gpa, "\"");
            }
            try out.appendSlice(init.gpa, ",\"patches\":");
            try cliEmitStrArray(init.gpa, &out, patches.items);
            try out.appendSlice(init.gpa, "}");
        } else {
            const defaultOnly = dumpDefault;
            if (defaultOnly and patches.items.len > 0) return cliExitResult(init, 1); // takes no --patch
            try out.appendSlice(init.gpa, "{\"mode\":\"dump-config\",\"profile\":\"");
            try appendEscapedStr(init.gpa, &out, p);
            try out.appendSlice(init.gpa, "\"");
            if (fromDefault) |fd| {
                try out.appendSlice(init.gpa, ",\"fromDefaultProfile\":\"");
                try appendEscapedStr(init.gpa, &out, fd);
                try out.appendSlice(init.gpa, "\"");
            }
            try out.appendSlice(init.gpa, ",\"defaultOnly\":");
            if (defaultOnly) {
                try out.appendSlice(init.gpa, "true");
            } else {
                try out.appendSlice(init.gpa, "false");
            }
            try out.appendSlice(init.gpa, ",\"patches\":");
            try cliEmitStrArray(init.gpa, &out, patches.items);
            try out.appendSlice(init.gpa, "}");
        }
    }

    const output = try out.toOwnedSlice(init.gpa);
    defer init.gpa.free(output);
    try printResult(init, .{ .ok = true, .output = output, .err = "", .exitCode = 0, .outputIsJson = true });
}

fn cliParsePlugin(init: std.process.Init, tokens: []const []const u8) !void {
    var profile: ?[]const u8 = null;
    var args: []const []const u8 = &.{};
    var i: usize = 0;
    while (i < tokens.len) {
        const tok = tokens[i];
        if (std.mem.eql(u8, tok, "--profile")) {
            if (profile != null) return cliExitResult(init, 1);
            if (i + 1 >= tokens.len) return cliExitResult(init, 1);
            profile = tokens[i + 1];
            i += 2;
        } else {
            args = tokens[i..];
            break;
        }
    }
    // requiredOption --profile
    if (profile == null) return cliExitResult(init, 1);
    const p = profile.?;
    if (p.len == 0) return cliExitResult(init, 1); // --profile needs a name
    if (std.ascii.eqlIgnoreCase(p, "desktop")) return cliExitResult(init, 1); // reserved (manageDesktopProfile=false)
    if (args.len == 0) return cliExitResult(init, 1); // plugin needs pnpm arguments

    var out = try std.ArrayList(u8).initCapacity(init.gpa, 64);
    defer out.deinit(init.gpa);
    try out.appendSlice(init.gpa, "{\"mode\":\"plugin\",\"profile\":\"");
    try appendEscapedStr(init.gpa, &out, p);
    try out.appendSlice(init.gpa, "\",\"args\":");
    try cliEmitStrArray(init.gpa, &out, args);
    try out.appendSlice(init.gpa, "}");

    const output = try out.toOwnedSlice(init.gpa);
    defer init.gpa.free(output);
    try printResult(init, .{ .ok = true, .output = output, .err = "", .exitCode = 0, .outputIsJson = true });
}

fn appendEscapedStr(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '"') { try buf.appendSlice(a, "\\\""); }
        else if (c == '\\') { try buf.appendSlice(a, "\\\\"); }
        else if (c == '\n') { try buf.appendSlice(a, "\\n"); }
        else if (c == '\r') { try buf.appendSlice(a, "\\r"); }
        else if (c == '\t') { try buf.appendSlice(a, "\\t"); }
        else { try buf.appendSlice(a, s[i..i + 1]); }
        i += 1;
    }
}

fn yamlToString(val: YamlValue.Value, a: std.mem.Allocator) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(a, 64);
    defer buf.deinit(a);
    try appendYamlVal(&buf, val, a, 0);
    return try buf.toOwnedSlice(a);
}

fn appendYamlVal(buf: *std.ArrayList(u8), val: YamlValue.Value, a: std.mem.Allocator, indent: usize) !void {
    switch (val.typ) {
        .null => try buf.appendSlice(a, "null"),
        .boolean => if (val.bool) try buf.appendSlice(a, "true") else try buf.appendSlice(a, "false"),
        .number => {
            const s = try emitNumber(val.num, a);
            try buf.appendSlice(a, s);
        },
        .string => try buf.appendSlice(a, val.str),
        .jsExpr => {
            try buf.appendSlice(a, "!!js ");
            try buf.appendSlice(a, val.str);
        },
        .array => {
            for (val.arr) |item| {
                try buf.appendSlice(a, "-");
                try appendYamlVal(buf, item, a, indent + 2);
            }
        },
        .mapping => {
            for (val.map) |entry| {
                try buf.appendSlice(a, entry.key);
                try buf.appendSlice(a, ":");
                try appendYamlVal(buf, entry.val, a, indent + 2);
            }
        }
    }
}

fn groupedDump(
    composed: []const YamlValue.Value,
    origins: []const Origin,
    a: std.mem.Allocator,
) ![]const u8 {
    var lines = try std.ArrayList([]const u8).initCapacity(a, composed.len + 8);
    defer lines.deinit(a);

    var currentLabel: []const u8 = "";
    var hasCurrent = false;
    var groupArr = try std.ArrayList(YamlValue.Value).initCapacity(a, 4);
    defer groupArr.deinit(a);

    for (0..composed.len) |i| {
        const entry = composed[i];
        const label = try buildLabel(origins[i], a);
        if (!hasCurrent or !std.mem.eql(u8, currentLabel, label)) {
            if (hasCurrent) {
                try flushGroup(&lines, &groupArr, currentLabel, a);
            }
            currentLabel = label;
            hasCurrent = true;
        }
        try groupArr.append(a, entry);
    }
    if (hasCurrent) {
        try flushGroup(&lines, &groupArr, currentLabel, a);
    }

    const slices = try lines.toOwnedSlice(a);
    // Match the Node reference: groupedDump ends with a trailing newline.
    var buf = try std.ArrayList(u8).initCapacity(a, 256);
    defer buf.deinit(a);
    for (0..slices.len) |i| {
        if (i > 0) try buf.appendSlice(a, "\n");
        try buf.appendSlice(a, slices[i]);
    }
    try buf.appendSlice(a, "\n");
    return try buf.toOwnedSlice(a);
}

fn flushGroup(
    lines: *std.ArrayList([]const u8),
    groupArr: *std.ArrayList(YamlValue.Value),
    label: []const u8,
    a: std.mem.Allocator,
) !void {
    if (groupArr.items.len == 0) return;
    const header = try std.fmt.allocPrint(a, "# == {s}", .{label});
    try lines.append(a, header);
    const body = try emitYamlValueArr(groupArr.items, a);
    try lines.append(a, body);
    while (groupArr.items.len > 0) {
        _ = groupArr.pop();
    }
}

fn buildLabel(origin: Origin, a: std.mem.Allocator) ![]const u8 {
    if (origin.patchedBy.len == 0) {
        return origin.origin;
    }
    var buf = try std.ArrayList(u8).initCapacity(a, origin.origin.len + 16 + origin.patchedBy.len * 12);
    defer buf.deinit(a);
    try buf.appendSlice(a, origin.origin);
    try buf.appendSlice(a, ", patched by ");
    for (0..origin.patchedBy.len) |i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try buf.appendSlice(a, origin.patchedBy[i]);
    }
    return try buf.toOwnedSlice(a);
}

// ============================================================================
// Result output
// ============================================================================

fn printResult(init: std.process.Init, result: ConformanceResult) !void {
    const json = try buildJson(init.gpa, result);
    defer init.gpa.free(json);
    try writeAll(init, json);
    try writeAll(init, "\n");
}

fn buildJson(allocator: std.mem.Allocator, result: ConformanceResult) ![]const u8 {
    var parts = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer parts.deinit(allocator);

    try parts.append(allocator, "{\"ok\":");
    if (result.ok) { try parts.append(allocator, "true"); } else { try parts.append(allocator, "false"); }

    if (result.output.len > 0) {
        if (result.outputIsJson) {
            try parts.append(allocator, ",\"output\":");
            try parts.append(allocator, result.output);
        } else {
            try parts.append(allocator, ",\"output\":\"");
            try appendEscaped(allocator, &parts, result.output);
            try parts.append(allocator, "\"");
        }
    }
    if (!result.ok) {
        if (result.err.len > 0) {
            try parts.append(allocator, ",\"error\":\"");
            try appendEscaped(allocator, &parts, result.err);
            try parts.append(allocator, "\"");
        }
        if (result.exitCode != 0 or result.emitExitCode) {
            try parts.append(allocator, ",\"exitCode\":");
            var numBuf: [20]u8 = undefined;
            const numStr = try std.fmt.bufPrint(numBuf[0..], "{d}", .{result.exitCode});
            try parts.append(allocator, numStr);
        }
    }
    try parts.append(allocator, "}");

    return try std.mem.join(allocator, "", parts.items);
}

fn appendEscaped(allocator: std.mem.Allocator, parts: *std.ArrayList([]const u8), input: []const u8) !void {
    const hex_digits = "0123456789abcdef";
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '"') { try parts.append(allocator, "\\\""); }
        else if (c == '\\') { try parts.append(allocator, "\\\\"); }
        else if (c == '\n') { try parts.append(allocator, "\\n"); }
        else if (c == '\r') { try parts.append(allocator, "\\r"); }
        else if (c == '\t') { try parts.append(allocator, "\\t"); }
        else if (c < 0x20) {
            const hi = hex_digits[(c >> 4) & 0xf];
            const lo = hex_digits[c & 0xf];
            try parts.append(allocator, "\\u00");
            try parts.append(allocator, &[_]u8{ hi, lo });
        } else {
            try parts.append(allocator, input[i..i + 1]);
        }
        i += 1;
    }
}

// ============================================================================
// Web server — slice 6 (dsh-v0.2.0-rc.2, @deepseek-ai/dsh-host-webserver subset)
// ============================================================================

fn hex4(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @as(u4, @intCast(c - '0'));
    if (c >= 'a' and c <= 'f') return @as(u4, @intCast(c - 'a' + 10));
    if (c >= 'A' and c <= 'F') return @as(u4, @intCast(c - 'A' + 10));
    return null;
}

/// Percent-decode `s` into a freshly allocated slice (caller frees).
fn percentDecode(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(a, s.len);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = hex4(s[i + 1]);
            const lo = hex4(s[i + 2]);
            if (hi != null and lo != null) {
                const v = @as(u16, hi.?) * 16 + @as(u16, lo.?);
                try out.append(a, @intCast(v));
                i += 3;
                continue;
            }
        }
        try out.append(a, s[i]);
        i += 1;
    }
    return try out.toOwnedSlice(a);
}

fn matchCI(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    var i: usize = 0;
    while (i < prefix.len) {
        if (std.ascii.toLower(s[i]) != std.ascii.toLower(prefix[i])) return false;
        i += 1;
    }
    return true;
}

/// Index of the char just past the closing '>' of an open tag like `<head`.
/// Case-insensitive on the tag name. Returns null when the tag is absent.
fn findOpenTag(html: []const u8, name: []const u8) ?usize {
    var i: usize = 0;
    while (i + 1 + name.len <= html.len) {
        if (html[i] == '<' and matchCI(html[i + 1..], name)) {
            var j = i + 1 + name.len;
            while (j < html.len and html[j] != '>') j += 1;
            if (j < html.len) return j + 1;
            return null;
        }
        i += 1;
    }
    return null;
}

fn emitJsonStr(a: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.appendSlice(a, "\"");
    try appendEscapedStr(a, buf, s);
    try buf.appendSlice(a, "\"");
}

fn emitJsonValue(a: std.mem.Allocator, buf: *std.ArrayList(u8), jv: JsonValue) !void {
    switch (jv.typ) {
        .null => try buf.appendSlice(a, "null"),
        .bool => try buf.appendSlice(a, if (jv.bool) "true" else "false"),
        .num => {
            const s = try std.fmt.allocPrint(a, "{}", .{jv.num});
            defer a.free(s);
            try buf.appendSlice(a, s);
        },
        .str => try emitJsonStr(a, buf, jv.str),
        .arr => {
            try buf.appendSlice(a, "[");
            for (0..jv.arr.len) |i| {
                if (i > 0) try buf.appendSlice(a, ",");
                try emitJsonValue(a, buf, jv.arr[i]);
            }
            try buf.appendSlice(a, "]");
        },
        .obj => {
            try buf.appendSlice(a, "{");
            for (0..jv.obj.len) |i| {
                const field = jv.obj[i];
                if (i > 0) try buf.appendSlice(a, ",");
                try emitJsonStr(a, buf, field.key);
                try buf.appendSlice(a, ":");
                try emitJsonValue(a, buf, field.val);
            }
            try buf.appendSlice(a, "}");
        },
    }
}

fn emitOk(init: std.process.Init, a: std.mem.Allocator, out: *std.ArrayList(u8), outputIsJson: bool) !void {
    const output = try out.toOwnedSlice(a);
    defer a.free(output);
    try printResult(init, .{
        .ok = true,
        .output = output,
        .err = "",
        .exitCode = 0,
        .outputIsJson = outputIsJson,
    });
}

fn emitErr(init: std.process.Init, msg: []const u8, ec: usize) !void {
    try printResult(init, .{
        .ok = false,
        .output = "",
        .err = msg,
        .exitCode = ec,
        .outputIsJson = false,
    });
}

fn conformanceWebServer(init: std.process.Init, inputFile: [:0]const u8) !void {
    const cwd_dir = std.Io.Dir.cwd();
    const file = try cwd_dir.readFileAlloc(init.io, inputFile, init.gpa, .unlimited);
    defer init.gpa.free(file);

    var parser = JsonParser{ .s = file, .a = init.gpa };
    const input = try jsonParseValue(&parser);
    if (input.typ != .obj) return error.ExpectedObject;

    const opJv = jsonObjGet(input, "op") orelse return error.MissingOp;
    if (opJv.typ != .str) return error.ExpectedString;
    const op = opJv.str;
    const a = init.gpa;

    if (std.mem.eql(u8, op, "web.route.select")) {
        const routesJv = jsonObjGet(input, "routes") orelse return error.MissingRoutes;
        if (routesJv.typ != .arr) return error.ExpectedArray;
        const pathnameJv = jsonObjGet(input, "pathname") orelse return error.MissingPathname;
        if (pathnameJv.typ != .str) return error.ExpectedString;
        const pathname = pathnameJv.str;

        var exactMatched: ?[]const u8 = null;
        var bestPrefix: ?[]const u8 = null;
        var bestPrefixLen: usize = 0;
        for (routesJv.arr) |routeJv| {
            if (routeJv.typ != .obj) continue;
            const kindJv = jsonObjGet(routeJv, "kind") orelse continue;
            const pathJv = jsonObjGet(routeJv, "path") orelse continue;
            if (kindJv.typ != .str or pathJv.typ != .str) continue;
            if (std.mem.eql(u8, kindJv.str, "exact")) {
                if (std.mem.eql(u8, pathname, pathJv.str)) exactMatched = pathJv.str;
            } else if (std.mem.eql(u8, kindJv.str, "prefix")) {
                const p = pathJv.str;
                var matches = false;
                if (pathname.len == p.len) {
                    matches = std.mem.eql(u8, pathname, p);
                } else if (pathname.len > p.len and pathname[p.len] == '/') {
                    matches = std.mem.eql(u8, pathname[0..p.len], p);
                }
                if (matches and (bestPrefix == null or p.len > bestPrefixLen)) {
                    bestPrefix = p;
                    bestPrefixLen = p.len;
                }
            }
        }

        var out = try std.ArrayList(u8).initCapacity(a, 64);
        defer out.deinit(a);
        try out.appendSlice(a, "{\"matched\":");
        if (exactMatched) |m| {
            try out.appendSlice(a, "{\"kind\":\"exact\",\"path\":");
            try emitJsonStr(a, &out, m);
            try out.appendSlice(a, "}");
        } else if (bestPrefix) |p| {
            try out.appendSlice(a, "{\"kind\":\"prefix\",\"path\":");
            try emitJsonStr(a, &out, p);
            try out.appendSlice(a, "}");
        } else {
            try out.appendSlice(a, "null");
        }
        try out.appendSlice(a, "}");
        try emitOk(init, a, &out, true);
        return;
    }

    if (std.mem.eql(u8, op, "web.route.dup-throws")) {
        const routesJv = jsonObjGet(input, "routes") orelse return error.MissingRoutes;
        if (routesJv.typ != .arr) return error.ExpectedArray;
        var seen = try std.ArrayList([]const u8).initCapacity(a, routesJv.arr.len);
        defer seen.deinit(a);
        for (routesJv.arr) |routeJv| {
            if (routeJv.typ != .obj) continue;
            const pathJv = jsonObjGet(routeJv, "path") orelse continue;
            if (pathJv.typ != .str) continue;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, pathJv.str)) {
                    const msg = try std.fmt.allocPrint(a, "webserver: duplicate exact route \"{s}\"", .{pathJv.str});
                    defer a.free(msg);
                    return emitErr(init, msg, 1);
                }
            }
            try seen.append(a, pathJv.str);
        }
        var empty = try std.ArrayList(u8).initCapacity(a, 0);
        try emitOk(init, a, &empty, true);
        return;
    }

    if (std.mem.eql(u8, op, "web.upgrade.select")) {
        const upgradesJv = jsonObjGet(input, "upgrades") orelse return error.MissingRoutes;
        if (upgradesJv.typ != .arr) return error.ExpectedArray;
        const pathnameJv = jsonObjGet(input, "pathname") orelse return error.MissingPathname;
        if (pathnameJv.typ != .str) return error.ExpectedString;
        const pathname = pathnameJv.str;

        var matched: ?[]const u8 = null;
        for (upgradesJv.arr) |routeJv| {
            if (routeJv.typ != .obj) continue;
            const pathJv = jsonObjGet(routeJv, "path") orelse continue;
            if (pathJv.typ != .str) continue;
            if (std.mem.eql(u8, pathname, pathJv.str)) matched = pathJv.str;
        }

        var out = try std.ArrayList(u8).initCapacity(a, 64);
        defer out.deinit(a);
        try out.appendSlice(a, "{\"matched\":");
        if (matched) |m| {
            try out.appendSlice(a, "{\"path\":");
            try emitJsonStr(a, &out, m);
            try out.appendSlice(a, "}");
        } else {
            try out.appendSlice(a, "null");
        }
        try out.appendSlice(a, "}");
        try emitOk(init, a, &out, true);
        return;
    }

    if (std.mem.eql(u8, op, "web.upgrade.dup-throws")) {
        const upgradesJv = jsonObjGet(input, "upgrades") orelse return error.MissingRoutes;
        if (upgradesJv.typ != .arr) return error.ExpectedArray;
        var seen = try std.ArrayList([]const u8).initCapacity(a, upgradesJv.arr.len);
        defer seen.deinit(a);
        for (upgradesJv.arr) |routeJv| {
            if (routeJv.typ != .obj) continue;
            const pathJv = jsonObjGet(routeJv, "path") orelse continue;
            if (pathJv.typ != .str) continue;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, pathJv.str)) {
                    const msg = try std.fmt.allocPrint(a, "webserver: duplicate upgrade route \"{s}\"", .{pathJv.str});
                    defer a.free(msg);
                    return emitErr(init, msg, 1);
                }
            }
            try seen.append(a, pathJv.str);
        }
        var empty = try std.ArrayList(u8).initCapacity(a, 0);
        try emitOk(init, a, &empty, true);
        return;
    }

    if (std.mem.eql(u8, op, "web.gzip.decision")) {
        const ctJv = jsonObjGet(input, "contentType");
        const ct = if (ctJv) |v| (if (v.typ == .str) v.str else "") else "";
        const clJv = jsonObjGet(input, "contentLength");
        // contentLength is null (unknown length) or a f64; >= 1024 bytes is
        // compressible unless it's an event stream.
        var clOk = false;
        if (clJv) |v| {
            if (v.typ == .num) clOk = v.num >= 1024.0;
        }
        const aeJv = jsonObjGet(input, "acceptEncoding");
        const ae = if (aeJv) |v| (if (v.typ == .str) v.str else "") else "";

        var encoding: []const u8 = "identity";
        if (!std.mem.eql(u8, ct, "text/event-stream")) {
            if (clJv == null or clOk) {
                var i: usize = 0;
                var gzip = false;
                while (i < ae.len) {
                    const segStart = i;
                    while (i < ae.len and ae[i] != ',') i += 1;
                    var seg = ae[segStart..i];
                    var s: usize = 0;
                    while (s < seg.len and (seg[s] == ' ' or seg[s] == '\t')) s += 1;
                    var e: usize = seg.len;
                    while (e > s and (seg[e - 1] == ' ' or seg[e - 1] == '\t')) e -= 1;
                    seg = seg[s..e];
                    i += 1;
                    if (std.mem.eql(u8, seg, "gzip")) gzip = true;
                }
                if (gzip) encoding = "gzip";
            }
        }

        var out = try std.ArrayList(u8).initCapacity(a, 64);
        defer out.deinit(a);
        try out.appendSlice(a, "{\"encoding\":\"");
        try appendEscapedStr(a, &out, encoding);
        try out.appendSlice(a, "\"}");
        try emitOk(init, a, &out, true);
        return;
    }

    if (std.mem.eql(u8, op, "web.host.check")) {
        const hostJv = jsonObjGet(input, "host") orelse return error.MissingHost;
        if (hostJv.typ != .str) return error.ExpectedString;
        const host = hostJv.str;
        var colon: ?usize = null;
        var i: usize = 0;
        while (i < host.len) {
            if (host[i] == ':') { colon = i; break; }
            i += 1;
        }
        const hostPart = if (colon) |c| host[0..c] else host;
        const allowed = std.mem.eql(u8, hostPart, "127.0.0.1") or std.mem.eql(u8, hostPart, "0.0.0.0");

        var out = try std.ArrayList(u8).initCapacity(a, 64);
        defer out.deinit(a);
        try out.appendSlice(a, "{\"allowed\":");
        try out.appendSlice(a, if (allowed) "true" else "false");
        try out.appendSlice(a, "}");
        try emitOk(init, a, &out, true);
        return;
    }

    if (std.mem.eql(u8, op, "web.auth.basic")) {
        const authJv = jsonObjGet(input, "authorization");
        const authorization = if (authJv) |v| (if (v.typ == .str) v.str else null) else null;
        const expectedUserJv = jsonObjGet(input, "expectedUser") orelse return error.MissingExpectedUser;
        const expectedPassJv = jsonObjGet(input, "expectedPass") orelse return error.MissingExpectedPass;
        if (expectedUserJv.typ != .str or expectedPassJv.typ != .str) return error.ExpectedString;
        const expectedUser = expectedUserJv.str;
        const expectedPass = expectedPassJv.str;

        var authenticated = false;
        if (authorization) |auth| {
            var basic = auth.len >= 6 and auth[5] == ' ';
            if (basic) {
                var k: usize = 0;
                while (k < 5) {
                    if (std.ascii.toLower(auth[k]) != std.ascii.toLower("Basic"[k])) { basic = false; break; }
                    k += 1;
                }
            }
            if (basic) {
                const encoded = auth[6..];
                const decoder = std.base64.standard.Decoder;
                const exactLen = try decoder.calcSizeForSlice(encoded);
                var credBuf = try a.alloc(u8, exactLen);
                defer a.free(credBuf);
                try decoder.decode(credBuf, encoded);
                const credentials = credBuf[0..exactLen];

                var colon: ?usize = null;
                var k: usize = 0;
                while (k < credentials.len) {
                    if (credentials[k] == ':') { colon = k; break; }
                    k += 1;
                }
                const user = if (colon) |c| credentials[0..c] else credentials;
                const pass = if (colon) |c| credentials[c + 1..] else "";
                if (std.mem.eql(u8, user, expectedUser) and std.mem.eql(u8, pass, expectedPass)) {
                    authenticated = true;
                }
            }
        }

        var out = try std.ArrayList(u8).initCapacity(a, 64);
        defer out.deinit(a);
        if (!authenticated) {
            return emitErr(init, "unauthorized", 401);
        }
        try out.appendSlice(a, "{\"authenticated\":true}");
        try emitOk(init, a, &out, true);
        return;
    }

    if (std.mem.eql(u8, op, "web.static.resolve")) {
        const assetsJv = jsonObjGet(input, "assets") orelse return error.MissingAssets;
        if (assetsJv.typ != .arr) return error.ExpectedArray;
        const urlPathJv = jsonObjGet(input, "urlPath") orelse return error.MissingUrlPath;
        if (urlPathJv.typ != .str) return error.ExpectedString;
        const urlPath = urlPathJv.str;

        const decoded = try percentDecode(a, urlPath);
        defer a.free(decoded);

        var start: usize = 0;
        var i: usize = 0;
        while (i <= decoded.len) {
            if (i == decoded.len or decoded[i] == '/') {
                if (std.mem.eql(u8, decoded[start..i], "..")) {
                    return emitErr(init, "traversal", 1);
                }
                start = i + 1;
            }
            i += 1;
        }

        var assetPath: ?[]const u8 = null;
        for (assetsJv.arr) |assetJv| {
            if (assetJv.typ != .obj) continue;
            const urlJv = jsonObjGet(assetJv, "url") orelse continue;
            if (urlJv.typ != .str) continue;
            if (std.mem.eql(u8, decoded, urlJv.str)) {
                const pathJv = jsonObjGet(assetJv, "path") orelse continue;
                if (pathJv.typ == .str) assetPath = pathJv.str;
                break;
            }
        }

        var out = try std.ArrayList(u8).initCapacity(a, 64);
        defer out.deinit(a);
        try out.appendSlice(a, "{\"assetPath\":");
        if (assetPath) |p| {
            try emitJsonStr(a, &out, p);
        } else {
            try out.appendSlice(a, "null");
        }
        try out.appendSlice(a, "}");
        try emitOk(init, a, &out, true);
        return;
    }

    if (std.mem.eql(u8, op, "web.index-injections.render")) {
        const htmlJv = jsonObjGet(input, "html") orelse return error.MissingHtml;
        if (htmlJv.typ != .str) return error.ExpectedString;
        const html = htmlJv.str;
        const rowsJv = jsonObjGet(input, "rows") orelse return error.MissingRows;
        if (rowsJv.typ != .arr) return error.ExpectedArray;

        var headBuf = try std.ArrayList(u8).initCapacity(a, 64);
        defer headBuf.deinit(a);
        var bodyBuf = try std.ArrayList(u8).initCapacity(a, 64);
        defer bodyBuf.deinit(a);

        for (rowsJv.arr) |rowJv| {
            if (rowJv.typ != .obj) continue;
            const kindJv = jsonObjGet(rowJv, "kind") orelse continue;
            if (kindJv.typ != .str) continue;
            const placementJv = jsonObjGet(rowJv, "placement");
            const isHead = if (placementJv) |p| p.typ == .str and std.mem.eql(u8, p.str, "head") else true;
            const into = if (isHead) &headBuf else &bodyBuf;

            if (std.mem.eql(u8, kindJv.str, "global")) {
                const nameJv = jsonObjGet(rowJv, "name") orelse continue;
                const valJv = jsonObjGet(rowJv, "value");
                if (nameJv.typ != .str) continue;
                try into.appendSlice(a, "<script>globalThis[");
                try emitJsonStr(a, into,  nameJv.str);
                try into.appendSlice(a, "] = ");
                if (valJv) |v| {
                    try emitJsonValue(a, into,  v);
                } else {
                    try into.appendSlice(a, "undefined");
                }
                try into.appendSlice(a, "</script>");
            } else if (std.mem.eql(u8, kindJv.str, "script")) {
                const textJv = jsonObjGet(rowJv, "text") orelse continue;
                if (textJv.typ != .str) continue;
                try into.appendSlice(a, "<script>");
                try appendEscapedStr(a, into,  textJv.str);
                try into.appendSlice(a, "</script>");
            } else if (std.mem.eql(u8, kindJv.str, "style")) {
                const textJv = jsonObjGet(rowJv, "text") orelse continue;
                if (textJv.typ != .str) continue;
                try into.appendSlice(a, "<style>");
                try appendEscapedStr(a, into,  textJv.str);
                try into.appendSlice(a, "</style>");
            } else if (std.mem.eql(u8, kindJv.str, "html")) {
                const htmlJv2 = jsonObjGet(rowJv, "html") orelse continue;
                if (htmlJv2.typ != .str) continue;
                try into.appendSlice(a, htmlJv2.str);
            } else if (std.mem.eql(u8, kindJv.str, "script-src")) {
                const srcJv = jsonObjGet(rowJv, "src") orelse continue;
                if (srcJv.typ != .str) continue;
                try into.appendSlice(a, "<script src=\"");
                try appendEscapedStr(a, into,  srcJv.str);
                try into.appendSlice(a, "\"></script>");
            } else if (std.mem.eql(u8, kindJv.str, "script-preload")) {
                const srcJv = jsonObjGet(rowJv, "src") orelse continue;
                if (srcJv.typ != .str) continue;
                try into.appendSlice(a, "<link rel=\"preload\" as=\"script\" href=\"");
                try appendEscapedStr(a, into,  srcJv.str);
                try into.appendSlice(a, "\">");
            }
        }
        const ready = "<script>(globalThis.__DSH_BOOT_READY__ ??= Promise.withResolvers()).resolve()</script>";
        try bodyBuf.appendSlice(a, ready);

        const headAt = findOpenTag(html, "head");
        const bodyAt = findOpenTag(html, "body");

        var finalOut = try std.ArrayList(u8).initCapacity(a, html.len + headBuf.items.len + bodyBuf.items.len);
        defer finalOut.deinit(a);
        var cursor: usize = 0;
        if (headAt) |at| {
            try finalOut.appendSlice(a, html[0..at]);
            try finalOut.appendSlice(a, headBuf.items);
            cursor = at;
        }
        if (bodyAt) |ba| {
            try finalOut.appendSlice(a, html[cursor..ba]);
            try finalOut.appendSlice(a, bodyBuf.items);
            cursor = ba;
        }
        try finalOut.appendSlice(a, html[cursor..]);
        try emitOk(init, a, &finalOut, false);
        return;
    }

    const msg = try std.fmt.allocPrint(a, "unknown web op: {s}", .{op});
    defer a.free(msg);
    return emitErr(init, msg, 2);
}
