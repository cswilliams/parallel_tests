# frozen_string_literal: true

module ParallelTests
  module RSpec
    class ParentProcess
      IGNORED_SIGNALS = %w(INT QUIT)

      class << self
        def boot
          ENV['RAILS_ENV'] ||= 'test'
          # Load Rails environment from the application directory
          require File.expand_path('config/application', Dir.pwd)
          require File.expand_path('config/environment', Dir.pwd)
          
          # Load RSpec
          require 'rspec/core'
          $LOAD_PATH.unshift(Rails.root.join('spec').to_s)
          require 'rails_helper'

          # Precompile assets
          Rails.application.assets
          Rails.application.precompiled_assets
        end

        def fork_and_run(command, process_number, num_processes, _options)
          # Create a pipe for capturing output
          read_io, write_io = IO.pipe

          pid = Process.fork do
            begin
              # Close read end in child
              read_io.close

              Process.setsid
              setup_child_process
              setup_test_env(process_number, num_processes)
              
              # Redirect stdout/stderr to pipe
              $stdout.reopen(write_io)
              $stderr.reopen(write_io)

              # Reconnect to database in child
              reconnect_database(process_number)

              # Parse command to get executable and args
              executable = command.first
              args = command[1..]

              require 'vernier'
              require 'test-prof'

              TestProf.configure do |config|
                config.output_dir = "test_prof/test_prof_#{ENV.fetch('TEST_ENV_NUMBER', nil)}"
              end
              
              # Clear ARGV and set with our args
              ARGV.clear
              args.each { |arg| ARGV << arg }

              # Use load to maintain preloaded state
              load Bundler.which(executable)
            rescue => e
              puts "Error in child process: #{e.message}"
              puts e.backtrace
              exit!(1)
            ensure
              write_io.close
            end
          end

          # Close write end in parent
          write_io.close
          
          # Read all output at once
          output = read_io.read
          read_io.close

          # Wait for process and get status
          Process.wait(pid)
          
          {
            stdout: output,
            exit_status: $?.exitstatus || 1,
            command: command
          }
        end

        private

        def setup_child_process
          # Reset signal handlers
          IGNORED_SIGNALS.each { |sig| trap(sig, "DEFAULT") }
          trap("TERM", "DEFAULT")
        end

        def setup_test_env(process_number, num_processes)
          ENV['TEST_ENV_NUMBER'] = (process_number == 0 ? '' : (process_number + 1).to_s)
          ENV['PARALLEL_TEST_GROUPS'] = num_processes.to_s
          ENV['PARALLEL_PID'] = Process.pid.to_s
          ENV['RAILS_ENV'] = 'test'
        end

        def reconnect_database(process_number)
          config = ActiveRecord::Base.connection_db_config.configuration_hash
          ActiveRecord::Base.establish_connection(
            config.merge(
              database: config.fetch(:database) + (process_number == 0 ? '' : (process_number + 1).to_s)
            )
          )
        rescue => e
          puts "Failed to reconnect to database: #{e.message}"
        end
      end
    end
  end
end
