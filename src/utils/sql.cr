module Doma
  # SQL string-building helpers shared by `Doma::Database` and the
  # services that issue ad-hoc statements through a transaction
  # connection. Centralized so the IN-list / multi-row-VALUES shape
  # doesn't drift between sibling call sites.
  module Sql
    extend self

    # Returns `?,?,?` (with `group = "?"`) or `(?, ?),(?, ?),...`
    # (with a parenthesized group) — the chunk that goes inside an
    # `IN (...)` clause or a multi-row `VALUES ...` tail.
    def placeholders_for(n : Int, group : String = "?") : String
      Array.new(n, group).join(",")
    end
  end
end
