const std = @import("std");

fn is_power_of_two(n: anytype) bool {
    if (n == 1) return true;
    if (n & 1 == 0)
        return is_power_of_two(n >> 1);
    return false;
}

const Error = std.mem.Allocator.Error || error{};

/// T is the type of element of the queue
/// invariant: only one thread can push back and pop back data,
/// the others can pop front data from the queue
/// not lock-free but the current thread have the priority over the other threads
pub fn StaticDeque(comptime T: type) type {
    return comptime struct {
        head: std.atomic.Atomic(usize),
        tail: std.atomic.Atomic(usize),

        buffer: []T,

        mutex: std.Thread.Mutex,
        allocator: std.mem.Allocator,

        comptime index_mode: IndexMode = .Abs,

        const Self = @This();

        const IndexMode = enum(u1) { Mod, Abs };
        const Result = union(enum) { Fail, Empty, Ok: T };

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            var buffer = try allocator.alloc(T, capacity);

            var result = Self{
                .tail = std.atomic.Atomic(usize).init(0),
                .head = std.atomic.Atomic(usize).init(0),
                .mutex = std.Thread.Mutex{},
                .allocator = allocator,
                .buffer = buffer,
            };

            switch (result.index_mode) {
                .Mod => try std.testing.expect(is_power_of_two(buffer.len)),
                else => {},
            }

            return result;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        fn isEmpty(self: Self, head: usize, tail: usize) bool {
            return switch (self.index_mode) {
                .Mod => head <= tail,
                .Abs => head == tail or self.nextIndex(head) == tail,
            };
        }

        fn load(self: *Self, index: usize) T {
            return switch (self.index_mode) {
                .Mod => self.buffer[index & (self.buffer.len - 1)],
                .Abs => self.buffer[index],
            };
        }

        fn store(self: *Self, index: usize, value: T) void {
            switch (self.index_mode) {
                .Mod => {
                    self.buffer[index & (self.buffer.len - 1)] = value;
                },
                .Abs => {
                    self.buffer[index] = value;
                },
            }
        }

        fn nextIndex(self: Self, index: usize) usize {
            return switch (self.index_mode) {
                .Mod => index +% 1,
                .Abs => if (index + 1 >= self.buffer.len) 0 else index + 1,
            };
        }

        fn prevIndex(self: Self, index: usize) usize {
            return switch (self.index_mode) {
                .Mod => index -% 1,
                .Abs => if (index == 0) self.buffer.len - 1 else index - 1,
            };
        }

        pub fn pushBack(self: *Self, t: T) !void {
            var old_head = self.head.load(.Monotonic);
            var head = self.nextIndex(old_head);
            var tail = self.tail.load(.Acquire);

            if (self.isEmpty(head, tail))
                return error.OutOfMemory;

            self.store(old_head, t);

            std.atomic.fence(.Release);

            self.head.store(head, .Monotonic);
        }

        pub fn tryPopBack(self: *Self) Self.Result {
            var old_head = self.head.load(.Monotonic);
            var head = self.prevIndex(old_head);
            self.head.store(head, .Monotonic);

            std.atomic.fence(.SeqCst);

            var tail = self.tail.load(.Monotonic);

            if (self.isEmpty(old_head, tail)) {
                self.head.store(old_head, .Monotonic);
                return .Empty;
            }

            var value = self.load(head);

            if (self.isEmpty(head, tail)) {
                if (self.tail
                    .compareAndSwap(tail, self.nextIndex(tail), .SeqCst, .Monotonic) != null)
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
            return self.isEmpty(head, tail);
        }

        pub fn tryPopFront(self: *Self) Self.Result {
            var tail = self.tail.load(.Acquire);

            std.atomic.fence(.SeqCst);

            var head = self.head.load(.Acquire);

            if (self.isEmpty(head, tail))
                return .Empty;
            var value = self.load(tail);

            if (self.tail
                .compareAndSwap(tail, self.nextIndex(tail), .SeqCst, .Monotonic) != null)
                return .Fail;
            return Self.Result{ .Ok = value };
        }
    };
}

pub fn Deque(comptime T: type) type {
    return struct {
        lock: std.Thread.RwLock = .{},
        deque: StaticDeque(T),

        pub const Result = StaticDeque(T).Result;

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return .{
                .deque = try StaticDeque(T).init(allocator, capacity),
            };
        }

        pub fn deinit(self: *Self) void {
            self.deque.deinit();
        }

        pub fn pushBack(self: *Self, value: T) !void {
            self.deque.pushBack(value) catch |err| {
                switch (err) {
                    error.OutOfMemory => {
                        self.lock.lock();
                        defer self.lock.unlock();

                        var deque = try StaticDeque(T).init(
                            self.deque.allocator,
                            2 * self.deque.buffer.len,
                        );

                        defer {
                            self.deque.deinit();
                            self.deque = deque;
                        }

                        while (true) {
                            switch (self.deque.tryPopFront()) {
                                .Ok => |t| try deque.pushBack(t),
                                .Fail => unreachable, // RwLock !!!
                                .Empty => break,
                            }
                        }

                        try deque.pushBack(value);
                    },
                }
            };
        }

        pub fn empty(self: *Self) bool {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            return self.deque.empty();
        }

        pub fn tryPopBack(self: *Self) Result {
            return self.deque.tryPopBack();
        }

        pub fn tryPopFront(self: *Self) Result {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            return self.deque.tryPopFront();
        }
    };
}
