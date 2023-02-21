const std = @import("std");
const testing = std.testing;

const Task = @import("scheduler.zig").Worker.TaskType;
const SaveOutput = @import("task.zig").SaveOutput;
const Worker = @import("scheduler.zig").Worker;
const Deque = @import("deque.zig").Deque;

const ThreadPool = @import("scheduler.zig").ThreadPool;

fn fibo_fn(n: usize) usize {
    if (n < 2) return n;

    return fibo_fn(n - 1) + fibo_fn(n - 2);
}

test "final test" {
    var allocator = std.heap.page_allocator;
    var wsq = try Deque(usize).init(allocator, 10000);
    defer wsq.free();

    try std.testing.expect(wsq.pop_front() == null);

    try wsq.push_back(42);
    var x = wsq.pop_front() orelse unreachable;
    var y = wsq.pop_back();

    try std.testing.expect(x == 42);
    try std.testing.expect(y == null);

    try wsq.push_back(41);
    try wsq.push_back(43);
    try wsq.push_back(44);

    var z = wsq.pop_back() orelse unreachable;
    try std.testing.expect(z == 44);

    var t = wsq.pop_front() orelse unreachable;
    try std.testing.expect(t == 41);

    const compute_fibo = struct {
        //ret: u64 = undefined,
        arg: u64,

        const Self = @This();
        const SavedSelf = SaveOutput(Self, u64);

        pub fn call(self: *Self, worker: Worker) u64 {
            if (self.arg < 2) {
                return self.arg;
            }

            if (self.arg < 2) {
                return fibo_fn(self.arg);
            }

            var fibo1 = SavedSelf.init(Self{ .arg = self.arg - 1 });
            var fibo2 = SavedSelf.init(Self{ .arg = self.arg - 2 });

            var c1 = Task.from_struct(SavedSelf, &fibo1);
            worker.spawn(&c1);
            fibo2.call(worker);
            worker.join(&c1);

            return fibo1.eval() + fibo2.eval();
        }
    };

    var thread_pool = try ThreadPool.init(allocator, 9, 10000);

    var arg: usize = 40;
    var fibo = SaveOutput(compute_fibo, u64).init(compute_fibo{ .arg = arg });
    var closure = Task.from_struct(SaveOutput(compute_fibo, u64), &fibo);

    var worker = thread_pool.get_main_worker();
    worker.run(&closure);

    std.debug.print("{}: {}\n", .{ arg, fibo.eval() });

    thread_pool.free();
}