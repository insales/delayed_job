require 'active_record'
require 'benchmark'
require 'socket'

module Delayed
  class DeserializationError < StandardError
  end

  JobSuperclass = ActiveRecord::Base unless defined?(JobSuperclass)

  # A job object that is persisted to the database.
  # Contains the work object as a YAML field.
  class Job < JobSuperclass
    MAX_ATTEMPTS = 3
    MAX_RUN_TIME = 2.hours
    CACHE_TIME_FOR_MIN_ID = 10.minutes
    self.table_name = :delayed_jobs

    # By default failed jobs are destroyed after too many attempts.
    # If you want to keep them around (perhaps to inspect the reason
    # for the failure), set this to false.
    cattr_accessor :destroy_failed_jobs
    self.destroy_failed_jobs = true

    # Every worker has a unique name which by default is the pid of the process.
    # There are some advantages to overriding this with something which survives worker retarts:
    # Workers can safely resume working on tasks which are locked by themselves. The worker will assume that it crashed before.
    cattr_accessor :worker_name
    self.worker_name = "host:#{Socket.gethostname} pid:#{Process.pid}" rescue "pid:#{Process.pid}"

    cattr_accessor :worker_host
    self.worker_host = "host:#{Socket.gethostname} %"

    NextTaskSQL         = '(run_at <= ? AND (locked_at IS NULL OR (locked_at < ? AND locked_by LIKE ?)) OR (locked_by = ?)) AND failed_at IS NULL'
    NextTaskOrder       = 'priority DESC, run_at ASC'

    ParseObjectFromYaml = /\!ruby\/\w+\:([^\s]+)/

    cattr_accessor :min_priority, :max_priority
    self.min_priority = nil
    self.max_priority = nil

    before_save do
      # Вычитаем 1 час для того чтобы run_at не оказывалось в будущем, если времена на серверах разойдуться.
      self.run_at ||= self.class.db_time_now - 1.hour
      true
    end

    # When a worker is exiting, make sure we don't have any locked jobs.
    def self.clear_locks!
      where(locked_by: worker_name).update_all(locked_by: nil, locked_at: nil)
    end

    def get_pid_and_host
      return if locked_by.blank?
      raise "Bad locked_by format: '#{locked_by}'" unless locked_by.match(/^host:([\w\d\-\.]+) pid:(\d+)$/)
      @host = $1
      @pid = $2.to_i
    end

    def pid
      return @pid if @pid
      get_pid_and_host
      @pid
    end

    def host
      return @host if @host
      get_pid_and_host
      @host
    end

    def this_host?
      host == Socket.gethostname
    end

    def kill!
      Process.kill(9, pid) if pid
    end

    def killed?
      return false if !this_host?
      !Process.kill(0, pid)
    rescue Errno::ESRCH => e
      return true
    end

    def failed?
      failed_at
    end
    alias_method :failed, :failed?

    def payload_object
      @payload_object ||= deserialize(self['handler'])
    end

    def name
      @name ||= begin
        payload = payload_object
        if payload.respond_to?(:display_name)
          payload.display_name
        else
          payload.class.name
        end
      end
    end

    # Name to be used when payload is failed to be parsed.
    def safe_name
      defined?(@name) && @name || 'unknown'
    end

    def payload_object=(object)
      self['handler'] = object.to_yaml
    end

    # Reschedule the job in the future (when a job fails).
    # Uses an exponential scale depending on the number of failed attempts.
    def reschedule(message, backtrace = [], time = nil)
      if self.attempts < MAX_ATTEMPTS
        time ||= Job.db_time_now + (attempts ** 4) + 5

        self.attempts    += 1
        self.run_at       = time
        self.last_error   = message + "\n" + backtrace.join("\n")
        self.unlock
        begin
          save!
        rescue
          self.last_error = "Can't save error message\n" + backtrace.join("\n")
          save!
        end
      else
        logger.info "* [JOB] PERMANENTLY removing #{safe_name} because of #{attempts} consequetive failures."
        destroy_failed_jobs ? destroy : update_attribute(:failed_at, Time.now)
      end
    end

    # Try to run one job. Returns true/false (work done/work failed) or nil if job can't be locked.
    def run_with_lock(max_run_time, worker_name)
      logger.info "* [JOB] aquiring lock on #{name}"
      unless lock_exclusively!(max_run_time, worker_name)
        # We did not get the lock, some other worker process must have
        logger.warn "* [JOB] failed to aquire exclusive lock for #{name}"
        return nil # no work done
      end

      runtime =  Benchmark.realtime do
        invoke_job # TODO: raise error if takes longer than max_run_time
        destroy
      end
      # TODO: warn if runtime > max_run_time ?
      logger.info "* [JOB] #{name} completed after %.4f" % runtime
      return true  # did work
    rescue Exception => e
      begin
        # Log before reschedule to report more params
        log_exception(e)
      ensure
        reschedule e.message, e.backtrace
      end
      return false  # work failed
    end

    # Add a job to the queue
    def self.enqueue(*args, &block)
      object = block_given? ? EvaledJob.new(&block) : args.shift

      unless object.respond_to?(:perform) || block_given?
        raise ArgumentError, 'Cannot enqueue items which do not respond to perform'
      end

      priority = args.first || 0
      run_at   = args[1] || db_time_now
      job = Job.create(:payload_object => object, :priority => priority.to_i, :run_at => run_at)
      logger.info "* [JOB] create job_id: #{job.id} class: #{job.handler}"
      job
    end

    def self.cached_min_available_id
      if defined?(@cached_min_available_id) && @cached_min_available_id && @min_available_id_cache_time &&
         Time.now < @min_available_id_cache_time + CACHE_TIME_FOR_MIN_ID
        return @cached_min_available_id
      end

      @min_available_id_cache_time = Time.now
      current_min_id = find_available_relation.minimum(:id)
      current_min_id ||= connection.execute("select last_value from delayed_jobs_id_seq").first["last_value"]
      @cached_min_available_id = current_min_id
    end

    def self.find_available_relation(max_run_time = MAX_RUN_TIME)
      time_now = db_time_now
      sql = NextTaskSQL.dup
      conditions = [time_now, time_now - max_run_time, worker_host, worker_name]

      if min_priority
        sql << ' AND (priority >= ?)'
        conditions << min_priority
      end

      if max_priority
        sql << ' AND (priority <= ?)'
        conditions << max_priority
      end

      conditions.unshift(sql)
      where(conditions)
    end

    # Find a few candidate jobs to run (in case some immediately get locked by others).
    # Return in random order prevent everyone trying to do same head job at once.
    def self.find_available(limit = 5, max_run_time = MAX_RUN_TIME)
      find_available_relation(max_run_time)
        .where("id >= ?", cached_min_available_id)
        .order(NextTaskOrder).limit(limit).shuffle
    end

    # Run the next job we can get an exclusive lock on.
    # If no jobs are left we return nil
    def self.reserve_and_run_one_job(max_run_time = MAX_RUN_TIME)

      # We get up to 50 jobs from the db. In case we cannot get exclusive access to a job we try the next.
      # this leads to a more even distribution of jobs across the worker processes
      find_available(50, max_run_time).each do |job|
        t = job.run_with_lock(max_run_time, worker_name)
        return t unless t == nil  # return if we did work (good or bad)
      end

      nil # we didn't do any work, all 5 were not lockable
    end

    # Lock this job for this worker.
    # Returns true if we have the lock, false otherwise.
    def lock_exclusively!(max_run_time, worker = worker_name)
      now = self.class.db_time_now
      if !locked_by.blank? && locked_by != worker && !killed?
        self.class.where(id: id).update_all(locked_at: now)
        return false
      end
      affected_rows = if locked_by != worker
        # We don't own this job so we will update the locked_by name and the locked_at
        self.class.
          where(id: id).
          where('(locked_at is null or locked_at < ?)', now - max_run_time.to_i).
          update_all(locked_at: now, locked_by: worker)
      else
        # We already own this job, this may happen if the job queue crashes.
        # Simply resume and update the locked_at
        self.class.where(id: id, locked_by: worker).update_all(locked_at: now)
      end
      if affected_rows == 1
        self.locked_at    = now
        self.locked_by    = worker
        return true
      else
        return false
      end
    end

    # Unlock this job (note: not saved to DB)
    def unlock
      self.locked_at    = nil
      self.locked_by    = nil
    end

    # This is a good hook if you need to report job processing errors in additional or different ways
    def log_exception(error)
      logger.error "* [JOB] #{safe_name} failed with #{error.class.name}: #{error.message} - #{attempts} failed attempts"
      logger.error(error)
      if defined?(Rollbar)
        rollbar_scope = as_json(except: :last_error)
        ::Rollbar.scope(:request => rollbar_scope).error(error, :use_exception_level_filters => true)
      end
    end

    # Do num jobs and return stats on success/failure.
    # Exit early if interrupted.
    def self.work_off(num = 100)
      success, failure = 0, 0

      num.times do
        case self.reserve_and_run_one_job
        when true
            success += 1
        when false
            failure += 1
        else
          break  # leave if no work could be done
        end
        break if $exit # leave if we're exiting
      end

      return [success, failure]
    end

    # Moved into its own method so that new_relic can trace it.
    # add hook https://github.com/collectiveidea/delayed_job/blob/v4.0.6/lib/delayed/backend/base.rb#L90
    def invoke_job
      begin
        hook :before
        payload_object.perform
        hook :success
      rescue Exception => e # rubocop:disable RescueException
        hook :error, e
        raise e
      ensure
        hook :after
      end
    end

  private
    # add hook https://github.com/collectiveidea/delayed_job/blob/v4.0.6/lib/delayed/backend/base.rb#L111
    def hook(name, *args)
      if payload_object.respond_to?(name)
        method = payload_object.public_method(name)
        method.arity == 0 ? method.call : method.call(self, *args)
      end
      rescue DeserializationError # rubocop:disable HandleExceptions
    end

    def deserialize(source)
      handler = (YAML.respond_to?(:unsafe_load) ? YAML.unsafe_load(source) : YAML.load(source)) rescue nil

      unless handler.respond_to?(:perform)
        if handler.nil? && source =~ ParseObjectFromYaml
          handler_class = $1
        end
        attempt_to_load(handler_class || handler.class)
        handler = (YAML.respond_to?(:unsafe_load) ? YAML.unsafe_load(source) : YAML.load(source))
      end

      return handler if handler.respond_to?(:perform)

      raise DeserializationError,
        'Job failed to load: Unknown handler. Try to manually require the appropiate file.'
    rescue TypeError, LoadError, NameError => e
      raise DeserializationError,
        "Job failed to load: #{e.message}. Try to manually require the required file."
    end

    # Constantize the object so that ActiveSupport can attempt
    # its auto loading magic. Will raise LoadError if not successful.
    def attempt_to_load(klass)
       klass.constantize
    end

    # Get the current time (GMT or local depending on DB)
    # Note: This does not ping the DB to get the time, so all your clients
    # must have syncronized clocks.
    def self.db_time_now
      # modern rails
      return Time.zone.now if Time.zone

      default_timezone = if ::ActiveRecord.respond_to?(:default_timezone)
                           ::ActiveRecord.default_timezone
                         else
                           ::ActiveRecord::Base.default_timezone
                         end

      if default_timezone == :utc
        Time.now.utc
      else
        Time.now # rubocop:disable Rails/TimeZone
      end
    end
  end

  class EvaledJob
    def initialize
      @job = yield
    end

    def perform
      eval(@job)
    end
  end
end
