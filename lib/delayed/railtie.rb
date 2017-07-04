require 'delayed_job'
require 'rails'

module Delayed
  class Railtie < Rails::Railtie
    rake_tasks do
      load 'taks/tasks.rb'
      load 'taks/jobs.rake'
    end
  end
end
