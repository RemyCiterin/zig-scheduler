const std = @import("std");

const Error = std.mem.Allocator.Error || error{};

/// T is the type of element of the queue
/// invariant: only one thread can push back and pop back data,
/// the others can pop front data from the queue
/// not lock-free but the current thread have the priority over the other threads
pub fn Deque(comptime T: type) type {
    return struct {
        head: std.atomic.Atomic(usize),
        tail: std.atomic.Atomic(usize),

        buffer: []T,

        mutex: std.Thread.Mutex,
        allocator: ?std.mem.Allocator,

        comptime index_mode: IndexMode = .Mod,

        const Self = @This();

        const IndexMode = enum(u1) { Mod, Abs };
        const Result = union(enum) { Fail, Empty, Ok: T };

        pub fn init(allocator: std.mem.Allocator, capacity: usize) Error!Self {
            return Self.init_with(try allocator.alloc(T, capacity));
        }

        pub fn init_with(buffer: []T) Self {
            return Self{
                .tail = std.atomic.Atomic(usize).init(0),
                .head = std.atomic.Atomic(usize).init(0),
                .mutex = std.Thread.Mutex{},
                .index_mode = .Mod,
                .allocator = null,
                .buffer = buffer,
            };
        }

        pub fn free(self: *Self) void {
            self.allocator.?.free(self.buffer);
        }

        fn is_empty(self: Self, head: usize, tail: usize) bool {
            return switch (self.index_mode) {
                .Mod => head <= tail,
                .Abs => head == tail or self.get_next_index(head) == tail,
            };
        }

        fn load(self: *Self, index: usize) T {
            return switch (self.index_mode) {
                .Mod => self.buffer[index % self.buffer.len],
                .Abs => self.buffer[index],
            };
        }

        fn store(self: *Self, index: usize, value: T) void {
            switch (self.index_mode) {
                .Mod => {
                    self.buffer[index % self.buffer.len] = value;
                },
                .Abs => {
                    self.buffer[index] = value;
                },
            }
        }

        fn get_next_index(self: Self, index: usize) usize {
            return switch (self.index_mode) {
                .Mod => index +% 1,
                .Abs => if (index + 1 >= self.buffer.len) 0 else index + 1,
            };
        }

        fn get_previous_index(self: Self, index: usize) usize {
            return switch (self.index_mode) {
                .Mod => index -% 1,
                .Abs => if (index == 0) self.buffer.len - 1 else index - 1,
            };
        }

        pub fn push_back(self: *Self, t: T) !void {
            var old_head = self.head.load(.Monotonic);
            var head = self.get_next_index(old_head);
            var tail = self.tail.load(.Acquire);

            if (self.is_empty(head, tail))
                return error.OutOfMemory;

            self.store(old_head, t);

            std.atomic.fence(.Release);

            self.head.store(head, .Monotonic);
        }

        pub fn pop_back(self: *Self) Self.Result {
            var old_head = self.head.load(.Monotonic);
            var head = self.get_previous_index(old_head);
            self.head.store(head, .Monotonic);

            std.atomic.fence(.SeqCst);

            var tail = self.tail.load(.Monotonic);

            if (self.is_empty(old_head, tail)) {
                self.head.store(old_head, .Monotonic);
                return .Empty;
            }

            var value = self.load(head);

            if (self.is_empty(head, tail)) {
                if (self.tail
                    .compareAndSwap(tail, self.get_next_index(tail), .SeqCst, .Monotonic) != null)
                {
                    self.head.store(old_head, .Monotonic);
                    return .Fail;
                }

                self.head.store(old_head, .Monotonic);
            }

            return Self.Result{ .Ok = value };
        }

        pub fn empty(self: *Self) bool {
            var tail = self.tail.load(.Monotonic);
            var head = self.head.load(.Monotonic);
            return self.is_empty(head, tail);
        }

        pub fn pop_front(self: *Self) Self.Result {
            var tail = self.tail.load(.Acquire);

            std.atomic.fence(.SeqCst);

            var head = self.head.load(.Acquire);

            if (self.is_empty(head, tail))
                return .Empty;
            var value = self.load(tail);

            if (self.tail
                .compareAndSwap(tail, self.get_next_index(tail), .SeqCst, .Monotonic) != null)
                return .Fail;
            return Self.Result{ .Ok = value };
        }
    };
}
