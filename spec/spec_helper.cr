require "spec"
require "../src/finfry"

# Keep the specs away from the real recent-books registry.
ENV["XDG_STATE_HOME"] = Dir.tempdir + "/finfry-spec-state"
