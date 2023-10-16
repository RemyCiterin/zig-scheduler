# zig-scheduler
An efficient thread pool implementation in Zig using work stealing with `Chase-Lev deque` algorithm for scheduling.

## Usage

Here is an example of use:

```zig
fn fibo_fn(n: usize) usize {
    if (n < 2) return n;

    return fibo_fn(n - 1) + fibo_fn(n - 2);
}


const compute_fibo = struct {
    arg: u64,
    ret: u64 = undefined,

    const Self = @This();

    pub fn eval(self: Self) u64 {
        return ret;
    }

    pub fn call(self: *Self, worker: Worker) u64 {
        if (self.arg < 2) {
            return self.arg;
        }

        if (self.arg < 2) {
            return fibo_fn(self.arg);
        }

        var fibo1 = Self{ .arg = self.arg - 1 };
        var fibo2 = Self{ .arg = self.arg - 2 };

        var t = Task.init(Self, &fibo1);
        worker.spawn(&t);
        fibo2.call(worker);
        worker.join(&t);

        return fibo1.eval() + fibo2.eval();
    }
};

var thread_pool = try ThreadPool.init(allocator, 8, 32);
defer thread_pool.free();

var arg: usize = 42;
var fibo = compute_fibo{ .arg = arg };
var task = Task.init(compute_fibo, &fibo);

var worker = thread_pool.get_main_worker();
worker.run(&task);

try std.testing.expect(fibo.eval() == fibo_fn(arg));
```
A thread pool is initialized with an allocator, the number of CPU used, and the maximal stack size. It return a worker using `thread_pool.get_main_worker()`.
To use a worker you must
- create a task and call `worker.spawn(&task)` then `worker.join(&task)` to finish it's execution
- call `worker.run(&task)` to execute the task on the current CPU but by distributing the task generated by `task` on all the CPUs

A task must be create using `Task(Worker).init(comptime T: type, value: *align(8) T)`, the pointer give the internal state of the task, and T must have a declaration `call` of type `fn call(*T, Worker) void`.

