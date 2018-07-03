Gem::Specification.new do |s|
  s.name     = "delayed_job"
  s.version  = "1.7.0"
  s.date     = "2008-11-28"
  s.summary  = "Database-backed asynchronous priority queue system -- Extracted from Shopify"
  s.email    = "tobi@leetsoft.com"
  s.homepage = "http://github.com/tobi/delayed_job/tree/master"
  s.description = "Delated_job (or DJ) encapsulates the common pattern of asynchronously executing longer tasks in the background. It is a direct extraction from Shopify where the job table is responsible for a multitude of core tasks."
  s.authors  = ["Tobias Lütke"]

  s.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^spec/}) }
  s.require_paths = ['lib']

  s.add_dependency 'activerecord', '>= 3.2', '< 4.0'
  s.add_dependency 'railties'

  s.add_development_dependency 'bundler'
  s.add_development_dependency 'rake'
end
