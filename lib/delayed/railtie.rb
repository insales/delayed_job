require 'delayed_job'
require 'rails'

module Delayed
  class Railtie < Rails::Railtie
    rake_tasks do
      load 'tasks/tasks.rb'
      load 'tasks/jobs.rake'
    end
  end
end
