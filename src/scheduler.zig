pub const Task = @import("task.zig").Task;
pub const Deque = @import("deque.zig").Deque;
const std = @import("std");

pub const Intrusive = @import("intrusive.zig");

pub const Worker = struct {
    const Self = @This();
    pub const TaskPtr = *TaskType;
    pub const TaskType = Task(Self);

    done: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(false),
    wsq: []*Deque(TaskPtr),
    index: usize,

    fn steal(self: Self) ?TaskPtr {
        var index: usize = 0;

        while (index < self.wsq.len) : (index += 1) {
            if (index != self.index) {
                while (true) {
                    switch (self.wsq[index].tryPopFront()) {
                        .Ok => |task| {
                            return task;
                        },
                        .Empty => break,
                        .Fail => continue,
                    }
                }
            }
        }

        return null;
    }

    pub fn stop(self: *Self) void {
        self.done.store(true, .Release);
    }

    pub fn work(self: *Self) void {
        while (!self.done.load(.Acquire)) {
            if (!self.wsq[self.index].empty()) {
                switch (self.wsq[self.index].tryPopBack()) {
                    .Ok => |task| {
                        task.call_from(self.*, self.index);
                        continue;
                    },
                    else => {},
                }
            }

            if (self.steal()) |task|
                task.call_from(self.*, self.index);

            //std.atomic.spinLoopHint();
        }
    }

    pub fn join(self: Self, t: TaskPtr) void {
        main_loop: while (!t.is_done()) {
            if (!self.wsq[self.index].empty()) {
                switch (self.wsq[self.index].tryPopBack()) {
                    .Ok => |task| {
                        task.call_from(self, self.index);
                        continue;
                    },
                    else => {},
                }
            }

            if (t.get_caller()) |index| {
                if (index != self.index) {
                    while (!self.wsq[index].empty() and !t.is_done()) {
                        if (!self.wsq[self.index].empty())
                            continue :main_loop;

                        switch (self.wsq[index].tryPopFront()) {
                            .Ok => |task| task.call_from(self, self.index),
                            else => {},
                        }
                    }
                }
            }

            if (self.steal()) |task|
                task.call_from(self, self.index);

            //std.atomic.spinLoopHint();
        }
    }

    pub fn spawn(self: Self, task: TaskPtr) void {
        self.wsq[self.index].pushBack(task) catch @panic("out of memory (pushBack)");
    }

    pub fn run(self: Self, task: TaskPtr) void {
        task.call_from(self, self.index);
    }
};

pub const ThreadPool = struct {
    const Thread = struct { worker: Worker, deque: Deque(Worker.TaskPtr), thread: ?std.Thread };

    threads: []Thread,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, number: usize, capacity: usize) !Self {
        try std.testing.expect(number > 0);

        var deques = try allocator.alloc(*Deque(Worker.TaskPtr), number);
        var threads = try allocator.alloc(Thread, number);

        var i: usize = 0;
        while (i < number) : (i += 1) {
            threads[i].deque = try Deque(Worker.TaskPtr).init(allocator, capacity);
            threads[i].worker = Worker{ .wsq = deques, .index = i };
            deques[i] = &threads[i].deque;
        }

        i = 1;
        while (i < number) : (i += 1) {
            threads[i].thread = try std.Thread.spawn(.{}, Worker.work, .{&threads[i].worker});
        }

        return Self{ .threads = threads, .allocator = allocator };
    }

    pub fn getMainWorker(self: Self) Worker {
        return self.threads[0].worker;
    }

    pub fn deinit(self: *Self) void {
        var i: usize = 0;
        while (i < self.threads.len) : (i += 1)
            self.threads[i].worker.stop();

        i = 1;
        while (i < self.threads.len) : (i += 1)
            self.threads[i].thread.?.join();

        i = 0;
        while (i < self.threads.len) : (i += 1)
            self.threads[i].deque.deinit();

        self.allocator.free(self.threads[0].worker.wsq);
        self.allocator.free(self.threads);
    }
};
