///! a reimplemtation of scheduler using intrusive memory
const std = @import("std");
pub const Deque = @import("deque.zig").Deque;

/// task definition, to use place a task as a field of a struct,
/// exec `this.task = .{.callback = myFn}; Worker.spawn(&this.task)`
/// and call @fieldParentPtr(@This(), "task", task) in myFn to
/// reconstruct the caller context
pub const Task = struct {
    callback: *const fn (*Task, Worker) void,
    _done: std.atomic.Atomic(bool),
    _worker_id: std.atomic.Atomic(usize),

    pub fn init(callback: *const fn (*Task, Worker) void) Task {
        return .{
            .callback = callback,
            ._done = std.atomic.Atomic(bool).init(false),
            ._worker_id = std.atomic.Atomic(usize).init(0),
        };
    }

    pub fn call(this: *Task, worker: Worker) void {
        this._worker_id.store(worker.index + 1, .Monotonic);
        this.callback(this, worker);
        this._done.store(true, .Release);
    }

    pub fn getWID(this: *Task) ?usize {
        var wid = this._worker_id.load(.Monotonic);
        if (wid == 0) return null;
        return wid - 1;
    }

    pub fn done(this: *Task) bool {
        return this._done.load(.Acquire);
    }
};

pub const Worker = struct {
    const Self = @This();

    done: std.atomic.Atomic(bool) = std.atomic.Atomic(bool).init(false),
    wsq: []*Deque(*Task),
    index: usize,

    fn steal(self: Self) ?*Task {
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
                        task.call(self.*);
                        continue;
                    },
                    else => {},
                }
            }

            if (self.steal()) |task|
                task.call(self.*);
        }
    }

    pub fn join(self: Self, t: *Task) void {
        main_loop: while (!t.done()) {
            if (!self.wsq[self.index].empty()) {
                switch (self.wsq[self.index].tryPopBack()) {
                    .Ok => |task| {
                        task.call(self);
                        continue;
                    },
                    else => {},
                }
            }

            if (t.getWID()) |index| {
                if (index != self.index) {
                    while (!self.wsq[index].empty() and !t.done()) {
                        if (!self.wsq[self.index].empty())
                            continue :main_loop;

                        switch (self.wsq[index].tryPopFront()) {
                            .Ok => |task| task.call(self),
                            else => {},
                        }
                    }
                }
            }

            if (self.steal()) |task|
                task.call(self);
        }
    }

    pub fn spawn(self: Self, task: *Task) void {
        self.wsq[self.index].pushBack(task) catch @panic("out of memory (pushBack)");
    }

    pub fn run(self: Self, task: *Task) void {
        task.call(self);
    }
};

pub const ThreadPool = struct {
    const Thread = struct { worker: Worker, deque: Deque(*Task), thread: ?std.Thread };

    threads: []Thread,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, number: usize, capacity: usize) !Self {
        try std.testing.expect(number > 0);

        var deques = try allocator.alloc(*Deque(*Task), number);
        var threads = try allocator.alloc(Thread, number);

        var i: usize = 0;
        while (i < number) : (i += 1) {
            threads[i].deque = try Deque(*Task).init(allocator, capacity);
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

/// `fun(args ++ {worker})` must return an object of type `Ret`
pub fn Closure(comptime Args: type, comptime Ret: type, comptime fun: anytype) type {
    return struct {
        task: Task,
        args: Args,
        ret: ?Ret,

        const This = @This();

        pub fn spawn(this: *This, worker: Worker) void {
            worker.spawn(&this.task);
        }

        pub fn join(this: *This, worker: Worker) void {
            worker.join(&this.task);
        }

        pub fn run(this: *This, worker: Worker) void {
            worker.run(&this.task);
        }

        pub fn create(args: Args) This {
            return .{
                .task = Task.init(call),
                .args = args,
                .ret = null,
            };
        }

        pub fn call(task: *Task, worker: Worker) void {
            var this = @fieldParentPtr(This, "task", task);
            this.ret = @call(.auto, fun, this.args ++ .{worker});
            // fun(this.args, worker);
        }

        pub fn eval(this: This) Ret {
            return this.ret.?;
        }
    };
}

test {
    var allocator = std.heap.page_allocator;
    var thread_pool = try ThreadPool.init(allocator, 8, 4);

    var worker = thread_pool.getMainWorker();

    const Fibo = struct {
        pub fn singleThread(x: usize) usize {
            if (x < 2) {
                return x;
            }

            return singleThread(x - 2) + singleThread(x - 1);
        }

        pub fn multiThread(x: usize, w: Worker) usize {
            if (x < 2) return x;

            var c1 = Closure(struct { usize }, usize, multiThread).create(.{x - 1});
            var c2 = Closure(struct { usize }, usize, multiThread).create(.{x - 2});

            c1.spawn(w);
            c2.spawn(w);

            c1.join(w);
            c2.join(w);

            return c1.eval() + c2.eval();
        }
    };

    var arg: usize = 12;

    var f = Fibo.singleThread(arg);

    try std.testing.expect(Fibo.multiThread(arg, worker) == f);
}
