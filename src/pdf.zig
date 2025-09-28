// https://en.wikipedia.org/wiki/PDF
// https://opensource.adobe.com/dc-acrobat-sdk-docs/pdfstandards/pdfreference1.4.pdf

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidPageSize,
    EmptyDocument,
    InvalidObjectReference,
    StreamWriteError,
    AllocationError,
};

pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    real: f64,
    string: []const u8,
    name: []const u8,
    array: []Value,
    dictionary: []DictEntry,
    reference: ObjectRef,
};

pub const DictEntry = struct {
    key: []const u8, // without leading '/'
    value: Value,

    pub fn kv(key: []const u8, value: Value) DictEntry {
        return .{ .key = key, .value = value };
    }
};

pub const ObjectRef = struct {
    id: u32,
    generation: u16 = 0,
};

pub const PdfObject = struct {
    ref: ObjectRef,
    value: Value,
};

// Document structure
pub const Document = struct {
    arena: std.mem.Allocator,
    objects: ArrayList(PdfObject) = .empty,
    pages: ArrayList(*Page) = .empty,
    next_object_id: u32 = 1,
    stream_page_map: std.AutoHashMap(u32, usize), // object ids -> page indices

    pub fn init(allocator: Allocator) !Document {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(allocator);

        return .{
            .arena = arena.allocator(),
            .stream_page_map = std.AutoHashMap(u32, usize).init(arena.allocator()),
        };
    }

    pub fn deinit(self: *Document) void {
        const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self.arena.ptr));
        const allocator = arena.child_allocator;

        arena.deinit();
        allocator.destroy(arena);
    }

    pub fn addPage(self: *Document, width: f64, height: f64) !*Page {
        if (width <= 0 or height <= 0) {
            return Error.InvalidPageSize;
        }

        const page = try self.arena.create(Page);
        page.* = try Page.init(self, width, height);
        try self.pages.append(self.arena, page);

        return page;
    }

    fn nextObjectId(self: *Document) u32 {
        const id = self.next_object_id;
        self.next_object_id += 1;
        return id;
    }

    // TODO: accept *std.io.Writer but we need some way to find out where we are (global pos)
    pub fn render(self: *Document, allocator: std.mem.Allocator) ![]u8 {
        if (self.pages.items.len == 0) {
            return Error.EmptyDocument;
        }

        var buf: std.io.Writer.Allocating = .init(allocator);
        defer buf.deinit();

        const writer = &buf.writer;

        try self.buildDocumentObjects();

        // Header
        try writer.writeAll("%PDF-1.4\n");

        var xref_positions = ArrayList(u32){};
        defer xref_positions.deinit(allocator);
        try xref_positions.append(allocator, 0); // Object 0 is always free

        // Objects
        for (self.objects.items) |obj| {
            try xref_positions.append(allocator, @intCast(buf.written().len));
            try self.writeObject(writer, obj);
        }

        // Cross-reference table
        const xref_offset = buf.written().len;
        try writer.writeAll("xref\n");
        try writer.print("0 {}\n", .{xref_positions.items.len});
        try writer.writeAll("0000000000 65535 f\n"); // Free object 0

        for (xref_positions.items[1..]) |pos| {
            try writer.print("{:0>10} 00000 n\n", .{pos});
        }

        // Trailer
        try writer.writeAll("trailer\n");
        try writer.writeAll("<<\n");
        try writer.print("/Size {}\n", .{xref_positions.items.len});
        try writer.writeAll("/Root 1 0 R\n");
        try writer.writeAll(">>\n");
        try writer.print("startxref\n{}\n", .{xref_offset});
        try writer.writeAll("%%EOF\n");

        return buf.toOwnedSlice();
    }

    // TODO: reserve AoT known sizes!
    fn buildDocumentObjects(self: *Document) !void {
        // Clear
        self.objects.clearRetainingCapacity();
        self.stream_page_map.clearRetainingCapacity();
        self.next_object_id = 1;

        // Catalog
        const catalog_entries = try self.arena.dupe(DictEntry, &.{
            .kv("Type", .{ .name = "Catalog" }),
            .kv("Pages", .{ .reference = .{ .id = 2 } }),
        });

        try self.objects.append(self.arena, .{
            .ref = .{ .id = self.nextObjectId() },
            .value = .{ .dictionary = catalog_entries },
        });

        // Pages
        const page_count = self.pages.items.len;
        const kids_array = try self.arena.alloc(Value, page_count);
        for (0..page_count) |i| {
            // Start at ID 4 (after catalog, pages, font)
            kids_array[i] = .{ .reference = .{ .id = @intCast(4 + i * 2) } };
        }

        const pages_entries = try self.arena.dupe(DictEntry, &.{
            .kv("Type", .{ .name = "Pages" }),
            .kv("Kids", .{ .array = kids_array }),
            .kv("Count", .{ .integer = @intCast(page_count) }),
        });

        try self.objects.append(self.arena, .{
            .ref = .{ .id = self.nextObjectId() },
            .value = .{ .dictionary = pages_entries },
        });

        // Font object (shared)
        const font_entries = try self.arena.dupe(DictEntry, &.{
            .kv("Type", .{ .name = "Font" }),
            .kv("Subtype", .{ .name = "Type1" }),
            .kv("BaseFont", .{ .name = "Helvetica" }),
        });

        const font_id = self.nextObjectId();
        try self.objects.append(self.arena, .{
            .ref = .{ .id = font_id },
            .value = .{ .dictionary = font_entries },
        });

        // Page objects and content streams
        for (self.pages.items, 0..) |page, page_index| {
            // Page object
            const mediabox_array = try self.arena.alloc(Value, 4);
            mediabox_array[0] = .{ .integer = 0 };
            mediabox_array[1] = .{ .integer = 0 };
            mediabox_array[2] = .{ .real = page.width };
            mediabox_array[3] = .{ .real = page.height };

            const font_dict_entries = try self.arena.dupe(DictEntry, &.{
                .kv("F1", .{ .reference = .{ .id = font_id } }),
            });

            const resources_entries = try self.arena.dupe(DictEntry, &.{
                .kv("Font", .{ .dictionary = font_dict_entries }),
            });

            const page_entries = try self.arena.dupe(DictEntry, &.{
                .kv("Type", .{ .name = "Page" }),
                .kv("Parent", .{ .reference = .{ .id = 2 } }),
                .kv("MediaBox", .{ .array = mediabox_array }),
                .kv("Resources", .{ .dictionary = resources_entries }),
            });

            if (page.buf.written().len > 0) {
                const updated_page_entries = try self.arena.dupe(DictEntry, &.{
                    .kv("Type", .{ .name = "Page" }),
                    .kv("Parent", .{ .reference = .{ .id = 2 } }),
                    .kv("MediaBox", .{ .array = mediabox_array }),
                    .kv("Resources", .{ .dictionary = resources_entries }),
                    .kv("Contents", .{ .reference = .{ .id = self.next_object_id + 1 } }),
                });

                try self.objects.append(self.arena, .{
                    .ref = .{ .id = self.nextObjectId() },
                    .value = .{ .dictionary = updated_page_entries },
                });

                // Content stream object
                const stream_entries = try self.arena.dupe(DictEntry, &.{
                    .kv("Length", .{ .integer = @intCast(page.buf.written().len) }),
                });

                const stream_id = self.nextObjectId();
                try self.stream_page_map.put(stream_id, page_index);
                try self.objects.append(self.arena, .{
                    .ref = .{ .id = stream_id },
                    .value = .{ .dictionary = stream_entries },
                });
            } else {
                try self.objects.append(self.arena, .{
                    .ref = .{ .id = self.nextObjectId() },
                    .value = .{ .dictionary = page_entries },
                });
            }
        }
    }

    fn writeObject(self: *Document, writer: *std.io.Writer, obj: PdfObject) !void {
        try writer.print("{} {} obj\n", .{ obj.ref.id, obj.ref.generation });
        try self.writeValue(writer, obj.value);

        // Handle stream objects specially
        if (obj.value == .dictionary) {
            // Check if this is a content stream (has Length and corresponds to page content)
            for (obj.value.dictionary) |entry| {
                if (std.mem.eql(u8, entry.key, "Length")) {
                    // This is a stream object, look up which page it belongs to
                    if (self.stream_page_map.get(obj.ref.id)) |page_index| {
                        if (page_index >= self.pages.items.len) {
                            return Error.InvalidObjectReference;
                        }
                        const page = self.pages.items[page_index];
                        if (page.buf.written().len > 0) {
                            try writer.writeAll("\nstream\n");
                            try writer.writeAll(page.buf.written());
                            try writer.writeAll("\nendstream");
                        }
                    }
                    break;
                }
            }
        }

        try writer.writeAll("\nendobj\n");
    }

    fn writeValue(self: *Document, writer: *std.io.Writer, value: Value) !void {
        switch (value) {
            .null => try writer.writeAll("null"),
            .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try writer.print("{}", .{i}),
            .real => |r| try writer.print("{d}", .{r}),
            .string => |s| try writer.print("({s})", .{s}),
            .name => |n| try writer.print("/{s}", .{n}),
            .reference => |r| try writer.print("{} {} R", .{ r.id, r.generation }),
            .array => |arr| {
                try writer.writeAll("[");
                for (arr, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(" ");
                    try self.writeValue(writer, item);
                }
                try writer.writeAll("]");
            },
            .dictionary => |dict| {
                try writer.writeAll("<<\n");
                for (dict) |entry| {
                    try writer.print("/{s} ", .{entry.key});
                    try self.writeValue(writer, entry.value);
                    try writer.writeAll("\n");
                }
                try writer.writeAll(">>");
            },
        }
    }
};

