require "http/server"
require "ecr"
require "html"
require "uri"
require "./app"
require "./queries"

module Finfry
  # The web UI: a small multi-page app over the same `App`/`Store` the CLI
  # uses. Pages are server-rendered (ECR) from the query layer; every write is
  # a form POST that runs the matching command through `App#execute` — so the
  # account policy, balance guards and undo journal apply exactly as on the
  # command line — then redirects with the command's own output as a note. A
  # few lines of JS let the due and reconcile pages save a toggle without a
  # round trip, but every action works with JS off.
  #
  # Local-only by design: it binds 127.0.0.1 and has no authentication.
  class Web
    DEFAULT_HOST = "127.0.0.1"
    DEFAULT_PORT = 4747

    # Assets are baked into the binary so `finfry serve` stays self-contained.
    STYLE  = {{ read_file("#{__DIR__}/web/style.css") }}
    SCRIPT = {{ read_file("#{__DIR__}/web/app.js") }}
    DEV_JS = {{ read_file("#{__DIR__}/web/dev.js") }}

    # Where `serve --dev` appends UI notes picked in the browser.
    DEV_NOTES = "dev/ui-notes.md"

    FLASH_COOKIE = "finfry_flash"

    # `dev_notes` enables the in-page note picker and names the file it
    # appends to (see `web/dev.js`); nil serves no dev tooling at all.
    def initialize(@store : Store, @host : String = DEFAULT_HOST, @port : Int32 = DEFAULT_PORT, @dev_notes : String? = nil)
      # Commands run non-interactively; their output is captured per request.
      @app = App.new(@store, out: STDERR, interactive: false)
    end

    # Serve until interrupted. Yields the URL once bound, before listening.
    def run(& : String ->) : Nil
      server = HTTP::Server.new { |ctx| handle(ctx) }
      address = server.bind_tcp(@host, @port)
      yield "http://#{address}"
      server.listen
    end

    # Route one request. Public so specs can drive it without a socket.
    def handle(ctx : HTTP::Server::Context) : Nil
      @store.refresh # pick up edits the CLI or an MCP session made meanwhile
      c = Ctx.new(ctx)
      route(c)
    rescue ex : Money::Error | Error | KeyError | TypeCastError
      # A bad filter (invalid month, unparsable amount) or a form missing a
      # field: say so on the page that sent it rather than 500.
      c ||= Ctx.new(ctx)
      message = ex.is_a?(KeyError) || ex.is_a?(TypeCastError) ? "missing or invalid field" : ex.message.to_s
      c.finish(true, message, c.referer)
    end

    # --- routing --------------------------------------------------------

    private def route(c : Ctx) : Nil
      case {c.method, c.path}
      when {"GET", "/"}                  then page_overview(c)
      when {"GET", "/register"}          then page_register(c)
      when {"GET", "/balances"}          then page_balances(c)
      when {"GET", "/ledger"}            then page_ledger(c)
      when {"GET", "/income"}            then page_income(c)
      when {"GET", "/balance-sheet"}     then page_balance_sheet(c)
      when {"GET", "/daily"}             then page_daily(c)
      when {"GET", "/accounts"}          then page_accounts(c)
      when {"GET", "/budgets"}           then page_budgets(c)
      when {"GET", "/recurring"}         then page_recurring(c)
      when {"GET", "/due"}               then page_due(c)
      when {"GET", "/reconcile"}         then page_reconcile(c)
      when {"GET", "/history"}           then page_history(c)
      when {"GET", "/record"}            then page_record(c)
      when {"GET", "/api/recall"}        then api_recall(c)
      when {"GET", "/static/style.css"}  then c.asset("text/css", STYLE)
      when {"GET", "/static/app.js"}     then c.asset("text/javascript", SCRIPT)
      when {"GET", "/static/dev.js"}     then @dev_notes ? c.asset("text/javascript", DEV_JS) : c.not_found
      when {"POST", "/dev/note"}         then post_dev_note(c)
      when {"POST", "/record"}           then post_record(c)
      when {"POST", "/accounts/add"}     then perform(c, "accounts add", {"names" => list(c["names"].split)}, "/accounts")
      when {"POST", "/budgets/set"}      then perform(c, "budget set", args(c, "account", "amount"), "/budgets")
      when {"POST", "/budgets/rm"}       then perform(c, "budget rm", args(c, "account"), "/budgets")
      when {"POST", "/recurring/off"}    then perform(c, "recurring off", {"id" => JSON::Any.new(c["id"].to_i64)}, "/recurring")
      when {"POST", "/due/stage"}        then post_due_stage(c)
      when {"POST", "/due/edit"}         then post_due_edit(c)
      when {"POST", "/due/post"}         then perform(c, "due post", {} of String => JSON::Any, "/due")
      when {"POST", "/reconcile/mark"}   then post_reconcile_mark(c)
      when {"POST", "/reconcile/commit"} then post_reconcile_commit(c)
      when {"POST", "/undo"}             then post_undo(c)
      when {"POST", "/redo"}             then perform(c, "redo", {} of String => JSON::Any, "/history")
      else
        c.not_found
      end
    end

    # --- pages ----------------------------------------------------------

    private def page_overview(c : Ctx) : Nil
      month = current_month
      c.html render(c, "Overview", "overview", OverviewPage.new(
        @app.balance_sheet, @app.income_statement(month), @app.due_queue.size,
        @app.budgets(month), @app.register(limit: 8).rows.reverse, today
      ).to_s)
    end

    # With no date filter the page shows the current month (all-time,
    # oldest-first is the CLI's default, and the right one for a pipe, but a
    # page wants the recent past); `?all=1` widens it. A `month` from a
    # report link becomes the same From/To range the form shows.
    private def page_register(c : Ctx) : Nil
      since = c["since"]?.presence
      until_date = c["until"]?.presence
      if (since.nil? && until_date.nil?) && !c["all"]?.presence
        month = c["month"]?.presence || current_month
        since, until_date = month_bounds(month)
      end
      view = @app.register(
        account: c["account"]?.presence,
        since: since,
        until_date: until_date,
        min: c["min"]?.presence.try { |m| Money.parse(m) },
        max: c["max"]?.presence.try { |m| Money.parse(m) },
        match: c["q"]?.presence,
        limit: c["limit"]?.presence.try(&.to_i?),
      )
      c.html render(c, "Register", "register", RegisterPage.new(view, c.params, account_filter_options, since, until_date).to_s)
    end

    # A period, like the register: this month unless a range (or ?all=1) is given.
    private def page_ledger(c : Ctx) : Nil
      since = c["since"]?.presence
      until_date = c["until"]?.presence
      if since.nil? && until_date.nil? && !c["all"]?.presence
        since, until_date = month_bounds(c["month"]?.presence || current_month)
      end
      prefix = c["prefix"]?.presence
      pages = @app.general_ledger(prefix, since, until_date)
      c.html render(c, "General ledger", "ledger", LedgerPage.new(pages, account_filter_options, prefix, since, until_date).to_s)
    end

    private def page_balances(c : Ctx) : Nil
      prefix = c["prefix"]?.presence
      c.html render(c, "Balances", "balances", BalancesPage.new(@app.balance_tree(prefix), prefix, account_filter_options).to_s)
    end

    private def page_income(c : Ctx) : Nil
      month = c["month"]?.presence || current_month
      c.html render(c, "Income statement", "income", IncomePage.new(@app.income_statement(month)).to_s)
    end

    private def page_balance_sheet(c : Ctx) : Nil
      as_of = c["date"]?.presence
      c.html render(c, "Balance sheet", "balance-sheet", BalanceSheetPage.new(@app.balance_sheet(as_of), as_of || today).to_s)
    end

    private def page_daily(c : Ctx) : Nil
      c.html render(c, "Daily cost", "daily", DailyPage.new(@app.daily).to_s)
    end

    private def page_accounts(c : Ctx) : Nil
      c.html render(c, "Accounts", "accounts", AccountsPage.new(@app.chart, @store.account_policy).to_s)
    end

    private def page_budgets(c : Ctx) : Nil
      month = c["month"]?.presence || current_month
      c.html render(c, "Budgets", "budgets", BudgetsPage.new(@app.budgets(month), month, account_names).to_s)
    end

    private def page_recurring(c : Ctx) : Nil
      c.html render(c, "Recurring", "recurring", RecurringPage.new(@store.recurring_rules, @app).to_s)
    end

    private def page_due(c : Ctx) : Nil
      c.html render(c, "Due", "due", DuePage.new(@app.due_queue, @app).to_s)
    end

    # No account: the overview of what needs reconciling. With one: the
    # statement strip, the working list, and the commit.
    private def page_reconcile(c : Ctx) : Nil
      unless account = c["account"]?.presence
        return c.html render(c, "Reconcile", "reconcile", ReconcileIndexPage.new(@app.reconcilable_accounts).to_s)
      end
      statement = c["statement"]?.presence.try { |s| Money.parse(s) }
      # The strip shows a suggested statement date; what's shown is what's
      # used, so a balance given without a date takes the suggestion.
      as_of = c["as_of"]?.presence || (statement ? @app.next_statement_date(account) : nil)
      view = @app.reconciliation(account, statement, as_of)
      c.html render(c, "Reconcile", "reconcile", ReconcilePage.new(
        view, @store.reconciliations(account), c["statement"]?.presence, as_of || @app.next_statement_date(account)
      ).to_s)
    end

    private def page_history(c : Ctx) : Nil
      c.html render(c, "History", "history", HistoryPage.new(@app.history, @store.db.redo_snapshot.nil?).to_s)
    end

    private def page_record(c : Ctx) : Nil
      c.html render(c, "Record", "record", RecordPage.new(
        @app.accounts_by_recency, @app.usual_funding_account, @app.recent_memos, today
      ).to_s)
    end

    # Memo recall for the record form: the last entry under this memo, as the
    # fields the form would need. The page only uses it to fill blanks.
    private def api_recall(c : Ctx) : Nil
      txn = @app.recall(c["memo"]? || "")
      return c.json({} of String => String) unless txn
      to = txn.postings.find { |p| p.amount > 0 }
      from = txn.postings.find { |p| p.amount < 0 }
      c.json({
        "memo"       => txn.description,
        "amount"     => Money.format(txn.postings.max_of(&.amount.abs)).lchop('$'),
        "to"         => to.try(&.account),
        "from"       => from.try(&.account),
        "recurrence" => txn.recurrence,
        "date"       => txn.date,
      })
    end

    # --- writes ---------------------------------------------------------

    # One form for every two-legged entry: money moves *from* one account *to*
    # another, so direction is always explicit and any pair of accounts works
    # (a refund, a card payment, a reclassification). The kind is only
    # inferred to pick the matching CLI command, so the note and the history
    # read the same as they would from the command line.
    private def post_record(c : Ctx) : Nil
      to = c["to"].strip
      from = c["from"].strip
      a = args(c, "amount", "memo", "date", "recurrence")
      if to.starts_with?("Expenses")
        a["account"] = JSON::Any.new(to)
        a["from"] = JSON::Any.new(from)
        perform(c, "spend", a, "/record")
      elsif from.starts_with?("Income")
        a["account"] = JSON::Any.new(from)
        a["to"] = JSON::Any.new(to)
        perform(c, "earn", a, "/record")
      else
        a.delete("recurrence") # transfer has no cadence flag
        a["from"] = JSON::Any.new(from)
        a["to"] = JSON::Any.new(to)
        perform(c, "transfer", a, "/record")
      end
    end

    # Undo. From the History page `id` reverses an older change (a correcting
    # entry). From a note's Undo button `expect` names the change the note was
    # about: it's only popped if it is still the latest, so an entry made
    # meanwhile (from the CLI, say) can never be undone by mistake.
    private def post_undo(c : Ctx) : Nil
      if expect = c["expect"]?.presence
        latest = @store.changesets.last?.try(&.id)
        unless latest.to_s == expect
          return c.finish(true, "Something else was recorded since — undo it from History instead.", c.referer)
        end
        return perform(c, "undo", {} of String => JSON::Any, c.referer)
      end
      a = {} of String => JSON::Any
      a["id"] = JSON::Any.new(c["id"].to_i64) if c["id"]?.presence
      perform(c, "undo", a, "/history")
    end

    # Decisions arrive as `status-<id>=pending|ok|skip`, one per row (the whole
    # table without JS, a single row with it). Group them into the CLI's own
    # `due ok/skip/reset` calls.
    private def post_due_stage(c : Ctx) : Nil
      groups = {"ok" => [] of String, "skip" => [] of String, "pending" => [] of String}
      c.params.each do |name, value|
        next unless name.starts_with?("status-") && groups.has_key?(value)
        groups[value] << name.lchop("status-")
      end
      messages = [] of String
      {"ok" => "due ok", "skip" => "due skip", "pending" => "due reset"}.each do |status, command|
        next if groups[status].empty?
        output, error = @app.execute(command, JSON::Any.new({"ids" => list(groups[status])}))
        return c.finish(error, output, "/due") if error
        messages << output
      end
      staged = @store.due_entries.count { |e| e.status != "pending" }
      c.finish(false, messages.join("\n"), "/due", {"staged" => staged})
    end

    private def post_due_edit(c : Ctx) : Nil
      a = args(c, "amount", "date", "memo")
      a["id"] = JSON::Any.new(c["id"].to_i64)
      perform(c, "due edit", a, "/due")
    end

    # `ids` lists every row the client is deciding about and `clear` the ones
    # that should be staged; the rest of `ids` are unstaged. The JS sends one
    # row at a time, the plain form the whole working list.
    private def post_reconcile_mark(c : Ctx) : Nil
      account = c["account"]
      ids = c.all("ids")
      clear = c.all("clear")
      unclear = ids - clear
      back = "/reconcile?account=#{URI.encode_www_form(account)}"
      back += "&statement=#{URI.encode_www_form(c["statement"])}" if c["statement"]?.presence
      back += "&as_of=#{URI.encode_www_form(c["as_of"])}" if c["as_of"]?.presence

      {"clear" => clear, "unclear" => unclear}.each do |action, targets|
        next if targets.empty?
        output, error = @app.execute("reconcile", JSON::Any.new({
          "account" => JSON::Any.new(account), "action" => JSON::Any.new(action), "args" => list(targets),
        }))
        return c.finish(error, output, back) if error
      end

      view = @app.reconciliation(account, c["statement"]?.presence.try { |s| Money.parse(s) })
      c.finish(false, "Saved.", back, {
        "cleared"     => Money.format(view.cleared),
        "ledger"      => Money.format(view.ledger),
        "staged"      => view.staged_count,
        "cleared_out" => Money.format(view.cleared_out),
        "cleared_in"  => Money.format(view.cleared_in),
        "difference"  => view.difference.try { |d| Money.format(d) },
        "matches"     => view.matches?,
      })
    end

    private def post_reconcile_commit(c : Ctx) : Nil
      account = c["account"]
      a = {
        "account" => JSON::Any.new(account),
        "action"  => JSON::Any.new("commit"),
        "args"    => list([c["statement"]]),
        "adjust"  => JSON::Any.new(c["adjust"]?.presence ? true : false),
      }
      if as_of = c["as_of"]?.presence
        a["as-of"] = JSON::Any.new(as_of)
      end
      perform(c, "reconcile", a, "/reconcile?account=#{URI.encode_www_form(account)}")
    end

    # Run a command and answer: JSON for fetch callers, else a redirect that
    # carries the command's output (or error) as the next page's note.
    # When the command journaled a new change, the note offers to undo it —
    # except for a reconcile commit, whose adjustment entry is locked under the
    # reconciliation it just finalized.
    private def perform(c : Ctx, subcommand : String, arguments : Hash(String, JSON::Any), back : String) : Nil
      before = @store.changesets.last?.try(&.id)
      output, error = @app.execute(subcommand, JSON::Any.new(arguments))
      after = @store.changesets.last?.try(&.id)
      created = after && (before.nil? || after > before) # a new change, not one popped by undo
      undo = !error && created && subcommand != "reconcile" ? after : nil
      c.finish(error, output, back, undo: undo)
    end

    # Append a note picked in the browser to the notes file, as markdown a
    # reader can act on: the page, the view (→ its template), the element's
    # path and context, then the note itself.
    private def post_dev_note(c : Ctx) : Nil
      return c.not_found unless file = @dev_notes
      info = JSON.parse(c.raw_body)
      note = info["note"]?.try(&.as_s).to_s.strip
      return c.finish(true, "empty note", "/") if note.empty?
      view = info["view"]?.try(&.as_s).to_s
      Dir.mkdir_p(File.dirname(file))
      File.open(file, "a") do |f|
        f.puts "## #{Time.local.to_s("%Y-%m-%d %H:%M")}  #{info["page"]?.try(&.as_s)}"
        f.puts "- view: `#{view}` → `src/finfry/web/#{view}.ecr`" unless view.empty?
        f.puts "- element: `#{info["path"]?.try(&.as_s)}`"
        {"section", "label", "column", "row", "text"}.each do |k|
          if v = info[k]?.try(&.as_s).presence
            f.puts "- #{k}: #{v}"
          end
        end
        f.puts "- html: `#{info["html"]?.try(&.as_s)}`"
        f.puts
        f.puts note
        f.puts
      end
      c.json({"ok" => true, "file" => file})
    end

    # --- helpers --------------------------------------------------------

    # The named form fields that were filled in, as command arguments.
    private def args(c : Ctx, *names : String) : Hash(String, JSON::Any)
      out = {} of String => JSON::Any
      names.each do |n|
        if v = c[n]?.presence
          out[n] = JSON::Any.new(v.strip)
        end
      end
      out
    end

    private def list(items : Array(String)) : JSON::Any
      JSON::Any.new(items.map { |i| JSON::Any.new(i) })
    end

    private def account_names : Array(String)
      @store.known_accounts
    end

    # Every account plus every parent node (`Expenses`, `Expenses:Food`), so
    # the register can be filtered to a subtree from a dropdown.
    private def account_filter_options : Array(String)
      names = Set(String).new
      @store.known_accounts.each do |a|
        parts = a.split(':')
        (1..parts.size).each { |n| names << parts[0, n].join(':') }
      end
      names.to_a.sort
    end

    # First and last day of a "YYYY-MM" month.
    private def month_bounds(month : String) : {String, String}
      first = Time.parse(month, "%Y-%m", Time::Location::UTC)
      {first.to_s("%Y-%m-%d"), first.shift(months: 1).shift(days: -1).to_s("%Y-%m-%d")}
    rescue Time::Format::Error
      raise Error.new("invalid month #{month.inspect} (expected YYYY-MM)")
    end

    private def render(c : Ctx, title : String, active : String, body : String) : String
      Layout.new(title, active, body, @store.path, @store.due_entries.size, c.flash, !@dev_notes.nil?).to_s
    end

    private def today : String
      Time.local.to_s("%Y-%m-%d")
    end

    private def current_month : String
      Time.local.to_s("%Y-%m")
    end

    # A request/response pair with the few conveniences the handlers need:
    # merged query+form params, the flash note carried across a redirect, and
    # content negotiation for the JS callers.
    class Ctx
      getter params : HTTP::Params
      getter flash : Flash?

      # A note carried across one redirect: what happened, and — when the
      # change can be popped — which changeset the Undo button should expect.
      record Flash, kind : String, text : String, undo : Int32? = nil

      getter raw_body : String = ""

      def initialize(@ctx : HTTP::Server::Context)
        @params = @ctx.request.query_params.dup
        if @ctx.request.method == "POST"
          @raw_body = @ctx.request.body.try(&.gets_to_end) || ""
          unless @ctx.request.headers["Content-Type"]?.try(&.starts_with?("application/json"))
            HTTP::Params.parse(@raw_body).each { |k, v| @params.add(k, v) }
          end
        end
        @flash = read_flash
      end

      def method : String
        @ctx.request.method
      end

      def path : String
        @ctx.request.path
      end

      def [](name : String) : String
        @params[name]? || raise Error.new("missing field '#{name}'")
      end

      def []?(name : String) : String?
        @params[name]?
      end

      # Every value posted under `name` (multi-valued fields).
      def all(name : String) : Array(String)
        @params.fetch_all(name).reject(&.blank?)
      end

      def referer : String
        @ctx.request.headers["Referer"]? || "/"
      end

      def wants_json? : Bool
        @ctx.request.headers["Accept"]?.try(&.includes?("application/json")) || false
      end

      def html(body : String) : Nil
        res = @ctx.response
        res.content_type = "text/html; charset=utf-8"
        clear_flash if @flash
        res.print(body)
      end

      def asset(type : String, body : String) : Nil
        res = @ctx.response
        res.content_type = type
        res.headers["Cache-Control"] = "no-cache"
        res.print(body)
      end

      def json(data) : Nil
        res = @ctx.response
        res.content_type = "application/json"
        res.print(data.to_json)
      end

      def not_found : Nil
        @ctx.response.status = HTTP::Status::NOT_FOUND
        @ctx.response.content_type = "text/plain"
        @ctx.response.print("not found")
      end

      # Answer a completed write: JSON (with any extra fields) for fetch
      # callers, otherwise redirect and carry the message as a note.
      def finish(error : Bool, message : String, back : String, extra = nil, undo : Int32? = nil) : Nil
        if wants_json?
          payload = {"ok" => !error, "message" => message}
          @ctx.response.status = HTTP::Status::UNPROCESSABLE_ENTITY if error
          json(extra ? payload.merge(extra) : payload)
        elsif error
          redirect(back, error: message)
        else
          redirect(back, notice: message, undo: undo)
        end
      end

      def redirect(to : String, notice : String? = nil, error : String? = nil, undo : Int32? = nil) : Nil
        res = @ctx.response
        if text = error || notice
          kind = error ? "error" : "notice"
          # Cookies are small; the note is a summary, not a transcript.
          text = "#{text[0, 900]}…" if text.size > 900
          value = URI.encode_www_form("#{kind}:#{undo}:#{text}")
          res.cookies << HTTP::Cookie.new(FLASH_COOKIE, value, path: "/", http_only: true)
        end
        res.status = HTTP::Status::SEE_OTHER
        res.headers["Location"] = to
      end

      private def read_flash : Flash?
        raw = @ctx.request.cookies[FLASH_COOKIE]?.try(&.value)
        return nil unless raw
        kind, _, rest = URI.decode_www_form(raw).partition(':')
        undo, _, text = rest.partition(':')
        Flash.new(kind, text, undo.to_i?)
      end

      private def clear_flash : Nil
        @ctx.response.cookies << HTTP::Cookie.new(FLASH_COOKIE, "", path: "/", expires: Time.unix(0), http_only: true)
      end
    end

    # --- templates ------------------------------------------------------

    # Helpers available inside every template.
    module Helpers
      def h(value) : String
        HTML.escape(value.to_s)
      end

      # An amount cell: monospace, signed, red when negative.
      def money(cents : Int64) : String
        %(<span class="num#{cents < 0 ? " neg" : ""}">#{Money.format(cents)}</span>)
      end

      def money(cents : Float64) : String
        money(cents.round.to_i64)
      end

      def url(path : String, **query) : String
        pairs = query.to_h.compact_map { |k, v| v ? "#{k}=#{URI.encode_www_form(v.to_s)}" : nil }
        pairs.empty? ? path : "#{path}?#{pairs.join('&')}"
      end

      # Account names as <option>s for a select/datalist.
      def account_options(names : Array(String), selected : String? = nil) : String
        names.map { |n| %(<option value="#{h n}"#{n == selected ? " selected" : ""}>#{h n}</option>) }.join
      end

      def cadence_options(selected : String? = nil) : String
        Recurrence.names.map { |n| %(<option value="#{n}"#{n == selected ? " selected" : ""}>#{n}</option>) }.join
      end

      def prev_month(month : String) : String
        shift_month(month, -1)
      end

      def next_month(month : String) : String
        shift_month(month, 1)
      end

      private def shift_month(month : String, by : Int32) : String
        Time.parse(month, "%Y-%m", Time::Location::UTC).shift(months: by).to_s("%Y-%m")
      end

      # Spent-of-limit as a ruled bar; red once over.
      def budget_bar(row : BudgetRow) : String
        pct = row.limit > 0 ? (row.spent * 100 // row.limit).clamp(0, 100) : 100
        %(<div class="track#{row.over? ? " over" : ""}" role="img" aria-label="#{pct}% of budget"><div class="fill" style="width:#{pct}%"></div></div>)
      end

      # Accounts that have statements to reconcile against.
      def reconcilable?(account : String) : Bool
        account.starts_with?("Assets") || account.starts_with?("Liabilities")
      end

      # The ledger path for the sidebar: $HOME shortened, and only the tail if
      # it's still long (the full path is in the title attribute).
      def home(path : String) : String
        short = path.sub(/\A#{Regex.escape(Path.home.to_s)}/, "~")
        parts = short.split('/')
        parts.size > 3 ? "…/#{parts.last(2).join('/')}" : short
      end
    end

    class Layout
      include Helpers

      def initialize(@title : String, @active : String, @body : String, @book : String,
                     @due_count : Int32, @flash : Ctx::Flash?, @dev : Bool = false)
      end

      def nav(name : String) : String
        name == @active ? %( aria-current="page") : ""
      end

      ECR.def_to_s "#{__DIR__}/web/layout.ecr"
    end

    class OverviewPage
      include Helpers

      def initialize(@sheet : BalanceSheet, @statement : IncomeStatement, @due : Int32,
                     @budgets : Array(BudgetRow), @recent : Array(RegisterRow), @today : String)
      end

      ECR.def_to_s "#{__DIR__}/web/overview.ecr"
    end

    class RegisterPage
      include Helpers

      def initialize(@view : RegisterView, @params : HTTP::Params, @accounts : Array(String),
                     @since : String?, @until : String?)
      end

      # Full names: sorted, they already read as a hierarchy, and the closed
      # select stays unambiguous.
      def account_filter_options : String
        account_options(@accounts, @params["account"]?)
      end

      def param(name : String) : String
        h(@params[name]? || "")
      end

      ECR.def_to_s "#{__DIR__}/web/register.ecr"
    end

    class LedgerPage
      include Helpers

      def initialize(@pages : Array(LedgerAccount), @accounts : Array(String), @prefix : String?,
                     @since : String?, @until : String?)
      end

      ECR.def_to_s "#{__DIR__}/web/ledger.ecr"
    end

    class BalancesPage
      include Helpers

      def initialize(@nodes : Array(BalanceNode), @prefix : String?, @accounts : Array(String))
      end

      ECR.def_to_s "#{__DIR__}/web/balances.ecr"
    end

    class IncomePage
      include Helpers

      def initialize(@statement : IncomeStatement)
      end

      ECR.def_to_s "#{__DIR__}/web/income.ecr"
    end

    class BalanceSheetPage
      include Helpers

      def initialize(@sheet : BalanceSheet, @as_of : String)
      end

      ECR.def_to_s "#{__DIR__}/web/balance_sheet.ecr"
    end

    class DailyPage
      include Helpers

      def initialize(@report : DailyReport)
      end

      ECR.def_to_s "#{__DIR__}/web/daily.ecr"
    end

    class AccountsPage
      include Helpers

      def initialize(@rows : Array(AccountRow), @policy : String)
      end

      ECR.def_to_s "#{__DIR__}/web/accounts.ecr"
    end

    class BudgetsPage
      include Helpers

      def initialize(@rows : Array(BudgetRow), @month : String, @accounts : Array(String))
      end

      ECR.def_to_s "#{__DIR__}/web/budgets.ecr"
    end

    class RecurringPage
      include Helpers

      def initialize(@rules : Array(RecurringRule), @app : App)
      end

      ECR.def_to_s "#{__DIR__}/web/recurring.ecr"
    end

    class DuePage
      include Helpers

      def initialize(@entries : Array(DueEntry), @app : App)
      end

      def staged : Int32
        @entries.count { |e| e.status != "pending" }
      end

      ECR.def_to_s "#{__DIR__}/web/due.ecr"
    end

    class ReconcileIndexPage
      include Helpers

      def initialize(@rows : Array(ReconcileSummary))
      end

      ECR.def_to_s "#{__DIR__}/web/reconcile_index.ecr"
    end

    class ReconcilePage
      include Helpers

      # `statement` is the balance as typed (kept verbatim for the inputs);
      # `as_of` is the statement date to show — given, or suggested.
      def initialize(@view : ReconcileView, @past : Array(Reconciliation), @statement : String?, @as_of : String)
      end

      ECR.def_to_s "#{__DIR__}/web/reconcile.ecr"
    end

    class HistoryPage
      include Helpers

      def initialize(@rows : Array(HistoryRow), @redo_empty : Bool)
      end

      ECR.def_to_s "#{__DIR__}/web/history.ecr"
    end

    class RecordPage
      include Helpers

      def initialize(@accounts : Array(String), @funding : String, @memos : Array(String), @today : String)
      end

      # Suggestions for the "to" field: what money is *for* first (expenses,
      # income), then everything else — all of it, in recency order.
      def to_accounts : Array(String)
        category, other = @accounts.partition { |a| a.starts_with?("Expenses") || a.starts_with?("Income") }
        category + other
      end

      # Suggestions for the "from" field: where money is *held* first.
      def from_accounts : Array(String)
        holding, other = @accounts.partition { |a| a.starts_with?("Assets") || a.starts_with?("Liabilities") }
        holding + other
      end

      ECR.def_to_s "#{__DIR__}/web/record.ecr"
    end
  end
end
