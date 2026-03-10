require 'benchmark'

module Delayed
  class Worker
    SLEEP = 5

    cattr_accessor :plugins

    # Add or remove plugins in this list before the worker is instantiated
    self.plugins = [Delayed::Plugins::ClearLocks]

    cattr_accessor :logger
    self.logger = if defined?(Merb::Logger)
      Merb.logger
    elsif defined?(RAILS_DEFAULT_LOGGER)
      RAILS_DEFAULT_LOGGER
    end

    def self.lifecycle
      @lifecycle ||= Delayed::Lifecycle.new
    end

    def initialize(options={})
      @quiet = options.has_key?(:quiet) ? options[:quiet] : true
      Delayed::Job.min_priority = options[:min_priority] if options.has_key?(:min_priority)
      Delayed::Job.max_priority = options[:max_priority] if options.has_key?(:max_priority)

      self.plugins.each { |klass| klass.new }
    end

    # Every worker has a unique name which by default is the pid of the process. There are some
    # advantages to overriding this with something which survives worker retarts:  Workers can#
    # safely resume working on tasks which are locked by themselves. The worker will assume that
    # it crashed before.
    def name
      return @name unless @name.nil?
      "#{@name_prefix}host:#{Socket.gethostname} pid:#{Process.pid}" rescue "#{@name_prefix}pid:#{Process.pid}"
    end

    # Sets the name of the worker.
    # Setting the name to nil will reset the default worker name
    def name=(val)
      @name = val
    end

    def start
      say "*** Starting job worker #{Delayed::Job.worker_name}"

      $exit = false
      @exit = false
      trap('TERM') { say 'Exiting...'; stop }
      trap('INT')  { say 'Exiting...'; stop }

      self.class.lifecycle.run_callbacks(:execute, self) do
        loop do
          self.class.lifecycle.run_callbacks(:loop, self) do
            result = nil

            realtime = Benchmark.realtime do
              result = Delayed::Job.work_off
            end

            count = result.sum

            break if stop?

            if count.zero?
              sleep(SLEEP)
            else
              say "#{count} jobs processed at %.4f j/s, %d failed ..." % [count / realtime, result.last]
            end

            break if stop?
          end
        end
      end
    end

    def stop
      $exit = true
      @exit = true
    end

    def stop?
      !!@exit || !!$exit
    end

    def say(text)
      puts text unless @quiet
      logger.info text if logger
    end

  end
end
