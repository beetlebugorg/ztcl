//! Line breaking with the total-fit algorithm of Knuth and Plass
//! ("Breaking Paragraphs into Lines", Software: Practice and Experience
//! 11, 1981, pages 1119 to 1184).
//!
//! A paragraph is a list of boxes, glue, and penalties. A box has a
//! fixed width. Glue has a width, a stretch, and a shrink. A penalty is
//! a place where a line can end, with a cost and a width that shows only
//! at the end of a line (the hyphen). A line can also end at glue after
//! a box. The algorithm keeps a list of active nodes: the breaks that
//! can start the next line. For each place where a line can end, it
//! computes the adjustment ratio of the line from each active node, and
//! the demerits of the break: (l + 100 |r|^3)^2 plus the square of the
//! penalty, with extra demerits for two hyphens in a row and for lines
//! of very different tightness next to each other (the four fitness
//! classes of the paper). It keeps the best break of each class. An
//! active node goes out when a line from it is too long. The result is
//! the path of breaks with the fewest total demerits.
//!
//! A pass with a tolerance that no line can meet gives no result. Then
//! the caller runs a second pass with a higher tolerance, and a last
//! pass with `emergency` stretch, which gives each line more stretch
//! (TeX has the same idea as \emergencystretch).
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const inf_penalty: f32 = 10000;

pub const Item = struct {
    kind: enum { box, glue, penalty },
    width: f32 = 0,
    stretch: f32 = 0,
    shrink: f32 = 0,
    penalty: f32 = 0,
    flagged: bool = false,
};

pub const Params = struct {
    /// The most badness of a line: 100 |r|^3 for the ratio r.
    tolerance: f32 = 200,
    line_penalty: f32 = 10,
    flagged_demerits: f32 = 3000,
    fitness_demerits: f32 = 10000,
    /// Extra stretch of each line, in points.
    emergency: f32 = 0,
    /// The most compute work: the count of node visits.
    max_steps: usize = 50_000_000,
};

pub const Break = struct {
    /// The index of the item where the line ends.
    pos: usize,
    ratio: f32,
};

const Node = struct {
    pos: usize,
    line: usize,
    fitness: u2,
    width: f32,
    stretch: f32,
    shrink: f32,
    demerits: f64,
    prev: ?u32,
    next: ?u32,
    /// The node of the break before this one, for the result.
    link: ?u32,
    ratio: f32,
};

pub const Error = error{ OutOfMemory, TooMuchWork };

/// Breaks `items` into lines. `widths[i]` is the width of line i, and
/// the last width is the width of the lines after it. Returns null when
/// no path of breaks meets the tolerance. The caller frees the result.
pub fn breakLines(gpa: std.mem.Allocator, items: []const Item, widths: []const f32, p: Params, steps: *usize) Error!?[]Break {
    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(gpa);
    try nodes.append(gpa, .{ .pos = 0, .line = 0, .fitness = 1, .width = 0, .stretch = 0, .shrink = 0, .demerits = 0, .prev = null, .next = null, .link = null, .ratio = 0 });
    var head: ?u32 = 0;
    var sum_w: f32 = 0;
    var sum_y: f32 = 0;
    var sum_z: f32 = 0;

    for (items, 0..) |it, b| {
        const can_break = switch (it.kind) {
            .box => false,
            .glue => b > 0 and items[b - 1].kind == .box,
            .penalty => it.penalty < inf_penalty,
        };
        if (can_break) {
            try tryBreak(gpa, &nodes, &head, items, b, widths, p, sum_w, sum_y, sum_z, steps);
            if (head == null) return null;
        }
        switch (it.kind) {
            .box => sum_w += it.width,
            .glue => {
                sum_w += it.width;
                sum_y += it.stretch;
                sum_z += it.shrink;
            },
            .penalty => {},
        }
    }
    // The best active node at the end of the paragraph.
    var best: ?u32 = null;
    var k = head;
    while (k) |i| : (k = nodes.items[i].next) {
        if (nodes.items[i].pos != items.len - 1) continue;
        if (best == null or nodes.items[i].demerits < nodes.items[best.?].demerits) best = i;
    }
    const last = best orelse return null;
    var count: usize = 0;
    var n: ?u32 = last;
    while (n) |i| : (n = nodes.items[i].link) {
        if (nodes.items[i].link != null) count += 1;
    }
    const out = try gpa.alloc(Break, count);
    n = last;
    var at = count;
    while (n) |i| : (n = nodes.items[i].link) {
        if (nodes.items[i].link == null) break;
        at -= 1;
        out[at] = .{ .pos = nodes.items[i].pos, .ratio = nodes.items[i].ratio };
    }
    return out;
}

