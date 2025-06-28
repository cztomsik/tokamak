// Here we go again...
// https://github.com/cztomsik/graffiti/tree/master/src/dom
// But this time, our scope is not that broad - this is only intended for
// scraping, querying, and simple transformations. Eventually, it could also be
// dumped into Markdown, PDF, or whatever, but the latter one or anything more
// complex is unlikely.

pub const Document = @import("dom/document.zig").Document;
pub const Element = @import("dom/element.zig").Element;
pub const Node = @import("dom/node.zig").Node;
pub const LocalName = @import("dom/local_name.zig").LocalName;
pub const Text = @import("dom/text.zig").Text;
