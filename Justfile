# finfry task runner — see https://github.com/casey/just

# Where `install` copies the binary (must be on your PATH).
bindir := env_var_or_default("FINFRY_BINDIR", "$HOME/.local/bin")

# List available tasks.
default:
    @just --list

# Build a debug binary into ./bin.
build:
    shards build

# Build an optimized binary into ./bin.
release:
    shards build --release

# Run the test suite.
test:
    crystal spec

# Format sources.
format:
    crystal tool format src/ spec/

# Build a release binary and install it to {{bindir}}.
install: release
    @mkdir -p {{bindir}}
    cp bin/finfry {{bindir}}/finfry
    @echo "installed finfry -> {{bindir}}/finfry"

# Register finfry as an MCP server with Claude Code (user scope).
mcp-add:
    claude mcp add finfry --scope user -- finfry mcp
