require "json"
require "./store"

module Finfry
  # The books finfry has opened, most recent first — a registry that fills
  # itself as a side effect of use (any command run in scope of a book, or
  # `finfry init`), so `finfry books` and the web UI's book switcher can find
  # them again. Kept under XDG *state* (history, recently-used), apart from
  # the ledgers themselves under XDG data.
  module Books
    struct Entry
      include JSON::Serializable

      property path : String
      property opened_at : String # "YYYY-MM-DD HH:MM"

      def initialize(@path, @opened_at)
      end

      def exists? : Bool
        File.exists?(path)
      end

      def global? : Bool
        path == Store.global_path
      end

      # Peek at the file for the example flag without loading it as a Store.
      def example? : Bool
        return false unless exists?
        JSON.parse(File.read(path))["example"]?.try(&.as_bool?) || false
      rescue JSON::ParseException | IO::Error
        false
      end
    end

    def self.registry_path : String
      base = ENV["XDG_STATE_HOME"]? || File.join(Path.home.to_s, ".local", "state")
      File.join(base, "finfry", "books.json")
    end

    # Record that `book` was opened now. Entries whose file has gone are
    # dropped at the same time.
    def self.touch(book : String, at : Time = Time.local) : Nil
      full = File.expand_path(book)
      entries = load.reject { |e| e.path == full || !e.exists? }
      entries.unshift(Entry.new(full, at.to_s("%Y-%m-%d %H:%M")))
      save(entries)
    rescue ex : IO::Error | File::Error
      # The registry is a convenience; never let it break a real command.
    end

    # Every known book, most recently opened first. The global ledger is
    # always listed, even before it's ever been used.
    def self.list : Array(Entry)
      entries = load
      unless entries.any?(&.global?)
        entries << Entry.new(Store.global_path, "")
      end
      entries
    end

    # A registered book by path, if it's one we know (the web switcher only
    # opens books from the registry — never an arbitrary path from a form).
    def self.find(path : String) : Entry?
      full = File.expand_path(path)
      list.find { |e| e.path == full }
    end

    # A path with $HOME shortened, for listings.
    def self.display(path : String) : String
      path.sub(/\A#{Regex.escape(Path.home.to_s)}/, "~")
    end

    private def self.load : Array(Entry)
      return [] of Entry unless File.exists?(registry_path)
      Array(Entry).from_json(File.read(registry_path))
    rescue JSON::ParseException
      [] of Entry
    end

    private def self.save(entries : Array(Entry)) : Nil
      Dir.mkdir_p(File.dirname(registry_path))
      tmp = "#{registry_path}.tmp"
      File.write(tmp, entries.to_pretty_json)
      File.rename(tmp, registry_path)
    end
  end
end
