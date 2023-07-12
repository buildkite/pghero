module PgHero
  module Methods
    module Maintenance
      # https://www.postgresql.org/docs/current/routine-vacuuming.html#VACUUM-FOR-WRAPAROUND
      # "the system will shut down and refuse to start any new transactions
      # once there are fewer than 1 million transactions left until wraparound"
      # warn when 10,000,000 transactions left
      def transaction_id_danger(threshold: 10000000, max_value: 2146483648)
        max_value = max_value.to_i
        threshold = threshold.to_i

        select_all <<~SQL
          SELECT
            n.nspname AS schema,
            c.relname AS table,
            #{quote(max_value)} - GREATEST(AGE(c.relfrozenxid), AGE(t.relfrozenxid)) AS transactions_left
          FROM
            pg_class c
          INNER JOIN
            pg_catalog.pg_namespace n ON n.oid = c.relnamespace
          LEFT JOIN
            pg_class t ON c.reltoastrelid = t.oid
          WHERE
            c.relkind = 'r'
            AND (#{quote(max_value)} - GREATEST(AGE(c.relfrozenxid), AGE(t.relfrozenxid))) < #{quote(threshold)}
          ORDER BY
           3, 1, 2
        SQL
      end

      def autovacuum_danger
        max_value = select_one("SHOW autovacuum_freeze_max_age").to_i
        transaction_id_danger(threshold: 2000000, max_value: max_value)
      end

      def vacuum_progress
        if server_version_num >= 90600
          select_all <<~SQL
            SELECT
              pid,
              phase,
              heap_blks_scanned,
              heap_blks_vacuumed,
              heap_blks_total,
              index_vacuum_count,
              num_dead_tuples,
              max_dead_tuples
            FROM
              pg_stat_progress_vacuum
            WHERE
              datname = current_database()
          SQL
        else
          []
        end
      end

      def create_index_progress
        if server_version_num >= 120000
          select_all <<-SQL
            SELECT
              pid,
              datid,
              datname,
              relid,
              relid::regclass::text as relname,
              index_relid,
              index_relid::regclass::text as index_relname,
              command,
              phase,
              lockers_total,
              lockers_done,
              current_locker_pid,
              blocks_total,
              blocks_done,
              tuples_total,
              tuples_done,
              partitions_total,
              partitions_done
            FROM
              pg_stat_progress_create_index
            WHERE
              datname = current_database()
          SQL
        else
          []
        end
      end

      def maintenance_info
        info = select_all(<<~SQL, cast_values: true)
          SELECT
            schemaname AS schema,
            pg_stat_user_tables.relname AS table,
            reloptions AS options,
            last_vacuum,
            last_autovacuum,
            last_analyze,
            last_autoanalyze,
            n_dead_tup AS dead_rows,
            n_live_tup AS live_rows
          FROM
            pg_stat_user_tables
          JOIN
            pg_class ON pg_stat_user_tables.relid = pg_class.oid
          ORDER BY
            1, 2
        SQL

        runtime_parameters = autovacuum_settings

        info.each do |row|
          table_options = row[:options]&.map { |opt| opt.split("=", 2) }.to_h || {}

          # look up a table storage parameter, defaulting to the globally set value
          find_param = ->(key) { table_options[key.to_s] || runtime_parameters[key] }

          # vacuum_threshold = autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor * pg_class.reltuples
          # — https://www.postgresql.org/docs/13/routine-vacuuming.html#AUTOVACUUM
          threshold = find_param.(:autovacuum_vacuum_threshold).to_i
          scale_factor = find_param.(:autovacuum_vacuum_scale_factor).to_f
          reltuples = row[:live_rows].to_i

          row[:vacuum_threshold] = (threshold + scale_factor * reltuples).to_i
          row[:vacuum_threshold_calc] = "#{threshold} + #{scale_factor} * #{reltuples}"
        end

        info
      end

      def analyze(table, verbose: false)
        execute "ANALYZE #{verbose ? "VERBOSE " : ""}#{quote_table_name(table)}"
        true
      end

      def analyze_tables(verbose: false, min_size: nil, tables: nil)
        tables = table_stats(table: tables).reject { |s| %w(information_schema pg_catalog).include?(s[:schema]) }
        tables = tables.select { |s| s[:size_bytes] > min_size } if min_size
        tables.map { |s| s.slice(:schema, :table) }.each do |stats|
          begin
            with_transaction(lock_timeout: 5000, statement_timeout: 120000) do
              analyze "#{stats[:schema]}.#{stats[:table]}", verbose: verbose
            end
            success = true
          rescue ActiveRecord::StatementInvalid => e
            $stderr.puts e.message
            success = false
          end
          stats[:success] = success
        end
      end

      def vacuum(table, analyze: false, verbose: false)
        execute "VACUUM #{"VERBOSE " if verbose}#{"ANALYZE " if analyze}#{quote_table_name(table)}"
        true
      end
    end
  end
end
