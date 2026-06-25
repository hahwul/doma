module Doma
  # Bounded-concurrency fan-out over a collection.
  #
  # doma's `status` and `run --parallel` both sweep a tagged directory
  # set by forking one subprocess per directory. That concurrency is a
  # *real* wall-clock win even though doma is built single-threaded (no
  # `-Dpreview_mt`): `Process.run` yields the fiber while the child runs,
  # so N children overlap on the one thread Crystal gives us and the
  # sweep finishes in roughly max(child) instead of sum(child) time.
  #
  # What does NOT belong here is fanning fibers over *blocking* syscalls
  # — `Dir.exists?`, `File.read`, SQLite driver calls. Those never yield,
  # so the fibers would serialize on the single thread anyway and you'd
  # pay channel + fiber overhead for zero overlap. Reach for this only
  # when each unit of work waits on async I/O (a subprocess or a socket).
  #
  # Both entry points pull work items through a closed channel, so at
  # most `jobs` fibers run at once — a 500-repo sweep never forks 500
  # children simultaneously and saturates the box. `jobs` is clamped to
  # `1..items.size`, so a 0-core helper return or an oversized `--jobs`
  # can't stall or over-subscribe.
  module Parallel
    extend self

    # Runs `block` over every item with at most `jobs` concurrent fibers,
    # returning results in INPUT order regardless of which item finishes
    # first. Use when the caller renders or tallies *after* the whole
    # sweep (e.g. `status`, which prints a path-sorted table once every
    # probe is in).
    #
    # If `block` raises for some item the exception is re-raised here
    # after the pool drains — workers always signal completion through an
    # `ensure`, so one raising item can never hang the sweep waiting on a
    # `done` that never arrives. When several items raise, the lowest
    # index wins, matching a sequential `map`'s fail-at-first behavior.
    def map(items : Indexable(T), jobs : Int32, &block : T -> U) : Array(U) forall T, U
      size = items.size
      return [] of U if size == 0

      cap = jobs.clamp(1, size)
      # Result and error land at the item's original index, so input
      # order survives out-of-order completion.
      slots = Array(U?).new(size, nil)
      errors = Array(Exception?).new(size, nil)

      pending = Channel(Int32).new(size)
      done = Channel(Nil).new(size)
      size.times { |i| pending.send(i) }
      pending.close

      cap.times do
        spawn do
          loop do
            i = pending.receive?
            break if i.nil?
            begin
              slots[i] = block.call(items[i])
            rescue ex
              errors[i] = ex
            ensure
              done.send(nil)
            end
          end
        end
      end

      size.times { done.receive }

      errors.each { |e| raise e if e }

      # Every slot was written before its `done` signal, so the cast is
      # total; it only re-narrows `U?` back to `U` (and stays correct even
      # when `U` is itself nilable).
      Array(U).new(size) { |i| slots[i].as(U) }
    end

    # Runs `work` over every item with at most `jobs` concurrent fibers
    # and yields each `{item, result}` to the block on the CALLING fiber
    # as it finishes — COMPLETION order, streamed while the rest of the
    # sweep is still running. Use when the caller wants live progress
    # (e.g. `run --parallel` printing a ✓/✗ marker per directory the
    # moment that command returns, rather than a silent wait then a wall
    # of markers at the end).
    #
    # Yielding on the calling fiber means the consumer can safely touch
    # caller-local state (a failure counter, ordered output) without any
    # cross-fiber sharing. As with `map`, a raising `work` is surfaced
    # here rather than killing a worker and hanging the reaper.
    def each_completed(items : Indexable(T), jobs : Int32, work : T -> U, &) : Nil forall T, U
      size = items.size
      return if size == 0

      cap = jobs.clamp(1, size)
      pending = Channel(Int32).new(size)
      # Carries {index, result, error}; exactly one of result/error is
      # set. Index lets the consumer recover the originating item even
      # when items aren't unique.
      results = Channel({Int32, U?, Exception?}).new(size)
      size.times { |i| pending.send(i) }
      pending.close

      cap.times do
        spawn do
          loop do
            i = pending.receive?
            break if i.nil?
            begin
              results.send({i, work.call(items[i]), nil})
            rescue ex
              results.send({i, nil, ex})
            end
          end
        end
      end

      size.times do
        i, result, error = results.receive
        raise error if error
        yield items[i], result.as(U)
      end
    end
  end
end
