module Doma
  struct Entry
    getter id : Int64
    getter path : String
    getter basename : String
    getter tags : Array(String)

    def initialize(@id : Int64, @path : String, @basename : String, @tags : Array(String))
    end
  end
end
