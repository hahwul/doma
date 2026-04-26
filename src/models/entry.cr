module Doma
  struct Entry
    getter id : Int64
    getter short_id : String
    getter path : String
    getter basename : String
    getter tags : Array(String)

    def initialize(@id : Int64, @short_id : String, @path : String, @basename : String, @tags : Array(String))
    end
  end
end
