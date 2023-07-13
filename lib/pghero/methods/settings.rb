module PgHero
  module Methods
    module Settings
      def settings
        names =
          if server_version_num >= 90500
            %i(
              max_connections shared_buffers effective_cache_size work_mem
              maintenance_work_mem min_wal_size max_wal_size checkpoint_completion_target
              wal_buffers default_statistics_target
            )
          else
            %i(
              max_connections shared_buffers effective_cache_size work_mem
              maintenance_work_mem checkpoint_segments checkpoint_completion_target
              wal_buffers default_statistics_target
            )
          end
        fetch_settings(names)
      end

      def autovacuum_settings
        fetch_settings %i(autovacuum autovacuum_max_workers autovacuum_vacuum_cost_limit autovacuum_vacuum_scale_factor autovacuum_vacuum_threshold autovacuum_analyze_scale_factor)
      end

      def vacuum_settings
        fetch_settings %i(vacuum_cost_limit)
      end

      # The number of dead tuples that an autovacuum phase can track.
      # https://www.postgresql.org/docs/current/runtime-config-resource.html#GUC-MAINTENANCE-WORK-MEM
      def autovacuum_max_dead_tuples
        # SHOW … returns the value as a string like "64MB" which would require parsing the units.
        # PostgreSQL stores this as kB (KiB) internally, which is simpler / less ambiguous.
        show_setting_kb = ->(key) {
          select_one("SELECT setting FROM pg_settings WHERE name = '#{key}' AND unit = 'kB'")
        }

        # autovacuum_work_mem (integer):
        # Specifies the maximum amount of memory to be used by each autovacuum worker process.
        work_mem_kib = show_setting_kb.(:autovacuum_work_mem).to_i

        # It defaults to -1, indicating that maintenance_work_mem should be used instead.
        if work_mem_kib == -1
          work_mem_kib = show_setting_kb.(:maintenance_work_mem).to_i
        end

        # For the collection of dead tuple identifiers, VACUUM is only able to utilize up to a
        # maximum of 1GB of memory.
        work_mem = [work_mem_kib * 1024, 1024*1024*1024].min

        # I can't remember why this is 6 bytes, but it is.
        bytes_per_tuple_ref = 6

        # This maxes out at 178,956,969 for work_mem >= 1 GiB
        (work_mem / bytes_per_tuple_ref) - 1
      end

      private

      def fetch_settings(names)
        names.to_h { |name| [name, select_one("SHOW #{name}")] }
      end
    end
  end
end
