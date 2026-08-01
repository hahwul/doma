module Doma
  struct Entry
    getter id : Int64
    getter short_id : String
    getter path : String
    getter basename : String
    getter tags : Array(String)
    # Epoch seconds. `last_used_at == 0` is the schema's "never used"
    # sentinel (see `info`'s "last used: never"), and both default to 0
    # for the narrow-column reads that never render them — `dead_paths`
    # deliberately skips these columns to stay cheap at 10k rows.
    getter created_at : Int64
    getter last_used_at : Int64

    def initialize(@id : Int64, @short_id : String, @path : String, @basename : String, @tags : Array(String),
                   @created_at : Int64 = 0_i64, @last_used_at : Int64 = 0_i64)
    end
  end
end