fn tryBreak(gpa: std.mem.Allocator, nodes: *std.ArrayList(Node), head: *?u32, items: []const Item, b: usize, widths: []const f32, p: Params, sum_w: f32, sum_y: f32, sum_z: f32, steps: *usize) Error!void {
    const it = items[b];
    const pen: f32 = if (it.kind == .penalty) it.penalty else 0;
    const forced = it.kind == .penalty and pen <= -inf_penalty;
    const flagged = it.kind == .penalty and it.flagged;
    const extra: f32 = if (it.kind == .penalty) it.width else 0;

    var best_d: [4]f64 = @splat(std.math.inf(f64));
    var best_node: [4]?u32 = @splat(null);
    var best_ratio: [4]f32 = @splat(0);
    var best_line: [4]usize = @splat(0);
    var min_d: f64 = std.math.inf(f64);

    var prev: ?u32 = null;
    var k = head.*;
    while (k) |a| {
        steps.* += 1;
        if (steps.* > p.max_steps) return error.TooMuchWork;
        const node = nodes.items[a];
        const next = node.next;
        const line_w = widths[@min(node.line, widths.len - 1)];
        const len = sum_w - node.width + extra;
        var ratio: f32 = 0;
        if (len < line_w) {
            const y = sum_y - node.stretch + p.emergency;
            ratio = if (y > 0) (line_w - len) / y else 10000;
        } else if (len > line_w) {
            const z = sum_z - node.shrink;
            ratio = if (z > 0) (line_w - len) / z else -10000;
        }
        if (ratio < -1 or forced) {
            // Take the node out.
            if (prev) |q| nodes.items[q].next = next else head.* = next;
        } else prev = a;
        const bad: f64 = 100 * std.math.pow(f64, @abs(ratio), 3);
        if (ratio >= -1 and bad <= p.tolerance) {
            var d: f64 = std.math.pow(f64, p.line_penalty + bad, 2);
            if (pen >= 0) d += pen * pen else if (pen > -inf_penalty) d -= pen * pen;
            if (flagged and items[node.pos].kind == .penalty and items[node.pos].flagged) d += p.flagged_demerits;
            const fit: u2 = if (ratio < -0.5) 0 else if (ratio <= 0.5) 1 else if (ratio <= 1) 2 else 3;
            if (@abs(@as(i8, fit) - @as(i8, node.fitness)) > 1) d += p.fitness_demerits;
            d += node.demerits;
            if (d < best_d[fit]) {
                best_d[fit] = d;
                best_node[fit] = a;
                best_ratio[fit] = ratio;
                best_line[fit] = node.line + 1;
                if (d < min_d) min_d = d;
            }
        }
        k = next;
    }
    if (min_d == std.math.inf(f64)) return;
    // The totals after the break: skip the glue and penalties that follow
    // it, up to the next box or forced break.
    var w = sum_w;
    var y = sum_y;
    var z = sum_z;
    var i = b;
    while (i < items.len) : (i += 1) {
        const x = items[i];
        switch (x.kind) {
            .box => break,
            .glue => {
                w += x.width;
                y += x.stretch;
                z += x.shrink;
            },
            .penalty => if (x.penalty <= -inf_penalty and i > b) break,
        }
    }
    for (0..4) |f| {
        const bn = best_node[f] orelse continue;
        if (best_d[f] > min_d + p.fitness_demerits) continue;
        const id: u32 = @intCast(nodes.items.len);
        try nodes.append(gpa, .{ .pos = b, .line = best_line[f], .fitness = @intCast(f), .width = w, .stretch = y, .shrink = z, .demerits = best_d[f], .prev = null, .next = head.*, .link = bn, .ratio = best_ratio[f] });
        head.* = id;
    }
}

test "knuth: a forced end gives one line" {
    const gpa = std.testing.allocator;
    const items = [_]Item{
        .{ .kind = .box, .width = 10 },
        .{ .kind = .glue, .width = 3, .stretch = 2, .shrink = 1 },
        .{ .kind = .box, .width = 10 },
        .{ .kind = .glue, .stretch = 10000 },
        .{ .kind = .penalty, .penalty = -inf_penalty },
    };
    var steps: usize = 0;
    const br = (try breakLines(gpa, &items, &.{100}, .{}, &steps)).?;
    defer gpa.free(br);
    try std.testing.expectEqual(@as(usize, 1), br.len);
    try std.testing.expectEqual(@as(usize, 4), br[0].pos);
}
