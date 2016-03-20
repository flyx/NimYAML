import stopwatch

template multiBench*(nanosecs: int64, times: int, body: stmt): stmt =
    assert(times mod 2 == 0)
    var arr: array[0..times - 1, int64]
    for i in countup(0, times - 1):
        var c: clock
        bench(c):
            body
        arr[i] = c.nanoseconds()
    sort(arr, cmp)
    # ignore lowest and highest 10%
    let tenth: int = times div 10
    let lowest = arr[tenth]
    var totaldiff = 0.int64
    for i in countup(tenth + 1, times - tenth - 1):
        totaldiff += arr[i] - lowest
    nanosecs = lowest + totaldiff div (times - 2 * tenth)