pub const Page = struct {
    document: *Document,
    width: f64,
    height: f64,
    buf: std.io.Writer.Allocating,

    pub fn init(document: *Document, width: f64, height: f64) !Page {
        return Page{
            .document = document,
            .width = width,
            .height = height,
            .buf = try .initCapacity(document.arena, 512),
        };
    }

    pub fn addText(self: *Page, x: f64, y: f64, text: []const u8) !void {
        // TODO: escape special PDF characters: ( ) \ \n \r \t
        try self.buf.writer.print("BT\n/F1 12 Tf\n{d} {d} Td\n({s}) Tj\nET\n", .{ x, y, text });
    }

    pub fn addLine(self: *Page, x1: f64, y1: f64, x2: f64, y2: f64) !void {
        try self.buf.writer.print("{d} {d} m\n{d} {d} l\nS\n", .{ x1, y1, x2, y2 });
    }

    pub fn addRect(self: *Page, x: f64, y: f64, w: f64, h: f64) !void {
        try self.buf.writer.print("{d} {d} {d} {d} re\nS\n", .{ x, y, w, h });
    }

    // Path operations
    pub fn moveTo(self: *Page, x: f64, y: f64) !void {
        try self.buf.writer.print("{d} {d} m\n", .{ x, y });
    }

    pub fn lineTo(self: *Page, x: f64, y: f64) !void {
        try self.buf.writer.print("{d} {d} l\n", .{ x, y });
    }

    pub fn curveTo(self: *Page, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) !void {
        try self.buf.writer.print("{d} {d} {d} {d} {d} {d} c\n", .{ x1, y1, x2, y2, x3, y3 });
    }

    pub fn closePath(self: *Page) !void {
        try self.buf.writer.writeAll("h\n");
    }

    pub fn stroke(self: *Page) !void {
        try self.buf.writer.writeAll("S\n");
    }

    pub fn fill(self: *Page) !void {
        try self.buf.writer.writeAll("f\n");
    }

    pub fn fillAndStroke(self: *Page) !void {
        try self.buf.writer.writeAll("B\n");
    }
};

