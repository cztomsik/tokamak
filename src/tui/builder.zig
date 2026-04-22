const Context = @import("context.zig").Context;
const Container = @import("context.zig").Container;
const Frame = @import("frame.zig").Frame;
const Control = @import("control.zig").Control;

pub const Builder = struct {
    ctx: *Context,
    frame: *Frame,

    pub fn container(self: Builder) *Container {
        return @fieldParentPtr("frame", self.frame);
    }

    pub fn state(self: Builder, comptime T: type, default: T) *T {
        var key: u64 = @intFromPtr(self.frame);
        key = (key ^ @returnAddress()) *% 0x100000001b3;

        return self.ctx.getState(key, T, default);
    }

    pub fn push(self: Builder, widths: []const i32, height: i32) ?Builder {
        return .{
            .ctx = self.ctx,
            .frame = &(self.container().push(widths, height) orelse return null).frame,
        };
    }

    pub fn pushEq(self: Builder, n: u8, height: i32) ?Builder {
        return .{
            .ctx = self.ctx,
            .frame = &(self.container().pushEq(n, height) orelse return null).frame,
        };
    }

    pub fn peek(self: Builder, width: i32, height: i32) ?[4]i32 {
        return self.container().peek(width, height);
    }

    pub fn next(self: Builder, width: i32, height: i32) ?Frame {
        return self.container().next(width, height);
    }

    pub fn control(self: Builder, ptr: anytype) Control(@TypeOf(ptr.*)) {
        return .init(self.ctx, ptr);
    }

    pub fn inset(self: Builder, sides: [4]i32) ?Builder {
        self.frame.* = self.frame.inset(sides);
        if (self.frame.empty()) return null;
        return self;
    }

    const widgets = @import("widgets.zig");
    pub const spacer = widgets.spacer;
    pub const stack = widgets.stack;
    pub const row = widgets.row;
    pub const grid = widgets.grid;

    pub const text = widgets.text;
    pub const label = widgets.label;
    pub const num = widgets.num;
    pub const paragraph = widgets.paragraph;

    pub const panel = widgets.panel;
    pub const header = widgets.header;
    pub const collapsible = widgets.collapsible;
    pub const separator = widgets.separator;

    pub const button = widgets.button;
    pub const checkbox = widgets.checkbox;
    pub const numberInput = widgets.numberInput;
    pub const textInput = widgets.textInput;
    pub const select = widgets.select;
    pub const slider = widgets.slider;

    pub const alert = widgets.alert;
    pub const spinner = widgets.spinner;
    pub const progress = widgets.progress;

    pub const overlay = widgets.overlay;
    pub const flash = widgets.flash;
    pub const modal = widgets.modal;

    pub const statusBar = widgets.statusBar;
    pub const tabs = widgets.tabs;
    pub const menu = widgets.menu;
    pub const menuItem = widgets.menuItem;
    pub const kvRow = widgets.kvRow;
    pub const tree = widgets.tree;
};
