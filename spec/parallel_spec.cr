require "./spec_helper"

# These specs avoid wall-clock timing (flaky under CI load). Crystal's
# single-threaded fiber scheduler is cooperative and FIFO, so `Fiber.yield`
# gives us *deterministic* interleaving to assert ordering and the
# concurrency cap without ever calling `sleep`.
describe Doma::Parallel do
  describe ".map" do
    it "returns [] for empty input" do
      Doma::Parallel.map([] of Int32, 4) { |i| i * 2 }.should eq([] of Int32)
    end

    it "maps every item and preserves input order" do
      Doma::Parallel.map([1, 2, 3, 4, 5], 2) { |i| i * 10 }.should eq([10, 20, 30, 40, 50])
    end

    it "preserves input order even when later items finish first" do
      # Earlier indices yield more times, so they complete LAST; the
      # result must still come back in input order, not completion order.
      result = Doma::Parallel.map([0, 1, 2, 3, 4], 5) do |i|
        (5 - i).times { Fiber.yield }
        i * 10
      end
      result.should eq([0, 10, 20, 30, 40])
    end

    it "keeps nils when the result type is nilable (no compact)" do
      result = Doma::Parallel.map([1, 2, 3, 4], 2) do |i|
        i.even? ? i : nil
      end
      result.should eq([nil, 2, nil, 4])
    end

    it "never runs more than `jobs` blocks at once" do
      active = 0
      max_active = 0
      Doma::Parallel.map(Array.new(12) { |i| i }, 3) do |i|
        active += 1
        max_active = {max_active, active}.max
        Fiber.yield # force a reschedule so peers pile up if the cap is broken
        active -= 1
        i
      end
      max_active.should eq(3)
    end

    it "clamps jobs to 1..size" do
      Doma::Parallel.map([1, 2, 3], 99) { |i| i }.should eq([1, 2, 3])
      Doma::Parallel.map([1, 2, 3], 0) { |i| i }.should eq([1, 2, 3])
      Doma::Parallel.map([1, 2, 3], -5) { |i| i }.should eq([1, 2, 3])
    end

    it "re-raises the lowest-index error and does not hang" do
      ex = expect_raises(Exception, "boom-2") do
        Doma::Parallel.map([0, 1, 2, 3, 4], 4) do |i|
          raise "boom-#{i}" if i == 2 || i == 4
          i
        end
      end
      ex.message.should eq("boom-2")
    end
  end

  describe ".each_completed" do
    it "yields nothing for empty input" do
      count = 0
      Doma::Parallel.each_completed([] of Int32, 4, ->(x : Int32) { x }) { |_, _| count += 1 }
      count.should eq(0)
    end

    it "visits every item exactly once with its result" do
      seen = [] of Int32
      Doma::Parallel.each_completed([10, 20, 30], 2, ->(x : Int32) { x * 2 }) do |item, result|
        result.should eq(item * 2)
        seen << item
      end
      seen.sort.should eq([10, 20, 30])
    end

    it "yields on the calling fiber so caller-local state is safe to mutate" do
      total = 0
      Doma::Parallel.each_completed([1, 2, 3, 4], 3, ->(x : Int32) { x }) do |_item, result|
        total += result # no cross-fiber sharing: this runs on the reaper fiber
      end
      total.should eq(10)
    end

    it "re-raises a work failure without hanging" do
      ex = expect_raises(Exception, "kaboom") do
        Doma::Parallel.each_completed([1, 2, 3], 3, ->(x : Int32) {
          raise "kaboom" if x == 2
          x
        }) { |_item, _result| }
      end
      ex.message.should eq("kaboom")
    end
  end
end
