module PgHero
  module BaseHelper
    def pghero_humanize_duration_ms(millis)
      [[1000, "ms"], [60, "s"], [60, "m"], [24, "h"], [1000, "d"]].map do |count, name|
        if millis > 0
          millis, n = millis.divmod(count)
          "#{n.to_i}#{name}"
        end
      end.compact.reverse.join(" ")
    end

    def pghero_pretty_ident(table, schema: nil)
      ident = table
      if schema && schema != "public"
        ident = "#{schema}.#{table}"
      end
      if ident =~ /\A[a-z0-9_]+\z/
        ident
      else
        @database.quote_ident(ident)
      end
    end
  end
end
