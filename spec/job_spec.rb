require 'database_helper'

class SimpleJob
  cattr_accessor :runs; self.runs = 0
  def perform; @@runs += 1; end
end

class ErrorJob
  cattr_accessor :runs; self.runs = 0
  def perform; raise 'did not work'; end
end

module M
  class ModuleJob
    cattr_accessor :runs; self.runs = 0
    def perform; @@runs += 1; end
  end

end

describe Delayed::Job do
  before  do
    Delayed::Job.max_priority = nil
    Delayed::Job.min_priority = nil
    Delayed::Job.delete_all

    SimpleJob.runs = 0
  end

  it "should set run_at automatically if not set" do
    expect(Delayed::Job.create(:payload_object => ErrorJob.new ).run_at).not_to eq nil
  end

  it "should not set run_at automatically if already set" do
    later = 5.minutes.from_now
    expect(Delayed::Job.create(:payload_object => ErrorJob.new, :run_at => later).run_at).to be_within(0.000001.seconds).of later
  end

  it "should raise ArgumentError when handler doesn't respond_to :perform" do
    expect { Delayed::Job.enqueue(Object.new) }.to raise_error(ArgumentError)
  end

  it "should increase count after enqueuing items" do
    Delayed::Job.enqueue SimpleJob.new
    expect(Delayed::Job.count).to eq 1
  end

  it "should be able to set priority when enqueuing items" do
    Delayed::Job.enqueue SimpleJob.new, 5
    expect(Delayed::Job.first.priority).to eq 5
  end

  it "should be able to set run_at when enqueuing items" do
    later = 5.minutes.from_now
    Delayed::Job.enqueue SimpleJob.new, 5, later

    # use be close rather than equal to because millisecond values cn be lost in DB round trip
    expect(Delayed::Job.first.run_at).to be_within(1).of(later)
  end

  it "should call perform on jobs when running work_off" do
    expect(SimpleJob.runs).to eq 0

    Delayed::Job.enqueue SimpleJob.new
    Delayed::Job.work_off

    expect(SimpleJob.runs).to eq 1
  end


  it "should work with eval jobs" do
    $eval_job_ran = false

    Delayed::Job.enqueue do <<-JOB
      $eval_job_ran = true
    JOB
    end

    Delayed::Job.work_off

    expect($eval_job_ran).to eq true
  end

  it "should work with jobs in modules" do
    expect(M::ModuleJob.runs).to eq 0

    Delayed::Job.enqueue M::ModuleJob.new
    Delayed::Job.work_off

    expect(M::ModuleJob.runs).to eq 1
  end

  it "should re-schedule by about 1 second at first and increment this more and more minutes when it fails to execute properly" do
    Delayed::Job.enqueue ErrorJob.new
    Delayed::Job.work_off(1)

    job = Delayed::Job.first

    expect(job.last_error).to match(/did not work/)
    expect(job.last_error).to match(/job_spec.rb:10:in .(ErrorJob#)?perform'/)
    expect(job.attempts).to eq 1

    expect(job.run_at).to be > Delayed::Job.db_time_now - 10.minutes
    expect(job.run_at).to be < Delayed::Job.db_time_now + 10.minutes
  end

  let(:deserialization_error) { [ArgumentError, /undefined .*JobThatDoesNotExist/] }

  it "should raise an DeserializationError when the job class is totally unknown" do

    job = Delayed::Job.new
    job['handler'] = "--- !ruby/object:JobThatDoesNotExist {}"

    expect { job.payload_object.perform }.to raise_error(Delayed::DeserializationError)
  end

  it "should try to load the class when it is unknown at the time of the deserialization" do
    job = Delayed::Job.new
    job['handler'] = "--- !ruby/object:JobThatDoesNotExist {}"

    expect(job).to receive(:attempt_to_load).with('JobThatDoesNotExist').and_return(true)

    expect { job.payload_object.perform }.to raise_error(*deserialization_error)
  end

  it "should try include the namespace when loading unknown objects" do
    job = Delayed::Job.new
    job['handler'] = "--- !ruby/object:Delayed::JobThatDoesNotExist {}"
    expect(job).to receive(:attempt_to_load).with('Delayed::JobThatDoesNotExist').and_return(true)
    expect { job.payload_object.perform }.to raise_error(*deserialization_error)
  end

  it "should also try to load structs when they are unknown (raises TypeError)" do
    job = Delayed::Job.new
    job['handler'] = "--- !ruby/struct:JobThatDoesNotExist {}"

    expect(job).to receive(:attempt_to_load).with('JobThatDoesNotExist').and_return(true)

    expect { job.payload_object.perform }.to raise_error(*deserialization_error)
  end

  it "should try include the namespace when loading unknown structs" do
    job = Delayed::Job.new
    job['handler'] = "--- !ruby/struct:Delayed::JobThatDoesNotExist {}"

    expect(job).to receive(:attempt_to_load).with('Delayed::JobThatDoesNotExist').and_return(true)
    expect { job.payload_object.perform }.to raise_error(*deserialization_error)
  end

  it "should be failed if it failed more than MAX_ATTEMPTS times and we don't want to destroy jobs" do
    default = Delayed::Job.destroy_failed_jobs
    Delayed::Job.destroy_failed_jobs = false

    @job = Delayed::Job.create :payload_object => SimpleJob.new, :attempts => 50
    expect(@job.reload.failed_at).to eq nil
    @job.reschedule 'FAIL'
    expect(@job.reload.failed_at).not_to eq nil

    Delayed::Job.destroy_failed_jobs = default
  end

  it "should be destroyed if it failed more than MAX_ATTEMPTS times and we want to destroy jobs" do
    default = Delayed::Job.destroy_failed_jobs
    Delayed::Job.destroy_failed_jobs = true

    @job = Delayed::Job.create :payload_object => SimpleJob.new, :attempts => 50
    expect(@job).to receive(:destroy)
    @job.reschedule 'FAIL'

    Delayed::Job.destroy_failed_jobs = default
  end

  it "should never find failed jobs" do
    @job = Delayed::Job.create :payload_object => SimpleJob.new, :attempts => 50, :failed_at => Time.now
    expect(Delayed::Job.find_available(1).length).to eq 0
  end

  context "when another worker is already performing an task, it" do

    before :each do
      Delayed::Job.worker_name = 'worker1'
      @job = Delayed::Job.create :payload_object => SimpleJob.new, :locked_by => 'worker1', :locked_at => Delayed::Job.db_time_now - 5.minutes
      # This examples are written assuming that job is killable.
      allow(@job).to receive(:killed?).and_return(true)
    end

    it "should not allow a second worker to get exclusive access" do
      expect(@job.lock_exclusively!(4.hours, 'worker2')).to eq false
    end

    it "should allow a second worker to get exclusive access if the timeout has passed" do
      expect(@job.lock_exclusively!(1.minute, 'worker2')).to eq true
    end

    it "should be able to get access to the task if it was started more then max_age ago" do
      @job.locked_at = 5.hours.ago
      @job.save

      @job.lock_exclusively! 4.hours, 'worker2'
      @job.reload
      expect(@job.locked_by).to eq 'worker2'
      expect(@job.locked_at).to be > 1.minute.ago
    end

    it "should not be found by another worker" do
      Delayed::Job.worker_name = 'worker2'

      expect(Delayed::Job.find_available(1, 6.minutes).length).to eq 0
    end

    it "should be found by another worker if the time has expired" do
      skip 'is it supported?'
      Delayed::Job.worker_name = 'worker2'

      expect(Delayed::Job.find_available(1, 4.minutes).length).to eq 1
    end

    it "should be able to get exclusive access again when the worker name is the same" do
      @job.lock_exclusively! 5.minutes, 'worker1'
      @job.lock_exclusively! 5.minutes, 'worker1'
      @job.lock_exclusively! 5.minutes, 'worker1'
    end
  end

  context "#name" do
    it "should be the class name of the job that was enqueued" do
      expect(Delayed::Job.create(:payload_object => ErrorJob.new ).name).to eq 'ErrorJob'
    end

    it "should be the method that will be called if its a performable method object" do
      Delayed::Job.send_later(:clear_locks!)
      expect(Delayed::Job.last.name).to eq 'Delayed::Job.clear_locks!'

    end
    it "should be the instance method that will be called if its a performable method object" do
      story = Story.create :text => "..."

      story.send_later(:save)

      expect(Delayed::Job.last.name).to eq 'Story#save'
    end
  end

  context "worker prioritization" do

    before(:each) do
      Delayed::Job.max_priority = nil
      Delayed::Job.min_priority = nil
    end

    it "should only work_off jobs that are >= min_priority" do
      Delayed::Job.min_priority = -5
      Delayed::Job.max_priority = 5
      expect(SimpleJob.runs).to eq 0

      Delayed::Job.enqueue SimpleJob.new, -10
      Delayed::Job.enqueue SimpleJob.new, 0
      Delayed::Job.work_off

      expect(SimpleJob.runs).to eq 1
    end

    it "should only work_off jobs that are <= max_priority" do
      Delayed::Job.min_priority = -5
      Delayed::Job.max_priority = 5
      expect(SimpleJob.runs).to eq 0

      Delayed::Job.enqueue SimpleJob.new, 10
      Delayed::Job.enqueue SimpleJob.new, 0

      Delayed::Job.work_off

      expect(SimpleJob.runs).to eq 1
    end

  end

  context "when pulling jobs off the queue for processing, it" do
    before(:each) do
      @job = Delayed::Job.create(
        :payload_object => SimpleJob.new,
        :locked_by => 'worker1',
        :locked_at => Delayed::Job.db_time_now - 5.minutes)
    end

    it "should leave the queue in a consistent state and not run the job if locking fails" do
      expect(SimpleJob.runs).to eq 0
      allow(@job).to receive(:lock_exclusively!).with(any_args).once.and_return(false)
      expect(Delayed::Job).to receive(:find_available).once.and_return([@job])
      Delayed::Job.work_off(1)
      expect(SimpleJob.runs).to eq 0
    end

  end

  context "while running alongside other workers that locked jobs, it" do
    before(:each) do
      Delayed::Job.worker_name = 'worker1'
      Delayed::Job.create(:payload_object => SimpleJob.new, :locked_by => 'worker1', :locked_at => (Delayed::Job.db_time_now - 1.minutes))
      Delayed::Job.create(:payload_object => SimpleJob.new, :locked_by => 'worker2', :locked_at => (Delayed::Job.db_time_now - 1.minutes))
      Delayed::Job.create(:payload_object => SimpleJob.new)
      Delayed::Job.create(:payload_object => SimpleJob.new, :locked_by => 'worker1', :locked_at => (Delayed::Job.db_time_now - 1.minutes))
    end

    it "should ingore locked jobs from other workers" do
      Delayed::Job.worker_name = 'worker3'
      expect(SimpleJob.runs).to eq 0
      Delayed::Job.work_off
      expect(SimpleJob.runs).to eq 1 # runs the one open job
    end

    it "should find our own jobs regardless of locks" do
      Delayed::Job.worker_name = 'worker1'
      expect(SimpleJob.runs).to eq 0
      Delayed::Job.work_off
      expect(SimpleJob.runs).to eq 3 # runs open job plus worker1 jobs that were already locked
    end
  end

  context "while running with locked and expired jobs, it" do
    before(:each) do
      Delayed::Job.worker_name = 'worker1'
      exp_time = Delayed::Job.db_time_now - (1.minutes + Delayed::Job::MAX_RUN_TIME)
      Delayed::Job.create(:payload_object => SimpleJob.new, :locked_by => 'worker1', :locked_at => exp_time)
      Delayed::Job.create(:payload_object => SimpleJob.new, :locked_by => 'worker2', :locked_at => (Delayed::Job.db_time_now - 1.minutes))
      Delayed::Job.create(:payload_object => SimpleJob.new)
      Delayed::Job.create(:payload_object => SimpleJob.new, :locked_by => 'worker1', :locked_at => (Delayed::Job.db_time_now - 1.minutes))
    end

    it "should only find unlocked and expired jobs" do
      Delayed::Job.worker_name = 'worker3'
      expect(SimpleJob.runs).to eq 0
      Delayed::Job.work_off
      skip 'looks like it shoud run expired job only on same worker'
      expect(SimpleJob.runs).to eq 2 # runs the one open job and one expired job
    end

    it "should ignore locks when finding our own jobs" do
      Delayed::Job.worker_name = 'worker1'
      expect(SimpleJob.runs).to eq 0
      Delayed::Job.work_off
      expect(SimpleJob.runs).to eq 3 # runs open job plus worker1 jobs
      # This is useful in the case of a crash/restart on worker1, but make sure multiple workers on the same host have unique names!
    end

  end

end
