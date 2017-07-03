# Re-definitions are appended to existing tasks
task :environment
task :merb_env

namespace :jobs do
  desc "Clear the delayed_job queue."
  task :clear => [:merb_env, :environment] do
    Delayed::Job.delete_all
  end

  desc "Start a delayed_job worker."
  task :work => [:merb_env, :environment] do
    Delayed::Worker.new(:min_priority => ENV['MIN_PRIORITY'], :max_priority => ENV['MAX_PRIORITY']).start
  end

  desc "Destroy delayed_jobs locked by dead workers, and kill hanging workers"
  task :destroy => [:merb_env, :environment] do
  	Delayed::Job.where("locked_by ~ '\:#{Socket.gethostname} '").find_all(&:killed?).each do |d|
  	  puts "[#{Time.now}] id: #{d.id}, created_at: #{d.created_at}, locked_at: #{d.locked_at}, locked_by: #{d.locked_by}\nhandler: #{d.handler}\nlast_error: #{d.last_error}\n\n"
  	  d.destroy
  	end

  end
end