fn expectPdf(pdf: []const u8, comptime expected_entries: []const []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4"));

    const required_entries: []const []const u8 = &.{
        "/Type /Page",
        "/Type /Catalog",
        "/Type /Pages",
        "/Type /Page",
        "/Type /Font",
        "xref",
        "trailer",
        "startxref",
        "%%EOF",
    };

    for (required_entries ++ expected_entries) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, pdf, entry) != null);
    }
}

test "basic usage" {
    var doc = try Document.init(std.testing.allocator);
    defer doc.deinit();

    // Check empty
    try std.testing.expectError(Error.EmptyDocument, doc.render(std.testing.allocator));

    // Create a new page
    var page = try doc.addPage(612, 792);

    // Check empty page
    const empty = try doc.render(std.testing.allocator);
    defer std.testing.allocator.free(empty);
    try expectPdf(empty, &.{});

    // Add some contents
    try page.addText(100, 700, "Hello PDF!");
    try page.addLine(50, 50, 100, 100);
    try page.addRect(200, 200, 50, 75);

    const pdf = try doc.render(std.testing.allocator);
    defer std.testing.allocator.free(pdf);

    try expectPdf(pdf, &.{
        "Hello PDF!",
        "BT",
        "ET",

        "50 50 m",
        "200 200 50 75 re",
    });
}

test "path operations" {
    var doc = try Document.init(std.testing.allocator);
    defer doc.deinit();

    var page = try doc.addPage(612, 792);

    // Test path operations
    try page.moveTo(100, 100);
    try page.lineTo(200, 200);
    try page.curveTo(250, 250, 300, 200, 350, 150);
    try page.closePath();
    try page.stroke();

    const pdf = try doc.render(std.testing.allocator);
    defer std.testing.allocator.free(pdf);

    try expectPdf(pdf, &.{
        "100 100 m",
        "200 200 l",
        "250 250 300 200 350 150 c",
        "h",
        "S",
    });
}

test "multi-page" {
    var doc = try Document.init(std.testing.allocator);
    defer doc.deinit();

    // Add multiple pages
    var page1 = try doc.addPage(612, 792);
    try page1.addText(100, 700, "Page 1");

    var page2 = try doc.addPage(612, 792);
    try page2.addText(100, 700, "Page 2");

    var page3 = try doc.addPage(612, 792);
    try page3.addText(100, 700, "Page 3");

    const pdf = try doc.render(std.testing.allocator);
    defer std.testing.allocator.free(pdf);

    try expectPdf(pdf, &.{
        "Page 1",
        "Page 2",
        "Page 3",
        "/Count 3",
    });
}
