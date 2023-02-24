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
    //var wsq = try Deque(usize).init(allocator, 10000);
    //defer wsq.free();

    //try std.testing.expect(wsq.pop_front() == null);

    //try wsq.push_back(42);
    //var x = wsq.pop_front() orelse unreachable;
    //var y = wsq.pop_back();

    //try std.testing.expect(x == 42);
    //try std.testing.expect(y == null);

    //try wsq.push_back(41);
    //try wsq.push_back(43);
    //try wsq.push_back(44);

    //var z = wsq.pop_back() orelse unreachable;
    //try std.testing.expect(z == 44);

    //var t = wsq.pop_front() orelse unreachable;
    //try std.testing.expect(t == 41);

    const compute_fibo = struct {
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

            var t = Task.from_struct(SavedSelf, &fibo1);
            worker.spawn(&t);
            fibo2.call(worker);
            worker.join(&t);

            return fibo1.eval() + fibo2.eval();
        }
    };

    var thread_pool = try ThreadPool.init(allocator, 8, 64);
    defer thread_pool.free();

    var arg: usize = 40;
    var fibo = SaveOutput(compute_fibo, u64).init(compute_fibo{ .arg = arg });
    var task = Task.from_struct(SaveOutput(compute_fibo, u64), &fibo);

    var worker = thread_pool.get_main_worker();
    var mean_time: f32 = 0;

    const num_try = 50;

    comptime var try_index = 0;
    inline while (try_index < num_try) : (try_index += 1) {
        var timer = try std.time.Timer.start();
        worker.run(&task);

        var time = timer.read();

        var print_info = .{ try_index, arg, fibo.eval(), @intToFloat(f32, time) * 1e-9 };
        std.debug.print("{}: fibo {} := {} in {} seconds\n", print_info);

        mean_time += @intToFloat(f32, time) * 1e-9 / @intToFloat(f32, num_try);
    }
    std.debug.print("mean time: {}\n", .{mean_time});
}
