require 'database_helper'

class RandomRubyObject
  def say_hello
    'hello'
  end
end

class ErrorObject

  def throw
    raise ActiveRecord::RecordNotFound, '...'
    false
  end

end

class StoryReader

  def read(story)
    "Epilog: #{story.tell}"
  end

end

describe 'random ruby objects' do
  before       { Delayed::Job.delete_all }

  it "should respond_to :send_later method" do

    RandomRubyObject.new.respond_to?(:send_later)

  end

  it "should raise a ArgumentError if send_later is called but the target method doesn't exist" do
    expect { RandomRubyObject.new.send_later(:method_that_deos_not_exist) }.to raise_error(NoMethodError)
  end

  it "should add a new entry to the job table when send_later is called on it" do
    expect(Delayed::Job.count).to eq 0

    RandomRubyObject.new.send_later(:to_s)

    expect(Delayed::Job.count).to eq 1
  end

  it "should add a new entry to the job table when send_later is called on the class" do
    expect(Delayed::Job.count).to eq 0

    RandomRubyObject.send_later(:to_s)

    expect(Delayed::Job.count).to eq 1
  end

  it "should run get the original method executed when the job is performed" do

    RandomRubyObject.new.send_later(:say_hello)

    expect(Delayed::Job.count).to eq 1
  end

  it "should ignore ActiveRecord::RecordNotFound errors because they are permanent" do

    ErrorObject.new.send_later(:throw)

    expect(Delayed::Job.count).to eq 1

    Delayed::Job.reserve_and_run_one_job

    expect(Delayed::Job.count).to eq 0

  end

  it "should store the object as string if its an active record" do
    story = Story.create :text => 'Once upon...'
    story.send_later(:tell)

    job = Delayed::Job.first
    expect(job.payload_object.class).to eq Delayed::PerformableMethod
    expect(job.payload_object.object).to eq "AR:Story:#{story.id}"
    expect(job.payload_object.method).to eq :tell
    expect(job.payload_object.args).to eq([])
    expect(job.payload_object.perform).to eq 'Once upon...'
  end

  it "should store arguments as string if they an active record" do

    story = Story.create :text => 'Once upon...'

    reader = StoryReader.new
    reader.send_later(:read, 0, story)

    job = Delayed::Job.first
    expect(job.payload_object.class).to eq Delayed::PerformableMethod
    expect(job.payload_object.method).to eq :read
    expect(job.payload_object.args).to eq(["AR:Story:#{story.id}"])
    expect(job.payload_object.perform).to eq 'Epilog: Once upon...'
  end

  it "should call send later on methods which are wrapped with handle_asynchronously" do
    story = Story.create :text => 'Once upon...'

    expect(Delayed::Job.count).to eq 0

    story.whatever(1, 5)

    expect(Delayed::Job.count).to eq 1
    job = Delayed::Job.first
    expect(job.payload_object.class).to eq Delayed::PerformableMethod
    expect(job.payload_object.method).to eq :whatever_without_send_later
    expect(job.payload_object.args).to eq([1, 5])
    expect(job.payload_object.perform).to eq 'Once upon...'
  end

end
