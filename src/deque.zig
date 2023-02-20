const std = @import("std");

const Error = std.mem.Allocator.Error || error{};

/// T is the type of element of the queue
/// invariant: only one thread can push back and pop back data,
/// the others can pop front data from the queue
/// not lock-free but the current thread have the priority over the other threads
pub fn Deque(comptime T: type) type {
    return struct {
        top: std.atomic.Atomic(u64),
        bot: std.atomic.Atomic(u64),

        buffer: []T,

        mutex: std.Thread.Mutex,
        allocator: std.mem.Allocator,
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, capacity: u64) Error!Self {
            return Self{
                .bot = std.atomic.Atomic(u64).init(0),
                .top = std.atomic.Atomic(u64).init(capacity - 1),
                .buffer = try allocator.alloc(T, capacity),
                .mutex = std.Thread.Mutex{},
                .allocator = allocator,
            };
        }

        pub fn free(self: *Self) void {
            self.allocator.free(self.buffer);
        }

        fn get_next_index(self: Self, index: u64) u64 {
            if (index + 1 >= self.buffer.len)
                return 0;
            return index + 1;
        }

        fn get_previous_index(self: Self, index: u64) u64 {
            if (index == 0)
                return @intCast(u64, self.buffer.len - 1);
            return index - 1;
        }

        pub fn push_back(self: *Self, t: T) !void {
            var top = self.top.load(.Monotonic);
            var bot = self.bot.load(.Acquire);

            top = self.get_next_index(top);

            if (self.is_empty(top, bot))
                return error.OutOfMemory;

            self.buffer[top] = t;

            std.atomic.fence(.Release);

            self.top.store(top, .Monotonic);
        }

        pub fn pop_back(self: *Self) ?T {
            var old_top = self.top.load(.Monotonic);
            var top = self.get_previous_index(old_top);
            self.top.store(top, .Monotonic);

            std.atomic.fence(.SeqCst);

            var bot = self.bot.load(.Monotonic);

            if (self.is_empty(old_top, bot)) {
                self.top.store(old_top, .Monotonic);
                return null;
            }

            var value = self.buffer[old_top];

            if (self.is_empty(top, bot)) {
                if (self.bot
                    .compareAndSwap(bot, self.get_next_index(bot), .SeqCst, .Monotonic) != null)
                {
                    self.top.store(old_top, .Monotonic);
                    return null;
                }

                self.top.store(old_top, .Monotonic);
            }

            return value;
        }

        fn is_empty(self: Self, top: u64, bot: u64) bool {
            var cond1 = self.get_next_index(top) == bot;
            var cond2 = self.get_next_index(self.get_next_index(top)) == bot;
            return cond1 or cond2;
        }

        pub fn empty(self: *Self) bool {
            var bot = self.bot.load(.Monotonic);
            var top = self.top.load(.Monotonic);
            return self.is_empty(top, bot);
        }

        pub fn pop_front(self: *Self) ?T {
            var bot = self.bot.load(.Acquire);

            std.atomic.fence(.SeqCst);

            var top = self.top.load(.Acquire);

            if (self.is_empty(top, bot))
                return null;

            var value = self.buffer[bot];

            if (self.bot
                .compareAndSwap(bot, self.get_next_index(bot), .SeqCst, .Monotonic) != null)
                return null;

            return value;
        }
    };
}
