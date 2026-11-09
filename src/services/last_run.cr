require "json"
require "../utils/config"
require "../utils/logger"

module Doma
  # Failed paths from the most recent `doma run`, read back as the
  # `@failed` set. Last writer wins — two concurrent sweeps just race for
  # whose failures are remembered.
  module LastRun
    extend self

    def path : String
      File.join(Config.home, "last_run.json")
    end

    # Bookkeeping must never fail the sweep it records.
    def save(failed : Array(String)) : Nil
      Config.ensure_home!
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, failed.to_json)
      File.rename(tmp, path)
    rescue ex
      Logger.debug "could not record last run: #{ex.message}"
    end

    def failed : Array(String)
      return [] of String unless File.exists?(path)
      Array(String).from_json(File.read(path))
    rescue
      [] of String
    end
  end
end
