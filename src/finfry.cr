require "./finfry/app"
require "./finfry/mcp"

# Finfry is a small command-line budget & expense tracker built on the Jargon
# CLI shard. This file is the library entry point; the executable lives in
# `src/cli.cr`. See `finfry --help` for available commands.
module Finfry
  VERSION = "0.2.0"
end
