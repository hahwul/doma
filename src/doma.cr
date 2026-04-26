# doma — directory tag manager.
#
# Layout:
#   utils/     logger, config, errors, validator
#   models/    Entry value type
#   db/        SQLite-backed Database + Migrations
#   services/  selector, git_detector, exporter, importer
#   cli/       Runner + per-command classes

require "option_parser"
require "colorize"
require "json"
require "yaml"
require "file_utils"
require "db"
require "sqlite3"

require "./utils/errors"
require "./utils/logger"
require "./utils/config"
require "./utils/duration"
require "./utils/validator"
require "./models/entry"
require "./db/migrations"
require "./db/database"
require "./services/picker"
require "./services/selector"
require "./services/git_detector"
require "./services/installer"
require "./services/exporter"
require "./services/importer"
require "./cli/runner"

module Doma
  VERSION = "0.1.0"
end
